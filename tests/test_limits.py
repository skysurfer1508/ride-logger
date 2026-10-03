"""app/limits.py (speed against the limit) and app/insights.py (elevation, braking and acceleration). Synthetic rides with known numbers."""
import random

import pytest

from app import insights, limits


def pts(speeds_mps, step=1.0, altitude=None):
    """Points one `step` apart at the given speeds (m/s), distance accumulated from the speeds."""
    out, t, dist = [], 0.0, 0.0
    for i, v in enumerate(speeds_mps):
        out.append({"t": t, "mps": float(v), "dist": dist, "lat": 47.0 + dist / 111_195.0, "lon": 8.0, "altitude": None if altitude is None else altitude[i]})
        dist += v * step
        t += step
    return out


def match(limit=None, road_class="secondary", name="Hardstrasse"):
    return {"limit_kmh": limit, "road_class": road_class, "name": name, "way_id": 1, "use": "road"}


# ----------------------------------------------------------------------------------------------------------------------------- limit_for --

def test_a_tagged_limit_wins_over_the_default():
    assert limits.limit_for(match(limit=50, road_class="primary")) == (50, "tagged")
    assert limits.limit_for(match(limit=79.6)) == (80, "tagged")


def test_without_a_tag_the_swiss_default_of_the_road_class_is_an_estimate():
    assert limits.limit_for(match(road_class="motorway")) == (120, "estimated")
    assert limits.limit_for(match(road_class="trunk")) == (100, "estimated")
    assert limits.limit_for(match(road_class="tertiary")) == (80, "estimated")
    assert limits.limit_for(match(road_class="residential")) == (50, "estimated")


def test_nothing_is_made_up_for_a_road_with_no_default_or_no_match():
    assert limits.limit_for(match(road_class="service_other")) == (None, None)
    assert limits.limit_for(match(road_class=None)) == (None, None)
    assert limits.limit_for(None) == (None, None)
    assert limits.limit_for({"limit_kmh": 0, "road_class": "weird"}) == (None, None)


# ------------------------------------------------------------------------------------------------------------------------------ analyze --

def test_time_and_distance_over_a_tagged_limit():
    points = pts([20] * 10 + [12] * 6)                                    # 72 km/h for 10 s, then 43 km/h, in a 50 zone
    result = limits.analyze(points, [match(limit=50)] * 16)
    tagged = result["tagged"]
    assert tagged["seconds"] == 15 and tagged["over_seconds"] == 10 and tagged["notable_seconds"] == 10 and tagged["over_metres"] == 200
    assert tagged["over_share"] == 66.7
    assert result["worst"] == {"t": 0.0, "over_kmh": 22, "kmh": 72, "limit_kmh": 50, "name": "Hardstrasse"}
    assert result["stretches"] == [{"t_start": 0.0, "t_end": 10.0, "limit_kmh": 50, "max_kmh": 72, "max_over_kmh": 22, "name": "Hardstrasse", "dist_start_m": 0}]
    assert result["matched_share"] == 100.0 and result["tagged_share"] == 100.0


def test_riding_exactly_at_the_limit_is_not_over():
    result = limits.analyze(pts([50 / 3.6] * 10), [match(limit=50)] * 10)
    assert result["tagged"]["over_seconds"] == 0 and result["worst"] is None and result["stretches"] == []


def test_a_little_over_counts_as_over_but_not_as_clearly_over():
    result = limits.analyze(pts([53 / 3.6] * 10), [match(limit=50)] * 10)           # 3 km/h over
    assert result["tagged"]["over_seconds"] == 9 and result["tagged"]["notable_seconds"] == 0
    result = limits.analyze(pts([55 / 3.6] * 10), [match(limit=50)] * 10)           # 5 km/h over
    assert result["tagged"]["notable_seconds"] == 9


def test_estimated_limits_are_counted_apart_and_never_make_stretches_or_a_worst_case():
    result = limits.analyze(pts([25] * 10), [match(limit=None, road_class="secondary")] * 10)                  # 90 km/h on a road assumed to be 80
    assert result["estimated"]["over_seconds"] == 9 and result["estimated"]["notable_seconds"] == 9
    assert result["tagged"]["seconds"] == 0 and result["tagged"]["over_share"] is None
    assert result["worst"] is None and result["stretches"] == [] and result["tagged_share"] == 0.0


def test_points_that_were_not_matched_are_left_out_of_everything():
    matches = [match(limit=50)] * 5 + [None] * 5
    result = limits.analyze(pts([20] * 10), matches)
    assert result["tagged"]["seconds"] == 5 and result["matched_share"] == 55.6                   # 5 of the 9 one-second steps


