"""GPX 1.1 export of a ride and import of a track from other apps (Strava, Komoot, a bike computer ...). Pure functions: no database, no network.

Export writes every stored point (not the thinned map track): position, elevation, time in UTC and the speed in a small extension, so another app can
use it and RideLog can read it back. Import is strict about what it will parse (it is a file from outside): a size limit, no DOCTYPE or entities (so
no entity-expansion tricks), plausible coordinates only, points sorted by time, repeated timestamps dropped.
"""
import hashlib
import math
import re
import xml.etree.ElementTree as ET
from datetime import datetime, timezone
from typing import Optional, Sequence
from xml.sax.saxutils import escape

from . import geo

GPX_NS = "http://www.topografix.com/GPX/1/1"
RIDELOG_NS = "https://ride-logger.invalid/gpx/1"          # a made-up address: it only names the extension elements
MAX_BYTES = 15 * 1024 * 1024
MAX_POINTS = 200_000
MIN_POINTS = 2
_DANGEROUS = re.compile(rb"<!\s*(DOCTYPE|ENTITY)", re.IGNORECASE)


class GpxError(ValueError):
    """The file cannot be used. The message is written for the person who chose the file."""


# -------------------------------------------------------------------------------------------------------------------------------- export --

def _iso_z(text: str) -> str:
    """A stored timestamp as GPX wants it: UTC, whole seconds when there are no fractions, 'Z'."""
    dt = datetime.fromisoformat(text)
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    dt = dt.astimezone(timezone.utc)
    return dt.strftime("%Y-%m-%dT%H:%M:%S") + (f".{dt.microsecond // 1000:03d}" if dt.microsecond else "") + "Z"


def build_gpx(rows: Sequence, name: str) -> bytes:
    """GPX for one ride from its stored point rows (lat, lon, timestamp, speed, altitude, horizontal_accuracy), oldest first."""
    out = [
        '<?xml version="1.0" encoding="UTF-8"?>',
        f'<gpx version="1.1" creator="RideLog" xmlns="{GPX_NS}" xmlns:rl="{RIDELOG_NS}">',
    ]
    if rows:
        out.append(f"<metadata><name>{escape(name)}</name><time>{_iso_z(rows[0]['timestamp'])}</time></metadata>")
    out.append(f"<trk><name>{escape(name)}</name><trkseg>")
    for r in rows:
        parts = [f'<trkpt lat="{r["lat"]:.6f}" lon="{r["lon"]:.6f}">']
        if r["altitude"] is not None:
            parts.append(f"<ele>{r['altitude']:.1f}</ele>")
        parts.append(f"<time>{_iso_z(r['timestamp'])}</time>")
        ext = []
        if r["speed"] is not None and r["speed"] >= 0:
            ext.append(f"<rl:speed>{r['speed']:.2f}</rl:speed>")
        if r["horizontal_accuracy"] is not None and r["horizontal_accuracy"] >= 0:
            ext.append(f"<rl:hacc>{r['horizontal_accuracy']:.1f}</rl:hacc>")
        if ext:
            parts.append("<extensions>" + "".join(ext) + "</extensions>")
        parts.append("</trkpt>")
        out.append("".join(parts))
    out.append("</trkseg></trk></gpx>")
    return "\n".join(out).encode("utf-8")


def build_route_gpx(name: str, points) -> bytes:
    """GPX 1.1 for a planned route: a track with no times (there are none yet), which Garmin, Komoot, Strava and Apple Files all take. `points` are (lat, lon)."""
    out = [
        '<?xml version="1.0" encoding="UTF-8"?>',
        f'<gpx version="1.1" creator="RideLog" xmlns="{GPX_NS}">',
        f"<metadata><name>{escape(name)}</name></metadata>",
        f"<trk><name>{escape(name)}</name><trkseg>",
    ]
    out += [f'<trkpt lat="{lat:.6f}" lon="{lon:.6f}"/>' for lat, lon in points]
    out.append("</trkseg></trk></gpx>")
    return "\n".join(out).encode("utf-8")


# -------------------------------------------------------------------------------------------------------------------------------- import --

def _local(tag) -> str:
    return tag.rsplit("}", 1)[-1] if isinstance(tag, str) else ""


def _child_text(el, name: str) -> Optional[str]:
    for c in el:
        if _local(c.tag) == name and c.text and c.text.strip():
            return c.text.strip()
    return None


