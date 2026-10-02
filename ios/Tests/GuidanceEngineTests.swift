import XCTest

/// Turn-by-turn guidance on a REAL Valhalla route (the golden api_planner_trip.json: Zurich to Winterthur with a stop on the way). The behaviour was first worked out in a
/// prototype driven along this same route, with GPS noise, a tunnel, leaving the route and parking short of the destination.
final class GuidanceEngineTests: XCTestCase {
    private let metresPerDegree = 111_194.9266

    private func route() throws -> GuidanceRoute {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "api_planner_trip", withExtension: "json"), "missing fixture api_planner_trip.json")
        let answer = try JSONDecoder.ridelog.decode(PlanResponse.self, from: Data(contentsOf: url))
        return try XCTUnwrap(GuidanceRoute(route: try XCTUnwrap(answer.routes.first), name: "Test"))
    }

    /// A small repeatable "random" number, roughly normal (sum of twelve uniforms).
    private struct Noise {
        var state: UInt64 = 88172645463325252
        mutating func uniform() -> Double {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return Double(state % 1_000_000) / 1_000_000
        }
        mutating func normal() -> Double { (0..<12).reduce(0.0) { acc, _ in acc + uniform() } - 6 }
    }

    struct RideOutcome {
        var said: [(t: Int, text: String)] = []
        var reroutes: [Int] = []
        var arrived = false
        var texts: [String] { said.map(\.text) }
    }

    /// Rides the route at `speed` m/s, one fix a second.
    private func ride(_ route: GuidanceRoute, speed: Double = 14, noise: Double = 0, offset: ClosedRange<Double>? = nil, gap: ClosedRange<Double>? = nil,
                      stopShort: Double = 0, muted: Bool = false, announceStart: Bool = true) -> RideOutcome {
        var engine = GuidanceEngine(route: route, announceStart: announceStart)
        engine.muted = muted
        var sim = DriveSimulator(line: route.line)
        var random = Noise()
        var result = RideOutcome()
        let stopAt = route.line.total - stopShort
        var along = 0.0
        var t = 0
        while t < 20_000 {
            defer { t += 1; along += speed }
            if let gap, gap.contains(along) { continue }
            sim.alongM = min(along, stopAt)
            var position = sim.position(at: sim.alongM)
            if noise > 0 {
                position.lat += random.normal() * noise / metresPerDegree
                position.lon += random.normal() * noise / (metresPerDegree * cos(position.lat * .pi / 180))
            }
            if let offset, offset.contains(along) { position = sideways(of: route, at: sim.alongM, metres: 300) }
            let moving = along < stopAt ? speed : 0
            for output in engine.update(lat: position.lat, lon: position.lon, speedMps: moving, now: Double(t)) {
                switch output {
                case .say(let text): result.said.append((t, text))
                case .needReroute: result.reroutes.append(t)
                case .arrived: result.arrived = true
                }
            }
            if result.arrived || along > route.line.total + 3000 { break }
        }
        return result
    }

    /// A point `metres` to the side of the route at `along`: sideways, so that it is really off the route wherever the road runs.
    private func sideways(of route: GuidanceRoute, at along: Double, metres: Double) -> (lat: Double, lon: Double) {
        let sim = DriveSimulator(line: route.line)
        let a = sim.position(at: max(0, along - 10)), b = sim.position(at: along + 10), here = sim.position(at: along)
        let east = (b.lon - a.lon) * cos(here.lat * .pi / 180) * metresPerDegree, north = (b.lat - a.lat) * metresPerDegree
        let length = max(1, (east * east + north * north).squareRoot())
        let leftEast = -north / length, leftNorth = east / length
        return (here.lat + leftNorth * metres / metresPerDegree, here.lon + leftEast * metres / (metresPerDegree * cos(here.lat * .pi / 180)))
    }

    // MARK: the real route

    func testTheRealRouteHasTheTurnsTheEngineNeeds() throws {
        let route = try route()
        XCTAssertEqual(route.maneuvers.count, 17)
        XCTAssertEqual(route.lastLeg, 1)
        XCTAssertEqual(route.mode, "fast")
        XCTAssertGreaterThan(route.totalM, 29_000)
        XCTAssertEqual(route.waypoints.count, 2)
    }

    func testARouteWithoutTurnsCannotBeGuided() throws {
        let bare = PlannedRoute(name: "x", distanceKm: 1, durationMin: 1, twistyKm: 0, twistiness: 0, retracedPct: 0, newPct: 100, shape: [RoadPoint(lat: 1, lon: 1), RoadPoint(lat: 1.1, lon: 1.1)])
        XCTAssertNil(GuidanceRoute(route: bare, name: "x"))
    }

    // MARK: a whole ride

    func testARideIsAnnouncedFromStartToArrivalInOrder() throws {
        let r = ride(try route())
        XCTAssertTrue(r.arrived)
        XCTAssertEqual(r.texts.first, "Starting navigation. Drive east on Bahnhofquai. Then Bear right onto Central.")
        XCTAssertEqual(r.texts.last, "You have arrived at your destination.")
        let far = try XCTUnwrap(r.texts.firstIndex(of: "In 600 meters, turn right onto Schaffhauserplatz."))
        let near = try XCTUnwrap(r.texts.firstIndex(of: "Turn right onto Schaffhauserplatz."))
        XCTAssertLessThan(far, near)
        XCTAssertTrue(r.texts.contains("You have reached your stop."))
        XCTAssertTrue(r.texts.contains("Your stop is ahead."))
        XCTAssertTrue(r.texts.contains("You will arrive at your destination."))
        XCTAssertGreaterThan(r.said.count, 20)
        XCTAssertLessThan(r.said.count, 40)
    }

    func testEachTurnIsSaidOnceAtTheNearDistanceAndNeverTwice() throws {
        let r = ride(try route())
        for sentence in ["Turn right onto Schaffhauserplatz.", "Bear right onto Berninaplatz.", "Turn right onto Wallisellerstrasse.", "Turn left onto Alte Winterthurerstrasse.",
                         "Turn right onto Baltenswilerstrasse.", "Turn left onto Neue Winterthurerstrasse.", "You have reached your stop.", "You have arrived at your destination."] {
            XCTAssertEqual(r.texts.filter { $0 == sentence }.count, 1, sentence)
        }
        for (a, b) in zip(r.texts, r.texts.dropFirst()) { XCTAssertNotEqual(a, b) }
    }

    func testRoadNumbersAreNotReadOut() throws {
        let r = ride(try route())
        XCTAssertFalse(r.texts.contains { $0.contains(", 4") || $0.contains("/4") || $0.contains("Continue on") })
        XCTAssertTrue(r.texts.contains("Continue for 4 kilometers."))
        XCTAssertTrue(r.texts.contains("Continue for 12 kilometers."))
    }

    func testTheRoundaboutIsOneAnnouncementNotTwo() throws {
        let r = ride(try route())
        let roundabout = r.texts.filter { $0.lowercased().contains("roundabout") }
        XCTAssertFalse(roundabout.isEmpty)
        XCTAssertTrue(roundabout.allSatisfy { $0.contains("2nd exit") }, "\(roundabout)")
        XCTAssertFalse(r.texts.contains { $0.lowercased().contains("exit the roundabout") })
    }

    func testALongStraightGetsAnEarlyHeadsUp() throws {
        let r = ride(try route())
        XCTAssertTrue(r.texts.contains { $0.hasPrefix("In 2 kilometers, enter the roundabout") })
    }

    func testFasterRidersAreToldEarlierAndInKilometres() throws {
        let slow = ride(try route(), speed: 14).texts
        let fast = ride(try route(), speed: 25).texts
        XCTAssertTrue(slow.contains("In 600 meters, turn right onto Schaffhauserplatz."))
        XCTAssertTrue(fast.contains("In 1 kilometer, turn right onto Schaffhauserplatz."))
    }

    // MARK: noise, gaps, standing still

    func testGPSNoiseCausesNeitherARerouteNorAMissedArrival() throws {
        for noise in [8.0, 20.0] {
            let r = ride(try route(), noise: noise)
            XCTAssertTrue(r.reroutes.isEmpty, "noise \(noise)")
            XCTAssertTrue(r.arrived, "noise \(noise)")
        }
    }

    func testATunnelDoesNotMakeItSayTurnsThatAreAlreadyBehind() throws {
        let r = ride(try route(), gap: 5000...5700)
        XCTAssertTrue(r.arrived)
        XCTAssertEqual(r.texts.filter { $0 == "You have arrived at your destination." }.count, 1)
        for (a, b) in zip(r.texts, r.texts.dropFirst()) { XCTAssertNotEqual(a, b) }
    }

    func testStandingStillAtTheStartSaysTheStartOnceAndNothingMore() throws {
        let route = try route()
        var engine = GuidanceEngine(route: route)
        var said: [String] = []
        for t in 0..<120 {
            for case .say(let text) in engine.update(lat: route.line.lat[0], lon: route.line.lon[0], speedMps: 0, now: Double(t)) { said.append(text) }
        }
        XCTAssertEqual(said.count, 1)
        XCTAssertTrue(said[0].hasPrefix("Starting navigation."))
    }

    func testMutedIsSilentButStillKnowsItArrived() throws {
        let r = ride(try route(), muted: true)
        XCTAssertTrue(r.said.isEmpty)
        XCTAssertTrue(r.arrived)
    }

    func testAGuidanceThatIsToldNotToAnnounceTheStartDoesNot() throws {
        let r = ride(try route(), announceStart: false)
        XCTAssertFalse(r.texts.contains { $0.hasPrefix("Starting navigation") })
    }

    // MARK: leaving the route

    func testLeavingTheRouteAsksForANewOneOnceAndSaysSo() throws {
        let r = ride(try route(), offset: 2000...2100)                          // about seven seconds off the road, then back
        XCTAssertEqual(r.texts.filter { $0 == "Off route. Recalculating." }.count, 1)
        XCTAssertEqual(r.reroutes.count, 1)
        XCTAssertTrue(r.arrived)                                                // back on the route afterwards, guidance carries on
    }

    func testStayingOffTheRouteAsksAgainAfterAWhile() throws {
        let r = ride(try route(), offset: 2000...3500)
        XCTAssertGreaterThanOrEqual(r.reroutes.count, 2)
        XCTAssertGreaterThanOrEqual(r.reroutes[1] - r.reroutes[0], 15)
    }

    func testAShortWanderOffTheRouteIsNotARerouteYet() throws {
        let r = ride(try route(), offset: 2000...2040)                          // three seconds: a parking manoeuvre, not a wrong turn
        XCTAssertTrue(r.reroutes.isEmpty)
        XCTAssertFalse(r.texts.contains("Off route. Recalculating."))
    }

    func testBeingOffTheRouteWhileStandingStillIsNotAReroute() throws {
        let route = try route()
        var engine = GuidanceEngine(route: route, announceStart: false)
        var events: [GuidanceOutput] = []
        let aside = sideways(of: route, at: 1500, metres: 400)
        for t in 0..<60 { events += engine.update(lat: aside.lat, lon: aside.lon, speedMps: 0.0, now: Double(t)) }
        XCTAssertTrue(events.isEmpty)
    }

    // MARK: arriving

    func testStoppingJustShortOfTheDestinationCountsAsArrived() throws {
        XCTAssertTrue(ride(try route(), noise: 5, stopShort: 55).arrived)
    }

    func testStoppingFarShortDoesNot() throws {
        XCTAssertFalse(ride(try route(), noise: 5, stopShort: 100).arrived)
    }

    // MARK: the screen's numbers

    func testTheStatusCountsDownToTheNextTurnAndTheArrival() throws {
        let route = try route()
        var engine = GuidanceEngine(route: route, announceStart: false)
        var sim = DriveSimulator(line: route.line)
        var position = sim.step(seconds: 100, speedMps: 14)
        _ = engine.update(lat: position.lat, lon: position.lon, speedMps: 14, now: 100)
        let early = engine.status
        XCTAssertEqual(early.alongM, 1400, accuracy: 30)
        XCTAssertEqual(early.remainingM, route.totalM - 1400, accuracy: 30)
        let next = try XCTUnwrap(early.nextIndex)
        XCTAssertEqual(route.maneuvers[next].alongM - early.alongM, try XCTUnwrap(early.distanceToNextM), accuracy: 1)
        XCTAssertGreaterThan(early.remainingS, 600)
        position = sim.step(seconds: 600, speedMps: 14)
        _ = engine.update(lat: position.lat, lon: position.lon, speedMps: 14, now: 700)
        XCTAssertLessThan(engine.status.remainingM, early.remainingM)
        XCTAssertLessThan(engine.status.remainingS, early.remainingS)
        XCTAssertFalse(engine.status.isOffRoute)
    }

    // MARK: stops ahead, for rerouting

    func testTheStopsStillAheadAreWorkedOutAlongTheRoute() throws {
        let route = try route()
        let line = route.line
        let a = DriveSimulator(line: line).position(at: 0), stop = DriveSimulator(line: line).position(at: 12_236), end = DriveSimulator(line: line).position(at: line.total)
        let waypoints = [RouteWaypoint(lat: a.lat, lon: a.lon), RouteWaypoint(lat: stop.lat, lon: stop.lon), RouteWaypoint(lat: end.lat, lon: end.lon)]
        let alongs = RouteWaypoints.alongs(of: waypoints, on: line)
        XCTAssertEqual(alongs[0], 0)
        XCTAssertEqual(alongs[1], 12_236, accuracy: 30)
        XCTAssertEqual(alongs[2], line.total, accuracy: 1)
        let early = RouteWaypoints.remaining(waypoints: waypoints, alongM: 5000, on: line, current: (47.4, 8.6))
        XCTAssertEqual(early.count, 3)                                            // where you are, the stop, the end
        XCTAssertEqual(early[0].lat, 47.4)
        let late = RouteWaypoints.remaining(waypoints: waypoints, alongM: 20_000, on: line, current: (47.45, 8.7))
        XCTAssertEqual(late.count, 2)                                             // the stop is behind: where you are, the end
        let justBefore = RouteWaypoints.remaining(waypoints: waypoints, alongM: 12_200, on: line, current: (47.45, 8.7))
        XCTAssertEqual(justBefore.count, 2)                                       // closer than 50 m: counts as reached
    }

    func testALoopsEndIsNotMistakenForItsStart() {
        let line = RouteFollow.line([[47.0, 8.0], [47.05, 8.0], [47.05, 8.07], [47.0, 8.07], [47.0, 8.0]])!
        let waypoints = [RouteWaypoint(lat: 47.0, lon: 8.0), RouteWaypoint(lat: 47.05, lon: 8.07, type: "through"), RouteWaypoint(lat: 47.0, lon: 8.0)]
        let alongs = RouteWaypoints.alongs(of: waypoints, on: line)
        XCTAssertEqual(alongs[0], 0)
        XCTAssertEqual(alongs[1], 5560 + 5308, accuracy: 60)
        XCTAssertEqual(alongs[2], line.total, accuracy: 1)
        let ahead = RouteWaypoints.remaining(waypoints: waypoints, alongM: 2000, on: line, current: (47.02, 8.0))
        XCTAssertEqual(ahead.count, 3)
    }

    // MARK: the simulator

    func testTheSimulatorRidesAlongTheLineAtTheSpeedGiven() throws {
        let route = try route()
        var sim = DriveSimulator(line: route.line)
        let start = sim.position(at: 0)
        XCTAssertEqual(start.lat, route.line.lat[0], accuracy: 1e-9)
        _ = sim.step(seconds: 10, speedMps: 14)
        XCTAssertEqual(sim.alongM, 140, accuracy: 1e-9)
        sim.skip(metres: 1000)
        XCTAssertEqual(sim.alongM, 1140, accuracy: 1e-9)
        _ = sim.step(seconds: 100_000, speedMps: 14)
        XCTAssertTrue(sim.isFinished)
        XCTAssertEqual(sim.alongM, route.line.total, accuracy: 1e-9)
        let end = sim.position(at: 1e9)
        XCTAssertEqual(end.lat, route.line.lat.last!, accuracy: 1e-9)
    }
}

