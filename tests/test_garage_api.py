"""/api/v1/garage/*, the garage tables and the rides.bike_id migration."""
import sqlite3
from datetime import date

import pytest

from app import db as db_module
from app.config import settings
from app.db import get_db
from app.routers import api_garage
from conftest import ALICE, BOB, add_ride

CLIENT = {"X-RideLog-Client": "1"}
TODAY = date(2026, 10, 2)


@pytest.fixture(autouse=True)
def fixed_today(monkeypatch):
    monkeypatch.setattr(api_garage, "_today", lambda: TODAY)


def new_bike(client, name="Tuono", **extra):
    data = {"name": name, "start_odometer_km": "10000", "start_date": "2026-01-01", **extra}
    r = client.post("/api/v1/garage/bikes", data=data, headers=CLIENT)
    assert r.status_code == 200, r.text
    return r.json()["bike_id"]


def detail(client, bike_id):
    r = client.get(f"/api/v1/garage/bikes/{bike_id}")
    assert r.status_code == 200
    return r.json()


def message(response):
    assert response.status_code == 400
    return response.json()["detail"]["message"]


# ---------------------------------------------------------------------------------------------------------------------------- access --

def test_logged_out_is_a_401_and_changes_need_the_header(anon, alice):
    assert anon.get("/api/v1/garage").status_code == 401
    assert anon.post("/api/v1/garage/bikes", data={"name": "x"}, headers=CLIENT).status_code == 401
    assert alice.post("/api/v1/garage/bikes", data={"name": "x"}).status_code == 403
    bike = new_bike(alice)
    assert alice.delete(f"/api/v1/garage/bikes/{bike}").status_code == 403


def test_a_new_account_has_an_empty_garage(alice):
    assert alice.get("/api/v1/garage").json() == {"api": 1, "bikes": []}


# ---------------------------------------------------------------------------------------------------------------------------- bikes --

def test_the_first_bike_becomes_the_default_and_the_second_does_not(alice):
    first, second = new_bike(alice, "Tuono"), new_bike(alice, "Monster")
    bikes = {b["id"]: b for b in alice.get("/api/v1/garage").json()["bikes"]}
    assert bikes[first]["is_default"] and not bikes[second]["is_default"]
    assert [b["id"] for b in alice.get("/api/v1/garage").json()["bikes"]][0] == first                 # the default is listed first


def test_bike_details_are_saved_and_can_be_edited(alice):
    bike = new_bike(alice, "  Tuono V4  ", make="Aprilia", model="1100 RR", year="2021")
    d = detail(alice, bike)["bike"]
    assert (d["name"], d["make"], d["model"], d["year"], d["start_odometer_km"], d["odometer_km"]) == ("Tuono V4", "Aprilia", "1100 RR", 2021, 10000, 10000)
    r = alice.post(f"/api/v1/garage/bikes/{bike}", data={"name": "Tuono", "make": "Aprilia", "model": "Factory", "year": ""}, headers=CLIENT)
    assert r.status_code == 200 and r.json()["bike"]["model"] == "Factory" and r.json()["bike"]["year"] is None


@pytest.mark.parametrize("data,words", [
    ({"name": ""}, "enter a name"),
    ({"name": "x" * 61}, "too long"),
    ({"name": "a", "year": "1800"}, "between 1900 and 2100"),
    ({"name": "a", "year": "2020.5"}, "whole number"),
    ({"name": "a", "start_odometer_km": "-5"}, "between 0"),
    ({"name": "a", "start_odometer_km": "abc"}, "must be a number"),
    ({"name": "a", "start_odometer_km": "nan"}, "between 0"),
    ({"name": "a", "start_date": "yesterday"}, "2026-09-28"),
    ({"name": "a", "start_date": "2030-01-01"}, "cannot be in the future"),
])
def test_mistakes_in_a_new_bike_get_a_sentence(alice, data, words):
    r = alice.post("/api/v1/garage/bikes", data={"start_odometer_km": "0", **data}, headers=CLIENT)
    assert words in message(r)
    assert alice.get("/api/v1/garage").json()["bikes"] == []


