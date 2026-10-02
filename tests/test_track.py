"""app/track.py (stop detection, the full track) and GET /api/v1/rides/{id}/track."""
import json
import pytest

from app import track
from app.db import get_db
from conftest import ALICE, BOB, add_ride
from trackgen import make_rows

CLIENT = {"X-RideLog-Client": "1"}
RED_LIGHT = [("drive", 60, 12), ("stop", 30, "zero"), ("drive", 60, 12)]


def stops_of(segments, **kw):
    return track.build_track(make_rows(segments, **kw))["stops"]


# ------------------------------------------------------------------ stop detection --

def test_a_red_light_with_zero_speed_fixes_is_one_stop():
    (stop,) = stops_of(RED_LIGHT)
    assert stop["duration_s"] == pytest.approx(30, abs=4)
    assert stop["t_start"] == pytest.approx(60, abs=4)
    assert stop["kind"] == "unknown" and stop["label"] == "Stop"
    assert stop["dist_from_start_m"] == pytest.approx(720, abs=30)         # 60 s at 12 m/s


def test_a_stop_with_no_fixes_at_all_is_found_too():
    """The iOS recorder's distance filter: standing still produces no fixes, only a gap between two nearby ones."""
    (stop,) = stops_of([("drive", 60, 12), ("stop", 40, "gap"), ("drive", 60, 12)])
    assert stop["duration_s"] == pytest.approx(40, abs=4)
    assert stop["t_start"] == pytest.approx(60, abs=4)


def test_gps_jitter_while_standing_does_not_split_or_hide_the_stop():
    stops = stops_of(RED_LIGHT, jitter_m=4.0, seed=7)
    assert len(stops) == 1 and stops[0]["duration_s"] == pytest.approx(30, abs=6)


def test_two_waits_with_a_creep_between_are_two_stops():
    segments = [("drive", 40, 12), ("stop", 20, "zero"), ("creep", 6, 2), ("stop", 20, "zero"), ("drive", 40, 12)]
    assert len(stops_of(segments)) == 2


def test_a_short_lurch_does_not_end_a_stop():
    segments = [("drive", 40, 12), ("stop", 14, "zero"), ("creep", 2, 2), ("stop", 14, "zero"), ("drive", 40, 12)]
    (stop,) = stops_of(segments)
    assert stop["duration_s"] == pytest.approx(28, abs=1)          # one stop spanning both halves, not 12 s + 12 s


def test_slow_traffic_is_not_a_stop():
    assert stops_of([("drive", 30, 12), ("creep", 90, 2), ("drive", 30, 12)]) == []


def test_a_five_second_pause_is_not_a_stop():
    assert stops_of([("drive", 40, 12), ("stop", 5, "gap"), ("drive", 40, 12)]) == []
    assert stops_of([("drive", 40, 12), ("stop", 6, "zero"), ("drive", 40, 12)]) == []


def test_getting_going_and_parking_are_not_stops():
    assert stops_of([("stop", 20, "zero"), ("drive", 60, 12), ("stop", 20, "zero")]) == []


def test_a_wait_right_after_pressing_start_is_not_a_stop_even_if_the_first_fix_has_a_stale_speed():
    rows = make_rows([("stop", 24, "zero"), ("drive", 60, 12), ("stop", 20, "zero"), ("drive", 60, 12)])
    rows[0]["speed"] = 4.3                                     # the real ride's first fix: speed left over from before the phone settled
    stops = track.build_track(rows)["stops"]
    assert len(stops) == 1 and stops[0]["dist_from_start_m"] > 600     # only the light 60 s later


def test_a_wait_just_before_the_end_is_parking_not_a_stop():
    assert stops_of([("drive", 60, 12), ("stop", 20, "zero"), ("drive", 1, 5)]) == []


def test_stops_are_found_when_the_speed_is_unknown_by_working_it_out_from_the_fixes():
    (stop,) = stops_of(RED_LIGHT, unknown_speed=True)
    assert stop["duration_s"] == pytest.approx(30, abs=4)


def test_several_lights_in_one_ride():
    segments = [("drive", 30, 12), ("stop", 25, "gap"), ("drive", 30, 12), ("stop", 45, "zero"), ("drive", 30, 12),
                ("stop", 12, "zero"), ("drive", 30, 12)]
    stops = stops_of(segments)
    assert len(stops) == 3
    assert [s["duration_s"] for s in stops] == pytest.approx([25, 44, 12], abs=4)
    result = track.build_track(make_rows(segments))
    assert result["stopped_s"] == pytest.approx(sum(s["duration_s"] for s in result["stops"]))


# -------------------------------------------------------------------------- the track --

def test_the_track_has_time_position_speed_and_distance_per_point():
    result = track.build_track(make_rows(RED_LIGHT))
    first, last = result["points"][0], result["points"][-1]
    assert first[0] == 0 and first[5] == 0
    assert last[0] == result["duration_s"] and last[5] == result["distance_m"]
    assert result["distance_m"] == pytest.approx(60 * 12 * 2, abs=30)                      # 120 s of driving at 12 m/s
    assert result["start"].startswith("2026-09-30T08:00:00")
    assert [p[0] for p in result["points"]] == sorted(p[0] for p in result["points"])
    assert max(p[3] for p in result["points"]) == pytest.approx(12.0)


