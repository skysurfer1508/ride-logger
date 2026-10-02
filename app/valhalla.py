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
NO_ROUTE_CODES = {171, 442, 443, 444}


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


# ----------------------------------------------------------------------------------------------------------------------------------- routing --

class NoRoute(Exception):
    """Valhalla found no way between the points (or one of them is not near a suitable road)."""


def decode_polyline6(encoded: str) -> list[tuple[float, float]]:
    """Valhalla's encoded line (Google's polyline algorithm at 1e-6 degrees) as (lat, lon) pairs."""
    coords: list[tuple[float, float]] = []
    index = lat = lon = 0
    while index < len(encoded):
        for axis in (0, 1):
            shift = result = 0
            while True:
                byte = ord(encoded[index]) - 63
                index += 1
                result |= (byte & 0x1F) << shift
                shift += 5
                if byte < 0x20:
                    break
            delta = ~(result >> 1) if result & 1 else result >> 1
            if axis == 0:
                lat += delta
            else:
                lon += delta
        coords.append((lat / 1e6, lon / 1e6))
    return coords


def encode_polyline6(coords: Sequence[tuple[float, float]]) -> str:
    """The polyline algorithm at 1e-6 degrees: the other way round from decode_polyline6. A whole route in a few kilobytes of text."""
    out: list[str] = []
    last_lat = last_lon = 0
    for lat, lon in coords:
        for value, last in ((round(lat * 1e6), last_lat), (round(lon * 1e6), last_lon)):
            delta = value - last
            delta = ~(delta << 1) if delta < 0 else delta << 1
            while delta >= 0x20:
                out.append(chr((0x20 | (delta & 0x1F)) + 63))
                delta >>= 5
            out.append(chr(delta + 63))
        last_lat, last_lon = round(lat * 1e6), round(lon * 1e6)
    return "".join(out)


def _haversine_m(a: tuple[float, float], b: tuple[float, float]) -> float:
    from . import geo
    return geo.haversine_m(a[0], a[1], b[0], b[1])


def parse_trip(trip: dict) -> dict:
    """One Valhalla trip as {"distance_m", "duration_s", "shape": [(lat, lon)...], "maneuvers": [...]}. `maneuvers` is empty unless the request asked for
    instructions. Each maneuver: type (Valhalla's code), instruction (written), pre / alert / post (the sentences meant to be spoken before, at and after it),
    street, length_m, time_s, along_m (metres from the start of the whole route), lat / lon (where it happens), leg (which stretch between stops), roundabout_exit."""
    shape: list[tuple[float, float]] = []
    offsets: list[int] = []
    for leg in trip.get("legs", []):
        part = decode_polyline6(leg.get("shape", ""))
        offsets.append(max(0, len(shape) - 1) if shape else 0)            # the next leg starts at the last point of this one
        shape.extend(part[1:] if shape and part else part)
    if len(shape) < 2:
        raise NoRoute("The map service returned an empty route.")
    cumulative = [0.0]
    for a, b in zip(shape, shape[1:]):
        cumulative.append(cumulative[-1] + _haversine_m(a, b))
    maneuvers: list[dict] = []
    for leg_no, leg in enumerate(trip.get("legs", [])):
        for m in leg.get("maneuvers") or []:
            index = min(len(shape) - 1, offsets[leg_no] + int(m.get("begin_shape_index", 0)))
            streets = m.get("street_names") or []
            maneuvers.append({
                "type": int(m.get("type", 0)),
                "instruction": m.get("instruction") or "",
                "pre": m.get("verbal_pre_transition_instruction") or m.get("instruction") or "",
                "alert": m.get("verbal_transition_alert_instruction"),
                "post": m.get("verbal_post_transition_instruction"),
                "street": streets[0] if streets else None,
                "length_m": round(float(m.get("length", 0.0)) * 1000.0),
                "time_s": round(float(m.get("time", 0.0))),
                "along_m": round(cumulative[index]),
                "lat": round(shape[index][0], 6),
                "lon": round(shape[index][1], 6),
                "leg": leg_no,
                "roundabout_exit": m.get("roundabout_exit_count"),
            })
    summary = trip.get("summary") or {}
    return {"distance_m": float(summary.get("length", 0.0)) * 1000.0, "duration_s": float(summary.get("time", 0.0)), "shape": shape, "maneuvers": maneuvers}


def route(locations: Sequence[dict], avoid_motorways: bool = True, paved_only: bool = True, *, costing_options: Optional[dict] = None, directions: bool = False,
          language: str = "en-US", alternates: int = 0, heading: Optional[float] = None) -> dict:
    """A motorcycle route through the locations ({"lat", "lon", optional "type": "break" | "through"}, in order).
    Returns {"distance_m", "duration_s", "shape": [(lat, lon), ...], "maneuvers": [...]} (see parse_trip) and, with `alternates`, "alternates": [the same, ...] for other
    ways between the same two points. `costing_options` replaces the avoid_motorways / paved_only settings (the planner's styles); `heading` is the direction the rider
    is already travelling at the first location, so a new route does not start with a U-turn. Raises NoRoute, or ValhallaUnavailable when the service is off or down."""
    if not configured():
        raise ValhallaUnavailable("The map service is switched off.")
    if costing_options is None:
        costing_options = {"use_trails": 0.0, "use_ferry": 0.0}
        if avoid_motorways:
            costing_options.update({"exclude_highways": True, "exclude_tolls": True})
        if paved_only:
            costing_options["exclude_unpaved"] = True
    stops = [dict(l) for l in locations]
    if heading is not None and stops:
        stops[0]["heading"] = round(heading) % 360
        stops[0]["heading_tolerance"] = 60
    payload: dict = {"locations": stops, "costing": "motorcycle", "costing_options": {"motorcycle": costing_options},
                     "directions_type": "instructions" if directions else "none"}
    if directions:
        payload["directions_options"] = {"language": language, "units": "kilometers"}
    if alternates > 0 and len(stops) == 2:
        payload["alternates"] = alternates
    try:
        answer = _post("/route", payload)
    except NoMatch as e:                                    # _post reads error codes 171/442/443 as "no match": for a route that means "no way"
        raise NoRoute(str(e)) from e
    except ValhallaUnavailable as e:
        if "(400)" in str(e):
            raise NoRoute("The map service could not find a way between those points.") from e
        raise
    result = parse_trip(answer.get("trip") or {})
    others = []
    for alternate in answer.get("alternates") or []:
        try:
            others.append(parse_trip(alternate.get("trip") or {}))
        except NoRoute:
            continue
    if others:
        result["alternates"] = others
    return result