def test_a_comma_works_as_the_decimal_mark(alice):
    bike = new_bike(alice, start_odometer_km="12345,6")
    assert detail(alice, bike)["bike"]["odometer_km"] == 12345.6


def test_there_is_a_limit_on_bikes(alice):
    for i in range(20):
        new_bike(alice, f"b{i}")
    assert "at most 20 bikes" in message(alice.post("/api/v1/garage/bikes", data={"name": "one more"}, headers=CLIENT))


# ---------------------------------------------------------------------------------------------------------------------------- odometer --

def test_the_odometer_is_the_start_reading_plus_the_rides_since_the_start_date(alice):
    bike = new_bike(alice, start_odometer_km="10000", start_date="2026-09-01")
    add_ride(ALICE["sub"], "2026-08-30T08:00:00+00:00", distance_m=50_000)                         # before the bike was added: not counted
    add_ride(ALICE["sub"], "2026-09-01T08:00:00+00:00", distance_m=40_000)                         # on the start date: counted
    add_ride(ALICE["sub"], "2026-09-20T08:00:00+00:00", distance_m=25_500)
    assert detail(alice, bike)["bike"]["odometer_km"] == 10065.5 and detail(alice, bike)["bike"]["ridden_km"] == 65.5


def test_new_rides_count_for_the_default_bike_without_any_assignment(alice):
    bike = new_bike(alice)
    assert detail(alice, bike)["bike"]["odometer_km"] == 10000
    add_ride(ALICE["sub"], "2026-09-25T08:00:00+00:00", distance_m=30_000)
    assert detail(alice, bike)["bike"]["odometer_km"] == 10030


def test_a_ride_can_be_put_on_another_bike_and_back(alice):
    tuono, monster = new_bike(alice, "Tuono"), new_bike(alice, "Monster")
    ride = add_ride(ALICE["sub"], "2026-09-25T08:00:00+00:00", distance_m=30_000)
    assert alice.post(f"/api/v1/rides/{ride}/bike", data={"bike_id": str(monster)}, headers=CLIENT).json()["bike_id"] == monster
    assert detail(alice, tuono)["bike"]["odometer_km"] == 10000 and detail(alice, monster)["bike"]["odometer_km"] == 10030
    alice.post(f"/api/v1/rides/{ride}/bike", data={"bike_id": ""}, headers=CLIENT)                  # back to "the default bike"
    assert detail(alice, tuono)["bike"]["odometer_km"] == 10030 and detail(alice, monster)["bike"]["odometer_km"] == 10000


def test_changing_the_default_does_not_move_the_history_to_the_new_bike(alice):
    tuono, monster = new_bike(alice, "Tuono"), new_bike(alice, "Monster")
    add_ride(ALICE["sub"], "2026-09-25T08:00:00+00:00", distance_m=30_000)                         # unassigned: counts for the default (Tuono)
    assert alice.post(f"/api/v1/garage/bikes/{monster}/default", headers=CLIENT).status_code == 200
    assert detail(alice, tuono)["bike"]["odometer_km"] == 10030                                    # still Tuono's ride
    assert detail(alice, monster)["bike"]["odometer_km"] == 10000
    add_ride(ALICE["sub"], "2026-09-30T08:00:00+00:00", distance_m=10_000)                         # a new ride goes to the new default
    assert detail(alice, monster)["bike"]["odometer_km"] == 10010 and detail(alice, tuono)["bike"]["odometer_km"] == 10030
    assert detail(alice, monster)["bike"]["is_default"] and not detail(alice, tuono)["bike"]["is_default"]


def test_setting_the_odometer_adjusts_the_starting_value(alice):
    bike = new_bike(alice, start_odometer_km="10000")
    add_ride(ALICE["sub"], "2026-09-25T08:00:00+00:00", distance_m=30_000)
    d = alice.post(f"/api/v1/garage/bikes/{bike}/odometer", data={"km": "10100"}, headers=CLIENT).json()["bike"]
    assert d["odometer_km"] == 10100 and d["start_odometer_km"] == 10070
    add_ride(ALICE["sub"], "2026-09-28T08:00:00+00:00", distance_m=5_000)
    assert detail(alice, bike)["bike"]["odometer_km"] == 10105
    assert "between 0" in message(alice.post(f"/api/v1/garage/bikes/{bike}/odometer", data={"km": "-1"}, headers=CLIENT))


