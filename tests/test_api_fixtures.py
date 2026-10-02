"""Golden JSON for the iOS app (ios/Tests/Fixtures/api_*.json), the contract behind ios/Sources/API/Models.swift.

Normal run: each endpoint's answer must have the same *shape* as its committed fixture (same keys, same value types, a null where the
fixture has a null). If the server changes an endpoint, this fails until the Swift models and the fixture are updated together:

    UPDATE_API_FIXTURES=1 python -m pytest tests/test_api_fixtures.py

The fixtures use fixed rides and a fixed token, so they only change when the API does (the 90-day calendar's dates follow today's date,
which the shape check ignores).
"""
import json
import os
from datetime import date, datetime, timedelta, timezone
from pathlib import Path

import pytest

from conftest import ALICE, add_ride, add_token
from app.db import get_db
from test_track import insert_points
from trackgen import make_path_rows, make_rows

FIXTURES = Path(__file__).resolve().parent.parent / "ios" / "Tests" / "Fixtures"
ENDPOINTS = {
    "api_me": "/api/v1/me",
    "api_home": "/api/v1/home",
    "api_rides": "/api/v1/rides",
    "api_ride_detail": "/api/v1/rides/{ride_id}",
    "api_track": "/api/v1/rides/{ride_id}/track",
    "api_overview": "/api/v1/overview",
    "api_map": "/api/v1/map",
    "api_settings": "/api/v1/settings",
    "api_garage": "/api/v1/garage",
    "api_garage_bike": "/api/v1/garage/bikes/{bike_id}",
    "api_insights": "/api/v1/rides/{insights_ride_id}/insights",
    "api_roads": "/api/v1/roads?south=47.39&west=8.55&north=47.45&east=8.65&min_score=0",
    "api_planner_loop": ("/api/v1/planner/loop", {"lat": 47.3769, "lon": 8.5417, "distance_km": 60}),
    "api_planner_trip": ("/api/v1/planner/route", {"locations": json.dumps([{"lat": 47.3769, "lon": 8.5417}, {"lat": 47.4988, "lon": 8.7241}]), "mode": "fast", "alternatives": "1"}),
    "api_planner_directions": ("/api/v1/planner/directions", {"locations": json.dumps([{"lat": 47.3769, "lon": 8.5417, "type": "break"}, {"lat": 47.4988, "lon": 8.7241, "type": "break"}]), "mode": "relaxed"}),
    "api_planner_routes": "/api/v1/planner/routes",
    "api_planner_route": "/api/v1/planner/routes/{route_id}",
    "api_traffic_config": "/api/v1/traffic/config",
    "api_traffic_incidents": "/api/v1/traffic/incidents?lat=47.3769&lon=8.5417&radius_km=25",
    "api_traffic_webcams": "/api/v1/traffic/webcams?lat=47.3769&lon=8.5417&radius_km=15",
}


def shape(value):
    """The structure of a JSON value, ignoring the values themselves (and looking only at the first item of a list)."""
    if isinstance(value, dict):
        return {k: shape(v) for k, v in sorted(value.items())}
    if isinstance(value, list):
        return [shape(value[0])] if value else []
    if value is None:
        return "null"
    if isinstance(value, bool):
        return "bool"
    if isinstance(value, (int, float)):
        return "number"
    return "string"


@pytest.fixture(autouse=True)
def fake_traffic(monkeypatch):
    """The traffic endpoints answer from the hand-written samples in test_traffic.py instead of the network."""
    from app import traffic
    from app.config import settings
    from app import tmc
    from test_traffic import LOC, NOW, SAMPLE, WINDY_JSON
    traffic._cache.clear()
    monkeypatch.setattr(traffic, "_now", lambda: NOW)
    monkeypatch.setattr(tmc, "locations", lambda: LOC)
    monkeypatch.setattr(settings, "opentransportdata_api_key", "fixture-key")
    monkeypatch.setattr(settings, "windy_api_key", "fixture-key")
    monkeypatch.setattr(traffic, "_post_soap", lambda body: SAMPLE)
    monkeypatch.setattr(traffic, "_windy_get", lambda params: WINDY_JSON)


