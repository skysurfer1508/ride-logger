"""Route planning for the Roads layer: a loop of a chosen length that goes through the twistiest roads nearby, or a plain A-to-B route. Pure logic on top of two
services it is handed: Valhalla for the routing (app/valhalla.py) and the twisty-road database (app/roads.py). No turn-by-turn: the result is a line on a map.

How a loop is found. Roads do not form neat circles, so many candidates are tried and the best kept:
  1. Waypoints go round a circle that passes through the start, sized so the loop should come out near the wanted length (a route between points is about
     1.35 times longer than the straight line). Each waypoint is moved onto the best twisty stretch of the road database nearby, and the route is made to go
     along that stretch (in through one end, out through the other).
  2. Valhalla routes every candidate; the circle is then rescaled by how far off the lengths came out, and a second round is tried.
  3. Each route is scored on the twistiness of its actual shape (the same measure as the Roads layer), on the share of it that doubles back over road it has
     already used, on how close the length is to the wish, and optionally on how much of it is road you have not ridden yet. The best few that differ from
     each other are returned.
The score is a heuristic for "a good ride", not a promise: it knows the shape of the roads, not their surface, traffic or whether a pass is open.
"""
import math
from concurrent.futures import ThreadPoolExecutor
from statistics import median
from typing import Optional, Sequence

from . import corners, curvature, geo, roads, valhalla

ROAD_FACTOR = 1.35               # a route between points is about this much longer than the straight line
MIN_KM, MAX_KM = 20.0, 400.0
SNAPPED, PLAIN = 12, 6           # candidates whose waypoints move onto twisty stretches, and plain circles for comparison
ROUNDS = 3                       # each candidate is re-sized this many times at most
CALIBRATED = 0.08                # a loop within this share of the wished length needs no re-sizing
WORKERS = 4
MAX_ROUTES = 3
LENGTH_TOLERANCE = 0.25          # a loop this much longer or shorter than wished is still offered, if there is nothing better
SNAP_SHARE = 0.3                 # a waypoint may move this share of the circle's radius to reach a twisty stretch
MIN_SNAP_M = 2000.0
MAX_SNAP_M = 15000.0
SNAP_SCORES = (55, 40)           # first look for stretches at least this twisty, then at least that
RETRACE_MIN_ALONG_M = 1500.0     # a point counts as doubling back when the road was already used at least this far earlier along the route
CELL_DEG = 0.0006                # about 65 m: how close two points must be to count as the same place
RIDDEN_CELL_DEG = 0.0004
DISTINCT_OVERLAP = 0.6           # two alternatives sharing more than this much of their road are the same loop
SHAPE_POINTS = 800


class PlannerError(Exception):
    """The plan cannot be made; the message is for the person."""


# --------------------------------------------------------------------------------------------------------------------------------- geometry --

def destination(lat: float, lon: float, bearing_deg: float, metres: float) -> tuple[float, float]:
    b = math.radians(bearing_deg)
    d = metres / 6_371_000.0
    p1, l1 = math.radians(lat), math.radians(lon)
    p2 = math.asin(math.sin(p1) * math.cos(d) + math.cos(p1) * math.sin(d) * math.cos(b))
    l2 = l1 + math.atan2(math.sin(b) * math.sin(d) * math.cos(p1), math.cos(d) - math.sin(p1) * math.sin(p2))
    return math.degrees(p2), (math.degrees(l2) + 540.0) % 360.0 - 180.0


def circle_waypoints(start: tuple[float, float], target_m: float, rotation_deg: float, clockwise: bool, radius_scale: float = 1.0) -> list[tuple[float, float]]:
    """Three waypoints on a circle through `start` that should give a loop of about `target_m`. `rotation_deg` is the direction from the start to the circle's centre."""
    radius = radius_scale * target_m / (2.0 * math.pi * ROAD_FACTOR)
    centre = destination(start[0], start[1], rotation_deg, radius)
    first = (rotation_deg + 180.0) % 360.0                       # bearing from the centre back to the start
    step = 90.0 if clockwise else -90.0
    return [destination(centre[0], centre[1], first + step * k, radius) for k in (1, 2, 3)]


