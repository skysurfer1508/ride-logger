import XCTest

/// The trip screen's decisions (Sources/Core/TripLogic.swift) and the encoded line (Sources/Core/Polyline6.swift).
final class TripLogicTests: XCTestCase {
    private func place(_ name: String, _ lat: Double, _ lon: Double, _ subtitle: String = "") -> Place { Place(name: name, subtitle: subtitle, lat: lat, lon: lon) }

    private func store() throws -> (PlaceStore, () -> Void) {
        let suite = "ridelog.test.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        return (PlaceStore(defaults: defaults), { defaults.removePersistentDomain(forName: suite) })
    }

    // MARK: styles

    func testTheFourStylesAreNamedAndExplained() {
        XCTAssertEqual(RouteMode.allCases.map(\.rawValue), ["ultra_fast", "fast", "relaxed", "twisty"])
        XCTAssertEqual(RouteMode.allCases.map(\.title), ["Ultra fast", "Fast", "Relaxed", "Twisty"])
        for mode in RouteMode.allCases {
            XCTAssertFalse(mode.blurb.isEmpty)
            XCTAssertFalse(mode.symbol.isEmpty)
        }
        XCTAssertEqual(RouteMode(rawValue: "twisty"), .twisty)
        XCTAssertNil(RouteMode(rawValue: "warp"))
    }

    func testDetoursReadLikeTime() {
        XCTAssertEqual(TripLogic.detourText(minutes: 30), "+30 min")
        XCTAssertEqual(TripLogic.detourText(minutes: 60), "+1 h")
        XCTAssertEqual(TripLogic.detourText(minutes: 75), "+1 h 15 min")
        XCTAssertEqual(TripLogic.detourRange, 5...120)
    }

    // MARK: asking the server

    func testTheTripFormIsWhatTheServerReads() throws {
        let form = TripLogic.tripForm(start: (47.3769, 8.5417), stops: [place("Pass", 46.9, 8.7)], finish: place("Chur", 46.85, 9.53), mode: .relaxed, detourMin: 30, pavedOnly: true,
                                      alternatives: true, heading: 271.6)
        XCTAssertEqual(form["mode"], "relaxed")
        XCTAssertEqual(form["paved_only"], "true")
        XCTAssertEqual(form["alternatives"], "0")                                           // stops in between: other ways are only offered start to finish
        XCTAssertEqual(form["heading"], "272")
        XCTAssertNil(form["detour_min"])
        let locations = try JSONSerialization.jsonObject(with: Data(try XCTUnwrap(form["locations"]).utf8)) as? [[String: Double]]
        XCTAssertEqual(locations?.count, 3)
        XCTAssertEqual(locations?[0]["lat"], 47.3769)
        XCTAssertEqual(locations?[1]["lon"], 8.7)
        XCTAssertEqual(locations?[2]["lat"], 46.85)
    }

    func testAlternativesAreAskedForOnlyWhenTheyMakeSense() {
        func alternatives(_ mode: RouteMode, stops: [Place] = [], want: Bool = true) -> String? {
            TripLogic.tripForm(start: (1, 1), stops: stops, finish: place("B", 2, 2), mode: mode, detourMin: 30, pavedOnly: true, alternatives: want)["alternatives"]
        }
        XCTAssertEqual(alternatives(.fast), "2")
        XCTAssertEqual(alternatives(.ultraFast), "2")
        XCTAssertEqual(alternatives(.fast, want: false), "0")
        XCTAssertEqual(alternatives(.twisty), "0")                                           // twisty makes its own alternatives
        XCTAssertEqual(alternatives(.fast, stops: [place("S", 1.5, 1.5)]), "0")
    }

    func testTheDetourIsOnlySentForTwistyAndStaysInRange() {
        func detour(_ minutes: Double, _ mode: RouteMode = .twisty) -> String? {
            TripLogic.tripForm(start: (1, 1), stops: [], finish: place("B", 2, 2), mode: mode, detourMin: minutes, pavedOnly: false, alternatives: false)["detour_min"]
        }
        XCTAssertEqual(detour(45), "45")
        XCTAssertEqual(detour(1), "5")
        XCTAssertEqual(detour(500), "120")
        XCTAssertNil(detour(45, .fast))
        XCTAssertEqual(TripLogic.tripForm(start: (1, 1), stops: [], finish: place("B", 2, 2), mode: .fast, detourMin: 30, pavedOnly: false, alternatives: false)["paved_only"], "false")
    }

    func testNoMoreThanFiveStopsAreSent() throws {
        let many = (0..<9).map { place("S\($0)", 47 + Double($0) * 0.1, 8) }
        let form = TripLogic.tripForm(start: (47, 8), stops: many, finish: place("B", 48, 8), mode: .fast, detourMin: 30, pavedOnly: true, alternatives: false)
        let locations = try JSONSerialization.jsonObject(with: Data(try XCTUnwrap(form["locations"]).utf8)) as? [[String: Double]]
        XCTAssertEqual(locations?.count, 2 + TripLogic.maxStops)
        XCTAssertFalse(TripLogic.canPlan(finish: place("B", 1, 1), stops: many))
        XCTAssertTrue(TripLogic.canPlan(finish: place("B", 1, 1), stops: Array(many.prefix(5))))
        XCTAssertFalse(TripLogic.canPlan(finish: nil, stops: []))
    }

