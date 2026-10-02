"""Traffic lights, stop / give-way signs and level crossings from OpenStreetMap, to say what a rider stopped for.

Only the SERVER talks to the Overpass API, and only for coarse 0.05 degree tiles (about 4 x 5.5 km) around the places a rider stood still. Tiles are
cached in SQLite (osm_tiles / osm_features), so a tile is fetched once and not once per ride, and the phone never sends your locations to a third
party. The public Overpass servers are shared and sometimes busy, so: one request at a time (a lock), a time budget per ride, a second server as a
fallback, a 30 s pause after "too many requests", and a failed tile is simply not stored, so it is tried again later. If nothing can be fetched the
stops stay plain "Stop" (status "unavailable"); a ride is never held up or broken by this.

Data (c) OpenStreetMap contributors, ODbL: https://www.openstreetmap.org/copyright. The app shows that credit under the stops.
"""
import json
import logging
import math
import threading
import time
from datetime import datetime, timedelta, timezone
from typing import Optional

import httpx

from . import geo, track
from .config import settings

logger = logging.getLogger("ride_logger.osm")

TILE_DEG = 0.05
TTL = timedelta(days=60)
REQUEST_TIMEOUT_S = 8.0
BUDGET_S = 14.0                  # most time one ride's lookup may spend waiting on Overpass
BACKOFF_S = 30.0                 # the public server's own rule after HTTP 429 / 406
FAILURE_RETRY_S = 60.0           # don't re-ask for a tile that just failed
SEARCH_RADIUS_M = track.CLASSIFY_RADIUS_M + 5
# how far around a stop its tile(s) must reach: a bit more than the radius, in degrees (about 65 m north, 95 m east at Zurich)
_MARGIN_LAT = 0.0006
_MARGIN_LON = 0.0009

_lock = threading.Lock()                  # one Overpass request at a time, as the public servers ask
_backoff_until = 0.0                      # monotonic seconds
_failed_until: dict[str, float] = {}


class OverpassBusy(Exception):
    """HTTP 429 / 406: the server wants us to wait."""


# ----------------------------------------------------------------------------------------------------------------------------- tiles --

def tile_id(lat: float, lon: float) -> str:
    return f"{math.floor(lat / TILE_DEG)}_{math.floor(lon / TILE_DEG)}"


def tile_bbox(tid: str) -> tuple[float, float, float, float]:
    """(south, west, north, east)"""
    i, j = (int(x) for x in tid.split("_"))
    return i * TILE_DEG, j * TILE_DEG, (i + 1) * TILE_DEG, (j + 1) * TILE_DEG


def tiles_around(lat: float, lon: float) -> set[str]:
    """The tile of a point, plus the neighbour(s) if the point is close enough to an edge that a sign just across it could matter."""
    return {tile_id(lat + dy, lon + dx) for dy in (-_MARGIN_LAT, _MARGIN_LAT) for dx in (-_MARGIN_LON, _MARGIN_LON)}


def build_query(tid: str) -> str:
    s, w, n, e = tile_bbox(tid)
    box = f"{s:.4f},{w:.4f},{n:.4f},{e:.4f}"
    return (
        "[out:json][timeout:25];("
        f'node["highway"~"^(traffic_signals|stop|give_way)$"]({box});'
        f'node["railway"="level_crossing"]({box});'
        f'node["highway"="crossing"]["crossing"="traffic_signals"]({box});'
        ");out;"
    )


# ---------------------------------------------------------------------------------------------------------------------------- parsing --

def feature_kind(tags: dict) -> Optional[str]:
    if tags.get("railway") == "level_crossing":
        return "rail_crossing"
    highway = tags.get("highway")
    if highway == "traffic_signals":
        return "traffic_light"
    if highway == "crossing" and tags.get("crossing") == "traffic_signals":
        return "traffic_light"                       # a pedestrian crossing with its own lights
    if highway == "stop":
        return "stop_sign"
    if highway == "give_way":
        return "give_way"
    return None


def parse_elements(data: dict) -> list[dict]:
    out = []
    for el in data.get("elements", []):
        if el.get("type") != "node" or "lat" not in el or "lon" not in el:
            continue
        tags = el.get("tags") or {}
        kind = feature_kind(tags)
        if not kind:
            continue
        out.append({
            "osm_id": el["id"], "kind": kind, "lat": el["lat"], "lon": el["lon"],
            "direction": tags.get("traffic_signals:direction") or tags.get("stop:direction") or tags.get("direction"),
        })
    return out


# ---------------------------------------------------------------------------------------------------------------------------- network --

