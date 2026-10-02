"""Speed against the limit, from a ride's points and what the map matcher found for each of them. Pure functions.

Two kinds of limit, never mixed up:
  * tagged: the OpenStreetMap road carries a `maxspeed`. Reliable where present.
  * estimated: it does not, so the Swiss default for its road class is assumed. These are guesses: in a town a 'secondary' road is really 50, not 80, so an
    estimated limit can be too HIGH (a speeding stretch missed) but is never made up for a road class that has no default.
The headline numbers use tagged limits only; estimated ones are reported separately. Nothing here applies a legal tolerance or says a fine is due:
it is the raw difference between your GPS speed and the number on the map.
"""
from typing import Optional, Sequence

# Switzerland's general limits outside built-up areas, by Valhalla road class. Built-up roads (50) cannot be told from here, see the module docstring.
SWISS_DEFAULTS = {"motorway": 120, "trunk": 100, "primary": 80, "secondary": 80, "tertiary": 80, "unclassified": 80, "residential": 50}
MAX_STEP_S = 10.0               # a gap between two fixes longer than this is not counted as time spent at either speed
NOTABLE_OVER_KMH = 5.0          # "clearly over": at least this much above the limit


def limit_for(match: Optional[dict]) -> tuple[Optional[int], Optional[str]]:
    """(limit in km/h, "tagged" | "estimated") for a matched point, or (None, None)."""
    if not match:
        return None, None
    tagged = match.get("limit_kmh")
    if tagged:
        return int(round(tagged)), "tagged"
    default = SWISS_DEFAULTS.get(match.get("road_class") or "")
    return (default, "estimated") if default else (None, None)


def analyze(points: Sequence[dict], matches: Sequence[Optional[dict]]) -> dict:
    """points: prepared track points (t seconds, mps, dist metres). matches: one entry per point (see valhalla.match_points).

    Each point stands for the time until the next one (at most MAX_STEP_S) at its own speed. Returns totals for tagged and for estimated limits, the stretches
    where you were over a tagged limit, and how much of the ride was on roads without a tagged limit.
    """
    n = len(points)
    totals = {"tagged": {"seconds": 0.0, "over_seconds": 0.0, "notable_seconds": 0.0, "over_metres": 0.0},
              "estimated": {"seconds": 0.0, "over_seconds": 0.0, "notable_seconds": 0.0, "over_metres": 0.0}}
    worst = None
    stretches: list[dict] = []
    current: Optional[dict] = None
    matched_seconds = 0.0
    total_seconds = 0.0
    for i, p in enumerate(points):
        step = min(points[i + 1]["t"] - p["t"], MAX_STEP_S) if i + 1 < n else 0.0
        if step <= 0:
            continue
        total_seconds += step
        limit, source = limit_for(matches[i] if i < len(matches) else None)
        if limit is None:
            current = _close(current, stretches)
            continue
        matched_seconds += step
        kmh = p["mps"] * 3.6
        over = kmh - limit
        bucket = totals[source]
        bucket["seconds"] += step
        if over > 0:
            bucket["over_seconds"] += step
            bucket["over_metres"] += p["mps"] * step
            if over >= NOTABLE_OVER_KMH:
                bucket["notable_seconds"] += step
        if source != "tagged":
            current = _close(current, stretches)
            continue
        if over > 0:
            name = (matches[i] or {}).get("name")
            if current is None:
                current = {"t_start": round(p["t"], 1), "t_end": round(p["t"] + step, 1), "limit_kmh": limit, "max_kmh": round(kmh), "max_over_kmh": round(over),
                           "name": name, "dist_start_m": round(p["dist"])}
            else:
                current["t_end"] = round(p["t"] + step, 1)
                current["max_kmh"] = max(current["max_kmh"], round(kmh))
                current["max_over_kmh"] = max(current["max_over_kmh"], round(over))
                current["name"] = current["name"] or name
            if worst is None or over > worst["over_kmh"]:
                worst = {"t": round(p["t"], 1), "over_kmh": round(over), "kmh": round(kmh), "limit_kmh": limit, "name": name}
        else:
            current = _close(current, stretches)
    _close(current, stretches)

    def share(part: float, whole: float) -> Optional[float]:
        return round(100.0 * part / whole, 1) if whole > 0 else None

    tagged, estimated = totals["tagged"], totals["estimated"]
    return {
        "tagged": {"seconds": round(tagged["seconds"]), "over_seconds": round(tagged["over_seconds"]), "notable_seconds": round(tagged["notable_seconds"]),
                   "over_metres": round(tagged["over_metres"]), "over_share": share(tagged["over_seconds"], tagged["seconds"])},
        "estimated": {"seconds": round(estimated["seconds"]), "over_seconds": round(estimated["over_seconds"]), "notable_seconds": round(estimated["notable_seconds"]),
                      "over_metres": round(estimated["over_metres"]), "over_share": share(estimated["over_seconds"], estimated["seconds"])},
        "worst": worst,
        "stretches": stretches,
        "matched_share": share(matched_seconds, total_seconds),
        "tagged_share": share(tagged["seconds"], total_seconds),
    }


def _close(current: Optional[dict], stretches: list[dict]) -> None:
    if current is not None:
        stretches.append(current)
    return None