def test_a_stretch_ends_where_the_speed_drops_or_the_match_is_lost_and_a_new_one_starts_after():
    speeds = [20] * 4 + [10] * 3 + [20] * 4
    result = limits.analyze(pts(speeds), [match(limit=50)] * 11)
    assert [(s["t_start"], s["t_end"]) for s in result["stretches"]] == [(0.0, 4.0), (7.0, 10.0)]
    lost = limits.analyze(pts([20] * 6), [match(limit=50)] * 3 + [None] + [match(limit=50)] * 2)
    assert len(lost["stretches"]) == 2


def test_a_long_gap_between_fixes_counts_for_at_most_ten_seconds():
    points = pts([20, 20, 20])
    points[2]["t"] = 100.0
    result = limits.analyze(points, [match(limit=50)] * 3)
    assert result["tagged"]["seconds"] == 11                                                         # 1 s + capped 10 s


def test_the_worst_stretch_is_the_one_with_the_biggest_overspeed():
    speeds = [20] * 3 + [10] * 2 + [30] * 3
    result = limits.analyze(pts(speeds), [match(limit=50)] * 8)
    assert result["worst"]["over_kmh"] == 58 and result["worst"]["kmh"] == 108
    assert len(result["stretches"]) == 2 and result["stretches"][1]["max_over_kmh"] == 58


def test_nothing_to_analyse():
    empty = limits.analyze([], [])
    assert empty["tagged"]["seconds"] == 0 and empty["worst"] is None and empty["matched_share"] is None
    assert limits.analyze(pts([10]), [match(limit=50)])["tagged"]["seconds"] == 0                      # one point has no time span


# ----------------------------------------------------------------------------------------------------------------------------- elevation --

def test_a_steady_climb():
    profile = insights.elevation_profile(pts([10] * 200, altitude=[400 + i for i in range(200)]))
    assert profile["ascent_m"] == pytest.approx(193, abs=8) and profile["descent_m"] == 0
    assert profile["min_m"] <= 403 and profile["max_m"] >= 596
    assert profile["points"][0][0] == 0 and profile["points"][-1][0] == 1990


def test_up_and_down_gives_both():
    altitude = [400 + i for i in range(100)] + [500 - i for i in range(100)]
    profile = insights.elevation_profile(pts([10] * 200, altitude=altitude))
    assert profile["ascent_m"] == pytest.approx(95, abs=10) and profile["descent_m"] == pytest.approx(95, abs=10)


def test_gps_noise_on_flat_ground_is_not_climbing():
    for seed in range(10):
        rnd = random.Random(seed)
        profile = insights.elevation_profile(pts([10] * 300, altitude=[400 + rnd.uniform(-4, 4) for _ in range(300)]))
        assert profile["ascent_m"] <= 8 and profile["descent_m"] <= 8, seed


def test_too_little_altitude_data_gives_no_profile():
    assert insights.elevation_profile(pts([10] * 10, altitude=[400] * 10)) is None
    assert insights.elevation_profile(pts([10] * 100)) is None
    mixed = pts([10] * 100, altitude=[400 + i if i % 2 else None for i in range(100)])
    assert insights.elevation_profile(mixed) is not None                                              # fixes without altitude are skipped


def test_a_long_ride_is_thinned_for_the_chart():
    profile = insights.elevation_profile(pts([10] * 3000, altitude=[400 + (i % 50) for i in range(3000)]))
    assert len(profile["points"]) <= insights.MAX_PROFILE_POINTS + 1 and profile["points"][-1][0] == 29990


# ---------------------------------------------------------------------------------------------------------------------------- smoothness --

def test_a_steady_ride_has_no_events_and_a_perfect_score():
    result = insights.smoothness(pts([15] * 200))
    assert result["events"] == [] and result["score"] == 100 and result["events_per_10km"] == 0


def test_one_hard_stop_is_one_braking_event():
    speeds = [15] * 60 + [15, 10, 5, 0, 0] + [0] * 3 + [5, 8] + [15] * 100                           # 15 to 0 m/s in 3 s: -5 m/s2
    result = insights.smoothness(pts(speeds))
    braking = [e for e in result["events"] if e["kind"] == "braking"]
    assert len(braking) == 1 and result["hard_braking"] == 1
    assert braking[0]["peak_mps2"] == pytest.approx(-5.0, abs=0.01) and braking[0]["from_kmh"] == 54 and braking[0]["dist_m"] > 900


