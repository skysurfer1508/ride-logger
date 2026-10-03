"""Where the sun is, from the date, the time and a position alone (the NOAA solar position approximation: good to about a minute, which is plenty for "sunset in
twenty minutes"). Pure functions: no network, no tables. Used to tell a rider how much of a planned ride falls after dark.
"""
import math
from datetime import datetime, timedelta, timezone
from typing import Optional

SUNSET_DEG = -0.833                 # the sun's upper edge on the horizon, with refraction
DUSK_DEG = -6.0                     # civil twilight ends: headlights on, riding in the dark


def elevation_deg(lat: float, lon: float, when: datetime) -> float:
    """The sun's height above the horizon, in degrees (negative below it) at `when` (a timezone-aware time)."""
    when = when.astimezone(timezone.utc)
    day = when.timetuple().tm_yday
    hours = when.hour + when.minute / 60.0 + when.second / 3600.0
    g = 2.0 * math.pi / 365.0 * (day - 1 + (hours - 12.0) / 24.0)
    equation_min = 229.18 * (0.000075 + 0.001868 * math.cos(g) - 0.032077 * math.sin(g) - 0.014615 * math.cos(2 * g) - 0.040849 * math.sin(2 * g))
    declination = (0.006918 - 0.399912 * math.cos(g) + 0.070257 * math.sin(g) - 0.006758 * math.cos(2 * g) + 0.000907 * math.sin(2 * g)
                   - 0.002697 * math.cos(3 * g) + 0.00148 * math.sin(3 * g))
    solar_minutes = hours * 60.0 + equation_min + 4.0 * lon
    hour_angle = math.radians(solar_minutes / 4.0 - 180.0)
    la = math.radians(lat)
    cos_zenith = math.sin(la) * math.sin(declination) + math.cos(la) * math.cos(declination) * math.cos(hour_angle)
    return 90.0 - math.degrees(math.acos(max(-1.0, min(1.0, cos_zenith))))


def _crossing(lat: float, lon: float, start: datetime, hours: float, threshold: float, rising: bool) -> Optional[datetime]:
    """The first minute within `hours` of `start` at which the sun crosses `threshold` going up (`rising`) or down."""
    previous = elevation_deg(lat, lon, start)
    for minute in range(1, int(hours * 60) + 1):
        moment = start + timedelta(minutes=minute)
        now = elevation_deg(lat, lon, moment)
        if rising and previous < threshold <= now or not rising and previous >= threshold > now:
            return moment
        previous = now
    return None


def evening(lat: float, lon: float, after: datetime) -> dict:
    """The next sunset and the next end of civil twilight after `after`: {"sunset": datetime | None, "dusk": datetime | None} (None in polar summer or winter,
    when the sun does not cross the line within a day)."""
    return {"sunset": _crossing(lat, lon, after, 24.0, SUNSET_DEG, rising=False), "dusk": _crossing(lat, lon, after, 24.0, DUSK_DEG, rising=False)}


def dawn(lat: float, lon: float, after: datetime) -> Optional[datetime]:
    """The next start of civil twilight after `after`."""
    return _crossing(lat, lon, after, 24.0, DUSK_DEG, rising=True)


def is_dark(lat: float, lon: float, when: datetime) -> bool:
    """Past the end of civil twilight (or before its start in the morning): lights on."""
    return elevation_deg(lat, lon, when) < DUSK_DEG
