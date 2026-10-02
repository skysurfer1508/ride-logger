"""app/gpx.py, GET /api/v1/rides/{id}/gpx and POST /api/v1/import/gpx."""
import xml.etree.ElementTree as ET
from datetime import datetime, timedelta, timezone

import pytest

from app import gpx
from app.db import get_db
from conftest import ALICE, BOB, add_ride
from test_track import RED_LIGHT, insert_points
from trackgen import LAT0, LON0, M_PER_DEG_LAT, make_rows

CLIENT = {"X-RideLog-Client": "1"}
NS = {"g": "http://www.topografix.com/GPX/1/1", "rl": gpx.RIDELOG_NS}


def gpx_xml(points, name="Evening loop", extra_tracks="", ext=False):
    """A GPX file like another app writes it. points: (lat, lon, time or None, ele or None, speed or None)."""
    def pt(p):
        lat, lon, time, ele, speed = p
        inner = (f"<ele>{ele}</ele>" if ele is not None else "") + (f"<time>{time}</time>" if time else "")
        if speed is not None:
            inner += f"<extensions><gpxtpx:TrackPointExtension xmlns:gpxtpx='x'><gpxtpx:speed>{speed}</gpxtpx:speed></gpxtpx:TrackPointExtension></extensions>"
        return f'<trkpt lat="{lat}" lon="{lon}">{inner}</trkpt>'
    return (f'<?xml version="1.0"?><gpx version="1.1" creator="Strava" xmlns="http://www.topografix.com/GPX/1/1">'
            f'<trk><name>{name}</name><trkseg>{"".join(pt(p) for p in points)}</trkseg></trk>{extra_tracks}</gpx>').encode()


def straight(n=60, step=5, mps=10.0, start="2026-09-20T07:00:00Z", north0=0.0, ele=None, speed=None):
    t0 = datetime.fromisoformat(start.replace("Z", "+00:00"))
    return [(round(LAT0 + (north0 + mps * step * i) / M_PER_DEG_LAT, 6), LON0, (t0 + timedelta(seconds=step * i)).strftime("%Y-%m-%dT%H:%M:%SZ"),
             ele, speed) for i in range(n)]


def upload(client, data, name="ride.gpx", headers=CLIENT):
    return client.post("/api/v1/import/gpx", files={"file": (name, data, "application/gpx+xml")}, headers=headers)


def rides_of(owner):
    conn = get_db()
    try:
        return [dict(r) for r in conn.execute("SELECT * FROM rides WHERE owner_sub = ? ORDER BY id", (owner,)).fetchall()]
    finally:
        conn.close()


def count_points(owner):
    conn = get_db()
    try:
        return conn.execute("SELECT COUNT(*) FROM points WHERE owner_sub = ?", (owner,)).fetchone()[0]
    finally:
        conn.close()


# -------------------------------------------------------------------------------------------------------------------------------- export --

def test_the_export_is_valid_gpx_with_every_point(alice):
    rid = add_ride(ALICE["sub"], "2026-09-30T08:00:00+00:00")
    rows = make_rows(RED_LIGHT)
    insert_points(ALICE["sub"], rid, rows)
    r = alice.get(f"/api/v1/rides/{rid}/gpx")
    assert r.status_code == 200 and r.headers["content-type"].startswith("application/gpx+xml")
    assert r.headers["content-disposition"] == 'attachment; filename="ridelog-20260930-0800.gpx"'
    root = ET.fromstring(r.content)
    pts = root.findall(".//g:trkpt", NS)
    assert len(pts) == len(rows) and root.attrib["version"] == "1.1"
    first = pts[0]
    assert first.find("g:time", NS).text == "2026-09-30T08:00:00Z"
    assert first.find("g:ele", NS) is not None and first.find("g:extensions/rl:speed", NS) is not None
    assert root.find("g:trk/g:name", NS).text == "RideLog 2026-09-30 08:00"


def test_the_export_escapes_the_name_and_survives_missing_values():
    rows = [{"lat": 47.0, "lon": 8.0, "timestamp": "2026-09-30T08:00:00Z", "speed": None, "altitude": None, "horizontal_accuracy": None},
            {"lat": 47.0001, "lon": 8.0, "timestamp": "2026-09-30T08:00:05+00:00", "speed": -1.0, "altitude": 400.0, "horizontal_accuracy": 5.0}]
    root = ET.fromstring(gpx.build_gpx(rows, 'A & B <"x">'))
    assert root.find("g:trk/g:name", NS).text == 'A & B <"x">'
    p0, p1 = root.findall(".//g:trkpt", NS)
    assert p0.find("g:ele", NS) is None and p0.find("g:extensions", NS) is None
    assert p1.find("g:extensions/rl:speed", NS) is None and p1.find("g:extensions/rl:hacc", NS).text == "5.0"      # an unknown speed is not exported


