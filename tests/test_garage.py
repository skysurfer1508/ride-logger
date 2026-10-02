"""app/garage.py: the pure rules. The database and HTTP side are in tests/test_garage_api.py."""
from datetime import date

import pytest

from app import garage


# ------------------------------------------------------------------------------------------------------------------------- add_months --

@pytest.mark.parametrize("start,months,expected", [
    (date(2026, 1, 15), 1, date(2026, 2, 15)),
    (date(2026, 1, 31), 1, date(2026, 2, 28)),            # no 31st in February
    (date(2028, 1, 31), 1, date(2028, 2, 29)),            # leap year
    (date(2026, 11, 30), 3, date(2027, 2, 28)),           # across the new year
    (date(2026, 5, 31), 1, date(2026, 6, 30)),
    (date(2026, 12, 15), 12, date(2027, 12, 15)),
    (date(2026, 3, 10), 0, date(2026, 3, 10)),
    (date(2026, 1, 1), 25, date(2028, 2, 1)),
])
def test_add_months(start, months, expected):
    assert garage.add_months(start, months) == expected


# ----------------------------------------------------------------------------------------------------------------------- service due --

TODAY = date(2026, 10, 2)


def status(**kw):
    base = dict(interval_km=6000, interval_months=12, last_km=10_000.0, last_date=date(2026, 6, 1), odometer_km=11_000.0, today=TODAY)
    return garage.service_status(**{**base, **kw})


def test_a_service_well_within_both_intervals_is_ok():
    s = status()
    assert s["state"] == "ok" and s["remaining_km"] == 5000 and s["due_km"] == 16_000 and s["due_date"] == "2027-06-01"
    assert s["remaining_days"] == 242 and s["limited_by"] == "date"                 # 83 % of the distance left but only 66 % of the time


def test_it_is_due_at_whichever_interval_runs_out_first():
    by_km = status(odometer_km=16_200.0)                                          # 200 km past, dates still fine
    assert by_km["state"] == "overdue" and by_km["remaining_km"] == -200 and by_km["limited_by"] == "km"
    by_date = status(last_date=date(2025, 6, 1), odometer_km=10_100.0)            # a year and four months, hardly ridden
    assert by_date["state"] == "overdue" and by_date["remaining_days"] < 0 and by_date["limited_by"] == "date"


def test_due_soon_by_distance_uses_a_tenth_of_the_interval_capped_at_500_km():
    assert status(odometer_km=15_500.0)["state"] == "soon"                          # 500 left of a 6000 interval: min(500, 600) = 500
    assert status(odometer_km=15_400.0)["state"] == "ok"                            # 600 left
    short = status(interval_km=2000, odometer_km=11_850.0, last_km=10_000.0, interval_months=None, last_date=None)   # 150 left; a tenth is 200
    assert short["state"] == "soon"
    assert status(interval_km=2000, odometer_km=11_700.0, last_km=10_000.0, interval_months=None, last_date=None)["state"] == "ok"   # 300 left


def test_due_soon_by_date_is_thirty_days():
    ahead_31 = status(last_date=date(2025, 11, 2))                                 # due 2026-11-02, 31 days ahead: not yet
    assert ahead_31["state"] == "ok" and ahead_31["remaining_days"] == 31
    due = status(last_date=date(2025, 11, 1))                                      # due 2026-11-01: 30 days
    assert due["state"] == "soon" and due["remaining_days"] == 30
    assert status(last_date=date(2025, 11, 3))["state"] == "ok"


def test_exactly_at_the_limit_is_not_yet_overdue():
    assert status(odometer_km=16_000.0)["state"] == "soon"                          # 0 km left
    assert status(odometer_km=16_000.1)["state"] == "overdue"


def test_a_service_with_only_one_interval():
    only_km = status(interval_months=None, last_date=None)
    assert only_km["due_date"] is None and only_km["remaining_days"] is None and only_km["limited_by"] == "km"
    only_months = status(interval_km=None, last_km=None)
    assert only_months["due_km"] is None and only_months["remaining_km"] is None and only_months["limited_by"] == "date"


def test_nothing_to_count_from_means_never_done():
    for kw in (dict(last_km=None, last_date=None), dict(interval_months=None, last_km=None), dict(interval_km=None, last_date=None)):
        assert status(**kw)["state"] == "never_done"


