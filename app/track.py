"""A ride's full GPS track for the app's map, and the stops in it. Pure functions, no database: the caller hands in the ride's point rows.

The track is measured with the same rules as the ride's own numbers (geo.filter_points), so the map, the top speed and the distance always
agree with the ride card.

Stops are the interesting part. The iOS recorder uses a 5 m distance filter, so while the rider stands at a red light the phone sends NOTHING:
a stop then shows up as a time gap between two fixes that are close together, not as a run of 0 km/h fixes. Overland, and the app while
creeping, do send low-speed fixes. detect_stops() handles both.
"""
import math
from typing import Optional, Sequence

from . import geo
from .processing import _rows_to_points

# --- stop detection -------------------------------------------------------------------------------------------------------------------
STOP_SPEED_MPS = 0.8        # slower than this (about walking pace /4) counts as standing still
STOP_MAX_MOVE_M = 10.0      # ...and the fixes must not have moved further apart than this
GAP_S = 6.0                 # no fix for this long...
GAP_MAX_MOVE_M = 20.0       # ...between two fixes this close together means the phone stood still (distance filter)
MERGE_BLIP_S = 4.5          # two stationary spells closer together than this are one stop (one stray moving fix at 2 s spacing leaves 4 s)
START_END_ZONE_M = 25.0     # a wait before the bike has left this circle around the start / after it entered the one around the end is
                            # getting going or parking, not a stop (the first fix often carries a stale speed, so "touches the first fix" misses it)
MIN_STOP_S = 8.0            # shorter than this is slowing down, not a stop

# --- payload size ---------------------------------------------------------------------------------------------------------------------
MAX_TRACK_POINTS = 2500


def _prepare(rows: Sequence) -> list[dict]:
    """Filtered points, oldest first, strictly increasing in time, each with seconds since the start and the distance so far."""
    points = _rows_to_points(rows)
    points.sort(key=lambda p: p["timestamp"])
    filtered = geo.filter_points(points)
    if len(filtered) < 2:
        filtered = points
    kept: list[dict] = []
    for p in filtered:
        if kept and p["timestamp"] <= kept[-1]["timestamp"]:
            continue                                  # two fixes with the same timestamp: keep the first
        kept.append(dict(p))
    if not kept:
        return []
    start = kept[0]["timestamp"]
    dist = 0.0
    for i, p in enumerate(kept):
        if i:
            prev = kept[i - 1]
            dist += geo.haversine_m(prev["lat"], prev["lon"], p["lat"], p["lon"])
        p["t"] = (p["timestamp"] - start).total_seconds()
        p["dist"] = dist
    return kept


def _fill_speeds(points: list[dict]) -> None:
    """`mps` on every point: the reported speed when valid, otherwise worked out from the neighbours (CoreLocation uses a negative speed for 'unknown')."""
    n = len(points)
    for i, p in enumerate(points):
        reported = p.get("speed")
        if reported is not None and reported >= 0:
            p["mps"] = float(reported)
            continue
        a, b = points[max(0, i - 1)], points[min(n - 1, i + 1)]
        dt = b["t"] - a["t"]
        p["mps"] = geo.haversine_m(a["lat"], a["lon"], b["lat"], b["lon"]) / dt if dt > 0 else 0.0


def _interval_is_stationary(a: dict, b: dict) -> bool:
    dt = b["t"] - a["t"]
    d = geo.haversine_m(a["lat"], a["lon"], b["lat"], b["lon"])
    if dt >= GAP_S:
        return d < GAP_MAX_MOVE_M
    return max(a["mps"], b["mps"]) < STOP_SPEED_MPS and d < STOP_MAX_MOVE_M


def detect_stops(points: list[dict]) -> list[dict]:
    """Stops in a prepared track (needs `t`, `dist`, `mps`). A wait at the very start or the very end is not reported: that is the rider
    getting going or parking, not waiting for a light."""
    n = len(points)
    if n < 3:
        return []
    # runs of consecutive stationary intervals, as (first point index, last point index)
    runs: list[list[int]] = []
    for i in range(n - 1):
        if _interval_is_stationary(points[i], points[i + 1]):
            if runs and runs[-1][1] == i:
                runs[-1][1] = i + 1
            else:
                runs.append([i, i + 1])
    # a short lurch between two stationary spells does not end the stop
    merged: list[list[int]] = []
    for run in runs:
        if merged and points[run[0]]["t"] - points[merged[-1][1]]["t"] <= MERGE_BLIP_S:
            merged[-1][1] = run[1]
        else:
            merged.append(run)

    stops = []
    for first, last in merged:
        duration = points[last]["t"] - points[first]["t"]
        if duration < MIN_STOP_S or first == 0 or last == n - 1:
            continue
        if points[first]["dist"] < START_END_ZONE_M or points[-1]["dist"] - points[last]["dist"] < START_END_ZONE_M:
            continue
        inside = points[first:last + 1]
        lats = sorted(p["lat"] for p in inside)
        lons = sorted(p["lon"] for p in inside)
        mid = len(inside) // 2
        stops.append({
            "t_start": round(points[first]["t"], 1),
            "t_end": round(points[last]["t"], 1),
            "duration_s": round(duration, 1),
            "lat": round(lats[mid], 6),
            "lon": round(lons[mid], 6),
            "dist_from_start_m": round(points[first]["dist"]),
            "kind": "unknown",
            "label": "Stop",
            "_first": first,
            "_last": last,
        })
    return stops


def _downsample(points: list[dict], stops: list[dict], top: Optional[int]) -> list[dict]:
    n = len(points)
    if n <= MAX_TRACK_POINTS:
        return points
    must = {0, n - 1}
    if top is not None:
        must.add(top)
    for s in stops:
        must.update((s["_first"], s["_last"]))
    stride = math.ceil(n / max(1, MAX_TRACK_POINTS - len(must)))
    keep = sorted(must | set(range(0, n, stride)))
    return [points[i] for i in keep]


def build_track(rows: Sequence) -> dict:
    """Everything the map needs for one ride. Times are seconds since the first fix, so the app never parses timestamps per point."""
    points = _prepare(rows)
    if not points:
        return {"start": None, "duration_s": 0, "distance_m": 0, "points": [], "max_speed": None, "stops": [], "stopped_s": 0, "point_count": 0}
    _fill_speeds(points)
    stops = detect_stops(points)

    top = None
    for i, p in enumerate(points):
        reported = p.get("speed")
        if reported is not None and reported >= 0 and (top is None or reported > points[top]["speed"]):
            top = i
    max_speed = None
    if top is not None:
        tp = points[top]
        max_speed = {"t": round(tp["t"], 1), "mps": round(tp["speed"], 1), "lat": round(tp["lat"], 6), "lon": round(tp["lon"], 6)}

    shown = _downsample(points, stops, top)
    return {
        "start": points[0]["timestamp"].isoformat(),
        "duration_s": round(points[-1]["t"], 1),
        "distance_m": round(points[-1]["dist"]),
        "points": [
            [round(p["t"], 1), round(p["lat"], 6), round(p["lon"], 6), round(p["mps"], 1),
             None if p.get("altitude") is None else round(p["altitude"]), round(p["dist"])]
            for p in shown
        ],
        "max_speed": max_speed,
        "stops": [{k: v for k, v in s.items() if not k.startswith("_")} for s in stops],
        "stopped_s": round(sum(s["duration_s"] for s in stops), 1),
        "point_count": len(points),
    }
