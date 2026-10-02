"""Synthetic GPS tracks for the stop-detection and /track tests. A track is a list of segments driven north from a start point:

    ("drive", seconds, metres_per_second)             one fix every `step` seconds
    ("stop", seconds, "zero")                         fixes keep coming, speed 0, a few metres of GPS jitter (Overland, or creeping)
    ("stop", seconds, "gap")                          NO fixes for that long (the iOS recorder's 5 m distance filter while standing)
    ("creep", seconds, metres_per_second)             same as drive, named for readability
"""
import random
from datetime import datetime, timedelta, timezone

M_PER_DEG_LAT = 111_194.9266
START = datetime(2026, 9, 30, 8, 0, 0, tzinfo=timezone.utc)
LAT0, LON0 = 47.3769, 8.5417


def make_rows(segments, step=2.0, jitter_m=0.0, accuracy=6.0, seed=1, unknown_speed=False, start=START) -> list[dict]:
    rnd = random.Random(seed)
    rows: list[dict] = []
    t = 0.0
    north_m = 0.0

    def add(speed):
        jitter_lat = rnd.uniform(-jitter_m, jitter_m) / M_PER_DEG_LAT if jitter_m else 0.0
        rows.append({
            "id": len(rows) + 1,
            "lat": LAT0 + north_m / M_PER_DEG_LAT + jitter_lat,
            "lon": LON0,
            "timestamp": (start + timedelta(seconds=t)).isoformat(),
            "speed": -1.0 if unknown_speed else speed,
            "altitude": 410.0 + len(rows) * 0.01,
            "horizontal_accuracy": accuracy,
        })

    add(0.0)                                   # the first fix
    for kind, seconds, how in segments:
        if kind in ("drive", "creep"):
            for _ in range(int(seconds / step)):
                t += step
                north_m += how * step
                add(how)
        elif kind == "stop" and how == "zero":
            for _ in range(int(seconds / step)):
                t += step
                add(0.0)
        elif kind == "stop" and how == "gap":
            t += seconds
            add(0.3)                           # the first fix after the wait, just starting to move again
        else:
            raise ValueError((kind, how))
    return rows
