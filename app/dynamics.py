"""Lean angle and G-forces ESTIMATED FROM GPS, for the ride screen. Pure functions: no database, no network.

How: a bike in a steady corner at speed v turning at yaw rate w (how fast its heading changes) pulls sideways with a = v * w, and the rider leans until
tan(lean) = a / g. Heading comes from the phone's own course (measured from the GPS Doppler, good to a few degrees) when the ride has it, and otherwise from
the bearing between positions a few metres before and after each fix (every ride recorded before this feature, and Overland rides). Forwards and backwards
G come from how fast the speed changes.

Measured limits (synthetic rides, 3 m GPS error): with the phone's course a corner is found every time and the peak is within about 3 degrees; from positions a
tight 5-second corner is missed about one time in four and the peak reads about 3 degrees low, so old rides under-report their shortest corners.

What it is NOT, and the app says so: not a measurement. It assumes a steady corner (a quick flick is under-read), ignores tyre profile and the rider hanging
off the bike (the real lean differs), and 1 Hz GPS cannot see a tight corner at speed. Treat it as a way to compare corners and rides with each other.
"""
import math
from typing import Optional, Sequence

G = 9.80665
MIN_SPEED_MPS = 6.0            # about 22 km/h: slower than this a bike is not leaning on a line, and the heading is mostly noise
MAX_GAP_S = 3.0                # a longer gap between two neighbouring fixes is not differentiated across
COURSE_WINDOW_S = 1.6          # yaw rate and acceleration are the slope over fixes this close to the one in question ...
POSITION_WINDOW_S = 3.0        # ... a longer window when the heading itself comes from positions, which are noisier
BASELINE_M = 20.0              # a position-derived heading uses the fixes this far (along the track) before and after
COURSE_MAX_ACCURACY_DEG = 25.0
COURSE_SHARE_NEEDED = 0.9      # the ride counts as having course when this share of its moving fixes carry a usable one (iOS has one at any real speed)
MAX_LEAN_DEG = 60.0
CORNER_LEAN_DEG = 12.0         # a corner is a spell at least this leaned over, to one side ...
CORNER_MIN_S = 2.0             # ... for at least this long (the phone's own course is precise enough for that)
CORNER_MIN_S_POSITIONS = 3.0   # ... and this long when the heading comes from positions: measured, shorter spells appear on straight roads with a poor GPS fix
CORNER_GAP_S = 2.5             # fixes further apart than this end a corner
MIN_POINTS = 30
MIN_DISTANCE_M = 1000.0
MAX_SERIES = 400


def _wrap(angle: float) -> float:
    """Radians into (-pi, pi]."""
    return (angle + math.pi) % (2 * math.pi) - math.pi if not -math.pi < angle <= math.pi else angle