def test_export_of_someone_elses_ride_is_a_404_and_needs_a_login(alice, anon, bob):
    theirs = add_ride(BOB["sub"], "2026-09-30T08:00:00+00:00")
    insert_points(BOB["sub"], theirs, make_rows(RED_LIGHT))
    assert alice.get(f"/api/v1/rides/{theirs}/gpx").status_code == 404
    assert alice.get("/api/v1/rides/99999/gpx").status_code == 404
    assert anon.get(f"/api/v1/rides/{theirs}/gpx").status_code == 401


# -------------------------------------------------------------------------------------------------------------------------------- import --

def test_a_ride_exported_by_one_user_imports_for_another_with_the_same_numbers(alice, bob):
    rid = add_ride(ALICE["sub"], "2026-09-30T08:00:00+00:00")
    insert_points(ALICE["sub"], rid, make_rows(RED_LIGHT))
    original = alice.get(f"/api/v1/rides/{rid}/track").json()
    exported = alice.get(f"/api/v1/rides/{rid}/gpx").content
    r = upload(bob, exported)
    assert r.status_code == 200 and r.json()["imported"] == 1
    (ride,) = rides_of(BOB["sub"])
    assert ride["device_id"] == "gpx-import" and ride["source"] == "trip_marker" and ride["trip_id"].startswith("gpx-")
    copy = bob.get(f"/api/v1/rides/{ride['id']}/track").json()
    assert copy["point_count"] == original["point_count"]
    assert copy["distance_m"] == pytest.approx(original["distance_m"], rel=0.01)
    assert copy["duration_s"] == original["duration_s"]
    assert copy["max_speed"]["mps"] == pytest.approx(original["max_speed"]["mps"], abs=0.1)
    assert len(copy["stops"]) == len(original["stops"]) == 1                                  # the red light survives the round trip


def test_importing_your_own_export_does_not_duplicate_the_ride(alice):
    rid = add_ride(ALICE["sub"], "2026-09-30T08:00:00+00:00")
    insert_points(ALICE["sub"], rid, make_rows(RED_LIGHT))
    before = count_points(ALICE["sub"])
    r = upload(alice, alice.get(f"/api/v1/rides/{rid}/gpx").content)
    assert r.json()["results"][0]["status"] == "already_have_this_ride" and r.json()["imported"] == 0
    assert count_points(ALICE["sub"]) == before and len(rides_of(ALICE["sub"])) == 1


def test_a_file_from_another_app_without_speeds_gets_speeds_worked_out(alice):
    r = upload(alice, gpx_xml(straight(mps=12.0, ele=410.5)))
    assert r.status_code == 200 and r.json()["imported"] == 1
    (ride,) = rides_of(ALICE["sub"])
    assert ride["distance_m"] == pytest.approx(59 * 5 * 12.0, rel=0.01) and ride["duration_s"] == 59 * 5
    assert ride["max_speed_mps"] == pytest.approx(12.0, abs=0.3)                                # worked out from positions, not 0
    track = alice.get(f"/api/v1/rides/{ride['id']}/track").json()
    assert len(track["points"]) == 60 and track["points"][5][3] == pytest.approx(12.0, abs=0.3) and track["points"][0][4] == 410


def test_speeds_in_the_file_are_used_when_present(alice):
    upload(alice, gpx_xml(straight(mps=12.0, speed=9.5)))
    (ride,) = rides_of(ALICE["sub"])
    assert ride["max_speed_mps"] == pytest.approx(9.5)


def test_the_same_file_twice_is_recognised(alice):
    data = gpx_xml(straight())
    assert upload(alice, data).json()["results"][0]["status"] == "imported"
    again = upload(alice, data).json()
    assert again["results"][0]["status"] == "already_imported" and again["imported"] == 0
    assert len(rides_of(ALICE["sub"])) == 1 and count_points(ALICE["sub"]) == 60


def test_two_people_can_import_the_same_file_each_getting_their_own_ride(alice, bob):
    data = gpx_xml(straight())
    assert upload(alice, data).json()["imported"] == 1
    assert upload(bob, data).json()["imported"] == 1
    assert rides_of(ALICE["sub"])[0]["trip_id"] != rides_of(BOB["sub"])[0]["trip_id"]
    assert len(rides_of(ALICE["sub"])) == len(rides_of(BOB["sub"])) == 1


def test_a_file_with_two_tracks_makes_two_rides(alice):
    second = gpx_xml(straight(start="2026-09-21T07:00:00Z")).decode().split("<trk>", 1)[1].rsplit("</gpx>", 1)[0]
    r = upload(alice, gpx_xml(straight(), extra_tracks="<trk>" + second))
    assert r.json()["imported"] == 2 and len(rides_of(ALICE["sub"])) == 2


