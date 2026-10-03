"""The weather during a ride, from Open-Meteo (free, no key, CC BY 4.0: https://open-meteo.com/en/terms). Recent rides use the forecast API's `past_days`
(up to 92 days back), older ones the archive API. Only the rounded start position of the ride is sent; the answer is cached with the ride (routers/insights).
Both endpoints were run against the live service when this was written: hourly arrays in UTC, units in the answer.
"""
import math
from datetime import datetime, timedelta, timezone
from typing import Optional

import httpx

from .config import settings

FORECAST_URL = "https://api.open-meteo.com/v1/forecast"
ARCHIVE_URL = "https://archive-api.open-meteo.com/v1/archive"
HOURLY = "temperature_2m,precipitation,wind_speed_10m,wind_gusts_10m,weather_code"
MAX_PAST_DAYS = 92
ARCHIVE_AFTER_DAYS = 90
TIMEOUT_S = 20.0
ATTRIBUTION = "Weather data by Open-Meteo.com (CC BY 4.0)"

# WMO weather codes as Open-Meteo documents them
CONDITIONS = {0: "Clear", 1: "Mostly clear", 2: "Partly cloudy", 3: "Overcast", 45: "Fog", 48: "Freezing fog", 51: "Light drizzle", 53: "Drizzle", 55: "Heavy drizzle",
              56: "Freezing drizzle", 57: "Heavy freezing drizzle", 61: "Light rain", 63: "Rain", 65: "Heavy rain", 66: "Freezing rain", 67: "Heavy freezing rain",
              71: "Light snow", 73: "Snow", 75: "Heavy snow", 77: "Snow grains", 80: "Light showers", 81: "Showers", 82: "Heavy showers", 85: "Snow showers",
              86: "Heavy snow showers", 95: "Thunderstorm", 96: "Thunderstorm with hail", 99: "Thunderstorm with heavy hail"}
WET_CODES = {code for code in CONDITIONS if 51 <= code <= 99}


class WeatherUnavailable(Exception):
    """The weather could not be fetched. The message is safe to show."""


def condition(code: Optional[int]) -> Optional[str]:
    if code is None:
        return None
    if code in CONDITIONS:
        return CONDITIONS[code]
    return CONDITIONS[max(c for c in CONDITIONS if c <= code)] if code > 0 else None      # an unknown code is read as the nearest known one below it


def _get(url: str, params: dict) -> dict:
    try:
        response = httpx.get(url, params=params, headers={"User-Agent": settings.osm_user_agent}, timeout=TIMEOUT_S)
    except httpx.HTTPError as e:
        raise WeatherUnavailable("The weather service could not be reached.") from e
    if response.status_code == 429:
        raise WeatherUnavailable("The weather service says there were too many requests. Try again later.")
    if response.status_code != 200:
        raise WeatherUnavailable(f"The weather service answered with an error ({response.status_code}).")
    try:
        data = response.json()
    except ValueError as e:
        raise WeatherUnavailable("The weather service sent something unreadable.") from e
    if not isinstance(data, dict) or "hourly" not in data:
        raise WeatherUnavailable("The weather service had no data for that day.")
    return data["hourly"]


def fetch(lat: float, lon: float, start: datetime, end: datetime, now: Optional[datetime] = None) -> dict:
    """The hourly arrays covering the ride (UTC). The position is rounded to 0.1 degree (about 10 km): enough for weather, and less of your route is sent."""
    now = now or datetime.now(timezone.utc)
    params = {"latitude": round(lat, 1), "longitude": round(lon, 1), "hourly": HOURLY, "timezone": "UTC", "wind_speed_unit": "kmh"}
    days_ago = (now - start).days
    if days_ago > ARCHIVE_AFTER_DAYS:
        return _get(ARCHIVE_URL, {**params, "start_date": start.date().isoformat(), "end_date": end.date().isoformat()})
    return _get(FORECAST_URL, {**params, "past_days": min(max(days_ago + 1, 1), MAX_PAST_DAYS), "forecast_days": 1})


def fetch_many(points: list[tuple[float, float]], forecast_days: int = 2) -> list[dict]:
    """The hourly forecast (UTC) for several places at once, in the order given: one request. Positions are rounded to 0.1 degree like `fetch`."""
    params = {"latitude": ",".join(str(round(lat, 1)) for lat, _ in points), "longitude": ",".join(str(round(lon, 1)) for _, lon in points), "hourly": HOURLY,
              "timezone": "UTC", "wind_speed_unit": "kmh", "forecast_days": forecast_days}
    try:
        response = httpx.get(FORECAST_URL, params=params, headers={"User-Agent": settings.osm_user_agent}, timeout=TIMEOUT_S)
    except httpx.HTTPError as e:
        raise WeatherUnavailable("The weather service could not be reached.") from e
    if response.status_code != 200:
        raise WeatherUnavailable(f"The weather service answered with an error ({response.status_code}).")
    try:
        data = response.json()
    except ValueError as e:
        raise WeatherUnavailable("The weather service sent something unreadable.") from e
    places = data if isinstance(data, list) else [data]            # one place comes back as an object, several as a list
    hourlies = [p.get("hourly") for p in places if isinstance(p, dict)]
    if len(hourlies) != len(points) or not all(isinstance(h, dict) for h in hourlies):
        raise WeatherUnavailable("The weather service had no data for those places.")
    return hourlies


def _hour(text: str) -> datetime:
    return datetime.fromisoformat(text).replace(tzinfo=timezone.utc)


def summarize(hourly: dict, start: datetime, end: datetime) -> Optional[dict]:
    """What the weather was over the ride: temperature at the start, the end and the extremes, rain, the strongest wind and gust, and the worst conditions."""
    times = hourly.get("time") or []
    first = start.replace(minute=0, second=0, microsecond=0)
    last = end.replace(minute=0, second=0, microsecond=0)
    picked = [i for i, t in enumerate(times) if first <= _hour(t) <= last]
    if not picked:
        return None

    def series(key: str) -> list:
        values = hourly.get(key) or []
        return [(i, values[i]) for i in picked if i < len(values) and values[i] is not None and not (isinstance(values[i], float) and math.isnan(values[i]))]

    temps, rain, wind, gusts, codes = series("temperature_2m"), series("precipitation"), series("wind_speed_10m"), series("wind_gusts_10m"), series("weather_code")
    if not temps and not codes:
        return None
    worst = max((int(c) for _, c in codes), default=None)
    rain_mm = round(sum(v for _, v in rain), 1) if rain else None
    return {
        "temperature_start_c": round(temps[0][1], 1) if temps else None,
        "temperature_end_c": round(temps[-1][1], 1) if temps else None,
        "temperature_min_c": round(min(v for _, v in temps), 1) if temps else None,
        "temperature_max_c": round(max(v for _, v in temps), 1) if temps else None,
        "precipitation_mm": rain_mm,
        "wind_max_kmh": round(max(v for _, v in wind)) if wind else None,
        "gust_max_kmh": round(max(v for _, v in gusts)) if gusts else None,
        "condition": condition(worst),
        "condition_start": condition(int(codes[0][1])) if codes else None,
        "wet": bool((rain_mm or 0) >= 0.2 or (worst is not None and worst in WET_CODES)),
        "attribution": ATTRIBUTION,
    }