@pytest.fixture(autouse=True)
def fake_insights(monkeypatch):
    """The insights endpoint gets a road and limit for every point and a dry grey day, instead of Valhalla and Open-Meteo."""
    from app import valhalla, weather
    from app.config import settings
    from test_insights_api import hourly
    monkeypatch.setattr(settings, "valhalla_url", "http://valhalla.invalid")
    monkeypatch.setattr(settings, "weather_enabled", True)
    monkeypatch.setattr(valhalla, "match_points", lambda pts: [{"limit_kmh": 80, "road_class": "primary", "name": "Hardstrasse", "way_id": 1, "use": "road"}] * len(pts))
    monkeypatch.setattr(weather, "fetch", lambda lat, lon, start, end, now=None: hourly())


@pytest.fixture
def seeded(alice, monkeypatch):
    add_token(ALICE["sub"], ALICE["email"], "fixture-ingest-token-0000000000000000000")
    today = datetime.now(timezone.utc).replace(hour=12, minute=0, second=0, microsecond=0)
    ids = []
    for days, km, minutes, top, climb in [(2, 12.4, 22, 27.0, 40), (9, 88.0, 95, 38.5, 610), (30, 260.3, 240, 41.2, 1500)]:
        start = (today - timedelta(days=days)).isoformat()
        ids.append(add_ride(ALICE["sub"], start, distance_m=km * 1000, duration_s=minutes * 60, max_mps=top, climb_m=climb, points=180,
                            polyline=[[47.3769, 8.5417], [47.3801, 8.5502], [47.3866, 8.5611], [47.3902, 8.5739]]))
    # ride ids[1] gets a real track (a light with fixes, a wait with none) so api_track.json has stops in it
    insert_points(ALICE["sub"], ids[1], make_rows([("drive", 40, 12), ("stop", 25, "zero"), ("drive", 30, 14), ("stop", 40, "gap"), ("drive", 30, 12)]))
    # a bike with a service item, two fuel fills and an expense, for api_garage*.json (the database is fresh for every test, so this bike has id 1)
    from app import garage_store as g
    from app.routers import api_garage
    monkeypatch.setattr(api_garage, "_today", lambda: date(2026, 10, 2))
    conn = get_db()
    try:
        bike = g.create_bike(conn, ALICE["sub"], name="Tuono", make="Aprilia", model="1100 RR", year=2021, start_odometer_km=10000.0, start_date=date(2026, 1, 1))
        item = g.add_item(conn, ALICE["sub"], bike, name="Oil change", interval_km=6000.0, interval_months=12)
        g.log_service(conn, ALICE["sub"], item, done_date=date(2026, 6, 1), odometer=9500.0, cost=180.5, note="Dealer")
        g.add_fuel(conn, ALICE["sub"], bike, day=date(2026, 9, 1), odometer=10000.0, litres=12.0, price=24.0, full_tank=True)
        g.add_fuel(conn, ALICE["sub"], bike, day=date(2026, 9, 10), odometer=10250.0, litres=11.0, price=23.1, full_tank=True)
        g.add_expense(conn, ALICE["sub"], bike, day=date(2026, 9, 15), category="Tyres", amount=180.0, note="Rear")
    finally:
        conn.close()
    return ids


@pytest.mark.parametrize("name", sorted(ENDPOINTS))
def test_fixture_matches_the_live_api(name, alice, seeded, monkeypatch):
    insights_ride_id = None
    if name == "api_insights":
        # 90 km/h (over the 80 limit) through a right-hander, then a hard stop and a hard getaway: a corner with its lean, a braking and an acceleration event.
        # Added only here so the other fixtures keep their three rides.
        insights_ride_id = add_ride(ALICE["sub"], datetime.now(timezone.utc).isoformat(), distance_m=3200, duration_s=130, points=130)
        rows = make_path_rows([("straight", 1500), ("turn", 150, 90), ("straight", 1500)], 25, course_sigma=1.0)
        for i in (100, 101):
            rows[i]["speed"] = 3.0
        rows[102]["speed"] = 22.0
        insert_points(ALICE["sub"], insights_ride_id, rows)
    if name == "api_roads":
        _roads_for_fixture(seeded, monkeypatch)
    route_id = None
    if name.startswith("api_planner"):
        route_id = _planner_for_fixture(alice, monkeypatch)
    if name in ("api_planner_trip", "api_planner_directions"):
        _real_valhalla_for_fixture(monkeypatch)
    spec = ENDPOINTS[name]
    if isinstance(spec, tuple):
        response = alice.post(spec[0], data=spec[1], headers={"X-RideLog-Client": "1"})
        assert response.status_code == 200
        _check_or_write(name, response.json())
        return
    path = spec.format(ride_id=seeded[1], bike_id=1, insights_ride_id=insights_ride_id, route_id=route_id)
    response = alice.get(path)
    assert response.status_code == 200
    _check_or_write(name, response.json())