# ----------------------------------------------------------------------------------------------------------------------------- service --

def add_item(client, bike, name="Oil change", **extra):
    r = client.post(f"/api/v1/garage/bikes/{bike}/items", data={"name": name, **extra}, headers=CLIENT)
    assert r.status_code == 200, r.text
    return r.json()["item_id"], r.json()


def item(client, bike, item_id):
    return next(i for i in detail(client, bike)["items"] if i["id"] == item_id)


def test_a_service_with_a_starting_point_has_a_due_date_and_distance(alice):
    bike = new_bike(alice)
    item_id, d = add_item(alice, bike, interval_km="6000", interval_months="12", last_done_date="2026-06-01", last_done_km="9500")
    status = item(alice, bike, item_id)["status"]
    assert status["state"] == "ok" and status["due_km"] == 15500 and status["due_date"] == "2027-06-01" and status["remaining_km"] == 5500


def test_a_service_without_a_starting_point_is_never_done_until_marked(alice):
    bike = new_bike(alice)
    item_id, _ = add_item(alice, bike, interval_km="6000")
    assert item(alice, bike, item_id)["status"]["state"] == "never_done"
    r = alice.post(f"/api/v1/garage/items/{item_id}/done", data={}, headers=CLIENT)                  # today, at the current odometer
    done = next(i for i in r.json()["items"] if i["id"] == item_id)
    assert done["last_done_date"] == "2026-10-02" and done["last_done_km"] == 10000 and done["status"]["state"] == "ok"


def test_counting_from_now_makes_a_starting_point(alice):
    bike = new_bike(alice)
    item_id, _ = add_item(alice, bike, interval_months="12", count_from_now="1")
    got = item(alice, bike, item_id)
    assert got["last_done_date"] == "2026-10-02" and got["status"]["due_date"] == "2027-10-02"


def test_riding_makes_a_service_come_due(alice):
    bike = new_bike(alice)
    item_id, _ = add_item(alice, bike, interval_km="6000", last_done_date="2026-09-01", last_done_km="10000")
    add_ride(ALICE["sub"], "2026-09-10T08:00:00+00:00", distance_m=5_700_000)                     # 5,700 km: 300 left
    assert item(alice, bike, item_id)["status"]["state"] == "soon"
    add_ride(ALICE["sub"], "2026-09-20T08:00:00+00:00", distance_m=400_000)
    assert item(alice, bike, item_id)["status"]["state"] == "overdue"
    summary = alice.get("/api/v1/garage").json()["bikes"][0]
    assert summary["overdue"] == 1 and summary["next_due"]["name"] == "Oil change" and summary["next_due"]["state"] == "overdue"


def test_marking_a_service_done_starts_the_next_interval_and_is_logged_with_its_cost(alice):
    bike = new_bike(alice)
    item_id, _ = add_item(alice, bike, interval_km="6000", last_done_date="2025-01-01", last_done_km="1000")
    assert item(alice, bike, item_id)["status"]["state"] == "overdue"
    r = alice.post(f"/api/v1/garage/items/{item_id}/done", data={"date": "2026-10-01", "odometer_km": "10000", "cost": "180,50", "note": "Dealer"}, headers=CLIENT)
    body = r.json()
    assert next(i for i in body["items"] if i["id"] == item_id)["status"]["state"] == "ok"
    assert body["service_log"][0]["cost"] == 180.5 and body["service_log"][0]["note"] == "Dealer" and body["totals"]["service"] == 180.5


