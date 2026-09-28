"""Golden JSON for the iOS app (ios/Tests/Fixtures/api_*.json), the contract behind ios/Sources/API/Models.swift.

Normal run: each endpoint's answer must have the same *shape* as its committed fixture (same keys, same value types, a null where the
fixture has a null). If the server changes an endpoint, this fails until the Swift models and the fixture are updated together:

    UPDATE_API_FIXTURES=1 python -m pytest tests/test_api_fixtures.py

The fixtures use fixed rides and a fixed token, so they only change when the API does (the 90-day calendar's dates follow today's date,
which the shape check ignores).
"""
import json
import os
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest

from conftest import ALICE, add_ride, add_token

FIXTURES = Path(__file__).resolve().parent.parent / "ios" / "Tests" / "Fixtures"
ENDPOINTS = {
    "api_me": "/api/v1/me",
    "api_home": "/api/v1/home",
    "api_rides": "/api/v1/rides",
    "api_ride_detail": "/api/v1/rides/{ride_id}",
    "api_overview": "/api/v1/overview",
    "api_map": "/api/v1/map",
    "api_settings": "/api/v1/settings",
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


@pytest.fixture
def seeded(alice):
    add_token(ALICE["sub"], ALICE["email"], "fixture-ingest-token-0000000000000000000")
    today = datetime.now(timezone.utc).replace(hour=12, minute=0, second=0, microsecond=0)
    ids = []
    for days, km, minutes, top, climb in [(2, 12.4, 22, 27.0, 40), (9, 88.0, 95, 38.5, 610), (30, 260.3, 240, 41.2, 1500)]:
        start = (today - timedelta(days=days)).isoformat()
        ids.append(add_ride(ALICE["sub"], start, distance_m=km * 1000, duration_s=minutes * 60, max_mps=top, climb_m=climb, points=180,
                            polyline=[[47.3769, 8.5417], [47.3801, 8.5502], [47.3866, 8.5611], [47.3902, 8.5739]]))
    return ids


@pytest.mark.parametrize("name", sorted(ENDPOINTS))
def test_fixture_matches_the_live_api(name, alice, seeded):
    path = ENDPOINTS[name].format(ride_id=seeded[1])
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