def _cell(lat: float, lon: float, size: float) -> tuple[int, int]:
    return round(lat / size), round(lon / size)


def _cells_around(cell: tuple[int, int]):
    for di in (-1, 0, 1):
        for dj in (-1, 0, 1):
            yield cell[0] + di, cell[1] + dj


# ------------------------------------------------------------------------------------------------------------------------------- measuring --

def measure(shape: Sequence[tuple[float, float]], ridden: Optional[set] = None) -> dict:
    """What a route is like: length, how twisty (same measure as the Roads layer), how much doubles back, how much is road you have not ridden."""
    pts = curvature.resample(list(shape), curvature.STEP_M)
    segs = curvature.segments(shape)
    length = sum(s["length_m"] for s in segs) or 1
    curvy = sum(s["curvy_m"] for s in segs)
    seen: dict[tuple[int, int], float] = {}
    retraced = 0
    along = 0.0
    prev = None
    for lat, lon in pts:
        if prev is not None:
            along += geo.haversine_m(prev[0], prev[1], lat, lon)
        prev = (lat, lon)
        cell = _cell(lat, lon, CELL_DEG)
        earlier = [seen[c] for c in _cells_around(cell) if c in seen]
        if earlier and along - min(earlier) >= RETRACE_MIN_ALONG_M:
            retraced += 1
        seen.setdefault(cell, along)
    known = 0
    if ridden:
        for lat, lon in pts:
            cell = _cell(lat, lon, RIDDEN_CELL_DEG)
            if any(c in ridden for c in _cells_around(cell)):
                known += 1
    return {
        "twist_density": curvy / length,
        "twisty_m": curvy,
        "retraced_share": retraced / max(1, len(pts)),
        "ridden_share": known / max(1, len(pts)),
        "cells": {_cell(lat, lon, CELL_DEG) for lat, lon in pts},
    }


def quality(measured: dict, distance_m: float, target_m: Optional[float], prefer_new: bool) -> float:
    q = measured["twist_density"] * (1.0 - min(0.9, measured["retraced_share"] * 2.0))
    if target_m:
        q *= 1.0 - min(0.6, abs(distance_m - target_m) / target_m)
    if prefer_new:
        q *= 1.0 - 0.6 * measured["ridden_share"]
    return q


def _overlap(a: set, b: set) -> float:
    return len(a & b) / max(1, min(len(a), len(b)))


def present(route: dict, measured: dict, name: str, *, waypoints: Optional[list] = None, mode: Optional[str] = None) -> dict:
    """A route as the app gets it. When the route has maneuvers (it was asked for with directions) the full-resolution line (encoded polyline6) and the maneuvers go
    along for turn-by-turn; `waypoints` are the stops that make the route, so the app can ask for the same route again (a saved route, a reroute)."""
    shape = route["shape"]
    step = max(25.0, route["distance_m"] / SHAPE_POINTS)
    thin = curvature.resample(shape, step)
    out = {
        "name": name,
        "distance_km": round(route["distance_m"] / 1000.0, 1),
        "duration_min": round(route["duration_s"] / 60.0),
        "twisty_km": round(measured["twisty_m"] / 1000.0, 1),
        "twistiness": min(100, round(100.0 * measured["twist_density"])),
        "retraced_pct": round(100.0 * measured["retraced_share"]),
        "new_pct": round(100.0 * (1.0 - measured["ridden_share"])),
        "shape": [[round(lat, 5), round(lon, 5)] for lat, lon in thin],
    }
    if mode:
        out["mode"] = mode
    if waypoints is not None:
        out["waypoints"] = [{"lat": round(w["lat"], 6), "lon": round(w["lon"], 6), "type": w.get("type", "break")} for w in waypoints]
    if route.get("maneuvers"):
        out["shape6"] = valhalla.encode_polyline6(shape)
        out["maneuvers"] = route["maneuvers"]
        out["corners"] = corners.find(shape, route["maneuvers"])
    return out


