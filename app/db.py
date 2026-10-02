import sqlite3
from pathlib import Path

from .config import settings
from .paths import SCHEMA_PATH


def get_db() -> sqlite3.Connection:
    Path(settings.db_path).parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(settings.db_path)
    conn.row_factory = sqlite3.Row
    return conn


def _column_exists(conn: sqlite3.Connection, table: str, column: str) -> bool:
    return any(row["name"] == column for row in conn.execute(f"PRAGMA table_info({table})"))


def _migrate_owner_columns(conn: sqlite3.Connection) -> None:
    """Add owner_sub to tables that predate multi-user support.

    schema.sql's CREATE TABLE IF NOT EXISTS won't retroactively add a column
    to a table that already exists, so this covers upgrading an existing
    database in place. New rows default to owner_sub='' (unclaimed) until a
    logged-in user claims them via the settings-page banner.
    """
    for table in ("points", "rides"):
        if not _column_exists(conn, table, "owner_sub"):
            conn.execute(f"ALTER TABLE {table} ADD COLUMN owner_sub TEXT NOT NULL DEFAULT ''")
    # which bike a ride was on (NULL = the owner's default bike, see schema.sql "Garage")
    if not _column_exists(conn, "rides", "bike_id"):
        conn.execute("ALTER TABLE rides ADD COLUMN bike_id INTEGER")


_MIGRATION_MARKER = "-- ##POST_MIGRATION##"


def init_db() -> None:
    conn = get_db()
    try:
        schema = SCHEMA_PATH.read_text()
        tables_sql, _, rest_sql = schema.partition(_MIGRATION_MARKER)
        conn.executescript(tables_sql)
        conn.commit()
        _migrate_owner_columns(conn)
        conn.commit()
        conn.executescript(rest_sql)
        conn.commit()
    finally:
        conn.close()
