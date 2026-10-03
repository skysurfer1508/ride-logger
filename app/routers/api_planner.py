"""The route planner's API (/api/v1/planner/*): find loops and A-to-B routes, keep the ones you like, export them as GPX. Same rules as the rest of /api/v1: a plain
401 when logged out, changes need the X-RideLog-Client header, and someone else's route is the same 404 as one that does not exist.

Planning answers with `status`: ok | unavailable (the routing service is off or down) | no_route (nothing found; `message` says what to try).
"""
import json
import threading
import time
from datetime import datetime, timezone
from typing import Optional
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from fastapi import APIRouter, Depends, Form, HTTPException, Response
from fastapi.responses import JSONResponse

from .. import conditions, curvature, geo, gpx, limits, planner, roads, valhalla, weather
from ..auth import current_owner_sub, require_api_client, require_api_login
from ..db import get_db

router = APIRouter(prefix="/api/v1/planner", dependencies=[Depends(require_api_login)])
CLIENT = [Depends(require_api_client)]
MAX_SAVED = 100
MAX_SHAPE_POINTS = 5000
MAX_DIRECTIONS_STOPS = 40
_slots = threading.BoundedSemaphore(2)          # a plan is 20 to 40 routing requests: two at a time is plenty for one household


def reply(payload: dict) -> JSONResponse:
    return JSONResponse({"api": 1, **payload}, headers={"Cache-Control": "no-store"})


def _bad(message: str) -> HTTPException:
    return HTTPException(status_code=400, detail={"detail": "invalid_input", "message": message})


def _point(lat: float, lon: float, label: str) -> tuple[float, float]:
    if not (-90 <= lat <= 90 and -180 <= lon <= 180):
        raise _bad(f"The {label} is not a place on Earth.")
    return lat, lon


def _planning(work) -> JSONResponse:
    """Runs a planning job and turns its failures into the statuses the app understands."""
    if not valhalla.configured():
        return reply({"status": "unavailable", "routes": [], "message": "The routing service is switched off on your server."})
    if not _slots.acquire(blocking=False):
        return reply({"status": "unavailable", "routes": [], "message": "The server is busy planning another route. Try again in a few seconds."})
    try:
        result = work()
    except valhalla.ValhallaUnavailable:
        return reply({"status": "unavailable", "routes": [], "message": "The routing service is not answering right now. Try again in a moment."})
    except planner.PlannerError as e:
        return reply({"status": "no_route", "routes": [], "message": str(e)})
    finally:
        _slots.release()
    return reply({"status": "ok", "message": None, **result})


@router.post("/loop", dependencies=CLIENT)
def plan_loop(lat: float = Form(), lon: float = Form(), distance_km: float = Form(), avoid_motorways: bool = Form(True), paved_only: bool = Form(True),
              prefer_new: bool = Form(False), owner_sub: str = Depends(current_owner_sub)):
    """Loops of about `distance_km` from a start point, through the twistiest roads nearby. `prefer_new` favours roads you have not ridden."""
    start = _point(lat, lon, "start")
    if not planner.MIN_KM <= distance_km <= planner.MAX_KM:
        raise _bad(f"Choose a length between {planner.MIN_KM:.0f} and {planner.MAX_KM:.0f} km.")

    def work():
        rdb = roads.connect() if roads.available() else None
        conn = get_db()
        try:
            ridden = None
            if prefer_new:
                span = distance_km / 111.0 / 2.0 * 1.2
                ridden = planner.ridden_cells(conn, owner_sub, lat - span, lon - span * 1.5, lat + span, lon + span * 1.5)
            result = planner.plan_loops(start, distance_km, roads_conn=rdb, ridden=ridden, avoid_motorways=avoid_motorways, paved_only=paved_only, prefer_new=prefer_new)
            result["roads_data"] = rdb is not None
            return result
        finally:
            conn.close()
            if rdb is not None:
                rdb.close()

    return _planning(work)


