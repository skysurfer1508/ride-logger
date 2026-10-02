"""Route planning (app/planner.py, app/routers/api_planner.py, the route call in app/valhalla.py). Valhalla is faked with a router that joins the points with lines,
so the logic around it (where the waypoints go, how loops are scored and chosen, what the API says when things fail) is tested without a map."""
import json
import math
import xml.etree.ElementTree as ET

import pytest

from app import curvature, geo, gpx, planner, roads, valhalla
from app.config import settings
from app.db import get_db
from conftest import ALICE, BOB
from trackgen import LAT0, LON0, road_coords

CLIENT = {"X-RideLog-Client": "1"}
START = (LAT0, LON0)
TWISTY = [("straight", 150)] + [("turn", 60, 70 if i % 2 else -70) for i in range(18)] + [("straight", 150)]


# ----------------------------------------------------------------------------------------------------------------------------------- fakes --

def wiggle(a, b, twisty):
    """A road from a to b: straight, or snaking when `twisty`. (lat, lon) points about 15 m apart."""
    length = geo.haversine_m(a[0], a[1], b[0], b[1])
    n = max(2, round(length / 15.0))
    out = []
    for i in range(n + 1):
        f = i / n
        lat, lon = a[0] + (b[0] - a[0]) * f, a[1] + (b[1] - a[1]) * f
        if twisty:
            offset = 30.0 * math.sin(2 * math.pi * (f * length) / 200.0) / 111_194.9266
            lon += offset / math.cos(math.radians(lat))
        out.append((lat, lon))
    return out


class FakeRouter:
    """Stands in for valhalla.route: the road between two points is a line `factor` times longer than the straight one (more than the planner expects, so the first
    guess at a loop's size is about 17% too long and has to be corrected), and it snakes east of START's longitude + 0.05."""

    def __init__(self, monkeypatch):
        self.factor = 1.75
        self.same_shape = None
        self.calls = []
        self.fail_if = None
        self.unavailable = False
        monkeypatch.setattr(settings, "valhalla_url", "http://valhalla.invalid")
        monkeypatch.setattr(valhalla, "route", self.route)

    def route(self, locations, avoid_motorways=True, paved_only=True):
        self.calls.append({"locations": list(locations), "avoid_motorways": avoid_motorways, "paved_only": paved_only})
        if self.unavailable:
            raise valhalla.ValhallaUnavailable("down")
        if self.fail_if and self.fail_if(locations):
            raise valhalla.NoRoute("no way")
        if self.same_shape is not None:
            return self.same_shape
        pts = [(l["lat"], l["lon"]) for l in locations]
        shape = []
        for a, b in zip(pts, pts[1:]):
            part = wiggle(a, b, twisty=((a[1] + b[1]) / 2) > LON0 + 0.05)
            shape.extend(part[1:] if shape else part)
        straight = sum(geo.haversine_m(a[0], a[1], b[0], b[1]) for a, b in zip(pts, pts[1:]))
        return {"distance_m": straight * self.factor, "duration_s": straight * self.factor / 12.0, "shape": shape}


@pytest.fixture
def router(monkeypatch):
    return FakeRouter(monkeypatch)


@pytest.fixture
def road_conn(tmp_path, monkeypatch):
    conn = roads.create(tmp_path / "roads.db")
    roads.add_way(conn, 1, {"highway": "secondary", "name": "East twisty"}, road_coords(TWISTY, spacing=12, lat0=LAT0 + 0.02, lon0=LON0 + 0.10))
    roads.add_way(conn, 2, {"highway": "secondary", "name": "West twisty"}, road_coords(TWISTY, spacing=12, lat0=LAT0 - 0.03, lon0=LON0 - 0.12))
    roads.finish(conn, "test")
    monkeypatch.setattr(settings, "roads_db_path", str(tmp_path / "roads.db"))
    return roads.connect()


# ------------------------------------------------------------------------------------------------------------------------------- geometry --

