"""JSON API for the native iOS app (ios/). Versioned under /api/v1; every response carries "api": 1.

The responses come from the same view-models the web pages render (app/views.py), so the app and the website always agree.
Unauthenticated calls get a plain 401 (require_api_login), never a redirect. Anything that changes state also needs the
X-RideLog-Client header (require_api_client). This is a different surface from POST /api/ingest, which Overland and the app's
recorder use with a bearer token.
"""
from datetime import datetime

from fastapi import APIRouter, Depends, File, Form, HTTPException, Query, Request, UploadFile
from fastapi.responses import JSONResponse, Response

from .. import extras, gpx, osm, track, traffic, views
from ..auth import current_owner_sub, require_api_client, require_api_login
from ..config import settings
from ..db import get_db
from ..env_file import update_env_file
from ..paths import ENV_PATH

API_VERSION = 1
INGEST_PATH = "/api/ingest"
DEFAULT_PAGE = 100
MAX_PAGE = 200

router = APIRouter(prefix="/api/v1", dependencies=[Depends(require_api_login)])


def reply(payload: dict, status: int = 200) -> JSONResponse:
    return JSONResponse({"api": API_VERSION, **payload}, status_code=status, headers={"Cache-Control": "no-store"})


def _detection() -> dict:
    return {
        "gap_minutes": settings.gap_minutes,
        "min_points": settings.min_points,
        "min_distance_m": settings.min_distance_m,
        "stale_trip_minutes": settings.stale_trip_minutes,
    }


def _summary_or_none(view: dict | None) -> dict | None:
    return views.ride_summary(view) if view else None


@router.get("/me")
def me(request: Request, owner_sub: str = Depends(current_owner_sub)):
    """Who is signed in, and their ingest token: the app's recorder uploads with it (Authorization: Bearer), the same way Overland does.
    The token is created on first use, like the website's settings page does."""
    user = request.session["user"]
    conn = get_db()
    try:
        token = views.get_or_create_ingest_token(conn, owner_sub, user.get("email", ""))
    finally:
        conn.close()
    return reply({
        "name": user.get("name") or user.get("email", ""),
        "email": user.get("email", ""),
        "ingest_token": token,
        "ingest_path": INGEST_PATH,
    })


@router.get("/home")
def home(owner_sub: str = Depends(current_owner_sub)):
    conn = get_db()
    try:
        context = views.home_context(conn, owner_sub)
    finally:
        conn.close()
    return reply({
        "ride_count": context["ride_count"],
        "total_distance_display": context["total_distance_display"],
        "avg_speed_display": context["avg_speed_display"],
        "week_km": context["week_km"],
        "latest": _summary_or_none(context["latest"]),
        "recent_routes": context["map_data"],
    })


@router.get("/rides")
def rides(
    owner_sub: str = Depends(current_owner_sub),
    date_from: str = Query(default=""),
    date_to: str = Query(default=""),
    min_km: str = Query(default=""),
    max_km: str = Query(default=""),
    limit: int = Query(default=DEFAULT_PAGE, ge=1, le=MAX_PAGE),
    offset: int = Query(default=0, ge=0),
):
    conn = get_db()
    try:
        # one extra row tells us whether there is another page
        found = views.list_rides(conn, owner_sub, date_from, date_to, min_km, max_km, limit=limit + 1, offset=offset)
    finally:
        conn.close()
    return reply({
        "rides": [views.ride_summary(v) for v in found[:limit]],
        "limit": limit,
        "offset": offset,
        "has_more": len(found) > limit,
    })


@router.get("/rides/{ride_id}")
def ride_detail(ride_id: int, owner_sub: str = Depends(current_owner_sub)):
    conn = get_db()
    try:
        found = views.get_ride(conn, owner_sub, ride_id)
    finally:
        conn.close()
    # Same 404 whether the ride doesn't exist or belongs to someone else.
    if not found:
        raise HTTPException(status_code=404, detail="ride_not_found")
    view, polyline = found
    return reply({"ride": views.ride_summary(view), "polyline": polyline})


