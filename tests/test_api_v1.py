from datetime import datetime, timedelta, timezone

import pytest

import app.routers.api_v1 as api_v1
from app.config import settings
from conftest import ALICE, BOB, add_ride, add_token, logged_in

CLIENT = {"X-RideLog-Client": "1"}
GETS = ["/api/v1/me", "/api/v1/home", "/api/v1/rides", "/api/v1/rides/1", "/api/v1/overview", "/api/v1/map", "/api/v1/settings"]


def days_ago(n: int) -> str:
    return (datetime.now(timezone.utc).replace(hour=12, minute=0, second=0, microsecond=0) - timedelta(days=n)).isoformat()


# ----------------------------------------------------------------- access --

@pytest.mark.parametrize("path", GETS)
def test_logged_out_gets_a_plain_401_not_a_redirect(anon, path):
    r = anon.get(path)
    assert r.status_code == 401
    assert r.json() == {"detail": "not_authenticated"}
    assert "location" not in r.headers


def test_changes_need_the_client_header(alice):
    body = {"gap_minutes": 10, "min_points": 5, "min_distance_m": 200, "stale_trip_minutes": 60}
    assert alice.post("/api/v1/settings/regenerate-token").status_code == 403
    assert alice.post("/api/v1/settings/detection", data=body).status_code == 403


def test_logged_out_change_is_401_even_with_the_header(anon):
    assert anon.post("/api/v1/settings/regenerate-token", headers=CLIENT).status_code == 401


def test_replies_carry_the_api_version_and_are_not_cacheable(alice):
    r = alice.get("/api/v1/home")
    assert r.json()["api"] == 1
    assert r.headers["cache-control"] == "no-store"


def test_the_website_still_redirects_logged_out_visitors(anon):
    r = anon.get("/rides")
    assert r.status_code == 303 and r.headers["location"].startswith("/login")


# --------------------------------------------------------------------- me --

def test_me_creates_the_ingest_token_once_and_keeps_it(alice):
    first = alice.get("/api/v1/me").json()
    second = alice.get("/api/v1/me").json()
    assert first["name"] == "Alice" and first["email"] == "alice@example.com"
    assert first["ingest_path"] == "/api/ingest"
    assert len(first["ingest_token"]) >= 32
    assert second["ingest_token"] == first["ingest_token"]


def test_each_user_gets_their_own_token(alice, bob):
    assert alice.get("/api/v1/me").json()["ingest_token"] != bob.get("/api/v1/me").json()["ingest_token"]


def test_regenerate_token_replaces_the_old_one(alice):
    old = alice.get("/api/v1/me").json()["ingest_token"]
    new = alice.post("/api/v1/settings/regenerate-token", headers=CLIENT).json()["ingest_token"]
    assert new != old
    assert alice.get("/api/v1/me").json()["ingest_token"] == new
    # the old token no longer authenticates an upload
    assert alice.post("/api/ingest", json={"locations": []}, headers={"Authorization": f"Bearer {old}"}).status_code == 401
    assert alice.post("/api/ingest", json={"locations": []}, headers={"Authorization": f"Bearer {new}"}).status_code == 200


# ------------------------------------------------------------------- home --

def test_home_for_a_new_user_is_empty_not_an_error(alice):
    data = alice.get("/api/v1/home").json()
    assert data["ride_count"] == 0 and data["latest"] is None and data["recent_routes"] == []


def test_home_says_how_far_you_rode_this_week_and_only_this_week(alice, bob):
    from datetime import datetime, timedelta, timezone
    now = datetime.now(timezone.utc)
    add_ride(ALICE["sub"], now.isoformat(), distance_m=40_000)
    add_ride(ALICE["sub"], (now - timedelta(days=21)).isoformat(), distance_m=90_000)
    add_ride(BOB["sub"], now.isoformat(), distance_m=70_000)
    assert alice.get("/api/v1/home").json()["week_km"] == 40.0
    assert bob.get("/api/v1/home").json()["week_km"] == 70.0


def test_a_new_user_has_ridden_nothing_this_week(alice):
    assert alice.get("/api/v1/home").json()["week_km"] == 0.0


