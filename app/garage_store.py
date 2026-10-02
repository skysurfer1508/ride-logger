"""The garage's tables: bikes, service items and their log, fuel fills, other expenses. Every function takes the owner's `sub` and only ever touches that
owner's rows (a row that belongs to someone else behaves exactly like one that does not exist). The arithmetic is in garage.py.
"""
import sqlite3
from datetime import date
from typing import Optional

from . import garage

MAX_BIKES = 20
MAX_ITEMS_PER_BIKE = 60
LIST_LIMIT = 60


# ---------------------------------------------------------------------------------------------------------------------------------- bikes --

def get_bike(conn: sqlite3.Connection, owner: str, bike_id: int) -> Optional[sqlite3.Row]:
    return conn.execute("SELECT * FROM bikes WHERE id = ? AND owner_sub = ?", (bike_id, owner)).fetchone()


def list_bikes(conn: sqlite3.Connection, owner: str) -> list[sqlite3.Row]:
    return conn.execute("SELECT * FROM bikes WHERE owner_sub = ? ORDER BY is_default DESC, id", (owner,)).fetchall()


def rides_km(conn: sqlite3.Connection, owner: str, bike: sqlite3.Row) -> float:
    """Kilometres ridden on this bike since its start date, from the rides that were assigned to it or (for the default bike) not assigned to any."""
    row = conn.execute(
        """
        SELECT COALESCE(SUM(distance_m), 0) AS m FROM rides
        WHERE owner_sub = ? AND substr(start_time, 1, 10) >= ? AND (bike_id = ? OR (bike_id IS NULL AND ? = 1))
        """,
        (owner, bike["start_date"], bike["id"], bike["is_default"]),
    ).fetchone()
    return (row["m"] or 0) / 1000.0


def odometer_km(conn: sqlite3.Connection, owner: str, bike: sqlite3.Row) -> float:
    return round(bike["start_odometer_km"] + rides_km(conn, owner, bike), 1)


def create_bike(conn: sqlite3.Connection, owner: str, *, name: str, make: str, model: str, year: Optional[int], start_odometer_km: float, start_date: date) -> int:
    first = conn.execute("SELECT COUNT(*) AS c FROM bikes WHERE owner_sub = ?", (owner,)).fetchone()["c"] == 0
    cur = conn.execute(
        "INSERT INTO bikes (owner_sub, name, make, model, year, start_odometer_km, start_date, is_default) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
        (owner, name, make, model, year, start_odometer_km, start_date.isoformat(), 1 if first else 0),
    )
    conn.commit()
    return cur.lastrowid


def update_bike(conn: sqlite3.Connection, owner: str, bike_id: int, *, name: str, make: str, model: str, year: Optional[int]) -> bool:
    cur = conn.execute("UPDATE bikes SET name = ?, make = ?, model = ?, year = ? WHERE id = ? AND owner_sub = ?", (name, make, model, year, bike_id, owner))
    conn.commit()
    return cur.rowcount > 0


def set_default(conn: sqlite3.Connection, owner: str, bike_id: int) -> bool:
    """Makes this the default bike. Rides that were not assigned to any bike were counting for the previous default, so they are pinned to it first:
    otherwise changing the default would move the whole history to the new bike."""
    new = get_bike(conn, owner, bike_id)
    if new is None:
        return False
    old = conn.execute("SELECT * FROM bikes WHERE owner_sub = ? AND is_default = 1 AND id != ?", (owner, bike_id)).fetchone()
    if old is not None:
        conn.execute("UPDATE rides SET bike_id = ? WHERE owner_sub = ? AND bike_id IS NULL AND substr(start_time, 1, 10) >= ?", (old["id"], owner, old["start_date"]))
    conn.execute("UPDATE bikes SET is_default = CASE WHEN id = ? THEN 1 ELSE 0 END WHERE owner_sub = ?", (bike_id, owner))
    conn.commit()
    return True


def set_odometer(conn: sqlite3.Connection, owner: str, bike_id: int, reading_km: float) -> bool:
    """The odometer reads `reading_km` now: the starting value is adjusted so that start + rides = reading."""
    bike = get_bike(conn, owner, bike_id)
    if bike is None:
        return False
    conn.execute("UPDATE bikes SET start_odometer_km = ? WHERE id = ? AND owner_sub = ?", (reading_km - rides_km(conn, owner, bike), bike_id, owner))
    conn.commit()
    return True


def delete_bike(conn: sqlite3.Connection, owner: str, bike_id: int) -> bool:
    bike = get_bike(conn, owner, bike_id)
    if bike is None:
        return False
    for table in ("service_log", "service_items", "fuel_log", "expenses"):
        conn.execute(f"DELETE FROM {table} WHERE bike_id = ? AND owner_sub = ?", (bike_id, owner))
    conn.execute("UPDATE rides SET bike_id = NULL WHERE bike_id = ? AND owner_sub = ?", (bike_id, owner))
    conn.execute("DELETE FROM bikes WHERE id = ? AND owner_sub = ?", (bike_id, owner))
    if bike["is_default"]:
        nxt = conn.execute("SELECT id FROM bikes WHERE owner_sub = ? ORDER BY id LIMIT 1", (owner,)).fetchone()
        if nxt is not None:
            conn.execute("UPDATE bikes SET is_default = 1 WHERE id = ?", (nxt["id"],))
    conn.commit()
    return True