def test_hard_acceleration_is_found_too():
    speeds = [5] * 60 + [5, 10, 15, 20] + [20] * 100
    result = insights.smoothness(pts(speeds))
    assert result["hard_acceleration"] == 1 and result["hard_braking"] == 0
    assert result["events"][0]["peak_mps2"] == pytest.approx(5.0, abs=0.01)


def test_a_gentle_slowdown_is_not_an_event():
    speeds = [15] * 60 + [15 - i * 0.5 for i in range(20)] + [5] * 100                                # -0.5 m/s2
    assert insights.smoothness(pts(speeds))["events"] == []


def test_the_score_falls_with_the_number_of_events_per_distance():
    speeds = ([15] * 40 + [15, 10, 5, 0, 0] + [0] * 3 + [5, 10, 15]) * 2 + [15] * 120
    result = insights.smoothness(pts(speeds))
    km = result and sum(speeds) / 1000
    assert result["events_per_10km"] == pytest.approx(len(result["events"]) / km * 10, abs=0.1)
    assert result["score"] == max(0, round(100 - insights.EVENT_PENALTY * result["events_per_10km"])) and result["score"] < 100


def test_a_gap_in_the_fixes_is_not_mistaken_for_braking():
    points = pts([15] * 60 + [0] * 60 + [15] * 60)
    for p in points[60:]:
        p["t"] += 60                                                                                   # a minute without fixes while standing
    assert insights.smoothness(points)["hard_braking"] <= 1


def test_rides_too_short_to_judge_get_no_score():
    assert insights.smoothness(pts([15] * 20)) is None                                                 # fewer than 30 points
    assert insights.smoothness(pts([5] * 100)) is None                                                 # 500 m


# ------------------------------------------------------------------------------------------------------------------------------ weather --

from datetime import datetime, timedelta, timezone  # noqa: E402

from app import valhalla, weather  # noqa: E402


def hours(day, temps, rain, wind, gust, codes):
    times = [f"{day}T{h:02d}:00" for h in range(24)]
    pad = lambda v: v + [None] * (24 - len(v))                                          # noqa: E731
    return {"time": times, "temperature_2m": pad(temps), "precipitation": pad(rain), "wind_speed_10m": pad(wind), "wind_gusts_10m": pad(gust), "weather_code": pad(codes)}


def utc(*a):
    return datetime(*a, tzinfo=timezone.utc)


def test_the_summary_covers_exactly_the_hours_of_the_ride():
    data = hours("2026-09-30", [10.0 + h for h in range(24)], [0.0] * 8 + [0.5, 1.0, 0.0] + [0.0] * 13, [5.0 + h for h in range(24)], [15.0 + h for h in range(24)], [1] * 24)
    s = weather.summarize(data, utc(2026, 9, 30, 8, 40), utc(2026, 9, 30, 10, 15))              # hours 08, 09 and 10
    assert s["temperature_start_c"] == 18.0 and s["temperature_end_c"] == 20.0 and s["temperature_min_c"] == 18.0 and s["temperature_max_c"] == 20.0
    assert s["precipitation_mm"] == 1.5 and s["wind_max_kmh"] == 15 and s["gust_max_kmh"] == 25 and s["wet"] is True
    assert s["attribution"] == "Weather data by Open-Meteo.com (CC BY 4.0)"


def test_a_dry_ride_and_the_worst_conditions():
    data = hours("2026-09-30", [15.0] * 24, [0.0] * 24, [10.0] * 24, [20.0] * 24, [0, 0, 0, 0, 0, 0, 0, 0, 2, 3, 3, 0] + [0] * 12)
    s = weather.summarize(data, utc(2026, 9, 30, 8, 0), utc(2026, 9, 30, 10, 0))
    assert s["wet"] is False and s["precipitation_mm"] == 0.0 and s["condition"] == "Overcast" and s["condition_start"] == "Partly cloudy"


def test_a_rain_code_means_wet_even_without_measured_rain():
    data = hours("2026-09-30", [15.0] * 24, [0.0] * 24, [10.0] * 24, [20.0] * 24, [61] * 24)
    assert weather.summarize(data, utc(2026, 9, 30, 8, 0), utc(2026, 9, 30, 9, 0))["wet"] is True


def test_a_ride_across_midnight_uses_both_days():
    first = hours("2026-09-30", [10.0] * 24, [0.0] * 24, [5.0] * 24, [9.0] * 24, [0] * 24)
    second = hours("2026-10-01", [4.0] * 24, [0.0] * 24, [5.0] * 24, [9.0] * 24, [0] * 24)
    both = {k: first[k] + second[k] for k in first}
    s = weather.summarize(both, utc(2026, 9, 30, 23, 30), utc(2026, 10, 1, 0, 30))
    assert s["temperature_start_c"] == 10.0 and s["temperature_end_c"] == 4.0 and s["temperature_min_c"] == 4.0


