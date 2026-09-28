"""View-models shared by the HTML dashboard (routers/dashboard.py) and the JSON API the iOS app uses (routers/api_v1.py).

Every function takes an open connection and the owner's `sub` and only ever reads that owner's rows. The dicts they return are exactly
what the Jinja templates render, so the two front ends can never disagree about a number.
"""
import json
import secrets
import sqlite3
from datetime import datetime, timedelta, timezone

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
