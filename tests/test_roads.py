"""The Roads layer: the road database (app/roads.py), building it from a map file (app/roads_build.py), the ridden / not-ridden marking, and GET /api/v1/roads."""
from pathlib import Path

import pytest

from app import extras, roads, valhalla
from app.config import settings
from app.db import get_db
from conftest import ALICE, BOB, add_ride
from test_track import insert_points
from trackgen import LAT0, LON0, make_rows, road_coords

TWISTY = [("straight", 150)] + [("turn", 60, 70 if i % 2 else -70) for i in range(18)] + [("straight", 150)]
NORTH_OF_ZURICH = (LAT0, LON0)                 # the synthetic rides start here and drive north
BOX = dict(south=47.39, west=8.55, north=47.45, east=8.65)                  # holds the twisty ways (47.40 / 47.41, 8.60)
RIDE_BOX = dict(south=47.37, west=8.53, north=47.40, east=8.55)             # holds the straight way along the synthetic ride


@pytest.fixture
def road_db(tmp_path, monkeypatch):
    target = tmp_path / "roads.db"
    conn = roads.create(target)
    assert roads.add_way(conn, 111, {"highway": "secondary", "name": "Kurvenstrasse", "ref": "7", "maxspeed": "80"}, road_coords(TWISTY, spacing=12, lat0=47.40, lon0=8.60)) >= 1
    assert roads.add_way(conn, 333, {"highway": "unclassified", "surface": "gravel", "name": "Schotterweg"}, road_coords(TWISTY, spacing=12, lat0=47.41, lon0=8.60)) >= 1
    assert roads.add_way(conn, 555, {"highway": "tertiary", "name": "Flachstrasse"}, road_coords([("straight", 2500)], spacing=40, lat0=47.42, lon0=8.60)) >= 1
    assert roads.add_way(conn, 444, {"highway": "motorway"}, road_coords(TWISTY, spacing=12, lat0=47.43, lon0=8.60)) == 0                      # not a road to ride
    assert roads.add_way(conn, 222, {"highway": "tertiary", "name": "Geradeaus"}, road_coords([("straight", 2500)], spacing=40, lat0=LAT0, lon0=LON0)) >= 1
    roads.finish(conn, "test")
    monkeypatch.setattr(settings, "roads_db_path", str(target))
    return target


@pytest.fixture
def matcher(monkeypatch):
    """A map matcher that says every point is on way 222, the straight road along the synthetic rides."""
    state = {"calls": 0, "way": 222, "down": False, "match": True}

    def fake(points):
        state["calls"] += 1
        if state["down"]:
            raise valhalla.ValhallaUnavailable("down")
        if not state["match"]:
            return [None] * len(points)
        return [{"limit_kmh": 50, "road_class": "tertiary", "name": "Geradeaus", "way_id": state["way"], "use": "road"}] * len(points)

    monkeypatch.setattr(settings, "valhalla_url", "http://valhalla.invalid")
    monkeypatch.setattr(valhalla, "match_points", fake)
    return state


def ride_north(owner=ALICE, seconds=150):
    rid = add_ride(owner["sub"], "2026-09-30T08:00:00+00:00")
    insert_points(owner["sub"], rid, make_rows([("drive", seconds, 12)]))
    return rid


def get_roads(client, **params):
    return client.get("/api/v1/roads", params={**BOX, "min_score": 0, **params})


# ------------------------------------------------------------------------------------------------------------------------------ the database --

def test_the_database_keeps_the_roads_to_ride_and_describes_how_it_was_built(road_db):
    info = roads.info()
    assert info["segments"] == str(len(roads.query(roads.connect(), 40, 7, 50, 10, 1000, 0, False)[0])) and info["source"] == "test" and info["built_at"].startswith("20")
    names = {r["name"] for r in roads.query(roads.connect(), 40, 7, 50, 10, 1000, 0, False)[0]}
    assert names == {"Kurvenstrasse", "Schotterweg", "Flachstrasse", "Geradeaus"}                         # the motorway is not there


