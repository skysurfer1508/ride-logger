"""GET /api/v1/rides/{id}/insights: elevation, smoothness, weather and speed against the limit, each with its own status, cached per ride."""
import pytest

from app import extras, valhalla, weather
from app.config import settings
from app.db import get_db
from conftest import ALICE, BOB, add_ride
from test_track import insert_points
from trackgen import make_rows

START = "2026-09-30T08:00:00+00:00"
FAST_RIDE = [("drive", 200, 25.0), ("drive", 60, 8.0), ("drive", 200, 25.0)]          # 90 km/h, a slowdown, 90 km/h again


def hourly():
    n = 24
    return {"time": [f"2026-09-30T{h:02d}:00" for h in range(n)], "temperature_2m": [12.0 + h * 0.5 for h in range(n)], "precipitation": [0.0] * n,
            "wind_speed_10m": [10.0] * n, "wind_gusts_10m": [22.0] * n, "weather_code": [3] * n}


class Fakes:
    """Counts the calls that would have left the machine."""
    def __init__(self, monkeypatch):
        self.match_calls = 0
        self.weather_calls = 0
        self.match_error = None
        self.weather_error = None
        self.limit = 80
        self.matched = True
        monkeypatch.setattr(settings, "valhalla_url", "http://valhalla.invalid")
        monkeypatch.setattr(settings, "weather_enabled", True)
        monkeypatch.setattr(valhalla, "match_points", self.match)
        monkeypatch.setattr(weather, "fetch", self.fetch)

    def match(self, points):
        self.match_calls += 1
        if self.match_error:
            raise self.match_error
        if not self.matched:
            return [None] * len(points)
        return [{"limit_kmh": self.limit, "road_class": "primary", "name": "Teststrasse", "way_id": 1, "use": "road"}] * len(points)

    def fetch(self, lat, lon, start, end, now=None):
        self.weather_calls += 1
        if self.weather_error:
            raise self.weather_error
        return hourly()


@pytest.fixture
def fakes(monkeypatch):
    return Fakes(monkeypatch)


def ride_with_points(owner=ALICE, segments=FAST_RIDE):
    rid = add_ride(owner["sub"], START)
    insert_points(owner["sub"], rid, make_rows(segments))
    return rid


def test_everything_is_reported_for_a_ride(alice, fakes):
    rid = ride_with_points()
    body = alice.get(f"/api/v1/rides/{rid}/insights").json()
    assert body["api"] == 1 and body["ride_id"] == rid
    assert body["limits"]["status"] == "ok" and body["limits"]["tagged"]["over_seconds"] > 300 and body["limits"]["worst"]["limit_kmh"] == 80
    assert body["limits"]["worst"]["name"] == "Teststrasse" and len(body["limits"]["stretches"]) == 2 and body["limits"]["tagged_share"] == 100.0
    assert body["road_names"] == [[0.0, "Teststrasse"]]
    assert body["weather"]["status"] == "ok" and body["weather"]["condition"] == "Overcast" and body["weather"]["wet"] is False
    assert body["weather"]["attribution"].startswith("Weather data by Open-Meteo")
    assert body["elevation"]["points"] and body["smoothness"] is not None


def test_a_limit_the_rider_obeys_has_no_overspeed(alice, fakes):
    fakes.limit = 120
    rid = ride_with_points()
    limits = alice.get(f"/api/v1/rides/{rid}/insights").json()["limits"]
    assert limits["tagged"]["over_seconds"] == 0 and limits["worst"] is None and limits["stretches"] == []


def test_the_remote_answers_are_cached_and_a_longer_ride_asks_again(alice, fakes):
    rid = ride_with_points()
    first = alice.get(f"/api/v1/rides/{rid}/insights").json()
    second = alice.get(f"/api/v1/rides/{rid}/insights").json()
    assert (fakes.match_calls, fakes.weather_calls) == (1, 1) and first == second
    insert_points(ALICE["sub"], rid, make_rows([("drive", 400, 20.0)], start=__import__("trackgen").START.replace(hour=9)))          # late points arrive
    alice.get(f"/api/v1/rides/{rid}/insights")
    assert (fakes.match_calls, fakes.weather_calls) == (2, 2)


def test_switched_off_services_are_reported_not_hidden(alice):
    rid = ride_with_points()
    body = alice.get(f"/api/v1/rides/{rid}/insights").json()                         # the test environment has both switched off
    assert body["limits"] == {"status": "disabled"} and body["weather"] == {"status": "disabled"}
    assert body["elevation"] is not None


def test_a_failing_service_does_not_break_the_rest_and_is_tried_again(alice, fakes):
    fakes.match_error = valhalla.ValhallaUnavailable("down")
    fakes.weather_error = weather.WeatherUnavailable("The weather service could not be reached.")
    rid = ride_with_points()
    body = alice.get(f"/api/v1/rides/{rid}/insights").json()
    assert body["limits"] == {"status": "unavailable"} and body["road_names"] == []
    assert body["weather"] == {"status": "unavailable", "message": "The weather service could not be reached."}
    assert body["elevation"] is not None and body["smoothness"] is not None
    fakes.match_error = fakes.weather_error = None                                   # back up: the failure was not cached
    body = alice.get(f"/api/v1/rides/{rid}/insights").json()
    assert body["limits"]["status"] == "ok" and body["weather"]["status"] == "ok"


def test_a_track_the_matcher_cannot_place_is_no_match_and_not_cached(alice, fakes):
    fakes.matched = False
    rid = ride_with_points()
    assert alice.get(f"/api/v1/rides/{rid}/insights").json()["limits"] == {"status": "no_match"}
    alice.get(f"/api/v1/rides/{rid}/insights")
    assert fakes.match_calls == 2


def test_a_tiny_ride_says_so(alice, fakes):
    rid = add_ride(ALICE["sub"], START)
    insert_points(ALICE["sub"], rid, make_rows([]))
    body = alice.get(f"/api/v1/rides/{rid}/insights").json()
    assert body["limits"] == {"status": "no_data"} and body["elevation"] is None and fakes.match_calls == 0 and fakes.weather_calls == 0


def test_only_the_owner_can_read_insights(alice, bob, anon, fakes):
    rid = ride_with_points()
    assert bob.get(f"/api/v1/rides/{rid}/insights").status_code == 404
    assert bob.get("/api/v1/rides/99999/insights").status_code == 404
    assert anon.get(f"/api/v1/rides/{rid}/insights").status_code == 401
    assert fakes.match_calls == 0


def test_deleting_a_ride_removes_its_cached_answers(alice, fakes):
    rid = ride_with_points()
    alice.get(f"/api/v1/rides/{rid}/insights")
    conn = get_db()
    assert conn.execute("SELECT COUNT(*) FROM ride_extras WHERE ride_id = ?", (rid,)).fetchone()[0] == 2
    conn.close()
    assert alice.delete(f"/api/v1/rides/{rid}", headers={"X-RideLog-Client": "1"}).status_code == 200
    conn = get_db()
    assert conn.execute("SELECT COUNT(*) FROM ride_extras WHERE ride_id = ?", (rid,)).fetchone()[0] == 0
    conn.close()


def test_a_cache_row_in_an_old_format_is_ignored(alice, fakes):
    rid = ride_with_points()
    alice.get(f"/api/v1/rides/{rid}/insights")
    conn = get_db()
    conn.execute("UPDATE ride_extras SET version = version + 1")
    conn.commit()
    conn.close()
    alice.get(f"/api/v1/rides/{rid}/insights")
    assert fakes.match_calls == 2 and fakes.weather_calls == 2
