"""Client for the self-hosted Valhalla (deploy/valhalla): matches a ride's GPS points to OpenStreetMap roads, which says which road you were on, what
its speed limit is when OSM has one, and later also plans routes. Only this server talks to Valhalla (127.0.0.1:8002), never the phone.

A ride is matched in chunks: one long request is slow, and a place where the track cannot be matched (a ferry, a car park, a private road) must only
cost that chunk, not the whole ride. Points that could not be matched come back as None and are simply left out of every number.
"""
from typing import Optional, Sequence

import httpx

from .config import settings

TIMEOUT_S = 120.0
CHUNK_POINTS = 1500
CHUNK_OVERLAP = 25            # points repeated at the start of the next chunk so the matcher has context; the earlier chunk's answer is kept for them
NO_MATCH_CODES = {171, 442, 443}


class ValhallaUnavailable(Exception):
    """The map service could not be reached or understood. The message is safe to show."""


class NoMatch(Exception):
    """This stretch of the track could not be matched to roads."""


def configured() -> bool:
    return bool(settings.valhalla_url.strip())


def _base() -> str:
    return settings.valhalla_url.strip().rstrip("/")


def _post(path: str, payload: dict) -> dict:
    try:
        response = httpx.post(_base() + path, json=payload, timeout=TIMEOUT_S)
    except httpx.HTTPError as e:
        raise ValhallaUnavailable("The map service could not be reached.") from e
    if response.status_code == 200:
        try:
            return response.json()
        except ValueError as e:
            raise ValhallaUnavailable("The map service sent something unreadable.") from e
    try:
        body = response.json()
    except ValueError:
        body = {}
    if response.status_code == 400 and (body.get("error_code") in NO_MATCH_CODES or "match" in str(body.get("error", "")).lower()):
        raise NoMatch(str(body.get("error", "no match")))
    raise ValhallaUnavailable(f"The map service answered with an error ({response.status_code}).")


def status() -> dict:
    try:
        response = httpx.get(_base() + "/status", timeout=10.0)
        response.raise_for_status()
        return response.json()
    except (httpx.HTTPError, ValueError) as e:
        raise ValhallaUnavailable("The map service is not answering.") from e


ATTRIBUTES = ["edge.names", "edge.speed_limit", "edge.road_class", "edge.way_id", "edge.use", "edge.length", "matched.type", "matched.edge_index"]


def trace_attributes(points: Sequence[tuple[float, float]]) -> dict:
    """One map-matching request for (lat, lon) points in order."""
    payload = {
        "shape": [{"lat": round(lat, 6), "lon": round(lon, 6)} for lat, lon in points],
        "costing": "motorcycle",
        "shape_match": "map_snap",
        "filters": {"attributes": ATTRIBUTES, "action": "include"},
    }
    return _post("/trace_attributes", payload)


def parse_match(response: dict, count: int) -> list[Optional[dict]]:
    """For each of the `count` points sent: what road it was matched to (limit_kmh or None, road_class, name, way_id, use), or None if it was not matched."""
    edges = response.get("edges") or []
    matched = response.get("matched_points") or []
    out: list[Optional[dict]] = []
    for i in range(count):
        mp = matched[i] if i < len(matched) else None
        if not mp or mp.get("type") == "unmatched" or mp.get("edge_index") is None:
            out.append(None)
            continue
        index = mp["edge_index"]
        if not (0 <= index < len(edges)):
            out.append(None)
            continue
        edge = edges[index]
        names = edge.get("names") or []
        limit = edge.get("speed_limit")
        out.append({
            "limit_kmh": limit if isinstance(limit, (int, float)) and 0 < limit < 250 else None,
            "road_class": edge.get("road_class"),
            "name": names[0] if names else None,
            "way_id": edge.get("way_id"),
            "use": edge.get("use"),
        })
    return out


def chunk_ranges(total: int, size: int = CHUNK_POINTS, overlap: int = CHUNK_OVERLAP) -> list[tuple[int, int, int]]:
    """(start, end, first index whose answer this chunk is responsible for). Chunks overlap by `overlap` points; each point is taken from the chunk before."""
    if total <= 0:
        return []
    ranges: list[tuple[int, int, int]] = []
    start = 0
    while True:
        end = min(total, start + size)
        keep_from = start if not ranges else min(start + overlap, end)
        ranges.append((start, end, keep_from))
        if end >= total:
            return ranges
        start = end - overlap


def match_points(points: Sequence[tuple[float, float]]) -> list[Optional[dict]]:
    """Matches a whole track chunk by chunk. A chunk that cannot be matched leaves its points as None."""
    result: list[Optional[dict]] = [None] * len(points)
    for start, end, keep_from in chunk_ranges(len(points)):
        try:
            matched = parse_match(trace_attributes(points[start:end]), end - start)
        except NoMatch:
            continue
        for i in range(keep_from, end):
            result[i] = matched[i - start]
    return result
