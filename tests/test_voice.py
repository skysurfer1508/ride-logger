"""The natural voice (app/voice.py, app/routers/api_voice.py). Piper and ffmpeg are faked: what is tested is the cache, the limits and what the API says when the voice
is not set up. The real voice is tried by hand (deploy/voice/setup.sh)."""
import json
from pathlib import Path

import pytest

from app import voice
from app.config import settings
from conftest import ALICE

CLIENT = {"X-RideLog-Client": "1"}


@pytest.fixture
def speaker(tmp_path, monkeypatch):
    """A voice that 'renders' by writing the phrase itself, and counts how often it was asked."""
    monkeypatch.setattr(settings, "voice_dir", str(tmp_path / "clips"))
    monkeypatch.setattr(settings, "voice_enabled", True)
    calls = []
    monkeypatch.setattr(voice, "available", lambda lang="en": True)
    monkeypatch.setattr(voice, "_wav", lambda lang, text: calls.append((lang, text)) or f"{lang}:{text}".encode())
    monkeypatch.setattr(voice, "_mp3", lambda wav: b"MP3" + wav)
    return calls


def test_a_phrase_is_rendered_once_and_found_again_by_its_hash(speaker):
    first = voice.render("en", "In 300 meters")
    again = voice.render("en", "In 300 meters")
    assert first == again and len(first) == 16 and speaker == [("en", "In 300 meters")]
    assert voice.read(first).read_bytes() == b"MP3en:In 300 meters"


def test_the_same_words_in_the_other_language_are_another_clip(speaker):
    assert voice.render("en", "Hardstrasse") != voice.render("de", "Hardstrasse")


def test_a_clip_id_must_look_like_one(speaker):
    assert voice.read("../../etc/passwd") is None and voice.read("0" * 16) is None and voice.read("ZZ") is None


def test_a_phrase_that_is_not_one_is_refused(speaker):
    for lang, text in [("fr", "Bonjour"), ("en", "   "), ("en", "x" * 201)]:
        with pytest.raises(ValueError):
            voice.render(lang, text)


def test_without_the_voice_nothing_is_rendered(tmp_path, monkeypatch):
    monkeypatch.setattr(settings, "voice_dir", str(tmp_path / "none"))
    monkeypatch.setattr(settings, "voice_models_dir", str(tmp_path / "no-models"))
    assert voice.available("en") is False
    with pytest.raises(voice.VoiceUnavailable):
        voice.render("en", "Left in 300")


def test_a_clip_that_was_rendered_before_is_served_even_if_the_voice_is_gone(speaker, monkeypatch):
    clip = voice.render("en", "Hairpin left")
    monkeypatch.setattr(voice, "available", lambda lang="en": False)
    assert voice.render("en", "Hairpin left") == clip


def test_the_api_renders_the_phrases_and_serves_the_clips(alice, speaker):
    items = [{"text": "In 300 meters", "lang": "en"}, {"text": "Hardstrasse", "lang": "de"}, {"text": "In 300 meters", "lang": "en"}]
    body = alice.post("/api/v1/voice/clips", data={"items": json.dumps(items)}, headers=CLIENT).json()
    assert body["status"] == "ok" and [c["text"] for c in body["clips"]] == ["In 300 meters", "Hardstrasse", "In 300 meters"]
    assert body["clips"][0]["id"] == body["clips"][2]["id"] and body["clips"][0]["id"] != body["clips"][1]["id"] and len(speaker) == 2
    got = alice.get(body["clips"][1]["url"])
    assert got.status_code == 200 and got.headers["content-type"] == "audio/mpeg" and "immutable" in got.headers["cache-control"] and got.content == b"MP3de:Hardstrasse"


def test_the_api_says_when_the_voice_is_not_set_up(alice, tmp_path, monkeypatch):
    monkeypatch.setattr(settings, "voice_models_dir", str(tmp_path / "no-models"))
    body = alice.post("/api/v1/voice/clips", data={"items": json.dumps([{"text": "Left", "lang": "en"}])}, headers=CLIENT).json()
    assert body["status"] == "unavailable" and body["clips"] == []
    assert alice.get("/api/v1/voice/status").json()["available"] is False


def test_a_phrase_the_voice_cannot_say_does_not_cost_the_others(alice, speaker, monkeypatch):
    real = voice._wav

    def picky(lang, text):
        if text == "bad":
            raise RuntimeError("cannot")
        return real(lang, text)

    monkeypatch.setattr(voice, "_wav", picky)
    body = alice.post("/api/v1/voice/clips", data={"items": json.dumps([{"text": "bad"}, {"text": "good"}])}, headers=CLIENT).json()
    assert [c["text"] for c in body["clips"]] == ["good"]


@pytest.mark.parametrize("items", ["nope", "[]", json.dumps([{"text": ""}]), json.dumps([{"text": "x", "lang": "fr"}]), json.dumps(["x"]), json.dumps([{"text": "x"}] * 201), json.dumps([{"text": "y" * 201}])])
def test_bad_requests_are_refused(alice, speaker, items):
    assert alice.post("/api/v1/voice/clips", data={"items": items}, headers=CLIENT).status_code == 400


def test_a_missing_clip_is_a_404_and_the_voice_needs_a_login_and_the_client_header(alice, anon, speaker):
    assert alice.get("/api/v1/voice/clips/" + "0" * 16 + ".mp3").status_code == 404
    assert anon.get("/api/v1/voice/status").status_code == 401
    assert alice.post("/api/v1/voice/clips", data={"items": json.dumps([{"text": "x"}])}).status_code in (400, 401, 403)