def test_a_service_log_entry_can_be_removed(alice):
    bike = new_bike(alice)
    item_id, _ = add_item(alice, bike, interval_km="6000", last_done_date="2026-09-01", last_done_km="10000")
    log_id = detail(alice, bike)["service_log"][0]["id"]
    r = alice.delete(f"/api/v1/garage/service-log/{log_id}", headers=CLIENT)
    assert r.status_code == 200 and r.json()["service_log"] == [] and item(alice, bike, item_id)["status"]["state"] == "never_done"


@pytest.mark.parametrize("extra,words", [
    ({"name": ""}, "enter a name for the service"),
    ({}, "distance interval, a time interval, or both"),
    ({"interval_km": "0"}, "between 1"),
    ({"interval_months": "6.5"}, "whole number"),
    ({"interval_months": "999"}, "between 1 and 240"),
    ({"interval_km": "6000", "last_done_km": "9000"}, "date it was last done"),
    ({"interval_km": "6000", "last_done_date": "next week"}, "2026-09-28"),
])
def test_mistakes_in_a_service_item_get_a_sentence(alice, extra, words):
    bike = new_bike(alice)
    data = {"name": "Oil", **extra}
    r = alice.post(f"/api/v1/garage/bikes/{bike}/items", data=data, headers=CLIENT)
    assert words in message(r)
    assert detail(alice, bike)["items"] == []


def test_a_service_item_can_be_deleted_with_its_log(alice):
    bike = new_bike(alice)
    item_id, _ = add_item(alice, bike, interval_km="6000", last_done_date="2026-09-01", last_done_km="10000")
    r = alice.delete(f"/api/v1/garage/items/{item_id}", headers=CLIENT)
    assert r.status_code == 200 and r.json()["items"] == [] and r.json()["service_log"] == []
    assert alice.delete(f"/api/v1/garage/items/{item_id}", headers=CLIENT).status_code == 404


# -------------------------------------------------------------------------------------------------------------------------------- fuel --

def fuel(client, bike, odo, litres, price="", full="1", day="2026-09-20"):
    r = client.post(f"/api/v1/garage/bikes/{bike}/fuel", data={"date": day, "odometer_km": str(odo), "litres": str(litres), "price": price, "full_tank": full}, headers=CLIENT)
    assert r.status_code == 200, r.text
    return r.json()


def test_consumption_and_cost_from_the_fuel_log(alice):
    bike = new_bike(alice)
    fuel(alice, bike, 10000, 12, "24", day="2026-09-01")
    d = fuel(alice, bike, 10250, 11, "23,10", day="2026-09-10")
    assert d["fuel"]["average_l_per_100km"] == 4.4 and d["fuel"]["total_spent"] == 47.1
    assert d["fuel"]["fills"][0]["date"] == "2026-09-10" and d["fuel"]["fills"][0]["l_per_100km"] == 4.4        # newest first
    assert d["totals"]["fuel"] == 47.1 and d["totals"]["all"] == 47.1


def test_a_part_fill_is_flagged_and_does_not_end_the_interval(alice):
    bike = new_bike(alice)
    fuel(alice, bike, 10000, 12)
    fuel(alice, bike, 10100, 4, full="0")
    d = fuel(alice, bike, 10300, 8)
    assert d["fuel"]["average_l_per_100km"] == 4.0


@pytest.mark.parametrize("data,words", [
    ({"odometer_km": "", "litres": "10"}, "odometer reading"),
    ({"odometer_km": "10000", "litres": ""}, "litres"),
    ({"odometer_km": "10000", "litres": "0"}, "between 0.1 and 200"),
    ({"odometer_km": "10000", "litres": "500"}, "between 0.1 and 200"),
    ({"odometer_km": "10000", "litres": "10", "price": "-3"}, "between 0 and"),
    ({"odometer_km": "10000", "litres": "10", "date": "2031-01-01"}, "cannot be in the future"),
])
def test_mistakes_in_a_fuel_entry_get_a_sentence(alice, data, words):
    bike = new_bike(alice)
    r = alice.post(f"/api/v1/garage/bikes/{bike}/fuel", data=data, headers=CLIENT)
    assert words in message(r) and detail(alice, bike)["fuel"]["fills"] == []