@router.get("/rides/{ride_id}/track")
def ride_track(ride_id: int, owner_sub: str = Depends(current_owner_sub)):
    """The ride's GPS track with speed at every fix, its top speed and the stops in it (what each was for, from OpenStreetMap), for the map,
    the scrubber and the replay. `features_status`: ok | unavailable (the OSM lookup failed, stops are plain "Stop") | disabled."""
    conn = get_db()
    try:
        found = views.get_ride(conn, owner_sub, ride_id)
        rows = views.get_ride_points(conn, owner_sub, ride_id)
        if not found or rows is None:
            raise HTTPException(status_code=404, detail="ride_not_found")
        view, _ = found
        result = track.build_track(rows)
        result["features_status"] = osm.classify_stops(conn, result["stops"])
    finally:
        conn.close()
    return reply({"ride": views.ride_summary(view), **result})


@router.get("/rides/{ride_id}/insights")
def ride_insights(ride_id: int, owner_sub: str = Depends(current_owner_sub)):
    """Elevation profile, smoothness, weather, and speed against the limit for one ride. Each part has its own status (ok | disabled | unavailable |
    no_match | no_data) so one service being down never hides the rest. The slow remote answers are cached per ride."""
    conn = get_db()
    try:
        rows = views.get_ride_points(conn, owner_sub, ride_id)
        if rows is None:
            raise HTTPException(status_code=404, detail="ride_not_found")
        result = extras.build(conn, ride_id, rows)
    finally:
        conn.close()
    return reply({"ride_id": ride_id, **result})


@router.get("/rides/{ride_id}/gpx")
def ride_gpx(ride_id: int, owner_sub: str = Depends(current_owner_sub)):
    """The ride as a GPX 1.1 file (every stored point), for another app or as a backup."""
    conn = get_db()
    try:
        found = views.get_ride(conn, owner_sub, ride_id)
        rows = views.get_ride_points(conn, owner_sub, ride_id)
    finally:
        conn.close()
    if not found or rows is None:
        raise HTTPException(status_code=404, detail="ride_not_found")
    view, _ = found
    start = datetime.fromisoformat(view["start_time"])
    body = gpx.build_gpx(rows, f"RideLog {start:%Y-%m-%d %H:%M}")
    return Response(content=body, media_type="application/gpx+xml",
                    headers={"Content-Disposition": f'attachment; filename="ridelog-{start:%Y%m%d-%H%M}.gpx"', "Cache-Control": "no-store"})


@router.post("/import/gpx", dependencies=[Depends(require_api_client)])
def import_gpx(file: UploadFile = File(...), owner_sub: str = Depends(current_owner_sub)):
    """Adds the track(s) of a GPX file from another app as rides. Safe to repeat: the same file or the same moments are recognised."""
    data = file.file.read(gpx.MAX_BYTES + 1)
    try:
        tracks = gpx.parse_gpx(data)
    except gpx.GpxError as e:
        raise HTTPException(status_code=413 if len(data) > gpx.MAX_BYTES else 400, detail={"detail": "gpx_invalid", "message": str(e)})
    conn = get_db()
    try:
        results = views.import_tracks(conn, owner_sub, tracks)
    finally:
        conn.close()
    return reply({"results": results, "imported": sum(1 for r in results if r["status"] == "imported")})


@router.delete("/rides/{ride_id}", dependencies=[Depends(require_api_client)])
def delete_ride(ride_id: int, owner_sub: str = Depends(current_owner_sub)):
    """Deletes one of my rides and its GPS points. Someone else's ride is the same 404 as a missing one and is left untouched."""
    conn = get_db()
    try:
        deleted = views.delete_ride(conn, owner_sub, ride_id)
    finally:
        conn.close()
    if not deleted:
        raise HTTPException(status_code=404, detail="ride_not_found")
    return reply({"deleted": ride_id})


# ------------------------------------------------------------------------------------------------------------------------------ traffic --