    func testTheDirectionsFormKeepsTheTypesOfTheStops() throws {
        let form = TripLogic.directionsForm(waypoints: [RouteWaypoint(lat: 47, lon: 8), RouteWaypoint(lat: 47.1, lon: 8.1, type: "through"), RouteWaypoint(lat: 47, lon: 8)],
                                            mode: "loop", pavedOnly: true, heading: 90)
        XCTAssertEqual(form["mode"], "loop")
        XCTAssertEqual(form["heading"], "90")
        let parsed = try JSONSerialization.jsonObject(with: Data(try XCTUnwrap(form["locations"]).utf8)) as? [[String: Any]]
        XCTAssertEqual(parsed?.map { $0["type"] as? String }, ["break", "through", "break"])
        XCTAssertNil(TripLogic.directionsForm(waypoints: [], mode: "fast")["heading"])
    }

    // MARK: places

    func testAPlaceReadsAsOneLine() {
        XCTAssertEqual(place("Hardstrasse 10", 1, 1, "Zürich").line, "Hardstrasse 10, Zürich")
        XCTAssertEqual(place("Zürich HB", 1, 1, "").line, "Zürich HB")
        XCTAssertEqual(place("Hardstrasse 10, Zürich", 1, 1, "Zürich").line, "Hardstrasse 10, Zürich")
    }

    func testRecentPlacesAreNewestFirstWithoutRepeatsAndCapped() throws {
        let (store, cleanUp) = try store()
        defer { cleanUp() }
        XCTAssertTrue(store.recents.isEmpty)
        store.addRecent(place("A", 47.0, 8.0))
        store.addRecent(place("B", 47.1, 8.1))
        store.addRecent(place("A again, a few metres off", 47.0002, 8.0001))                 // the same spot
        XCTAssertEqual(store.recents.map(\.name), ["A again, a few metres off", "B"])
        for i in 0..<20 { store.addRecent(place("P\(i)", 46 + Double(i) * 0.05, 8)) }
        XCTAssertEqual(store.recents.count, PlaceStore.recentLimit)
        XCTAssertEqual(store.recents.first?.name, "P19")
        store.removeRecent(try XCTUnwrap(store.recents.first))
        XCTAssertEqual(store.recents.first?.name, "P18")
        store.clearRecents()
        XCTAssertTrue(store.recents.isEmpty)
    }

    func testHomeAndWorkAreKeptAndCleared() throws {
        let (store, cleanUp) = try store()
        defer { cleanUp() }
        store.save(place("Home", 47.4, 8.5), as: "home")
        store.save(place("Office", 47.38, 8.54), as: "work")
        XCTAssertEqual(store.saved["home"]?.name, "Home")
        XCTAssertEqual(store.saved["work"]?.name, "Office")
        store.save(nil, as: "home")
        XCTAssertNil(store.saved["home"])
        XCTAssertEqual(store.saved["work"]?.name, "Office")
    }

    func testTheSuggestionsListPutsHomeAndWorkFirstAndNeverRepeats() {
        let home = place("Home", 47.4, 8.5), work = place("Office", 47.38, 8.54), cafe = place("Cafe", 47.3, 8.4)
        let list = TripLogic.suggestions(saved: ["home": home, "work": work], recents: [cafe, home, work])
        XCTAssertEqual(list.map(\.place.name), ["Home", "Office", "Cafe"])
        XCTAssertEqual(list.map(\.label), ["Home", "Work", nil])
        XCTAssertEqual(TripLogic.suggestions(saved: [:], recents: []).count, 0)
        XCTAssertEqual(TripLogic.suggestions(saved: [:], recents: [cafe]).map(\.label), [nil])
    }

    // MARK: the encoded line

    func testAKnownEncodedLineDecodes() {
        let points = Polyline6.decode("g_tjyAg_jhO_gEgrOfmEvbS~xy}yCodzboG")
        XCTAssertEqual(points.count, 4)
        XCTAssertEqual(points[0], RoadPoint(lat: 47.3769, lon: 8.5417))
        XCTAssertEqual(points[1], RoadPoint(lat: 47.3801, lon: 8.5502))
        XCTAssertEqual(points[2], RoadPoint(lat: 47.3768, lon: 8.5399))
        XCTAssertEqual(points[3], RoadPoint(lat: -33.8688, lon: 151.2093))                  // negative latitude, three-digit longitude
    }

    func testADamagedLineGivesWhatCameBeforeTheDamage() {
        XCTAssertTrue(Polyline6.decode("").isEmpty)
        XCTAssertEqual(Polyline6.decode("g_tjyAg_jhO_gEgrOfmEvbS~xy}yCodz").count, 3)        // cut off in the middle of the fourth point
        XCTAssertEqual(Polyline6.decode("g_tjyAg_jhO_gE").count, 1)                          // a latitude without its longitude is not a point
        XCTAssertNoThrow(Polyline6.decode("\u{1}\u{2}\u{3}"))
    }

    func testTheGoldenRoutesFullLineMatchesItsTurns() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "api_planner_trip", withExtension: "json"))
        let trip = try JSONDecoder.ridelog.decode(PlanResponse.self, from: Data(contentsOf: url))
        let route = try XCTUnwrap(trip.routes.first)
        let line = Polyline6.decode(try XCTUnwrap(route.shape6))
        XCTAssertGreaterThan(line.count, 1000)
        let maneuvers = try XCTUnwrap(route.maneuvers)
        XCTAssertEqual(line.first!.lat, maneuvers.first!.lat, accuracy: 0.0001)
        XCTAssertEqual(line.last!.lat, maneuvers.last!.lat, accuracy: 0.0001)
        XCTAssertEqual(line.last!.lon, maneuvers.last!.lon, accuracy: 0.0001)
        let follow = try XCTUnwrap(RouteFollow.line(line.map { [$0.lat, $0.lon] }))
        XCTAssertEqual(follow.total, maneuvers.last!.alongM, accuracy: 120)                  // the line's length agrees with the server's distance to the arrival
        XCTAssertGreaterThan(route.shape.count, 100)
        XCTAssertLessThan(route.shape.count, line.count)                                     // the display line is the thinned one
    }
}
