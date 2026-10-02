"""How twisty a road is (app/curvature.py). The expectations are geometry; the spacing test is the reason the settings are what they are."""
import math

import pytest

from app import curvature, geo
from trackgen import road_coords

S_BENDS = [("turn", 75, 60 if i % 2 else -60) for i in range(21)]                     # 21 alternating 60 degree bends of radius 75 m: 1.6 km of twisty road
SWEEPERS = [("turn", 300, 25 if i % 2 else -25) for i in range(14)]                    # long gentle bends, radius 300 m


def total_length(coords):
    return sum(geo.haversine_m(a[0], a[1], b[0], b[1]) for a, b in zip(coords, coords[1:]))


@pytest.mark.parametrize("radius,expected", [(1000, 0.0), (400, 0.0), (399, 0.25), (200, 0.25), (150, 0.6), (100, 0.6), (60, 1.0), (50, 1.0), (30, 1.4), (25, 1.4), (24, 1.0), (5, 1.0)])
def test_each_radius_band_counts_for_its_share(radius, expected):
    assert curvature.weight(radius) == expected


def test_the_radius_of_three_points():
    r = 100.0
    on_circle = [(r * math.sin(a), r * (1 - math.cos(a))) for a in (0.0, 0.1, 0.2)]
    assert curvature.radius_m(*on_circle) == pytest.approx(r, rel=1e-6)
    assert curvature.radius_m((0, 0), (10, 0), (20, 0)) == math.inf
    assert curvature.radius_m((0, 0), (0, 0), (0, 0)) == math.inf


def test_resampling_keeps_the_length_and_both_ends_and_spaces_the_points():
    coords = road_coords([("straight", 500), ("turn", 60, 90), ("straight", 400)], spacing=7.0)
    out = curvature.resample(coords)
    assert out[0] == coords[0] and out[-1] == coords[-1]
    assert total_length(out) == pytest.approx(total_length(coords), rel=0.01)
    gaps = [geo.haversine_m(a[0], a[1], b[0], b[1]) for a, b in zip(out, out[1:])]
    assert all(g == pytest.approx(curvature.STEP_M, rel=0.1) for g in gaps[:-1]) and curvature.STEP_M * 0.4 <= gaps[-1] <= curvature.STEP_M * 1.6
    assert curvature.resample([(47.0, 8.0)]) == [(47.0, 8.0)] and curvature.resample([]) == []


def test_a_straight_road_scores_zero_and_a_chain_of_tight_bends_scores_high():
    straight = curvature.segments(road_coords([("straight", 3000)], spacing=25))
    assert straight and all(s["score"] == 0 for s in straight)
    twisty = curvature.segments(road_coords(S_BENDS, spacing=12))
    assert len(twisty) == 1 and twisty[0]["score"] >= 70                  # the changeovers between bends count for less, so not 100


def test_gentle_bends_score_low_and_in_between_roads_in_between():
    gentle = curvature.segments(road_coords(SWEEPERS, spacing=15))
    assert gentle and all(s["score"] <= 35 for s in gentle)
    mixed = curvature.segments(road_coords([("straight", 200), ("turn", 70, 90), ("straight", 200), ("turn", 70, -90), ("straight", 200), ("turn", 70, 90), ("straight", 200)], spacing=12))
    assert len(mixed) == 1 and 25 <= mixed[0]["score"] <= 80


@pytest.mark.parametrize("radius,spacings,tolerance", [(40, (5, 10, 15), 0.10), (75, (5, 10, 15, 25), 0.08), (150, (5, 10, 15, 25, 40), 0.08)])
def test_the_score_does_not_depend_on_how_finely_the_bend_was_digitised(radius, spacings, tolerance):
    """Mappers put a vertex every 5 to 25 m on a bend (more on tighter ones). The score of the same road must not move by more than a few points across that range.
    A tight bend with a vertex every 40 m is not a curve any more but a polygon (one or two vertices per bend), and no method can read it."""
    parts = [("straight", 300)] + [("turn", radius, 70 if i % 2 else -70) for i in range(14)] + [("straight", 300)]
    scores = [sum(s["curvy_m"] for s in curvature.segments(road_coords(parts, spacing=sp))) / sum(s["length_m"] for s in curvature.segments(road_coords(parts, spacing=sp)))
              for sp in spacings]
    assert max(scores) - min(scores) < tolerance             # measured spreads: 0.097, 0.026, 0.01


def test_a_long_road_is_cut_into_stretches_that_cover_it_once():
    coords = road_coords([("straight", 6000)], spacing=40)
    parts = curvature.segments(coords)
    assert len(parts) == 4 and all(1300 <= p["length_m"] <= 1700 for p in parts)
    assert sum(p["length_m"] for p in parts) == pytest.approx(total_length(coords), rel=0.02)
    assert parts[0]["geometry"][0] == [round(coords[0][0], 5), round(coords[0][1], 5)]


def test_one_twisty_kilometre_in_a_long_road_is_not_averaged_away():
    coords = road_coords([("straight", 3000)] + [("turn", 60, 70 if i % 2 else -70) for i in range(14)] + [("straight", 3000)], spacing=15)
    scores = [p["score"] for p in curvature.segments(coords)]
    assert max(scores) >= 60 and min(scores) == 0


def test_tiny_ways_are_ignored():
    assert curvature.segments(road_coords([("straight", 200)], spacing=10)) == []
    assert curvature.segments([(47.0, 8.0), (47.0001, 8.0)]) == []
    assert curvature.segments([(47.0, 8.0)]) == [] and curvature.segments([]) == []


@pytest.mark.parametrize("tags,ok", [
    ({"highway": "secondary"}, True), ({"highway": "tertiary", "surface": "asphalt"}, True), ({"highway": "unclassified"}, True), ({"highway": "primary"}, True),
    ({"highway": "motorway"}, False), ({"highway": "residential"}, False), ({"highway": "track"}, False), ({"highway": "service"}, False),
    ({"highway": "secondary_link"}, False), ({"highway": "secondary", "tunnel": "yes"}, False), ({"highway": "secondary", "area": "yes"}, False),
    ({"highway": "tertiary", "access": "private"}, False), ({"highway": "tertiary", "motor_vehicle": "no"}, False), ({"highway": "tertiary", "vehicle": "forestry"}, False),
    ({"highway": "tertiary", "motorcycle": "no"}, False), ({"highway": "tertiary", "access": "no", "motorcycle": "yes"}, True),
    ({"highway": "tertiary", "access": "destination"}, True), ({"highway": "tertiary", "construction": "yes"}, False), ({}, False),
])
def test_which_ways_are_roads_to_ride(tags, ok):
    assert curvature.wanted(tags) is ok


def test_surface_and_speed_limit_parsing():
    assert curvature.paved({"surface": "asphalt"}) and curvature.paved({}) and curvature.paved({"surface": "paving_stones"})
    assert not curvature.paved({"surface": "gravel"}) and not curvature.paved({"surface": "Dirt"}) and not curvature.paved({"tracktype": "grade4"})
    assert curvature.maxspeed_kmh({"maxspeed": "80"}) == 80 and curvature.maxspeed_kmh({"maxspeed": "50 km/h"}) == 50
    assert curvature.maxspeed_kmh({"maxspeed": "30 mph"}) is None and curvature.maxspeed_kmh({"maxspeed": "CH:urban"}) is None and curvature.maxspeed_kmh({}) is None