def test_home_shows_only_my_rides(alice, bob):
    add_ride(ALICE["sub"], days_ago(2), distance_m=40_000)
    add_ride(ALICE["sub"], days_ago(1), distance_m=60_000)
    add_ride(BOB["sub"], days_ago(0), distance_m=999_000)
    data = alice.get("/api/v1/home").json()
    assert data["ride_count"] == 2
    assert data["total_distance_display"] == "100"
    assert data["latest"]["distance_km"] == 60.0
    assert len(data["recent_routes"]) == 2
    assert "polyline_simplified" not in data["latest"] and "owner_sub" not in data["latest"]


# ------------------------------------------------------------------ rides --

def test_rides_list_is_newest_first_and_has_no_polylines(alice):
    for n in (5, 3, 1):
        add_ride(ALICE["sub"], days_ago(n))
    data = alice.get("/api/v1/rides").json()
    assert [r["start_time"][:10] for r in data["rides"]] == [days_ago(1)[:10], days_ago(3)[:10], days_ago(5)[:10]]
    assert all("polyline" not in r and "polyline_simplified" not in r for r in data["rides"])
    assert data["has_more"] is False


def test_rides_paging(alice):
    for n in range(5):
        add_ride(ALICE["sub"], days_ago(n))
    first = alice.get("/api/v1/rides?limit=2").json()
    assert len(first["rides"]) == 2 and first["has_more"] is True
    last = alice.get("/api/v1/rides?limit=2&offset=4").json()
    assert len(last["rides"]) == 1 and last["has_more"] is False


def test_rides_filters(alice):
    add_ride(ALICE["sub"], days_ago(30), distance_m=5_000)
    add_ride(ALICE["sub"], days_ago(20), distance_m=50_000)
    add_ride(ALICE["sub"], days_ago(10), distance_m=200_000)
    assert len(alice.get("/api/v1/rides?min_km=10&max_km=100").json()["rides"]) == 1
    assert len(alice.get(f"/api/v1/rides?date_from={days_ago(25)[:10]}").json()["rides"]) == 2
    assert len(alice.get(f"/api/v1/rides?date_to={days_ago(25)[:10]}").json()["rides"]) == 1


def test_a_garbage_number_filter_is_ignored_not_a_server_error(alice):
    add_ride(ALICE["sub"], days_ago(1))
    add_token(ALICE["sub"], ALICE["email"], "alice-token")          # the website sends a user with no token to /welcome first
    assert len(alice.get("/api/v1/rides?min_km=abc").json()["rides"]) == 1
    assert alice.get("/rides?min_km=abc").status_code == 200        # the website page too


def test_rides_limit_is_validated(alice):
    assert alice.get("/api/v1/rides?limit=0").status_code == 422
    assert alice.get("/api/v1/rides?limit=100000").status_code == 422


def test_ride_detail_returns_polyline(alice):
    rid = add_ride(ALICE["sub"], days_ago(1), polyline=[[47.1, 8.1], [47.2, 8.2]])
    data = alice.get(f"/api/v1/rides/{rid}").json()
    assert data["polyline"] == [[47.1, 8.1], [47.2, 8.2]]
    assert data["ride"]["id"] == rid and data["ride"]["duration_hm"] == "0:30"


def test_someone_elses_ride_is_a_404_exactly_like_a_missing_one(alice):
    theirs = add_ride(BOB["sub"], days_ago(1))
    other = alice.get(f"/api/v1/rides/{theirs}")
    missing = alice.get("/api/v1/rides/99999")
    assert other.status_code == missing.status_code == 404
    assert other.json() == missing.json() == {"detail": "ride_not_found"}


# --------------------------------------------------------------- overview --

def test_overview_shape(alice):
    add_ride(ALICE["sub"], days_ago(1), distance_m=120_000, duration_s=5400, max_mps=40, climb_m=800)
    add_ride(ALICE["sub"], days_ago(2), distance_m=20_000)
    data = alice.get("/api/v1/overview").json()
    assert data["ride_count"] == 2
    assert data["total_distance_display"] == "140"
    assert data["longest_ride_display"] == "120"
    assert len(data["calendar"]) == 90
    assert data["records"]["longest"]["distance_km"] == 120.0
    assert data["records"]["most_climb"]["elevation_gain_m"] == 800
    assert sum(w["km"] for w in data["weekly"]) == pytest.approx(140.0)


