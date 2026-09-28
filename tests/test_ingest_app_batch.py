"""POST /api/ingest with the batches the RideLog app uploads (contract: ios/Tests/Fixtures/ingest_batch.json), and point de-duplication."""
import copy
import json
import math
from pathlib import Path

import pytest

from app.db import get_db
from conftest import ALICE, BOB, add_token

FIXTURE = Path(__file__).resolve().parent.parent / "ios" / "Tests" / "Fixtures" / "ingest_batch.json"
TOKEN = "alice-ingest-token"
AUTH = {"Authorization": f"Bearer {TOKEN}"}


@pytest.fixture
def doc():
    return json.loads(FIXTURE.read_text())


@pytest.fixture(autouse=True)
def alice_token():
    add_token(ALICE["sub"], ALICE["email"], TOKEN)


def haversine(a, b):
    p1, p2 = math.radians(a["lat"]), math.radians(b["lat"])
    h = math.sin((p2 - p1) / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(math.radians(b["lon"] - a["lon"]) / 2) ** 2
    return 2 * 6371000.0 * math.asin(math.sqrt(h))


def rows(sql, *args):
    conn = get_db()
    try:
        return conn.execute(sql, args).fetchall()
    finally:
        conn.close()


def post(client, body, headers=AUTH):
    return client.post("/api/ingest", json=body, headers=headers)


def test_a_whole_app_ride_becomes_one_ride_with_the_right_numbers(anon, doc):
    r = post(anon, doc["body"])
    assert r.status_code == 200 and r.json() == {"result": "ok"}

    (ride,) = rows("SELECT * FROM rides")
    s = doc["samples"]
    assert ride["owner_sub"] == ALICE["sub"]
    assert ride["source"] == "trip_marker" and ride["trip_id"] == doc["trip_id"]
    assert ride["device_id"] == doc["device_id"]
    assert ride["point_count"] == 40
    assert ride["duration_s"] == 195
    assert ride["distance_m"] == pytest.approx(sum(haversine(a, b) for a, b in zip(s, s[1:])), abs=0.5)
    assert ride["max_speed_mps"] == 24.0
    assert ride["elevation_gain_m"] == 57.0                     # 19 steps of +3 m; the +0 steps are below the noise floor
    assert ride["app_reported_distance_m"] == doc["trip"]["distance_m"]
    assert ride["start_time"].startswith("2026-09-28T09:15:00") and ride["end_time"].startswith("2026-09-28T09:18:15")
    assert json.loads(ride["polyline_simplified"])[0] == [s[0]["lat"], s[0]["lon"]]
    # every stored point now belongs to the ride
    assert rows("SELECT COUNT(*) c FROM points WHERE ride_id IS NULL")[0]["c"] == 0


def test_the_ride_shows_up_in_the_api_the_app_reads(alice, doc):
    post(alice, doc["body"])
    data = alice.get("/api/v1/rides").json()["rides"]
    assert len(data) == 1 and data[0]["point_count"] == 40 and data[0]["max_kmh"] == 86


def test_posting_the_same_batch_twice_changes_nothing(anon, doc):
    post(anon, doc["body"])
    before = rows("SELECT distance_m, point_count FROM rides")[0]
    assert post(anon, doc["body"]).status_code == 200
    assert rows("SELECT COUNT(*) c FROM rides")[0]["c"] == 1
    assert rows("SELECT COUNT(*) c FROM points")[0]["c"] == 40
    after = rows("SELECT distance_m, point_count FROM rides")[0]
    assert (after["distance_m"], after["point_count"]) == (before["distance_m"], before["point_count"])


def test_a_retried_batch_before_the_end_does_not_double_the_points(anon, doc):
    """The upload timed out, so the app sends the same 25 points again, then the rest and the trip marker."""
    locations = doc["body"]["locations"]
    first = {"locations": locations[:25]}
    post(anon, first)
    post(anon, first)                                            # retry of a batch the server had already stored
    assert rows("SELECT COUNT(*) c FROM points")[0]["c"] == 25
    assert rows("SELECT COUNT(*) c FROM rides")[0]["c"] == 0     # a trip is only closed by its marker, not by silence
    post(anon, {"locations": locations[25:]})                    # remaining 15 points + marker
    (ride,) = rows("SELECT * FROM rides")
    assert ride["point_count"] == 40


def test_overlapping_batches_still_make_one_correct_ride(anon, doc):
    locations = doc["body"]["locations"]
    post(anon, {"locations": locations[:25]})
    post(anon, {"locations": locations[15:]})                    # 10 points re-sent, then the rest + marker
    (ride,) = rows("SELECT * FROM rides")
    assert ride["point_count"] == 40
    assert ride["distance_m"] == pytest.approx(rows("SELECT distance_m FROM rides")[0]["distance_m"])
    assert ride["duration_s"] == 195


def test_the_marker_is_what_closes_the_ride(anon, doc):
    locations = doc["body"]["locations"]
    post(anon, {"locations": locations[:-1]})                    # all 40 points, no marker yet
    assert rows("SELECT COUNT(*) c FROM rides")[0]["c"] == 0
    post(anon, {"locations": locations[-1:]})                    # marker alone, in a later request
    assert rows("SELECT COUNT(*) c FROM rides")[0]["c"] == 1


def test_a_repeated_marker_does_not_make_a_second_ride(anon, doc):
    post(anon, doc["body"])
    post(anon, {"locations": doc["body"]["locations"][-1:]})
    assert rows("SELECT COUNT(*) c FROM rides")[0]["c"] == 1


def test_same_time_but_a_different_place_is_not_a_duplicate(anon, doc):
    body = copy.deepcopy(doc["body"])
    moved = copy.deepcopy(body["locations"][3])
    moved["geometry"]["coordinates"] = [8.6, 47.4]               # same device + timestamp, different position
    body["locations"].insert(4, moved)
    post(anon, body)
    assert rows("SELECT COUNT(*) c FROM points")[0]["c"] == 41


def test_two_users_can_upload_the_same_timestamps(anon, doc):
    add_token(BOB["sub"], BOB["email"], "bob-token")
    a = copy.deepcopy(doc["body"])
    b = copy.deepcopy(doc["body"])
    for feature in b["locations"]:
        if feature["properties"].get("trip_id"):
            feature["properties"]["trip_id"] += "-bob"
        if feature["properties"].get("start"):
            feature["properties"]["start"] += "-bob"
    post(anon, a)
    post(anon, b, headers={"Authorization": "Bearer bob-token"})
    assert rows("SELECT COUNT(*) c FROM points")[0]["c"] == 80   # the de-dupe is per owner
    assert {r["owner_sub"] for r in rows("SELECT owner_sub FROM rides")} == {ALICE["sub"], BOB["sub"]}


def test_a_wrong_or_missing_token_is_rejected_and_stores_nothing(anon, doc):
    assert post(anon, doc["body"], headers={"Authorization": "Bearer nope"}).status_code == 401
    assert post(anon, doc["body"], headers={}).status_code == 401
    assert rows("SELECT COUNT(*) c FROM points")[0]["c"] == 0


def test_overland_style_batch_without_a_trip_is_still_accepted(anon):
    """Overland's plain background tracking (no trip id, no marker) keeps working: the answer is {"result": "ok"} and the points are kept."""
    body = {"locations": [
        {"type": "Feature", "geometry": {"type": "Point", "coordinates": [8.5, 47.3]},
         "properties": {"timestamp": "2026-09-28T09:00:00Z", "speed": 3.0, "horizontal_accuracy": 10, "device_id": "iphone"}},
        {"type": "Feature", "geometry": {"type": "Point", "coordinates": [8.5001, 47.3001]},
         "properties": {"timestamp": "2026-09-28T09:00:05Z", "speed": 3.1, "horizontal_accuracy": 10, "device_id": "iphone"}},
    ]}
    assert post(anon, body).json() == {"result": "ok"}
    assert post(anon, body).json() == {"result": "ok"}
    assert rows("SELECT COUNT(*) c FROM points")[0]["c"] == 2


def test_malformed_items_are_skipped_not_fatal(anon, doc):
    body = copy.deepcopy(doc["body"])
    body["locations"].insert(2, {"type": "Feature", "geometry": {}, "properties": {}})
    assert post(anon, body).json() == {"result": "ok"}
    assert rows("SELECT COUNT(*) c FROM rides")[0]["c"] == 1
