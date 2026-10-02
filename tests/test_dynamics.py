"""Lean angle and G-force estimated from GPS (app/dynamics.py). The expected numbers are physics: a bike at speed v on a corner of radius r leans atan(v^2 / (r g)).
The tolerances come from running the same synthetic rides many times with realistic GPS error (see the module's docstring for what the method cannot see)."""
import math
import statistics

import pytest

from app import dynamics, track
from conftest import ALICE, add_ride
from test_track import insert_points
from trackgen import make_path_rows


def prepared(rows):
    points = track._prepare(rows)
    track._fill_speeds(points)
    return points


def expected_lean(v, r):
    return math.degrees(math.atan(v * v / (r * 9.80665)))


@pytest.mark.parametrize("v,r", [(10, 30), (15, 60), (20, 100), (25, 150)])
@pytest.mark.parametrize("course", [0.0, None])
def test_a_clean_circle_gives_the_textbook_lean(v, r, course):
    rows = make_path_rows([("straight", 300), ("turn", r, 1080), ("straight", 300)], v, course_sigma=course)
    result = dynamics.analyze(prepared(rows))
    assert result["source"] == ("course" if course is not None else "positions")
    assert result["max_right_deg"] == pytest.approx(expected_lean(v, r), abs=1.5)
    assert result["max_left_deg"] == 0


def test_left_and_right_are_told_apart():
    right = dynamics.analyze(prepared(make_path_rows([("straight", 600), ("turn", 50, 90), ("straight", 600)], 14, course_sigma=1.0)))
    left = dynamics.analyze(prepared(make_path_rows([("straight", 600), ("turn", 50, -90), ("straight", 600)], 14, course_sigma=1.0)))
    assert right["max_right_deg"] > 15 and right["max_left_deg"] == 0 and right["corners"][0]["direction"] == "right"
    assert left["max_left_deg"] > 15 and left["max_right_deg"] == 0 and left["corners"][0]["direction"] == "left"
    assert right["series"][0][1] <= 3 and max(row[1] for row in right["series"]) > 15 and min(row[1] for row in left["series"]) < -15     # signed: right is positive


@pytest.mark.parametrize("course_sigma,pos_sigma", [(2.0, 3.0), (4.0, 3.0), (None, 2.0), (None, 3.0), (None, 5.0)])
@pytest.mark.parametrize("speed", [10, 20, 30])
def test_a_straight_road_is_never_a_corner_however_noisy_the_gps(speed, course_sigma, pos_sigma):
    """At 100 km/h a 3 m position error alone makes single fixes read up to ~20 degrees; none of it may become a corner or a 'max lean'."""
    for seed in range(12):
        result = dynamics.analyze(prepared(make_path_rows([("straight", 2500)], speed, pos_sigma=pos_sigma, course_sigma=course_sigma, seed=seed)))
        assert result["corner_count"] == 0 and result["max_left_deg"] == 0 and result["max_right_deg"] == 0 and result["best_corner"] is None


def test_a_short_corner_is_found_with_a_sensible_lean_under_gps_noise():
    """Straight, a 90 degree turn of radius 40 m at 43 km/h (about 5 s long), straight: expected lean 20."""
    for course_sigma, tolerance, at_least in [(2.0, 4, 15), (None, 6, 9)]:          # from positions only a tight 5 s corner is sometimes missed (measured: about 1 in 4), never invented
        peaks = []
        for seed in range(15):
            result = dynamics.analyze(prepared(make_path_rows([("straight", 600), ("turn", 40, 90), ("straight", 600)], 12, pos_sigma=3.0, course_sigma=course_sigma, seed=seed)))
            assert result["corner_count"] <= 1
            if result["corner_count"]:
                peaks.append(result["max_right_deg"])
        assert len(peaks) >= at_least
        assert statistics.median(peaks) == pytest.approx(expected_lean(12, 40), abs=tolerance)


def test_a_corner_reports_where_how_fast_and_how_long():
    rows = make_path_rows([("straight", 600), ("turn", 50, 90), ("straight", 600)], 14, course_sigma=1.0)
    corner = dynamics.analyze(prepared(rows))["best_corner"]
    assert corner["direction"] == "right" and 3.0 <= corner["t_end"] - corner["t_start"] <= 7.0
    assert corner["entry_kmh"] == corner["apex_kmh"] == corner["exit_kmh"] == 50
    assert 45 <= corner["length_m"] <= 90 and 590 <= corner["dist_m"] <= 630               # the stretch leaned past 12 degrees, a bit shorter than the 79 m arc
    assert corner["peak_lean"] == pytest.approx(expected_lean(14, 50), abs=2) and corner["peak_g"] == pytest.approx(14 ** 2 / 50 / 9.80665, abs=0.05)
    assert corner["t_start"] <= corner["t_apex"] <= corner["t_end"] and 47.38 < corner["lat"] < 47.39 and 8.54 < corner["lon"] < 8.55


def test_an_s_bend_is_two_corners_one_each_way():
    result = dynamics.analyze(prepared(make_path_rows([("straight", 600), ("turn", 50, 90), ("turn", 50, -90), ("straight", 600)], 14, pos_sigma=2.0, course_sigma=2.0, seed=3)))
    assert [c["direction"] for c in sorted(result["corners"], key=lambda c: c["t_start"])] == ["right", "left"]
    assert result["best_corner"] == max(result["corners"], key=lambda c: c["peak_lean"])


