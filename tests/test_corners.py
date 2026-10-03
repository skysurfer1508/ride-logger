"""Corner warnings (app/corners.py): synthetic roads with known bends, plus a REAL route (Zurich to Winterthur, tests/data) that must stay quiet.
The thresholds were set by measuring live Valhalla routes: ordinary roads give none to a handful of corners, alpine passes one or two a kilometre."""
import json
import math
from pathlib import Path

import pytest

from app import corners, valhalla

LAT0, LON0 = 47.0, 8.0
KY = 111_194.9266
KX = KY * math.cos(math.radians(LAT0))
REAL = json.loads((Path(__file__).parent / "data" / "valhalla_trip_instructions.json").read_text())


def line(*parts):
    """A road from metres east/north of the origin: ("straight", metres) and ("arc", radius, degrees, +1 left / -1 right) in turn, as [(lat, lon)]."""
    x = y = 0.0
    heading = 0.0                                              # radians, 0 = east
    pts = [(x, y)]
    for part in parts:
        if part[0] == "straight":
            steps = max(1, int(part[1] // 5))
            for _ in range(steps):
                x += math.cos(heading) * part[1] / steps
                y += math.sin(heading) * part[1] / steps
                pts.append((x, y))
        else:
            _, radius, degrees, side = part
            steps = max(2, int(abs(degrees) / 3))
            for _ in range(steps):
                turn = math.radians(degrees) / steps * side
                heading += turn / 2
                x += math.cos(heading) * abs(turn) * radius
                y += math.sin(heading) * abs(turn) * radius
                heading += turn / 2
                pts.append((x, y))
    return [(LAT0 + py / KY, LON0 + px / KX) for px, py in pts]


def test_a_straight_road_and_a_gentle_sweeper_say_nothing():
    assert corners.find(line(("straight", 500), ("arc", 250, 60, 1), ("straight", 500))) == []


def test_a_hairpin_is_found_with_its_direction_place_and_a_slow_speed():
    found = corners.find(line(("straight", 300), ("arc", 15, 180, 1), ("straight", 300)))
    assert len(found) == 1
    c = found[0]
    assert c["kind"] == "hairpin" and c["dir"] == "left" and c["angle_deg"] == pytest.approx(180, abs=20)
    assert 250 <= c["along_m"] <= 310 and c["radius_m"] == pytest.approx(15, abs=6) and c["advisory_kmh"] == 25 and c["series"] is None


def test_a_right_hand_corner_is_a_right():
    found = corners.find(line(("straight", 300), ("arc", 40, 90, -1), ("straight", 300)))
    assert [(c["kind"], c["dir"]) for c in found] == [("sharp", "right")]


def test_a_medium_bend_is_not_worth_a_warning():
    assert corners.find(line(("straight", 300), ("arc", 90, 70, 1), ("straight", 300))) == []


def test_three_sharp_corners_close_together_are_a_series_said_once():
    road = line(("straight", 200), ("arc", 30, 100, 1), ("straight", 120), ("arc", 30, 100, -1), ("straight", 120), ("arc", 30, 100, 1), ("straight", 200))
    found = corners.find(road)
    assert [c["series"] for c in found] == ["start", "in", "in"] and [c["dir"] for c in found] == ["left", "right", "left"]


def test_two_far_apart_corners_are_no_series():
    road = line(("straight", 200), ("arc", 30, 100, 1), ("straight", 1500), ("arc", 30, 100, -1), ("straight", 200))
    assert [c["series"] for c in corners.find(road)] == [None, None]


def test_a_corner_at_a_maneuver_is_left_to_the_turn_by_turn_cue():
    road = line(("straight", 300), ("arc", 15, 90, 1), ("straight", 300))
    assert len(corners.find(road)) == 1
    assert corners.find(road, [{"along_m": 305}]) == []


def test_the_advisory_speed_is_rounded_and_never_below_15():
    assert corners.advisory_kmh(100) == 60 and corners.advisory_kmh(5) == 15 and corners.advisory_kmh(30) == 35


def test_a_real_commuter_route_stays_quiet():
    trip = valhalla.parse_trip(REAL["trip"])
    found = corners.find(trip["shape"], trip["maneuvers"])
    assert len(found) <= 3 and corners.per_km(found, trip["distance_m"]) < 0.2
