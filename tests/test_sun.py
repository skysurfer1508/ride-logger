"""Sunset and dusk (app/sun.py) against values published for these places and dates, to within a few minutes."""
from datetime import datetime, timedelta, timezone

import pytest

from app import sun

LONDON = (51.5074, -0.1278)
ZURICH = (47.3769, 8.5417)


def minutes(moment, hour, minute):
    return (moment - moment.replace(hour=hour, minute=minute, second=0, microsecond=0)).total_seconds() / 60.0


def test_sunset_in_london_on_the_summer_solstice():
    e = sun.evening(*LONDON, datetime(2024, 6, 21, 12, tzinfo=timezone.utc))
    assert minutes(e["sunset"], 20, 21) == pytest.approx(0, abs=3)               # 21:21 BST


def test_sunset_in_zurich_at_midwinter_and_midsummer():
    winter = sun.evening(*ZURICH, datetime(2025, 12, 21, 12, tzinfo=timezone.utc))["sunset"]
    summer = sun.evening(*ZURICH, datetime(2024, 6, 21, 12, tzinfo=timezone.utc))["sunset"]
    assert minutes(winter, 15, 38) == pytest.approx(0, abs=3) and minutes(summer, 19, 29) == pytest.approx(0, abs=4)


def test_dusk_comes_after_sunset_and_dawn_before_the_next_sunrise():
    day = datetime(2026, 10, 2, 12, tzinfo=timezone.utc)
    e = sun.evening(*ZURICH, day)
    assert timedelta(minutes=20) < e["dusk"] - e["sunset"] < timedelta(minutes=45)
    assert sun.is_dark(*ZURICH, e["dusk"] + timedelta(minutes=5)) and not sun.is_dark(*ZURICH, e["dusk"] - timedelta(minutes=5))
    assert sun.dawn(*ZURICH, e["dusk"]) > e["dusk"]


def test_the_midnight_sun_never_sets():
    assert sun.evening(78.0, 15.0, datetime(2024, 6, 21, 12, tzinfo=timezone.utc))["sunset"] is None