def _locations(text: str, most: int) -> list[dict]:
    """The stops of a trip from the app: JSON [{"lat", "lon", optional "type": "break" | "through"}, ...]."""
    try:
        raw = json.loads(text)
        stops = [{"lat": float(p["lat"]), "lon": float(p["lon"]), "type": p.get("type", "break")} for p in raw]
    except (ValueError, TypeError, KeyError, AttributeError):
        raise _bad("The stops of the trip are not readable.")
    if not 2 <= len(stops) <= most:
        raise _bad(f"A trip needs between 2 and {most} stops.")
    for stop in stops:
        _point(stop["lat"], stop["lon"], "stop")
        if stop["type"] not in ("break", "through"):
            raise _bad("A stop is either a break or a through point.")
    return stops


@router.post("/route", dependencies=CLIENT)
def plan_route(locations: str = Form(), mode: str = Form("fast"), paved_only: bool = Form(True), alternatives: int = Form(0), detour_min: int = Form(planner.DEFAULT_DETOUR_MIN),
               heading: Optional[float] = Form(None), prefer_new: bool = Form(False), owner_sub: str = Depends(current_owner_sub)):
    """From the first to the last of the stops (up to five in between), in one of four styles (ultra_fast, fast, relaxed, twisty), with the turns for turn-by-turn.
    `alternatives` (0 to 2) asks for other ways between start and finish; `detour_min` is how much longer a twisty trip may take; `heading` is the direction you are
    already going (for a reroute from the road)."""
    stops = _locations(locations, planner.MAX_STOPS)
    if mode not in planner.MODES:
        raise _bad("Choose ultra fast, fast, relaxed or twisty.")
    if not planner.MIN_DETOUR_MIN <= detour_min <= planner.MAX_DETOUR_MIN:
        raise _bad(f"A detour is between {planner.MIN_DETOUR_MIN} and {planner.MAX_DETOUR_MIN} minutes.")

    def work():
        rdb = roads.connect() if (mode == "twisty" and roads.available()) else None
        conn = get_db()
        try:
            ridden = None
            if prefer_new and stops:
                lats = [s["lat"] for s in stops]
                lons = [s["lon"] for s in stops]
                ridden = planner.ridden_cells(conn, owner_sub, min(lats) - 0.3, min(lons) - 0.4, max(lats) + 0.3, max(lons) + 0.4)
            return planner.plan_trip(stops, mode, paved_only, max(0, min(2, alternatives)), detour_min, roads_conn=rdb, ridden=ridden, heading=heading, prefer_new=prefer_new)
        finally:
            conn.close()
            if rdb is not None:
                rdb.close()

    return _planning(work)


@router.post("/directions", dependencies=CLIENT)
def directions(locations: str = Form(), mode: str = Form("relaxed"), paved_only: bool = Form(True), heading: Optional[float] = Form(None), owner_sub: str = Depends(current_owner_sub)):
    """The same stops asked for again, with the turns: to start navigating a route that was saved or planned as a loop, and to reroute from where you are now
    (the first stop is your position, `heading` the way you are facing). `mode` is one of the four styles, or `loop` for a loop made by the planner."""
    stops = _locations(locations, MAX_DIRECTIONS_STOPS)
    if mode != "loop" and mode not in planner.MODES:
        raise _bad("Choose ultra fast, fast, relaxed, twisty or loop.")

    def work():
        extra = {"directions": True, "heading": heading}
        if mode != "loop":
            extra["costing_options"] = planner.mode_options(mode, paved_only)
        route = planner._try(stops, True, paved_only, **extra)
        if route is None:
            raise planner.PlannerError("No route could be found between those places.")
        return {"routes": [planner.present(route, planner.measure(route["shape"]), "Route", waypoints=stops, mode=mode)], "tried": 1}

    return _planning(work)


# ------------------------------------------------------------------------------------------------------------------------ along the route --
# What the rider is told on the way besides the turns. Asked for after navigation has started, so that a slow answer never holds up the first instruction.

_info_slots = threading.BoundedSemaphore(2)
LIMIT_STEP_M = 30.0
MAX_LIMIT_POINTS = 6000