def test_a_destination_is_where_the_bearing_and_distance_say():
    lat, lon = planner.destination(47.0, 8.0, 0, 1000)
    assert lat == pytest.approx(47.0 + 1000 / 111_194.9266, abs=1e-5) and lon == pytest.approx(8.0, abs=1e-9)
    lat, lon = planner.destination(47.0, 8.0, 90, 5000)
    assert geo.haversine_m(47.0, 8.0, lat, lon) == pytest.approx(5000, rel=1e-4) and lat == pytest.approx(47.0, abs=1e-3) and lon > 8.0


@pytest.mark.parametrize("rotation", [0, 45, 100, 270])
@pytest.mark.parametrize("clockwise", [True, False])
def test_the_waypoints_lie_on_a_circle_through_the_start(rotation, clockwise):
    target = 120_000
    points = planner.circle_waypoints(START, target, rotation, clockwise)
    radius = target / (2 * math.pi * planner.ROAD_FACTOR)
    centre = planner.destination(START[0], START[1], rotation, radius)
    assert geo.haversine_m(START[0], START[1], *centre) == pytest.approx(radius, rel=1e-3)
    for p in points:
        assert geo.haversine_m(centre[0], centre[1], p[0], p[1]) == pytest.approx(radius, rel=1e-3)
    assert [geo.haversine_m(START[0], START[1], p[0], p[1]) / radius for p in points] == pytest.approx([math.sqrt(2), 2.0, math.sqrt(2)], abs=0.02)      # quarter, half and three quarters round
    assert len(points) == 3


def test_the_two_directions_visit_the_waypoints_in_opposite_order():
    cw = planner.circle_waypoints(START, 100_000, 30, True)
    ccw = planner.circle_waypoints(START, 100_000, 30, False)
    assert cw[1] == pytest.approx(ccw[1], abs=1e-9) and cw[0] == pytest.approx(ccw[2], abs=1e-9) and cw[2] == pytest.approx(ccw[0], abs=1e-9)


# ------------------------------------------------------------------------------------------------------------------------------ measuring --

def test_a_straight_road_is_not_twisty_and_does_not_double_back():
    m = planner.measure(road_coords([("straight", 5000)], spacing=30))
    assert m["twist_density"] == 0 and m["retraced_share"] == 0 and m["twisty_m"] == 0


def test_a_snaking_road_is_twisty():
    m = planner.measure(road_coords(TWISTY * 3, spacing=12))
    assert m["twist_density"] > 0.5 and m["twisty_m"] > 2000


def test_an_out_and_back_route_is_mostly_retraced():
    there = road_coords([("straight", 8000)], spacing=30)
    back = list(reversed(there))
    m = planner.measure(there + back[1:])
    assert 0.4 <= m["retraced_share"] <= 0.55
    assert planner.measure(there)["retraced_share"] == 0


def test_a_loop_that_comes_back_to_where_it_started_is_not_retraced():
    loop = road_coords([("straight", 3000), ("turn", 300, 90), ("straight", 3000), ("turn", 300, 90), ("straight", 3000), ("turn", 300, 90), ("straight", 3000), ("turn", 300, 90)], spacing=30)
    assert planner.measure(loop)["retraced_share"] < 0.05


