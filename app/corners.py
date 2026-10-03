"""Corners worth a warning along a planned route, from the route's own line. Pure functions: no database, no map service.

The line is resampled every STEP_M metres; at each sample the radius of the circle through it and its neighbours LOOK_M either side says how tight the bend is
and which way it turns. A run of samples that all turn the same way is one corner: its turning angle, its tightest radius and where it starts. Gentle sweepers
are left alone (a rider does not need telling), and a turn that is a junction is left to the turn-by-turn maneuver there ("turn left onto ...") so that the same
spot is not announced twice.

Like curvature.py the numbers are a judgement about what a motorcycle rider wants to be told, tuned by measurement on real routes (see tests/test_corners.py), not physics:
the advisory speed is the speed at which the bend is taken at a comfortable lateral acceleration, v = sqrt(a * R), rounded to 5 km/h.
"""
import math
from typing import Optional, Sequence

from . import curvature

STEP_M = 10.0
LOOK_STEPS = 2                       # the radius is read from the sample this many steps either side (20 m)
MIN_TURN_DEG = 1.5                   # a sample turns this much (over LOOK_STEPS steps) or it is a straight
GAP_STEPS = 2                        # a straight this short inside a bend does not end it
SHARP_RADIUS_M = 55.0                # tightest radius in the corner at most this: a sharp corner
SHARP_MIN_ANGLE = 45.0               # ... and it turns at least this much
HAIRPIN_RADIUS_M = 32.0
HAIRPIN_MIN_ANGLE = 110.0
LATERAL_MPS2 = 3.0                   # comfortable street-riding lateral acceleration used for the advisory speed
SERIES_COUNT = 3                     # this many sharp corners within SERIES_SPAN_M of the first make a series
SERIES_SPAN_M = 800.0
JUNCTION_M = 40.0                    # a corner this close to a maneuver is that maneuver's business


def advisory_kmh(radius_m: float) -> int:
    """The comfortable speed through a bend of this radius, rounded to 5 km/h and never below 15."""
    kmh = math.sqrt(LATERAL_MPS2 * radius_m) * 3.6
    return max(15, int(round(kmh / 5.0)) * 5)


def _turn_deg(a: tuple[float, float], b: tuple[float, float], c: tuple[float, float]) -> float:
    """Signed turn at b in degrees, positive to the left (planar points, x east and y north)."""
    h1 = math.atan2(b[1] - a[1], b[0] - a[0])
    h2 = math.atan2(c[1] - b[1], c[0] - b[0])
    d = math.degrees(h2 - h1)
    return (d + 180.0) % 360.0 - 180.0


def find(shape: Sequence[tuple[float, float]], maneuvers: Optional[Sequence[dict]] = None) -> list[dict]:
    """The sharp corners and hairpins on a route line [(lat, lon), ...], in order:
    {"along_m", "lat", "lon", "dir": "left" | "right", "kind": "sharp" | "hairpin", "radius_m", "angle_deg", "length_m", "advisory_kmh", "series": "start" | "in" | None}.
    `along_m` is where the corner begins, metres from the start of the line. Corners next to a maneuver (within JUNCTION_M) are dropped."""
    pts = curvature.resample(list(shape), STEP_M)
    n = len(pts)
    if n < 2 * LOOK_STEPS + 3:
        return []
    dist = curvature._cumulative(pts)
    xy = curvature._xy(pts)
    k = LOOK_STEPS
    radius = [math.inf] * n
    sign = [0] * n
    for i in range(k, n - k):
        turn = _turn_deg(xy[i - k], xy[i], xy[i + k])
        if abs(turn) < MIN_TURN_DEG:
            continue
        radius[i] = curvature.radius_m(xy[i - k], xy[i], xy[i + k])
        sign[i] = 1 if turn > 0 else -1

    runs: list[tuple[int, int]] = []
    i = k
    while i < n - k:
        if sign[i] == 0:
            i += 1
            continue
        start, last, side = i, i, sign[i]
        j = i + 1
        while j < n - k and j - last <= GAP_STEPS:
            if sign[j] == side:
                last = j
            elif sign[j] == -side:
                break
            j += 1
        runs.append((start, last))
        i = last + 1

    stops = sorted(m["along_m"] for m in (maneuvers or []))
    corners: list[dict] = []
    for start, last in runs:
        lo, hi = max(0, start - k), min(n - 1, last + k)
        angle = abs(sum(_turn_deg(xy[x - 1], xy[x], xy[x + 1]) for x in range(max(1, lo), min(n - 1, hi + 1))))
        tightest = min(radius[start:last + 1])
        length = dist[hi] - dist[lo]
        if tightest <= HAIRPIN_RADIUS_M and angle >= HAIRPIN_MIN_ANGLE:
            kind = "hairpin"
        elif tightest <= SHARP_RADIUS_M and angle >= SHARP_MIN_ANGLE:
            kind = "sharp"
        else:
            continue
        at = dist[lo]
        if any(at - JUNCTION_M <= m <= dist[hi] + JUNCTION_M for m in stops):
            continue
        corners.append({
            "along_m": round(at),
            "lat": round(pts[start][0], 6),
            "lon": round(pts[start][1], 6),
            "dir": "left" if sign[start] > 0 else "right",
            "kind": kind,
            "radius_m": round(tightest),
            "angle_deg": round(angle),
            "length_m": round(length),
            "advisory_kmh": advisory_kmh(tightest),
            "series": None,
        })

    # a run of three or more sharp corners close together: say "curves ahead" once, at the first
    first = 0
    while first < len(corners):
        last = first
        while last + 1 < len(corners) and corners[last + 1]["along_m"] - corners[first]["along_m"] <= SERIES_SPAN_M:
            last += 1
        if last - first + 1 >= SERIES_COUNT:
            corners[first]["series"] = "start"
            for x in range(first + 1, last + 1):
                corners[x]["series"] = "in"
            first = last + 1
        else:
            first += 1
    return corners


def per_km(corners: Sequence[dict], length_m: float) -> float:
    """Corners per kilometre, for measuring a threshold on a real route."""
    return len(corners) / max(0.001, length_m / 1000.0)