/// The words and symbols (Sources/Core/GuidanceEngine.swift GuidanceText).
final class GuidanceTextTests: XCTestCase {
    func testTheFirstSentenceIsTakenWithoutBreakingOnDecimalPoints() {
        XCTAssertEqual(GuidanceText.firstSentence("Turn right onto Wannenweg. Then bear left."), "Turn right onto Wannenweg.")
        XCTAssertEqual(GuidanceText.firstSentence("Turn left"), "Turn left")
        XCTAssertEqual(GuidanceText.firstSentence("Continue for 1.5 kilometers."), "Continue for 1.5 kilometers.")
        XCTAssertEqual(GuidanceText.firstSentence("  Drive east.  "), "Drive east.")
        XCTAssertEqual(GuidanceText.firstSentence(""), "")
    }

    func testTheFirstLetterIsLoweredUnlessItIsAnAbbreviation() {
        XCTAssertEqual(GuidanceText.lowerFirst("Turn right."), "turn right.")
        XCTAssertEqual(GuidanceText.lowerFirst("SBB station"), "SBB station")
        XCTAssertEqual(GuidanceText.lowerFirst(""), "")
    }

    func testRoadNumbersAreTakenOutOfNames() {
        XCTAssertEqual(GuidanceText.clean("Bear right onto Berninaplatz, 4."), "Bear right onto Berninaplatz.")
        XCTAssertEqual(GuidanceText.clean("Exit onto Schaffhauserstrasse/4."), "Exit onto Schaffhauserstrasse.")
        XCTAssertEqual(GuidanceText.clean("Turn left onto Neue Winterthurerstrasse, 1."), "Turn left onto Neue Winterthurerstrasse.")
        XCTAssertEqual(GuidanceText.clean("Turn right onto Hardstrasse 10."), "Turn right onto Hardstrasse 10.")          // a house number is not a road number
        XCTAssertEqual(GuidanceText.clean("Drive  east   on Bahnhofquai ."), "Drive east on Bahnhofquai .")
    }

