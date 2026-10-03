import XCTest

/// The answers the app decodes for corners, limits and conditions (Tests/Fixtures/api_planner_*.json, written by the server's tests).
final class RiderGuidanceModelsTests: XCTestCase {
    private func fixture<T: Decodable>(_ name: String, as type: T.Type) throws -> T {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "json"), "missing fixture \(name).json")
        return try JSONDecoder.ridelog.decode(T.self, from: Data(contentsOf: url))
    }

    func testTheCornersOfARouteAreDecodedAndReachTheGuidance() throws {
        let answer = try fixture("api_planner_directions", as: PlanResponse.self)
        let planned = try XCTUnwrap(answer.routes.first)
        let corners = try XCTUnwrap(planned.corners)
        XCTAssertFalse(corners.isEmpty)
        let first = corners[0]
        XCTAssertTrue(["sharp", "hairpin"].contains(first.kind))
        XCTAssertTrue(["left", "right"].contains(first.dir))
        XCTAssertGreaterThan(first.advisoryKmh, 0)
        let route = try XCTUnwrap(GuidanceRoute(route: planned, name: "x"))
        XCTAssertEqual(route.corners.count, corners.count)
        XCTAssertEqual(route.encodedLine, planned.shape6)
    }

    func testARouteWithoutCornersStillWorks() throws {
        let json = #"{"name":"x","distance_km":1,"duration_min":1,"twisty_km":0,"twistiness":0,"retraced_pct":0,"new_pct":100,"shape":[]}"#
        let route = try JSONDecoder.ridelog.decode(PlannedRoute.self, from: Data(json.utf8))
        XCTAssertNil(route.corners)
    }

    func testTheLimitsAlongARouteAreDecoded() throws {
        let answer = try fixture("api_planner_limits", as: LimitsResponse.self)
        XCTAssertEqual(answer.status, "ok")
        let limits = try XCTUnwrap(answer.limits)
        XCTAssertEqual(limits.map(\.kmh), [50, 80])
        XCTAssertEqual(limits[0].alongM, 0)
        let unknown = try JSONDecoder.ridelog.decode(LimitChange.self, from: Data(#"{"along_m":120,"kmh":null}"#.utf8))
        XCTAssertNil(unknown.kmh)
    }

    func testTheConditionsOfARideAreDecoded() throws {
        let answer = try fixture("api_planner_conditions", as: ConditionsResponse.self)
        XCTAssertEqual(answer.status, "ok")
        XCTAssertEqual(answer.alerts?.first?.kind, "rain")
        XCTAssertEqual(answer.alerts?.first?.label, "rain likely")
        XCTAssertNotNil(answer.light?.sunset)
        XCTAssertNotNil(answer.light?.darkMin)
        XCTAssertTrue(answer.summary?.hasPrefix("Rain likely") ?? false)
        XCTAssertEqual(answer.weather?.temperatureMinC, 9)
    }

    func testAnAnswerWithoutAlertsOrWeatherIsStillAnAnswer() throws {
        let answer = try JSONDecoder.ridelog.decode(ConditionsResponse.self, from: Data(#"{"api":1,"status":"ok","message":null,"light":{"sunset":null,"dusk":null,"dark_min":0},"summary":"","weather":null}"#.utf8))
        XCTAssertNil(answer.alerts)
        XCTAssertNil(answer.weather)
        XCTAssertNil(answer.light?.sunset)
    }
}