def test_a_gentle_bend_below_the_corner_threshold_is_not_a_corner():
    result = dynamics.analyze(prepared(make_path_rows([("straight", 600), ("turn", 400, 40), ("straight", 600)], 20, course_sigma=1.0)))      # about 6 degrees
    assert result["corner_count"] == 0 and result["max_right_deg"] == 0


def test_slow_riding_has_no_lean():
    result = dynamics.analyze(prepared(make_path_rows([("straight", 600), ("turn", 10, 720), ("straight", 400)], 4, course_sigma=1.0)) + [])
    assert result is None or result["corner_count"] == 0


def test_forward_and_backward_g_come_from_the_change_in_speed():
    rows = make_path_rows([("straight", 3000)], 20)
    for i, row in enumerate(rows):
        row["speed"] = 10.0 + 0.5 * i if i < 30 else 25.0 - 0.8 * (i - 30) if i < 40 else 17.0           # +0.5 m/s2, then -0.8 m/s2, then steady
    points = prepared(rows)
    for p in points:
        p["course"] = 0.0
    result = dynamics.analyze(points)
    assert result["max_accel_g"] == pytest.approx(0.5 / 9.80665, abs=0.02)
    assert result["max_braking_g"] == pytest.approx(0.8 / 9.80665, abs=0.03)


def test_a_course_the_phone_calls_unreliable_is_not_used():
    rows = make_path_rows([("straight", 300), ("turn", 100, 720), ("straight", 300)], 20, course_sigma=1.0)
    for row in rows:
        row["course_accuracy"] = 90.0                       # the phone says it has no idea
    assert dynamics.analyze(prepared(rows))["source"] == "positions"
    for row in rows:
        row["course"], row["course_accuracy"] = -1.0, -1.0     # CoreLocation's "invalid"
    assert dynamics.analyze(prepared(rows))["source"] == "positions"


def test_a_ride_with_course_on_only_some_fixes_uses_positions_unless_nearly_all_have_it():
    rows = make_path_rows([("straight", 300), ("turn", 100, 720), ("straight", 300)], 20, course_sigma=1.0)
    some = [dict(r, course=None, course_accuracy=None) if i % 3 else r for i, r in enumerate(rows)]
    assert dynamics.analyze(prepared(some))["source"] == "positions"
    most = [dict(r, course=None, course_accuracy=None) if i % 25 == 0 else r for i, r in enumerate(rows)]
    result = dynamics.analyze(prepared(most))
    assert result["source"] == "course" and result["max_right_deg"] == pytest.approx(expected_lean(20, 100), abs=2)


def test_a_gap_in_the_fixes_is_not_differentiated_across():
    rows = make_path_rows([("straight", 600), ("turn", 50, 90), ("straight", 600)], 14, course_sigma=1.0)
    around_the_corner = [r for i, r in enumerate(rows) if not 52 <= i <= 62]
    # the track now jumps ahead by ~150 m at the corner with no fixes in between: nothing in there is measured, and nothing is invented
    result = dynamics.analyze(prepared(around_the_corner))
    assert result["corner_count"] == 0 or result["max_right_deg"] < 40


def test_short_or_tiny_rides_say_nothing():
    assert dynamics.analyze(prepared(make_path_rows([("straight", 300)], 14))) is None                          # under 1 km
    assert dynamics.analyze([]) is None
    assert dynamics.analyze(prepared(make_path_rows([("straight", 2000)], 3))) is None                         # never above 22 km/h


def test_the_chart_series_is_capped_but_keeps_the_peaks():
    rows = make_path_rows([("straight", 3000), ("turn", 50, 90), ("straight", 20000)], 14, course_sigma=1.0)
    result = dynamics.analyze(prepared(rows))
    assert len(result["series"]) <= dynamics.MAX_SERIES and len(rows) > 3 * dynamics.MAX_SERIES
    assert max(abs(row[1]) for row in result["series"]) == pytest.approx(expected_lean(14, 50), abs=2)
    assert all(len(row) == 5 for row in result["series"]) and [r[0] for r in result["series"]] == sorted(r[0] for r in result["series"])


# ------------------------------------------------------------------------------------------------------------------------------- the API --

def test_the_insights_endpoint_reads_the_phones_course_from_the_stored_points(alice):
    rid = add_ride(ALICE["sub"], "2026-09-30T08:00:00+00:00")
    insert_points(ALICE["sub"], rid, make_path_rows([("straight", 600), ("turn", 50, 90), ("straight", 600)], 14, course_sigma=1.0))
    body = alice.get(f"/api/v1/rides/{rid}/insights").json()
    assert body["dynamics"]["source"] == "course" and body["dynamics"]["corner_count"] == 1
    assert body["dynamics"]["max_right_deg"] == pytest.approx(expected_lean(14, 50), abs=2)


def test_rides_without_course_still_get_an_estimate_from_positions(alice):
    rid = add_ride(ALICE["sub"], "2026-09-30T08:00:00+00:00")
    insert_points(ALICE["sub"], rid, make_path_rows([("straight", 600), ("turn", 50, 90), ("straight", 600)], 14))
    body = alice.get(f"/api/v1/rides/{rid}/insights").json()
    assert body["dynamics"]["source"] == "positions" and body["dynamics"]["corner_count"] == 1


def test_a_short_ride_has_null_dynamics_and_the_rest_still_works(alice):
    rid = add_ride(ALICE["sub"], "2026-09-30T08:00:00+00:00")
    insert_points(ALICE["sub"], rid, make_path_rows([("straight", 300)], 14))
    body = alice.get(f"/api/v1/rides/{rid}/insights").json()
    assert body["dynamics"] is None and body["limits"]["status"] == "disabled"