@router.get("/traffic/config")
def traffic_config():
    """Which Traffic-tab layers the server has keys for. (Apple's traffic colours need no key: the phone draws them itself.)"""
    return reply({"incidents": traffic.incidents_configured(), "webcams": traffic.webcams_configured()})


def _traffic_failed(e: traffic.TrafficUnavailable) -> HTTPException:
    return HTTPException(status_code=502, detail={"detail": "traffic_unavailable", "message": str(e)})


@router.get("/traffic/incidents")
def traffic_incidents(lat: float = Query(ge=-90, le=90), lon: float = Query(ge=-180, le=180), radius_km: float = Query(default=25, gt=0, le=100)):
    if not traffic.incidents_configured():
        raise HTTPException(status_code=404, detail="not_configured")
    try:
        return reply(traffic.incidents_near(lat, lon, radius_km))
    except traffic.TrafficUnavailable as e:
        raise _traffic_failed(e)


@router.get("/traffic/webcams")
def traffic_webcams(lat: float = Query(ge=-90, le=90), lon: float = Query(ge=-180, le=180), radius_km: float = Query(default=15, gt=0, le=50)):
    if not traffic.webcams_configured():
        raise HTTPException(status_code=404, detail="not_configured")
    try:
        return reply(traffic.webcams_near(lat, lon, radius_km))
    except traffic.TrafficUnavailable as e:
        raise _traffic_failed(e)


@router.get("/overview")
def overview(owner_sub: str = Depends(current_owner_sub)):
    conn = get_db()
    try:
        context = views.overview_context(conn, owner_sub)
    finally:
        conn.close()
    return reply({
        "ride_count": context["ride_count"],
        "total_distance_display": context["total_distance_display"],
        "avg_speed_display": context["avg_speed_display"],
        "longest_ride_display": context["longest_ride_display"],
        "weekly": [
            {"week": week, "km": km}
            for week, km in zip(context["weekly_labels"], context["weekly_distances"])
        ],
        "records": {key: _summary_or_none(view) for key, view in context["records"].items()},
        "calendar": context["calendar"],
    })


@router.get("/map")
def all_rides_map(owner_sub: str = Depends(current_owner_sub)):
    conn = get_db()
    try:
        context = views.map_context(conn, owner_sub)
    finally:
        conn.close()
    routes = [
        {**item, "label": item["label"].replace(" &middot; ", " · ")}     # the web page renders HTML entities, the app does not
        for item in context["map_data"]
    ]
    return reply({"ride_count": context["ride_count"], "routes": routes})


@router.get("/settings")
def settings_read():
    return reply({"detection": _detection()})


@router.post("/settings/regenerate-token", dependencies=[Depends(require_api_client)])
def regenerate_token(request: Request, owner_sub: str = Depends(current_owner_sub)):
    conn = get_db()
    try:
        token = views.regenerate_ingest_token(conn, owner_sub, request.session["user"].get("email", ""))
    finally:
        conn.close()
    return reply({"ingest_token": token, "ingest_path": INGEST_PATH})


@router.post("/settings/detection", dependencies=[Depends(require_api_client)])
def update_detection(
    gap_minutes: float = Form(...),
    min_points: int = Form(...),
    min_distance_m: float = Form(...),
    stale_trip_minutes: float = Form(...),
):
    # NOTE: like the website's form, this is a server-wide setting (it is written to .env), not a per-user one.
    if gap_minutes <= 0 or min_points <= 0 or min_distance_m < 0 or stale_trip_minutes <= 0:
        raise HTTPException(status_code=400, detail="values_must_be_positive")
    settings.gap_minutes = gap_minutes
    settings.min_points = min_points
    settings.min_distance_m = min_distance_m
    settings.stale_trip_minutes = stale_trip_minutes
    update_env_file(
        ENV_PATH,
        {
            "GAP_MINUTES": str(gap_minutes),
            "MIN_POINTS": str(min_points),
            "MIN_DISTANCE_M": str(min_distance_m),
            "STALE_TRIP_MINUTES": str(stale_trip_minutes),
        },
    )
    return reply({"detection": _detection()})
