"""Geometry helpers: distance, elevation, speed stats, and route simplification.

No third-party geo dependency (e.g. geopy, rdp) is used on purpose -- these are
all short, well-understood algorithms and pulling in a package for them isn't
worth it on a disk-constrained host.
"""

import math
from typing import Optional, Sequence

EARTH_RADIUS_M = 6371000.0

# Points with worse (larger) horizontal accuracy than this are dropped before
# computing distance/speed stats.
MAX_ACCURACY_M = 50.0

# A consecutive-point jump implying a faster speed than this (m/s, ~288 km/h)
# is treated as a GPS glitch and excluded from the distance sum.
MAX_PLAUSIBLE_SPEED_MPS = 80.0

# Altitude deltas smaller than this (meters) are treated as barometric/GPS
# noise and ignored entirely when summing elevation gain.
ELEV_NOISE_THRESHOLD_M = 2.0


def haversine_m(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    phi1, phi2 = math.radians(lat1), math.radians(lat2)
    dphi = math.radians(lat2 - lat1)
    dlambda = math.radians(lon2 - lon1)
    a = math.sin(dphi / 2) ** 2 + math.cos(phi1) * math.cos(phi2) * math.sin(dlambda / 2) ** 2
    return 2 * EARTH_RADIUS_M * math.asin(min(1.0, math.sqrt(a)))


def filter_points(points: Sequence[dict]) -> list[dict]:
    """Drop points with poor GPS accuracy or physically-impossible jumps.

    Each dict must have lat, lon, timestamp (datetime, timezone-aware) and may
    have horizontal_accuracy. `points` must already be sorted by timestamp.
    """
    filtered: list[dict] = []
    for p in points:
        acc = p.get("horizontal_accuracy")
        if acc is not None and (acc < 0 or acc > MAX_ACCURACY_M):
            continue
        if filtered:
            prev = filtered[-1]
            dt = (p["timestamp"] - prev["timestamp"]).total_seconds()
            if dt > 0:
                dist = haversine_m(prev["lat"], prev["lon"], p["lat"], p["lon"])
                if dist / dt > MAX_PLAUSIBLE_SPEED_MPS:
                    continue
        filtered.append(p)
    return filtered


def total_distance_m(points: Sequence[dict]) -> float:
    return sum(
        haversine_m(a["lat"], a["lon"], b["lat"], b["lon"]) for a, b in zip(points, points[1:])
    )


SPIKE_MPS = 5.0                 # a speed this far (18 km/h) from the mean of its two neighbours, ...
SPIKE_NEIGHBOURS_MPS = 4.0      # ... when those two agree with each other within this much, is a measuring glitch, not riding: no bike gains 20 m/s in a second and loses it the next


def despike(speeds: Sequence[Optional[float]]) -> list[Optional[float]]:
    """The speeds with single-sample spikes (up or down) replaced by the mean of their neighbours. A speed worked out from two fixes is distance over the time between them;
    when a fix's time is rounded to the second the two can be 1 s apart on the record and nearly 2 s apart in fact, which doubles that one speed (and the next one halves).
    Real changes of speed last more than one sample, or the neighbours would not agree; they are left alone. None stays None."""
    out = list(speeds)
    for i in range(1, len(speeds) - 1):
        s, a, b = speeds[i], speeds[i - 1], speeds[i + 1]
        if s is None or a is None or b is None or abs(a - b) > SPIKE_NEIGHBOURS_MPS:
            continue
        mean = (a + b) / 2.0
        if abs(s - mean) > SPIKE_MPS:
            out[i] = mean
    return out


def max_speed_mps(points: Sequence[dict]) -> float:
    speeds = despike([p["speed"] if p.get("speed") is not None and p["speed"] >= 0 else None for p in points])
    valid = [s for s in speeds if s is not None]
    return max(valid) if valid else 0.0


def elevation_gain_m(points: Sequence[dict]) -> float:
    gain = 0.0
    last_altitude = None
    for p in points:
        alt = p.get("altitude")
        if alt is None:
            continue
        if last_altitude is not None:
            delta = alt - last_altitude
            if delta > ELEV_NOISE_THRESHOLD_M:
                gain += delta
        last_altitude = alt
    return gain


def _to_local_xy(lat: float, lon: float, ref_lat: float) -> tuple[float, float]:
    """Local equirectangular projection so RDP epsilon can be given in meters."""
    x = math.radians(lon) * math.cos(math.radians(ref_lat)) * EARTH_RADIUS_M
    y = math.radians(lat) * EARTH_RADIUS_M
    return x, y


def _perpendicular_distance_m(pt, start, end) -> float:
    if start == end:
        return math.hypot(pt[0] - start[0], pt[1] - start[1])
    num = abs(
        (end[1] - start[1]) * pt[0]
        - (end[0] - start[0]) * pt[1]
        + end[0] * start[1]
        - end[1] * start[0]
    )
    den = math.hypot(end[0] - start[0], end[1] - start[1])
    return num / den


def rdp_simplify(
    latlon_points: list[tuple[float, float]], epsilon_m: float = 5.0
) -> list[tuple[float, float]]:
    """Ramer-Douglas-Peucker route simplification for smoother map rendering."""
    if len(latlon_points) < 3:
        return list(latlon_points)

    ref_lat = latlon_points[0][0]
    xy = [_to_local_xy(lat, lon, ref_lat) for lat, lon in latlon_points]

    def _rdp(start_i: int, end_i: int) -> list[int]:
        start, end = xy[start_i], xy[end_i]
        max_dist = -1.0
        split = None
        for i in range(start_i + 1, end_i):
            d = _perpendicular_distance_m(xy[i], start, end)
            if d > max_dist:
                max_dist = d
                split = i
        if split is not None and max_dist > epsilon_m:
            left = _rdp(start_i, split)
            right = _rdp(split, end_i)
            return left[:-1] + right
        return [start_i, end_i]

    kept_indices = _rdp(0, len(xy) - 1)
    return [latlon_points[i] for i in kept_indices]