def assign_ride(conn: sqlite3.Connection, owner: str, ride_id: int, bike_id: Optional[int]) -> bool:
    """Puts one ride on a bike (or back to 'the default bike' with None). False if the ride or the bike is not the owner's."""
    if conn.execute("SELECT 1 FROM rides WHERE id = ? AND owner_sub = ?", (ride_id, owner)).fetchone() is None:
        return False
    if bike_id is not None and get_bike(conn, owner, bike_id) is None:
        return False
    conn.execute("UPDATE rides SET bike_id = ? WHERE id = ? AND owner_sub = ?", (bike_id, ride_id, owner))
    conn.commit()
    return True


# ------------------------------------------------------------------------------------------------------------------------------- service --

def get_item(conn: sqlite3.Connection, owner: str, item_id: int) -> Optional[sqlite3.Row]:
    return conn.execute("SELECT * FROM service_items WHERE id = ? AND owner_sub = ?", (item_id, owner)).fetchone()


def add_item(conn: sqlite3.Connection, owner: str, bike_id: int, *, name: str, interval_km: Optional[float], interval_months: Optional[int]) -> Optional[int]:
    if get_bike(conn, owner, bike_id) is None:
        return None
    cur = conn.execute("INSERT INTO service_items (bike_id, owner_sub, name, interval_km, interval_months) VALUES (?, ?, ?, ?, ?)",
                       (bike_id, owner, name, interval_km, interval_months))
    conn.commit()
    return cur.lastrowid


def count_items(conn: sqlite3.Connection, owner: str, bike_id: int) -> int:
    return conn.execute("SELECT COUNT(*) AS c FROM service_items WHERE bike_id = ? AND owner_sub = ?", (bike_id, owner)).fetchone()["c"]


def delete_item(conn: sqlite3.Connection, owner: str, item_id: int) -> bool:
    if get_item(conn, owner, item_id) is None:
        return False
    conn.execute("DELETE FROM service_log WHERE item_id = ? AND owner_sub = ?", (item_id, owner))
    conn.execute("DELETE FROM service_items WHERE id = ? AND owner_sub = ?", (item_id, owner))
    conn.commit()
    return True


def log_service(conn: sqlite3.Connection, owner: str, item_id: int, *, done_date: date, odometer: Optional[float], cost: Optional[float], note: str) -> Optional[int]:
    item = get_item(conn, owner, item_id)
    if item is None:
        return None
    cur = conn.execute(
        "INSERT INTO service_log (item_id, bike_id, owner_sub, done_date, odometer_km, cost, note) VALUES (?, ?, ?, ?, ?, ?, ?)",
        (item_id, item["bike_id"], owner, done_date.isoformat(), odometer, cost, note),
    )
    conn.commit()
    return cur.lastrowid


def delete_service_log(conn: sqlite3.Connection, owner: str, log_id: int) -> bool:
    cur = conn.execute("DELETE FROM service_log WHERE id = ? AND owner_sub = ?", (log_id, owner))
    conn.commit()
    return cur.rowcount > 0


def last_log(conn: sqlite3.Connection, item_id: int) -> Optional[sqlite3.Row]:
    return conn.execute(
        "SELECT * FROM service_log WHERE item_id = ? ORDER BY done_date DESC, COALESCE(odometer_km, 0) DESC, id DESC LIMIT 1", (item_id,)
    ).fetchone()


def item_view(conn: sqlite3.Connection, item: sqlite3.Row, odometer: float, today: date) -> dict:
    last = last_log(conn, item["id"])
    last_date = date.fromisoformat(last["done_date"]) if last else None
    status = garage.service_status(
        interval_km=item["interval_km"], interval_months=item["interval_months"],
        last_km=last["odometer_km"] if last else None, last_date=last_date, odometer_km=odometer, today=today)
    return {
        "id": item["id"], "name": item["name"], "interval_km": item["interval_km"], "interval_months": item["interval_months"],
        "last_done_date": last["done_date"] if last else None, "last_done_km": last["odometer_km"] if last else None, "status": status,
    }


# ------------------------------------------------------------------------------------------------------------------------- fuel, expenses --

def add_fuel(conn: sqlite3.Connection, owner: str, bike_id: int, *, day: date, odometer: float, litres: float, price: Optional[float], full_tank: bool) -> Optional[int]:
    if get_bike(conn, owner, bike_id) is None:
        return None
    cur = conn.execute("INSERT INTO fuel_log (bike_id, owner_sub, date, odometer_km, litres, price, full_tank) VALUES (?, ?, ?, ?, ?, ?, ?)",
                       (bike_id, owner, day.isoformat(), odometer, litres, price, 1 if full_tank else 0))
    conn.commit()
    return cur.lastrowid


