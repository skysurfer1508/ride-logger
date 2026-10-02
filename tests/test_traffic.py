"""app/traffic.py and /api/v1/traffic/*. The network is always faked; the DATEX II sample is hand-written (tests/data/datex_sample.xml), not a real capture."""
from datetime import datetime, timezone
from pathlib import Path

import httpx
import pytest

from app import tmc, traffic
from app.config import settings
from conftest import ALICE

SAMPLE = (Path(__file__).parent / "data" / "datex_sample.xml").read_bytes()
ZURICH = (47.3769, 8.5417)
NOW = datetime(2026, 10, 2, 9, 0, tzinfo=timezone.utc)                  # what the sample's validity times are written against
LOC = {"7.5": {"1001": (47.36, 8.50), "1002": (47.38, 8.52)}, "7.4": {}}
WINDY_JSON = {"webcams": [
    {"webcamId": 111, "title": "Hardbrucke", "location": {"latitude": 47.3869, "longitude": 8.5217},
     "images": {"current": {"preview": "https://img.example/111.jpg"}}, "urls": {"detail": "https://windy.example/111"},
     "player": {"live": "https://player.example/111"}},
    {"webcamId": 222, "title": "Far away", "location": {"latitude": 47.5, "longitude": 8.9}, "images": {}, "urls": {}, "player": {}},
    {"webcamId": 333, "title": "No position"},
]}


@pytest.fixture(autouse=True)
def clean(monkeypatch):
    traffic._cache.clear()
    monkeypatch.setattr(traffic, "_now", lambda: NOW)
    monkeypatch.setattr(tmc, "locations", lambda: LOC)
    monkeypatch.setattr(settings, "opentransportdata_api_key", "OTD-SECRET-KEY")
    monkeypatch.setattr(settings, "windy_api_key", "WINDY-SECRET-KEY")


class Resp:
    def __init__(self, status=200, content=b"", payload=None):
        self.status_code, self.content, self._payload = status, content, payload

    def json(self):
        if self._payload is None:
            raise ValueError("no json")
        return self._payload


# --------------------------------------------------------------------------------------------------------------------------- DATEX II --

def read(xml=SAMPLE, locations=None):
    return traffic.parse_datex(xml, now=NOW, locations=LOC if locations is None else locations)


def one_record(record_type, inner="", comments=""):
    """A minimal feed with one record at a known position, for the cases that vary one thing."""
    return (f'<r><situation><situationRecord xsi:type="{record_type}" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">{comments}'
            f'<pointCoordinates><latitude>47</latitude><longitude>8</longitude></pointCoordinates>{inner}</situationRecord></situation></r>').encode()


def description(*values):
    inner = "".join(f'<value lang="{lang}">{text}</value>' for lang, text in values)
    return f'<generalPublicComment><comment><values>{inner}</values></comment><commentType>description</commentType></generalPublicComment>'


def test_the_sample_keeps_exactly_what_a_rider_needs():
    located, unlocated = read()
    by_id = {i["id"]: i for i in located}
    # dropped: S6 released notice, S7 ended, S8 not started, S9 rerouting advice, S10 AbnormalTraffic "other"; S4 has a code its table doesn't know
    assert set(by_id) == {"S1-R1", "S2-R1", "S3-R1", "S5-R1", "S11-R1"} and unlocated == 1
    accident = by_id["S1-R1"]
    assert (accident["kind"], accident["title"], accident["severity"]) == ("accident", "Accident", "high")
    assert accident["comment"] == "Accident on the A1, right lane closed."                      # English chosen over German; the internal note ignored
    assert (accident["lat"], accident["lon"]) == (47.4123, 8.5712)
    assert accident["start"] == "2026-10-02T08:10:00Z" and accident["end"] == "2026-10-02T10:00:00Z"
    jam = by_id["S2-R1"]
    assert (jam["kind"], jam["title"]) == ("congestion", "Queuing traffic")
    assert (jam["lat"], jam["lon"]) == (47.37, 8.51)                                           # the middle of the section's two ends
    assert jam["comment"] == "" and jam["end"] is None
    assert (by_id["S3-R1"]["kind"], by_id["S3-R1"]["title"]) == ("roadworks", "Roadworks")
    assert (by_id["S5-R1"]["kind"], by_id["S5-R1"]["title"]) == ("other", "Traffic event")
    assert (by_id["S11-R1"]["kind"], by_id["S11-R1"]["title"]) == ("closure", "Road closed")


