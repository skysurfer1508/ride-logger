from authlib.integrations.starlette_client import OAuth
from fastapi import Header, HTTPException, Request, status

from .config import settings
from .db import get_db

oauth = OAuth()
oauth.register(
    name="authentik",
    client_id=settings.oidc_client_id,
    client_secret=settings.oidc_client_secret,
    server_metadata_url=settings.oidc_server_metadata_url,
    client_kwargs={"scope": "openid email profile"},
)


class NotAuthenticated(Exception):
    """Raised by require_login; caught by a handler that redirects to /login."""


class OnboardingRequired(Exception):
    """Raised by require_onboarded; caught by a handler that redirects to /welcome."""


def require_login(request: Request) -> None:
    if not request.session.get("user"):
        raise NotAuthenticated()


def current_owner_sub(request: Request) -> str:
    return request.session["user"]["sub"]


def require_onboarded(request: Request) -> None:
    """Send a first-time user to /welcome no matter which page they land on.

    A brand-new login can end up anywhere -- e.g. require_login's own
    redirect preserves `next`, so hitting /settings while logged out sends
    you right back to /settings after auth, never touching Home. Checking
    only from the Home route missed that path entirely, so this runs for
    every dashboard page instead (except /welcome itself, which would
    otherwise redirect to itself).
    """
    if request.url.path == "/welcome":
        return
    owner_sub = current_owner_sub(request)
    conn = get_db()
    try:
        has_token = conn.execute(
            "SELECT 1 FROM ingest_tokens WHERE owner_sub = ?", (owner_sub,)
        ).fetchone()
    finally:
        conn.close()
    if not has_token:
        raise OnboardingRequired()


def resolve_ingest_owner(authorization: str = Header(default="")) -> str:
    """Look up which account an ingested batch belongs to by its bearer token.

    Each user has their own token (see the settings page); there is no shared
    ingest secret anymore, so a valid token both authenticates the request
    and determines data ownership in one step.
    """
    if not authorization.startswith("Bearer "):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid or missing access token",
        )
    token = authorization.removeprefix("Bearer ")
    conn = get_db()
    try:
        row = conn.execute(
            "SELECT owner_sub FROM ingest_tokens WHERE token = ?", (token,)
        ).fetchone()
    finally:
        conn.close()
    if not row:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid or missing access token",
        )
    return row["owner_sub"]