# --------------------------------------------------------------------------------------------------------------------------------- snapping --

def snap_to_twisty(conn, point: tuple[float, float], radius_m: float, previous: tuple[float, float]) -> Optional[list[tuple[float, float]]]:
    """The two ends of the best twisty stretch within `radius_m` of `point`, the end nearer `previous` first; None without one."""
    if conn is None:
        return None
    d_lat = radius_m / 111_194.9266
    d_lon = d_lat / max(0.2, math.cos(math.radians(point[0])))
    for floor in SNAP_SCORES:
        found, _ = roads.query(conn, point[0] - d_lat, point[1] - d_lon, point[0] + d_lat, point[1] + d_lon, 1, floor, True)
        if found:
            line = found[0]["geometry"]
            ends = [(line[0][0], line[0][1]), (line[-1][0], line[-1][1])]
            ends.sort(key=lambda e: geo.haversine_m(previous[0], previous[1], e[0], e[1]))
            return ends
    return None


def loop_locations(conn, start: tuple[float, float], target_m: float, rotation: float, clockwise: bool, scale: float) -> list[dict]:
    waypoints = circle_waypoints(start, target_m, rotation, clockwise, scale)
    radius = scale * target_m / (2.0 * math.pi * ROAD_FACTOR)
    snap_m = min(MAX_SNAP_M, max(MIN_SNAP_M, SNAP_SHARE * radius))
    locations = [{"lat": start[0], "lon": start[1], "type": "break"}]
    previous = start
    for wp in waypoints:
        ends = snap_to_twisty(conn, wp, snap_m, previous)
        if ends:
            locations += [{"lat": e[0], "lon": e[1], "type": "through"} for e in ends]
            previous = ends[-1]
        else:
            locations.append({"lat": wp[0], "lon": wp[1], "type": "through"})
            previous = wp
    locations.append({"lat": start[0], "lon": start[1], "type": "break"})
    return locations


# ------------------------------------------------------------------------------------------------------------------------------------- loops --

def _try(locations: list[dict], avoid_motorways: bool, paved_only: bool, **extra) -> Optional[dict]:
    try:
        route = valhalla.route(locations, avoid_motorways=avoid_motorways, paved_only=paved_only, **extra)
    except valhalla.NoRoute:
        return None
    route["locations"] = locations                       # kept so that the chosen routes can be asked for again with directions
    return route


def plan_loops(start: tuple[float, float], distance_km: float, roads_conn=None, ridden: Optional[set] = None, avoid_motorways: bool = True, paved_only: bool = True,
               prefer_new: bool = False) -> dict:
    """Up to MAX_ROUTES different loops of about `distance_km` from `start`. Raises valhalla.ValhallaUnavailable when the routing service is off or down, and
    PlannerError when no loop could be made."""
    if not MIN_KM <= distance_km <= MAX_KM:
        raise PlannerError(f"Choose a length between {MIN_KM:.0f} and {MAX_KM:.0f} km.")
    target_m = distance_km * 1000.0

    # a candidate is a direction to the circle's centre, which way round, and whether its waypoints move onto twisty stretches; each keeps its own scale,
    # corrected after every round by how far its route came out from the wanted length (forcing a route through a stretch adds detours)
    candidates = [{"rotation": i * 360.0 / SNAPPED, "clockwise": i % 2 == 0, "snap": roads_conn is not None, "scale": 1.0} for i in range(SNAPPED)]
    candidates += [{"rotation": i * 360.0 / PLAIN + 15.0, "clockwise": i % 2 == 1, "snap": False, "scale": 1.0} for i in range(PLAIN)]
    results: list[dict] = []
    pending = candidates

    def run(batch: list[dict]) -> list[Optional[dict]]:
        jobs = [loop_locations(roads_conn if c["snap"] else None, start, target_m, c["rotation"], c["clockwise"], c["scale"]) for c in batch]
        with ThreadPoolExecutor(max_workers=WORKERS) as pool:
            return list(pool.map(lambda locs: _try(locs, avoid_motorways, paved_only), jobs))

    for _ in range(ROUNDS):
        if not pending:
            break
        again = []
        for candidate, route in zip(pending, run(pending)):
            if route is None:
                continue
            results.append(route)
            error = (route["distance_m"] - target_m) / target_m
            if abs(error) > CALIBRATED:
                candidate["scale"] = max(0.4, min(2.0, candidate["scale"] * target_m / route["distance_m"]))
                again.append(candidate)
        pending = again
    if not results:
        raise PlannerError("No loop could be found from there. Try a start point on a normal road, or a different length.")

    scored = []
    for route in results:
        m = measure(route["shape"], ridden)
        scored.append((quality(m, route["distance_m"], target_m, prefer_new), route, m))
    scored.sort(key=lambda item: -item[0])
    near = [s for s in scored if abs(s[1]["distance_m"] - target_m) <= LENGTH_TOLERANCE * target_m] or scored[:1]
    chosen: list[tuple[float, dict, dict]] = []
    for item in near:
        if all(_overlap(item[2]["cells"], other[2]["cells"]) < DISTINCT_OVERLAP for other in chosen):
            chosen.append(item)
        if len(chosen) == MAX_ROUTES:
            break
    names = ["Best loop", "Alternative", "Another option"]
    presented = []
    for i, (_, route, measured) in enumerate(chosen):
        guided = _try(route["locations"], avoid_motorways, paved_only, directions=True) or route         # the same stops again, this time with the turns
        presented.append(present(guided, measured, names[i], waypoints=route["locations"], mode="loop"))
    return {"routes": presented, "tried": len(results)}


