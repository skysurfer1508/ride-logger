"""The twisty-road database (roads.db) and the questions the Roads layer asks of it. Separate from the ride database: it is built offline from an OpenStreetMap
extract by `python -m app.cli build-roads`, holds the same for every user, and can be rebuilt at any time. Which roads a person has ridden comes from their own
rides (table ride_ways in the main database, filled when a ride is matched to the road network).
"""
import json
import math
import sqlite3
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable, Optional, Sequence

from . import curvature, geo
from .config import settings

SCHEMA = """
CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE segments (
  id INTEGER PRIMARY KEY,
  way_id INTEGER NOT NULL,
  part INTEGER NOT NULL,
  name TEXT,
  ref TEXT,
  highway TEXT NOT NULL,
  surface TEXT,
  paved INTEGER NOT NULL,
  maxspeed INTEGER,
  length_m INTEGER NOT NULL,
  curvy_m INTEGER NOT NULL,
  score INTEGER NOT NULL,
  geometry TEXT NOT NULL
);
CREATE INDEX idx_segments_way ON segments(way_id);
CREATE VIRTUAL TABLE segments_rtree USING rtree(id, min_lat, max_lat, min_lon, max_lon);
"""
MAX_LAT_SPAN = 1.0
MAX_LON_SPAN = 1.5
RIDDEN_RADIUS_M = 40.0          # a matched point of your ride this close to a stretch's line, on the same road, counts as having ridden it
RIDDEN_SHARE = 0.5              # ... and this share of the stretch's samples must have one nearby: riding across the end of it does not count
ATTRIBUTION = "Roads © OpenStreetMap contributors (ODbL). Twistiness is calculated by RideLog from the road shape."


def path() -> Path:
    return Path(settings.roads_db_path)


def available() -> bool:
    return path().is_file()


def connect() -> sqlite3.Connection:
    """The roads database, read only (the file is replaced as a whole when it is rebuilt)."""
    conn = sqlite3.connect(f"file:{path()}?mode=ro", uri=True)
    conn.row_factory = sqlite3.Row
    return conn


# ------------------------------------------------------------------------------------------------------------------------------- building --

def create(target: Path) -> sqlite3.Connection:
    """A fresh, empty roads database at `target` (an existing file there is replaced)."""
    target.parent.mkdir(parents=True, exist_ok=True)
    for suffix in ("", "-journal", "-wal", "-shm"):
        Path(str(target) + suffix).unlink(missing_ok=True)
    conn = sqlite3.connect(target)
    conn.row_factory = sqlite3.Row
    conn.executescript(SCHEMA)
    return conn


def add_way(conn: sqlite3.Connection, way_id: int, tags: dict, coords: Sequence[tuple[float, float]]) -> int:
    """Scores one OpenStreetMap way and stores its stretches. Returns how many were stored (0 for a way that is not a road to ride)."""
    if not curvature.wanted(tags):
        return 0
    stored = 0
    for part, seg in enumerate(curvature.segments(coords)):
        lats = [p[0] for p in seg["geometry"]]
        lons = [p[1] for p in seg["geometry"]]
        cur = conn.execute(
            "INSERT INTO segments (way_id, part, name, ref, highway, surface, paved, maxspeed, length_m, curvy_m, score, geometry) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)",
            (way_id, part, tags.get("name"), tags.get("ref"), tags["highway"], tags.get("surface"), 1 if curvature.paved(tags) else 0, curvature.maxspeed_kmh(tags),
             seg["length_m"], seg["curvy_m"], seg["score"], json.dumps(seg["geometry"], separators=(",", ":"))),
        )
        conn.execute("INSERT INTO segments_rtree (id, min_lat, max_lat, min_lon, max_lon) VALUES (?,?,?,?,?)", (cur.lastrowid, min(lats), max(lats), min(lons), max(lons)))
        stored += 1
    return stored