def test_a_fuel_entry_can_be_deleted(alice):
    bike = new_bike(alice)
    d = fuel(alice, bike, 10000, 12)
    fid = d["fuel"]["fills"][0]["id"]
    r = alice.delete(f"/api/v1/garage/fuel/{fid}", headers=CLIENT)
    assert r.status_code == 200 and r.json()["fuel"]["fills"] == []


def test_other_costs_and_the_cost_per_kilometre(alice):
    bike = new_bike(alice)
    add_ride(ALICE["sub"], "2026-09-25T08:00:00+00:00", distance_m=100_000)
    fuel(alice, bike, 10000, 10, "20")
    r = alice.post(f"/api/v1/garage/bikes/{bike}/expenses", data={"category": "Tyres", "amount": "180", "note": "Rear"}, headers=CLIENT)
    d = r.json()
    assert d["expenses"][0]["category"] == "Tyres" and d["totals"]["other"] == 180 and d["totals"]["all"] == 200 and d["totals"]["per_km"] == 2.0     # 200 over 100 km
    eid = d["expenses"][0]["id"]
    assert alice.delete(f"/api/v1/garage/expenses/{eid}", headers=CLIENT).json()["totals"]["other"] == 0
    assert "between 0.01" in message(alice.post(f"/api/v1/garage/bikes/{bike}/expenses", data={"amount": "0"}, headers=CLIENT))


# ----------------------------------------------------------------------------------------------------------------------------- deleting --

def test_deleting_a_bike_removes_its_records_and_frees_its_rides(alice):
    tuono, monster = new_bike(alice, "Tuono"), new_bike(alice, "Monster")
    ride = add_ride(ALICE["sub"], "2026-09-25T08:00:00+00:00", distance_m=30_000)
    alice.post(f"/api/v1/rides/{ride}/bike", data={"bike_id": str(monster)}, headers=CLIENT)
    add_item(alice, monster, interval_km="6000", last_done_date="2026-09-01", last_done_km="10000")
    fuel(alice, monster, 10000, 12)
    alice.post(f"/api/v1/garage/bikes/{monster}/expenses", data={"amount": "10"}, headers=CLIENT)
    assert alice.delete(f"/api/v1/garage/bikes/{monster}", headers=CLIENT).json() == {"api": 1, "deleted": monster}
    conn = get_db()
    try:
        for table in ("service_items", "service_log", "fuel_log", "expenses"):
            assert conn.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0] == 0
        assert conn.execute("SELECT bike_id FROM rides WHERE id = ?", (ride,)).fetchone()[0] is None          # the ride itself is untouched
    finally:
        conn.close()
    assert alice.get(f"/api/v1/garage/bikes/{monster}").status_code == 404


def test_deleting_the_default_bike_makes_another_the_default(alice):
    tuono, monster = new_bike(alice, "Tuono"), new_bike(alice, "Monster")
    alice.delete(f"/api/v1/garage/bikes/{tuono}", headers=CLIENT)
    assert detail(alice, monster)["bike"]["is_default"]


# ------------------------------------------------------------------------------------------------------------------------- isolation --

