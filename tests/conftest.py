"""Test setup. The environment is set before `app` is imported so the tests never read the real .env or touch the real database
(pydantic-settings lets real environment variables win over the .env file)."""
import base64
import json
import os
import sys
import tempfile
from pathlib import Path

_TMP = Path(tempfile.mkdtemp(prefix="ride-logger-tests-"))
os.environ["SESSION_SECRET"] = "test-session-secret-not-for-production"
os.environ["DB_PATH"] = str(_TMP / "test.db")
os.environ["OIDC_CLIENT_ID"] = "test-client"
os.environ["OIDC_CLIENT_SECRET"] = "test-secret"
os.environ["OIDC_SERVER_METADATA_URL"] = "https://auth.example.invalid/.well-known/openid-configuration"
os.environ["OIDC_REDIRECT_URI"] = "https://ride.example.invalid/auth/callback"

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import pytest  # noqa: E402
from fastapi.testclient import TestClient  # noqa: E402
from itsdangerous import TimestampSigner  # noqa: E402

from app.config import settings  # noqa: E402
from app.db import get_db, init_db  # noqa: E402
from app.main import app  # noqa: E402

SESSION_COOKIE = "ride_logger_session"
ALICE = {"sub": "sub-alice", "email": "alice@example.com", "name": "Alice"}
BOB = {"sub": "sub-bob", "email": "bob@example.com", "name": "Bob"}


def session_cookie(user: dict, **extra) -> str:
    """The exact value Starlette's SessionMiddleware would set for a logged-in `user` (plus any other session keys)."""
    raw = base64.b64encode(json.dumps({"user": user, **extra}).encode("utf-8"))
    return TimestampSigner(settings.session_secret).sign(raw).decode("utf-8")


@pytest.fixture(autouse=True)
def fresh_db():
    path = Path(settings.db_path)
    for suffix in ("", "-journal", "-wal", "-shm"):
        Path(str(path) + suffix).unlink(missing_ok=True)
    init_db()
    yield


@pytest.fixture
def anon() -> TestClient:
    return TestClient(app, follow_redirects=False)


def logged_in(user: dict) -> TestClient:
    client = TestClient(app, follow_redirects=False)
    client.cookies.set(SESSION_COOKIE, session_cookie(user))
    return client


@pytest.fixture
def alice() -> TestClient:
    return logged_in(ALICE)


@pytest.fixture
def bob() -> TestClient:
    return logged_in(BOB)


def add_ride(owner_sub: str, start: str, distance_m: float = 25_000, duration_s: float = 1800,
             max_mps: float = 33.0, climb_m: float = 120.0, points: int = 300,
             polyline: list | None = None, trip_id: str | None = None) -> int:
    """Insert a finished ride straight into the table and return its id."""
    conn = get_db()
    try:
        cur = conn.execute(
            """
            INSERT INTO rides (owner_sub, device_id, trip_id, start_time, end_time, distance_m, duration_s,
                               avg_speed_mps, max_speed_mps, elevation_gain_m, point_count, polyline_simplified, source)
            VALUES (?, 'dev', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'trip_marker')
            """,
            (owner_sub, trip_id, start, start, distance_m, duration_s, distance_m / duration_s, max_mps, climb_m,
             points, json.dumps(polyline or [[47.0, 8.0], [47.01, 8.01], [47.02, 8.03]])),
        )
        conn.commit()
        return cur.lastrowid
    finally:
        conn.close()


def add_token(owner_sub: str, email: str, token: str) -> None:
    conn = get_db()
    try:
        conn.execute("INSERT INTO ingest_tokens (token, owner_sub, owner_email) VALUES (?, ?, ?)", (token, owner_sub, email))
        conn.commit()
    finally:
        conn.close()