def test_garbage_is_an_error_not_a_crash():
    with pytest.raises(traffic.TrafficUnavailable):
        traffic.parse_datex(b"<html>not the feed")
    assert traffic.parse_datex(b"<a><situation/></a>", now=NOW) == ([], 0)
    assert traffic.parse_datex(b"<a/>", now=NOW) == ([], 0)


def test_a_zero_zero_position_is_not_a_position():
    xml = b'<r><situation><situationRecord id="x"><pointCoordinates><latitude>0</latitude><longitude>0</longitude></pointCoordinates></situationRecord></situation></r>'
    assert traffic.parse_datex(xml, now=NOW) == ([], 1)


@pytest.mark.parametrize("text", ["Freigegeben: A3 Chur", "Libéré: A3 Coire", "Approvato: A3 Chur", "Released: A3 Chur", "  freigegeben: x"])
def test_released_notices_are_dropped_in_every_language(text):
    assert traffic.parse_datex(one_record("Accident", comments=description(("de-CH", text))), now=NOW) == ([], 0)


def test_a_description_that_merely_mentions_released_is_kept():
    assert len(traffic.parse_datex(one_record("Accident", comments=description(("en-EN", "Lane released after the accident"))), now=NOW)[0]) == 1


def test_the_language_falls_back_to_german_then_to_whatever_there_is():
    def chosen(*values):
        return traffic.parse_datex(one_record("Accident", comments=description(*values)), now=NOW)[0][0]["comment"]
    assert chosen(("fr-CH", "fr"), ("de-CH", "de"), ("en-EN", "en")) == "en"
    assert chosen(("fr-CH", "fr"), ("de-CH", "de")) == "de"
    assert chosen(("fr-CH", "fr"), ("it-CH", "it")) == "fr"


def test_the_same_code_is_looked_up_in_the_table_of_its_own_version():
    xml = SAMPLE.replace(b"<alertCLocationTableVersion>7.5</alertCLocationTableVersion>", b"<alertCLocationTableVersion>7.3</alertCLocationTableVersion>")
    other = {"7.3": {"1001": (46.0, 7.0), "1002": (46.0, 7.0)}, "7.5": LOC["7.5"]}
    jam = {i["id"]: i for i in read(xml, other)[0]}["S2-R1"]
    assert (jam["lat"], jam["lon"]) == (46.0, 7.0)
    # a version nobody loaded cannot be used, even if the code exists in another version
    assert "S2-R1" not in {i["id"] for i in read(xml, {"7.5": LOC["7.5"]})[0]}


def test_without_any_location_table_only_records_with_coordinates_are_shown():
    located, unlocated = read(locations={})
    assert {i["id"] for i in located} == {"S1-R1", "S3-R1", "S5-R1", "S11-R1"} and unlocated == 2


def test_a_section_whose_ends_are_far_apart_uses_its_first_end():
    far = {"7.5": {"1001": (47.0, 8.0), "1002": (46.0, 7.0)}}                                  # 130 km apart: more likely a table mix-up than a section
    jam = {i["id"]: i for i in read(locations=far)[0]}["S2-R1"]
    assert (jam["lat"], jam["lon"]) == (47.0, 8.0)


@pytest.mark.parametrize("value,title", [("roadClosed", "Road closed"), ("narrowLanes", "Narrow lanes"), ("singleAlternateLineTraffic", "Single alternate line traffic"),
                                         ("other", "Closure / lane restriction"), ("", "Closure / lane restriction")])
def test_titles_come_from_the_feeds_own_detail(value, title):
    tag = f"<roadOrCarriagewayOrLaneManagementType>{value}</roadOrCarriagewayOrLaneManagementType>" if value else ""
    assert traffic.parse_datex(one_record("RoadOrCarriagewayOrLaneManagement", tag), now=NOW)[0][0]["title"] == title


@pytest.mark.parametrize("jam,title", [("stationaryTraffic", "Stationary traffic"), ("queuingTraffic", "Queuing traffic"), ("slowTraffic", "Slow traffic"), ("heavyTraffic", "Heavy traffic")])
def test_every_real_jam_type_is_shown_with_its_own_title(jam, title):
    assert traffic.parse_datex(one_record("AbnormalTraffic", f"<abnormalTrafficType>{jam}</abnormalTrafficType>"), now=NOW)[0][0]["title"] == title


