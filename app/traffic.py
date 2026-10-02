"""Live road information for the app's Traffic tab, fetched by the SERVER so the API keys never reach the phone:

  * incidents: the official Swiss traffic situations (accidents, congestion, roadworks), DATEX II from opentransportdata.swiss
  * webcams: public webcams near a spot, from the Windy Webcams API

(Apple's live traffic colours need none of this: MapKit draws them on the phone.)

Neither source has been run against the live service by the author: that needs your keys. `python -m app.cli check-traffic` calls each one once and
prints what came back (and the start of the raw answer when nothing could be read), so a wrong guess about the format is quick to fix.
The parsers are deliberately forgiving: they look for DATEX II elements by name, ignore namespaces, and skip what they don't understand.
"""
import threading
import time
import xml.etree.ElementTree as ET
from typing import Callable, Optional

import httpx

from . import geo
from .config import settings

TIMEOUT_S = 15.0
INCIDENTS_TTL_S = 300          # the feed changes every few minutes; one fetch serves every request meanwhile
WEBCAMS_TTL_S = 480            # Windy's free image links expire after 15 minutes: never serve one older than this
STALE_OK_S = 3600              # if a refresh fails, an answer up to this old is better than an error
MAX_RESULTS = 100

INCIDENTS_URL = "https://api.opentransportdata.swiss/TDP/Soap_Datex2/TrafficSituations/Pull"
INCIDENTS_SOAP_ACTION = "http://opentransportdata.swiss/TDP/Soap_Datex2/Pull/v1/pullTrafficMessages"
INCIDENTS_ENVELOPE = ('<?xml version="1.0" encoding="UTF-8"?>'
                      '<soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/"><soap:Body/></soap:Envelope>')
WINDY_URL = "https://api.windy.com/webcams/api/v3/webcams"


class TrafficUnavailable(Exception):
    """A source could not be reached or understood. The message is safe to show: it never contains a key."""


def incidents_configured() -> bool:
    return bool(settings.opentransportdata_api_key.strip())


def webcams_configured() -> bool:
    return bool(settings.windy_api_key.strip())


# ------------------------------------------------------------------------------------------------------------------------------ cache --

_cache: dict[str, tuple[float, float, object]] = {}      # key -> (fresh until, stored at, value), monotonic seconds
_lock = threading.Lock()


def _cached(key: str, ttl: float, loader: Callable[[], object]):
    now = time.monotonic()
    with _lock:
        hit = _cache.get(key)
    if hit and hit[0] > now:
        return hit[2]
    try:
        value = loader()
    except TrafficUnavailable:
        if hit and now - hit[1] < STALE_OK_S:
            return hit[2]
        raise
    with _lock:
        _cache[key] = (now + ttl, now, value)
        if len(_cache) > 200:
            for k in sorted(_cache, key=lambda k: _cache[k][1])[:50]:
                del _cache[k]
    return value


# -------------------------------------------------------------------------------------------------------------------------- incidents --

KINDS = [   # (substring of the DATEX II record type, our kind, label); first match wins
    ("Accident", "accident", "Accident"),
    ("AbnormalTraffic", "congestion", "Congestion"),
    ("Congestion", "congestion", "Congestion"),
    ("Roadworks", "roadworks", "Roadworks"),
    ("MaintenanceWorks", "roadworks", "Roadworks"),
    ("ConstructionWorks", "roadworks", "Roadworks"),
    ("Obstruction", "hazard", "Obstruction"),
    ("WeatherRelated", "hazard", "Weather hazard"),
    ("EnvironmentalObstruction", "hazard", "Hazard"),
    ("RoadOrCarriagewayOrLaneManagement", "closure", "Closure / lane restriction"),
    ("NetworkManagement", "closure", "Traffic management"),
    ("SpeedManagement", "closure", "Speed restriction"),
]
_XSI_TYPE = "{http://www.w3.org/2001/XMLSchema-instance}type"


def _local(tag) -> str:
    return tag.rsplit("}", 1)[-1] if isinstance(tag, str) else ""


def _text(el) -> str:
    return (el.text or "").strip() if el is not None else ""


def _first(el, name):
    return next((c for c in el.iter() if _local(c.tag) == name), None)