def test_the_tighter_interval_is_named():
    km_tight = status(odometer_km=15_000.0)                                       # 1000 of 6000 km left (17 %) against ~8.5 of 12 months (70 %)
    assert km_tight["limited_by"] == "km"
    date_tight = status(last_date=date(2025, 12, 1), odometer_km=10_100.0)        # ~2 of 12 months left against 5900 of 6000 km
    assert date_tight["limited_by"] == "date"


# ----------------------------------------------------------------------------------------------------------------------------- fuel --

def fill(id, odo, litres, full=True, price=None, day=1):
    return {"id": id, "date": f"2026-09-{day:02d}", "odometer_km": float(odo), "litres": float(litres), "price": price, "full_tank": full}


def test_consumption_between_two_full_tanks():
    stats = garage.fuel_stats([fill(1, 1000, 12.0), fill(2, 1250, 11.0, day=5)])
    assert stats["fills"][0]["l_per_100km"] is None                                  # the first full tank is only the starting point
    assert stats["fills"][1]["l_per_100km"] == 4.4 and stats["fills"][1]["km_since"] == 250
    assert stats["average_l_per_100km"] == 4.4 and stats["measured_km"] == 250


def test_a_part_fill_in_between_adds_its_litres_but_does_not_end_the_interval():
    stats = garage.fuel_stats([fill(1, 1000, 12.0), fill(2, 1100, 4.0, full=False, day=3), fill(3, 1300, 8.0, day=6)])
    assert stats["fills"][1]["l_per_100km"] is None
    assert stats["fills"][2]["l_per_100km"] == 4.0 and stats["fills"][2]["km_since"] == 300           # (4 + 8) litres over 300 km


def test_the_average_weighs_by_distance_not_by_fill():
    stats = garage.fuel_stats([fill(1, 0, 10), fill(2, 100, 10, day=2), fill(3, 500, 20, day=3)])    # 10 L/100 km over 100 km, then 5 L/100 km over 400 km
    assert [f["l_per_100km"] for f in stats["fills"]] == [None, 10.0, 5.0]
    assert stats["average_l_per_100km"] == 6.0 and stats["measured_km"] == 500


def test_nothing_can_be_worked_out_without_two_full_tanks():
    assert garage.fuel_stats([])["average_l_per_100km"] is None
    only_one = garage.fuel_stats([fill(1, 1000, 12)])
    assert only_one["average_l_per_100km"] is None and only_one["total_litres"] == 12
    part_first = garage.fuel_stats([fill(1, 1000, 5, full=False), fill(2, 1200, 10)])
    assert part_first["fills"][1]["l_per_100km"] is None                              # nothing to count from yet
    assert garage.fuel_stats([fill(1, 1000, 5, full=False), fill(2, 1200, 10, full=False)])["average_l_per_100km"] is None


def test_an_odometer_that_does_not_go_up_is_skipped_and_starts_over():
    stats = garage.fuel_stats([fill(1, 1000, 10), fill(2, 1000, 10, day=2), fill(3, 1200, 8, day=3)])
    assert stats["fills"][1]["l_per_100km"] is None                                    # same reading: no distance to divide by
    assert stats["fills"][2]["l_per_100km"] == 4.0                                     # counted from the second one


def test_fills_are_ordered_by_odometer_whatever_order_they_were_entered_in():
    stats = garage.fuel_stats([fill(2, 1250, 11.0, day=5), fill(1, 1000, 12.0)])
    assert [f["id"] for f in stats["fills"]] == [1, 2] and stats["fills"][1]["l_per_100km"] == 4.4


def test_money():
    stats = garage.fuel_stats([fill(1, 1000, 10.0, price=20.0), fill(2, 1200, 10.0, price=21.0, day=2), fill(3, 1300, 5.0, price=None, day=3)])
    assert stats["total_spent"] == 41.0 and stats["total_litres"] == 25.0
    assert stats["average_price_per_litre"] == 2.05                                    # 41 paid for the 20 litres that had a price
    assert garage.cost_per_km(41.0, 200.0) == 0.205 and garage.cost_per_km(10, 0) is None
