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

from . import curvature, geo, roads, valhalla

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


def present(route: dict, measured: dict, name: str) -> dict:
    """A route as the app gets it."""
    shape = route["shape"]
    step = max(25.0, route["distance_m"] / SHAPE_POINTS)
    thin = curvature.resample(shape, step)
    return {
        "name": name,
        "distance_km": round(route["distance_m"] / 1000.0, 1),
        "duration_min": round(route["duration_s"] / 60.0),
        "twisty_km": round(measured["twisty_m"] / 1000.0, 1),
        "twistiness": min(100, round(100.0 * measured["twist_density"])),
        "retraced_pct": round(100.0 * measured["retraced_share"]),
        "new_pct": round(100.0 * (1.0 - measured["ridden_share"])),
        "shape": [[round(lat, 5), round(lon, 5)] for lat, lon in thin],
    }


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

def _try(locations: list[dict], avoid_motorways: bool, paved_only: bool) -> Optional[dict]:
    try:
        return valhalla.route(locations, avoid_motorways=avoid_motorways, paved_only=paved_only)
    except valhalla.NoRoute:
        return None


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
    return {"routes": [present(r, m, names[i]) for i, (_, r, m) in enumerate(chosen)], "tried": len(results)}


def plan_route(start: tuple[float, float], end: tuple[float, float], ridden: Optional[set] = None, avoid_motorways: bool = True, paved_only: bool = True) -> dict:
    """The motorcycle route from `start` to `end`, described like a loop. Raises PlannerError when there is none."""
    route = _try([{"lat": start[0], "lon": start[1], "type": "break"}, {"lat": end[0], "lon": end[1], "type": "break"}], avoid_motorways, paved_only)
    if route is None:
        raise PlannerError("No route could be found between those points.")
    return {"routes": [present(route, measure(route["shape"], ridden), "Route")], "tried": 1}


def ridden_cells(conn, owner_sub: str, south: float, west: float, north: float, east: float) -> set:
    """The places this person has ridden inside a box (their matched points, as map cells), for the 'new roads' preference."""
    rows = conn.execute(
        "SELECT w.lat, w.lon FROM ride_ways w JOIN rides r ON r.id = w.ride_id WHERE r.owner_sub = ? AND w.lat BETWEEN ? AND ? AND w.lon BETWEEN ? AND ?",
        (owner_sub, south, north, west, east),
    ).fetchall()
    return {_cell(r["lat"], r["lon"], RIDDEN_CELL_DEG) for r in rows}