def _kind_of(record) -> tuple[str, str]:
    declared = record.attrib.get(_XSI_TYPE, "") or _local(record.tag)
    for needle, kind, label in KINDS:
        if needle.lower() in declared.lower():
            return kind, label
    return "other", "Traffic event"


def _position(record) -> Optional[tuple[float, float]]:
    """The first latitude/longitude pair inside the record (DATEX II: <pointCoordinates><latitude/><longitude/>; a linear section starts somewhere)."""
    lat_el, lon_el = _first(record, "latitude"), _first(record, "longitude")
    try:
        lat, lon = float(_text(lat_el)), float(_text(lon_el))
    except ValueError:
        return None
    return (lat, lon) if -90 <= lat <= 90 and -180 <= lon <= 180 and (lat or lon) else None


def _comment(record) -> str:
    for c in record.iter():
        if _local(c.tag) == "generalPublicComment":
            values = [_text(v) for v in c.iter() if _local(v.tag) == "value" and _text(v)]
            if values:
                return values[0][:400]
    return ""


def parse_datex(xml: bytes) -> tuple[list[dict], int]:
    """(situations with a map position, how many had none). Never raises on odd content: it returns what it could read."""
    try:
        root = ET.fromstring(xml)
    except ET.ParseError as e:
        raise TrafficUnavailable("The traffic feed sent something that is not XML.") from e
    located: list[dict] = []
    unlocated = 0
    for situation in (el for el in root.iter() if _local(el.tag) == "situation"):
        for record in (el for el in situation.iter() if _local(el.tag) == "situationRecord"):
            pos = _position(record)
            if pos is None:
                unlocated += 1
                continue
            kind, label = _kind_of(record)
            road = _first(record, "roadNumber")
            located.append({
                "id": record.attrib.get("id") or situation.attrib.get("id") or f"{pos[0]:.5f},{pos[1]:.5f}",
                "kind": kind,
                "title": label,
                "severity": _text(_first(record, "severity")).lower() or None,
                "comment": _comment(record),
                "road": _text(road) or None,
                "start": _text(_first(record, "overallStartTime")) or None,
                "end": _text(_first(record, "overallEndTime")) or None,
                "lat": round(pos[0], 6),
                "lon": round(pos[1], 6),
            })
    return located, unlocated


def _post_soap(body: str) -> bytes:
    headers = {"Authorization": settings.opentransportdata_api_key.strip(), "SOAPAction": INCIDENTS_SOAP_ACTION,
               "Content-Type": "text/xml; charset=utf-8", "User-Agent": settings.osm_user_agent}
    try:
        response = httpx.post(INCIDENTS_URL, content=body.encode("utf-8"), headers=headers, timeout=TIMEOUT_S)
    except httpx.HTTPError as e:
        raise TrafficUnavailable("The Swiss traffic service could not be reached.") from e
    if response.status_code in (401, 403):
        raise TrafficUnavailable("The Swiss traffic service refused the API key. Check OPENTRANSPORTDATA_API_KEY and that it is subscribed to Traffic situations.")
    if response.status_code == 429:
        raise TrafficUnavailable("The Swiss traffic service says there were too many requests. Try again in a few minutes.")
    if response.status_code != 200:
        raise TrafficUnavailable(f"The Swiss traffic service answered with an error ({response.status_code}).")
    return response.content


def incidents_near(lat: float, lon: float, radius_km: float) -> dict:
    if not incidents_configured():
        raise TrafficUnavailable("Not set up on the server.")
    everything, unlocated = _cached("incidents", INCIDENTS_TTL_S, lambda: parse_datex(_post_soap(INCIDENTS_ENVELOPE)))
    found = []
    for item in everything:
        d = geo.haversine_m(lat, lon, item["lat"], item["lon"]) / 1000
        if d <= radius_km:
            found.append({**item, "distance_km": round(d, 1)})
    found.sort(key=lambda i: i["distance_km"])
    return {"incidents": found[:MAX_RESULTS], "unlocated": unlocated, "total": len(everything)}


# ---------------------------------------------------------------------------------------------------------------------------- webcams --

