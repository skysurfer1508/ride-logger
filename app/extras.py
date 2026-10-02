"""Everything the ride screen shows that needs more than the stored points: road and speed limit per point (Valhalla), the weather (Open-Meteo), the
elevation profile and the smoothness. One answer per part, each with its own status, so one failing service never hides the others and never breaks
the ride. The two remote answers are cached per ride (table ride_extras); the cheap maths is done again each time.
"""
import json
import sqlite3
import threading
from datetime import datetime, timezone
from typing import Optional, Sequence

from . import dynamics, geo, insights, limits, track, valhalla, views, weather
from .config import settings

CACHE_VERSION = 1


def _cached(conn: sqlite3.Connection, ride_id: int, kind: str, points: int):
    row = conn.execute("SELECT version, points, payload FROM ride_extras WHERE ride_id = ? AND kind = ?", (ride_id, kind)).fetchone()
    if row and row["version"] == CACHE_VERSION and row["points"] == points:
        try:
            return json.loads(row["payload"])
        except ValueError:
            return None
    return None


def _store(conn: sqlite3.Connection, ride_id: int, kind: str, points: int, payload) -> None:
    conn.execute(
        "INSERT INTO ride_extras (ride_id, kind, version, points, payload, fetched_at) VALUES (?, ?, ?, ?, ?, ?) "
        "ON CONFLICT(ride_id, kind) DO UPDATE SET version = excluded.version, points = excluded.points, payload = excluded.payload, fetched_at = excluded.fetched_at",
        (ride_id, kind, CACHE_VERSION, points, json.dumps(payload), datetime.now(timezone.utc).isoformat()),
    )
    conn.commit()


def _matches(conn: sqlite3.Connection, ride_id: int, points: Sequence[dict]) -> tuple[str, Optional[list]]:
    """(status, per-point matches): ok | disabled | unavailable | no_match."""
    if not valhalla.configured():
        return "disabled", None
    cached = _cached(conn, ride_id, "match", len(points))
    if cached is not None:
        if _cached(conn, ride_id, "ways", len(points)) is None:         # matched before the Roads layer existed
            _store_ways(conn, ride_id, points, cached)
        return "ok", cached
    try:
        matches = valhalla.match_points([(p["lat"], p["lon"]) for p in points])
    except valhalla.ValhallaUnavailable:
        return "unavailable", None
    if not any(matches):
        _store_ways(conn, ride_id, points, matches)             # nothing to remember, but it was looked at: the catch-up must not try again and again
        return "no_match", None
    _store(conn, ride_id, "match", len(points), matches)
    _store_ways(conn, ride_id, points, matches)
    return "ok", matches


WAY_SPACING_M = 40.0
_catch_up_lock = threading.Lock()


def ways_from_matches(points: Sequence[dict], matches: Sequence[Optional[dict]]) -> list[tuple[int, float, float]]:
    """(way id, lat, lon) along the ride, one about every WAY_SPACING_M on each road (the first point on a road is always kept)."""
    kept: list[tuple[int, float, float]] = []
    last: dict[int, tuple[float, float]] = {}
    for p, m in zip(points, matches):
        way = (m or {}).get("way_id")
        if not way:
            continue
        before = last.get(way)
        if before is None or geo.haversine_m(before[0], before[1], p["lat"], p["lon"]) >= WAY_SPACING_M:
            last[way] = (p["lat"], p["lon"])
            kept.append((int(way), round(p["lat"], 6), round(p["lon"], 6)))
    return kept


def _store_ways(conn: sqlite3.Connection, ride_id: int, points: Sequence[dict], matches: Sequence[Optional[dict]]) -> None:
    conn.execute("DELETE FROM ride_ways WHERE ride_id = ?", (ride_id,))
    conn.executemany("INSERT INTO ride_ways (ride_id, way_id, lat, lon) VALUES (?, ?, ?, ?)", [(ride_id, w, lat, lon) for w, lat, lon in ways_from_matches(points, matches)])
    _store(conn, ride_id, "ways", len(points), {})


def pending_rides(conn: sqlite3.Connection, owner_sub: str) -> list[int]:
    """The owner's rides whose roads have not been worked out yet (newest first)."""
    rows = conn.execute(
        "SELECT r.id FROM rides r LEFT JOIN ride_extras e ON e.ride_id = r.id AND e.kind = 'ways' AND e.version = ? WHERE r.owner_sub = ? AND e.ride_id IS NULL ORDER BY r.start_time DESC",
        (CACHE_VERSION, owner_sub),
    ).fetchall()
    return [r["id"] for r in rows]


def catch_up_ways(owner_sub: str, limit: int = 25) -> int:
    """Works out the roads of up to `limit` of the owner's rides that have none yet. Returns how many were done. Meant for a background task; two at once
    would only repeat each other's work, so a second caller returns at once."""
    if not valhalla.configured() or not _catch_up_lock.acquire(blocking=False):
        return 0
    from .db import get_db
    conn = get_db()
    done = 0
    try:
        for ride_id in pending_rides(conn, owner_sub)[:limit]:
            rows = views.get_ride_points(conn, owner_sub, ride_id)
            points = track._prepare(rows or [])
            if len(points) < 2:
                _store(conn, ride_id, "ways", len(points), {})
                continue
            status, _ = _matches(conn, ride_id, points)
            if status == "unavailable":
                break                                              # the matcher is down: stop, the next visit tries again
            done += 1
    finally:
        conn.close()
        _catch_up_lock.release()
    return done


def _weather(conn: sqlite3.Connection, ride_id: int, points: Sequence[dict]) -> dict:
    if not settings.weather_enabled:
        return {"status": "disabled"}
    start, end = points[0]["timestamp"], points[-1]["timestamp"]
    cached = _cached(conn, ride_id, "weather", len(points))
    if cached is not None:
        return {"status": "ok", **cached}
    try:
        hourly = weather.fetch(points[0]["lat"], points[0]["lon"], start, end)
    except weather.WeatherUnavailable as e:
        return {"status": "unavailable", "message": str(e)}
    summary = weather.summarize(hourly, start, end)
    if summary is None:
        return {"status": "unavailable", "message": "The weather service has no data for this ride yet."}
    _store(conn, ride_id, "weather", len(points), summary)
    return {"status": "ok", **summary}


def _road_names(points: Sequence[dict], matches: Sequence[Optional[dict]]) -> list[list]:
    """[[seconds since start, road name], ...] each time the road changes, so the app can say which road a stop was on."""
    out: list[list] = []
    last = None
    for p, m in zip(points, matches):
        name = (m or {}).get("name")
        if name and name != last:
            out.append([round(p["t"], 1), name])
            last = name
    return out


def build(conn: sqlite3.Connection, ride_id: int, rows: Sequence) -> dict:
    points = track._prepare(rows)
    if len(points) < 2:
        return {"elevation": None, "smoothness": None, "dynamics": None, "weather": {"status": "unavailable", "message": "Not enough data."},
                "limits": {"status": "no_data"}, "road_names": []}
    track._fill_speeds(points)
    result = {"elevation": insights.elevation_profile(points), "smoothness": insights.smoothness(points), "dynamics": dynamics.analyze(points),
              "weather": _weather(conn, ride_id, points)}
    status, matches = _matches(conn, ride_id, points)
    if matches is None:
        result["limits"] = {"status": status}
        result["road_names"] = []
    else:
        result["limits"] = {"status": "ok", **limits.analyze(points, matches)}
        result["road_names"] = _road_names(points, matches)
    return result
