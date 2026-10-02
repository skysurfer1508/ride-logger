"""Trip segmentation and ride stat computation.

Segmentation priority:
1. `trip_id` grouping (points tagged while an Overland "trip" is active) --
   primary and most reliable signal.
2. Finalize on the trip-end marker Overland sends (properties.type == "trip").
3. Gap-based fallback for points that never got a trip_id at all (plain
   background tracking, no Start Trip press).
4. Stale-open-trip safety net, in case the end marker never arrives (app
   killed, phone died mid-ride).

Every function here is scoped by owner_sub: device_id alone is not unique
across accounts (e.g. two people's phones can both report device_id ""), so
grouping/segmentation always keys off (owner_sub, device_id) together.
"""

import json
import sqlite3
from datetime import datetime, timedelta, timezone
from typing import Optional

from . import geo
from .config import settings
from .models import LocationFeature, LocationProperties

DEFAULT_EPSILON_M = 5.0


def _parse_ts(ts: str) -> datetime:
    dt = datetime.fromisoformat(ts)
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt


def insert_point(conn: sqlite3.Connection, feature: LocationFeature, owner_sub: str) -> bool:
    """Store one point. Returns False (and stores nothing) if this exact point is already there.

    A client that never saw the "ok" for a batch has to send it again, and Overland and the RideLog app both do. Without this a
    retried batch would double its points and inflate the ride's distance. "Same point" = same owner, device, timestamp and position.
    """
    props = feature.properties
    lon, lat = feature.geometry.coordinates[0], feature.geometry.coordinates[1]
    duplicate = conn.execute(
        """
        SELECT 1 FROM points
        WHERE owner_sub = ? AND device_id = ? AND timestamp = ? AND lat = ? AND lon = ?
        LIMIT 1
        """,
        (owner_sub, props.device_id or "", props.timestamp, lat, lon),
    ).fetchone()
    if duplicate:
        return False
    conn.execute(
        """
        INSERT INTO points (owner_sub, device_id, lat, lon, timestamp, speed, altitude,
                             horizontal_accuracy, vertical_accuracy, motion,
                             battery_level, trip_id, raw_properties)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        (
            owner_sub,
            props.device_id or "",
            lat,
            lon,
            props.timestamp,
            props.speed,
            props.altitude,
            props.horizontal_accuracy,
            props.vertical_accuracy,
            json.dumps(props.motion) if props.motion else None,
            props.battery_level,
            props.trip_id,
            props.model_dump_json(),
        ),
    )
    return True


def _rows_to_points(rows) -> list[dict]:
    """Point rows as dicts. `course` / `course_accuracy` (degrees, from the app's GPS Doppler heading) are there only when the query asked for them."""
    return [
        {
            "id": r["id"],
            "lat": r["lat"],
            "lon": r["lon"],
            "timestamp": _parse_ts(r["timestamp"]),
            "speed": r["speed"],
            "altitude": r["altitude"],
            "horizontal_accuracy": r["horizontal_accuracy"],
            "course": r["course"] if "course" in r.keys() else None,
            "course_accuracy": r["course_accuracy"] if "course_accuracy" in r.keys() else None,
        }
        for r in rows
    ]


def _measure(rows) -> Optional[dict]:
    """Distance, duration, speeds, climb and the simplified route of a set of points; None if there is no ride in them."""
    if not rows:
        return None
    points = _rows_to_points(rows)
    points.sort(key=lambda p: p["timestamp"])
    filtered = geo.filter_points(points)
    if len(filtered) < 2:
        filtered = points
    if len(filtered) < 2:
        return None

    duration_s = (filtered[-1]["timestamp"] - filtered[0]["timestamp"]).total_seconds()
    if duration_s <= 0:
        return None

    distance_m = geo.total_distance_m(filtered)
    return {
        "start": filtered[0]["timestamp"].isoformat(),
        "end": filtered[-1]["timestamp"].isoformat(),
        "distance_m": distance_m,
        "duration_s": duration_s,
        "avg_speed_mps": distance_m / duration_s,
        "max_speed": geo.max_speed_mps(filtered),
        "elevation_gain": geo.elevation_gain_m(filtered),
        "polyline": geo.rdp_simplify([(p["lat"], p["lon"]) for p in filtered], epsilon_m=DEFAULT_EPSILON_M),
        "point_count": len(points),
    }


def _update_closed_ride(
    conn: sqlite3.Connection, ride_id: int, owner_sub: str, trip_id: str, app_reported_distance_m: Optional[float]
) -> int:
    """Points for a trip arrived after its ride had already been made (the stale-trip sweep closes a trip that goes quiet for an hour,
    e.g. a phone with no signal, and its last points come in later). The ride is measured again from every point of the trip, so it ends up
    exactly as if they had arrived on time."""
    all_rows = conn.execute(
        "SELECT * FROM points WHERE trip_id = ? AND owner_sub = ? ORDER BY timestamp", (trip_id, owner_sub)
    ).fetchall()
    m = _measure(all_rows)
    if m is not None:
        conn.execute(
            """
            UPDATE rides SET start_time = ?, end_time = ?, distance_m = ?, duration_s = ?, avg_speed_mps = ?,
                             max_speed_mps = ?, elevation_gain_m = ?, point_count = ?, polyline_simplified = ?,
                             app_reported_distance_m = COALESCE(?, app_reported_distance_m)
            WHERE id = ?
            """,
            (m["start"], m["end"], m["distance_m"], m["duration_s"], m["avg_speed_mps"], m["max_speed"],
             m["elevation_gain"], m["point_count"], json.dumps(m["polyline"]), app_reported_distance_m, ride_id),
        )
    conn.execute(
        "UPDATE points SET ride_id = ? WHERE trip_id = ? AND owner_sub = ? AND ride_id IS NULL", (ride_id, trip_id, owner_sub)
    )
    return ride_id


def compute_and_insert_ride(
    conn: sqlite3.Connection,
    rows,
    owner_sub: str,
    device_id: str,
    source: str,
    trip_id: Optional[str],
    app_reported_distance_m: Optional[float],
) -> Optional[int]:
    if not rows:
        return None
    if trip_id:
        existing = conn.execute(
            "SELECT id FROM rides WHERE trip_id = ? AND owner_sub = ?", (trip_id, owner_sub)
        ).fetchone()
        if existing:
            return _update_closed_ride(conn, existing["id"], owner_sub, trip_id, app_reported_distance_m)
    m = _measure(rows)
    if m is None:
        return None
    filtered_start, filtered_end = m["start"], m["end"]
    distance_m, duration_s = m["distance_m"], m["duration_s"]
    avg_speed_mps, max_speed = m["avg_speed_mps"], m["max_speed"]
    elevation_gain, polyline = m["elevation_gain"], m["polyline"]
    points = rows

    cur = conn.execute(
        """
        INSERT INTO rides (owner_sub, device_id, trip_id, start_time, end_time, distance_m,
                            duration_s, avg_speed_mps, max_speed_mps, elevation_gain_m,
                            point_count, polyline_simplified, source, app_reported_distance_m)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        (
            owner_sub,
            device_id,
            trip_id,
            filtered_start,
            filtered_end,
            distance_m,
            duration_s,
            avg_speed_mps,
            max_speed,
            elevation_gain,
            len(points),
            json.dumps(polyline),
            source,
            app_reported_distance_m,
        ),
    )
    ride_id = cur.lastrowid
    conn.executemany(
        "UPDATE points SET ride_id = ? WHERE id = ?",
        [(ride_id, r["id"]) for r in rows],
    )
    return ride_id


def finalize_trip_from_marker(
    conn: sqlite3.Connection, marker: LocationProperties, owner_sub: str, device_id: str
) -> Optional[int]:
    trip_id = marker.start
    if not trip_id:
        return None
    # A ride for this trip may already exist (a resent marker, or the stale-trip sweep closed it first). Only points that no ride has yet
    # matter: with none, there is nothing to do; with some, they are folded into that ride (see compute_and_insert_ride).
    rows = conn.execute(
        """
        SELECT * FROM points
        WHERE trip_id = ? AND owner_sub = ? AND ride_id IS NULL
        ORDER BY timestamp
        """,
        (trip_id, owner_sub),
    ).fetchall()
    if not rows:
        return None
    return compute_and_insert_ride(
        conn,
        rows,
        owner_sub=owner_sub,
        device_id=device_id,
        source="trip_marker",
        trip_id=trip_id,
        app_reported_distance_m=marker.distance,
    )


def maybe_finalize_gap_inferred_rides(
    conn: sqlite3.Connection, owner_sub: str, device_id: str
) -> None:
    rows = conn.execute(
        """
        SELECT * FROM points
        WHERE owner_sub = ? AND device_id = ? AND trip_id IS NULL AND ride_id IS NULL
        ORDER BY timestamp
        """,
        (owner_sub, device_id),
    ).fetchall()
    if not rows:
        return

    points = _rows_to_points(rows)
    gap = timedelta(minutes=settings.gap_minutes)
    now = datetime.now(timezone.utc)

    groups: list[list[dict]] = [[]]
    for p in points:
        if groups[-1] and (p["timestamp"] - groups[-1][-1]["timestamp"]) > gap:
            groups.append([])
        groups[-1].append(p)

    # Only close a group once we're sure it's over: either a later gap proves
    # it, or the most recent point in it is already stale relative to now.
    closable = list(groups[:-1])
    if groups[-1] and (now - groups[-1][-1]["timestamp"]) > gap:
        closable.append(groups[-1])

    rows_by_id = {r["id"]: r for r in rows}
    for group in closable:
        if len(group) < settings.min_points:
            continue
        dist = geo.total_distance_m(geo.filter_points(group))
        if dist < settings.min_distance_m:
            continue
        group_rows = [rows_by_id[p["id"]] for p in group]
        compute_and_insert_ride(
            conn,
            group_rows,
            owner_sub=owner_sub,
            device_id=device_id,
            source="gap_inferred",
            trip_id=None,
            app_reported_distance_m=None,
        )


def sweep_stale_open_trips(conn: sqlite3.Connection) -> None:
    stale_before = datetime.now(timezone.utc) - timedelta(minutes=settings.stale_trip_minutes)
    open_trips = conn.execute(
        """
        SELECT trip_id, owner_sub, device_id, MAX(timestamp) as last_ts
        FROM points
        WHERE trip_id IS NOT NULL AND ride_id IS NULL
        GROUP BY trip_id, owner_sub, device_id
        """
    ).fetchall()
    for t in open_trips:
        if _parse_ts(t["last_ts"]) >= stale_before:
            continue
        rows = conn.execute(
            """
            SELECT * FROM points
            WHERE trip_id = ? AND owner_sub = ? AND ride_id IS NULL
            ORDER BY timestamp
            """,
            (t["trip_id"], t["owner_sub"]),
        ).fetchall()
        compute_and_insert_ride(
            conn,
            rows,
            owner_sub=t["owner_sub"],
            device_id=t["device_id"],
            source="trip_marker",
            trip_id=t["trip_id"],
            app_reported_distance_m=None,
        )


def sweep_idle_devices(conn: sqlite3.Connection) -> None:
    """Catch-all sweep, meant to run on a schedule independent of ingest
    traffic.

    Both sweep_stale_open_trips() and maybe_finalize_gap_inferred_rides()
    only ever run as a side effect of a *new* ingest request arriving --
    which means a gap-inferred ride (no trip_id at all) that stops getting
    new points never gets closed if the device simply goes quiet and no
    further request ever triggers the check. This re-checks every device
    with pending unassigned points regardless of live traffic.
    """
    sweep_stale_open_trips(conn)
    owner_devices = conn.execute(
        """
        SELECT DISTINCT owner_sub, device_id FROM points
        WHERE trip_id IS NULL AND ride_id IS NULL
        """
    ).fetchall()
    for row in owner_devices:
        maybe_finalize_gap_inferred_rides(conn, row["owner_sub"], row["device_id"])
