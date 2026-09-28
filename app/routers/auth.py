from fastapi import APIRouter, Request
from fastapi.responses import HTMLResponse, RedirectResponse
from fastapi.templating import Jinja2Templates

from ..auth import oauth, safe_next
from ..config import settings
from ..paths import TEMPLATES_DIR

# Intentionally has no require_login dependency -- these are the only
# routes reachable while logged out.
router = APIRouter()
templates = Jinja2Templates(directory=str(TEMPLATES_DIR))


@router.get("/login", response_class=HTMLResponse)
def login_form(request: Request, next: str = "/"):
    if request.session.get("user"):
        return RedirectResponse(url=safe_next(next), status_code=303)
    return templates.TemplateResponse(request, "login.html", {"next": next})


@router.get("/login/authentik")
async def login_authentik(request: Request, next: str = "/"):
    request.session["post_login_next"] = safe_next(next)
    return await oauth.authentik.authorize_redirect(request, settings.oidc_redirect_uri)


@router.get("/auth/callback")
async def auth_callback(request: Request):
    token = await oauth.authentik.authorize_access_token(request)
    userinfo = token.get("userinfo") or await oauth.authentik.userinfo(token=token)
    request.session["user"] = {
        "sub": userinfo["sub"],
        "email": userinfo.get("email", ""),
        "name": userinfo.get("name") or userinfo.get("preferred_username", ""),
    }
    next_url = request.session.pop("post_login_next", "/")
    return RedirectResponse(url=safe_next(next_url), status_code=303)


@router.get("/logout")
def logout(request: Request):
    request.session.clear()
    return RedirectResponse(url="/login", status_code=303)
