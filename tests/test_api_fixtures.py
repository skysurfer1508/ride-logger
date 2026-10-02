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
def test_fixture_matches_the_live_api(name, alice, seeded):
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
    path = ENDPOINTS[name].format(ride_id=seeded[1], bike_id=1, insights_ride_id=insights_ride_id)
    response = alice.get(path)
    assert response.status_code == 200
    actual = response.json()
    target = FIXTURES / f"{name}.json"
    if os.environ.get("UPDATE_API_FIXTURES") == "1":
        FIXTURES.mkdir(parents=True, exist_ok=True)
        target.write_text(json.dumps(actual, indent=1, sort_keys=True) + "\n")
        return
    assert target.exists(), f"{target.name} is missing: run UPDATE_API_FIXTURES=1 python -m pytest tests/test_api_fixtures.py"
    assert shape(actual) == shape(json.loads(target.read_text())), f"{name}: the API's shape changed; update the Swift models, then the fixture"
