"""What a ride's own numbers say beyond distance and speed: elevation profile and braking/acceleration. Pure functions over prepared track points
(app/track.py: t seconds, dist metres, mps, altitude). Weather and speed limits need outside services and live in weather.py / valhalla.py + limits.py.
"""
from typing import Optional, Sequence

MAX_PROFILE_POINTS = 300
# GPS altitude is only good to about 5-10 m at 1 Hz, so neighbours are averaged before anything is worked out, and a change smaller than the hysteresis since
# the last turning point is noise, not climbing. Chosen by measuring (20 random seeds, +-4 m white noise): flat ground reads 0.3 m of climb on average (worst 3 m),
# a real 200 m climb reads 195 m. A window of 7 with 1.5 m invented 17 m on flat ground.
SMOOTH_WINDOW = 11
CLIMB_HYSTERESIS_M = 3.0

HARD_BRAKE_MPS2 = -3.5             # about 0.36 g
HARD_ACCEL_MPS2 = 3.0              # about 0.31 g
MAX_GAP_S = 5.0                    # acceleration across a longer gap between fixes is not measured
MIN_SMOOTHNESS_KM = 1.0
MIN_SMOOTHNESS_POINTS = 30
EVENT_PENALTY = 8.0                # score = 100 - this per event per 10 km


def _smooth(values: list[float], window: int) -> list[float]:
    half = window // 2
    return [sum(values[max(0, i - half): i + half + 1]) / len(values[max(0, i - half): i + half + 1]) for i in range(len(values))]


def elevation_profile(points: Sequence[dict]) -> Optional[dict]:
    """Altitude along the ride, smoothed, with ascent and descent. None when there is too little altitude data to say anything."""
    usable = [p for p in points if p.get("altitude") is not None]
    if len(usable) < 20:
        return None
    alt = _smooth([float(p["altitude"]) for p in usable], SMOOTH_WINDOW)
    ascent = descent = 0.0
    anchor = alt[0]
    for value in alt[1:]:
        if value - anchor >= CLIMB_HYSTERESIS_M:
            ascent += value - anchor
            anchor = value
        elif anchor - value >= CLIMB_HYSTERESIS_M:
            descent += anchor - value
            anchor = value
    stride = max(1, len(usable) // MAX_PROFILE_POINTS)
    keep = sorted(set(range(0, len(usable), stride)) | {len(usable) - 1})
    return {
        "points": [[round(usable[i]["dist"]), round(alt[i], 1)] for i in keep],
        "ascent_m": round(ascent),
        "descent_m": round(descent),
        "min_m": round(min(alt)),
        "max_m": round(max(alt)),
    }


def smoothness(points: Sequence[dict]) -> Optional[dict]:
    """Hard braking and hard acceleration from the speed series, and a score. 1 Hz GPS under-reads short peaks, so the real numbers are higher: this is a
    way to compare your own rides, not a measurement of g. None for rides too short to judge."""
    n = len(points)
    if n < MIN_SMOOTHNESS_POINTS or points[-1]["dist"] < MIN_SMOOTHNESS_KM * 1000:
        return None
    events: list[dict] = []
    open_event: Optional[dict] = None
    for i in range(1, n - 1):
        a, b = points[i - 1], points[i + 1]
        dt = b["t"] - a["t"]
        if dt <= 0 or dt > 2 * MAX_GAP_S:
            open_event = _finish(open_event, events)
            continue
        accel = (b["mps"] - a["mps"]) / dt
        kind = "braking" if accel <= HARD_BRAKE_MPS2 else "acceleration" if accel >= HARD_ACCEL_MPS2 else None
        if kind is None:
            open_event = _finish(open_event, events)
        elif open_event is not None and open_event["kind"] == kind:
            open_event["t_end"] = round(points[i]["t"], 1)
            open_event["peak_mps2"] = round(max(abs(open_event["peak_mps2"]), abs(accel)) * (1 if kind == "acceleration" else -1), 1)
            open_event["to_kmh"] = round(points[i]["mps"] * 3.6)
        else:
            open_event = _finish(open_event, events)
            open_event = {"kind": kind, "t_start": round(points[i]["t"], 1), "t_end": round(points[i]["t"], 1), "peak_mps2": round(accel, 1),
                          "from_kmh": round(a["mps"] * 3.6), "to_kmh": round(points[i]["mps"] * 3.6),
                          "lat": points[i]["lat"], "lon": points[i]["lon"], "dist_m": round(points[i]["dist"])}
    _finish(open_event, events)
    km = points[-1]["dist"] / 1000.0
    braking = sum(1 for e in events if e["kind"] == "braking")
    per_10km = len(events) / km * 10
    return {"events": events, "hard_braking": braking, "hard_acceleration": len(events) - braking,
            "events_per_10km": round(per_10km, 1), "score": max(0, round(100 - EVENT_PENALTY * per_10km))}


def _finish(event: Optional[dict], events: list[dict]) -> None:
    if event is not None:
        events.append(event)
    return None