def delete_fuel(conn: sqlite3.Connection, owner: str, fuel_id: int) -> bool:
    cur = conn.execute("DELETE FROM fuel_log WHERE id = ? AND owner_sub = ?", (fuel_id, owner))
    conn.commit()
    return cur.rowcount > 0


def add_expense(conn: sqlite3.Connection, owner: str, bike_id: int, *, day: date, category: str, amount: float, note: str) -> Optional[int]:
    if get_bike(conn, owner, bike_id) is None:
        return None
    cur = conn.execute("INSERT INTO expenses (bike_id, owner_sub, date, category, amount, note) VALUES (?, ?, ?, ?, ?, ?)", (bike_id, owner, day.isoformat(), category, amount, note))
    conn.commit()
    return cur.lastrowid


def delete_expense(conn: sqlite3.Connection, owner: str, expense_id: int) -> bool:
    cur = conn.execute("DELETE FROM expenses WHERE id = ? AND owner_sub = ?", (expense_id, owner))
    conn.commit()
    return cur.rowcount > 0


# ----------------------------------------------------------------------------------------------------------------------------- the views --

def bike_summary(conn: sqlite3.Connection, owner: str, bike: sqlite3.Row, today: date) -> dict:
    odo = odometer_km(conn, owner, bike)
    items = [item_view(conn, i, odo, today) for i in conn.execute("SELECT * FROM service_items WHERE bike_id = ? AND owner_sub = ? ORDER BY id", (bike["id"], owner))]
    order = {"overdue": 0, "soon": 1, "ok": 2, "never_done": 3}
    urgent = sorted((i for i in items if i["status"]["state"] in ("overdue", "soon")), key=lambda i: order[i["status"]["state"]])
    return {
        "id": bike["id"], "name": bike["name"], "make": bike["make"], "model": bike["model"], "year": bike["year"], "is_default": bool(bike["is_default"]),
        "odometer_km": odo, "overdue": sum(1 for i in items if i["status"]["state"] == "overdue"), "soon": sum(1 for i in items if i["status"]["state"] == "soon"),
        "next_due": ({"name": urgent[0]["name"], **urgent[0]["status"]} if urgent else None),
    }


def bike_detail(conn: sqlite3.Connection, owner: str, bike: sqlite3.Row, today: date) -> dict:
    odo = odometer_km(conn, owner, bike)
    ridden = rides_km(conn, owner, bike)
    items = [item_view(conn, i, odo, today) for i in conn.execute("SELECT * FROM service_items WHERE bike_id = ? AND owner_sub = ? ORDER BY id", (bike["id"], owner))]
    log = [dict(r) for r in conn.execute(
        """
        SELECT l.id, l.item_id, i.name AS item_name, l.done_date, l.odometer_km, l.cost, l.note FROM service_log l
        JOIN service_items i ON i.id = l.item_id WHERE l.bike_id = ? AND l.owner_sub = ?
        ORDER BY l.done_date DESC, l.id DESC LIMIT ?""", (bike["id"], owner, LIST_LIMIT))]
    fills = [{"id": r["id"], "date": r["date"], "odometer_km": r["odometer_km"], "litres": r["litres"], "price": r["price"], "full_tank": bool(r["full_tank"])}
             for r in conn.execute("SELECT * FROM fuel_log WHERE bike_id = ? AND owner_sub = ?", (bike["id"], owner))]
    fuel = garage.fuel_stats(fills)
    fuel["fills"] = sorted(fuel["fills"], key=lambda f: (f["date"], f["odometer_km"], f["id"]), reverse=True)[:LIST_LIMIT]
    expenses = [dict(r) for r in conn.execute(
        "SELECT id, date, category, amount, note FROM expenses WHERE bike_id = ? AND owner_sub = ? ORDER BY date DESC, id DESC LIMIT ?", (bike["id"], owner, LIST_LIMIT))]
    service_cost = conn.execute("SELECT COALESCE(SUM(cost), 0) AS c FROM service_log WHERE bike_id = ? AND owner_sub = ?", (bike["id"], owner)).fetchone()["c"]
    other_cost = conn.execute("SELECT COALESCE(SUM(amount), 0) AS c FROM expenses WHERE bike_id = ? AND owner_sub = ?", (bike["id"], owner)).fetchone()["c"]
    total = round(fuel["total_spent"] + service_cost + other_cost, 2)
    return {
        "bike": {"id": bike["id"], "name": bike["name"], "make": bike["make"], "model": bike["model"], "year": bike["year"], "is_default": bool(bike["is_default"]),
                 "start_odometer_km": bike["start_odometer_km"], "start_date": bike["start_date"], "odometer_km": odo, "ridden_km": round(ridden, 1)},
        "items": items,
        "service_log": log,
        "fuel": fuel,
        "expenses": expenses,
        "totals": {"fuel": fuel["total_spent"], "service": round(service_cost, 2), "other": round(other_cost, 2), "all": total,
                   "per_km": garage.cost_per_km(total, ridden)},
    }
