from contextlib import asynccontextmanager

from fastapi import FastAPI, Request
from fastapi.responses import RedirectResponse
from fastapi.staticfiles import StaticFiles
from starlette.middleware.sessions import SessionMiddleware

from .auth import NotAuthenticated, OnboardingRequired
from .config import settings
from .db import init_db
from .paths import STATIC_DIR
from .routers import api_garage, api_roads, api_v1, auth, dashboard, ingest, native_auth


@asynccontextmanager
async def lifespan(app: FastAPI):
    init_db()
    yield


app = FastAPI(title="Ride Logger", lifespan=lifespan)

app.add_middleware(
    SessionMiddleware,
    secret_key=settings.session_secret,
    session_cookie="ride_logger_session",
    max_age=60 * 60 * 24 * 30,
    same_site="lax",
    # Not https_only: the dashboard is also reached over plain HTTP on the
    # LAN directly (not just through the HTTPS Cloudflare Tunnel), and the
    # tunnel itself terminates TLS at Cloudflare's edge and forwards plain
    # HTTP to this origin -- so this app never actually sees an https:// scheme.
    https_only=False,
)


@app.exception_handler(NotAuthenticated)
async def not_authenticated_handler(request: Request, exc: NotAuthenticated):
    return RedirectResponse(url=f"/login?next={request.url.path}", status_code=303)


@app.exception_handler(OnboardingRequired)
async def onboarding_required_handler(request: Request, exc: OnboardingRequired):
    return RedirectResponse(url="/welcome", status_code=303)


app.mount("/static", StaticFiles(directory=str(STATIC_DIR)), name="static")
app.include_router(ingest.router)
app.include_router(auth.router)
app.include_router(native_auth.router)
app.include_router(api_v1.router)
app.include_router(api_garage.router)
app.include_router(api_roads.router)
app.include_router(dashboard.router)