def _post(url: str, query: str) -> dict:
    """One Overpass request. Raises OverpassBusy for 429/406, RuntimeError for anything else that isn't a usable answer."""
    response = httpx.post(url, data={"data": query}, headers={"User-Agent": settings.osm_user_agent}, timeout=REQUEST_TIMEOUT_S)
    if response.status_code in (429, 406):
        raise OverpassBusy(url)
    if response.status_code != 200:
        raise RuntimeError(f"HTTP {response.status_code}")
    try:
        data = response.json()
    except ValueError as e:                                  # a busy server can answer 200 with an HTML error page
        raise RuntimeError("not JSON") from e
    if "runtime error" in str(data.get("remark", "")):       # ...or with a JSON "remark" when the query ran out of time
        raise RuntimeError(data["remark"])
    return data


def _fetch_tile(tid: str) -> Optional[list[dict]]:
    """The features of one tile from the first server that answers, or None."""
    global _backoff_until
    query = build_query(tid)
    busy = False
    for url in (u.strip() for u in settings.overpass_urls.split(",") if u.strip()):
        try:
            return parse_elements(_post(url, query))
        except OverpassBusy:
            busy = True
            logger.warning("Overpass %s asks us to slow down", url)
        except Exception as e:                               # timeouts, connection errors, bad answers: try the next server
            logger.warning("Overpass %s failed for tile %s: %s", url, tid, e)
    if busy:
        _backoff_until = time.monotonic() + BACKOFF_S
    return None


# ------------------------------------------------------------------------------------------------------------------------------ cache --

def _fetched_at(conn, tid: str) -> Optional[datetime]:
    row = conn.execute("SELECT fetched_at FROM osm_tiles WHERE tile_id = ?", (tid,)).fetchone()
    return datetime.fromisoformat(row["fetched_at"]) if row else None


def _is_fresh(fetched: Optional[datetime]) -> bool:
    return fetched is not None and datetime.now(timezone.utc) - fetched < TTL


def _store(conn, tid: str, features: list[dict]) -> None:
    conn.execute("DELETE FROM osm_features WHERE tile_id = ?", (tid,))
    conn.executemany(
        "INSERT OR REPLACE INTO osm_features (osm_id, kind, lat, lon, direction, tile_id) VALUES (?, ?, ?, ?, ?, ?)",
        [(f["osm_id"], f["kind"], f["lat"], f["lon"], f["direction"], tid) for f in features],
    )
    conn.execute("INSERT OR REPLACE INTO osm_tiles (tile_id, fetched_at) VALUES (?, ?)", (tid, datetime.now(timezone.utc).isoformat()))
    conn.commit()


def ensure_tiles(conn, tile_ids: set[str]) -> set[str]:
    """Makes sure these tiles are cached; returns the ones that are usable afterwards (fresh, or stale when a refresh wasn't possible)."""
    deadline = time.monotonic() + BUDGET_S
    usable: set[str] = set()
    for tid in sorted(tile_ids):
        fetched = _fetched_at(conn, tid)
        if _is_fresh(fetched):
            usable.add(tid)
            continue
        can_try = time.monotonic() >= _failed_until.get(tid, 0) and time.monotonic() >= _backoff_until and time.monotonic() < deadline
        if can_try:
            with _lock:
                if _is_fresh(_fetched_at(conn, tid)):        # someone else fetched it while we waited for the lock
                    usable.add(tid)
                    continue
                features = _fetch_tile(tid)
            if features is not None:
                _store(conn, tid, features)
                usable.add(tid)
                continue
            _failed_until[tid] = time.monotonic() + FAILURE_RETRY_S
        if fetched is not None:
            usable.add(tid)                                  # old data beats none
    return usable


def features_near(conn, lat: float, lon: float, radius_m: float) -> list[dict]:
    dlat = radius_m / 110_540.0
    dlon = radius_m / (111_320.0 * max(0.1, math.cos(math.radians(lat))))
    rows = conn.execute(
        "SELECT osm_id, kind, lat, lon, direction FROM osm_features WHERE lat BETWEEN ? AND ? AND lon BETWEEN ? AND ?",
        (lat - dlat, lat + dlat, lon - dlon, lon + dlon),
    ).fetchall()
    return [dict(r) for r in rows if geo.haversine_m(lat, lon, r["lat"], r["lon"]) <= radius_m]


# ---------------------------------------------------------------------------------------------------------------------------- the job --

def classify_stops(conn, stops: list[dict]) -> str:
    """Sets kind / label on every stop it can. Returns "ok" (all looked up), "unavailable" (some tiles couldn't be fetched: those stops stay
    plain "Stop") or "disabled"."""
    if not settings.osm_enabled:
        return "disabled"
    if not stops:
        return "ok"
    needed: set[str] = set()
    for stop in stops:
        needed |= tiles_around(stop["lat"], stop["lon"])
    usable = ensure_tiles(conn, needed)
    for stop in stops:
        if tiles_around(stop["lat"], stop["lon"]) <= usable:
            track.classify_stop(stop, features_near(conn, stop["lat"], stop["lon"], SEARCH_RADIUS_M))
    return "ok" if needed <= usable else "unavailable"
