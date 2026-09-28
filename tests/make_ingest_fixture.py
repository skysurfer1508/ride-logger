"""Regenerates ios/Tests/Fixtures/ingest_batch.json: the contract between the iOS recorder and POST /api/ingest.

The file holds the raw `samples` and `trip` details the app knows, plus the `body` the app must upload for them. The server tests
(tests/test_ingest_app_batch.py) ingest `body`; the Swift tests (ios/Tests/IngestPayloadTests.swift) rebuild `body` from `samples`
and `trip` and compare. If either side changes the wire format, one of the two fails.

    python tests/make_ingest_fixture.py
"""
import json
import math
from datetime import datetime, timedelta, timezone
from pathlib import Path

OUT = Path(__file__).resolve().parent.parent / "ios" / "Tests" / "Fixtures" / "ingest_batch.json"

DEVICE_ID = "ridelog-ios-TEST0001"
START = datetime(2026, 9, 28, 9, 15, 0, tzinfo=timezone.utc)
TRIP_ID = "2026-09-28T09:15:00Z#a1b2c3d4"
STEP_S = 5
COUNT = 40


def iso(dt: datetime) -> str:
    return dt.strftime("%Y-%m-%dT%H:%M:%SZ")


def haversine_m(lat1, lon1, lat2, lon2) -> float:
    p1, p2 = math.radians(lat1), math.radians(lat2)
    a = math.sin((p2 - p1) / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(math.radians(lon2 - lon1) / 2) ** 2
    return 2 * 6371000.0 * math.asin(min(1.0, math.sqrt(a)))


def samples() -> list[dict]:
    out = []
    for i in range(COUNT):
        out.append({
            "timestamp": iso(START + timedelta(seconds=STEP_S * i)),
            "lat": round(47.3769 + i * 0.0009, 6),
            "lon": round(8.5417 + i * 0.0006, 6),
            "speed": round(18 + (i % 5) * 1.5, 1),
            "altitude": round(410.0 + 3 * (i // 2), 1),
            "horizontal_accuracy": round(5.0 + (i % 4), 1),
            "vertical_accuracy": 8.0,
            "battery_level": round(0.82 - i * 0.001, 3),
        })
    return out


def feature(sample: dict) -> dict:
    return {
        "type": "Feature",
        "geometry": {"type": "Point", "coordinates": [sample["lon"], sample["lat"]]},
        "properties": {
            "timestamp": sample["timestamp"],
            "altitude": sample["altitude"],
            "speed": sample["speed"],
            "horizontal_accuracy": sample["horizontal_accuracy"],
            "vertical_accuracy": sample["vertical_accuracy"],
            "battery_level": sample["battery_level"],
            "device_id": DEVICE_ID,
            "trip_id": TRIP_ID,
        },
    }


def marker(trip: dict, last: dict) -> dict:
    return {
        "type": "Feature",
        "geometry": {"type": "Point", "coordinates": [last["lon"], last["lat"]]},
        "properties": {
            "type": "trip",
            "timestamp": trip["end"],
            "mode": "motorcycle",
            "start": TRIP_ID,
            "end": trip["end"],
            "duration": trip["duration_s"],
            "distance": trip["distance_m"],
            "stopped_automatically": False,
            "device_id": DEVICE_ID,
        },
    }


def main() -> None:
    s = samples()
    distance = round(sum(haversine_m(a["lat"], a["lon"], b["lat"], b["lon"]) for a, b in zip(s, s[1:])), 1)
    trip = {"start": s[0]["timestamp"], "end": s[-1]["timestamp"], "duration_s": STEP_S * (COUNT - 1), "distance_m": distance}
    body = {"locations": [feature(x) for x in s] + [marker(trip, s[-1])]}
    doc = {"device_id": DEVICE_ID, "trip_id": TRIP_ID, "trip": trip, "samples": s, "body": body}
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(doc, indent=1) + "\n")
    print(f"wrote {OUT} ({COUNT} samples, {distance} m)")


if __name__ == "__main__":
    main()