def _line(shape6: str) -> list[tuple[float, float]]:
    try:
        line = valhalla.decode_polyline6(shape6)
    except (IndexError, ValueError):
        raise _bad("The route's line is not readable.")
    if not 2 <= len(line) <= 60_000:
        raise _bad("The route's line is not readable.")
    return line


@router.post("/limits", dependencies=CLIENT)
def route_limits(shape6: str = Form()):
    """The speed limits along a route (its polyline6 line): change points [{along_m, kmh}], `kmh` null where the map has no tagged limit."""
    line = _line(shape6)
    if not valhalla.configured():
        return reply({"status": "unavailable", "limits": [], "message": "The routing service is switched off on your server."})
    if not _info_slots.acquire(blocking=False):
        return reply({"status": "unavailable", "limits": [], "message": "The server is busy. Try again in a few seconds."})
    try:
        total = curvature._cumulative(line)[-1]
        points = curvature.resample(line, max(LIMIT_STEP_M, total / MAX_LIMIT_POINTS))
        distances = curvature._cumulative(points)
        matches = valhalla.match_points(points)
    except valhalla.ValhallaUnavailable:
        return reply({"status": "unavailable", "limits": [], "message": "The routing service is not answering right now."})
    finally:
        _info_slots.release()
    return reply({"status": "ok", "message": None, "limits": limits.route_limits(distances, matches) if any(matches) else []})