# ---------------------------------------------------------------------------------------------------------------------------------- A to B --

MODES = ("ultra_fast", "fast", "relaxed", "twisty")
MODE_LABELS = {"ultra_fast": "Ultra fast", "fast": "Fast", "relaxed": "Relaxed", "twisty": "Twisty"}
MAX_STOPS = 7                    # start, up to five stops in between, finish
DEFAULT_DETOUR_MIN = 30
MIN_DETOUR_MIN, MAX_DETOUR_MIN = 5, 180
CORRIDOR_PER_MIN_M = 250.0       # a twisty stretch may lie this far off the direct route for each minute of detour allowed ...
CORRIDOR_MIN_M, CORRIDOR_MAX_M = 2000.0, 15000.0          # ... between these limits
TWISTY_CANDIDATES = 10
TWISTY_MIN_SCORE = 55
TIME_SLACK = 1.05
STRETCH_SEPARATION_M = 3000.0


def mode_options(mode: str, paved_only: bool = True) -> dict:
    """Valhalla's motorcycle costing for each style. Measured on real Swiss trips (Zurich to Chur: ultra fast 119 km / 84 min on motorways, fast 118 km / 106 min with the
    motorway only where it saves a lot, relaxed and twisty 127 km / 173 min on ordinary roads): use_highways is a smooth dial between about 0.2 (never) and 0.4 (always),
    use_primary does nothing for motorcycles, and maneuver_penalty makes a route simpler (about a quarter fewer turns, a few km longer), which is what relaxed means here."""
    if mode not in MODES:
        raise PlannerError("Choose ultra fast, fast, relaxed or twisty.")
    options: dict = {"use_trails": 0.0, "use_ferry": 0.0}
    if mode == "ultra_fast":
        options.update({"use_highways": 1.0, "use_tolls": 1.0})
    elif mode == "fast":
        options.update({"use_highways": 0.3, "use_tolls": 1.0})
    elif mode == "relaxed":
        options.update({"exclude_highways": True, "exclude_tolls": True, "maneuver_penalty": 100})
    else:                                                  # twisty: no motorways; the twisty stretches are found by the planner, the routing between them is ordinary
        options.update({"exclude_highways": True, "exclude_tolls": True, "maneuver_penalty": 30})
    if paved_only:
        options["exclude_unpaved"] = True
    return options


def _stops(locations: list[dict]) -> list[dict]:
    if not 2 <= len(locations) <= MAX_STOPS:
        raise PlannerError(f"A trip needs a start, a finish and at most {MAX_STOPS - 2} stops in between.")
    return [{"lat": float(l["lat"]), "lon": float(l["lon"]), "type": l.get("type", "break")} for l in locations]


