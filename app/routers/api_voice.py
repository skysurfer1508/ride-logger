"""The natural navigation voice's API (/api/v1/voice/*): the phone sends the phrases of a route, the server renders the ones it has not got (app/voice.py) and answers with
where to fetch each clip. A clip never changes (its id is a hash of what is said and by which voice), so it is cached for ever on the phone and by anything on the way.
Same rules as the rest of /api/v1: a plain 401 when logged out, changes need the X-RideLog-Client header.
"""
import json
import threading

from fastapi import APIRouter, Depends, Form, HTTPException
from fastapi.responses import FileResponse, JSONResponse

from .. import voice
from ..auth import require_api_client, require_api_login

router = APIRouter(prefix="/api/v1/voice", dependencies=[Depends(require_api_login)])
CLIENT = [Depends(require_api_client)]
MAX_ITEMS = 200
_busy = threading.BoundedSemaphore(2)


def reply(payload: dict) -> JSONResponse:
    return JSONResponse({"api": 1, **payload}, headers={"Cache-Control": "no-store"})


def _bad(message: str) -> HTTPException:
    return HTTPException(status_code=400, detail={"detail": "invalid_input", "message": message})


@router.get("/status")
def voice_status():
    """Whether the server can speak, and with which voices."""
    return reply({"status": "ok", "message": None, **voice.status()})


@router.post("/clips", dependencies=CLIENT)
def clips(items: str = Form()):
    """`items`: a JSON list of {"text": "...", "lang": "en" | "de"}, up to 200. Answers {"clips": [{"text", "lang", "id", "url"}, ...]} for what could be rendered, in
    the order asked, and `status` unavailable (with no clips) when the voice is not set up on this server."""
    try:
        wanted = json.loads(items)
    except ValueError:
        raise _bad("The phrases are not readable.")
    if not isinstance(wanted, list) or not 1 <= len(wanted) <= MAX_ITEMS:
        raise _bad(f"Send between 1 and {MAX_ITEMS} phrases.")
    phrases = []
    for item in wanted:
        text = item.get("text") if isinstance(item, dict) else None
        lang = item.get("lang", "en") if isinstance(item, dict) else None
        if not isinstance(text, str) or not text.strip() or len(text) > voice.MAX_TEXT or lang not in voice.LANGUAGES:
            raise _bad(f"Each phrase is up to {voice.MAX_TEXT} characters and in English or German.")
        phrases.append((text.strip(), lang))
    if not voice.available("en"):
        return reply({"status": "unavailable", "clips": [], "message": "The natural voice is not set up on your server."})
    if not _busy.acquire(blocking=False):
        return reply({"status": "unavailable", "clips": [], "message": "The server is busy making voice clips. Try again in a moment."})
    out = []
    try:
        for text, lang in phrases:
            try:
                clip = voice.render(lang, text)
            except voice.VoiceUnavailable:
                continue                                                 # one phrase the voice cannot say must not cost the others
            out.append({"text": text, "lang": lang, "id": clip, "url": f"/api/v1/voice/clips/{clip}.mp3"})
    finally:
        _busy.release()
    return reply({"status": "ok" if out else "unavailable", "message": None if out else "The voice could not render those phrases.", "clips": out})


@router.get("/clips/{clip}.mp3")
def clip_file(clip: str):
    path = voice.read(clip)
    if path is None:
        raise HTTPException(status_code=404, detail="clip_not_found")
    return FileResponse(path, media_type="audio/mpeg", headers={"Cache-Control": "private, max-age=31536000, immutable"})