def test_overview_for_a_new_user(alice):
    data = alice.get("/api/v1/overview").json()
    assert data["ride_count"] == 0 and data["weekly"] == []
    assert all(v is None for v in data["records"].values())


# -------------------------------------------------------------------- map --

def test_map_labels_are_plain_text_and_only_mine(alice):
    add_ride(ALICE["sub"], days_ago(1), distance_m=12_300)
    add_ride(BOB["sub"], days_ago(1))
    data = alice.get("/api/v1/map").json()
    assert data["ride_count"] == 1
    assert "&middot;" not in data["routes"][0]["label"] and "12.3 km" in data["routes"][0]["label"]


# --------------------------------------------------------------- settings --

@pytest.fixture
def isolated_settings(monkeypatch, tmp_path):
    """The detection form writes to .env and to the process-wide settings: point it at a scratch file and restore the values."""
    env = tmp_path / ".env"
    env.write_text("SESSION_SECRET=x\n")
    monkeypatch.setattr(api_v1, "ENV_PATH", env)
    for name in ("gap_minutes", "min_points", "min_distance_m", "stale_trip_minutes"):
        monkeypatch.setattr(settings, name, getattr(settings, name))
    return env


def test_detection_settings_round_trip(alice, isolated_settings):
    body = {"gap_minutes": 15, "min_points": 8, "min_distance_m": 300, "stale_trip_minutes": 90}
    r = alice.post("/api/v1/settings/detection", data=body, headers=CLIENT)
    assert r.status_code == 200
    assert r.json()["detection"] == {"gap_minutes": 15, "min_points": 8, "min_distance_m": 300, "stale_trip_minutes": 90}
    assert alice.get("/api/v1/settings").json()["detection"]["gap_minutes"] == 15
    text = isolated_settings.read_text()
    assert "GAP_MINUTES=15.0" in text and "MIN_POINTS=8" in text and "SESSION_SECRET=x" in text


def test_detection_settings_reject_non_positive_values(alice, isolated_settings):
    body = {"gap_minutes": 0, "min_points": 5, "min_distance_m": 200, "stale_trip_minutes": 60}
    r = alice.post("/api/v1/settings/detection", data=body, headers=CLIENT)
    assert r.status_code == 400 and r.json() == {"detail": "values_must_be_positive"}
    assert isolated_settings.read_text() == "SESSION_SECRET=x\n"


def test_two_users_are_independent_sessions(alice, bob):
    add_ride(ALICE["sub"], days_ago(1))
    assert alice.get("/api/v1/home").json()["ride_count"] == 1
    assert bob.get("/api/v1/home").json()["ride_count"] == 0
    assert logged_in(BOB).get("/api/v1/rides/1").status_code == 404


# ----------------------------------------------------------------- delete --

def add_points(owner_sub: str, ride_id: int | None, trip_id: str | None, count: int = 3) -> None:
    from app.db import get_db
    conn = get_db()
    try:
        for i in range(count):
            conn.execute(
                "INSERT INTO points (owner_sub, device_id, lat, lon, timestamp, trip_id, ride_id, raw_properties) VALUES (?, 'dev', 47, 8, ?, ?, ?, '{}')",
                (owner_sub, f"2026-09-01T10:00:0{i}Z", trip_id, ride_id),
            )
        conn.commit()
    finally:
        conn.close()


def count(sql: str, *args) -> int:
    from app.db import get_db
    conn = get_db()
    try:
        return conn.execute(sql, args).fetchone()[0]
    finally:
        conn.close()