def test_incidents_near_filters_by_distance_and_sorts(monkeypatch):
    monkeypatch.setattr(traffic, "_post_soap", lambda body: SAMPLE)
    result = traffic.incidents_near(*ZURICH, 25)
    assert [i["id"] for i in result["incidents"]] == ["S5-R1", "S2-R1", "S1-R1", "S11-R1"]    # Bern's roadworks are 90 km away
    assert [i["distance_km"] for i in result["incidents"]] == sorted(i["distance_km"] for i in result["incidents"])
    assert result["unlocated"] == 1 and result["total"] == 5
    assert [i["id"] for i in traffic.incidents_near(46.95, 7.45, 5)["incidents"]] == ["S3-R1"]


def test_a_crowd_of_roadworks_never_pushes_a_jam_out_of_the_answer(monkeypatch):
    """Near Zurich the 100 nearest records are mostly roadworks; a jam further out must still be there (the app hides works by default)."""
    works = "".join(f'<situation><situationRecord xsi:type="MaintenanceWorks" id="W{i}"><pointCoordinates><latitude>{47.3769 + i * 0.0002}</latitude><longitude>8.5417</longitude>'
                    f'</pointCoordinates></situationRecord></situation>' for i in range(300))
    jam = ('<situation><situationRecord xsi:type="AbnormalTraffic" id="JAM"><pointCoordinates><latitude>47.55</latitude><longitude>8.5417</longitude></pointCoordinates>'
           '<abnormalTrafficType>queuingTraffic</abnormalTrafficType></situationRecord></situation>')
    xml = f'<r xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">{works}{jam}</r>'.encode()
    monkeypatch.setattr(traffic, "_post_soap", lambda body: xml)
    result = traffic.incidents_near(*ZURICH, 25)["incidents"]
    assert "JAM" in {i["id"] for i in result}                                         # 19 km away, behind 300 nearer roadworks
    assert sum(1 for i in result if i["kind"] == "roadworks") == traffic.MAX_WORKS
    assert [i["distance_km"] for i in result] == sorted(i["distance_km"] for i in result)


def test_the_feed_is_fetched_once_for_many_requests(monkeypatch):
    calls = []
    monkeypatch.setattr(traffic, "_post_soap", lambda body: calls.append(1) or SAMPLE)
    traffic.incidents_near(*ZURICH, 25)
    traffic.incidents_near(46.95, 7.45, 5)
    assert len(calls) == 1


def test_an_old_answer_is_used_when_the_refresh_fails(monkeypatch):
    monkeypatch.setattr(traffic, "_post_soap", lambda body: SAMPLE)
    traffic.incidents_near(*ZURICH, 25)
    fresh_until, stored, value = traffic._cache["incidents"]
    traffic._cache["incidents"] = (0.0, stored, value)                                         # expired
    def down(body): raise traffic.TrafficUnavailable("down")
    monkeypatch.setattr(traffic, "_post_soap", down)
    assert len(traffic.incidents_near(*ZURICH, 25)["incidents"]) == 4
    traffic._cache.clear()
    with pytest.raises(traffic.TrafficUnavailable):
        traffic.incidents_near(*ZURICH, 25)


def test_the_request_carries_the_key_and_soap_action(monkeypatch):
    seen = {}
    def fake_post(url, content=None, headers=None, timeout=None):
        seen.update(url=url, headers=headers, body=content)
        return Resp(200, SAMPLE)
    monkeypatch.setattr(traffic.httpx, "post", fake_post)
    traffic._post_soap(traffic.INCIDENTS_ENVELOPE)
    assert seen["headers"]["Authorization"] == "OTD-SECRET-KEY"
    assert seen["headers"]["SOAPAction"].endswith("pullTrafficMessages")
    assert seen["url"].endswith("/TrafficSituations/Pull") and b"Envelope" in seen["body"]


@pytest.mark.parametrize("status,words", [(401, "refused the API key"), (403, "refused the API key"), (429, "too many requests"), (503, "(503)")])
def test_http_errors_become_readable_messages_without_the_key(monkeypatch, status, words):
    monkeypatch.setattr(traffic.httpx, "post", lambda *a, **k: Resp(status))
    with pytest.raises(traffic.TrafficUnavailable) as e:
        traffic._post_soap("x")
    assert words in str(e.value) and "OTD-SECRET-KEY" not in str(e.value)