@router.post("/conditions", dependencies=CLIENT)
def route_conditions(shape6: str = Form(), duration_min: float = Form(), depart: Optional[float] = Form(None), tz: str = Form("UTC")):
    """What the ride will meet: alerts [{along_m, kind, label}] for rain, snow, storm, ice and wind where the forecast says so, the light (sunset, dusk, minutes after
    dark) and one spoken `summary`. `depart` is the departure as epoch seconds (default now), `tz` the rider's time zone for the clock times."""
    line = _line(shape6)
    if not 1 <= duration_min <= 24 * 60:
        raise _bad("The ride's duration is not plausible.")
    now = time.time()
    when = datetime.fromtimestamp(depart if depart is not None else now, timezone.utc)
    if abs(when.timestamp() - now) > conditions.MAX_LOOKAHEAD_H * 3600:
        raise _bad("The departure is too far from now for a forecast.")
    try:
        zone = ZoneInfo(tz)
    except (ZoneInfoNotFoundError, ValueError):
        zone = ZoneInfo("UTC")
    total = curvature._cumulative(line)[-1]
    duration_s = duration_min * 60.0
    mid = line[len(line) // 2]
    lit = conditions.light(mid[0], mid[1], when, duration_s, zone)
    samples = conditions.forecast(conditions.sample_points(line), when, duration_s, total)
    found = conditions.alerts(samples)
    span = conditions.temperature_range(samples)
    return reply({"status": "ok", "message": None, "alerts": found, "light": lit, "summary": conditions.spoken_summary(found, lit),
                  "weather": {"temperature_min_c": round(span[0]), "temperature_max_c": round(span[1]), "attribution": weather.ATTRIBUTION} if span else None})


# ----------------------------------------------------------------------------------------------------------------------------- saved routes --

def _summary(row) -> dict:
    return {"id": row["id"], "name": row["name"], "kind": row["kind"], "mode": row["mode"], "distance_km": round(row["distance_m"] / 1000.0, 1), "duration_min": round(row["duration_s"] / 60.0),
            "twisty_km": round(row["twisty_m"] / 1000.0, 1), "twistiness": row["twistiness"], "created_at": row["created_at"]}


def _own(conn, owner_sub: str, route_id: int):
    row = conn.execute("SELECT * FROM planned_routes WHERE id = ? AND owner_sub = ?", (route_id, owner_sub)).fetchone()
    if not row:
        raise HTTPException(status_code=404, detail="route_not_found")
    return row


@router.post("/routes", dependencies=CLIENT)
def save_route(name: str = Form(), kind: str = Form("loop"), shape: str = Form(), duration_s: float = Form(0.0), waypoints: Optional[str] = Form(None),
               mode: Optional[str] = Form(None), owner_sub: str = Depends(current_owner_sub)):
    """Keeps a planned route. The length and twistiness are worked out here from the line, not taken from the app."""
    name = " ".join(name.split())
    if not name or len(name) > 80:
        raise _bad("Give the route a name of up to 80 characters.")
    if kind not in ("loop", "route"):
        raise _bad("The kind of route must be loop or route.")
    try:
        points = [(float(p[0]), float(p[1])) for p in json.loads(shape)]
    except (ValueError, TypeError, IndexError, KeyError):
        raise _bad("The route's line is not readable.")
    if not 2 <= len(points) <= MAX_SHAPE_POINTS or any(not (-90 <= a <= 90 and -180 <= b <= 180) for a, b in points):
        raise _bad("The route's line must have between 2 and 5000 points on Earth.")
    stops = _locations(waypoints, MAX_DIRECTIONS_STOPS) if waypoints else None        # the stops that make the route, to navigate it later
    if mode is not None and mode != "loop" and mode not in planner.MODES:
        raise _bad("The mode of the route is not known.")
    measured = planner.measure(points)
    distance_m = sum(s["length_m"] for s in curvature.segments(points)) or sum(
        geo.haversine_m(a[0], a[1], b[0], b[1]) for a, b in zip(points, points[1:]))
    conn = get_db()
    try:
        if conn.execute("SELECT COUNT(*) FROM planned_routes WHERE owner_sub = ?", (owner_sub,)).fetchone()[0] >= MAX_SAVED:
            raise _bad(f"You have {MAX_SAVED} saved routes: delete one first.")
        cur = conn.execute(
            "INSERT INTO planned_routes (owner_sub, name, kind, distance_m, duration_s, twisty_m, twistiness, shape, waypoints, mode) VALUES (?,?,?,?,?,?,?,?,?,?)",
            (owner_sub, name, kind, distance_m, max(0.0, duration_s), measured["twisty_m"], min(100, round(100.0 * measured["twist_density"])),
             json.dumps([[round(a, 5), round(b, 5)] for a, b in points], separators=(",", ":")), json.dumps(stops) if stops else None, mode),
        )
        conn.commit()
        return reply({"route": _summary(conn.execute("SELECT * FROM planned_routes WHERE id = ?", (cur.lastrowid,)).fetchone())})
    finally:
        conn.close()


@router.get("/routes")
def list_routes(owner_sub: str = Depends(current_owner_sub)):
    conn = get_db()
    try:
        rows = conn.execute("SELECT * FROM planned_routes WHERE owner_sub = ? ORDER BY id DESC", (owner_sub,)).fetchall()
    finally:
        conn.close()
    return reply({"routes": [_summary(r) for r in rows]})


@router.get("/routes/{route_id}")
def get_route(route_id: int, owner_sub: str = Depends(current_owner_sub)):
    conn = get_db()
    try:
        row = _own(conn, owner_sub, route_id)
    finally:
        conn.close()
    return reply({"route": {**_summary(row), "shape": json.loads(row["shape"]), "waypoints": json.loads(row["waypoints"]) if row["waypoints"] else None}})


@router.delete("/routes/{route_id}", dependencies=CLIENT)
def delete_route(route_id: int, owner_sub: str = Depends(current_owner_sub)):
    conn = get_db()
    try:
        _own(conn, owner_sub, route_id)
        conn.execute("DELETE FROM planned_routes WHERE id = ? AND owner_sub = ?", (route_id, owner_sub))
        conn.commit()
    finally:
        conn.close()
    return reply({"deleted": route_id})


@router.get("/routes/{route_id}/gpx")
def route_gpx(route_id: int, owner_sub: str = Depends(current_owner_sub)):
    conn = get_db()
    try:
        row = _own(conn, owner_sub, route_id)
    finally:
        conn.close()
    data = gpx.build_route_gpx(row["name"], [tuple(p) for p in json.loads(row["shape"])])
    filename = "".join(c if c.isalnum() or c in "-_" else "-" for c in row["name"]).strip("-")[:60] or "route"
    return Response(content=data, media_type="application/gpx+xml", headers={"Content-Disposition": f'attachment; filename="{filename}.gpx"', "Cache-Control": "no-store"})
