"""The garage's arithmetic: when a service is due, how much a bike really burns, what it costs. Pure functions (no database, no network), so every rule
is unit-tested (tests/test_garage.py). The tables and the HTTP side are in garage_store.py and routers/api_v1.py.
"""
import calendar
from datetime import date
from typing import Optional, Sequence

DUE_SOON_DAYS = 30            # a date-based service is "due soon" this many days ahead ...
DUE_SOON_KM_CAP = 500.0       # ... a distance-based one this many km ahead, or a tenth of its interval if that is smaller
DUE_SOON_FRACTION = 0.1


def add_months(d: date, months: int) -> date:
    """The same day `months` later; a 31st that does not exist in the target month becomes that month's last day (Jan 31 + 1 month = Feb 28/29)."""
    index = d.month - 1 + months
    year, month = d.year + index // 12, index % 12 + 1
    return date(year, month, min(d.day, calendar.monthrange(year, month)[1]))


def service_status(*, interval_km: Optional[float], interval_months: Optional[int], last_km: Optional[float], last_date: Optional[date],
                   odometer_km: float, today: date) -> dict:
    """Where one service item stands. A service has a distance interval, a time interval or both, and is due at whichever comes first.

    state: never_done (nothing known to count from) | ok | soon | overdue. `limited_by` says which interval is the tighter one right now.
    """
    due_km = last_km + interval_km if (interval_km and last_km is not None) else None
    due_date = add_months(last_date, interval_months) if (interval_months and last_date is not None) else None
    if due_km is None and due_date is None:
        return {"state": "never_done", "due_km": None, "due_date": None, "remaining_km": None, "remaining_days": None, "limited_by": None}
    remaining_km = None if due_km is None else round(due_km - odometer_km, 1)
    remaining_days = None if due_date is None else (due_date - today).days

    overdue = (remaining_km is not None and remaining_km < 0) or (remaining_days is not None and remaining_days < 0)
    soon_km = remaining_km is not None and interval_km and remaining_km <= min(DUE_SOON_KM_CAP, DUE_SOON_FRACTION * interval_km)
    soon_days = remaining_days is not None and remaining_days <= DUE_SOON_DAYS
    state = "overdue" if overdue else "soon" if (soon_km or soon_days) else "ok"

    # which interval is closer to running out, as a share of its own length
    km_share = None if remaining_km is None else remaining_km / interval_km
    day_share = None if remaining_days is None else remaining_days / (interval_months * 30.4)
    if km_share is None:
        limited_by = "date"
    elif day_share is None:
        limited_by = "km"
    else:
        limited_by = "km" if km_share <= day_share else "date"
    return {"state": state, "due_km": None if due_km is None else round(due_km, 1), "due_date": None if due_date is None else due_date.isoformat(),
            "remaining_km": remaining_km, "remaining_days": remaining_days, "limited_by": limited_by}


def fuel_stats(fills: Sequence[dict]) -> dict:
    """Consumption from a fuel log. Each fill: id, date, odometer_km, litres, price (the total paid, or None), full_tank (bool).

    The standard method: litres per 100 km are only worked out between two FULL fills, using every litre put in after the first one up to and including
    the second (a part fill in between adds its litres but does not end the interval). The first full fill is only the starting point: its litres were
    burnt before it. An interval whose odometer does not go up is skipped and starts a new one. Returns the fills (oldest odometer first) with
    `l_per_100km` and `km_since` filled in where an interval ended, and a summary.
    """
    rows = sorted(fills, key=lambda f: (f["odometer_km"], f["date"], f["id"]))
    out: list[dict] = []
    last_full: Optional[dict] = None
    litres_since = 0.0
    burnt_litres = 0.0
    burnt_km = 0.0
    for fill in rows:
        entry = {**fill, "l_per_100km": None, "km_since": None}
        if last_full is None:
            if fill["full_tank"]:
                last_full, litres_since = fill, 0.0
        else:
            litres_since += fill["litres"]
            if fill["full_tank"]:
                km = fill["odometer_km"] - last_full["odometer_km"]
                if km > 0:
                    entry["l_per_100km"] = round(litres_since / km * 100, 2)
                    entry["km_since"] = round(km, 1)
                    burnt_litres += litres_since
                    burnt_km += km
                last_full, litres_since = fill, 0.0
        out.append(entry)
    paid = [f["price"] for f in rows if f.get("price") is not None]
    litres_paid = [f["litres"] for f in rows if f.get("price") is not None]
    return {
        "fills": out,
        "average_l_per_100km": round(burnt_litres / burnt_km * 100, 2) if burnt_km > 0 else None,
        "measured_km": round(burnt_km, 1),
        "total_litres": round(sum(f["litres"] for f in rows), 2),
        "total_spent": round(sum(paid), 2),
        "average_price_per_litre": round(sum(paid) / sum(litres_paid), 3) if paid and sum(litres_paid) > 0 else None,
    }


def cost_per_km(total_cost: float, km: float) -> Optional[float]:
    return round(total_cost / km, 3) if km > 0 else None
