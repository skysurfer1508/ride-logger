"""Everything the ride screen shows that needs more than the stored points: road and speed limit per point (Valhalla), the weather (Open-Meteo), the
elevation profile and the smoothness. One answer per part, each with its own status, so one failing service never hides the others and never breaks
the ride. The two remote answers are cached per ride (table ride_extras); the cheap maths is done again each time.
"""
import json
import sqlite3
from datetime import datetime, timezone
from typing import Optional, Sequence

from . import dynamics, insights, limits, track, valhalla, weather
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
        return "ok", cached
    try:
        matches = valhalla.match_points([(p["lat"], p["lon"]) for p in points])
    except valhalla.ValhallaUnavailable:
        return "unavailable", None
    if not any(matches):
        return "no_match", None
    _store(conn, ride_id, "match", len(points), matches)
    return "ok", matches


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
