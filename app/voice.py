"""The natural navigation voice: short phrases rendered to mp3 by Piper (https://github.com/rhasspy/piper, a local neural text-to-speech: nothing is sent anywhere)
and kept on disk by the hash of what was said, so a phrase is rendered once for ever, for every route that uses it. The phone asks for the phrases of a route ahead of
the ride and keeps the clips, so guidance works with no signal.

Piper and its voice models are optional: without them `available()` is False and the phone speaks with its own voice. Two voices are used because a Swiss street name
read by an English voice is a mess: English for the instruction, German for the name.
"""
import hashlib
import io
import re
import subprocess
import threading
import wave
from pathlib import Path
from typing import Optional

from .config import settings

LANGUAGES = ("en", "de")
MAX_TEXT = 200
FFMPEG = "ffmpeg"
# a clip is trimmed of the silence Piper puts before and after it and levelled, so that phrases played one after the other join like one sentence
FILTER = "silenceremove=start_periods=1:start_threshold=-50dB:start_silence=0.02,areverse,silenceremove=start_periods=1:start_threshold=-50dB:start_silence=0.02,areverse,loudnorm=I=-16:TP=-1.5:LRA=7"
ID_PATTERN = re.compile(r"^[0-9a-f]{16}$")


class VoiceUnavailable(Exception):
    """No voice can be rendered here. The message is safe to show."""


_lock = threading.Lock()                       # one phrase at a time: the voice model is not shared between threads
_loaded: dict = {}


def model_name(lang: str) -> str:
    return settings.voice_en_model if lang == "en" else settings.voice_de_model


def _model_path(lang: str) -> Path:
    return Path(settings.voice_models_dir) / f"{model_name(lang)}.onnx"


def available(lang: str = "en") -> bool:
    if not settings.voice_enabled or not _model_path(lang).exists():
        return False
    try:
        import piper  # noqa: F401
    except ImportError:
        return False
    return True


def clip_id(lang: str, text: str) -> str:
    return hashlib.sha1(f"{lang}|{model_name(lang)}|{text}".encode("utf-8")).hexdigest()[:16]


def clip_path(clip: str) -> Path:
    return Path(settings.voice_dir) / clip[:2] / f"{clip}.mp3"


def _voice(lang: str):
    if lang not in _loaded:
        from piper import PiperVoice
        _loaded[lang] = PiperVoice.load(str(_model_path(lang)))
    return _loaded[lang]


def _wav(lang: str, text: str) -> bytes:
    """What Piper says, as a wav file's bytes."""
    voice = _voice(lang)
    out = io.BytesIO()
    with wave.open(out, "wb") as f:
        if hasattr(voice, "synthesize_wav"):                      # piper-tts 1.3 and later
            voice.synthesize_wav(text, f)
        else:                                                     # earlier versions write straight into the wav file
            voice.synthesize(text, f)
    return out.getvalue()


def _mp3(wav: bytes) -> bytes:
    try:
        done = subprocess.run([FFMPEG, "-v", "error", "-f", "wav", "-i", "pipe:0", "-af", FILTER, "-codec:a", "libmp3lame", "-q:a", "4", "-ar", "44100", "-ac", "1",
                               "-f", "mp3", "pipe:1"], input=wav, capture_output=True, timeout=30, check=True)
    except (OSError, subprocess.SubprocessError) as e:
        raise VoiceUnavailable("The audio encoder (ffmpeg) is not working.") from e
    if not done.stdout:
        raise VoiceUnavailable("The audio encoder produced nothing.")
    return done.stdout


def render(lang: str, text: str) -> str:
    """Makes sure the clip for this phrase exists and returns its id. Raises VoiceUnavailable when the voice is not set up or fails."""
    if lang not in LANGUAGES or not text.strip() or len(text) > MAX_TEXT:
        raise ValueError("not a phrase")
    clip = clip_id(lang, text)
    target = clip_path(clip)
    if target.exists():
        return clip
    if not available(lang):
        raise VoiceUnavailable("The natural voice is not set up on this server.")
    with _lock:
        if target.exists():
            return clip
        try:
            mp3 = _mp3(_wav(lang, text))
        except VoiceUnavailable:
            raise
        except Exception as e:                                    # Piper's own errors: a bad model file, an unsayable text
            raise VoiceUnavailable("The voice could not say that.") from e
        target.parent.mkdir(parents=True, exist_ok=True)
        part = target.with_suffix(".part")
        part.write_bytes(mp3)
        part.replace(target)                                      # never a half-written clip under its final name
    return clip


def status() -> dict:
    return {"available": available("en"), "street_available": available("de"), "voice": model_name("en"), "street_voice": model_name("de")}


def read(clip: str) -> Optional[Path]:
    """The file of a rendered clip, or None."""
    if not ID_PATTERN.match(clip):
        return None
    path = clip_path(clip)
    return path if path.exists() else None
