"""Maintenance CLI:

  python -m app.cli reprocess [--since ISO_DATE]
      Idempotently recomputes rides from raw points -- useful after tuning
      the segmentation/stat logic in processing.py or geo.py.

  python -m app.cli sweep
      Finalize any stale open trips or gap-inferred rides that stopped
      receiving points and never got a chance to close (this only happens
      as a side effect of ingest requests otherwise). Meant to run on a
      timer -- see deploy/ride-logger-sweep.timer.

  python -m app.cli claim-legacy EMAIL
      Assign rides/points recorded before multi-user support (owner_sub='')
      to the account with the given email. Deliberately CLI-only (server
      access required) rather than a self-serve web button -- Authentik
      registration is open, so any stranger who signed up could otherwise
      claim someone else's historical data. The target account must have
      logged in and visited /settings at least once already (that's what
      creates its ingest_tokens row).
"""

import argparse
from datetime import datetime

from . import processing
from .db import get_db


def reprocess(since: str | None) -> None:
    conn = get_db()
    try:
        if since:
            since_dt = datetime.fromisoformat(since)
            conn.execute("DELETE FROM rides WHERE start_time >= ?", (since_dt.isoformat(),))
            conn.execute(
                "UPDATE points SET ride_id = NULL WHERE timestamp >= ?",
                (since_dt.isoformat(),),
            )
        else:
            conn.execute("DELETE FROM rides")
            conn.execute("UPDATE points SET ride_id = NULL")
        conn.commit()

        trip_keys = [
            (r["owner_sub"], r["trip_id"])
            for r in conn.execute(
                "SELECT DISTINCT owner_sub, trip_id FROM points WHERE trip_id IS NOT NULL"
            ).fetchall()
        ]
        for owner_sub, trip_id in trip_keys:
            rows = conn.execute(
                """
                SELECT * FROM points
                WHERE owner_sub = ? AND trip_id = ? AND ride_id IS NULL
                ORDER BY timestamp
                """,
                (owner_sub, trip_id),
            ).fetchall()
            if rows:
                processing.compute_and_insert_ride(
                    conn,
                    rows,
                    owner_sub=owner_sub,
                    device_id=rows[0]["device_id"],
                    source="trip_marker",
                    trip_id=trip_id,
                    app_reported_distance_m=None,
                )

        owner_devices = [
            (r["owner_sub"], r["device_id"])
            for r in conn.execute("SELECT DISTINCT owner_sub, device_id FROM points").fetchall()
        ]
        for owner_sub, device_id in owner_devices:
            processing.maybe_finalize_gap_inferred_rides(conn, owner_sub, device_id)

        conn.commit()
        count = conn.execute("SELECT COUNT(*) as c FROM rides").fetchone()["c"]
        print(f"Reprocessed. {count} rides now in the database.")
    finally:
        conn.close()


def sweep() -> None:
    conn = get_db()
    try:
        before = conn.execute("SELECT COUNT(*) as c FROM rides").fetchone()["c"]
        processing.sweep_idle_devices(conn)
        conn.commit()
        after = conn.execute("SELECT COUNT(*) as c FROM rides").fetchone()["c"]
        print(f"Swept. {after - before} new ride(s) finalized ({after} total).")
    finally:
        conn.close()


def claim_legacy(email: str) -> None:
    conn = get_db()
    try:
        row = conn.execute(
            "SELECT owner_sub FROM ingest_tokens WHERE owner_email = ?", (email,)
        ).fetchone()
        if not row:
            print(
                f"No account found for {email!r}. That account needs to log in and "
                "visit /settings at least once first (it has to exist before you can "
                "assign anything to it)."
            )
            return
        owner_sub = row["owner_sub"]
        unclaimed = conn.execute(
            "SELECT COUNT(*) as c FROM rides WHERE owner_sub = ''"
        ).fetchone()["c"]
        if unclaimed == 0:
            print("No unclaimed legacy rides to assign.")
            return
        conn.execute("UPDATE rides SET owner_sub = ? WHERE owner_sub = ''", (owner_sub,))
        conn.execute("UPDATE points SET owner_sub = ? WHERE owner_sub = ''", (owner_sub,))
        conn.commit()
        print(f"Assigned {unclaimed} legacy ride(s) to {email!r}.")
    finally:
        conn.close()


def check_traffic() -> None:
    from . import traffic
    for line in traffic.check():
        print(line)


def check_valhalla() -> None:
    """Asks the map-matching service for its status and for the road under one point in Zurich, and Open-Meteo for today's weather there."""
    from datetime import datetime, timedelta, timezone
    from . import valhalla, weather
    from .config import settings
    print(f"Valhalla at {settings.valhalla_url or '(not set)'}:", end=" ")
    if not valhalla.configured():
        print("switched off (VALHALLA_URL is empty)")
    else:
        try:
            print("answering, version", valhalla.status().get("version"))
            match = valhalla.match_points([(47.3769, 8.5417), (47.3772, 8.5421), (47.3775, 8.5425)])
            print("  road under the test points:", [(m or {}).get("name") for m in match])
        except valhalla.ValhallaUnavailable as e:
            print("NOT working:", e)
    print("Open-Meteo:", end=" ")
    now = datetime.now(timezone.utc)
    try:
        summary = weather.summarize(weather.fetch(47.3769, 8.5417, now - timedelta(hours=2), now), now - timedelta(hours=2), now)
        print(summary)
    except weather.WeatherUnavailable as e:
        print("NOT working:", e)


def main() -> None:
    parser = argparse.ArgumentParser(description="Ride Logger maintenance CLI")
    sub = parser.add_subparsers(dest="command", required=True)
    reprocess_p = sub.add_parser("reprocess", help="Recompute rides from raw points")
    reprocess_p.add_argument("--since", help="ISO date; only reprocess points from this date on")
    sub.add_parser("sweep", help="Finalize stale open trips / gap-inferred rides")
    sub.add_parser("check-traffic", help="Call the Traffic tab's data sources once and show what came back")
    sub.add_parser("check-valhalla", help="Check the map-matching service and the weather service once")
    claim_p = sub.add_parser("claim-legacy", help="Assign pre-multi-user data to an account")
    claim_p.add_argument("email", help="Email of the account to assign legacy data to")
    args = parser.parse_args()

    if args.command == "reprocess":
        reprocess(args.since)
    elif args.command == "sweep":
        sweep()
    elif args.command == "check-traffic":
        check_traffic()
    elif args.command == "check-valhalla":
        check_valhalla()
    elif args.command == "claim-legacy":
        claim_legacy(args.email)


if __name__ == "__main__":
    main()
