"""The app's sign-in handshake (app/routers/native_auth.py) and the login redirect hardening it depends on."""
import re
from urllib.parse import parse_qs, urlparse

import pytest
from fastapi.testclient import TestClient

import app.routers.native_auth as native_auth
from app.auth import safe_next
from app.main import app
from conftest import ALICE, SESSION_COOKIE, session_cookie

# RFC 7636 appendix B: the same vector the Swift side tests (ios/Tests/LogicTests.swift)
RFC_VERIFIER = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
RFC_CHALLENGE = "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
VERIFIER = "v" * 43


def carrier(challenge: str) -> TestClient:
    """The sign-in sheet's browser session at the moment Authentik has just sent the person back: logged in + the app's challenge."""
    client = TestClient(app, follow_redirects=False)
    client.cookies.set(SESSION_COOKIE, session_cookie(ALICE, app_challenge=challenge))
    return client


def get_code(challenge: str) -> str:
    r = carrier(challenge).get("/app/done")
    assert r.status_code == 303
    location = r.headers["location"]
    assert location.startswith("ridelogger://auth?code=")
    return parse_qs(urlparse(location).query)["code"][0]


def exchange(code: str, verifier: str = RFC_VERIFIER):
    return TestClient(app, follow_redirects=False).post("/app/exchange", data={"code": code, "verifier": verifier})


def test_challenge_matches_the_rfc_7636_vector():
    assert native_auth.challenge_of(RFC_VERIFIER) == RFC_CHALLENGE


def test_login_remembers_the_challenge_and_sends_the_person_to_authentik(anon):
    r = anon.get(f"/app/login?challenge={RFC_CHALLENGE}")
    assert r.status_code == 303 and r.headers["location"] == "/login/authentik?next=/app/done"
    assert SESSION_COOKIE in r.headers["set-cookie"]


@pytest.mark.parametrize("challenge", ["", "short", "a" * 42, "a" * 44, "a" * 42 + "=", "a" * 42 + "!"])
def test_login_rejects_a_malformed_challenge(anon, challenge):
    assert anon.get("/app/login", params={"challenge": challenge}).status_code == 400


def test_done_without_a_session_is_rejected(anon):
    assert anon.get("/app/done").status_code == 400


def test_full_handshake_ends_with_a_working_session():
    code = get_code(RFC_CHALLENGE)
    client = TestClient(app, follow_redirects=False)
    r = client.post("/app/exchange", data={"code": code, "verifier": RFC_VERIFIER})
    assert r.status_code == 204
    assert re.search(rf"{SESSION_COOKIE}=", r.headers["set-cookie"])
    me = client.get("/api/v1/me")                       # the cookie the exchange set is all the app needs
    assert me.status_code == 200 and me.json()["email"] == "alice@example.com"


def test_done_ends_the_carrier_session():
    r = carrier(RFC_CHALLENGE).get("/app/done")
    # the browser session is told to forget everything: only the one-time code carries the login forward
    assert f"{SESSION_COOKIE}=null" in r.headers["set-cookie"] and "1970" in r.headers["set-cookie"]


def test_a_code_works_only_once():
    code = get_code(RFC_CHALLENGE)
    assert exchange(code).status_code == 204
    assert exchange(code).status_code == 400


def test_the_wrong_verifier_is_rejected():
    code = get_code(RFC_CHALLENGE)
    assert exchange(code, verifier="x" * 43).status_code == 400
    assert exchange(code).status_code == 204                    # ...and a wrong guess did not burn the code


def test_a_stolen_code_is_useless_without_the_verifier():
    """An app that intercepts ridelogger://auth?code=... only has the code: the verifier never left the real app."""
    code = get_code(native_auth.challenge_of(VERIFIER))
    assert exchange(code, verifier="y" * 43).status_code == 400


def test_an_expired_code_is_rejected(monkeypatch):
    code = get_code(RFC_CHALLENGE)
    monkeypatch.setattr(native_auth, "CODE_MAX_AGE_S", -1)
    assert exchange(code).status_code == 400


def test_a_tampered_or_junk_code_is_rejected():
    code = get_code(RFC_CHALLENGE)
    assert exchange(code[:-2] + "xx").status_code == 400
    assert exchange("junk").status_code == 400
    assert exchange("").status_code == 400


@pytest.mark.parametrize("verifier", ["", "a" * 42, "a" * 129, "a" * 43 + "!"])
def test_a_malformed_verifier_is_rejected(verifier):
    assert exchange(get_code(RFC_CHALLENGE), verifier=verifier).status_code == 400


def test_the_redirect_target_scheme_is_fixed(anon):
    """?next= and friends can never change where the code is sent: it is always ridelogger://auth."""
    r = carrier(RFC_CHALLENGE).get("/app/done?next=https://evil.example&scheme=evil")
    assert r.headers["location"].startswith("ridelogger://auth?code=")


# ------------------------------------------------------- open-redirect fix --

@pytest.mark.parametrize("value,expected", [
    ("/rides", "/rides"), ("/app/done", "/app/done"), ("/", "/"),
    ("//evil.example", "/"), ("https://evil.example", "/"), ("/\\evil.example", "/"), ("", "/"), (None, "/"),
])
def test_safe_next(value, expected):
    assert safe_next(value) == expected


def test_login_page_does_not_redirect_a_logged_in_user_off_site():
    client = TestClient(app, follow_redirects=False)
    client.cookies.set(SESSION_COOKIE, session_cookie(ALICE))
    assert client.get("/login", params={"next": "//evil.example"}).headers["location"] == "/"
    assert client.get("/login", params={"next": "/rides"}).headers["location"] == "/rides"