def test_a_box_finds_only_what_is_inside_it_and_most_twisty_road_comes_first(road_db):
    conn = roads.connect()
    found, truncated = roads.query(conn, 47.39, 8.55, 47.45, 8.65, 50, 0, False)
    assert [r["name"] for r in found][:2] in (["Kurvenstrasse", "Schotterweg"], ["Schotterweg", "Kurvenstrasse"]) and not truncated
    assert "Geradeaus" not in {r["name"] for r in found}                                                    # outside the box
    assert all(a["curvy_m"] >= b["curvy_m"] for a, b in zip(found, found[1:]))
    road = next(r for r in found if r["name"] == "Kurvenstrasse")
    assert road["way_id"] == 111 and road["ref"] == "7" and road["highway"] == "secondary" and road["maxspeed"] == 80 and road["paved"] is True
    assert road["score"] >= 60 and road["length_m"] > 800 and len(road["geometry"]) > 20 and set(road) >= {"id", "curvy_m", "surface"}
    assert roads.query(conn, 47.0, 7.0, 47.1, 7.1, 50, 0, False) == ([], False)


def test_a_long_twisty_road_outranks_a_short_stretch_with_a_higher_score(tmp_path, monkeypatch):
    """The score is how bendy a stretch is per metre; the ranking is by how much bendy road there is, or a 300 m piece with one hairpin would beat a pass."""
    conn = roads.create(tmp_path / "roads.db")
    short = [("straight", 20)] + [("turn", 60, 70 if i % 2 else -70) for i in range(5)] + [("straight", 20)]
    long = [("straight", 250), ("turn", 70, 90), ("straight", 250), ("turn", 70, -90), ("straight", 250), ("turn", 70, 90), ("straight", 250)]
    roads.add_way(conn, 1, {"highway": "tertiary", "name": "Kurzer Hairpin"}, road_coords(short, spacing=12, lat0=47.40, lon0=8.60))
    roads.add_way(conn, 2, {"highway": "tertiary", "name": "Langer Pass"}, road_coords(long, spacing=12, lat0=47.41, lon0=8.60))
    roads.finish(conn, "test")
    monkeypatch.setattr(settings, "roads_db_path", str(tmp_path / "roads.db"))
    found, _ = roads.query(roads.connect(), 47.39, 8.55, 47.45, 8.65, 10, 0, False)
    by_name = {r["name"]: r for r in found}
    assert by_name["Kurzer Hairpin"]["score"] > by_name["Langer Pass"]["score"] and by_name["Kurzer Hairpin"]["curvy_m"] < by_name["Langer Pass"]["curvy_m"]       # the set-up
    assert [r["name"] for r in found] == ["Langer Pass", "Kurzer Hairpin"]


def test_score_surface_and_limit_filters(road_db):
    conn = roads.connect()
    everything, _ = roads.query(conn, 47.39, 8.55, 47.45, 8.65, 50, 0, False)
    assert {r["name"] for r in everything} == {"Kurvenstrasse", "Schotterweg", "Flachstrasse"}
    assert {r["name"] for r in roads.query(conn, 47.39, 8.55, 47.45, 8.65, 50, 30, False)[0]} == {"Kurvenstrasse", "Schotterweg"}        # the straight road scores 0
    assert {r["name"] for r in roads.query(conn, 47.39, 8.55, 47.45, 8.65, 50, 30, True)[0]} == {"Kurvenstrasse"}                    # and gravel is not paved
    found, truncated = roads.query(conn, 47.39, 8.55, 47.45, 8.65, 1, 0, False)
    assert len(found) == 1 and truncated


def test_a_road_database_replaces_the_old_one_whole(tmp_path):
    target = tmp_path / "roads.db"
    conn = roads.create(target)
    roads.add_way(conn, 1, {"highway": "tertiary"}, road_coords(TWISTY, spacing=12))
    roads.finish(conn, "first")
    conn = roads.create(target)
    roads.finish(conn, "second")
    import sqlite3
    check = sqlite3.connect(target)
    assert check.execute("SELECT COUNT(*) FROM segments").fetchone()[0] == 0 and dict(check.execute("SELECT key, value FROM meta").fetchall())["source"] == "second"