def test_the_top_speed_is_the_highest_reported_speed_and_says_where():
    rows = make_rows([("drive", 30, 10), ("drive", 6, 31), ("drive", 30, 10)])
    top = track.build_track(rows)["max_speed"]
    assert top["mps"] == 31.0
    assert top["t"] == pytest.approx(32, abs=2)
    assert 47.37 < top["lat"] < 47.40


def test_unknown_speed_is_replaced_by_the_speed_between_neighbours():
    pts = track.build_track(make_rows([("drive", 40, 12)], unknown_speed=True))["points"]
    assert all(p[3] == pytest.approx(12.0, abs=0.3) for p in pts[1:-1])
    assert track.build_track(make_rows([("drive", 40, 12)], unknown_speed=True))["max_speed"] is None      # none was reported


def test_poor_fixes_and_duplicate_timestamps_are_left_out_like_in_the_ride_stats():
    rows = make_rows([("drive", 60, 12)])
    rows[5]["horizontal_accuracy"] = 90.0                       # too inaccurate: the stats ignore it, so does the map
    rows.insert(8, dict(rows[7], id=999))                       # a duplicate of an earlier fix
    result = track.build_track(rows)
    assert result["point_count"] == len(rows) - 2


def test_a_long_ride_is_thinned_but_keeps_what_matters():
    segments = [("drive", 4000, 14), ("stop", 60, "zero"), ("drive", 2000, 30), ("drive", 4, 41), ("drive", 6000, 14)]
    rows = make_rows(segments, step=1.0)
    assert len(rows) > track.MAX_TRACK_POINTS
    full = track.build_track(rows[:])
    assert len(full["points"]) <= track.MAX_TRACK_POINTS + 10
    assert full["point_count"] == len(rows)
    assert full["points"][0][0] == 0 and full["points"][-1][0] == full["duration_s"]
    assert full["max_speed"]["mps"] == 41.0 and any(p[3] == 41.0 for p in full["points"])
    (stop,) = full["stops"]
    times = {p[0] for p in full["points"]}
    assert any(abs(t - stop["t_start"]) <= 1 for t in times) and any(abs(t - stop["t_end"]) <= 1 for t in times)
    assert full["distance_m"] == pytest.approx(4000 * 14 + 2000 * 30 + 4 * 41 + 6000 * 14, rel=0.01)


def test_no_points_and_a_single_point_are_not_errors():
    assert track.build_track([])["points"] == []
    assert track.build_track(make_rows([]))["stops"] == []
    assert track.build_track([])["max_speed"] is None


# ----------------------------------------------------------------------------- the API --

def insert_points(owner_sub: str, ride_id: int, rows: list[dict]) -> None:
    conn = get_db()
    try:
        for r in rows:
            raw = {k: r[k] for k in ("course", "course_accuracy") if r.get(k) is not None}         # what the app's uploads carry beyond the columns
            conn.execute(
                """INSERT INTO points (owner_sub, device_id, lat, lon, timestamp, speed, altitude, horizontal_accuracy, ride_id, raw_properties)
                   VALUES (?, 'dev', ?, ?, ?, ?, ?, ?, ?, ?)""",
                (owner_sub, r["lat"], r["lon"], r["timestamp"], r["speed"], r["altitude"], r["horizontal_accuracy"], ride_id, json.dumps(raw)),
            )
        conn.commit()
    finally:
        conn.close()


def test_the_track_endpoint_returns_the_points_the_ride_was_built_from(alice):
    rid = add_ride(ALICE["sub"], "2026-09-30T08:00:00+00:00")
    insert_points(ALICE["sub"], rid, make_rows(RED_LIGHT))
    r = alice.get(f"/api/v1/rides/{rid}/track")
    assert r.status_code == 200
    body = r.json()
    assert body["api"] == 1 and body["ride"]["id"] == rid
    assert len(body["points"]) == body["point_count"] > 50
    assert len(body["stops"]) == 1 and body["max_speed"]["mps"] == 12.0
    assert r.headers["cache-control"] == "no-store"


def test_a_ride_without_points_gives_an_empty_track_not_an_error(alice):
    rid = add_ride(ALICE["sub"], "2026-09-30T08:00:00+00:00")
    body = alice.get(f"/api/v1/rides/{rid}/track").json()
    assert body["points"] == [] and body["stops"] == [] and body["max_speed"] is None


def test_someone_elses_track_is_the_same_404_as_a_missing_ride(alice, bob):
    theirs = add_ride(BOB["sub"], "2026-09-30T08:00:00+00:00")
    insert_points(BOB["sub"], theirs, make_rows(RED_LIGHT))
    other = alice.get(f"/api/v1/rides/{theirs}/track")
    missing = alice.get("/api/v1/rides/99999/track")
    assert other.status_code == missing.status_code == 404
    assert other.json() == missing.json() == {"detail": "ride_not_found"}
    assert bob.get(f"/api/v1/rides/{theirs}/track").status_code == 200


def test_the_track_needs_a_login(anon):
    assert anon.get("/api/v1/rides/1/track").status_code == 401


def test_points_of_another_ride_never_leak_into_a_track(alice):
    a = add_ride(ALICE["sub"], "2026-09-30T08:00:00+00:00")
    b = add_ride(ALICE["sub"], "2026-09-30T12:00:00+00:00")
    insert_points(ALICE["sub"], a, make_rows(RED_LIGHT))
    insert_points(ALICE["sub"], b, make_rows([("drive", 20, 5)]))
    assert alice.get(f"/api/v1/rides/{b}/track").json()["point_count"] == 11