def plan_trip(locations: list[dict], mode: str = "fast", paved_only: bool = True, alternatives: int = 0, detour_min: int = DEFAULT_DETOUR_MIN, roads_conn=None,
              ridden: Optional[set] = None, heading: Optional[float] = None, prefer_new: bool = False) -> dict:
    """The route from the first to the last of `locations` (stops in between are visited in order), in one of the four styles, with the turns for turn-by-turn.
    Up to `alternatives` other ways between start and finish come back as well (only for a trip without stops). Raises PlannerError when there is no route and
    valhalla.ValhallaUnavailable when the routing service is off or down."""
    stops = _stops(locations)
    options = mode_options(mode, paved_only)
    if mode == "twisty":
        return _plan_twisty(stops, options, detour_min, roads_conn, ridden, heading, prefer_new)
    base = _try(stops, True, paved_only, costing_options=options, directions=True, alternates=max(0, min(2, alternatives)), heading=heading)
    if base is None:
        raise PlannerError("No route could be found between those places.")
    found = [base] + list(base.get("alternates") or [])
    routes = []
    for i, route in enumerate(found):
        name = MODE_LABELS[mode] if i == 0 else f"Alternative {i}"
        routes.append(present(route, measure(route["shape"], ridden), name, waypoints=_pinned(stops, route) if i else stops, mode=mode))
    return {"routes": routes, "tried": len(found)}


def _pinned(stops: list[dict], route: dict, every_m: float = 6000.0) -> list[dict]:
    """The stops of an alternative route with "through" points along its line added, so asking again for the same waypoints gives the same way and not the main route."""
    line = route["shape"]
    pins: list[dict] = []
    along = 0.0
    last_pin = 0.0
    prev = line[0]
    for point in line[1:]:
        along += geo.haversine_m(prev[0], prev[1], point[0], point[1])
        prev = point
        if along - last_pin >= every_m and along < route["distance_m"] - every_m / 2:
            pins.append({"lat": point[0], "lon": point[1], "type": "through"})
            last_pin = along
    return [stops[0]] + pins + stops[1:]


def _plan_twisty(stops: list[dict], options: dict, detour_min: int, roads_conn, ridden: Optional[set], heading: Optional[float], prefer_new: bool) -> dict:
    """A to B through twisty stretches: the ordinary route between the stops is the baseline; twisty stretches from the road database that lie near it are tried as
    detours (one or two of them, in the order they come along the way), kept if the trip takes at most `detour_min` longer, and the twistiest wins. Without stops in
    between and without the road database it is the baseline, said so."""
    detour_min = max(MIN_DETOUR_MIN, min(MAX_DETOUR_MIN, int(detour_min)))
    base = _try(stops, True, True, costing_options=options)
    if base is None:
        raise PlannerError("No route could be found between those places.")
    note = None
    candidates: list[list[dict]] = []
    if len(stops) != 2:
        note = "With stops in between the route is the relaxed one: twisty detours are only added between a start and a finish."
    elif roads_conn is None:
        note = "This server has no twisty-road database yet, so this is the relaxed route."
    else:
        candidates = _twisty_candidates(stops, base, detour_min, roads_conn)
    budget_s = base["duration_s"] + detour_min * 60.0
    results = [base]
    if candidates:
        with ThreadPoolExecutor(max_workers=WORKERS) as pool:
            routed = list(pool.map(lambda locs: _try(locs, True, True, costing_options=options), candidates))
        results += [r for r in routed if r and r["duration_s"] <= budget_s * TIME_SLACK]
    scored = sorted(((quality(measure(r["shape"], ridden), r["distance_m"], None, prefer_new), r) for r in results), key=lambda item: -item[0])
    chosen: list[tuple[float, dict, dict]] = []
    for q, route in scored:
        m = measure(route["shape"], ridden)
        if all(_overlap(m["cells"], other[2]["cells"]) < DISTINCT_OVERLAP for other in chosen):
            chosen.append((q, route, m))
        if len(chosen) == MAX_ROUTES:
            break
    names = ["Twistiest", "Alternative", "Another option"]
    out = []
    for i, (_, route, m) in enumerate(chosen):
        locations = route.get("locations", stops)
        guided = _try(locations, True, True, costing_options=options, directions=True, heading=heading) or route
        out.append(present(guided, m, names[i] if len(chosen) > 1 or note is None else "Relaxed", waypoints=locations, mode="twisty"))
    answer = {"routes": out, "tried": len(results)}
    if note:
        answer["note"] = note
    return answer