def test_a_map_file_becomes_a_road_database(tmp_path):
    pytest.importorskip("osmium")
    from app import roads_build
    coords = road_coords(TWISTY, spacing=12, lat0=47.40, lon0=8.60)
    nodes = "".join(f'<node id="{i + 1}" lat="{lat:.7f}" lon="{lon:.7f}"/>' for i, (lat, lon) in enumerate(coords))
    refs = "".join(f'<nd ref="{i + 1}"/>' for i in range(len(coords)))
    xml = (f'<?xml version="1.0"?><osm version="0.6" generator="test">{nodes}'
           f'<way id="900"> {refs}<tag k="highway" v="secondary"/><tag k="name" v="Kurvenstrasse"/><tag k="surface" v="asphalt"/></way>'
           f'<way id="901"> {refs}<tag k="highway" v="motorway"/></way>'
           f'<way id="902"> {refs}<tag k="highway" v="tertiary"/><tag k="access" v="private"/></way></osm>')
    source = tmp_path / "tiny.osm"
    source.write_text(xml)
    target = tmp_path / "built" / "roads.db"
    count = roads_build.build(source, target, progress=lambda *_: None)
    assert count >= 1 and target.is_file() and not (tmp_path / "built" / "roads.db.building").exists()
    import sqlite3
    conn = sqlite3.connect(target)
    conn.row_factory = sqlite3.Row
    rows = conn.execute("SELECT * FROM segments").fetchall()
    assert {r["way_id"] for r in rows} == {900} and rows[0]["name"] == "Kurvenstrasse" and rows[0]["paved"] == 1 and max(r["score"] for r in rows) >= 60
    assert conn.execute("SELECT COUNT(*) FROM segments_rtree").fetchone()[0] == len(rows)


# --------------------------------------------------------------------------------------------------------------------------- ridden flags --

def seed_ways(ride_id, way_id, points):
    conn = get_db()
    conn.executemany("INSERT INTO ride_ways (ride_id, way_id, lat, lon) VALUES (?, ?, ?, ?)", [(ride_id, way_id, lat, lon) for lat, lon in points])
    conn.commit()
    conn.close()


def a_road(way_id=222, n=40):
    return {"way_id": way_id, "geometry": [[47.30 + i * 0.0003, 8.50] for i in range(n)]}            # about 33 m apart, 1.3 km


def test_a_road_counts_as_ridden_when_enough_of_it_has_your_points_on_it(alice):
    rid = add_ride(ALICE["sub"], "2026-09-30T08:00:00+00:00")
    road = a_road()
    conn = get_db()
    try:
        seed_ways(rid, 222, road["geometry"][:25])                                               # most of the line
        assert roads.ridden_flags(conn, ALICE["sub"], [road]) == [True]
    finally:
        conn.close()


def test_riding_only_across_the_end_of_a_road_does_not_count(alice):
    rid = add_ride(ALICE["sub"], "2026-09-30T08:00:00+00:00")
    road = a_road()
    seed_ways(rid, 222, road["geometry"][:8])                                                    # a fifth of it
    conn = get_db()
    try:
        assert roads.ridden_flags(conn, ALICE["sub"], [road]) == [False]
    finally:
        conn.close()


def test_the_same_place_on_another_road_or_far_from_the_line_does_not_count(alice):
    rid = add_ride(ALICE["sub"], "2026-09-30T08:00:00+00:00")
    road = a_road()
    seed_ways(rid, 999, road["geometry"])                                                        # right place, a different OpenStreetMap road (a bridge over it)
    seed_ways(rid, 222, [[lat, 8.5015] for lat, _ in road["geometry"]])                          # the right road id but 110 m away
    conn = get_db()
    try:
        assert roads.ridden_flags(conn, ALICE["sub"], [road]) == [False]
        assert roads.ridden_flags(conn, ALICE["sub"], []) == []
    finally:
        conn.close()


