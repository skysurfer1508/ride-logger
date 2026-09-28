import json
import secrets
import sqlite3
from datetime import datetime, timedelta, timezone
from urllib.parse import quote

from fastapi import APIRouter, Depends, Form, HTTPException, Query, Request
from fastapi.responses import HTMLResponse, RedirectResponse
from fastapi.templating import Jinja2Templates

from ..auth import current_owner_sub, require_login, require_onboarded
from ..config import settings
from ..db import get_db
from ..env_file import update_env_file
from ..paths import ENV_PATH, TEMPLATES_DIR

router = APIRouter(dependencies=[Depends(require_login), Depends(require_onboarded)])
templates = Jinja2Templates(directory=str(TEMPLATES_DIR))


# ---------------------------------------------------------------- helpers --

def _format_duration(seconds: float) -> str:
    total_minutes = int(seconds // 60)
    hours, minutes = divmod(total_minutes, 60)
    return f"{hours}:{minutes:02d}"


def _ride_view(row: sqlite3.Row) -> dict:
    view = dict(row)
    view["duration_hm"] = _format_duration(row["duration_s"])
    view["distance_km"] = round(row["distance_m"] / 1000, 1)
    view["avg_kmh"] = round(row["avg_speed_mps"] * 3.6)
    view["max_kmh"] = round(row["max_speed_mps"] * 3.6)
    return view


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
        latest = conn.execute(
            "SELECT * FROM rides WHERE owner_sub = ? ORDER BY start_time DESC LIMIT 1",
            (owner_sub,),
        ).fetchone()
        totals = conn.execute(
            """
            SELECT COUNT(*) as ride_count,
                   COALESCE(SUM(distance_m), 0) as total_distance_m,
                   COALESCE(AVG(avg_speed_mps), 0) as avg_speed_mps
            FROM rides WHERE owner_sub = ?
            """,
            (owner_sub,),
        ).fetchone()
        map_rides = conn.execute(
            """
            SELECT id, start_time, polyline_simplified FROM rides
            WHERE owner_sub = ? ORDER BY start_time DESC LIMIT 20
            """,
            (owner_sub,),
        ).fetchall()
    finally:
        conn.close()

    map_data = [
        {
            "id": r["id"],
            "label": r["start_time"][:10],
            "polyline": json.loads(r["polyline_simplified"]),
        }
        for r in map_rides
    ]

    return templates.TemplateResponse(
        request,
        "home.html",
        {
            "latest": _ride_view(latest) if latest else None,
            "ride_count": totals["ride_count"],
            "total_distance_display": f"{(totals['total_distance_m'] or 0) / 1000:,.0f}",
            "avg_speed_display": f"{(totals['avg_speed_mps'] or 0) * 3.6:.0f}",
            "map_data": map_data,
        },
    )


@router.get("/welcome", response_class=HTMLResponse)
def welcome(request: Request, owner_sub: str = Depends(current_owner_sub)):
    user = request.session["user"]
    conn = get_db()
    try:
        ingest_token = _get_or_create_ingest_token(conn, owner_sub, user.get("email", ""))
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
    clauses = ["owner_sub = ?"]
    params: list = [owner_sub]

    if date_from:
        clauses.append("start_time >= ?")
        params.append(date_from)
    if date_to:
        clauses.append("start_time <= ?")
        params.append(date_to + "T23:59:59")
    if min_km:
        try:
            clauses.append("distance_m >= ?")
            params.append(float(min_km) * 1000)
        except ValueError:
            pass
    if max_km:
        try:
            clauses.append("distance_m <= ?")
            params.append(float(max_km) * 1000)
        except ValueError:
            pass

    where = f"WHERE {' AND '.join(clauses)}"
    conn = get_db()
    try:
        rides = conn.execute(
            f"SELECT * FROM rides {where} ORDER BY start_time DESC LIMIT 500", params
        ).fetchall()
    finally:
        conn.close()

    return templates.TemplateResponse(
        request,
        "rides_list.html",
        {
            "rides": [_ride_view(r) for r in rides],
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
        ride = conn.execute(
            "SELECT * FROM rides WHERE id = ? AND owner_sub = ?", (ride_id, owner_sub)
        ).fetchone()
    finally:
        conn.close()
    # Same 404 whether the ride doesn't exist or belongs to someone else --
    # never reveal that a given ID exists but isn't yours.
    if not ride:
        raise HTTPException(status_code=404, detail="Ride not found")
    polyline = json.loads(ride["polyline_simplified"])
    return templates.TemplateResponse(
        request, "ride_detail.html", {"ride": _ride_view(ride), "polyline": polyline}
    )


# ---------------------------------------------------------------- overview --

def _personal_records(conn: sqlite3.Connection, owner_sub: str) -> dict:
    records = {}
    queries = {
        "longest": ("distance_m", "DESC"),
        "fastest_avg": ("avg_speed_mps", "DESC"),
        "fastest_top": ("max_speed_mps", "DESC"),
        "most_climb": ("elevation_gain_m", "DESC"),
        "longest_time": ("duration_s", "DESC"),
    }
    for key, (column, direction) in queries.items():
        row = conn.execute(
            f"SELECT * FROM rides WHERE owner_sub = ? ORDER BY {column} {direction} LIMIT 1",
            (owner_sub,),
        ).fetchone()
        records[key] = _ride_view(row) if row else None
    return records


def _calendar_heatmap(conn: sqlite3.Connection, owner_sub: str, days: int = 90) -> list[dict]:
    since = (datetime.now(timezone.utc) - timedelta(days=days)).date().isoformat()
    rows = conn.execute(
        """
        SELECT substr(start_time, 1, 10) as day, SUM(distance_m) as distance_m
        FROM rides
        WHERE owner_sub = ? AND substr(start_time, 1, 10) >= ?
        GROUP BY day
        """,
        (owner_sub, since),
    ).fetchall()
    by_day = {r["day"]: r["distance_m"] or 0 for r in rows}

    today = datetime.now(timezone.utc).date()
    cells = []
    for offset in range(days - 1, -1, -1):
        day = today - timedelta(days=offset)
        km = by_day.get(day.isoformat(), 0) / 1000
        if km <= 0:
            level = 0
        elif km < 20:
            level = 1
        elif km < 60:
            level = 2
        elif km < 120:
            level = 3
        else:
            level = 4
        cells.append({"date": day.isoformat(), "km": round(km, 1), "level": level})
    return cells


@router.get("/overview", response_class=HTMLResponse)
def overview(request: Request, owner_sub: str = Depends(current_owner_sub)):
    conn = get_db()
    try:
        totals = conn.execute(
            """
            SELECT COUNT(*) as ride_count,
                   COALESCE(SUM(distance_m), 0) as total_distance_m,
                   COALESCE(AVG(avg_speed_mps), 0) as avg_speed_mps,
                   COALESCE(MAX(distance_m), 0) as longest_ride_m
            FROM rides WHERE owner_sub = ?
            """,
            (owner_sub,),
        ).fetchone()
        weekly = conn.execute(
            """
            SELECT strftime('%Y-W%W', start_time) as week, SUM(distance_m) as distance_m
            FROM rides
            WHERE owner_sub = ?
            GROUP BY week
            ORDER BY week
            """,
            (owner_sub,),
        ).fetchall()
        records = _personal_records(conn, owner_sub)
        calendar = _calendar_heatmap(conn, owner_sub)
    finally:
        conn.close()

    total_distance_km = (totals["total_distance_m"] or 0) / 1000
    longest_ride_km = (totals["longest_ride_m"] or 0) / 1000
    avg_speed_kmh = (totals["avg_speed_mps"] or 0) * 3.6

    return templates.TemplateResponse(
        request,
        "overview.html",
        {
            "ride_count": totals["ride_count"],
            "total_distance_display": f"{total_distance_km:,.0f}",
            "avg_speed_display": f"{avg_speed_kmh:.0f}",
            "longest_ride_display": f"{longest_ride_km:,.0f}",
            "weekly_labels": [w["week"] for w in weekly],
            "weekly_distances": [round((w["distance_m"] or 0) / 1000, 1) for w in weekly],
            "records": records,
            "calendar": calendar,
        },
    )


# --------------------------------------------------------------------- map --

@router.get("/map", response_class=HTMLResponse)
def all_rides_map(request: Request, owner_sub: str = Depends(current_owner_sub)):
    conn = get_db()
    try:
        rides = conn.execute(
            """
            SELECT id, start_time, distance_m, polyline_simplified FROM rides
            WHERE owner_sub = ? ORDER BY start_time DESC
            """,
            (owner_sub,),
        ).fetchall()
    finally:
        conn.close()

    map_data = [
        {
            "id": r["id"],
            "label": f"{r['start_time'][:10]} &middot; {round(r['distance_m'] / 1000, 1)} km",
            "polyline": json.loads(r["polyline_simplified"]),
        }
        for r in rides
    ]
    return templates.TemplateResponse(
        request, "map.html", {"map_data": map_data, "ride_count": len(rides)}
    )


# ----------------------------------------------------------------- settings --

def _get_or_create_ingest_token(conn: sqlite3.Connection, owner_sub: str, owner_email: str) -> str:
    row = conn.execute(
        "SELECT token FROM ingest_tokens WHERE owner_sub = ?", (owner_sub,)
    ).fetchone()
    if row:
        return row["token"]
    token = secrets.token_urlsafe(32)
    conn.execute(
        "INSERT INTO ingest_tokens (token, owner_sub, owner_email) VALUES (?, ?, ?)",
        (token, owner_sub, owner_email),
    )
    conn.commit()
    return token


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
        ingest_token = _get_or_create_ingest_token(conn, owner_sub, user.get("email", ""))
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
    new_token = secrets.token_urlsafe(32)
    conn = get_db()
    try:
        conn.execute("DELETE FROM ingest_tokens WHERE owner_sub = ?", (owner_sub,))
        conn.execute(
            "INSERT INTO ingest_tokens (token, owner_sub, owner_email) VALUES (?, ?, ?)",
            (new_token, owner_sub, request.session["user"].get("email", "")),
        )
        conn.commit()
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