def test_missing_values_are_skipped_and_no_data_is_none():
    data = hours("2026-09-30", [None] * 24, [None] * 24, [None] * 24, [None] * 24, [None] * 24)
    assert weather.summarize(data, utc(2026, 9, 30, 8, 0), utc(2026, 9, 30, 9, 0)) is None
    assert weather.summarize(hours("2026-09-30", [1.0] * 24, [0.0] * 24, [1.0] * 24, [1.0] * 24, [0] * 24), utc(2026, 10, 5, 8, 0), utc(2026, 10, 5, 9, 0)) is None
    partial = hours("2026-09-30", [12.0] + [None] * 23, [None] * 24, [None] * 24, [None] * 24, [None] * 24)
    s = weather.summarize(partial, utc(2026, 9, 30, 0, 10), utc(2026, 9, 30, 0, 50))
    assert s["temperature_start_c"] == 12.0 and s["precipitation_mm"] is None and s["wind_max_kmh"] is None and s["wet"] is False


@pytest.mark.parametrize("code,text", [(0, "Clear"), (3, "Overcast"), (61, "Light rain"), (95, "Thunderstorm"), (62, "Light rain"), (97, "Thunderstorm with hail"), (None, None)])
def test_condition_words(code, text):
    assert weather.condition(code) == text


def test_recent_rides_use_the_forecast_api_with_past_days_and_old_ones_the_archive(monkeypatch):
    seen = []
    monkeypatch.setattr(weather, "_get", lambda url, params: seen.append((url, params)) or {"time": []})
    now = utc(2026, 10, 2, 12, 0)
    weather.fetch(47.3769, 8.5417, utc(2026, 9, 30, 8, 0), utc(2026, 9, 30, 9, 0), now=now)
    url, params = seen[-1]
    assert url == weather.FORECAST_URL and params["past_days"] == 3 and params["latitude"] == 47.4 and params["longitude"] == 8.5 and params["timezone"] == "UTC"
    weather.fetch(47.3769, 8.5417, utc(2026, 6, 1, 8, 0), utc(2026, 6, 1, 9, 0), now=now)
    url, params = seen[-1]
    assert url == weather.ARCHIVE_URL and params["start_date"] == "2026-06-01" and params["end_date"] == "2026-06-01" and "past_days" not in params
    weather.fetch(47.0, 8.0, utc(2026, 7, 5, 8, 0), utc(2026, 7, 5, 9, 0), now=now)           # 89 days: still the forecast API, within its 92 days
    assert seen[-1][0] == weather.FORECAST_URL and seen[-1][1]["past_days"] == 90


def test_weather_errors_are_readable(monkeypatch):
    class R:
        def __init__(self, status, payload=None): self.status_code, self._p = status, payload
        def json(self):
            if self._p is None: raise ValueError("x")
            return self._p
    for status, words in [(429, "too many requests"), (500, "(500)")]:
        monkeypatch.setattr(weather.httpx, "get", lambda *a, **k: R(status))
        with pytest.raises(weather.WeatherUnavailable, match=words.replace("(", r"\(").replace(")", r"\)")):
            weather._get("u", {})
    monkeypatch.setattr(weather.httpx, "get", lambda *a, **k: R(200, {"error": True, "reason": "x"}))
    with pytest.raises(weather.WeatherUnavailable, match="no data"):
        weather._get("u", {})
    monkeypatch.setattr(weather.httpx, "get", lambda *a, **k: R(200))
    with pytest.raises(weather.WeatherUnavailable, match="unreadable"):
        weather._get("u", {})


# ----------------------------------------------------------------------------------------------------------------------------- valhalla --

def test_the_matcher_answer_becomes_one_road_per_point():
    response = {"edges": [{"names": ["Hardstrasse"], "speed_limit": 50, "road_class": "secondary", "way_id": 11, "use": "road"},
                          {"names": [], "road_class": "tertiary", "way_id": 12, "use": "road"},
                          {"names": ["Seestrasse"], "speed_limit": 999, "road_class": "primary", "way_id": 13}],
                "matched_points": [{"type": "matched", "edge_index": 0}, {"type": "interpolated", "edge_index": 1}, {"type": "unmatched"},
                                   {"type": "matched", "edge_index": 2}, {"type": "matched", "edge_index": 9}]}
    got = valhalla.parse_match(response, 6)
    assert got[0] == {"limit_kmh": 50, "road_class": "secondary", "name": "Hardstrasse", "way_id": 11, "use": "road"}
    assert got[1]["limit_kmh"] is None and got[1]["name"] is None and got[1]["road_class"] == "tertiary"
    assert got[2] is None and got[4] is None and got[5] is None                                       # unmatched, a bad edge index, and a point the answer did not cover
    assert got[3]["limit_kmh"] is None                                                                  # 999 km/h is not a speed limit