def test_other_peoples_rides_never_mark_your_roads(alice, bob):
    theirs = add_ride(BOB["sub"], "2026-09-30T08:00:00+00:00")
    road = a_road()
    seed_ways(theirs, 222, road["geometry"])
    conn = get_db()
    try:
        assert roads.ridden_flags(conn, ALICE["sub"], [road]) == [False]
        assert roads.ridden_flags(conn, BOB["sub"], [road]) == [True]
    finally:
        conn.close()


def test_matched_points_are_thinned_to_one_every_forty_metres_per_road():
    points = [{"lat": 47.0 + i * 0.00001, "lon": 8.0} for i in range(200)]                       # 1.1 m apart, 220 m in all
    matches = [{"way_id": 5}] * 100 + [None] * 20 + [{"way_id": 6}] * 50 + [{"limit_kmh": 50}] * 30
    kept = extras.ways_from_matches(points, matches)
    assert [w for w, _, _ in kept].count(5) == 3 and [w for w, _, _ in kept].count(6) == 2 and {w for w, _, _ in kept} == {5, 6}        # unmatched and id-less points are skipped
    assert kept[0] == (5, 47.0, 8.0)


# ------------------------------------------------------------------------------------------------------------------------------------ the API --

def test_without_a_road_database_the_layer_says_so(alice):
    body = get_roads(alice).json()
    assert body["status"] == "not_built" and body["roads"] == [] and "OpenStreetMap" in body["attribution"] and body["api"] == 1


def test_the_box_is_checked(alice, anon, road_db):
    assert anon.get("/api/v1/roads", params=BOX).status_code == 401
    assert alice.get("/api/v1/roads").status_code == 422
    assert alice.get("/api/v1/roads", params={**BOX, "south": 47.5, "north": 47.4}).status_code == 422
    assert alice.get("/api/v1/roads", params={**BOX, "south": 46.0, "north": 47.5}).status_code == 422             # more than a degree tall
    assert alice.get("/api/v1/roads", params={**BOX, "west": 7.0, "east": 8.7}).status_code == 422                 # more than a degree and a half wide
    assert alice.get("/api/v1/roads", params={**BOX, "limit": 1000}).status_code == 422
    assert alice.get("/api/v1/roads", params={**BOX, "min_score": 101}).status_code == 422


def test_roads_come_back_best_first_with_their_shape(alice, road_db):
    body = get_roads(alice, min_score=30).json()
    assert body["status"] == "ok" and body["truncated"] is False
    assert [r["name"] for r in body["roads"]] == ["Kurvenstrasse"] or {r["name"] for r in body["roads"]} == {"Kurvenstrasse"}        # gravel is left out by default
    assert get_roads(alice, min_score=30, paved_only="false").json()["roads"].__len__() > len(body["roads"])
    assert get_roads(alice, limit=1).json()["truncated"] is True
    road = body["roads"][0]
    assert isinstance(road["geometry"][0][0], float) and road["ridden"] in (True, False, None)


def test_without_the_map_matcher_ridden_is_unknown_not_false(alice, road_db):
    ride_north()
    body = get_roads(alice, min_score=30).json()
    assert body["ridden_status"] == "unavailable" and all(r["ridden"] is None for r in body["roads"]) and body["roads"]


def test_your_rides_are_matched_in_the_background_and_the_next_look_shows_what_you_have_ridden(alice, road_db, matcher):
    ride_north()
    first = alice.get("/api/v1/roads", params={**RIDE_BOX, "min_score": 0}).json()
    assert first["ridden_status"] == "updating" and first["pending_rides"] == 1 and [r["name"] for r in first["roads"]] == ["Geradeaus", "Geradeaus"]    # 2.5 km: two stretches
    assert [r["ridden"] for r in first["roads"]] == [False, False]                                       # not known yet
    second = alice.get("/api/v1/roads", params={**RIDE_BOX, "min_score": 0}).json()
    assert second["ridden_status"] == "ok" and second["pending_rides"] == 0
    assert [r["ridden"] for r in second["roads"]] == [True, False]                                       # the 1.8 km ride covers the first stretch whole and 44% of the second
    assert matcher["calls"] == 1                                                                           # matched once, then remembered