def test_the_imported_ride_shows_up_everywhere_a_ride_does(alice):
    upload(alice, gpx_xml(straight()))
    assert alice.get("/api/v1/home").json()["ride_count"] == 1
    assert len(alice.get("/api/v1/rides").json()["rides"]) == 1
    assert alice.get("/api/v1/overview").json()["ride_count"] == 1


def test_a_track_that_does_not_move_is_skipped_and_leaves_nothing_behind(alice):
    still = [(LAT0, LON0, f"2026-09-20T07:00:{s:02d}Z", None, None) for s in range(0, 40, 5)]
    r = upload(alice, gpx_xml(still))
    result = r.json()["results"][0]
    assert result["status"] == "skipped" and result["reason"] == "The track has no movement." and r.json()["imported"] == 0
    assert count_points(ALICE["sub"]) == 0 and rides_of(ALICE["sub"]) == []


@pytest.mark.parametrize("data,words", [
    (b"not xml at all", "not a readable GPX"),
    (b"<html><body/></html>", "not a GPX file"),
    (b'<gpx xmlns="http://www.topografix.com/GPX/1/1"/>', "no track"),
    (b'<!DOCTYPE gpx [<!ENTITY x "boom">]><gpx><trk/></gpx>', "DOCTYPE or ENTITY"),
    (b'<?xml version="1.0"?><!doctype gpx SYSTEM "http://evil.example/x.dtd"><gpx/>', "DOCTYPE or ENTITY"),
])
def test_unusable_files_are_refused_with_a_readable_message(alice, data, words):
    r = upload(alice, data)
    assert r.status_code == 400 and words in r.json()["detail"]["message"] and r.json()["detail"]["detail"] == "gpx_invalid"
    assert rides_of(ALICE["sub"]) == []


def test_a_track_without_timestamps_is_refused(alice):
    r = upload(alice, gpx_xml([(LAT0 + i * 0.0001, LON0, None, None, None) for i in range(10)]))
    assert r.status_code == 400 and "no timestamps" in r.json()["detail"]["message"]


def test_a_file_that_is_too_large_is_refused(alice, monkeypatch):
    monkeypatch.setattr(gpx, "MAX_BYTES", 1000)
    r = upload(alice, gpx_xml(straight(n=60)))
    assert r.status_code == 413 and "larger than" in r.json()["detail"]["message"]


def test_import_needs_the_client_header_and_a_login(alice, anon):
    data = gpx_xml(straight())
    assert upload(alice, data, headers={}).status_code == 403
    assert upload(anon, data).status_code == 401
    assert rides_of(ALICE["sub"]) == []


# ------------------------------------------------------------------------------------------------------------------------------- parsing --

def test_bad_coordinates_are_dropped_unsorted_times_sorted_repeated_times_removed():
    pts = straight(n=6)
    pts[2] = (95.0, LON0, pts[2][2], None, None)                          # latitude out of range
    scrambled = [pts[4], pts[0], pts[1], pts[5], pts[3], pts[3]]          # out of order, and one repeated
    (track,) = gpx.parse_gpx(gpx_xml(scrambled))
    times = [p["time"] for p in track["points"]]
    assert times == sorted(times) and len(set(times)) == len(times) == 5
    assert all(-90 <= p["lat"] <= 90 for p in track["points"])


def test_absurd_or_negative_speeds_in_the_file_are_ignored():
    pts = straight(n=4, speed=999)
    assert all(p["speed"] is None for p in gpx.parse_gpx(gpx_xml(pts))[0]["points"])
    assert all(p["speed"] is None for p in gpx.parse_gpx(gpx_xml(straight(n=4, speed=-3)))[0]["points"])
    assert [p["speed"] for p in gpx.parse_gpx(gpx_xml(straight(n=4, speed=7.5)))[0]["points"]] == [7.5] * 4


def test_the_trip_id_is_stable_per_person_and_differs_between_people():
    (track,) = gpx.parse_gpx(gpx_xml(straight()))
    a = gpx.import_id("alice", track["points"])
    assert a == gpx.import_id("alice", track["points"]) and a != gpx.import_id("bob", track["points"]) and a.startswith("gpx-")


def test_the_time_zone_offset_in_a_file_is_converted_to_utc():
    pts = [(LAT0, LON0, "2026-09-20T09:00:00+02:00", None, None), (LAT0 + 0.001, LON0, "2026-09-20T09:00:10+02:00", None, None)]
    (track,) = gpx.parse_gpx(gpx_xml(pts))
    assert track["points"][0]["time"] == datetime(2026, 9, 20, 7, 0, 0, tzinfo=timezone.utc)
