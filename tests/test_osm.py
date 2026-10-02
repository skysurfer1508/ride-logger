"""app/osm.py (tile cache, Overpass client behaviour) and app/track.classify_stop. The network is always faked."""
import threading
import time

import pytest

from app import osm, track
from app.config import settings
from app.db import get_db
from conftest import ALICE
from conftest import add_ride
from test_track import RED_LIGHT, insert_points
from trackgen import LAT0, LON0, M_PER_DEG_LAT, make_rows

M_PER_DEG_LON = M_PER_DEG_LAT * 0.6757     # cos(47.38 deg)


def node(osm_id, lat, lon, **tags):
    return {"type": "node", "id": osm_id, "lat": lat, "lon": lon, "tags": tags}


def north_of_start(metres):
    return LAT0 + metres / M_PER_DEG_LAT


@pytest.fixture(autouse=True)
def osm_on(monkeypatch):
    monkeypatch.setattr(settings, "osm_enabled", True)
    monkeypatch.setattr(settings, "overpass_urls", "https://one.example/api,https://two.example/api")
    monkeypatch.setattr(osm, "_backoff_until", 0.0)
    monkeypatch.setattr(osm, "_failed_until", {})


class FakeOverpass:
    """Stands in for osm._post: records calls, answers with `elements` unless told to fail."""

    def __init__(self, elements=None):
        self.elements = elements or []
        self.calls: list[tuple[str, str]] = []
        self.fail_urls: set[str] = set()
        self.busy_urls: set[str] = set()

    def __call__(self, url, query):
        self.calls.append((url, query))
        if url in self.busy_urls:
            raise osm.OverpassBusy(url)
        if url in self.fail_urls:
            raise RuntimeError("down")
        return {"elements": self.elements}


@pytest.fixture
def overpass(monkeypatch):
    fake = FakeOverpass()
    monkeypatch.setattr(osm, "_post", fake)
    return fake


def a_stop(lat=LAT0, lon=LON0, heading=0):
    return {"lat": lat, "lon": lon, "heading_deg": heading, "kind": "unknown", "label": "Stop"}


def classify(stop, *features):
    return track.classify_stop(stop, [dict(zip(("kind", "lat", "lon"), f)) for f in features])


# ------------------------------------------------------------------ choosing the cause --

def test_a_signal_just_ahead_means_a_traffic_light():
    stop = classify(a_stop(), ("traffic_light", north_of_start(12), LON0))
    assert (stop["kind"], stop["label"]) == ("traffic_light", "Traffic light")


def test_a_signal_too_far_away_is_not_why_the_rider_stopped():
    assert classify(a_stop(), ("traffic_light", north_of_start(60), LON0))["kind"] == "other"


def test_the_label_for_traffic_is_traffic_or_other():
    assert classify(a_stop())["label"] == "Traffic / other"


def test_each_kind_of_feature_gets_its_label():
    for kind, label in [("stop_sign", "Stop sign"), ("rail_crossing", "Level crossing"), ("give_way", "Give way")]:
        assert classify(a_stop(), (kind, north_of_start(10), LON0))["label"] == label


def test_a_feature_ahead_beats_a_slightly_nearer_one_behind():
    behind = ("stop_sign", north_of_start(-10), LON0)          # 10 m behind a bike heading north
    ahead = ("traffic_light", north_of_start(20), LON0)        # 20 m ahead: 20 < 10 + 15
    assert classify(a_stop(heading=0), behind, ahead)["kind"] == "traffic_light"


def test_a_much_nearer_feature_behind_still_wins_over_a_far_one_ahead():
    behind = ("stop_sign", north_of_start(-3), LON0)
    ahead = ("traffic_light", north_of_start(30), LON0)
    assert classify(a_stop(heading=0), behind, ahead)["kind"] == "stop_sign"


def test_without_a_heading_the_nearest_wins():
    stop = classify(a_stop(heading=None), ("stop_sign", north_of_start(-10), LON0), ("traffic_light", north_of_start(20), LON0))
    assert stop["kind"] == "stop_sign"


def test_the_travel_direction_comes_from_the_track():
    stop = track.build_track(make_rows(RED_LIGHT))["stops"][0]
    assert stop["heading_deg"] in (0, 360)                     # the synthetic rider drives due north


# ------------------------------------------------------------------------ parsing --

def test_only_the_wanted_nodes_become_features():
    data = {"elements": [
        node(1, 47.0, 8.0, highway="traffic_signals", **{"traffic_signals:direction": "forward"}),
        node(2, 47.0, 8.0, highway="stop"),
        node(3, 47.0, 8.0, highway="give_way"),
        node(4, 47.0, 8.0, railway="level_crossing"),
        node(5, 47.0, 8.0, highway="crossing", crossing="traffic_signals"),
        node(6, 47.0, 8.0, highway="crossing", crossing="zebra"),         # an unlit zebra crossing: not matched
        node(7, 47.0, 8.0, highway="bus_stop"),
        {"type": "way", "id": 8, "tags": {"highway": "traffic_signals"}},
        {"type": "node", "id": 9, "tags": {"highway": "stop"}},           # no position
    ]}
    got = osm.parse_elements(data)
    assert [(f["osm_id"], f["kind"]) for f in got] == [(1, "traffic_light"), (2, "stop_sign"), (3, "give_way"), (4, "rail_crossing"), (5, "traffic_light")]
    assert got[0]["direction"] == "forward"


