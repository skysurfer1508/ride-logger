"""The garage API (bikes, service, fuel, costs) for the iOS app: /api/v1/garage/*. Same rules as the rest of /api/v1: a plain 401 when logged out, every
change needs the X-RideLog-Client header, and something that belongs to someone else is the same 404 as something that does not exist. Mistakes in the
input come back as a 400 with a sentence the app can show as it is.
"""
import math
from datetime import date, datetime, timedelta, timezone
from typing import Optional

from fastapi import APIRouter, Depends, Form, HTTPException
from fastapi.responses import JSONResponse

from .. import garage_store as store
from ..auth import current_owner_sub, require_api_client, require_api_login
from ..db import get_db

router = APIRouter(prefix="/api/v1", dependencies=[Depends(require_api_login)])
CLIENT = [Depends(require_api_client)]


def _today() -> date:
    return datetime.now(timezone.utc).date()


def reply(payload: dict, status: int = 200) -> JSONResponse:
    return JSONResponse({"api": 1, **payload}, status_code=status, headers={"Cache-Control": "no-store"})


def _bad(message: str) -> HTTPException:
    return HTTPException(status_code=400, detail={"detail": "invalid_input", "message": message})


def _not_found() -> HTTPException:
    return HTTPException(status_code=404, detail="not_found")


# ------------------------------------------------------------------------------------------------------------------------------ parsing --

def _text(value: str, label: str, maxlen: int, required: bool = True) -> str:
    text = (value or "").strip()
    if required and not text:
        raise _bad(f"Please enter {label}.")
    if len(text) > maxlen:
        raise _bad(f"{label[:1].upper() + label[1:]} is too long (at most {maxlen} characters).")
    return text


def _number(value: str, label: str, low: float, high: float, required: bool = True) -> Optional[float]:
    text = (value or "").strip().replace(",", ".")
    if not text:
        if required:
            raise _bad(f"Please enter {label}.")
        return None
    try:
        number = float(text)
    except ValueError:
        raise _bad(f"{label[:1].upper() + label[1:]} must be a number.")
    if not math.isfinite(number) or not (low <= number <= high):
        raise _bad(f"{label[:1].upper() + label[1:]} must be between {low:g} and {high:g}.")
    return number


def _whole(value: str, label: str, low: int, high: int, required: bool = True) -> Optional[int]:
    number = _number(value, label, low, high, required)
    if number is None:
        return None
    if number != int(number):
        raise _bad(f"{label[:1].upper() + label[1:]} must be a whole number.")
    return int(number)


def _day(value: str, label: str, default: Optional[date] = None) -> date:
    text = (value or "").strip()
    if not text:
        if default is None:
            raise _bad(f"Please enter {label}.")
        return default
    try:
        parsed = date.fromisoformat(text)
    except ValueError:
        raise _bad(f"{label[:1].upper() + label[1:]} must look like 2026-09-28.")
    if parsed > _today() + timedelta(days=1):
        raise _bad(f"{label[:1].upper() + label[1:]} cannot be in the future.")
    if parsed.year < 1990:
        raise _bad(f"{label[:1].upper() + label[1:]} is too long ago.")
    return parsed


def _flag(value: str, default: bool = False) -> bool:
    text = (value or "").strip().lower()
    return default if not text else text in ("1", "true", "yes", "on")


def _detail(conn, owner: str, bike_id: int) -> dict:
    bike = store.get_bike(conn, owner, bike_id)
    if bike is None:
        raise _not_found()
    return store.bike_detail(conn, owner, bike, _today())


# ------------------------------------------------------------------------------------------------------------------------------- bikes --

@router.get("/garage")
def garage_overview(owner: str = Depends(current_owner_sub)):
    conn = get_db()
    try:
        today = _today()
        return reply({"bikes": [store.bike_summary(conn, owner, b, today) for b in store.list_bikes(conn, owner)]})
    finally:
        conn.close()


@router.post("/garage/bikes", dependencies=CLIENT)
def create_bike(name: str = Form(""), make: str = Form(""), model: str = Form(""), year: str = Form(""), start_odometer_km: str = Form("0"),
                start_date: str = Form(""), owner: str = Depends(current_owner_sub)):
    values = dict(
        name=_text(name, "a name for the bike", 60), make=_text(make, "the make", 40, required=False), model=_text(model, "the model", 40, required=False),
        year=_whole(year, "the year", 1900, 2100, required=False), start_odometer_km=_number(start_odometer_km or "0", "the odometer reading", 0, 2_000_000),
        start_date=_day(start_date, "the start date", default=_today()))
    conn = get_db()
    try:
        if len(store.list_bikes(conn, owner)) >= store.MAX_BIKES:
            raise _bad(f"You can have at most {store.MAX_BIKES} bikes.")
        bike_id = store.create_bike(conn, owner, **values)
        return reply({"bike_id": bike_id, **_detail(conn, owner, bike_id)})
    finally:
        conn.close()


