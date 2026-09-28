import logging

from fastapi import APIRouter, Depends, Request
from pydantic import ValidationError

from .. import processing
from ..auth import resolve_ingest_owner
from ..db import get_db
from ..models import LocationFeature

logger = logging.getLogger("ride_logger.ingest")

router = APIRouter()


@router.post("/api/ingest")
async def ingest(request: Request, owner_sub: str = Depends(resolve_ingest_owner)):
    # Overland requires {"result": "ok"} / HTTP 200 on success or it retries
    # the whole batch forever, so we parse leniently: bad individual points
    # are logged and skipped rather than failing the request.
    try:
        body = await request.json()
    except Exception:
        logger.warning("Ingest received unparseable JSON body")
        return {"result": "ok"}

    raw_items = list(body.get("locations", []))
    current = body.get("current")
    if current:
        raw_items.append(current)

    conn = get_db()
    device_id = ""
    try:
        for raw_feature in raw_items:
            try:
                feature = LocationFeature.model_validate(raw_feature)
            except ValidationError:
                logger.warning("Skipping malformed location item: %r", raw_feature)
                continue

            if feature.properties.type == "trip":
                dev = feature.properties.device_id or device_id
                processing.finalize_trip_from_marker(conn, feature.properties, owner_sub, dev)
            else:
                device_id = feature.properties.device_id or device_id
                processing.insert_point(conn, feature, owner_sub)
        conn.commit()

        processing.sweep_stale_open_trips(conn)
        if device_id:
            processing.maybe_finalize_gap_inferred_rides(conn, owner_sub, device_id)
        conn.commit()
    finally:
        conn.close()

    return {"result": "ok"}
