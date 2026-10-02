"""The route planner's API (/api/v1/planner/*): find loops and A-to-B routes, keep the ones you like, export them as GPX. Same rules as the rest of /api/v1: a plain
401 when logged out, changes need the X-RideLog-Client header, and someone else's route is the same 404 as one that does not exist.

Planning answers with `status`: ok | unavailable (the routing service is off or down) | no_route (nothing found; `message` says what to try).
"""
import json
import threading

from fastapi import APIRouter, Depends, Form, HTTPException, Response
from fastapi.responses import JSONResponse

from .. import curvature, geo, gpx, planner, roads, valhalla
from ..auth import current_owner_sub, require_api_client, require_api_login
from ..db import get_db

router = APIRouter(prefix="/api/v1/planner", dependencies=[Depends(require_api_login)])
CLIENT = [Depends(require_api_client)]
MAX_SAVED = 100
MAX_SHAPE_POINTS = 5000
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


@router.post("/route", dependencies=CLIENT)
def plan_route(from_lat: float = Form(), from_lon: float = Form(), to_lat: float = Form(), to_lon: float = Form(), avoid_motorways: bool = Form(True),
               paved_only: bool = Form(True), owner_sub: str = Depends(current_owner_sub)):
    """The motorcycle route from one place to another."""
    start, end = _point(from_lat, from_lon, "start"), _point(to_lat, to_lon, "destination")
    return _planning(lambda: planner.plan_route(start, end, avoid_motorways=avoid_motorways, paved_only=paved_only))


# ----------------------------------------------------------------------------------------------------------------------------- saved routes --

def _summary(row) -> dict:
    return {"id": row["id"], "name": row["name"], "kind": row["kind"], "distance_km": round(row["distance_m"] / 1000.0, 1), "duration_min": round(row["duration_s"] / 60.0),
            "twisty_km": round(row["twisty_m"] / 1000.0, 1), "twistiness": row["twistiness"], "created_at": row["created_at"]}


def _own(conn, owner_sub: str, route_id: int):
    row = conn.execute("SELECT * FROM planned_routes WHERE id = ? AND owner_sub = ?", (route_id, owner_sub)).fetchone()
    if not row:
        raise HTTPException(status_code=404, detail="route_not_found")
    return row


@router.post("/routes", dependencies=CLIENT)
def save_route(name: str = Form(), kind: str = Form("loop"), shape: str = Form(), duration_s: float = Form(0.0), owner_sub: str = Depends(current_owner_sub)):
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
    measured = planner.measure(points)
    distance_m = sum(s["length_m"] for s in curvature.segments(points)) or sum(
        geo.haversine_m(a[0], a[1], b[0], b[1]) for a, b in zip(points, points[1:]))
    conn = get_db()
    try:
        if conn.execute("SELECT COUNT(*) FROM planned_routes WHERE owner_sub = ?", (owner_sub,)).fetchone()[0] >= MAX_SAVED:
            raise _bad(f"You have {MAX_SAVED} saved routes: delete one first.")
        cur = conn.execute(
            "INSERT INTO planned_routes (owner_sub, name, kind, distance_m, duration_s, twisty_m, twistiness, shape) VALUES (?,?,?,?,?,?,?,?)",
            (owner_sub, name, kind, distance_m, max(0.0, duration_s), measured["twisty_m"], min(100, round(100.0 * measured["twist_density"])),
             json.dumps([[round(a, 5), round(b, 5)] for a, b in points], separators=(",", ":"))),
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
    return reply({"route": {**_summary(row), "shape": json.loads(row["shape"])}})


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