def _check_or_write(name, actual):
    target = FIXTURES / f"{name}.json"
    if os.environ.get("UPDATE_API_FIXTURES") == "1":
        FIXTURES.mkdir(parents=True, exist_ok=True)
        target.write_text(json.dumps(actual, indent=1, sort_keys=True) + "\n")
        return
    assert target.exists(), f"{target.name} is missing: run UPDATE_API_FIXTURES=1 python -m pytest tests/test_api_fixtures.py"
    assert shape(actual) == shape(json.loads(target.read_text())), f"{name}: the API's shape changed; update the Swift models, then the fixture"


def _roads_for_fixture(seeded, monkeypatch):
    """Two twisty ways near 47.40 / 47.41, 8.60: the app has ridden the first (matched points of a ride along it) and not the second."""
    import tempfile
    from app import extras, roads
    from app.config import settings
    from trackgen import road_coords
    twisty = [("straight", 150)] + [("turn", 60, 70 if i % 2 else -70) for i in range(18)] + [("straight", 150)]
    target = Path(tempfile.mkdtemp(prefix="roads-fixture-")) / "roads.db"
    conn = roads.create(target)
    first = road_coords(twisty, spacing=12, lat0=47.40, lon0=8.60)
    roads.add_way(conn, 111, {"highway": "secondary", "name": "Kurvenstrasse", "ref": "7", "maxspeed": "80"}, first)
    roads.add_way(conn, 333, {"highway": "tertiary", "name": "Passstrasse", "surface": "asphalt"}, road_coords(twisty, spacing=12, lat0=47.41, lon0=8.60))
    roads.finish(conn, "fixture")
    monkeypatch.setattr(settings, "roads_db_path", str(target))
    db = get_db()
    try:
        db.executemany("INSERT INTO ride_ways (ride_id, way_id, lat, lon) VALUES (?, 111, ?, ?)", [(seeded[1], lat, lon) for lat, lon in first])
        for ride_id in seeded:                                                  # every ride has had its roads worked out: nothing pending
            db.execute("INSERT OR REPLACE INTO ride_extras (ride_id, kind, version, points, payload, fetched_at) VALUES (?, 'ways', ?, 0, '{}', 'now')", (ride_id, extras.CACHE_VERSION))
        db.commit()
    finally:
        db.close()


def _planner_for_fixture(alice, monkeypatch):
    """A routing service that joins the points with lines, and one saved route (returns its id)."""
    from test_planner import FakeRouter, SHAPE
    FakeRouter(monkeypatch)
    waypoints = json.dumps([{"lat": 47.0, "lon": 8.0, "type": "break"}, {"lat": 47.05, "lon": 8.02, "type": "through"}, {"lat": 47.0, "lon": 8.0, "type": "break"}])
    saved = alice.post("/api/v1/planner/routes", data={"name": "Sunday loop", "kind": "loop", "shape": json.dumps(SHAPE), "duration_s": 3600, "waypoints": waypoints, "mode": "loop"},
                       headers={"X-RideLog-Client": "1"})
    assert saved.status_code == 200
    return saved.json()["route"]["id"]


def _real_valhalla_for_fixture(monkeypatch):
    """The routing service answers with a REAL captured Valhalla trip (tests/data), so the golden JSON holds real maneuvers: roundabout, stops, spoken sentences."""
    from pathlib import Path
    from app import valhalla
    real = json.loads((Path(__file__).parent / "data" / "valhalla_trip_instructions.json").read_text())

    def route(locations, avoid_motorways=True, paved_only=True, *, costing_options=None, directions=False, language="en-US", alternates=0, heading=None):
        out = valhalla.parse_trip(real["trip"])
        if alternates:
            out["alternates"] = [valhalla.parse_trip(real["trip"])]
        return out

    monkeypatch.setattr(valhalla, "route", route)
