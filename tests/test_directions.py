"""Turn-by-turn data from Valhalla (app/valhalla.py parse_trip / route / encode_polyline6), tested on a REAL answer captured from the Swiss map
(tests/data/valhalla_trip_instructions.json: Zurich to Winterthur with a stop on the way, motorcycle, no motorways, English)."""
import json
from pathlib import Path

import pytest

from app import geo, valhalla
from app.config import settings

REAL = json.loads((Path(__file__).parent / "data" / "valhalla_trip_instructions.json").read_text())


@pytest.fixture
def trip():
    return valhalla.parse_trip(REAL["trip"])


def test_the_real_answer_becomes_one_line_and_a_list_of_maneuvers(trip):
    assert len(trip["shape"]) > 1000 and trip["distance_m"] == pytest.approx(29_660, abs=100) and trip["duration_s"] > 600
    assert trip["shape"][0] == pytest.approx((47.3769, 8.5417), abs=0.003) and trip["shape"][-1] == pytest.approx((47.4988, 8.7241), abs=0.003)
    assert len(trip["maneuvers"]) == 17 and {m["leg"] for m in trip["maneuvers"]} == {0, 1}


def test_a_maneuver_carries_what_navigation_needs(trip):
    first, last = trip["maneuvers"][0], trip["maneuvers"][-1]
    assert first["type"] == 1 and first["along_m"] == 0 and first["pre"] and first["street"] == "Bahnhofquai" and first["length_m"] > 0
    assert last["type"] == 4 and last["pre"] == "You have arrived at your destination." and last["length_m"] == 0
    assert all(set(m) == {"type", "instruction", "pre", "alert", "post", "street", "length_m", "time_s", "along_m", "lat", "lon", "leg", "roundabout_exit"} for m in trip["maneuvers"])
    assert all(m["pre"] for m in trip["maneuvers"])


def test_the_distance_along_the_route_only_grows_and_ends_at_the_end(trip):
    along = [m["along_m"] for m in trip["maneuvers"]]
    assert along == sorted(along) and along[0] == 0
    assert along[-1] == pytest.approx(trip["distance_m"], abs=100)
    for m, nxt in zip(trip["maneuvers"], trip["maneuvers"][1:]):                          # each one's length reaches about to the next one
        assert nxt["along_m"] - m["along_m"] == pytest.approx(m["length_m"], abs=60)


def test_a_maneuver_sits_on_the_line_where_it_says(trip):
    for m in trip["maneuvers"]:
        assert min(geo.haversine_m(m["lat"], m["lon"], lat, lon) for lat, lon in trip["shape"][:: max(1, len(trip["shape"]) // 3000)]) < 40


def test_the_stop_on_the_way_ends_the_first_leg_and_starts_the_second(trip):
    leg0 = [m for m in trip["maneuvers"] if m["leg"] == 0]
    leg1 = [m for m in trip["maneuvers"] if m["leg"] == 1]
    assert leg0[-1]["type"] in (4, 5, 6) and leg1[0]["type"] in (1, 2, 3)                # arrive at the stop, set off again
    assert leg1[0]["along_m"] == pytest.approx(leg0[-1]["along_m"], abs=60)


def test_a_roundabout_says_which_exit_to_take(trip):
    enter = [m for m in trip["maneuvers"] if m["type"] == 26]
    assert enter and enter[0]["roundabout_exit"] == 2 and "2nd exit" in enter[0]["instruction"]
    assert all(m["roundabout_exit"] is None for m in trip["maneuvers"] if m["type"] not in (26, 27))


def test_the_transition_alert_is_the_short_sentence_for_the_moment_of_the_turn(trip):
    turns = [m for m in trip["maneuvers"] if m["type"] == 10]
    assert turns and all(m["alert"] and len(m["alert"]) <= len(m["pre"]) + 40 for m in turns)


def test_a_trip_without_instructions_has_no_maneuvers():
    plain = {"trip": {**REAL["trip"], "legs": [{"shape": leg["shape"], "summary": leg["summary"]} for leg in REAL["trip"]["legs"]]}}
    assert valhalla.parse_trip(plain["trip"])["maneuvers"] == []


def test_an_empty_route_is_no_route():
    with pytest.raises(valhalla.NoRoute, match="empty"):
        valhalla.parse_trip({"legs": [], "summary": {}})


def test_the_encoded_line_survives_the_trip_both_ways(trip):
    encoded = valhalla.encode_polyline6(trip["shape"])
    back = valhalla.decode_polyline6(encoded)
    assert len(back) == len(trip["shape"]) and back == pytest.approx(trip["shape"], abs=1e-6)
    assert len(encoded) < 6 * len(trip["shape"]) * 2                                         # a few bytes a point: a whole route in a few kilobytes
    assert valhalla.encode_polyline6([]) == ""


def test_the_request_asks_for_instructions_in_english_and_pins_the_heading(monkeypatch):
    sent = {}
    monkeypatch.setattr(settings, "valhalla_url", "http://valhalla.invalid")
    monkeypatch.setattr(valhalla, "_post", lambda path, payload: sent.update(payload=payload) or REAL)
    result = valhalla.route([{"lat": 47.3769, "lon": 8.5417}, {"lat": 47.4988, "lon": 8.7241}], directions=True, heading=272.6, costing_options={"maneuver_penalty": 100})
    payload = sent["payload"]
    assert payload["directions_type"] == "instructions" and payload["directions_options"] == {"language": "en-US", "units": "kilometers"}
    assert payload["locations"][0]["heading"] == 273 and payload["locations"][0]["heading_tolerance"] == 60 and "heading" not in payload["locations"][1]
    assert payload["costing_options"]["motorcycle"] == {"maneuver_penalty": 100} and "alternates" not in payload and result["maneuvers"]
    valhalla.route([{"lat": 1, "lon": 1}, {"lat": 2, "lon": 2}])
    assert sent["payload"]["directions_type"] == "none" and "directions_options" not in sent["payload"] and "heading" not in sent["payload"]["locations"][0]


def test_alternatives_are_asked_for_only_between_two_points_and_come_back_parsed(monkeypatch):
    sent = []
    monkeypatch.setattr(settings, "valhalla_url", "http://valhalla.invalid")
    monkeypatch.setattr(valhalla, "_post", lambda path, payload: sent.append(payload) or {**REAL, "alternates": [{"trip": REAL["trip"]}, {"trip": {"legs": [], "summary": {}}}]})
    two = [{"lat": 1, "lon": 1}, {"lat": 2, "lon": 2}]
    result = valhalla.route(two, alternates=2, directions=True)
    assert sent[0]["alternates"] == 2 and len(result["alternates"]) == 1 and result["alternates"][0]["maneuvers"]                # the empty one was dropped
    valhalla.route(two + [{"lat": 3, "lon": 3}], alternates=2)
    assert "alternates" not in sent[1]