def _windy_get(params: dict) -> dict:
    headers = {"x-windy-api-key": settings.windy_api_key.strip(), "User-Agent": settings.osm_user_agent}
    try:
        response = httpx.get(WINDY_URL, params=params, headers=headers, timeout=TIMEOUT_S)
    except httpx.HTTPError as e:
        raise TrafficUnavailable("The webcam service could not be reached.") from e
    if response.status_code in (401, 403):
        raise TrafficUnavailable("The webcam service refused the API key. Check WINDY_API_KEY.")
    if response.status_code == 400:
        raise ValueError("bad request")           # caught below: retried without the category filter
    if response.status_code != 200:
        raise TrafficUnavailable(f"The webcam service answered with an error ({response.status_code}).")
    try:
        return response.json()
    except ValueError as e:
        raise TrafficUnavailable("The webcam service sent something unreadable.") from e


def parse_webcams(data: dict) -> list[dict]:
    out = []
    for cam in data.get("webcams", []) or []:
        location = cam.get("location") or {}
        try:
            lat, lon = float(location["latitude"]), float(location["longitude"])
        except (KeyError, TypeError, ValueError):
            continue
        current = (cam.get("images") or {}).get("current") or {}
        player = cam.get("player") or {}
        urls = cam.get("urls") or {}
        out.append({
            "id": str(cam.get("webcamId") or cam.get("id") or f"{lat},{lon}"),
            "title": str(cam.get("title") or "Webcam"),
            "lat": round(lat, 6),
            "lon": round(lon, 6),
            "preview": current.get("preview") or current.get("thumbnail") or current.get("icon"),
            "detail_url": urls.get("detail"),
            "player_url": player.get("live") or player.get("day"),
        })
    return out


def webcams_near(lat: float, lon: float, radius_km: float) -> dict:
    if not webcams_configured():
        raise TrafficUnavailable("Not set up on the server.")

    def load():
        params = {"nearby": f"{lat:.4f},{lon:.4f},{int(round(radius_km))}", "limit": 50, "include": "location,images,urls,player"}
        try:
            data = _windy_get({**params, "categories": "traffic"})
        except ValueError:                         # this API version did not accept the filter: ask for everything nearby
            try:
                data = _windy_get(params)
            except ValueError as e:
                raise TrafficUnavailable("The webcam service did not accept the request.") from e
        return parse_webcams(data)

    cams = _cached(f"windy:{lat:.2f}:{lon:.2f}:{int(round(radius_km))}", WEBCAMS_TTL_S, load)
    found = [{**c, "distance_km": round(geo.haversine_m(lat, lon, c["lat"], c["lon"]) / 1000, 1)} for c in cams]
    found.sort(key=lambda c: c["distance_km"])
    return {"webcams": found}


# ------------------------------------------------------------------------------------------------------------------------------ check --

def check(lat: float = 47.3769, lon: float = 8.5417) -> list[str]:
    """One live call per configured source, for `python -m app.cli check-traffic`. Never prints a key."""
    lines = []
    if not incidents_configured():
        lines.append("incidents: OPENTRANSPORTDATA_API_KEY is empty, layer off")
    else:
        try:
            raw = _post_soap(INCIDENTS_ENVELOPE)
            located, unlocated = parse_datex(raw)
            lines.append(f"incidents: HTTP 200, {len(raw)} bytes, {len(located)} with a map position, {unlocated} without")
            if not located:
                lines.append("  nothing could be read; the start of the raw answer follows (send this to Claude Code):")
                lines.append("  " + raw[:1500].decode("utf-8", "replace").replace("\n", "\n  "))
        except TrafficUnavailable as e:
            lines.append(f"incidents: FAILED: {e}")
    if not webcams_configured():
        lines.append("webcams: WINDY_API_KEY is empty, layer off")
    else:
        try:
            result = webcams_near(lat, lon, 25)
            lines.append(f"webcams: {len(result['webcams'])} within 25 km of the centre of Zurich")
            for cam in result["webcams"][:5]:
                lines.append(f"  {cam['distance_km']:>5} km  {cam['title']}")
        except TrafficUnavailable as e:
            lines.append(f"webcams: FAILED: {e}")
    return lines
