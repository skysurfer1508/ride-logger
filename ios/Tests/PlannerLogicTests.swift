import XCTest

/// The planner models against the server's own golden JSON, and the words and requests the planner screen uses.
final class PlannerLogicTests: XCTestCase {
    private func load<T: Decodable>(_ name: String, as type: T.Type = T.self) throws -> T {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "json"), "missing fixture \(name).json")
        return try JSONDecoder.ridelog.decode(T.self, from: Data(contentsOf: url))
    }

    private func route(km: Double = 118.4, minutes: Int = 197, twisty: Double = 25.2, retraced: Int = 3, new: Int = 100, points: [RoadPoint] = [RoadPoint(lat: 47, lon: 8), RoadPoint(lat: 47.1, lon: 8.1)]) -> PlannedRoute {
        PlannedRoute(name: "Best loop", distanceKm: km, durationMin: minutes, twistyKm: twisty, twistiness: 40, retracedPct: retraced, newPct: new, shape: points)
    }

    // MARK: decoding

    func testTheGoldenLoopAnswerDecodes() throws {
        let answer: PlanResponse = try load("api_planner_loop")
        XCTAssertTrue(answer.isOk)
        XCTAssertNil(answer.message)
        XCTAssertEqual(answer.roadsData, false)
        XCTAssertGreaterThan(answer.tried ?? 0, 10)
        XCTAssertEqual(answer.routes.count, 3)
        let best = answer.routes[0]
        XCTAssertEqual(best.name, "Best loop")
        XCTAssertEqual(best.id, "Best loop")
        XCTAssertGreaterThan(best.distanceKm, 40)
        XCTAssertGreaterThan(best.shape.count, 100)
        XCTAssertEqual(best.newPct, 100)
        XCTAssertEqual(Set(answer.routes.map(\.id)).count, 3)
        XCTAssertNil(PlannerLogic.problem(answer))
    }

    func testTheGoldenSavedRoutesDecode() throws {
        let list: SavedRoutesResponse = try load("api_planner_routes")
        XCTAssertEqual(list.routes.count, 1)
        let saved = list.routes[0]
        XCTAssertEqual(saved.id, 1)
        XCTAssertEqual(saved.name, "Sunday loop")
        XCTAssertEqual(saved.kind, "loop")
        XCTAssertEqual(saved.distanceKm, 1.6, accuracy: 0.05)
        XCTAssertEqual(saved.durationMin, 60)
        XCTAssertEqual(saved.twistiness, 68)
        XCTAssertEqual(saved.mode, "loop")
        let detail: SavedRouteDetailResponse = try load("api_planner_route")
        XCTAssertEqual(detail.route.id, saved.id)
        XCTAssertEqual(detail.route.name, saved.name)
        XCTAssertGreaterThan(detail.route.shape.count, 50)
        let active = PlannerLogic.activeRoute(from: detail.route, now: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(active.points.count, detail.route.shape.count)
        XCTAssertNotNil(RouteFollow.line(active.points))
        XCTAssertEqual(detail.route.waypoints?.map(\.type), ["break", "through", "break"])
        XCTAssertEqual(detail.route.mode, "loop")
    }

    func testAnUnavailableAnswerDecodesAndExplainsItself() throws {
        let json = #"{"api":1,"status":"unavailable","routes":[],"message":"The routing service is not answering right now. Try again in a moment."}"#
        let answer = try JSONDecoder.ridelog.decode(PlanResponse.self, from: Data(json.utf8))
        XCTAssertFalse(answer.isOk)
        XCTAssertNil(answer.tried)
        XCTAssertEqual(PlannerLogic.problem(answer), "The routing service is not answering right now. Try again in a moment.")
    }

    func testSavingAndDeletingAnswersDecode() throws {
        let saved = try JSONDecoder.ridelog.decode(SavedRouteResponse.self, from: Data(#"{"api":1,"route":{"id":4,"name":"x","kind":"route","distance_km":3.5,"duration_min":7,"twisty_km":0.2,"twistiness":5,"created_at":"2026-10-02 19:36:58"}}"#.utf8))
        XCTAssertEqual(saved.route.id, 4)
        XCTAssertEqual(saved.route.kind, "route")
        XCTAssertEqual(try JSONDecoder.ridelog.decode(DeletedRouteResponse.self, from: Data(#"{"api":1,"deleted":4}"#.utf8)).deleted, 4)
    }

    // MARK: words

    func testDurationsAndLengths() {
        XCTAssertEqual(PlannerLogic.durationText(minutes: 45), "45 min")
        XCTAssertEqual(PlannerLogic.durationText(minutes: 59), "59 min")
        XCTAssertEqual(PlannerLogic.durationText(minutes: 60), "1 h")
        XCTAssertEqual(PlannerLogic.durationText(minutes: 120), "2 h")
        XCTAssertEqual(PlannerLogic.durationText(minutes: 197), "3 h 17 min")
        XCTAssertEqual(PlannerLogic.durationText(minutes: -5), "0 min")
        XCTAssertEqual(PlannerLogic.kmText(23.456), "23.5 km")
        XCTAssertEqual(PlannerLogic.kmText(121.4), "121 km")
    }

    func testTheSummaryLine() {
        XCTAssertEqual(PlannerLogic.summary(route()), "118 km · 3 h 17 min · 25.2 km twisty")
        let saved = SavedRouteSummary(id: 1, name: "x", kind: "loop", distanceKm: 61.6, durationMin: 114, twistyKm: 16, twistiness: 26, createdAt: "")
        XCTAssertEqual(PlannerLogic.summary(saved), "61.6 km · 1 h 54 min · 16.0 km twisty")
    }

    func testWarningsOnlyWhenTheyMatter() {
        XCTAssertNil(PlannerLogic.retraceWarning(route(retraced: 14)))
        XCTAssertEqual(PlannerLogic.retraceWarning(route(retraced: 38)), "Goes back over 38% of its own road: there may be no other way round here.")
        XCTAssertNotNil(PlannerLogic.retraceWarning(route(retraced: 15)))
        XCTAssertNil(PlannerLogic.newText(route(new: 100)))
        XCTAssertEqual(PlannerLogic.newText(route(new: 62)), "62% roads you have not ridden")
    }

    func testWhatToSayWhenPlanningFails() {
        func answer(_ status: String, _ message: String?, routes: [PlannedRoute] = []) -> PlanResponse {
            PlanResponse(status: status, message: message, routes: routes, tried: nil, roadsData: nil)
        }
        XCTAssertNil(PlannerLogic.problem(answer("ok", nil, routes: [route()])))
        XCTAssertEqual(PlannerLogic.problem(answer("ok", nil)), "No route came back.")
        XCTAssertEqual(PlannerLogic.problem(answer("no_route", "Try another start.")), "Try another start.")
        XCTAssertEqual(PlannerLogic.problem(answer("unavailable", nil)), "The routing service is not available right now.")
        XCTAssertEqual(PlannerLogic.problem(answer("no_route", "")), "No route could be found.")
    }

    func testTheDefaultNameSaysWhatAndWhen() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let day = DateComponents(calendar: calendar, timeZone: calendar.timeZone, year: 2026, month: 10, day: 2, hour: 12).date!
        XCTAssertEqual(PlannerLogic.defaultName(kind: "loop", km: 118.4, now: day, calendar: calendar), "Loop 118 km, 2 Oct")
        XCTAssertEqual(PlannerLogic.defaultName(kind: "route", km: 33.6, now: day, calendar: calendar), "Route 34 km, 2 Oct")
    }

    // MARK: requests

    func testTheLoopFormIsWhatTheServerReads() {
        let form = PlannerLogic.loopForm(lat: 47.3769, lon: 8.5417, km: 100, avoidMotorways: true, pavedOnly: false, preferNew: true)
        XCTAssertEqual(form, ["lat": "47.37690", "lon": "8.54170", "distance_km": "100", "avoid_motorways": "true", "paved_only": "false", "prefer_new": "true"])
        XCTAssertEqual(PlannerLogic.loopForm(lat: 1, lon: 2, km: 5, avoidMotorways: true, pavedOnly: true, preferNew: false)["distance_km"], "20")
        XCTAssertEqual(PlannerLogic.loopForm(lat: 1, lon: 2, km: 999, avoidMotorways: true, pavedOnly: true, preferNew: false)["distance_km"], "400")
        XCTAssertEqual(PlannerLogic.loopForm(lat: 1, lon: 2, km: 99.6, avoidMotorways: true, pavedOnly: true, preferNew: false)["distance_km"], "100")
        XCTAssertEqual(PlannerLogic.loopForm(lat: -33.8, lon: -70.6, km: 50, avoidMotorways: false, pavedOnly: true, preferNew: false)["lat"], "-33.80000")
    }

    func testASavedRouteCarriesTheStopsThatMakeItAndItsStyle() throws {
        var withStops = route(minutes: 60)
        withStops.mode = "twisty"
        withStops.waypoints = [RouteWaypoint(lat: 47, lon: 8), RouteWaypoint(lat: 47.05, lon: 8.02, type: "through"), RouteWaypoint(lat: 47, lon: 8)]
        let form = PlannerLogic.saveForm(name: "Sunday", kind: "route", route: withStops)
        XCTAssertEqual(form["mode"], "twisty")
        let parsed = try JSONSerialization.jsonObject(with: Data(try XCTUnwrap(form["waypoints"]).utf8)) as? [[String: Any]]
        XCTAssertEqual(parsed?.count, 3)
        XCTAssertEqual(parsed?[1]["type"] as? String, "through")
        XCTAssertNil(PlannerLogic.saveForm(name: "x", kind: "loop", route: route())["waypoints"])
    }

    func testFollowingARouteUsesItsFullResolutionLineWhenItHasOne() throws {
        let trip: PlanResponse = try load("api_planner_trip")
        let planned = try XCTUnwrap(trip.routes.first)
        XCTAssertGreaterThan(Polyline6.decode(try XCTUnwrap(planned.shape6)).count, planned.shape.count)
        let active = PlannerLogic.activeRoute(from: planned, name: "x", now: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(active.points.count, Polyline6.decode(planned.shape6!).count)
        XCTAssertNotNil(RouteFollow.line(active.points))
        let thin = PlannerLogic.activeRoute(from: route(), name: "x", now: Date(timeIntervalSince1970: 0))                // no shape6: the thinned line
        XCTAssertEqual(thin.points.count, 2)
    }

    func testTheGoldenTripAndDirectionsAnswersDecodeWithTheirTurns() throws {
        let trip: PlanResponse = try load("api_planner_trip")
        XCTAssertTrue(trip.isOk)
        XCTAssertEqual(trip.routes.map(\.name), ["Fast", "Alternative 1"])
        let route = trip.routes[0]
        XCTAssertEqual(route.mode, "fast")
        XCTAssertEqual(route.waypoints?.count, 2)
        let maneuvers = try XCTUnwrap(route.maneuvers)
        XCTAssertEqual(maneuvers.count, 17)
        XCTAssertEqual(maneuvers[0].type, 1)
        XCTAssertEqual(maneuvers[0].street, "Bahnhofquai")
        XCTAssertEqual(maneuvers[0].alongM, 0)
        XCTAssertEqual(maneuvers.last?.type, 4)
        XCTAssertEqual(maneuvers.map(\.alongM), maneuvers.map(\.alongM).sorted())
        XCTAssertTrue(maneuvers.contains { $0.type == 26 && $0.roundaboutExit == 2 })
        XCTAssertEqual(Set(maneuvers.map(\.leg)), [0, 1])
        XCTAssertTrue(maneuvers.allSatisfy { !$0.pre.isEmpty })
        let directions: PlanResponse = try load("api_planner_directions")
        XCTAssertEqual(directions.routes.count, 1)
        XCTAssertEqual(directions.routes[0].waypoints?.first?.type, "break")
    }

    func testTheSaveFormCarriesTheLineAsJSON() throws {
        let form = PlannerLogic.saveForm(name: "Sunday loop", kind: "loop", route: route(minutes: 60))
        XCTAssertEqual(form["name"], "Sunday loop")
        XCTAssertEqual(form["kind"], "loop")
        XCTAssertEqual(form["duration_s"], "3600")
        XCTAssertEqual(form["shape"], "[[47.00000,8.00000],[47.10000,8.10000]]")
        let parsed = try JSONSerialization.jsonObject(with: Data(try XCTUnwrap(form["shape"]).utf8)) as? [[Double]]
        XCTAssertEqual(parsed?.count, 2)
    }

    // MARK: following

    func testAPlannedRouteBecomesTheActiveOne() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let active = PlannerLogic.activeRoute(from: route(km: 55), name: "Mine", now: now)
        XCTAssertEqual(active.name, "Mine")
        XCTAssertEqual(active.distanceKm, 55)
        XCTAssertEqual(active.points, [[47, 8], [47.1, 8.1]])
        XCTAssertEqual(active.savedAt, now)
    }

    func testTheFollowWords() {
        func progress(_ along: Double, off: Double) -> RouteFollow.Progress {
            RouteFollow.Progress(alongM: along, offRouteM: off, remainingM: 0, fraction: 0, segment: 0, isOffRoute: off > RouteFollow.offRouteMetres)
        }
        XCTAssertEqual(PlannerLogic.progressText(progress(0, off: 0), totalKm: 118.4), "118 km to ride")
        XCTAssertEqual(PlannerLogic.progressText(progress(31_200, off: 0), totalKm: 118.4), "31.2 of 118 km")
        XCTAssertEqual(PlannerLogic.offRouteText(progress(1000, off: 30)), "On the route")
        XCTAssertEqual(PlannerLogic.offRouteText(progress(1000, off: 340)), "Off the route by 340 m")
        XCTAssertEqual(PlannerLogic.offRouteText(progress(1000, off: 1500)), "Off the route by 1.5 km")
    }
}
