"""View-models shared by the HTML dashboard (routers/dashboard.py) and the JSON API the iOS app uses (routers/api_v1.py).

Every function takes an open connection and the owner's `sub` and only ever reads that owner's rows. The dicts they return are exactly
what the Jinja templates render, so the two front ends can never disagree about a number.
"""
import json
import secrets
import sqlite3
from datetime import datetime, timedelta, timezone

from . import geo, gpx, processing

MAP_RIDES_ON_HOME = 20
RIDES_LIST_LIMIT = 500


def format_duration(seconds: float) -> str:
    total_minutes = int(seconds // 60)
    hours, minutes = divmod(total_minutes, 60)
    return f"{hours}:{minutes:02d}"


def ride_view(row: sqlite3.Row) -> dict:
    view = dict(row)
    view["duration_hm"] = format_duration(row["duration_s"])
    view["distance_km"] = round(row["distance_m"] / 1000, 1)
    view["avg_kmh"] = round(row["avg_speed_mps"] * 3.6)
    view["max_kmh"] = round(row["max_speed_mps"] * 3.6)
    return view


def ride_summary(view: dict) -> dict:
    """The fields the app needs to list a ride; deliberately without the polyline or the owner."""
    return {
        "id": view["id"],
        "start_time": view["start_time"],
        "end_time": view["end_time"],
        "distance_m": view["distance_m"],
        "distance_km": view["distance_km"],
        "duration_s": view["duration_s"],
        "duration_hm": view["duration_hm"],
        "avg_kmh": view["avg_kmh"],
        "max_kmh": view["max_kmh"],
        "elevation_gain_m": round(view["elevation_gain_m"]),
        "point_count": view["point_count"],
        "source": view["source"],
    }


# -------------------------------------------------------------------- home --

def home_context(conn: sqlite3.Connection, owner_sub: str) -> dict:
    latest = conn.execute(
        "SELECT * FROM rides WHERE owner_sub = ? ORDER BY start_time DESC LIMIT 1", (owner_sub,)
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
        WHERE owner_sub = ? ORDER BY start_time DESC LIMIT ?
        """,
        (owner_sub, MAP_RIDES_ON_HOME),
    ).fetchall()
    return {
        "latest": ride_view(latest) if latest else None,
        "ride_count": totals["ride_count"],
        "total_distance_display": f"{(totals['total_distance_m'] or 0) / 1000:,.0f}",
        "avg_speed_display": f"{(totals['avg_speed_mps'] or 0) * 3.6:.0f}",
        "map_data": [
            {
                "id": r["id"],
                "label": r["start_time"][:10],
                "polyline": json.loads(r["polyline_simplified"]),
            }
            for r in map_rides
        ],
    }


# ------------------------------------------------------------------- rides --

def list_rides(
    conn: sqlite3.Connection,
    owner_sub: str,
    date_from: str = "",
    date_to: str = "",
    min_km: str = "",
    max_km: str = "",
    limit: int = RIDES_LIST_LIMIT,
    offset: int = 0,
) -> list[dict]:
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
            value = float(min_km) * 1000
            clauses.append("distance_m >= ?")
            params.append(value)
        except ValueError:
            pass
    if max_km:
        try:
            value = float(max_km) * 1000
            clauses.append("distance_m <= ?")
            params.append(value)
        except ValueError:
            pass

    where = f"WHERE {' AND '.join(clauses)}"
    limit = max(1, min(int(limit), RIDES_LIST_LIMIT))
    offset = max(0, int(offset))
    rows = conn.execute(
        f"SELECT * FROM rides {where} ORDER BY start_time DESC LIMIT ? OFFSET ?",
        [*params, limit, offset],
    ).fetchall()
    return [ride_view(r) for r in rows]


def get_ride(conn: sqlite3.Connection, owner_sub: str, ride_id: int) -> tuple[dict, list] | None:
    """(ride view, polyline) or None. Same None whether the ride doesn't exist or belongs to someone else:
    never reveal that a given ID exists but isn't yours."""
    ride = conn.execute(
        "SELECT * FROM rides WHERE id = ? AND owner_sub = ?", (ride_id, owner_sub)
    ).fetchone()
    if not ride:
        return None
    return ride_view(ride), json.loads(ride["polyline_simplified"])


def get_ride_points(conn: sqlite3.Connection, owner_sub: str, ride_id: int) -> list | None:
    """The GPS points of one of the owner's rides, oldest first, or None if it isn't theirs / doesn't exist (same None for both)."""
    owned = conn.execute("SELECT 1 FROM rides WHERE id = ? AND owner_sub = ?", (ride_id, owner_sub)).fetchone()
    if not owned:
        return None
    return conn.execute(
        """
        SELECT id, lat, lon, timestamp, speed, altitude, horizontal_accuracy FROM points
        WHERE ride_id = ? AND owner_sub = ? ORDER BY timestamp
        """,
        (ride_id, owner_sub),
    ).fetchall()


GPX_DEVICE_ID = "gpx-import"          # marks imported rides (rides.source has a CHECK that only allows two values, and SQLite cannot change it cheaply)
MIN_IMPORT_DISTANCE_M = 50.0          # a track that moves less than this in total is a recording left running, not a ride
DUPLICATE_SHARE = 0.8                 # this much of a sample already in the database means the ride is already there


def _already_have(conn: sqlite3.Connection, owner_sub: str, points: list[dict]) -> bool:
    """True if (almost) all of a spread-out sample of these points is already stored for this owner: the same moment, within about a metre. Compared
    on the first 19 characters of the stored timestamp ("2026-09-28T09:15:00"), which is UTC in every format the server stores."""
    sample = gpx.sample_for_duplicate_check(points)
    found = 0
    for p in sample:
        moment = p["time"].strftime("%Y-%m-%dT%H:%M:%S")
        hit = conn.execute(
            "SELECT 1 FROM points WHERE owner_sub = ? AND substr(timestamp, 1, 19) = ? AND ABS(lat - ?) < 0.00002 AND ABS(lon - ?) < 0.00003 LIMIT 1",
            (owner_sub, moment, p["lat"], p["lon"]),
        ).fetchone()
        found += 1 if hit else 0
    return found / len(sample) >= DUPLICATE_SHARE


def import_tracks(conn: sqlite3.Connection, owner_sub: str, tracks: list[dict]) -> list[dict]:
    """Stores parsed GPX tracks as rides of this owner. Per track: imported (with the ride id), already_imported (the same file again) or
    already_have_this_ride (the same moments are in the database, e.g. the ride's own export), or skipped with a reason. Never raises for one bad track."""
    results = []
    for track in tracks:
        pts, name = track["points"], track["name"]
        trip_id = gpx.import_id(owner_sub, pts)
        existing = conn.execute("SELECT id FROM rides WHERE trip_id = ? AND owner_sub = ?", (trip_id, owner_sub)).fetchone()
        if existing:
            results.append({"status": "already_imported", "name": name, "ride_id": existing["id"], "points": len(pts)})
            continue
        if _already_have(conn, owner_sub, pts):
            results.append({"status": "already_have_this_ride", "name": name, "ride_id": None, "points": len(pts)})
            continue
        if geo.total_distance_m(pts) < MIN_IMPORT_DISTANCE_M:
            results.append({"status": "skipped", "name": name, "ride_id": None, "points": len(pts), "reason": "The track has no movement."})
            continue
        speeds = [p["speed"] for p in pts]
        if any(v is None for v in speeds):
            derived = gpx.derived_speeds(pts)
            speeds = [v if v is not None else d for v, d in zip(speeds, derived)]
        conn.executemany(
            """
            INSERT INTO points (owner_sub, device_id, lat, lon, timestamp, speed, altitude, horizontal_accuracy, trip_id, raw_properties)
            VALUES (?, ?, ?, ?, ?, ?, ?, NULL, ?, ?)
            """,
            [(owner_sub, GPX_DEVICE_ID, p["lat"], p["lon"], p["time"].isoformat(), None if v is None else max(v, 0.0), p["ele"], trip_id,
              json.dumps({"source": "gpx"})) for p, v in zip(pts, speeds)],
        )
        rows = conn.execute(
            "SELECT * FROM points WHERE trip_id = ? AND owner_sub = ? AND ride_id IS NULL ORDER BY timestamp", (trip_id, owner_sub)
        ).fetchall()
        ride_id = processing.compute_and_insert_ride(conn, rows, owner_sub, GPX_DEVICE_ID, "trip_marker", trip_id, None)
        if ride_id is None:
            conn.execute("DELETE FROM points WHERE trip_id = ? AND owner_sub = ?", (trip_id, owner_sub))
            results.append({"status": "skipped", "name": name, "ride_id": None, "points": len(pts), "reason": "The track has no movement or no duration."})
            continue
        results.append({"status": "imported", "name": name, "ride_id": ride_id, "points": len(pts)})
    conn.commit()
    return results


def delete_ride(conn: sqlite3.Connection, owner_sub: str, ride_id: int) -> bool:
    """Removes one of the owner's rides together with all of its GPS points. False (and nothing touched) if it isn't theirs or doesn't exist.

    The points go too, not just the ride row: points left behind with no ride would be turned into a ride again by the gap-based detection
    (a ride without a trip) or by the stale-trip sweep (a ride with one), so the ride would come back on the next upload.
    """
    ride = conn.execute(
        "SELECT id, trip_id FROM rides WHERE id = ? AND owner_sub = ?", (ride_id, owner_sub)
    ).fetchone()
    if not ride:
        return False
    conn.execute(
        "DELETE FROM points WHERE owner_sub = ? AND (ride_id = ? OR (trip_id IS NOT NULL AND trip_id = ?))",
        (owner_sub, ride["id"], ride["trip_id"]),
    )
    conn.execute("DELETE FROM rides WHERE id = ? AND owner_sub = ?", (ride["id"], owner_sub))
    conn.commit()
    return True


# ---------------------------------------------------------------- overview --

def personal_records(conn: sqlite3.Connection, owner_sub: str) -> dict:
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
        records[key] = ride_view(row) if row else None
    return records


def calendar_heatmap(conn: sqlite3.Connection, owner_sub: str, days: int = 90) -> list[dict]:
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


def overview_context(conn: sqlite3.Connection, owner_sub: str) -> dict:
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

    total_distance_km = (totals["total_distance_m"] or 0) / 1000
    longest_ride_km = (totals["longest_ride_m"] or 0) / 1000
    avg_speed_kmh = (totals["avg_speed_mps"] or 0) * 3.6
    return {
        "ride_count": totals["ride_count"],
        "total_distance_display": f"{total_distance_km:,.0f}",
        "avg_speed_display": f"{avg_speed_kmh:.0f}",
        "longest_ride_display": f"{longest_ride_km:,.0f}",
        "weekly_labels": [w["week"] for w in weekly],
        "weekly_distances": [round((w["distance_m"] or 0) / 1000, 1) for w in weekly],
        "records": personal_records(conn, owner_sub),
        "calendar": calendar_heatmap(conn, owner_sub),
    }


# --------------------------------------------------------------------- map --

def map_context(conn: sqlite3.Connection, owner_sub: str) -> dict:
    rides = conn.execute(
        """
        SELECT id, start_time, distance_m, polyline_simplified FROM rides
        WHERE owner_sub = ? ORDER BY start_time DESC
        """,
        (owner_sub,),
    ).fetchall()
    return {
        "map_data": [
            {
                "id": r["id"],
                "label": f"{r['start_time'][:10]} &middot; {round(r['distance_m'] / 1000, 1)} km",
                "polyline": json.loads(r["polyline_simplified"]),
            }
            for r in rides
        ],
        "ride_count": len(rides),
    }


# ----------------------------------------------------------- ingest tokens --

def get_or_create_ingest_token(conn: sqlite3.Connection, owner_sub: str, owner_email: str) -> str:
    row = conn.execute("SELECT token FROM ingest_tokens WHERE owner_sub = ?", (owner_sub,)).fetchone()
    if row:
        return row["token"]
    token = secrets.token_urlsafe(32)
    conn.execute(
        "INSERT INTO ingest_tokens (token, owner_sub, owner_email) VALUES (?, ?, ?)",
        (token, owner_sub, owner_email),
    )
    conn.commit()
    return token


def regenerate_ingest_token(conn: sqlite3.Connection, owner_sub: str, owner_email: str) -> str:
    token = secrets.token_urlsafe(32)
    conn.execute("DELETE FROM ingest_tokens WHERE owner_sub = ?", (owner_sub,))
    conn.execute(
        "INSERT INTO ingest_tokens (token, owner_sub, owner_email) VALUES (?, ?, ?)",
        (token, owner_sub, owner_email),
    )
    conn.commit()
    return token