def test_nobody_can_see_or_change_someone_elses_garage(alice, bob):
    bike = new_bike(alice)
    item_id, _ = add_item(alice, bike, interval_km="6000", last_done_date="2026-09-01", last_done_km="10000")
    fid = fuel(alice, bike, 10000, 12)["fuel"]["fills"][0]["id"]
    ride = add_ride(ALICE["sub"], "2026-09-25T08:00:00+00:00", distance_m=30_000)
    bobs_ride = add_ride(BOB["sub"], "2026-09-25T08:00:00+00:00", distance_m=30_000)
    bobs_bike = new_bike(bob, "Bobs")
    assert bob.get("/api/v1/garage").json()["bikes"][0]["name"] == "Bobs" and len(bob.get("/api/v1/garage").json()["bikes"]) == 1
    for method, path, data in [
        ("get", f"/api/v1/garage/bikes/{bike}", None), ("post", f"/api/v1/garage/bikes/{bike}", {"name": "mine now"}),
        ("post", f"/api/v1/garage/bikes/{bike}/default", None), ("post", f"/api/v1/garage/bikes/{bike}/odometer", {"km": "1"}),
        ("delete", f"/api/v1/garage/bikes/{bike}", None), ("post", f"/api/v1/garage/bikes/{bike}/items", {"name": "x", "interval_km": "5"}),
        ("post", f"/api/v1/garage/items/{item_id}/done", {}), ("delete", f"/api/v1/garage/items/{item_id}", None),
        ("post", f"/api/v1/garage/bikes/{bike}/fuel", {"odometer_km": "1", "litres": "5"}), ("delete", f"/api/v1/garage/fuel/{fid}", None),
        ("post", f"/api/v1/garage/bikes/{bike}/expenses", {"amount": "5"}), ("post", f"/api/v1/rides/{ride}/bike", {"bike_id": str(bobs_bike)}),
        ("post", f"/api/v1/rides/{bobs_ride}/bike", {"bike_id": str(bike)}),
    ]:
        r = getattr(bob, method)(path, headers=CLIENT, **({"data": data} if data is not None else {}))
        assert r.status_code == 404, (method, path, r.status_code)
    after = detail(alice, bike)
    assert after["bike"]["name"] == "Tuono" and len(after["items"]) == 1 and len(after["fuel"]["fills"]) == 1


# ------------------------------------------------------------------------------------------------------------------------- migration --

def test_a_database_from_before_the_garage_gets_the_new_column_and_keeps_its_rides(tmp_path, monkeypatch):
    old = tmp_path / "old.db"
    conn = sqlite3.connect(old)
    conn.executescript("""
        CREATE TABLE points (id INTEGER PRIMARY KEY AUTOINCREMENT, owner_sub TEXT NOT NULL DEFAULT '', device_id TEXT NOT NULL DEFAULT '', lat REAL NOT NULL, lon REAL NOT NULL,
          timestamp TEXT NOT NULL, speed REAL, altitude REAL, horizontal_accuracy REAL, vertical_accuracy REAL, motion TEXT, battery_level REAL, trip_id TEXT, ride_id INTEGER,
          raw_properties TEXT NOT NULL, received_at TEXT NOT NULL DEFAULT (datetime('now')));
        CREATE TABLE rides (id INTEGER PRIMARY KEY AUTOINCREMENT, owner_sub TEXT NOT NULL DEFAULT '', device_id TEXT NOT NULL DEFAULT '', trip_id TEXT, start_time TEXT NOT NULL,
          end_time TEXT NOT NULL, distance_m REAL NOT NULL, duration_s REAL NOT NULL, avg_speed_mps REAL NOT NULL, max_speed_mps REAL NOT NULL, elevation_gain_m REAL NOT NULL,
          point_count INTEGER NOT NULL, polyline_simplified TEXT NOT NULL, source TEXT NOT NULL CHECK (source IN ('trip_marker','gap_inferred')),
          app_reported_distance_m REAL, created_at TEXT NOT NULL DEFAULT (datetime('now')));
        INSERT INTO rides (owner_sub, start_time, end_time, distance_m, duration_s, avg_speed_mps, max_speed_mps, elevation_gain_m, point_count, polyline_simplified, source)
          VALUES ('s', '2026-09-01T08:00:00+00:00', '2026-09-01T09:00:00+00:00', 12345, 3600, 3, 9, 5, 100, '[]', 'trip_marker');
    """)
    conn.commit()
    conn.close()
    monkeypatch.setattr(settings, "db_path", str(old))
    db_module.init_db()
    db_module.init_db()                                                       # a second start must not fail on the column that now exists
    check = sqlite3.connect(old)
    columns = [r[1] for r in check.execute("PRAGMA table_info(rides)")]
    assert "bike_id" in columns
    assert check.execute("SELECT distance_m, bike_id FROM rides").fetchone() == (12345, None)
    assert check.execute("SELECT COUNT(*) FROM bikes").fetchone()[0] == 0
    check.close()
