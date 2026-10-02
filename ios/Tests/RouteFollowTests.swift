import XCTest

/// How far along a planned route the rider is, and how far off its line (Sources/Core/RouteFollow.swift).
final class RouteFollowTests: XCTestCase {
    private let metresPerDegree = 111_194.9266
    private let lat0 = 47.0
    private let lon0 = 8.0

    /// A point `north` metres north and `east` metres east of the origin.
    private func at(_ north: Double, _ east: Double = 0) -> [Double] {
        [lat0 + north / metresPerDegree, lon0 + east / (metresPerDegree * cos(lat0 * .pi / 180))]
    }

    /// A straight route north, a point every 100 m.
    private func straight(_ metres: Int = 1000) -> [[Double]] { stride(from: 0, through: metres, by: 100).map { at(Double($0)) } }

    private func progress(_ north: Double, _ east: Double = 0, on points: [[Double]], hint: Int? = nil) throws -> RouteFollow.Progress {
        let line = try XCTUnwrap(RouteFollow.line(points))
        let p = at(north, east)
        return RouteFollow.progress(lat: p[0], lon: p[1], on: line, hint: hint)
    }

    func testTheLineHasTheLengthOfTheRoute() throws {
        let line = try XCTUnwrap(RouteFollow.line(straight()))
        XCTAssertEqual(line.total, 1000, accuracy: 1)
        XCTAssertEqual(line.segmentCount, 10)
        XCTAssertEqual(line.cumulative.first, 0)
    }

    func testInvalidPointsAreLeftOutAndAShortLineIsNothing() throws {
        XCTAssertNil(RouteFollow.line([]))
        XCTAssertNil(RouteFollow.line([at(0)]))
        XCTAssertNil(RouteFollow.line([at(0), [999, 8], [47, .nan], [47.0]]))
        let line = try XCTUnwrap(RouteFollow.line([at(0), [999, 8], at(500), [1.0]]))
        XCTAssertEqual(line.lat.count, 2)
        XCTAssertEqual(line.total, 500, accuracy: 1)
    }

    func testAlongAndOffAreMeasuredFromTheNearestPointOfTheLine() throws {
        let p = try progress(350, 30, on: straight())
        XCTAssertEqual(p.alongM, 350, accuracy: 2)
        XCTAssertEqual(p.offRouteM, 30, accuracy: 1)
        XCTAssertEqual(p.remainingM, 650, accuracy: 2)
        XCTAssertEqual(p.fraction, 0.35, accuracy: 0.005)
        XCTAssertFalse(p.isOffRoute)
        XCTAssertEqual(p.segment, 3)
    }

    func testFarFromTheLineIsOffRoute() throws {
        XCTAssertFalse(try progress(500, 99, on: straight()).isOffRoute)
        XCTAssertTrue(try progress(500, 101, on: straight()).isOffRoute)
        XCTAssertEqual(try progress(500, 340, on: straight()).offRouteM, 340, accuracy: 1)
    }

    func testBeforeTheStartAndAfterTheEndAreClamped() throws {
        let before = try progress(-200, 0, on: straight())
        XCTAssertEqual(before.alongM, 0, accuracy: 0.5)
        XCTAssertEqual(before.offRouteM, 200, accuracy: 1)
        XCTAssertTrue(before.isOffRoute)
        let after = try progress(1300, 0, on: straight())
        XCTAssertEqual(after.alongM, 1000, accuracy: 2)
        XCTAssertEqual(after.remainingM, 0, accuracy: 2)
        XCTAssertEqual(after.fraction, 1, accuracy: 0.002)
    }

    func testAClosedLoopAtItsStartIsAtTheStartNotTheEnd() throws {
        let loop = [at(0, 0), at(500, 0), at(1000, 0), at(1000, 500), at(1000, 1000), at(500, 1000), at(0, 1000), at(0, 500), at(0, 0)]
        let p = try progress(0, 0, on: loop)
        XCTAssertEqual(p.alongM, 0, accuracy: 1)
        XCTAssertEqual(p.fraction, 0, accuracy: 0.001)
        XCTAssertEqual(p.segment, 0)
    }

