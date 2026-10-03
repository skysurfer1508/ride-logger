import XCTest

/// What the guidance says besides the turns: corner warnings, speed limits, weather and light, the wrist taps, wrong turns and the way back onto a route
/// (Sources/Core/GuidanceEngine.swift). Ridden on the REAL route (api_planner_trip.json); the extras are placed on its longest stretch between two turns, where nothing else is said.
final class GuidanceExtrasTests: XCTestCase {
    private let metresPerDegree = 111_194.9266

    private func baseRoute() throws -> GuidanceRoute {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "api_planner_trip", withExtension: "json"), "missing fixture api_planner_trip.json")
        let answer = try JSONDecoder.ridelog.decode(PlanResponse.self, from: Data(contentsOf: url))
        return try XCTUnwrap(GuidanceRoute(route: try XCTUnwrap(answer.routes.first), name: "Test"))
    }

    /// The longest stretch between two maneuvers: (where it starts, how long it is).
    private func longestGap(_ route: GuidanceRoute) -> (start: Double, length: Double) {
        var best = (start: 0.0, length: 0.0)
        for (a, b) in zip(route.maneuvers, route.maneuvers.dropFirst()) where b.alongM - a.alongM > best.length { best = (a.alongM, b.alongM - a.alongM) }
        return best
    }

    private func with(corners: [RouteCorner], on base: GuidanceRoute) -> GuidanceRoute {
        GuidanceRoute(line: base.line, maneuvers: base.maneuvers, waypoints: base.waypoints, mode: base.mode, name: base.name, corners: corners, encodedLine: base.encodedLine)
    }

    private func corner(_ along: Double, kind: String = "hairpin", dir: String = "left", advisory: Int = 25, series: String? = nil) -> RouteCorner {
        RouteCorner(alongM: along, lat: 0, lon: 0, dir: dir, kind: kind, radiusM: 12, angleDeg: 180, lengthM: 40, advisoryKmh: advisory, series: series)
    }

    struct Ride {
        var said: [String] = []
        var cues: [TurnCue] = []
        var reroutes: [Int] = []
        var finalStatus = GuidanceStatus()
        var arrived = false
    }

    private func ride(_ route: GuidanceRoute, speed: Double = 14, options: GuidanceOptions = GuidanceOptions(), limits: [LimitChange] = [], alerts: [RouteAlert] = [],
                      summary: String? = nil) -> Ride {
        var engine = GuidanceEngine(route: route, options: options)
        engine.attach(limits: limits, alerts: alerts, summary: summary)
        var sim = DriveSimulator(line: route.line)
        var result = Ride()
        var t = 0
        while !sim.isFinished && !engine.arrived && t < 40_000 {
            let position = sim.step(seconds: 1, speedMps: speed)
            for output in engine.update(lat: position.lat, lon: position.lon, speedMps: speed, now: Double(t)) {
                switch output {
                case .say(let phrase): result.said.append(phrase.text)
                case .cue(let cue): result.cues.append(cue)
                case .needReroute: result.reroutes.append(t)
                case .arrived: result.arrived = true
                }
            }
            t += 1
        }
        result.finalStatus = engine.status
        return result
    }

    // MARK: corners

    func testAHairpinIsWarnedOnceWithTheSpeedToSlowTo() throws {
        let base = try baseRoute()
        let gap = longestGap(base)
        let r = ride(with(corners: [corner(gap.start + 3000)], on: base))
        XCTAssertEqual(r.said.filter { $0.hasPrefix("Hairpin") }, ["Hairpin left, slow to 25."])
        XCTAssertTrue(r.cues.contains(.curve))
    }

    func testARiderAlreadyGoingSlowlyIsNotToldToSlowDown() throws {
        let base = try baseRoute()
        let r = ride(with(corners: [corner(gap(base).start + 3000, dir: "right")], on: base), speed: 6)
        XCTAssertEqual(r.said.filter { $0.hasPrefix("Hairpin") }, ["Hairpin right."])
    }

    private func gap(_ route: GuidanceRoute) -> (start: Double, length: Double) { longestGap(route) }

    func testCornerWarningsCanBeSwitchedOff() throws {
        let base = try baseRoute()
        var options = GuidanceOptions()
        options.curveWarnings = false
        let r = ride(with(corners: [corner(gap(base).start + 3000)], on: base), options: options)
        XCTAssertTrue(r.said.filter { $0.hasPrefix("Hairpin") || $0.hasPrefix("Sharp") }.isEmpty)
        XCTAssertFalse(r.cues.contains(.curve))
    }

    func testAStackOfCornersIsOneCurvesAheadAndThenSilenceForARiderWhoIsKeepingUp() throws {
        let base = try baseRoute()
        let start = gap(base).start
        let corners = [corner(start + 2000, kind: "sharp", advisory: 45, series: "start"), corner(start + 2200, kind: "sharp", advisory: 45, series: "in"),
                       corner(start + 2400, kind: "sharp", dir: "right", advisory: 45, series: "in")]
        let r = ride(with(corners: corners, on: base))
        XCTAssertEqual(r.said.filter { $0 == "Curves ahead." }.count, 1)
        XCTAssertTrue(r.said.filter { $0.hasPrefix("Sharp") && $0.contains("45") }.isEmpty)
    }

    func testACornerInsideAStackIsStillCalledWhenTheRiderIsFarTooFast() throws {
        let base = try baseRoute()
        let start = gap(base).start
        let corners = [corner(start + 2000, kind: "sharp", advisory: 30, series: "start"), corner(start + 2300, kind: "sharp", advisory: 30, series: "in")]
        let r = ride(with(corners: corners, on: base))
        XCTAssertTrue(r.said.contains("Sharp left, slow to 30."), "\(r.said)")
    }

    // MARK: speed limits

    func testTheLimitIsSaidWhenItChangesAndTheScreenKnowsIt() throws {
        let base = try baseRoute()
        let start = gap(base).start
        let limits = [LimitChange(alongM: 0, kmh: 50), LimitChange(alongM: start + 2000, kmh: 80), LimitChange(alongM: start + 4000, kmh: nil), LimitChange(alongM: start + 5000, kmh: 60)]
        let r = ride(base, limits: limits)
        XCTAssertEqual(r.said.filter { $0 == "Limit 80." }.count, 1)
        XCTAssertEqual(r.said.filter { $0 == "Limit 60." }.count, 1)
        XCTAssertEqual(r.finalStatus.limitKmh, 60)
    }

    func testTheLimitCanBeLimitedToWhenTheRiderIsOverIt() throws {
        let base = try baseRoute()
        let start = gap(base).start
        var options = GuidanceOptions()
        options.limitCallouts = .whenOver
        let r = ride(base, options: options, limits: [LimitChange(alongM: 0, kmh: nil), LimitChange(alongM: start + 1000, kmh: 80), LimitChange(alongM: start + 3000, kmh: 40)])
        XCTAssertEqual(r.said.filter { $0.hasPrefix("Limit") }, ["Limit 40."])                 // 50 km/h: under 80, over 40
    }

    func testTheLimitCanBeSwitchedOff() throws {
        let base = try baseRoute()
        var options = GuidanceOptions()
        options.limitCallouts = .off
        let r = ride(base, options: options, limits: [LimitChange(alongM: gap(base).start + 1000, kmh: 80)])
        XCTAssertTrue(r.said.filter { $0.hasPrefix("Limit") }.isEmpty)
        XCTAssertEqual(r.finalStatus.limitKmh, 80)                                               // the sign still shows it
    }

    // MARK: weather and light

    func testRainAheadIsToldOnceWithHowFarAway() throws {
        let base = try baseRoute()
        let gap = longestGap(base)
        let r = ride(base, alerts: [RouteAlert(alongM: gap.start + gap.length * 0.7, kind: "rain", label: "rain likely")])
        let said = r.said.filter { $0.hasSuffix(", rain likely.") }
        XCTAssertEqual(said.count, 1)
        XCTAssertTrue(said[0].hasPrefix("In "), said[0])
    }

    func testTheSummaryIsSaidOnceAfterTheStartAndNamesTheFirstAlertSoItIsNotSaidAgain() throws {
        let base = try baseRoute()
        let r = ride(base, alerts: [RouteAlert(alongM: 3000, kind: "rain", label: "rain likely")], summary: "Rain likely after 3 kilometers. Sunset is at 19:06.")
        let start = try XCTUnwrap(r.said.firstIndex { $0.hasPrefix("Starting navigation") })
        let summary = try XCTUnwrap(r.said.firstIndex(of: "Rain likely after 3 kilometers. Sunset is at 19:06."))
        XCTAssertGreaterThan(summary, start)
        XCTAssertEqual(r.said.filter { $0 == "Rain likely after 3 kilometers. Sunset is at 19:06." }.count, 1)
        XCTAssertTrue(r.said.filter { $0.hasSuffix(", rain likely.") }.isEmpty)
    }

    // MARK: wrist taps

    func testTheTurnsOfTheRealRouteTapBothWrists() throws {
        let r = ride(try baseRoute())
        XCTAssertTrue(r.cues.contains(.left))
        XCTAssertTrue(r.cues.contains(.right))
    }

    // MARK: a wrong turn

    private struct Detour {
        let lat: Double, lon: Double, bearing: Double
    }

    /// A rider `metres` beside the route at 2 km, to be sent off at right angles to it: the start of a wrong turn.
    private func detour(_ route: GuidanceRoute, metres: Double = 40) -> Detour {
        let here = DriveSimulator(line: route.line).position(at: 2000)
        let segment = RouteFollow.progress(lat: here.lat, lon: here.lon, on: route.line).segment
        let bearing = RouteFollow.bearing(on: route.line, segment: segment)
        let radians = (bearing + 90) * .pi / 180
        return Detour(lat: here.lat + cos(radians) * metres / metresPerDegree, lon: here.lon + sin(radians) * metres / (metresPerDegree * cos(here.lat * .pi / 180)), bearing: bearing)
    }

    private func reroutes(_ route: GuidanceRoute, speed: Double, course: Double?, watching: Bool = true, seconds: Int = 6) -> [Int] {
        let d = detour(route)
        var engine = GuidanceEngine(route: route, announceStart: false)
        engine.watchesOffRoute = watching
        var out: [Int] = []
        for t in 0..<seconds {
            let outputs = engine.update(lat: d.lat, lon: d.lon, speedMps: speed, now: Double(t), course: course)
            if outputs.contains(.needReroute) { out.append(t) }
        }
        return out
    }

    func testAWrongTurnIsNoticedInTwoSecondsWhenTheHeadingIsKnown() throws {
        let route = try baseRoute()
        let d = detour(route)
        let heading = (d.bearing + 90).truncatingRemainder(dividingBy: 360)
        XCTAssertEqual(reroutes(route, speed: 10, course: heading).first, 2)
    }

    func testWithoutAHeadingOnlyBeingFarFromTheRouteCounts() throws {
        XCTAssertTrue(reroutes(try baseRoute(), speed: 10, course: nil).isEmpty)               // 40 m is not yet 100 m
    }

    func testRidingAlongTheRouteBesideItIsNotAWrongTurn() throws {
        let route = try baseRoute()
        XCTAssertTrue(reroutes(route, speed: 10, course: detour(route).bearing).isEmpty)
    }

    func testCrawlingOrExploringIsNotAWrongTurn() throws {
        let route = try baseRoute()
        let heading = (detour(route).bearing + 90).truncatingRemainder(dividingBy: 360)
        XCTAssertTrue(reroutes(route, speed: 2, course: heading).isEmpty)
        XCTAssertTrue(reroutes(route, speed: 10, course: heading, watching: false).isEmpty)
    }

    func testBeingFarOffTheRouteSaysWhatSettingsSaid() throws {
        let route = try baseRoute()
        var options = GuidanceOptions()
        options.offRouteLine = GuidanceLines.offRouteBack
        var engine = GuidanceEngine(route: route, announceStart: false, options: options)
        let far = detour(route, metres: 300)
        var said: [String] = []
        for t in 0..<8 {
            for case .say(let phrase) in engine.update(lat: far.lat, lon: far.lon, speedMps: 14, now: Double(t)) { said.append(phrase.text) }
        }
        XCTAssertEqual(said, ["Off route. Heading back to your route."])
    }

    func testTheBearingAndTheAngleBetweenHeadings() {
        let line = RouteFollow.line([[47.0, 8.0], [47.1, 8.0], [47.1, 8.1]])!
        XCTAssertEqual(RouteFollow.bearing(on: line, segment: 0), 0, accuracy: 0.01)
        XCTAssertEqual(RouteFollow.bearing(on: line, segment: 1), 90, accuracy: 0.01)
        XCTAssertEqual(RouteFollow.angleBetween(350, 10), 20, accuracy: 1e-9)
        XCTAssertEqual(RouteFollow.angleBetween(90, 270), 180, accuracy: 1e-9)
        XCTAssertEqual(RouteFollow.angleBetween(45, 45), 0, accuracy: 1e-9)
    }

    // MARK: the way back onto the route

    func testTheWayBackJoinsTheRouteAKilometreAheadAndEndsAtTheSameDestination() throws {
        let route = try baseRoute()
        let line = route.line
        let back = RouteWaypoints.rejoin(waypoints: route.waypoints, alongM: 5000, on: line, current: (47.4, 8.6))
        XCTAssertEqual(back.first?.lat, 47.4)
        XCTAssertEqual(back.first?.type, "break")
        XCTAssertEqual(back[1].type, "through")
        let join = RouteFollow.progress(lat: back[1].lat, lon: back[1].lon, on: line)
        XCTAssertEqual(join.alongM, 6000, accuracy: 40)                                 // RouteFollow prefers the earliest of places about as near: up to ~25 m early
        XCTAssertLessThan(join.offRouteM, 30)
        XCTAssertEqual(back.last?.lat, route.waypoints.last?.lat)
        XCTAssertEqual(back.last?.lon, route.waypoints.last?.lon)
        XCTAssertEqual(back.last?.type, "break")
    }

    func testThePointsAlongTheWayKeepTheNewRouteOnThePlannedRoads() throws {
        let route = try baseRoute()
        let back = RouteWaypoints.rejoin(waypoints: route.waypoints, alongM: 1000, on: route.line, current: (47.4, 8.6))
        XCTAssertGreaterThanOrEqual(back.count, 5)                                  // about 28 km to go at a point every 8 km
        XCTAssertLessThanOrEqual(back.count, 40)
        let alongs = back.dropFirst().dropLast().map { RouteFollow.progress(lat: $0.lat, lon: $0.lon, on: route.line).alongM }
        XCTAssertEqual(alongs, alongs.sorted())
        XCTAssertTrue(back.dropFirst().dropLast().allSatisfy { $0.type == "through" })
    }

    func testAStopStillAheadIsKeptAndOneBehindIsNot() throws {
        let route = try baseRoute()
        let sim = DriveSimulator(line: route.line)
        let a = sim.position(at: 0), stop = sim.position(at: 12_236), end = sim.position(at: route.line.total)
        let waypoints = [RouteWaypoint(lat: a.lat, lon: a.lon), RouteWaypoint(lat: stop.lat, lon: stop.lon), RouteWaypoint(lat: end.lat, lon: end.lon)]
        let early = RouteWaypoints.rejoin(waypoints: waypoints, alongM: 5000, on: route.line, current: (47.4, 8.6))
        XCTAssertTrue(early.contains { abs($0.lat - stop.lat) < 1e-9 && abs($0.lon - stop.lon) < 1e-9 && $0.type == "break" })
        let late = RouteWaypoints.rejoin(waypoints: waypoints, alongM: 15_000, on: route.line, current: (47.45, 8.7))
        XCTAssertFalse(late.contains { abs($0.lat - stop.lat) < 1e-9 && abs($0.lon - stop.lon) < 1e-9 })
    }

    func testNearTheEndTheWayBackIsJustTheDestinationAndTheCountIsCapped() throws {
        let route = try baseRoute()
        let near = RouteWaypoints.rejoin(waypoints: route.waypoints, alongM: route.line.total - 500, on: route.line, current: (47.49, 8.72))
        XCTAssertEqual(near.count, 2)
        let capped = RouteWaypoints.rejoin(waypoints: route.waypoints, alongM: 0, on: route.line, current: (47.4, 8.6), maxCount: 4)
        XCTAssertLessThanOrEqual(capped.count, 4)
        XCTAssertEqual(capped.last?.lat, route.waypoints.last?.lat)
    }
}