def test_the_share_of_road_you_have_ridden_counts_places_not_exact_points():
    line = road_coords([("straight", 3000)], spacing=30)
    ridden = {planner._cell(lat, lon, planner.RIDDEN_CELL_DEG) for lat, lon in line[: len(line) // 2]}
    assert planner.measure(line, ridden)["ridden_share"] == pytest.approx(0.5, abs=0.05)
    assert planner.measure(line)["ridden_share"] == 0 and planner.measure(line, set())["ridden_share"] == 0


def test_quality_rewards_twist_and_the_right_length_and_punishes_retracing_and_old_roads():
    base = {"twist_density": 0.5, "retraced_share": 0.0, "ridden_share": 0.0}
    q = lambda m, d=100_000, t=100_000, new=False: planner.quality({**base, **m}, d, t, new)          # noqa: E731
    assert q({}) > q({"twist_density": 0.3}) > 0
    assert q({}) > q({}, d=130_000) and q({}) > q({}, d=70_000)
    assert q({}) > q({"retraced_share": 0.3}) > q({"retraced_share": 0.6})
    assert q({"ridden_share": 0.8}) == q({}) and q({"ridden_share": 0.8}, new=True) < q({}, new=True)               # only matters when asked
    assert q({"twist_density": 0.0}) == 0


def test_a_route_as_the_app_gets_it_is_light_and_rounded():
    shape = road_coords(TWISTY * 12, spacing=10)
    route = {"distance_m": 31_234.0, "duration_s": 3_700.0, "shape": shape}
    shown = planner.present(route, planner.measure(shape), "Best loop")
    assert shown["distance_km"] == 31.2 and shown["duration_min"] == 62 and shown["name"] == "Best loop"
    assert len(shown["shape"]) <= planner.SHAPE_POINTS + 2 and shown["shape"][0] == [round(shape[0][0], 5), round(shape[0][1], 5)]
    assert 0 <= shown["twistiness"] <= 100 and shown["new_pct"] == 100 and set(shown) == {"name", "distance_km", "duration_min", "twisty_km", "twistiness", "retraced_pct", "new_pct", "shape"}


# -------------------------------------------------------------------------------------------------------------------------------- snapping --

def test_a_waypoint_moves_onto_the_best_twisty_stretch_nearby_and_goes_along_it(road_conn):
    east = (LAT0 + 0.02, LON0 + 0.10)
    ends = planner.snap_to_twisty(road_conn, (east[0] + 0.005, east[1] + 0.005), 3000, previous=(LAT0, LON0))
    assert ends is not None and len(ends) == 2
    near_first = geo.haversine_m(LAT0, LON0, *ends[0]) <= geo.haversine_m(LAT0, LON0, *ends[1])
    assert near_first                                                            # in through the end nearer to where the rider comes from
    reverse = planner.snap_to_twisty(road_conn, (east[0] + 0.005, east[1] + 0.005), 3000, previous=(LAT0 - 1.0, LON0 + 0.1))
    assert reverse == ends[::-1]                                                  # coming from the other side, the other way round


def test_no_twisty_road_in_reach_means_no_snap(road_conn):
    assert planner.snap_to_twisty(road_conn, (LAT0 + 0.3, LON0 + 0.3), 2000, previous=START) is None
    assert planner.snap_to_twisty(None, START, 2000, previous=START) is None


# ---------------------------------------------------------------------------------------------------------------------------------- loops --

def test_loops_start_and_end_at_the_start_and_are_about_the_wished_length(router, road_conn):
    out = planner.plan_loops(START, 100, roads_conn=road_conn)
    assert 1 <= len(out["routes"]) <= planner.MAX_ROUTES and out["tried"] >= 10
    for route in out["routes"]:
        assert abs(route["distance_km"] - 100) <= 25 and route["shape"][0] == pytest.approx(list(START), abs=1e-3) and route["shape"][-1] == pytest.approx(list(START), abs=1e-3)
    assert out["routes"][0]["distance_km"] == pytest.approx(100, abs=10)                    # the best ones were re-sized until they came out right
    assert [r["name"] for r in out["routes"]][0] == "Best loop"


def test_a_first_guess_that_is_too_long_is_corrected_by_trying_again(router):
    out = planner.plan_loops(START, 100, roads_conn=None)
    first_round = [c for c in router.calls[: planner.SNAPPED + planner.PLAIN]]
    assert len(first_round) == planner.SNAPPED + planner.PLAIN and len(router.calls) > len(first_round)               # some were routed a second time
    assert out["routes"][0]["distance_km"] == pytest.approx(100, abs=8) and out["tried"] > planner.SNAPPED + planner.PLAIN
    straight = sum(geo.haversine_m(a["lat"], a["lon"], b["lat"], b["lon"]) for a, b in zip(first_round[0]["locations"], first_round[0]["locations"][1:]))
    assert straight * router.factor > 110_000                                         # the first guess really was too long (about 17% here)


def test_candidates_that_come_out_the_same_are_offered_once(router):
    router.same_shape = {"distance_m": 100_000.0, "duration_s": 6000.0, "shape": road_coords(TWISTY * 6, spacing=12)}
    out = planner.plan_loops(START, 100, roads_conn=None)
    assert len(out["routes"]) == 1 and out["tried"] >= planner.SNAPPED + planner.PLAIN


def test_loops_are_different_from_each_other(router, road_conn):
    out = planner.plan_loops(START, 100, roads_conn=road_conn)
    cells = [planner.measure([tuple(p) for p in r["shape"]])["cells"] for r in out["routes"]]
    for i in range(len(cells)):
        for j in range(i + 1, len(cells)):
            assert planner._overlap(cells[i], cells[j]) < planner.DISTINCT_OVERLAP


def test_the_snaking_side_is_preferred_to_the_straight_one(router, road_conn):
    out = planner.plan_loops(START, 100, roads_conn=road_conn)
    assert out["routes"][0]["twistiness"] >= 10 and out["routes"][0]["twisty_km"] > 3
    assert all(r["twistiness"] >= 1 for r in out["routes"])


def test_a_waypoint_near_a_twisty_stretch_becomes_a_ride_in_one_end_and_out_the_other(tmp_path, monkeypatch):
    wps = planner.circle_waypoints(START, 100_000, 0.0, True)                                # the first candidate's three waypoints
    conn = roads.create(tmp_path / "roads.db")
    roads.add_way(conn, 7, {"highway": "secondary"}, road_coords(TWISTY, spacing=12, lat0=wps[1][0], lon0=wps[1][1]))
    roads.finish(conn, "test")
    monkeypatch.setattr(settings, "roads_db_path", str(tmp_path / "roads.db"))
    line = roads.query(roads.connect(), 0, 0, 90, 20, 5, 0, False)[0][0]["geometry"]
    locations = planner.loop_locations(roads.connect(), START, 100_000, 0.0, True, 1.0)
    assert [l["type"] for l in locations] == ["break", "through", "through", "through", "through", "break"]
    assert (locations[1]["lat"], locations[1]["lon"]) == pytest.approx(wps[0], abs=1e-9) and (locations[4]["lat"], locations[4]["lon"]) == pytest.approx(wps[2], abs=1e-9)    # not near a stretch: as planned
    entry, exit_ = (locations[2]["lat"], locations[2]["lon"]), (locations[3]["lat"], locations[3]["lon"])
    assert {entry, exit_} == {tuple(line[0]), tuple(line[-1])}                               # the middle one was moved onto the stretch, in through one end and out the other
    assert geo.haversine_m(*wps[0], *entry) <= geo.haversine_m(*wps[0], *exit_)             # the end nearer to where the rider comes from first
    assert (locations[0]["lat"], locations[0]["lon"]) == START and (locations[-1]["lat"], locations[-1]["lon"]) == START


def test_loops_are_routed_in_through_stretches_when_the_database_has_one_in_reach(router, tmp_path, monkeypatch):
    wps = planner.circle_waypoints(START, 100_000, 0.0, True)
    conn = roads.create(tmp_path / "roads.db")
    roads.add_way(conn, 7, {"highway": "secondary"}, road_coords(TWISTY, spacing=12, lat0=wps[1][0], lon0=wps[1][1]))
    roads.finish(conn, "test")
    monkeypatch.setattr(settings, "roads_db_path", str(tmp_path / "roads.db"))
    planner.plan_loops(START, 100, roads_conn=roads.connect())
    assert any(len(call["locations"]) == 6 for call in router.calls)
    assert router.calls[0]["locations"][0]["type"] == "break" and router.calls[0]["locations"][-1]["type"] == "break"


def test_without_a_road_database_loops_are_still_made_from_plain_circles(router):
    out = planner.plan_loops(START, 80, roads_conn=None)
    assert out["routes"] and all(l.get("type") in ("break", "through") for call in router.calls for l in call["locations"])


def test_the_options_reach_the_router(router):
    planner.plan_loops(START, 60, avoid_motorways=False, paved_only=False)
    assert router.calls and all(c["avoid_motorways"] is False and c["paved_only"] is False for c in router.calls)
    router.calls.clear()
    planner.plan_loops(START, 60)
    assert all(c["avoid_motorways"] is True and c["paved_only"] is True for c in router.calls)


def test_candidates_that_have_no_route_are_skipped_and_all_failing_is_an_error(router):
    router.fail_if = lambda locs: locs[1]["lon"] < LON0                          # nothing can be routed to the west
    assert planner.plan_loops(START, 80)["routes"]
    router.fail_if = lambda locs: True
    with pytest.raises(planner.PlannerError, match="No loop could be found"):
        planner.plan_loops(START, 80)


def test_a_down_routing_service_is_not_an_empty_answer(router):
    router.unavailable = True
    with pytest.raises(valhalla.ValhallaUnavailable):
        planner.plan_loops(START, 80)


@pytest.mark.parametrize("km", [5, 19.9, 400.1, 1000])
def test_lengths_outside_the_range_are_refused(router, km):
    with pytest.raises(planner.PlannerError, match="between 20 and 400 km"):
        planner.plan_loops(START, km)
    assert router.calls == []


def test_a_route_from_a_to_b_is_one_request_described_like_a_loop(router):
    out = planner.plan_route(START, (LAT0 + 0.1, LON0 + 0.1))
    assert len(out["routes"]) == 1 and out["routes"][0]["name"] == "Route" and out["tried"] == 1 and len(router.calls) == 1
    assert [l["type"] for l in router.calls[0]["locations"]] == ["break", "break"]
    router.fail_if = lambda locs: True
    with pytest.raises(planner.PlannerError, match="No route"):
        planner.plan_route(START, (LAT0 + 0.1, LON0 + 0.1))


def test_the_ridden_places_in_a_box_are_found_for_that_person_only(alice, bob):
    from conftest import add_ride
    mine, theirs = add_ride(ALICE["sub"], "2026-09-30T08:00:00+00:00"), add_ride(BOB["sub"], "2026-09-30T08:00:00+00:00")
    conn = get_db()
    conn.executemany("INSERT INTO ride_ways (ride_id, way_id, lat, lon) VALUES (?, 1, ?, ?)", [(mine, 47.40, 8.50), (mine, 47.41, 8.51), (mine, 48.5, 9.0), (theirs, 47.42, 8.52)])
    conn.commit()
    try:
        cells = planner.ridden_cells(conn, ALICE["sub"], 47.3, 8.4, 47.5, 8.6)
        assert cells == {planner._cell(47.40, 8.50, planner.RIDDEN_CELL_DEG), planner._cell(47.41, 8.51, planner.RIDDEN_CELL_DEG)}
    finally:
        conn.close()


# --------------------------------------------------------------------------------------------------------------------------------- Valhalla --

def encode6(coords):
    """The polyline algorithm at 1e-6 degrees, the other way round from valhalla.decode_polyline6."""
    out, last_lat, last_lon = [], 0, 0
    for lat, lon in coords:
        for value, last in ((round(lat * 1e6), last_lat), (round(lon * 1e6), last_lon)):
            delta = value - last
            delta = ~(delta << 1) if delta < 0 else delta << 1
            while delta >= 0x20:
                out.append(chr((0x20 | (delta & 0x1F)) + 63))
                delta >>= 5
            out.append(chr(delta + 63))
        last_lat, last_lon = round(lat * 1e6), round(lon * 1e6)
    return "".join(out)


def test_a_valhalla_line_decodes_to_the_points_it_was_made_from():
    coords = [(47.409398, 8.519434), (47.409512, 8.519301), (47.3, 8.6), (46.5, 9.99), (-33.8, 151.2), (47.409398, 8.519434)]
    assert valhalla.decode_polyline6(encode6(coords)) == pytest.approx(coords, abs=1e-6)
    assert valhalla.decode_polyline6("") == []


def test_the_route_call_builds_the_request_and_joins_the_legs(monkeypatch):
    sent = {}
    leg1, leg2 = [(47.0, 8.0), (47.01, 8.01)], [(47.01, 8.01), (47.02, 8.0)]

    def fake_post(path, payload):
        sent.update(path=path, payload=payload)
        return {"trip": {"summary": {"length": 12.5, "time": 900.0}, "legs": [{"shape": encode6(leg1)}, {"shape": encode6(leg2)}]}}

    monkeypatch.setattr(settings, "valhalla_url", "http://valhalla.invalid")
    monkeypatch.setattr(valhalla, "_post", fake_post)
    result = valhalla.route([{"lat": 47.0, "lon": 8.0}, {"lat": 47.02, "lon": 8.0}])
    assert sent["path"] == "/route" and sent["payload"]["costing"] == "motorcycle" and sent["payload"]["directions_type"] == "none"
    options = sent["payload"]["costing_options"]["motorcycle"]
    assert options["exclude_highways"] and options["exclude_tolls"] and options["exclude_unpaved"] and options["use_trails"] == 0.0
    assert result["distance_m"] == 12_500 and result["duration_s"] == 900 and result["shape"] == pytest.approx([(47.0, 8.0), (47.01, 8.01), (47.02, 8.0)], abs=1e-6)       # the shared point once
    valhalla.route([{"lat": 47.0, "lon": 8.0}, {"lat": 47.02, "lon": 8.0}], avoid_motorways=False, paved_only=False)
    options = sent["payload"]["costing_options"]["motorcycle"]
    assert "exclude_highways" not in options and "exclude_unpaved" not in options


def test_route_failures_are_told_apart(monkeypatch):
    monkeypatch.setattr(settings, "valhalla_url", "http://valhalla.invalid")
    monkeypatch.setattr(valhalla, "_post", lambda *a: (_ for _ in ()).throw(valhalla.NoMatch("No path could be found")))
    with pytest.raises(valhalla.NoRoute):
        valhalla.route([{"lat": 1, "lon": 1}, {"lat": 2, "lon": 2}])
    monkeypatch.setattr(valhalla, "_post", lambda *a: (_ for _ in ()).throw(valhalla.ValhallaUnavailable("The map service answered with an error (400).")))
    with pytest.raises(valhalla.NoRoute):
        valhalla.route([{"lat": 1, "lon": 1}, {"lat": 2, "lon": 2}])
    monkeypatch.setattr(valhalla, "_post", lambda *a: (_ for _ in ()).throw(valhalla.ValhallaUnavailable("The map service could not be reached.")))
    with pytest.raises(valhalla.ValhallaUnavailable):
        valhalla.route([{"lat": 1, "lon": 1}, {"lat": 2, "lon": 2}])
    monkeypatch.setattr(valhalla, "_post", lambda *a: {"trip": {"summary": {}, "legs": []}})
    with pytest.raises(valhalla.NoRoute, match="empty"):
        valhalla.route([{"lat": 1, "lon": 1}, {"lat": 2, "lon": 2}])
    monkeypatch.setattr(settings, "valhalla_url", "")
    with pytest.raises(valhalla.ValhallaUnavailable, match="switched off"):
        valhalla.route([{"lat": 1, "lon": 1}, {"lat": 2, "lon": 2}])


# ------------------------------------------------------------------------------------------------------------------------------------ API --

LOOP = {"lat": LAT0, "lon": LON0, "distance_km": 80}


def test_planning_a_loop_over_the_api(alice, router):
    body = alice.post("/api/v1/planner/loop", data=LOOP, headers=CLIENT).json()
    assert body["status"] == "ok" and body["message"] is None and body["api"] == 1 and body["routes"] and body["roads_data"] is False
    route = body["routes"][0]
    assert set(route) == {"name", "distance_km", "duration_min", "twisty_km", "twistiness", "retraced_pct", "new_pct", "shape"} and route["shape"][0][0] == pytest.approx(LAT0, abs=1e-3)


def test_the_loop_uses_the_road_database_when_there_is_one(alice, router, tmp_path, monkeypatch):
    conn = roads.create(tmp_path / "roads.db")
    roads.add_way(conn, 1, {"highway": "secondary"}, road_coords(TWISTY, spacing=12, lat0=LAT0 + 0.02, lon0=LON0 + 0.10))
    roads.finish(conn, "test")
    monkeypatch.setattr(settings, "roads_db_path", str(tmp_path / "roads.db"))
    assert alice.post("/api/v1/planner/loop", data=LOOP, headers=CLIENT).json()["roads_data"] is True


def test_the_options_in_the_request_reach_the_router(alice, router):
    alice.post("/api/v1/planner/loop", data={**LOOP, "avoid_motorways": "false", "paved_only": "false"}, headers=CLIENT)
    assert router.calls and all(c["avoid_motorways"] is False and c["paved_only"] is False for c in router.calls)


def test_prefer_new_looks_at_your_ridden_places_only(alice, router):
    from conftest import add_ride
    mine = add_ride(ALICE["sub"], "2026-09-30T08:00:00+00:00")
    conn = get_db()
    conn.execute("INSERT INTO ride_ways (ride_id, way_id, lat, lon) VALUES (?, 1, ?, ?)", (mine, LAT0, LON0))
    conn.commit()
    conn.close()
    body = alice.post("/api/v1/planner/loop", data={**LOOP, "prefer_new": "true"}, headers=CLIENT).json()
    assert body["status"] == "ok" and all(0 <= r["new_pct"] <= 100 for r in body["routes"])


def test_the_planner_says_why_when_it_cannot_plan(alice, router, monkeypatch):
    router.unavailable = True
    assert alice.post("/api/v1/planner/loop", data=LOOP, headers=CLIENT).json() == {"api": 1, "status": "unavailable", "routes": [], "message": "The routing service is not answering right now. Try again in a moment."}
    router.unavailable = False
    router.fail_if = lambda locs: True
    body = alice.post("/api/v1/planner/loop", data=LOOP, headers=CLIENT).json()
    assert body["status"] == "no_route" and "No loop could be found" in body["message"]
    monkeypatch.setattr(settings, "valhalla_url", "")
    assert alice.post("/api/v1/planner/loop", data=LOOP, headers=CLIENT).json()["status"] == "unavailable"


def test_a_busy_planner_says_so_instead_of_queueing(alice, router):
    from app.routers import api_planner
    assert api_planner._slots.acquire(blocking=False) and api_planner._slots.acquire(blocking=False)
    try:
        body = alice.post("/api/v1/planner/loop", data=LOOP, headers=CLIENT).json()
        assert body["status"] == "unavailable" and "busy" in body["message"] and router.calls == []
    finally:
        api_planner._slots.release()
        api_planner._slots.release()
    assert alice.post("/api/v1/planner/loop", data=LOOP, headers=CLIENT).json()["status"] == "ok"                  # and the slots came back


def test_a_to_b_over_the_api(alice, router):
    body = alice.post("/api/v1/planner/route", data={"from_lat": LAT0, "from_lon": LON0, "to_lat": LAT0 + 0.2, "to_lon": LON0 + 0.1}, headers=CLIENT).json()
    assert body["status"] == "ok" and len(body["routes"]) == 1 and body["routes"][0]["name"] == "Route"


@pytest.mark.parametrize("data", [
    {**LOOP, "distance_km": 10}, {**LOOP, "distance_km": 500}, {**LOOP, "lat": 91}, {**LOOP, "lon": -181}, {"lat": LAT0, "lon": LON0}, {**LOOP, "distance_km": "far"},
])
def test_bad_planning_requests_are_refused(alice, router, data):
    assert alice.post("/api/v1/planner/loop", data=data, headers=CLIENT).status_code in (400, 422) and router.calls == []


def test_planning_needs_a_login_and_the_client_header(alice, anon, router):
    assert anon.post("/api/v1/planner/loop", data=LOOP, headers=CLIENT).status_code == 401
    assert alice.post("/api/v1/planner/loop", data=LOOP).status_code in (400, 401, 403)
    assert router.calls == []


# ----------------------------------------------------------------------------------------------------------------------------- saved routes --

SHAPE = [[round(a, 5), round(b, 5)] for a, b in road_coords(TWISTY, spacing=12)]


def save(client, name="Sunday loop", kind="loop", shape=None, **extra):
    return client.post("/api/v1/planner/routes", data={"name": name, "kind": kind, "shape": json.dumps(SHAPE if shape is None else shape), "duration_s": 3600, **extra}, headers=CLIENT)


def test_a_route_can_be_saved_listed_read_and_deleted(alice):
    saved = save(alice).json()["route"]
    assert saved["name"] == "Sunday loop" and saved["kind"] == "loop" and saved["twistiness"] >= 50 and saved["duration_min"] == 60 and saved["id"] >= 1
    assert saved["distance_km"] == pytest.approx(1.6, abs=0.1)                        # worked out here from the line
    assert alice.get("/api/v1/planner/routes").json()["routes"] == [saved]
    full = alice.get(f"/api/v1/planner/routes/{saved['id']}").json()["route"]
    assert full["shape"] == SHAPE and full["name"] == "Sunday loop"
    assert alice.delete(f"/api/v1/planner/routes/{saved['id']}", headers=CLIENT).json() == {"api": 1, "deleted": saved["id"]}
    assert alice.get("/api/v1/planner/routes").json()["routes"] == [] and alice.get(f"/api/v1/planner/routes/{saved['id']}").status_code == 404


def test_the_length_is_not_taken_from_the_app(alice):
    saved = save(alice, distance_m=999999999).json()["route"]
    assert saved["distance_km"] < 5


def test_someone_elses_route_is_a_404_for_everything(alice, bob):
    rid = save(alice).json()["route"]["id"]
    assert bob.get(f"/api/v1/planner/routes/{rid}").status_code == 404
    assert bob.get(f"/api/v1/planner/routes/{rid}/gpx").status_code == 404
    assert bob.delete(f"/api/v1/planner/routes/{rid}", headers=CLIENT).status_code == 404
    assert bob.get("/api/v1/planner/routes").json()["routes"] == []
    assert alice.get(f"/api/v1/planner/routes/{rid}").status_code == 200


def test_saving_is_refused_for_bad_input(alice, anon):
    assert save(alice, name="   ").status_code == 400 and save(alice, name="x" * 81).status_code == 400
    assert save(alice, kind="spaceship").status_code == 400
    assert save(alice, shape="not json").status_code == 400 and save(alice, shape=[[47.0, 8.0]]).status_code == 400
    assert save(alice, shape=[[91.0, 8.0], [47.0, 8.0]]).status_code == 400 and save(alice, shape=[[47.0, "x"], [47.0, 8.0]]).status_code == 400
    assert save(alice, shape=[[47.0, 8.0 + i * 1e-5] for i in range(planner and 5001)]).status_code == 400
    assert save(anon).status_code == 401
    assert alice.post("/api/v1/planner/routes", data={"name": "n", "shape": json.dumps(SHAPE)}).status_code in (400, 401, 403)
    assert alice.get("/api/v1/planner/routes").json()["routes"] == []


def test_there_is_a_limit_on_how_many_routes_are_kept(alice, monkeypatch):
    from app.routers import api_planner
    monkeypatch.setattr(api_planner, "MAX_SAVED", 2)
    assert save(alice, name="one").status_code == 200 and save(alice, name="two").status_code == 200
    assert save(alice, name="three").status_code == 400


def test_a_saved_route_is_a_gpx_file_other_apps_can_read(alice):
    rid = save(alice, name="Sunday <loop> & more").json()["route"]["id"]
    response = alice.get(f"/api/v1/planner/routes/{rid}/gpx")
    assert response.status_code == 200 and response.headers["content-type"].startswith("application/gpx+xml")
    assert response.headers["content-disposition"] == 'attachment; filename="Sunday--loop----more.gpx"'
    root = ET.fromstring(response.content)
    ns = {"g": gpx.GPX_NS}
    assert root.find("g:trk/g:name", ns).text == "Sunday <loop> & more"
    points = root.findall(".//g:trkpt", ns)
    assert len(points) == len(SHAPE) and float(points[0].attrib["lat"]) == pytest.approx(SHAPE[0][0], abs=1e-5) and float(points[-1].attrib["lon"]) == pytest.approx(SHAPE[-1][1], abs=1e-5)
    assert root.find(".//g:time", ns) is None


def test_deleting_all_traces_of_a_route_does_not_touch_other_peoples(alice, bob):
    a, b = save(alice).json()["route"]["id"], save(bob).json()["route"]["id"]
    alice.delete(f"/api/v1/planner/routes/{a}", headers=CLIENT)
    assert bob.get(f"/api/v1/planner/routes/{b}").status_code == 200