def _when(text: Optional[str]) -> Optional[datetime]:
    if not text:
        return None
    try:
        dt = datetime.fromisoformat(text.replace("Z", "+00:00"))
    except ValueError:
        return None
    return dt.astimezone(timezone.utc) if dt.tzinfo else dt.replace(tzinfo=timezone.utc)


def _number(text: Optional[str]) -> Optional[float]:
    try:
        value = float(text) if text is not None else None
    except ValueError:
        return None
    return value if value is not None and math.isfinite(value) else None


def _speed_extension(trkpt) -> Optional[float]:
    """A speed in m/s if the point carries one (our rl:speed, or another app's <speed> in its extensions); never a negative or absurd one."""
    ext = next((c for c in trkpt if _local(c.tag) == "extensions"), None)
    if ext is None:
        return None
    for el in ext.iter():
        if _local(el.tag) == "speed":
            v = _number((el.text or "").strip() or None)
            if v is not None and 0 <= v < 150:
                return v
    return None


def parse_gpx(data: bytes) -> list[dict]:
    """One entry per <trk> in the file: {"name", "points": [{lat, lon, time, ele, speed}]}, points sorted by time with repeated times dropped.
    Raises GpxError with a plain message when the file is not usable."""
    if len(data) > MAX_BYTES:
        raise GpxError(f"This file is larger than {MAX_BYTES // (1024 * 1024)} MB.")
    if _DANGEROUS.search(data[:200_000]) or _DANGEROUS.search(data):
        raise GpxError("This file contains DOCTYPE or ENTITY declarations, which are not allowed in a GPX file.")
    try:
        root = ET.fromstring(data)
    except ET.ParseError as e:
        raise GpxError("This is not a readable GPX file.") from e
    if _local(root.tag) != "gpx":
        raise GpxError("This is not a GPX file.")

    tracks = []
    total = 0
    for trk in (e for e in root if _local(e.tag) == "trk"):
        raw = []
        for seg in (s for s in trk if _local(s.tag) == "trkseg"):
            for pt in (p for p in seg if _local(p.tag) == "trkpt"):
                lat, lon = _number(pt.attrib.get("lat")), _number(pt.attrib.get("lon"))
                if lat is None or lon is None or not (-90 <= lat <= 90 and -180 <= lon <= 180):
                    continue
                raw.append({"lat": lat, "lon": lon, "time": _when(_child_text(pt, "time")), "ele": _number(_child_text(pt, "ele")),
                            "speed": _speed_extension(pt)})
        total += len(raw)
        if total > MAX_POINTS:
            raise GpxError(f"This file has more than {MAX_POINTS:,} points.")
        if not raw:
            continue
        timed = [p for p in raw if p["time"] is not None]
        if len(timed) < MIN_POINTS:
            raise GpxError("The track in this file has no timestamps, so speed and duration cannot be worked out.")
        timed.sort(key=lambda p: p["time"])
        points = []
        for p in timed:
            if points and p["time"] <= points[-1]["time"]:
                continue
            points.append(p)
        if len(points) >= MIN_POINTS:
            tracks.append({"name": _child_text(trk, "name") or "Imported ride", "points": points})
    if not tracks:
        raise GpxError("This file has no track with at least two timed points.")
    return tracks


def import_id(owner_sub: str, points: Sequence[dict]) -> str:
    """The same file imported twice by the same person gets the same trip id, so the second import is recognised. Different people get different
    ones (the rides table needs trip ids that are unique across all accounts)."""
    key = f"{owner_sub}|{points[0]['time'].isoformat()}|{points[-1]['time'].isoformat()}|{len(points)}"
    return "gpx-" + hashlib.sha1(key.encode("utf-8")).hexdigest()[:20]


def sample_for_duplicate_check(points: Sequence[dict], n: int = 40) -> list[dict]:
    """Evenly spread points to look for in the database: if almost all are already there, this ride was recorded or imported before."""
    if len(points) <= n:
        return list(points)
    step = (len(points) - 1) / (n - 1)
    return [points[round(i * step)] for i in range(n)]


def derived_speeds(points: Sequence[dict]) -> list[Optional[float]]:
    """Speed per point in m/s for files that carry none: between the neighbours, as the map track does it."""
    out: list[Optional[float]] = []
    n = len(points)
    for i, p in enumerate(points):
        a, b = points[max(0, i - 1)], points[min(n - 1, i + 1)]
        dt = (b["time"] - a["time"]).total_seconds()
        out.append(geo.haversine_m(a["lat"], a["lon"], b["lat"], b["lon"]) / dt if dt > 0 else None)
    return out