def test_someone_elses_ride_does_not_mark_your_roads_and_does_not_make_you_wait(alice, bob, road_db, matcher):
    ride_north(ALICE)
    alice.get("/api/v1/roads", params={**RIDE_BOX, "min_score": 0})
    alice.get("/api/v1/roads", params={**RIDE_BOX, "min_score": 0})
    mine = bob.get("/api/v1/roads", params={**RIDE_BOX, "min_score": 0}).json()
    assert mine["ridden_status"] == "ok" and mine["pending_rides"] == 0 and mine["roads"][0]["ridden"] is False


def test_a_ride_the_matcher_cannot_place_is_not_tried_again_and_again(alice, road_db, matcher):
    matcher["match"] = False
    ride_north()
    alice.get("/api/v1/roads", params={**RIDE_BOX, "min_score": 0})
    body = alice.get("/api/v1/roads", params={**RIDE_BOX, "min_score": 0}).json()
    assert body["ridden_status"] == "ok" and body["roads"][0]["ridden"] is False and matcher["calls"] == 1


def test_when_the_matcher_is_down_the_catch_up_stops_and_tries_again_next_time(alice, road_db, matcher):
    matcher["down"] = True
    ride_north()
    ride_north(seconds=120)
    first = alice.get("/api/v1/roads", params={**RIDE_BOX, "min_score": 0}).json()
    assert first["ridden_status"] == "updating" and matcher["calls"] == 1                                    # it gave up at the first failure
    matcher["down"] = False
    alice.get("/api/v1/roads", params={**RIDE_BOX, "min_score": 0})
    assert alice.get("/api/v1/roads", params={**RIDE_BOX, "min_score": 0}).json()["roads"][0]["ridden"] is True


def test_a_ride_with_no_usable_points_does_not_stay_pending_forever(alice, road_db, matcher):
    add_ride(ALICE["sub"], "2026-09-30T08:00:00+00:00")                                                        # a ride row with no points at all
    alice.get("/api/v1/roads", params={**RIDE_BOX, "min_score": 0})
    assert alice.get("/api/v1/roads", params={**RIDE_BOX, "min_score": 0}).json()["ridden_status"] == "ok" and matcher["calls"] == 0


def test_opening_a_rides_insights_also_remembers_its_roads(alice, road_db, matcher):
    rid = ride_north()
    alice.get(f"/api/v1/rides/{rid}/insights")
    conn = get_db()
    assert conn.execute("SELECT COUNT(*) FROM ride_ways WHERE ride_id = ? AND way_id = 222", (rid,)).fetchone()[0] >= 20
    conn.close()
    body = alice.get("/api/v1/roads", params={**RIDE_BOX, "min_score": 0}).json()
    assert body["ridden_status"] == "ok" and body["roads"][0]["ridden"] is True and matcher["calls"] == 1


def test_a_ride_matched_before_the_roads_layer_existed_is_picked_up_without_matching_again(alice, road_db, matcher):
    rid = ride_north()
    alice.get(f"/api/v1/rides/{rid}/insights")
    conn = get_db()
    conn.execute("DELETE FROM ride_extras WHERE kind = 'ways'")
    conn.execute("DELETE FROM ride_ways")
    conn.commit()
    conn.close()
    alice.get("/api/v1/roads", params={**RIDE_BOX, "min_score": 0})                                           # background catch-up reads the saved match
    body = alice.get("/api/v1/roads", params={**RIDE_BOX, "min_score": 0}).json()
    assert body["roads"][0]["ridden"] is True and matcher["calls"] == 1


def test_deleting_a_ride_forgets_its_roads(alice, road_db, matcher):
    rid = ride_north()
    alice.get(f"/api/v1/rides/{rid}/insights")
    assert alice.delete(f"/api/v1/rides/{rid}", headers={"X-RideLog-Client": "1"}).status_code == 200
    conn = get_db()
    assert conn.execute("SELECT COUNT(*) FROM ride_ways").fetchone()[0] == 0
    conn.close()
    assert alice.get("/api/v1/roads", params={**RIDE_BOX, "min_score": 0}).json()["roads"][0]["ridden"] is False