@router.get("/garage/bikes/{bike_id}")
def bike_detail(bike_id: int, owner: str = Depends(current_owner_sub)):
    conn = get_db()
    try:
        return reply(_detail(conn, owner, bike_id))
    finally:
        conn.close()


@router.post("/garage/bikes/{bike_id}", dependencies=CLIENT)
def update_bike(bike_id: int, name: str = Form(""), make: str = Form(""), model: str = Form(""), year: str = Form(""), owner: str = Depends(current_owner_sub)):
    values = dict(name=_text(name, "a name for the bike", 60), make=_text(make, "the make", 40, required=False), model=_text(model, "the model", 40, required=False),
                  year=_whole(year, "the year", 1900, 2100, required=False))
    conn = get_db()
    try:
        if not store.update_bike(conn, owner, bike_id, **values):
            raise _not_found()
        return reply(_detail(conn, owner, bike_id))
    finally:
        conn.close()


@router.post("/garage/bikes/{bike_id}/default", dependencies=CLIENT)
def make_default(bike_id: int, owner: str = Depends(current_owner_sub)):
    conn = get_db()
    try:
        if not store.set_default(conn, owner, bike_id):
            raise _not_found()
        return reply(_detail(conn, owner, bike_id))
    finally:
        conn.close()


@router.post("/garage/bikes/{bike_id}/odometer", dependencies=CLIENT)
def set_odometer(bike_id: int, km: str = Form(""), owner: str = Depends(current_owner_sub)):
    reading = _number(km, "the odometer reading", 0, 2_000_000)
    conn = get_db()
    try:
        if not store.set_odometer(conn, owner, bike_id, reading):
            raise _not_found()
        return reply(_detail(conn, owner, bike_id))
    finally:
        conn.close()


@router.delete("/garage/bikes/{bike_id}", dependencies=CLIENT)
def delete_bike(bike_id: int, owner: str = Depends(current_owner_sub)):
    conn = get_db()
    try:
        if not store.delete_bike(conn, owner, bike_id):
            raise _not_found()
        return reply({"deleted": bike_id})
    finally:
        conn.close()


@router.post("/rides/{ride_id}/bike", dependencies=CLIENT)
def assign_ride(ride_id: int, bike_id: str = Form(""), owner: str = Depends(current_owner_sub)):
    """Puts a ride on a bike; an empty bike_id puts it back on 'the default bike'."""
    wanted = _whole(bike_id, "the bike", 1, 2**31, required=False)
    conn = get_db()
    try:
        if not store.assign_ride(conn, owner, ride_id, wanted):
            raise _not_found()
        return reply({"ride_id": ride_id, "bike_id": wanted})
    finally:
        conn.close()


# ----------------------------------------------------------------------------------------------------------------------------- service --

@router.post("/garage/bikes/{bike_id}/items", dependencies=CLIENT)
def add_item(bike_id: int, name: str = Form(""), interval_km: str = Form(""), interval_months: str = Form(""), last_done_date: str = Form(""),
             last_done_km: str = Form(""), count_from_now: str = Form(""), owner: str = Depends(current_owner_sub)):
    item_name = _text(name, "a name for the service", 60)
    every_km = _number(interval_km, "the distance interval", 1, 200_000, required=False)
    every_months = _whole(interval_months, "the time interval in months", 1, 240, required=False)
    if every_km is None and every_months is None:
        raise _bad("Give a distance interval, a time interval, or both.")
    conn = get_db()
    try:
        bike = store.get_bike(conn, owner, bike_id)
        if bike is None:
            raise _not_found()
        if store.count_items(conn, owner, bike_id) >= store.MAX_ITEMS_PER_BIKE:
            raise _bad(f"A bike can have at most {store.MAX_ITEMS_PER_BIKE} service items.")
        baseline_km = _number(last_done_km, "the odometer reading it was last done at", 0, 2_000_000, required=False)
        if last_done_date.strip() == "" and baseline_km is not None:
            raise _bad("Enter the date it was last done as well.")
        baseline_date = _day(last_done_date, "the date it was last done") if last_done_date.strip() else None
        item_id = store.add_item(conn, owner, bike_id, name=item_name, interval_km=every_km, interval_months=every_months)
        if baseline_date is not None:
            store.log_service(conn, owner, item_id, done_date=baseline_date, odometer=baseline_km, cost=None, note="Starting point")
        elif _flag(count_from_now):
            store.log_service(conn, owner, item_id, done_date=_today(), odometer=store.odometer_km(conn, owner, bike), cost=None, note="Counting from now")
        return reply({"item_id": item_id, **_detail(conn, owner, bike_id)})
    finally:
        conn.close()