def test_delete_removes_the_ride_and_its_points(alice):
    keep = add_ride(ALICE["sub"], days_ago(3), trip_id="keep")
    gone = add_ride(ALICE["sub"], days_ago(2), trip_id="gone")
    add_points(ALICE["sub"], keep, "keep")
    add_points(ALICE["sub"], gone, "gone")
    r = alice.delete(f"/api/v1/rides/{gone}", headers=CLIENT)
    assert r.status_code == 200 and r.json() == {"api": 1, "deleted": gone}
    assert count("SELECT COUNT(*) FROM rides WHERE id = ?", gone) == 0
    assert count("SELECT COUNT(*) FROM points WHERE ride_id = ?", gone) == 0
    assert count("SELECT COUNT(*) FROM rides WHERE id = ?", keep) == 1          # the other ride is untouched
    assert count("SELECT COUNT(*) FROM points WHERE ride_id = ?", keep) == 3


def test_deleting_also_removes_points_of_the_trip_that_no_ride_has_yet(alice):
    """Points still waiting for their ride would otherwise bring it straight back (stale-trip sweep)."""
    rid = add_ride(ALICE["sub"], days_ago(2), trip_id="t")
    add_points(ALICE["sub"], rid, "t", count=2)
    add_points(ALICE["sub"], None, "t", count=2)
    alice.delete(f"/api/v1/rides/{rid}", headers=CLIENT)
    assert count("SELECT COUNT(*) FROM points") == 0


def test_a_deleted_ride_does_not_come_back_on_the_next_ingest(alice):
    """A gap-inferred ride (no trip) is deleted with its points, so the ingest that follows has nothing to rebuild it from."""
    add_token(ALICE["sub"], ALICE["email"], "tok")
    rid = add_ride(ALICE["sub"], "2026-09-01T10:00:00+00:00", trip_id=None)
    add_points(ALICE["sub"], rid, None, count=6)
    alice.delete(f"/api/v1/rides/{rid}", headers=CLIENT)
    assert alice.post("/api/ingest", json={"locations": []}, headers={"Authorization": "Bearer tok"}).status_code == 200
    assert count("SELECT COUNT(*) FROM rides") == 0


def test_the_totals_follow_a_delete(alice):
    a = add_ride(ALICE["sub"], days_ago(2), distance_m=40_000)
    add_ride(ALICE["sub"], days_ago(1), distance_m=60_000)
    assert alice.get("/api/v1/home").json()["ride_count"] == 2
    alice.delete(f"/api/v1/rides/{a}", headers=CLIENT)
    home = alice.get("/api/v1/home").json()
    assert home["ride_count"] == 1 and home["total_distance_display"] == "60"
    assert alice.get(f"/api/v1/rides/{a}").status_code == 404


def test_you_cannot_delete_someone_elses_ride(alice, bob):
    theirs = add_ride(BOB["sub"], days_ago(1), trip_id="bobs")
    add_points(BOB["sub"], theirs, "bobs")
    r = alice.delete(f"/api/v1/rides/{theirs}", headers=CLIENT)
    assert r.status_code == 404 and r.json() == {"detail": "ride_not_found"}          # the same answer as for a ride that doesn't exist
    assert alice.delete("/api/v1/rides/99999", headers=CLIENT).json() == r.json()
    assert count("SELECT COUNT(*) FROM rides WHERE id = ?", theirs) == 1
    assert count("SELECT COUNT(*) FROM points WHERE ride_id = ?", theirs) == 3
    assert bob.get(f"/api/v1/rides/{theirs}").status_code == 200


def test_delete_needs_the_client_header_and_a_login(alice, anon):
    rid = add_ride(ALICE["sub"], days_ago(1))
    assert alice.delete(f"/api/v1/rides/{rid}").status_code == 403
    assert anon.delete(f"/api/v1/rides/{rid}", headers=CLIENT).status_code == 401
    assert count("SELECT COUNT(*) FROM rides WHERE id = ?", rid) == 1


def test_deleting_twice_is_a_404_the_second_time(alice):
    rid = add_ride(ALICE["sub"], days_ago(1))
    assert alice.delete(f"/api/v1/rides/{rid}", headers=CLIENT).status_code == 200
    assert alice.delete(f"/api/v1/rides/{rid}", headers=CLIENT).status_code == 404