def finish(conn: sqlite3.Connection, source: str) -> int:
    count = conn.execute("SELECT COUNT(*) FROM segments").fetchone()[0]
    conn.executemany("INSERT INTO meta (key, value) VALUES (?, ?)", [("built_at", datetime.now(timezone.utc).isoformat()), ("source", source), ("segments", str(count))])
    conn.commit()
    conn.close()
    return count


def info() -> Optional[dict]:
    if not available():
        return None
    conn = connect()
    try:
        return {row["key"]: row["value"] for row in conn.execute("SELECT key, value FROM meta")}
    finally:
        conn.close()


# --------------------------------------------------------------------------------------------------------------------------------- query --

def query(conn: sqlite3.Connection, south: float, west: float, north: float, east: float, limit: int, min_score: int, paved_only: bool) -> tuple[list[dict], bool]:
    """The best stretches inside the box, most twisty road first (the length of road that is bendy, so a 1.5 km pass outranks a 300 m stretch with one hairpin;
    `min_score`, the share of the stretch that is bendy, keeps out roads that are mostly straight). The second value says whether there were more than `limit`."""
    rows = conn.execute(
        """
        SELECT s.* FROM segments_rtree r JOIN segments s ON s.id = r.id
        WHERE r.max_lat >= ? AND r.min_lat <= ? AND r.max_lon >= ? AND r.min_lon <= ? AND s.score >= ? AND (? = 0 OR s.paved = 1)
        ORDER BY s.curvy_m DESC, s.score DESC, s.id LIMIT ?
        """,
        (south, north, west, east, min_score, 1 if paved_only else 0, limit + 1),
    ).fetchall()
    truncated = len(rows) > limit
    return [_road(r) for r in rows[:limit]], truncated


def _road(row: sqlite3.Row) -> dict:
    return {
        "id": row["id"], "way_id": row["way_id"], "name": row["name"], "ref": row["ref"], "highway": row["highway"], "surface": row["surface"],
        "paved": bool(row["paved"]), "maxspeed": row["maxspeed"], "length_m": row["length_m"], "curvy_m": row["curvy_m"], "score": row["score"],
        "geometry": json.loads(row["geometry"]),
    }


# ----------------------------------------------------------------------------------------------------------------------------- ridden --

def ridden_flags(conn: sqlite3.Connection, owner_sub: str, roads: Sequence[dict]) -> list[bool]:
    """For each road: has this person ridden it? True when enough of the stretch's line has a point of one of THEIR matched rides within RIDDEN_RADIUS_M on
    the same OpenStreetMap road. Only their own rides are looked at."""
    way_ids = sorted({r["way_id"] for r in roads})
    if not way_ids:
        return []
    marks = ",".join("?" * len(way_ids))
    rows = conn.execute(
        f"SELECT w.way_id, w.lat, w.lon FROM ride_ways w JOIN rides r ON r.id = w.ride_id WHERE r.owner_sub = ? AND w.way_id IN ({marks})", [owner_sub, *way_ids]
    ).fetchall()
    by_way: dict[int, set[tuple[float, float]]] = {}
    for row in rows:
        by_way.setdefault(row["way_id"], set()).add((round(row["lat"], 4), round(row["lon"], 4)))          # many rides over the same road count once
    return [_covered(road["geometry"], list(by_way.get(road["way_id"], ()))) for road in roads]


def _covered(geometry: Sequence[Sequence[float]], ridden: Sequence[tuple[float, float]]) -> bool:
    if not ridden or not geometry:
        return False
    d_lat = RIDDEN_RADIUS_M / 111_194.9266
    near = 0
    for lat, lon in geometry:
        d_lon = d_lat / max(0.2, math.cos(math.radians(lat)))
        if any(abs(rl - lat) <= d_lat and abs(ro - lon) <= d_lon and geo.haversine_m(lat, lon, rl, ro) <= RIDDEN_RADIUS_M for rl, ro in ridden):
            near += 1
    return near >= max(1, RIDDEN_SHARE * len(geometry))