@router.delete("/garage/items/{item_id}", dependencies=CLIENT)
def delete_item(item_id: int, owner: str = Depends(current_owner_sub)):
    conn = get_db()
    try:
        item = store.get_item(conn, owner, item_id)
        if item is None or not store.delete_item(conn, owner, item_id):
            raise _not_found()
        return reply(_detail(conn, owner, item["bike_id"]))
    finally:
        conn.close()


@router.post("/garage/items/{item_id}/done", dependencies=CLIENT)
def service_done(item_id: int, date_done: str = Form("", alias="date"), odometer_km: str = Form(""), cost: str = Form(""), note: str = Form(""),
                 owner: str = Depends(current_owner_sub)):
    done = _day(date_done, "the date", default=_today())
    reading = _number(odometer_km, "the odometer reading", 0, 2_000_000, required=False)
    spent = _number(cost, "the cost", 0, 100_000, required=False)
    text = _text(note, "the note", 200, required=False)
    conn = get_db()
    try:
        item = store.get_item(conn, owner, item_id)
        if item is None:
            raise _not_found()
        if reading is None:
            reading = store.odometer_km(conn, owner, store.get_bike(conn, owner, item["bike_id"]))
        store.log_service(conn, owner, item_id, done_date=done, odometer=reading, cost=spent, note=text)
        return reply(_detail(conn, owner, item["bike_id"]))
    finally:
        conn.close()


@router.delete("/garage/service-log/{log_id}", dependencies=CLIENT)
def delete_service_log(log_id: int, owner: str = Depends(current_owner_sub)):
    conn = get_db()
    try:
        row = conn.execute("SELECT bike_id FROM service_log WHERE id = ? AND owner_sub = ?", (log_id, owner)).fetchone()
        if row is None or not store.delete_service_log(conn, owner, log_id):
            raise _not_found()
        return reply(_detail(conn, owner, row["bike_id"]))
    finally:
        conn.close()


# ------------------------------------------------------------------------------------------------------------------------ fuel, expenses --

@router.post("/garage/bikes/{bike_id}/fuel", dependencies=CLIENT)
def add_fuel(bike_id: int, date_filled: str = Form("", alias="date"), odometer_km: str = Form(""), litres: str = Form(""), price: str = Form(""),
             full_tank: str = Form("1"), owner: str = Depends(current_owner_sub)):
    day = _day(date_filled, "the date", default=_today())
    reading = _number(odometer_km, "the odometer reading", 0, 2_000_000)
    amount = _number(litres, "the litres", 0.1, 200)
    paid = _number(price, "the price", 0, 10_000, required=False)
    conn = get_db()
    try:
        if store.add_fuel(conn, owner, bike_id, day=day, odometer=reading, litres=amount, price=paid, full_tank=_flag(full_tank, default=True)) is None:
            raise _not_found()
        return reply(_detail(conn, owner, bike_id))
    finally:
        conn.close()


@router.delete("/garage/fuel/{fuel_id}", dependencies=CLIENT)
def delete_fuel(fuel_id: int, owner: str = Depends(current_owner_sub)):
    conn = get_db()
    try:
        row = conn.execute("SELECT bike_id FROM fuel_log WHERE id = ? AND owner_sub = ?", (fuel_id, owner)).fetchone()
        if row is None or not store.delete_fuel(conn, owner, fuel_id):
            raise _not_found()
        return reply(_detail(conn, owner, row["bike_id"]))
    finally:
        conn.close()


@router.post("/garage/bikes/{bike_id}/expenses", dependencies=CLIENT)
def add_expense(bike_id: int, date_spent: str = Form("", alias="date"), category: str = Form(""), amount: str = Form(""), note: str = Form(""),
                owner: str = Depends(current_owner_sub)):
    day = _day(date_spent, "the date", default=_today())
    kind = _text(category, "the category", 40, required=False)
    total = _number(amount, "the amount", 0.01, 1_000_000)
    text = _text(note, "the note", 200, required=False)
    conn = get_db()
    try:
        if store.add_expense(conn, owner, bike_id, day=day, category=kind, amount=total, note=text) is None:
            raise _not_found()
        return reply(_detail(conn, owner, bike_id))
    finally:
        conn.close()


@router.delete("/garage/expenses/{expense_id}", dependencies=CLIENT)
def delete_expense(expense_id: int, owner: str = Depends(current_owner_sub)):
    conn = get_db()
    try:
        row = conn.execute("SELECT bike_id FROM expenses WHERE id = ? AND owner_sub = ?", (expense_id, owner)).fetchone()
        if row is None or not store.delete_expense(conn, owner, expense_id):
            raise _not_found()
        return reply(_detail(conn, owner, row["bike_id"]))
    finally:
        conn.close()