def test_a_network_error_is_unavailable_not_a_crash(monkeypatch):
    def boom(*a, **k): raise httpx.ConnectTimeout("t")
    monkeypatch.setattr(traffic.httpx, "post", boom)
    monkeypatch.setattr(traffic.httpx, "get", boom)
    with pytest.raises(traffic.TrafficUnavailable):
        traffic._post_soap("x")
    with pytest.raises(traffic.TrafficUnavailable):
        traffic._windy_get({})


# ---------------------------------------------------------------------------------------------------------------------------- webcams --

def test_webcams_are_normalised_and_the_broken_one_dropped():
    cams = traffic.parse_webcams(WINDY_JSON, "city")
    assert [c["id"] for c in cams] == ["111", "222"]
    assert cams[0] == {"id": "111", "title": "Hardbrucke", "lat": 47.3869, "lon": 8.5217, "preview": "https://img.example/111.jpg",
                       "detail_url": "https://windy.example/111", "player_url": "https://player.example/111", "category": "city"}
    assert cams[1]["preview"] is None and cams[1]["detail_url"] is None


def test_traffic_and_city_cameras_are_asked_for_separately_and_merged(monkeypatch):
    seen = []
    def fake(params):
        seen.append(dict(params))
        if params["categories"] == "traffic":
            return {"webcams": [{"webcamId": 1, "title": "A1 Gubrist", "location": {"latitude": 47.42, "longitude": 8.45}}]}
        return {"webcams": [{"webcamId": 2, "title": "Sechselaeutenplatz", "location": {"latitude": 47.366, "longitude": 8.54}},
                            {"webcamId": 1, "title": "A1 Gubrist (again)", "location": {"latitude": 47.42, "longitude": 8.45}}]}
    monkeypatch.setattr(traffic, "_windy_get", fake)
    cams = {c["id"]: c for c in traffic.webcams_near(*ZURICH, 15)["webcams"]}
    assert [p["categories"] for p in seen] == ["traffic", "city"]
    assert seen[0]["nearby"] == "47.3769,8.5417,15" and "images" in seen[0]["include"] and "player" in seen[0]["include"]
    assert set(cams) == {"1", "2"}                                                              # the camera in both lists appears once
    assert (cams["1"]["category"], cams["1"]["title"]) == ("traffic", "A1 Gubrist")             # ...with its traffic label
    assert cams["2"]["category"] == "city"


def test_webcams_come_back_nearest_first(monkeypatch):
    monkeypatch.setattr(traffic, "_windy_get", lambda params: WINDY_JSON)
    result = traffic.webcams_near(*ZURICH, 15)
    assert [c["id"] for c in result["webcams"]] == ["111", "222"]
    assert [c["distance_km"] for c in result["webcams"]] == sorted(c["distance_km"] for c in result["webcams"])


def test_an_area_with_no_cameras_is_an_empty_list_not_an_error(monkeypatch):
    monkeypatch.setattr(traffic, "_windy_get", lambda params: {"webcams": []})
    assert traffic.webcams_near(*ZURICH, 15) == {"webcams": []}


def test_a_failure_in_either_request_is_reported(monkeypatch):
    def fake(params):
        if params["categories"] == "city":
            raise traffic.TrafficUnavailable("The webcam service answered with an error (503).")
        return {"webcams": []}
    monkeypatch.setattr(traffic, "_windy_get", fake)
    with pytest.raises(traffic.TrafficUnavailable):
        traffic.webcams_near(*ZURICH, 15)


def test_webcam_answers_are_cached_briefly_per_area(monkeypatch):
    calls = []
    monkeypatch.setattr(traffic, "_windy_get", lambda params: calls.append(1) or WINDY_JSON)
    traffic.webcams_near(*ZURICH, 15)
    assert len(calls) == 2                                              # one request per category
    traffic.webcams_near(47.3771, 8.5419, 15)                          # the same spot to two decimals
    assert len(calls) == 2
    traffic.webcams_near(46.95, 7.45, 15)
    assert len(calls) == 4
    assert traffic.WEBCAMS_TTL_S < 15 * 60                              # Windy's free image links expire after 15 minutes


def test_the_windy_request_carries_the_key_in_the_header_not_the_url(monkeypatch):
    seen = {}
    def fake_get(url, params=None, headers=None, timeout=None):
        seen.update(url=url, params=params, headers=headers)
        return Resp(200, payload=WINDY_JSON)
    monkeypatch.setattr(traffic.httpx, "get", fake_get)
    traffic._windy_get({"nearby": "1,2,3"})
    assert seen["headers"]["x-windy-api-key"] == "WINDY-SECRET-KEY" and "WINDY-SECRET-KEY" not in str(seen["params"]) + seen["url"]