def _bearing(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    """Radians clockwise from north."""
    p1, p2, dl = math.radians(lat1), math.radians(lat2), math.radians(lon2 - lon1)
    return math.atan2(math.sin(dl) * math.cos(p2), math.cos(p1) * math.sin(p2) - math.sin(p1) * math.cos(p2) * math.cos(dl))


def _course_headings(points: Sequence[dict]) -> list[Optional[float]]:
    out: list[Optional[float]] = []
    for p in points:
        course, accuracy = p.get("course"), p.get("course_accuracy")
        usable = course is not None and 0 <= course < 360 and (accuracy is None or accuracy < 0 or accuracy <= COURSE_MAX_ACCURACY_DEG)
        out.append(math.radians(course) if usable else None)
    return out


def _position_headings(points: Sequence[dict]) -> list[Optional[float]]:
    """The direction of travel at each fix from the fixes BASELINE_M before and after it along the track (shorter near the ends, none at the very ends)."""
    n = len(points)
    out: list[Optional[float]] = [None] * n
    before = 0
    after = 0
    for i in range(n):
        d = points[i]["dist"]
        while before < i and points[before + 1]["dist"] <= d - BASELINE_M:
            before += 1
        after = max(after, i)
        while after < n - 1 and points[after]["dist"] < d + BASELINE_M:
            after += 1
        a, b = points[before], points[after]
        if before < i and after > i and points[i]["dist"] - a["dist"] >= BASELINE_M * 0.5 and b["dist"] - points[i]["dist"] >= BASELINE_M * 0.5:
            out[i] = _bearing(a["lat"], a["lon"], b["lat"], b["lon"])
    return out


def _slopes(points: Sequence[dict], headings: Sequence[Optional[float]], window: float) -> list[tuple[Optional[float], Optional[float]]]:
    """(yaw rate rad/s, acceleration m/s2) at each fix: the least-squares slope through the fixes within `window` seconds of it."""
    n = len(points)
    out: list[tuple[Optional[float], Optional[float]]] = []
    lo = 0
    for i in range(n):
        t = points[i]["t"]
        while points[lo]["t"] < t - window:
            lo += 1
        hi = i
        while hi + 1 < n and points[hi + 1]["t"] <= t + window:
            hi += 1
        indexes = list(range(lo, hi + 1))
        gaps_ok = all(points[j + 1]["t"] - points[j]["t"] <= MAX_GAP_S for j in range(lo, hi))
        span = points[hi]["t"] - points[lo]["t"]
        if len(indexes) < 3 or span < window * 0.9 or not gaps_ok or headings[i] is None:
            out.append((None, None))
            continue
        yaw_num = yaw_den = acc_num = acc_den = 0.0
        yaw_used = 0
        for j in indexes:
            dt = points[j]["t"] - t
            acc_num += dt * (points[j]["mps"] - points[i]["mps"])
            acc_den += dt * dt
            if headings[j] is not None:
                yaw_num += dt * _wrap(headings[j] - headings[i])
                yaw_den += dt * dt
                yaw_used += 1
        if yaw_used < 3 or yaw_den <= 0 or acc_den <= 0:
            out.append((None, None))
        else:
            out.append((yaw_num / yaw_den, acc_num / acc_den))
    return out


def analyze(points: Sequence[dict]) -> Optional[dict]:
    """points: prepared track points (t, lat, lon, mps, dist, optional course / course_accuracy). None when there is too little to say anything."""
    n = len(points)
    if n < MIN_POINTS or points[-1]["dist"] < MIN_DISTANCE_M:
        return None
    moving = [i for i, p in enumerate(points) if p["mps"] >= MIN_SPEED_MPS]
    if len(moving) < MIN_POINTS // 2:
        return None
    course = _course_headings(points)
    with_course = sum(1 for i in moving if course[i] is not None)
    use_course = with_course >= COURSE_SHARE_NEEDED * len(moving)
    headings = course if use_course else _position_headings(points)
    slopes = _slopes(points, headings, COURSE_WINDOW_S if use_course else POSITION_WINDOW_S)

    samples: list[Optional[dict]] = []
    for i, p in enumerate(points):
        yaw, acc = slopes[i]
        if p["mps"] < MIN_SPEED_MPS or yaw is None:
            samples.append(None)
            continue
        lateral = p["mps"] * yaw
        lean = max(-MAX_LEAN_DEG, min(MAX_LEAN_DEG, math.degrees(math.atan(lateral / G))))
        samples.append({"i": i, "lean": lean, "lat_g": lateral / G, "long_g": acc / G})
    samples = _smooth(points, samples)
    valid = [s for s in samples if s]
    if len(valid) < MIN_POINTS // 2:
        return None

    # The headline numbers come from corners only (a spell of a few seconds above CORNER_LEAN_DEG). A single fix's lean on a straight road is noise that grows
    # with speed (measured: up to 20 degrees at 100 km/h with a 3 m position error), and must not become "your max lean".
    corners = _corners(points, samples, CORNER_MIN_S if use_course else CORNER_MIN_S_POSITIONS)
    left = max((c["peak_lean"] for c in corners if c["direction"] == "left"), default=0)
    right = max((c["peak_lean"] for c in corners if c["direction"] == "right"), default=0)
    best = max(corners, key=lambda c: c["peak_lean"], default=None)
    return {
        "source": "course" if use_course else "positions",
        "max_left_deg": left,
        "max_right_deg": right,
        "corner_count": len(corners),
        "best_corner": best,
        "corners": sorted(corners, key=lambda c: -c["peak_lean"])[:20],
        "max_braking_g": round(-min((s["long_g"] for s in valid), default=0.0), 2),
        "max_accel_g": round(max((s["long_g"] for s in valid), default=0.0), 2),
        "max_lateral_g": round(max((abs(s["lat_g"]) for s in valid), default=0.0), 2),
        "series": _series(points, samples),
    }


def _smooth(points: Sequence[dict], samples: Sequence[Optional[dict]]) -> list[Optional[dict]]:
    """Each fix's lean and lateral G averaged 1-2-1 with its neighbours (where both are there and close in time): the estimates overlap, so this takes the
    edge off single-fix spikes while a real corner, several seconds long, keeps its peak."""
    out: list[Optional[dict]] = []
    for i, s in enumerate(samples):
        if s is None:
            out.append(None)
            continue
        a = samples[i - 1] if i > 0 else None
        b = samples[i + 1] if i + 1 < len(samples) else None
        if a and b and points[i + 1]["t"] - points[i - 1]["t"] <= 2 * MAX_GAP_S:
            out.append({**s, "lean": (a["lean"] + 2 * s["lean"] + b["lean"]) / 4, "lat_g": (a["lat_g"] + 2 * s["lat_g"] + b["lat_g"]) / 4})
        else:
            out.append(s)
    return out


def _corners(points: Sequence[dict], samples: Sequence[Optional[dict]], min_seconds: float) -> list[dict]:
    """Spells leaned over to one side: lean beyond CORNER_LEAN_DEG without a break longer than CORNER_GAP_S, at least `min_seconds` long."""
    corners: list[dict] = []
    run: list[dict] = []

    def close() -> None:
        nonlocal run
        if run and points[run[-1]["i"]]["t"] - points[run[0]["i"]]["t"] >= min_seconds:
            apex = max(run, key=lambda s: abs(s["lean"]))
            first, last, ap = points[run[0]["i"]], points[run[-1]["i"]], points[apex["i"]]
            corners.append({
                "direction": "right" if apex["lean"] > 0 else "left",
                "t_start": round(first["t"], 1), "t_end": round(last["t"], 1), "t_apex": round(ap["t"], 1),
                "peak_lean": round(abs(apex["lean"])), "peak_g": round(abs(apex["lat_g"]), 2),
                "entry_kmh": round(first["mps"] * 3.6), "apex_kmh": round(ap["mps"] * 3.6), "exit_kmh": round(last["mps"] * 3.6),
                "length_m": round(last["dist"] - first["dist"]), "dist_m": round(first["dist"]),
                "lat": round(ap["lat"], 6), "lon": round(ap["lon"], 6),
            })
        run = []

    for s in samples:
        if s is None or abs(s["lean"]) < CORNER_LEAN_DEG:
            close()
            continue
        if run:
            same_side = (s["lean"] > 0) == (run[-1]["lean"] > 0)
            near = points[s["i"]]["t"] - points[run[-1]["i"]]["t"] <= CORNER_GAP_S
            if not (same_side and near):
                close()
        run.append(s)
    close()
    return corners


def _series(points: Sequence[dict], samples: Sequence[Optional[dict]]) -> list[list]:
    """[[t, lean, lateral g, longitudinal g, km/h], ...], at most MAX_SERIES rows. Each stretch of the ride is represented by its most leaned-over fix,
    so the peaks are still in a long ride's chart."""
    valid = [s for s in samples if s]
    stride = max(1, math.ceil(len(valid) / MAX_SERIES))
    rows = []
    for start in range(0, len(valid), stride):
        bucket = valid[start:start + stride]
        s = max(bucket, key=lambda x: abs(x["lean"]))
        p = points[s["i"]]
        rows.append([round(p["t"], 1), round(s["lean"], 1), round(s["lat_g"], 2), round(s["long_g"], 2), round(p["mps"] * 3.6)])
    return rows
