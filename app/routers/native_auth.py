"""Sign-in for the native iOS app (ios/): a PKCE-style handshake so Authentik runs in the system's own login sheet
(ASWebAuthenticationSession: passkeys and the shared Authentik session work) instead of inside an embedded web view.

    app                                   server                                    Authentik
     | GET /app/login?challenge=C  ------> |  remembers C in the session  ---------->  (normal login)
     | <----------------------- redirect to /app/done after login ---------------------|
     | ridelogger://auth?code=X  <-------- |  X = signed {user, C, nonce}, valid 120 s
     | POST /app/exchange (X, verifier V) -> |  checks age, signature, sha256(V) == C, nonce unused
     | <------- 204 + the normal site session cookie                                   |

C = base64url(sha256(V)); V never leaves the app until the exchange, so a code intercepted through the custom URL scheme is
useless on its own. The session cookie is the same one the website uses, so every /api/v1 call is simply logged in.
"""
import base64
import hashlib
import hmac
import re
import secrets
import time

from fastapi import APIRouter, Form, Request
from fastapi.responses import RedirectResponse, Response
from itsdangerous import BadSignature, SignatureExpired, URLSafeTimedSerializer

from ..config import settings

router = APIRouter()

APP_SCHEME = "ridelogger"           # fixed: the redirect target is never taken from a request
CODE_MAX_AGE_S = 120
_CHALLENGE = re.compile(r"^[A-Za-z0-9_-]{43}$")                 # base64url(sha256), no padding
_VERIFIER = re.compile(r"^[A-Za-z0-9_-]{43,128}$")              # RFC 7636 length range
_used: dict[str, float] = {}                                    # nonce -> expiry (single use; a restart forgets, the 120 s age limit still holds)


def _serializer() -> URLSafeTimedSerializer:
    return URLSafeTimedSerializer(settings.session_secret, salt="native-login")


def challenge_of(verifier: str) -> str:
    return base64.urlsafe_b64encode(hashlib.sha256(verifier.encode("ascii")).digest()).rstrip(b"=").decode("ascii")


def _remember(nonce: str, now: float) -> bool:
    """True the first time a nonce is seen; also forgets nonces that can no longer be replayed anyway."""
    for k in [k for k, exp in _used.items() if exp < now]:
        del _used[k]
    if nonce in _used:
        return False
    _used[nonce] = now + CODE_MAX_AGE_S + 5
    return True


@router.get("/app/login")
def app_login(request: Request, challenge: str = ""):
    if not _CHALLENGE.fullmatch(challenge):
        return Response("Bad request", status_code=400)
    request.session["app_challenge"] = challenge
    return RedirectResponse(url="/login/authentik?next=/app/done", status_code=303)


@router.get("/app/done")
def app_done(request: Request):
    user, challenge = request.session.get("user"), request.session.get("app_challenge")
    if not user or not challenge:
        return Response("Bad request", status_code=400)
    code = _serializer().dumps({"u": {"sub": user["sub"], "email": user.get("email", ""), "name": user.get("name", "")},
                                "c": challenge, "n": secrets.token_urlsafe(16)})
    request.session.clear()          # the sign-in sheet's browser session was only a carrier for this step
    return RedirectResponse(url=f"{APP_SCHEME}://auth?code={code}", status_code=303)


@router.post("/app/exchange")
def app_exchange(request: Request, code: str = Form(""), verifier: str = Form("")):
    fail = Response("Bad request", status_code=400)
    if not _VERIFIER.fullmatch(verifier):
        return fail
    try:
        data = _serializer().loads(code, max_age=CODE_MAX_AGE_S)
    except (BadSignature, SignatureExpired):
        return fail
    if not isinstance(data, dict) or not hmac.compare_digest(str(data.get("c", "")), challenge_of(verifier)):
        return fail
    if not _remember(str(data.get("n", "")), time.time()):
        return fail
    request.session["user"] = data["u"]
    return Response(status_code=204)