    func testDistancesAreSaidTheWayAPersonSaysThem() {
        XCTAssertEqual(GuidanceText.distancePhrase(620), "600 meters")
        XCTAssertEqual(GuidanceText.distancePhrase(603), "600 meters")
        XCTAssertEqual(GuidanceText.distancePhrase(300), "300 meters")
        XCTAssertEqual(GuidanceText.distancePhrase(140), "100 meters")
        XCTAssertEqual(GuidanceText.distancePhrase(60), "100 meters")
        XCTAssertEqual(GuidanceText.distancePhrase(960), "1 kilometer")
        XCTAssertEqual(GuidanceText.distancePhrase(1100), "1 kilometer")
        XCTAssertEqual(GuidanceText.distancePhrase(1970), "2 kilometers")
        XCTAssertEqual(GuidanceText.distancePhrase(2600), "2.5 kilometers")
        XCTAssertEqual(GuidanceText.distancePhrase(4000), "4 kilometers")
    }

    func testLongStretchesAreNamedInKilometres() {
        XCTAssertNil(GuidanceText.spokenLength(1200))
        XCTAssertEqual(GuidanceText.spokenLength(4294), "4 kilometers")
        XCTAssertEqual(GuidanceText.spokenLength(12_418), "12 kilometers")
        XCTAssertEqual(GuidanceText.spokenLength(1600), "2 kilometers")
    }

    func testTheBannerDistance() {
        XCTAssertEqual(GuidanceText.shortDistance(0), "0 m")
        XCTAssertEqual(GuidanceText.shortDistance(87), "90 m")
        XCTAssertEqual(GuidanceText.shortDistance(640), "640 m")
        XCTAssertEqual(GuidanceText.shortDistance(1250), "1.3 km")
        XCTAssertEqual(GuidanceText.shortDistance(-5), "0 m")
    }

    func testEveryManeuverTypeHasASymbol() {
        for type in 0...40 { XCTAssertFalse(GuidanceText.symbol(forType: type).isEmpty, "\(type)") }
        XCTAssertEqual(GuidanceText.symbol(forType: 10), "arrow.turn.up.right")
        XCTAssertEqual(GuidanceText.symbol(forType: 15), "arrow.turn.up.left")
        XCTAssertEqual(GuidanceText.symbol(forType: 26), "arrow.triangle.2.circlepath")
        XCTAssertEqual(GuidanceText.symbol(forType: 4), "flag.checkered")
        XCTAssertEqual(GuidanceText.symbol(forType: 8), "arrow.up")
        XCTAssertEqual(GuidanceText.symbol(forType: 12), "arrow.uturn.right")
    }
}
