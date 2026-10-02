"""How twisty a road is, from its shape alone (OpenStreetMap geometry). Pure functions: no database, no map file.

A road is resampled every STEP_M metres; at each sample the radius of the circle through it and its two neighbours says how tight the bend there is. Each
band of radius counts for a different share of the stretch it covers (a gentle sweeper a little, a tight bend a lot, a hairpin the same as a tight bend because
it is slow), and the score is that weighted length as a share of the whole stretch: a road that is one long tight-ish bend after another scores 100, a straight
one 0. Roads are cut into stretches of about 1.5 km so that a long road with one twisty section does not average itself out to nothing.

The radius bands and the weights are a judgement about what is fun on a motorcycle, not physics; the numbers are tuned by measurement on synthetic roads
(tests/test_curvature.py) so that they do not depend on how finely a mapper happened to digitise a bend.
"""
import math
from typing import Optional, Sequence

from . import geo

STEP_M = 30.0
TARGET_SEGMENT_M = 1500.0
MIN_SEGMENT_M = 400.0                     # a stretch shorter than this is not worth a ride of its own
MIN_WAY_M = 300.0
# (radius at least this many metres, share of the stretch that bend counts for): the first row that fits wins, from gentlest down
WEIGHTS = ((400.0, 0.0), (200.0, 0.25), (100.0, 0.6), (50.0, 1.0), (25.0, 1.4), (0.0, 1.0))
PAVED_NO = {"unpaved", "gravel", "dirt", "ground", "sand", "grass", "mud", "compacted", "fine_gravel", "pebblestone", "earth", "dirt/sand", "woodchips"}
WANTED_HIGHWAYS = ("primary", "secondary", "tertiary", "unclassified")
BLOCKED_ACCESS = {"no", "private", "agricultural", "forestry", "delivery"}


def weight(radius_m: float) -> float:
    for floor, w in WEIGHTS:
        if radius_m >= floor:
            return w
    return 1.0


def _xy(points: Sequence[tuple[float, float]]) -> list[tuple[float, float]]:
    lat0, lon0 = points[0]
    kx = math.cos(math.radians(lat0)) * 111_194.9266
    ky = 111_194.9266
    return [((lon - lon0) * kx, (lat - lat0) * ky) for lat, lon in points]


def radius_m(a: tuple[float, float], b: tuple[float, float], c: tuple[float, float]) -> float:
    """Radius of the circle through three planar points, infinity for a straight line."""
    ab, bc, ca = math.dist(a, b), math.dist(b, c), math.dist(c, a)
    twice_area = abs((b[0] - a[0]) * (c[1] - a[1]) - (c[0] - a[0]) * (b[1] - a[1]))
    if twice_area < 1e-6:
        return math.inf
    return ab * bc * ca / (2.0 * twice_area)


def resample(coords: Sequence[tuple[float, float]], step: float = STEP_M) -> list[tuple[float, float]]:
    """(lat, lon) points every `step` metres along the line, ending at its last point."""
    if len(coords) < 2:
        return list(coords)
    out = [tuple(coords[0])]
    carried = 0.0                                   # distance already covered since the last sample
    for (lat1, lon1), (lat2, lon2) in zip(coords, coords[1:]):
        seg = geo.haversine_m(lat1, lon1, lat2, lon2)
        if seg <= 0:
            continue
        pos = step - carried
        while pos <= seg:
            f = pos / seg
            out.append((lat1 + (lat2 - lat1) * f, lon1 + (lon2 - lon1) * f))
            pos += step
        carried = seg - (pos - step)
    last = tuple(coords[-1])
    if geo.haversine_m(out[-1][0], out[-1][1], last[0], last[1]) >= step * 0.5:
        out.append(last)
    elif len(out) > 1:
        out[-1] = last
    return out


def _cumulative(points: Sequence[tuple[float, float]]) -> list[float]:
    dist = [0.0]
    for (a, b), (c, d) in zip(points, points[1:]):
        dist.append(dist[-1] + geo.haversine_m(a, b, c, d))
    return dist


def segments(coords: Sequence[tuple[float, float]]) -> list[dict]:
    """Cuts one road into stretches of about TARGET_SEGMENT_M and scores each: [{"length_m", "curvy_m", "score", "geometry": [[lat, lon], ...]}, ...]."""
    pts = resample(coords)
    n = len(pts)
    if n < 3:
        return []
    dist = _cumulative(pts)
    total = dist[-1]
    if total < MIN_WAY_M:
        return []
    xy = _xy(pts)
    weighted = [0.0] * n                               # the length each sample's bend is worth
    for i in range(1, n - 1):
        weighted[i] = weight(radius_m(xy[i - 1], xy[i], xy[i + 1])) * ((dist[i + 1] - dist[i - 1]) / 2.0)
    parts = max(1, round(total / TARGET_SEGMENT_M))
    out = []
    for k in range(parts):
        lo = round(k * (n - 1) / parts)
        hi = round((k + 1) * (n - 1) / parts)
        length = dist[hi] - dist[lo]
        if hi - lo < 2 or length < MIN_SEGMENT_M and parts > 1:
            continue
        curvy = sum(weighted[lo:hi + 1])
        out.append({
            "length_m": round(length),
            "curvy_m": round(curvy),
            "score": min(100, round(100.0 * curvy / length)) if length > 0 else 0,
            "geometry": [[round(lat, 5), round(lon, 5)] for lat, lon in pts[lo:hi + 1]],
        })
    return out


def paved(tags: dict) -> bool:
    """False for an unpaved surface. Unknown counts as paved: the roads wanted here (primary to unclassified) nearly always are."""
    surface = (tags.get("surface") or "").lower()
    if surface in PAVED_NO:
        return False
    return (tags.get("tracktype") or "") not in {"grade3", "grade4", "grade5"}


def maxspeed_kmh(tags: dict) -> Optional[int]:
    text = (tags.get("maxspeed") or "").strip()
    digits = ""
    for ch in text:
        if ch.isdigit():
            digits += ch
        else:
            break
    return int(digits) if digits and "mph" not in text else None


def wanted(tags: dict) -> bool:
    """Is this road one to ride for fun: a real road (primary, secondary, tertiary, unclassified) open to motorcycles, above ground."""
    if tags.get("highway") not in WANTED_HIGHWAYS:
        return False
    if tags.get("area") == "yes" or tags.get("tunnel") in ("yes", "building_passage") or tags.get("construction"):
        return False
    for key in ("access", "motor_vehicle", "vehicle", "motorcycle"):
        value = tags.get(key)
        if value in BLOCKED_ACCESS and not (key != "motorcycle" and tags.get("motorcycle") == "yes"):
            return False
    return True