def test_the_query_asks_for_the_tile_and_the_right_tags():
    q = osm.build_query(osm.tile_id(LAT0, LON0))
    assert "traffic_signals|stop|give_way" in q and "level_crossing" in q and "out;" in q
    s, w, n, e = osm.tile_bbox(osm.tile_id(LAT0, LON0))
    assert s <= LAT0 <= n and w <= LON0 <= e and round(n - s, 6) == osm.TILE_DEG
    assert f"{s:.4f},{w:.4f},{n:.4f},{e:.4f}" in q


def test_tiles_for_a_point_near_an_edge_include_the_neighbour():
    inside = osm.tiles_around(47.3775, 8.5225)
    assert len(inside) == 1
    edge_lat = 47.4 - 0.0002                                   # just south of a tile boundary (47.40 = 948 * 0.05)
    assert len(osm.tiles_around(edge_lat, 8.5225)) == 2


# ------------------------------------------------------------------ cache and network --

def test_the_stop_is_matched_and_the_tile_is_cached(overpass):
    overpass.elements = [node(11, north_of_start(15), LON0, highway="traffic_signals")]
    conn = get_db()
    stops = [a_stop()]
    assert osm.classify_stops(conn, stops) == "ok"
    assert stops[0]["kind"] == "traffic_light"
    first_calls = len(overpass.calls)
    again = [a_stop()]
    assert osm.classify_stops(conn, again) == "ok" and again[0]["kind"] == "traffic_light"
    assert len(overpass.calls) == first_calls                  # second time: from the cache, no request
    conn.close()


def test_an_old_tile_is_fetched_again_and_replaced(overpass):
    overpass.elements = [node(11, north_of_start(15), LON0, highway="traffic_signals")]
    conn = get_db()
    osm.classify_stops(conn, [a_stop()])
    conn.execute("UPDATE osm_tiles SET fetched_at = '2020-01-01T00:00:00+00:00'")
    conn.commit()
    overpass.elements = [node(12, north_of_start(15), LON0, highway="stop")]                 # the map changed meanwhile
    stops = [a_stop()]
    osm.classify_stops(conn, stops)
    assert stops[0]["kind"] == "stop_sign"
    assert conn.execute("SELECT COUNT(*) FROM osm_features").fetchone()[0] == 1              # replaced, not piled up
    conn.close()


def test_when_overpass_is_down_the_stop_stays_a_plain_stop(overpass):
    overpass.fail_urls = {"https://one.example/api", "https://two.example/api"}
    conn = get_db()
    stops = [a_stop()]
    assert osm.classify_stops(conn, stops) == "unavailable"
    assert (stops[0]["kind"], stops[0]["label"]) == ("unknown", "Stop")
    assert conn.execute("SELECT COUNT(*) FROM osm_tiles").fetchone()[0] == 0                 # a failed tile is not remembered as fetched
    conn.close()


def test_a_failed_tile_is_tried_again_after_the_pause(overpass, monkeypatch):
    overpass.fail_urls = {"https://one.example/api", "https://two.example/api"}
    conn = get_db()
    osm.classify_stops(conn, [a_stop()])
    n = len(overpass.calls)
    osm.classify_stops(conn, [a_stop()])
    assert len(overpass.calls) == n                            # still inside the 60 s pause: nothing is asked again
    monkeypatch.setattr(osm, "_failed_until", {})
    overpass.fail_urls = set()
    overpass.elements = [node(1, north_of_start(10), LON0, highway="traffic_signals")]
    stops = [a_stop()]
    assert osm.classify_stops(conn, stops) == "ok" and stops[0]["kind"] == "traffic_light"
    conn.close()


def test_the_second_server_is_the_fallback(overpass):
    overpass.fail_urls = {"https://one.example/api"}
    overpass.elements = [node(1, north_of_start(10), LON0, highway="stop")]
    conn = get_db()
    stops = [a_stop()]
    assert osm.classify_stops(conn, stops) == "ok" and stops[0]["kind"] == "stop_sign"
    assert [u for u, _ in overpass.calls] == ["https://one.example/api", "https://two.example/api"]
    conn.close()


def test_too_many_requests_makes_us_back_off_for_a_while(overpass):
    overpass.busy_urls = {"https://one.example/api", "https://two.example/api"}
    conn = get_db()
    assert osm.classify_stops(conn, [a_stop()]) == "unavailable"
    assert osm._backoff_until > time.monotonic() + 20
    n = len(overpass.calls)
    other_tile = a_stop(lat=LAT0 + 0.2)
    assert osm.classify_stops(conn, [other_tile]) == "unavailable"
    assert len(overpass.calls) == n                            # during the 30 s pause no other tile is asked for either
    conn.close()


