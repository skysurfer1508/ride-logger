from urllib.parse import quote

from fastapi import APIRouter, Depends, Form, HTTPException, Query, Request
from fastapi.responses import HTMLResponse, RedirectResponse
from fastapi.templating import Jinja2Templates

from .. import views
from ..auth import current_owner_sub, require_login, require_onboarded
from ..config import settings
from ..db import get_db
from ..env_file import update_env_file
from ..paths import ENV_PATH, TEMPLATES_DIR

router = APIRouter(dependencies=[Depends(require_login), Depends(require_onboarded)])
templates = Jinja2Templates(directory=str(TEMPLATES_DIR))


# ---------------------------------------------------------------- helpers --

def _settings_redirect(ok: str | None = None, error: str | None = None) -> RedirectResponse:
    url = "/settings"
    if ok:
        url += f"?ok={quote(ok)}"
    elif error:
        url += f"?error={quote(error)}"
    return RedirectResponse(url=url, status_code=303)


# -------------------------------------------------------------------- home --

@router.get("/", response_class=HTMLResponse)
def home(request: Request, owner_sub: str = Depends(current_owner_sub)):
    conn = get_db()
    try:
        context = views.home_context(conn, owner_sub)
    finally:
        conn.close()
    return templates.TemplateResponse(request, "home.html", context)


@router.get("/welcome", response_class=HTMLResponse)
def welcome(request: Request, owner_sub: str = Depends(current_owner_sub)):
    user = request.session["user"]
    conn = get_db()
    try:
        ingest_token = views.get_or_create_ingest_token(conn, owner_sub, user.get("email", ""))
    finally:
        conn.close()

    ingest_url = str(request.base_url).rstrip("/") + "/api/ingest"
    return templates.TemplateResponse(
        request,
        "welcome.html",
        {
            "name": user.get("name") or user.get("email", ""),
            "ingest_url": ingest_url,
            "ingest_token": ingest_token,
        },
    )


# ------------------------------------------------------------------- rides --

@router.get("/rides", response_class=HTMLResponse)
def rides_list(
    request: Request,
    owner_sub: str = Depends(current_owner_sub),
    date_from: str = Query(default=""),
    date_to: str = Query(default=""),
    min_km: str = Query(default=""),
    max_km: str = Query(default=""),
):
    conn = get_db()
    try:
        rides = views.list_rides(conn, owner_sub, date_from, date_to, min_km, max_km)
    finally:
        conn.close()

    return templates.TemplateResponse(
        request,
        "rides_list.html",
        {
            "rides": rides,
            "filters": {
                "date_from": date_from,
                "date_to": date_to,
                "min_km": min_km,
                "max_km": max_km,
            },
        },
    )


@router.get("/rides/{ride_id}", response_class=HTMLResponse)
def ride_detail(request: Request, ride_id: int, owner_sub: str = Depends(current_owner_sub)):
    conn = get_db()
    try:
        found = views.get_ride(conn, owner_sub, ride_id)
    finally:
        conn.close()
    # Same 404 whether the ride doesn't exist or belongs to someone else --
    # never reveal that a given ID exists but isn't yours.
    if not found:
        raise HTTPException(status_code=404, detail="Ride not found")
    ride, polyline = found
    return templates.TemplateResponse(
        request, "ride_detail.html", {"ride": ride, "polyline": polyline}
    )


# ---------------------------------------------------------------- overview --

@router.get("/overview", response_class=HTMLResponse)
def overview(request: Request, owner_sub: str = Depends(current_owner_sub)):
    conn = get_db()
    try:
        context = views.overview_context(conn, owner_sub)
    finally:
        conn.close()
    return templates.TemplateResponse(request, "overview.html", context)


# --------------------------------------------------------------------- map --

@router.get("/map", response_class=HTMLResponse)
def all_rides_map(request: Request, owner_sub: str = Depends(current_owner_sub)):
    conn = get_db()
    try:
        context = views.map_context(conn, owner_sub)
    finally:
        conn.close()
    return templates.TemplateResponse(request, "map.html", context)


# ----------------------------------------------------------------- settings --

@router.get("/settings", response_class=HTMLResponse)
def settings_page(
    request: Request,
    owner_sub: str = Depends(current_owner_sub),
    ok: str = Query(default=""),
    error: str = Query(default=""),
):
    user = request.session["user"]
    conn = get_db()
    try:
        ingest_token = views.get_or_create_ingest_token(conn, owner_sub, user.get("email", ""))
    finally:
        conn.close()

    ingest_url = str(request.base_url).rstrip("/") + "/api/ingest"
    return templates.TemplateResponse(
        request,
        "settings.html",
        {
            "ingest_url": ingest_url,
            "ingest_token": ingest_token,
            "gap_minutes": settings.gap_minutes,
            "min_points": settings.min_points,
            "min_distance_m": settings.min_distance_m,
            "stale_trip_minutes": settings.stale_trip_minutes,
            "ok": ok,
            "error": error,
        },
    )


@router.post("/settings/regenerate-token")
def regenerate_token(request: Request, owner_sub: str = Depends(current_owner_sub)):
    conn = get_db()
    try:
        views.regenerate_ingest_token(conn, owner_sub, request.session["user"].get("email", ""))
    finally:
        conn.close()
    return _settings_redirect(ok="token")


@router.post("/settings/detection")
def update_detection_settings(
    request: Request,
    gap_minutes: float = Form(...),
    min_points: int = Form(...),
    min_distance_m: float = Form(...),
    stale_trip_minutes: float = Form(...),
):
    if gap_minutes <= 0 or min_points <= 0 or min_distance_m < 0 or stale_trip_minutes <= 0:
        return _settings_redirect(error="detection:Values must be positive.")

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
    return _settings_redirect(ok="detection")