def test_a_rejected_windy_key_is_a_readable_message(monkeypatch):
    monkeypatch.setattr(traffic.httpx, "get", lambda *a, **k: Resp(403))
    with pytest.raises(traffic.TrafficUnavailable) as e:
        traffic._windy_get({})
    assert "WINDY_API_KEY" in str(e.value) and "WINDY-SECRET-KEY" not in str(e.value)


# -------------------------------------------------------------------------------------------------------------------------- the check --

def test_check_traffic_reports_each_source_and_shows_raw_output_when_unreadable(monkeypatch):
    monkeypatch.setattr(traffic, "_post_soap", lambda body: b"<unexpected>format</unexpected>")
    monkeypatch.setattr(traffic, "_windy_get", lambda params: WINDY_JSON)
    text = "\n".join(traffic.check())
    assert "nothing could be read" in text and "<unexpected>format</unexpected>" in text
    assert "webcams: 2 within 25 km" in text and "Hardbrucke" in text and "SECRET" not in text


def test_check_traffic_says_when_a_layer_is_off(monkeypatch):
    monkeypatch.setattr(settings, "opentransportdata_api_key", "")
    monkeypatch.setattr(settings, "windy_api_key", " ")
    text = "\n".join(traffic.check())
    assert "OPENTRANSPORTDATA_API_KEY is empty" in text and "WINDY_API_KEY is empty" in text


# ------------------------------------------------------------------------------------------------------------------------- the endpoints --

def test_traffic_endpoints_need_a_login(anon):
    for path in ("/api/v1/traffic/config", "/api/v1/traffic/incidents?lat=47&lon=8", "/api/v1/traffic/webcams?lat=47&lon=8"):
        assert anon.get(path).status_code == 401


def test_config_tells_the_app_which_layers_exist(alice, monkeypatch):
    assert alice.get("/api/v1/traffic/config").json() == {"api": 1, "incidents": True, "webcams": True}
    monkeypatch.setattr(settings, "windy_api_key", "")
    assert alice.get("/api/v1/traffic/config").json()["webcams"] is False


def test_incidents_endpoint(alice, monkeypatch):
    monkeypatch.setattr(traffic, "_post_soap", lambda body: SAMPLE)
    body = alice.get("/api/v1/traffic/incidents?lat=47.3769&lon=8.5417&radius_km=25").json()
    assert body["api"] == 1 and len(body["incidents"]) == 4 and body["unlocated"] == 1
    assert body["incidents"][0]["distance_km"] <= body["incidents"][-1]["distance_km"]


def test_webcams_endpoint(alice, monkeypatch):
    monkeypatch.setattr(traffic, "_windy_get", lambda params: WINDY_JSON)
    body = alice.get("/api/v1/traffic/webcams?lat=47.3769&lon=8.5417").json()
    assert [c["id"] for c in body["webcams"]] == ["111", "222"]


def test_a_layer_without_a_key_is_a_404_not_an_error(alice, monkeypatch):
    monkeypatch.setattr(settings, "windy_api_key", "")
    monkeypatch.setattr(settings, "opentransportdata_api_key", "")
    assert alice.get("/api/v1/traffic/webcams?lat=47&lon=8").status_code == 404
    assert alice.get("/api/v1/traffic/incidents?lat=47&lon=8").json() == {"detail": "not_configured"}


def test_a_failing_source_is_a_502_with_a_message_the_app_can_show(alice, monkeypatch):
    def down(body): raise traffic.TrafficUnavailable("The Swiss traffic service could not be reached.")
    monkeypatch.setattr(traffic, "_post_soap", down)
    r = alice.get("/api/v1/traffic/incidents?lat=47&lon=8")
    assert r.status_code == 502
    assert r.json()["detail"] == {"detail": "traffic_unavailable", "message": "The Swiss traffic service could not be reached."}


@pytest.mark.parametrize("query", ["lat=91&lon=8", "lat=47&lon=181", "lat=47", "lat=47&lon=8&radius_km=0", "lat=47&lon=8&radius_km=500"])
def test_bad_coordinates_and_radii_are_rejected(alice, query):
    assert alice.get(f"/api/v1/traffic/incidents?{query}").status_code == 422
    assert alice.get(f"/api/v1/traffic/webcams?{query}").status_code in (422,)