def test_old_data_is_used_when_a_refresh_is_not_possible(overpass):
    overpass.elements = [node(1, north_of_start(10), LON0, highway="traffic_signals")]
    conn = get_db()
    osm.classify_stops(conn, [a_stop()])
    conn.execute("UPDATE osm_tiles SET fetched_at = '2020-01-01T00:00:00+00:00'")
    conn.commit()
    overpass.fail_urls = {"https://one.example/api", "https://two.example/api"}
    stops = [a_stop()]
    assert osm.classify_stops(conn, stops) == "ok" and stops[0]["kind"] == "traffic_light"   # stale beats nothing
    conn.close()


def test_a_stop_near_a_tile_edge_asks_for_both_tiles_and_sees_signals_in_either(overpass):
    edge_lat = 47.4 - 0.0002
    overpass.elements = [node(1, 47.4 + 0.0001, LON0, highway="traffic_signals")]
    conn = get_db()
    stops = [a_stop(lat=edge_lat, lon=8.5225, heading=0)]
    assert osm.classify_stops(conn, stops) == "ok"
    assert len(overpass.calls) == 2
    conn.close()


def test_requests_are_made_one_at_a_time(monkeypatch):
    running, peak = 0, 0
    guard = threading.Lock()

    def slow(url, query):
        nonlocal running, peak
        with guard:
            running += 1
            peak = max(peak, running)
        time.sleep(0.05)
        with guard:
            running -= 1
        return {"elements": []}

    monkeypatch.setattr(osm, "_post", slow)

    def work(lat):
        conn = get_db()
        try:
            osm.classify_stops(conn, [a_stop(lat=lat)])
        finally:
            conn.close()

    threads = [threading.Thread(target=work, args=(LAT0 + 0.1 * i,)) for i in range(4)]
    [t.start() for t in threads]
    [t.join() for t in threads]
    assert peak == 1


def test_a_server_that_answers_with_a_runtime_error_remark_counts_as_failed(monkeypatch):
    class Response:
        status_code = 200
        def json(self): return {"remark": "runtime error: Query timed out", "elements": []}
    monkeypatch.setattr(osm.httpx, "post", lambda *a, **k: Response())
    with pytest.raises(RuntimeError):
        osm._post("https://one.example/api", "q")


def test_the_user_agent_identifies_the_app(monkeypatch):
    seen = {}

    class Response:
        status_code = 200
        def json(self): return {"elements": []}

    def fake_post(url, data=None, headers=None, timeout=None):
        seen.update(headers=headers, data=data)
        return Response()

    monkeypatch.setattr(osm.httpx, "post", fake_post)
    monkeypatch.setattr(settings, "osm_user_agent", "ride-logger/1.0 (me@example.com)")
    osm._post("https://one.example/api", "the query")
    assert seen["headers"]["User-Agent"] == "ride-logger/1.0 (me@example.com)" and seen["data"] == {"data": "the query"}


def test_nothing_is_fetched_when_the_lookup_is_switched_off(overpass, monkeypatch):
    monkeypatch.setattr(settings, "osm_enabled", False)
    conn = get_db()
    stops = [a_stop()]
    assert osm.classify_stops(conn, stops) == "disabled" and stops[0]["kind"] == "unknown" and overpass.calls == []
    conn.close()


def test_a_ride_without_stops_needs_no_lookup(overpass):
    conn = get_db()
    assert osm.classify_stops(conn, []) == "ok" and overpass.calls == []
    conn.close()


# ------------------------------------------------------------------------ the endpoint --

def test_the_track_endpoint_labels_a_light_and_credits_the_status(alice, overpass):
    rid = add_ride(ALICE["sub"], "2026-09-30T08:00:00+00:00")
    insert_points(ALICE["sub"], rid, make_rows(RED_LIGHT))
    overpass.elements = [node(5, north_of_start(740), LON0, highway="traffic_signals")]      # just ahead of where the synthetic rider waits (720 m)
    body = alice.get(f"/api/v1/rides/{rid}/track").json()
    assert body["features_status"] == "ok"
    assert body["stops"][0]["kind"] == "traffic_light" and body["stops"][0]["label"] == "Traffic light"


def test_the_track_endpoint_still_works_when_overpass_is_down(alice, overpass):
    overpass.fail_urls = {"https://one.example/api", "https://two.example/api"}
    rid = add_ride(ALICE["sub"], "2026-09-30T08:00:00+00:00")
    insert_points(ALICE["sub"], rid, make_rows(RED_LIGHT))
    r = alice.get(f"/api/v1/rides/{rid}/track")
    assert r.status_code == 200
    body = r.json()
    assert body["features_status"] == "unavailable" and body["stops"][0]["label"] == "Stop" and len(body["points"]) > 50


def test_a_queue_far_from_any_signal_is_traffic(alice, overpass):
    rid = add_ride(ALICE["sub"], "2026-09-30T08:00:00+00:00")
    insert_points(ALICE["sub"], rid, make_rows(RED_LIGHT))
    overpass.elements = [node(5, north_of_start(900), LON0, highway="traffic_signals")]      # 180 m past the stop
    assert alice.get(f"/api/v1/rides/{rid}/track").json()["stops"][0]["label"] == "Traffic / other"