@pytest.mark.parametrize("total,expected", [
    (0, []), (10, [(0, 10, 0)]), (1500, [(0, 1500, 0)]),
    (1501, [(0, 1500, 0), (1475, 1501, 1500)]),
    (3000, [(0, 1500, 0), (1475, 2975, 1500), (2950, 3000, 2975)]),
])
def test_long_tracks_are_matched_in_overlapping_chunks_that_cover_every_point_once(total, expected):
    ranges = valhalla.chunk_ranges(total)
    assert ranges == expected
    owned = [i for start, end, keep in ranges for i in range(keep, end)]
    assert owned == list(range(total))


def test_a_stretch_that_cannot_be_matched_costs_only_its_own_chunk(monkeypatch):
    calls = []
    def fake(points):
        calls.append(len(points))
        if len(calls) == 2:
            raise valhalla.NoMatch("no path")
        return {"edges": [{"road_class": "primary", "speed_limit": 80}], "matched_points": [{"type": "matched", "edge_index": 0}] * len(points)}
    monkeypatch.setattr(valhalla, "trace_attributes", fake)
    result = valhalla.match_points([(47.0, 8.0)] * 3000)
    assert len(calls) == 3 and result[0]["limit_kmh"] == 80 and result[1499]["limit_kmh"] == 80
    assert result[1500] is None and result[2974] is None and result[2975]["limit_kmh"] == 80


def test_valhalla_errors_are_readable(monkeypatch):
    class R:
        def __init__(self, status, payload=None): self.status_code, self._p = status, payload
        def json(self):
            if self._p is None: raise ValueError("x")
            return self._p
    monkeypatch.setattr(valhalla.httpx, "post", lambda *a, **k: R(400, {"error_code": 443, "error": "No path could be found for input"}))
    with pytest.raises(valhalla.NoMatch):
        valhalla.trace_attributes([(47.0, 8.0)])
    monkeypatch.setattr(valhalla.httpx, "post", lambda *a, **k: R(500, {}))
    with pytest.raises(valhalla.ValhallaUnavailable, match=r"\(500\)"):
        valhalla.trace_attributes([(47.0, 8.0)])
    monkeypatch.setattr(valhalla.httpx, "post", lambda *a, **k: R(200))
    with pytest.raises(valhalla.ValhallaUnavailable, match="unreadable"):
        valhalla.trace_attributes([(47.0, 8.0)])

    def boom(*a, **k):
        raise valhalla.httpx.ConnectError("refused")
    monkeypatch.setattr(valhalla.httpx, "post", boom)
    with pytest.raises(valhalla.ValhallaUnavailable, match="could not be reached"):
        valhalla.trace_attributes([(47.0, 8.0)])


# ------------------------------------------------------------------------------------------------------------------------ limits along a route --

def tagged(kmh):
    return {"limit_kmh": kmh, "road_class": "secondary"}


def test_a_route_gets_its_tagged_limits_as_change_points():
    d = [i * 30.0 for i in range(100)]
    m = [tagged(50)] * 40 + [tagged(80)] * 60
    assert limits.route_limits(d, m) == [{"along_m": 0, "kmh": 50}, {"along_m": 1200, "kmh": 80}]


def test_an_estimated_or_unmatched_stretch_has_no_limit_to_offer():
    d = [i * 30.0 for i in range(60)]
    m = [tagged(50)] * 20 + [{"limit_kmh": None, "road_class": "secondary"}] * 20 + [None] * 20
    assert limits.route_limits(d, m) == [{"along_m": 0, "kmh": 50}, {"along_m": 600, "kmh": None}]


def test_a_glitch_shorter_than_a_stretch_is_not_a_new_limit():
    d = [i * 30.0 for i in range(100)]
    m = [tagged(80)] * 40 + [tagged(30)] * 3 + [tagged(80)] * 57                       # 90 m of 30 at a junction
    assert limits.route_limits(d, m) == [{"along_m": 0, "kmh": 80}]


def test_no_points_no_limits():
    assert limits.route_limits([], []) == []
