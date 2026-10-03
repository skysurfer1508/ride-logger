"""What a ride will meet (app/conditions.py): the decisions are pure functions of forecast samples; the network call is faked."""
from datetime import datetime, timezone
from zoneinfo import ZoneInfo

import pytest

from app import conditions, weather
from app.config import settings

DEPART = datetime(2026, 10, 2, 10, 0, tzinfo=timezone.utc)


def sample(along, t=12.0, rain=0.0, gust=10.0, code=1):
    return {"along_m": along, "temperature": t, "precipitation": rain, "gust": gust, "code": code}


def test_a_dry_mild_ride_has_no_alerts():
    assert conditions.alerts([sample(0), sample(20_000), sample(40_000)]) == []


def test_the_first_place_of_each_kind_of_trouble_is_reported_once():
    found = conditions.alerts([sample(0), sample(15_000, rain=1.2, code=61), sample(30_000, rain=2.0, code=63), sample(45_000, t=1.0, code=3)])
    assert [(a["kind"], a["along_m"]) for a in found] == [("rain", 15_000), ("ice", 45_000)]
    assert found[1]["label"] == "cold, 1 degrees, watch for ice"


def test_snow_and_storm_win_over_plain_rain():
    assert conditions.alerts([sample(0, code=73, rain=1.0)])[0]["kind"] == "snow"
    assert conditions.alerts([sample(0, code=95, rain=3.0)])[0]["kind"] == "storm"


def test_strong_gusts_and_freezing_rain_are_alerts():
    found = conditions.alerts([sample(0, gust=75.0), sample(10_000, code=66, rain=0.5, t=None)])
    assert [a["kind"] for a in found] == ["wind", "rain", "ice"] or [a["kind"] for a in found] == ["wind", "ice", "rain"]


def test_missing_values_are_not_trouble():
    assert conditions.alerts([{"along_m": 0, "temperature": None, "precipitation": None, "gust": None, "code": None}]) == []


def test_the_forecast_hour_is_found_by_the_time_the_rider_gets_there():
    hourly = {"time": ["2026-10-02T10:00", "2026-10-02T11:00"], "temperature_2m": [10.0, 4.0], "precipitation": [0.0, 1.0], "wind_gusts_10m": [5.0, 9.0], "weather_code": [1, 61]}
    assert conditions.hour_values(hourly, DEPART)["temperature"] == 10.0
    assert conditions.hour_values(hourly, datetime(2026, 10, 2, 11, 40, tzinfo=timezone.utc))["code"] == 61
    assert conditions.hour_values(hourly, datetime(2026, 10, 3, 11, 0, tzinfo=timezone.utc)) is None
    assert conditions.eta(DEPART, 3600, 5000, 10_000) == datetime(2026, 10, 2, 10, 30, tzinfo=timezone.utc)


def test_sample_points_run_from_the_start_to_the_end():
    shape = [(47.0 + i * 0.001, 8.0) for i in range(500)]            # about 55 km north
    pts = conditions.sample_points(shape)
    assert pts[0]["along_m"] == 0 and pts[-1]["along_m"] == pytest.approx(55_500, abs=300) and 2 <= len(pts) <= conditions.MAX_SAMPLES


def test_a_ride_that_ends_after_dusk_says_how_much_is_in_the_dark():
    lit = conditions.light(47.4, 8.5, datetime(2026, 10, 2, 16, 30, tzinfo=timezone.utc), 3 * 3600, ZoneInfo("Europe/Zurich"))
    assert lit["sunset"] == "19:06" and lit["dusk"] in ("19:36", "19:37") and 108 <= lit["dark_min"] <= 118          # dusk about 17:37 UTC, the ride ends 19:30 UTC
    early = conditions.light(47.4, 8.5, datetime(2026, 10, 2, 8, 0, tzinfo=timezone.utc), 3600, ZoneInfo("Europe/Zurich"))
    assert early["dark_min"] == 0


def test_the_spoken_summary_is_short_and_empty_when_there_is_nothing_to_say():
    assert conditions.spoken_summary([], {"dark_min": 0}) == ""
    said = conditions.spoken_summary([{"along_m": 22_000, "kind": "rain", "label": "rain likely"}], {"sunset": "19:06", "dusk": "19:36", "dark_min": 40})
    assert said == "Rain likely after 22 kilometers. Sunset is at 19:06, about 40 minutes of this ride are after dark."
    assert conditions.spoken_summary([{"along_m": 300, "kind": "rain", "label": "rain likely"}], {"dark_min": 0}) == "Rain likely from the start."


def test_the_forecast_is_asked_once_and_kept(monkeypatch):
    monkeypatch.setattr(settings, "weather_enabled", True)
    conditions._cache.clear()
    asked = []
    hourly = {"time": ["2026-10-02T10:00", "2026-10-02T11:00"], "temperature_2m": [10.0, 9.0], "precipitation": [0.0, 0.0], "wind_gusts_10m": [5.0, 5.0], "weather_code": [1, 1]}

    def fake(points, forecast_days=2):
        asked.append(points)
        return [hourly] * len(points)

    monkeypatch.setattr(weather, "fetch_many", fake)
    pts = [{"along_m": 0, "lat": 47.0, "lon": 8.0}, {"along_m": 10_000, "lat": 47.1, "lon": 8.1}]
    first = conditions.forecast(pts, DEPART, 3600, 10_000)
    again = conditions.forecast(pts, DEPART, 3600, 10_000)
    assert len(asked) == 1 and first == again and first[0]["temperature"] == 10.0


def test_no_forecast_is_no_samples_never_an_error(monkeypatch):
    conditions._cache.clear()
    pts = [{"along_m": 0, "lat": 47.0, "lon": 8.0}]
    assert conditions.forecast(pts, DEPART, 3600, 1000) == []                      # weather switched off in tests
    monkeypatch.setattr(settings, "weather_enabled", True)

    def down(points, forecast_days=2):
        raise weather.WeatherUnavailable("down")

    monkeypatch.setattr(weather, "fetch_many", down)
    assert conditions.forecast(pts, DEPART, 3600, 1000) == []
