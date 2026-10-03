"""What a planned ride will meet on the way: rain, snow, cold, wind and the dark. The forecast (Open-Meteo, see weather.py) is read at a handful of points along the
route, each at the time the rider is expected there; the light comes from sun.py. Everything that decides something is a pure function of those samples
(tests/test_conditions.py); only `forecast` talks to the network, and it never raises: a ride without a forecast still gets its sunset.
"""
import math
from datetime import datetime, timedelta, timezone
from typing import Optional, Sequence
from zoneinfo import ZoneInfo

from . import curvature, sun, weather
from .config import settings

SAMPLE_EVERY_M = 15_000.0
MIN_SAMPLES, MAX_SAMPLES = 2, 10
RAIN_MM = 0.3                      # an hour with at least this much rain is a wet hour
COLD_C = 3.0                       # at or below this the road may be icy
GUST_KMH = 60.0
SNOW_CODES = {71, 73, 75, 77, 85, 86}
STORM_CODES = {95, 96, 99}
FREEZING_CODES = {56, 57, 66, 67}
MAX_LOOKAHEAD_H = 36


def sample_points(shape: Sequence[tuple[float, float]], count: Optional[int] = None) -> list[dict]:
    """Evenly spaced points along the line, with how far along each is: [{"along_m", "lat", "lon"}, ...] (the first and the last included)."""
    pts = curvature.resample(list(shape), 100.0)
    dist = curvature._cumulative(pts)
    total = dist[-1] if dist else 0.0
    if count is None:
        count = min(MAX_SAMPLES, max(MIN_SAMPLES, int(round(total / SAMPLE_EVERY_M)) + 1))
    out = []
    for k in range(count):
        target = total * k / (count - 1) if count > 1 else 0.0
        i = min(range(len(pts)), key=lambda x: abs(dist[x] - target)) if pts else 0
        out.append({"along_m": round(dist[i]), "lat": round(pts[i][0], 5), "lon": round(pts[i][1], 5)})
    return out


def eta(depart: datetime, duration_s: float, along_m: float, total_m: float) -> datetime:
    """When the rider is expected `along_m` metres along a route that takes `duration_s` seconds (an even pace)."""
    return depart + timedelta(seconds=duration_s * (along_m / total_m if total_m > 0 else 0.0))


def hour_values(hourly: dict, when: datetime) -> Optional[dict]:
    """The forecast hour containing `when` (UTC): {"temperature", "precipitation", "gust", "code"} with None for anything missing."""
    times = hourly.get("time") or []
    key = when.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:00")
    try:
        i = times.index(key)
    except ValueError:
        return None

    def at(name: str):
        values = hourly.get(name) or []
        v = values[i] if i < len(values) else None
        return None if v is None or (isinstance(v, float) and math.isnan(v)) else v

    return {"temperature": at("temperature_2m"), "precipitation": at("precipitation"), "gust": at("wind_gusts_10m"), "code": at("weather_code")}


def alerts(samples: Sequence[dict]) -> list[dict]:
    """The first place each kind of trouble starts: [{"along_m", "kind": rain | snow | storm | ice | wind, "label"}, ...] in order along the route.
    `samples`: [{"along_m", "temperature", "precipitation", "gust", "code"}, ...] in order, any value may be None."""
    out: list[dict] = []
    seen: set[str] = set()

    def add(sample: dict, kind: str, label: str) -> None:
        if kind not in seen:
            seen.add(kind)
            out.append({"along_m": sample["along_m"], "kind": kind, "label": label})

    for s in samples:
        code = int(s["code"]) if s.get("code") is not None else None
        wet = (s.get("precipitation") or 0.0) >= RAIN_MM or (code is not None and code in weather.WET_CODES)
        if code in STORM_CODES:
            add(s, "storm", "thunderstorm possible")
        elif code in SNOW_CODES:
            add(s, "snow", "snow likely")
        elif wet:
            add(s, "rain", "rain likely")
        t = s.get("temperature")
        if (t is not None and t <= COLD_C) or code in FREEZING_CODES:
            add(s, "ice", f"cold, {round(t)} degrees, watch for ice" if t is not None else "freezing rain, watch for ice")
        if (s.get("gust") or 0.0) >= GUST_KMH:
            add(s, "wind", "strong gusts")
    return out


def light(lat: float, lon: float, depart: datetime, duration_s: float, tz: ZoneInfo) -> dict:
    """The evening for a ride starting at `depart` that takes `duration_s`: {"sunset": "19:06" | None, "dusk": "19:36" | None, "dark_min": minutes of the ride after dusk
    (0 if it ends before)}. Times are written in `tz` (the rider's own clock)."""
    end = depart + timedelta(seconds=duration_s)
    evening = sun.evening(lat, lon, depart)
    dusk = evening["dusk"]
    dark = 0.0
    if sun.is_dark(lat, lon, depart):                       # leaving before sunrise: dark until dawn
        morning = sun.dawn(lat, lon, depart)
        dark = (min(end, morning) - depart).total_seconds() if morning else duration_s
    elif dusk is not None and dusk < end:
        dark = (end - dusk).total_seconds()
    dark = round(dark / 60.0)

    def clock(moment: Optional[datetime]) -> Optional[str]:
        return moment.astimezone(tz).strftime("%H:%M") if moment else None

    return {"sunset": clock(evening["sunset"]), "dusk": clock(evening["dusk"]), "dark_min": max(0, dark)}


def spoken_summary(alert_list: Sequence[dict], lit: dict) -> str:
    """One short heads-up for the start of the ride ('' when there is nothing to say)."""
    parts: list[str] = []
    first = alert_list[0] if alert_list else None
    if first:
        km = first["along_m"] / 1000.0
        where = "from the start" if km < 1.0 else f"after {round(km)} kilometers"
        parts.append(f"{first['label'].capitalize()} {where}.")
    if lit.get("dark_min", 0) >= 10 and lit.get("dusk"):
        parts.append(f"Sunset is at {lit['sunset']}, about {lit['dark_min']} minutes of this ride are after dark." if lit.get("sunset")
                     else f"About {lit['dark_min']} minutes of this ride are after dark.")
    return " ".join(parts)


_cache: dict = {}


def forecast(points: Sequence[dict], depart: datetime, duration_s: float, total_m: float, now: Optional[datetime] = None) -> list[dict]:
    """The samples (see `alerts`) for the sample points, or [] when the forecast cannot be had. Cached for a quarter of an hour per place and hour."""
    now = now or datetime.now(timezone.utc)
    if not settings.weather_enabled or not points:
        return []
    key = (tuple((round(p["lat"], 1), round(p["lon"], 1)) for p in points), depart.strftime("%Y-%m-%dT%H"))
    cached = _cache.get(key)
    if cached and now.timestamp() - cached[0] < 900:
        hourlies = cached[1]
    else:
        try:
            hourlies = weather.fetch_many([(p["lat"], p["lon"]) for p in points], forecast_days=2)
        except weather.WeatherUnavailable:
            return []
        if len(_cache) > 100:
            _cache.clear()
        _cache[key] = (now.timestamp(), hourlies)
    out = []
    for p, hourly in zip(points, hourlies):
        values = hour_values(hourly, eta(depart, duration_s, p["along_m"], total_m))
        if values:
            out.append({"along_m": p["along_m"], **values})
    return out


def temperature_range(samples: Sequence[dict]) -> Optional[tuple[float, float]]:
    temps = [s["temperature"] for s in samples if s.get("temperature") is not None]
    return (min(temps), max(temps)) if temps else None