def _twisty_candidates(stops: list[dict], base: dict, detour_min: int, conn) -> list[list[dict]]:
    """Waypoint lists that send the trip through one or two twisty stretches near the baseline route."""
    line = curvature.resample(base["shape"], 100.0)
    radius = min(CORRIDOR_MAX_M, max(CORRIDOR_MIN_M, detour_min * CORRIDOR_PER_MIN_M))
    lats = [p[0] for p in line]
    lons = [p[1] for p in line]
    pad_lat = radius / 111_194.9266
    pad_lon = pad_lat / max(0.2, math.cos(math.radians(sum(lats) / len(lats))))
    found, _ = roads.query(conn, min(lats) - pad_lat, min(lons) - pad_lon, max(lats) + pad_lat, max(lons) + pad_lon, 400, TWISTY_MIN_SCORE, True)
    near: list[tuple[float, int, dict]] = []                      # (how much twisty road, where along the baseline, the stretch)
    for road in found:
        mid = road["geometry"][len(road["geometry"]) // 2]
        best, at = min(((geo.haversine_m(mid[0], mid[1], p[0], p[1]), i) for i, p in enumerate(line)))
        if best <= radius:
            near.append((road["curvy_m"], at, road))
    near.sort(key=lambda item: -item[0])
    chosen: list[tuple[float, int, dict]] = []
    for item in near:
        mid = item[2]["geometry"][len(item[2]["geometry"]) // 2]
        if all(geo.haversine_m(mid[0], mid[1], *c[2]["geometry"][len(c[2]["geometry"]) // 2]) > STRETCH_SEPARATION_M for c in chosen):
            chosen.append(item)
        if len(chosen) == TWISTY_CANDIDATES:
            break

    def through(item, previous):
        line_ = item[2]["geometry"]
        ends = [(line_[0][0], line_[0][1]), (line_[-1][0], line_[-1][1])]
        ends.sort(key=lambda e: geo.haversine_m(previous[0], previous[1], e[0], e[1]))
        return [{"lat": e[0], "lon": e[1], "type": "through"} for e in ends]

    start, end = stops[0], stops[-1]
    plans: list[list[dict]] = []
    for item in chosen:                                                      # one stretch
        plans.append([start, *through(item, (start["lat"], start["lon"])), end])
    ordered = sorted(chosen[:6], key=lambda item: item[1])                  # two stretches, in the order they come along the way
    for i in range(len(ordered)):
        for j in range(i + 1, len(ordered)):
            if ordered[j][1] - ordered[i][1] < 30:                           # at least ~3 km apart along the way (samples are 100 m apart)
                continue
            first = through(ordered[i], (start["lat"], start["lon"]))
            second = through(ordered[j], (first[-1]["lat"], first[-1]["lon"]))
            plans.append([start, *first, *second, end])
    return plans[:16]


def ridden_cells(conn, owner_sub: str, south: float, west: float, north: float, east: float) -> set:
    """The places this person has ridden inside a box (their matched points, as map cells), for the 'new roads' preference."""
    rows = conn.execute(
        "SELECT w.lat, w.lon FROM ride_ways w JOIN rides r ON r.id = w.ride_id WHERE r.owner_sub = ? AND w.lat BETWEEN ? AND ? AND w.lon BETWEEN ? AND ?",
        (owner_sub, south, north, west, east),
    ).fetchall()
    return {_cell(r["lat"], r["lon"], RIDDEN_CELL_DEG) for r in rows}