    func testPartWayRoundALoopTheLastStretchIsTheLastStretch() throws {
        // a 10 km square, a point every 100 m, back to where it began: 400 segments
        var square: [[Double]] = []
        for k in 0...100 { square.append(at(Double(k) * 100, 0)) }
        for k in 1...100 { square.append(at(10_000, Double(k) * 100)) }
        for k in 1...100 { square.append(at(10_000 - Double(k) * 100, 10_000)) }
        for k in 1...100 { square.append(at(0, 10_000 - Double(k) * 100)) }
        let line = try XCTUnwrap(RouteFollow.line(square))
        XCTAssertEqual(line.segmentCount, 400)
        let nearTheEnd = at(0, 550)                                                         // 550 m from where it began, on the last side
        let found = RouteFollow.progress(lat: nearTheEnd[0], lon: nearTheEnd[1], on: line, hint: 392)
        XCTAssertEqual(found.alongM, 39_450, accuracy: 30)                                 // the east side is a few metres short of 10 km (the longitudes use the start's latitude)
        XCTAssertEqual(found.remainingM, 550, accuracy: 30)
    }

    func testOnTheWayBackOfAnOutAndBackTheHintKeepsYouOnTheWayBack() throws {
        // north 2 km along one line, back south along a line 20 m to the east, a point every 100 m
        let there = stride(from: 0, through: 2000, by: 100).map { at(Double($0)) }
        let back = stride(from: 2000, through: 0, by: -100).map { at(Double($0), 20) }
        let route = there + back
        let line = try XCTUnwrap(RouteFollow.line(route))
        let between = at(1000, 10)                                                         // exactly between the two legs
        let blind = RouteFollow.progress(lat: between[0], lon: between[1], on: line)
        XCTAssertEqual(blind.alongM, 1000, accuracy: 30)                                   // no idea where you are: the earliest of equally good places
        let onTheWayBack = RouteFollow.progress(lat: between[0], lon: between[1], on: line, hint: 30)
        XCTAssertGreaterThan(onTheWayBack.alongM, 2900)                                    // you were on the way back a moment ago
        XCTAssertLessThan(onTheWayBack.alongM, 3100)
        XCTAssertGreaterThanOrEqual(onTheWayBack.segment, 30)
        XCTAssertLessThanOrEqual(onTheWayBack.segment, 31)
    }

    func testRejoiningTheRouteFurtherOnIsFoundEvenOutsideTheWindow() throws {
        let long = stride(from: 0, through: 40_000, by: 100).map { at(Double($0)) }       // 400 segments
        let line = try XCTUnwrap(RouteFollow.line(long))
        let p = at(30_050, 10)
        let found = RouteFollow.progress(lat: p[0], lon: p[1], on: line, hint: 5)
        XCTAssertEqual(found.alongM, 30_050, accuracy: 5)
        XCTAssertFalse(found.isOffRoute)
        XCTAssertEqual(found.segment, 300)
    }

    func testTheHintMovesForwardWithTheRider() throws {
        let line = try XCTUnwrap(RouteFollow.line(straight(5000)))
        var hint: Int?
        var lastAlong = -1.0
        for metres in stride(from: 0.0, through: 5000.0, by: 37.0) {
            let p = at(metres, 5)
            let progress = RouteFollow.progress(lat: p[0], lon: p[1], on: line, hint: hint)
            XCTAssertGreaterThanOrEqual(progress.alongM, lastAlong - 0.5)
            XCTAssertEqual(progress.alongM, metres, accuracy: 2)
            lastAlong = progress.alongM
            hint = progress.segment
        }
    }

    func testTheActiveRouteSurvivesTheAppBeingClosed() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let file = ActiveRouteFile(url: dir.appendingPathComponent("nested/route.json"))
        XCTAssertNil(file.load())
        let route = ActiveRoute(name: "Sunday loop", distanceKm: 118.4, points: straight(), savedAt: Date(timeIntervalSince1970: 1_790_000_000))
        file.save(route)
        XCTAssertEqual(file.load(), route)
        file.clear()
        XCTAssertNil(file.load())
        file.clear()                                                                       // clearing nothing is fine
    }

    func testAnUnreadableOrEmptyFileIsNoRoute() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("route.json")
        try Data("not json".utf8).write(to: url)
        XCTAssertNil(ActiveRouteFile(url: url).load())
        let file = ActiveRouteFile(url: url)
        file.save(ActiveRoute(name: "x", distanceKm: 1, points: [at(0)], savedAt: Date()))                    // one point is not a route
        XCTAssertNil(file.load())
    }
}
