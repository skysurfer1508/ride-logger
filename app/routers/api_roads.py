"""The Roads layer's API: GET /api/v1/roads. Twisty roads inside a map box, each marked ridden / not ridden yet for the person asking. Same rules as the rest
of /api/v1 (a plain 401 when logged out). The road database is the same for everyone; "ridden" comes only from the asker's own rides.
"""
from fastapi import APIRouter, BackgroundTasks, Depends, HTTPException, Query
from fastapi.responses import JSONResponse

from .. import extras, roads, valhalla
from ..auth import current_owner_sub, require_api_login
from ..db import get_db

router = APIRouter(prefix="/api/v1", dependencies=[Depends(require_api_login)])
DEFAULT_LIMIT = 60
MAX_LIMIT = 150
CATCH_UP_RIDES = 25


def reply(payload: dict) -> JSONResponse:
    return JSONResponse({"api": 1, **payload}, headers={"Cache-Control": "no-store"})


@router.get("/roads")
def twisty_roads(
    background: BackgroundTasks,
    south: float = Query(ge=-90, le=90),
    west: float = Query(ge=-180, le=180),
    north: float = Query(ge=-90, le=90),
    east: float = Query(ge=-180, le=180),
    limit: int = Query(default=DEFAULT_LIMIT, ge=1, le=MAX_LIMIT),
    min_score: int = Query(default=30, ge=0, le=100),
    paved_only: bool = True,
    owner_sub: str = Depends(current_owner_sub),
):
    """The best stretches inside the box (most twisty road first, at most `limit`), each with `ridden`: true, false, or null when that cannot be told yet.

    `status`: ok | not_built (nobody has built the road database on the server). `ridden_status`: ok | updating (some of your rides are still being matched to
    roads in the background: ask again in a moment) | unavailable (the map matcher is off or down: `ridden` is null)."""
    if north <= south or east <= west or north - south > roads.MAX_LAT_SPAN or east - west > roads.MAX_LON_SPAN:
        raise HTTPException(status_code=422, detail="box_invalid_or_too_large")
    if not roads.available():
        return reply({"status": "not_built", "roads": [], "truncated": False, "ridden_status": "unavailable", "attribution": roads.ATTRIBUTION})
    rdb = roads.connect()
    try:
        found, truncated = roads.query(rdb, south, west, north, east, limit, min_score, paved_only)
    finally:
        rdb.close()
    conn = get_db()
    try:
        pending = extras.pending_rides(conn, owner_sub) if valhalla.configured() else []
        flags = roads.ridden_flags(conn, owner_sub, found)
    finally:
        conn.close()
    if not valhalla.configured():
        ridden_status, flags = "unavailable", [None] * len(found)
    elif pending:
        ridden_status = "updating"
        background.add_task(extras.catch_up_ways, owner_sub, CATCH_UP_RIDES)
    else:
        ridden_status = "ok"
    for road, flag in zip(found, flags):
        road["ridden"] = flag
    return reply({"status": "ok", "roads": found, "truncated": truncated, "ridden_status": ridden_status, "pending_rides": len(pending), "attribution": roads.ATTRIBUTION})
