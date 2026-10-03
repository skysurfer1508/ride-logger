"""One-sample speed spikes (app/geo.py despike): a speed worked out from two fixes whose times were rounded down to the second doubles for one fix when the real gap is 1.99 s
and the stamps say 1 s. Real ride 11 had ten of them and a 134 km/h top speed on a ride that never went faster than 83. Rides are measured without them."""
import pytest

from app import cli, geo, track
from conftest import ALICE, add_ride
from test_track import insert_points
from trackgen import make_rows


def test_a_single_sample_spike_up_or_down_is_smoothed():
    assert geo.despike([17.0, 17.5, 37.3, 18.0, 18.2]) == [17.0, 17.5, pytest.approx(17.75), 18.0, 18.2]
    assert geo.despike([17.0, 17.5, 8.0, 17.8, 18.0])[2] == pytest.approx(17.65)


def test_real_changes_of_speed_are_left_alone():
    steady_climb = [10.0, 12.0, 14.0, 16.0, 18.0]
    assert geo.despike(steady_climb) == steady_climb
    hard_braking = [25.0, 24.0, 10.0, 9.0, 8.0]                          # the neighbours of the drop disagree: it is a change, not a glitch
    assert geo.despike(hard_braking) == hard_braking
    a_quick_peak = [15.0, 30.0, 31.0, 15.0]                              # lasts two samples
    assert geo.despike(a_quick_peak) == a_quick_peak


def test_the_ends_and_missing_speeds_are_not_touched():
    assert geo.despike([40.0, 10.0, 10.0]) == [40.0, 10.0, 10.0]
    assert geo.despike([10.0, 10.0, 40.0]) == [10.0, 10.0, 40.0]
    assert geo.despike([10.0, None, 40.0, 10.0]) == [10.0, None, 40.0, 10.0]
    assert geo.despike([]) == [] and geo.despike([5.0]) == [5.0]


def points_with(speeds):
    return [{"speed": s} for s in speeds]


def test_the_top_speed_of_a_ride_ignores_a_spike_but_not_a_real_peak():
    assert geo.max_speed_mps(points_with([17.0, 17.5, 37.3, 18.0, 18.2, 22.0, 23.0, 22.5])) == 23.0
    assert geo.max_speed_mps(points_with([17.0, 36.0, 37.0, 18.0])) == 37.0
    assert geo.max_speed_mps(points_with([-1.0, None, -1.0])) == 0.0
    assert geo.max_speed_mps([]) == 0.0


def spiky_rows():
    rows = make_rows([("drive", 60, 12)])
    rows[15]["speed"] = 36.0
    return rows


def test_the_map_track_shows_neither_the_spike_nor_a_top_speed_there():
    result = track.build_track(spiky_rows())
    assert result["max_speed"]["mps"] == 12.0
    assert max(p[3] for p in result["points"]) == pytest.approx(12.0)


def test_a_ride_already_stored_with_a_spiky_top_speed_is_corrected_and_nothing_else_changes(alice):
    ride_id = add_ride(ALICE["sub"], "2026-10-03T13:15:06+00:00", distance_m=720, duration_s=60, max_mps=36.0, points=60)
    other = add_ride(ALICE["sub"], "2026-10-02T13:15:06+00:00", distance_m=720, duration_s=60, max_mps=12.0, points=60)
    insert_points(ALICE["sub"], ride_id, spiky_rows())
    insert_points(ALICE["sub"], other, make_rows([("drive", 60, 12)]))
    changed = cli.recompute_max_speeds()
    assert [(i, round(new, 1)) for i, _, new in changed] == [(ride_id, 12.0)]
    from app.db import get_db
    conn = get_db()
    try:
        assert conn.execute("SELECT max_speed_mps FROM rides WHERE id = ?", (ride_id,)).fetchone()[0] == pytest.approx(12.0)
        assert conn.execute("SELECT max_speed_mps FROM rides WHERE id = ?", (other,)).fetchone()[0] == pytest.approx(12.0)
        assert conn.execute("SELECT COUNT(*) FROM rides").fetchone()[0] == 2
    finally:
        conn.close()
    assert cli.recompute_max_speeds() == []
