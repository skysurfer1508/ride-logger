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


def make_path_rows(segments, speed, pos_sigma=0.0, course_sigma=None, seed=1, start=START) -> list[dict]:
    """A ride that turns, for the lean and G-force tests. Starts heading north at a steady `speed` (m/s), one fix per second or so:

        ("straight", metres)               ("turn", radius metres, degrees)    degrees > 0 turns right (clockwise), < 0 turns left

    `pos_sigma` adds Gaussian GPS error in metres; `course_sigma` (degrees) adds the phone's heading in each row's "course" (None: no course, as in old rides).
    """
    import math
    rnd = random.Random(seed)
    x = y = heading = 0.0
    t = 0.0
    rows: list[dict] = []

    def emit():
        row = {
            "id": len(rows) + 1,
            "lat": LAT0 + (y + rnd.gauss(0, pos_sigma)) / M_PER_DEG_LAT,
            "lon": LON0 + (x + rnd.gauss(0, pos_sigma)) / (M_PER_DEG_LAT * math.cos(math.radians(LAT0))),
            "timestamp": (start + timedelta(seconds=t)).isoformat(),
            "speed": float(speed),
            "altitude": 410.0 + len(rows) * 0.01,
            "horizontal_accuracy": 6.0,
        }
        if course_sigma is not None:
            row["course"] = (math.degrees(heading) + rnd.gauss(0, course_sigma)) % 360
            row["course_accuracy"] = max(1.0, course_sigma)
        rows.append(row)

    emit()
    for seg in segments:
        if seg[0] == "straight":
            length, turn_rate = float(seg[1]), 0.0
        elif seg[0] == "turn":
            length = abs(math.radians(seg[2])) * seg[1]
            turn_rate = math.radians(seg[2]) / length
        else:
            raise ValueError(seg)
        steps = max(1, round(length / speed))
        ds = length / steps
        for _ in range(steps):
            heading += turn_rate * ds / 2
            x += ds * math.sin(heading)
            y += ds * math.cos(heading)
            heading += turn_rate * ds / 2
            t += ds / speed
            emit()
    return rows
