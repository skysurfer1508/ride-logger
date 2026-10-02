import XCTest

private func pt(_ t: Double, lat: Double = 47.0, mps: Double = 10, dist: Double = 0, alt: Double? = nil) -> TrackPoint {
    TrackPoint(t: t, lat: lat, lon: 8.0, mps: mps, altitude: alt, dist: dist)
}

final class TrackMathTests: XCTestCase {
    // MARK: finding a moment

    func testIndexIsTheLastFixAtOrBeforeTheTime() {
        let pts = [pt(0), pt(10), pt(20), pt(30)]
        XCTAssertEqual(TrackMath.index(atOrBefore: -5, in: pts), 0)
        XCTAssertEqual(TrackMath.index(atOrBefore: 0, in: pts), 0)
        XCTAssertEqual(TrackMath.index(atOrBefore: 9.99, in: pts), 0)
        XCTAssertEqual(TrackMath.index(atOrBefore: 10, in: pts), 1)
        XCTAssertEqual(TrackMath.index(atOrBefore: 25, in: pts), 2)
        XCTAssertEqual(TrackMath.index(atOrBefore: 999, in: pts), 3)
        XCTAssertEqual(TrackMath.index(atOrBefore: 5, in: []), 0)
    }

    func testBetweenTwoFixesThePositionAndSpeedAreInterpolated() throws {
        let pts = [pt(0, lat: 47.0, mps: 10, dist: 0, alt: 400), pt(10, lat: 47.001, mps: 20, dist: 111.2, alt: 410)]
        let s = try XCTUnwrap(TrackMath.sample(at: 5, in: pts))
        XCTAssertEqual(s.lat, 47.0005, accuracy: 1e-9)
        XCTAssertEqual(s.mps, 15, accuracy: 1e-9)
        XCTAssertEqual(s.dist, 55.6, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(s.altitude), 405, accuracy: 1e-9)
        XCTAssertEqual(s.index, 0)
        XCTAssertEqual(s.kmh, 54)                                                  // 15 m/s
    }

    func testBeforeTheFirstAndAfterTheLastFixTheEndsAreUsed() throws {
        let pts = [pt(0, lat: 47.0), pt(10, lat: 47.001)]
        XCTAssertEqual(try XCTUnwrap(TrackMath.sample(at: -3, in: pts)).lat, 47.0)
        let end = try XCTUnwrap(TrackMath.sample(at: 99, in: pts))
        XCTAssertEqual(end.lat, 47.001)
        XCTAssertEqual(end.index, 1)
        XCTAssertNil(TrackMath.sample(at: 0, in: []))
    }

    func testAStandstillGapKeepsTheBikeWhereItWasAtSpeedZero() throws {
        // the recorder's distance filter: no fixes for 40 s at a red light, 3 m apart
        let pts = [pt(0, lat: 47.0, mps: 0.3, dist: 0), pt(40, lat: 47.00003, mps: 0.5, dist: 3)]
        XCTAssertTrue(TrackMath.isStandstill(pts[0], pts[1]))
        let mid = try XCTUnwrap(TrackMath.sample(at: 20, in: pts))
        XCTAssertEqual(mid.lat, 47.0)
        XCTAssertEqual(mid.mps, 0)
        XCTAssertEqual(mid.dist, 0)
    }

    func testALongGapWithRealMovementIsInterpolatedNotTreatedAsAStop() throws {
        // a tunnel: 40 s without fixes but 500 m further on
        let pts = [pt(0, lat: 47.0, mps: 12, dist: 0), pt(40, lat: 47.0045, mps: 12, dist: 500)]
        XCTAssertFalse(TrackMath.isStandstill(pts[0], pts[1]))
        let mid = try XCTUnwrap(TrackMath.sample(at: 20, in: pts))
        XCTAssertEqual(mid.lat, 47.00225, accuracy: 1e-9)
        XCTAssertEqual(mid.dist, 250, accuracy: 1e-9)
    }

    func testAShortGapIsNeverAStandstill() {
        XCTAssertFalse(TrackMath.isStandstill(pt(0, dist: 0), pt(5.9, dist: 1)))
        XCTAssertTrue(TrackMath.isStandstill(pt(0, dist: 0), pt(6, dist: 1)))
        XCTAssertFalse(TrackMath.isStandstill(pt(0, dist: 0), pt(60, dist: 20)))
    }

    // MARK: tapping the map

    func testTheNearestFixToATapAndTheMaximumDistance() {
        let pts = [pt(0, lat: 47.000), pt(10, lat: 47.001), pt(20, lat: 47.002)]
        XCTAssertEqual(TrackMath.nearestIndex(lat: 47.0021, lon: 8.0, in: pts), 2)
        XCTAssertEqual(TrackMath.nearestIndex(lat: 46.9999, lon: 8.0, in: pts), 0)
        XCTAssertEqual(TrackMath.nearestIndex(lat: 47.0011, lon: 8.0, in: pts, maxMeters: 200), 1)
        XCTAssertNil(TrackMath.nearestIndex(lat: 47.02, lon: 8.0, in: pts, maxMeters: 200))        // about 2 km away
        XCTAssertNil(TrackMath.nearestIndex(lat: 47.0, lon: 8.0, in: []))
    }

    // MARK: speed colours

    func testSpeedBuckets() {
        XCTAssertEqual(TrackMath.speedBucket(kmh: 0), 0)
        XCTAssertEqual(TrackMath.speedBucket(kmh: 14.9), 0)
        XCTAssertEqual(TrackMath.speedBucket(kmh: 15), 1)
        XCTAssertEqual(TrackMath.speedBucket(kmh: 39.9), 1)
        XCTAssertEqual(TrackMath.speedBucket(kmh: 40), 2)
        XCTAssertEqual(TrackMath.speedBucket(kmh: 70), 3)
        XCTAssertEqual(TrackMath.speedBucket(kmh: 100), 4)
        XCTAssertEqual(TrackMath.speedBucket(kmh: 250), 4)
        XCTAssertEqual(TrackMath.bucketLimitsKmh.count + 1, SpeedColorsCount.value)
    }

    func testSegmentsJoinUpWithoutGapsAndFollowTheSpeed() {
        var pts: [TrackPoint] = []
        for i in 0..<10 { pts.append(pt(Double(i), lat: 47 + Double(i) * 0.0001, mps: 10 / 3.6)) }       // 10 km/h
        for i in 10..<20 { pts.append(pt(Double(i), lat: 47 + Double(i) * 0.0001, mps: 50 / 3.6)) }      // 50 km/h
        let segments = TrackMath.segments(pts)
        XCTAssertEqual(segments.first?.bucket, 0)
        XCTAssertEqual(segments.last?.bucket, 2)
        XCTAssertEqual(segments.first?.range.lowerBound, 0)
        XCTAssertEqual(segments.last?.range.upperBound, pts.count - 1)
        for (a, b) in zip(segments, segments.dropFirst()) {
            XCTAssertEqual(a.range.upperBound, b.range.lowerBound)                      // neighbours share a fix: the line has no hole
            XCTAssertNotEqual(a.bucket, b.bucket)
        }
        XCTAssertLessThanOrEqual(segments.count, 4)
    }

    func testOneNoisyReadingDoesNotChopTheLineUp() {
        var pts: [TrackPoint] = []
        for i in 0..<30 { pts.append(pt(Double(i), lat: 47 + Double(i) * 0.0001, mps: 50 / 3.6)) }
        pts[15] = pt(15, lat: 47.0015, mps: 5 / 3.6)                                        // one reading of 5 km/h in a steady 50
        XCTAssertEqual(TrackMath.segments(pts).map(\.bucket), [2])
    }

    func testTooFewPointsGiveNoSegments() {
        XCTAssertTrue(TrackMath.segments([]).isEmpty)
        XCTAssertTrue(TrackMath.segments([pt(0)]).isEmpty)
        XCTAssertTrue(TrackMath.smoothedKmh([]).isEmpty)
    }

    // MARK: stops

    func testWhichStopContainsAMoment() {
        let stops = [stop(60, 90), stop(200, 230)]
        XCTAssertNil(TrackMath.stop(at: 30, in: stops))
        XCTAssertEqual(TrackMath.stop(at: 60, in: stops)?.tStart, 60)
        XCTAssertEqual(TrackMath.stop(at: 90, in: stops)?.tStart, 60)
        XCTAssertNil(TrackMath.stop(at: 91, in: stops))
        XCTAssertEqual(TrackMath.stop(at: 215, in: stops)?.tStart, 200)
    }

    func testTheStopsSummaryWords() {
        XCTAssertEqual(TrackMath.stopsSummary(count: 0, standingSeconds: 0), "No stops")
        XCTAssertEqual(TrackMath.stopsSummary(count: 1, standingSeconds: 42), "1 stop · 0:42 standing")
        XCTAssertEqual(TrackMath.stopsSummary(count: 3, standingSeconds: 130), "3 stops · 2:10 standing")
    }

    func testServerStopKindsMapToIcons() {
        XCTAssertEqual(StopKind(serverKind: "traffic_light"), .trafficLight)
        XCTAssertEqual(StopKind(serverKind: "stop_sign"), .stopSign)
        XCTAssertEqual(StopKind(serverKind: "rail_crossing"), .railCrossing)
        XCTAssertEqual(StopKind(serverKind: "give_way"), .crossing)
        XCTAssertEqual(StopKind(serverKind: "other"), .traffic)
        XCTAssertEqual(StopKind(serverKind: "unknown"), .unknown)
        XCTAssertEqual(StopKind(serverKind: "something new from a newer server"), .unknown)
    }

    private func stop(_ start: Double, _ end: Double) -> RideStop {
        let json = #"{"t_start":\#(start),"t_end":\#(end),"duration_s":\#(end - start),"lat":47.0,"lon":8.0,"dist_from_start_m":100,"kind":"unknown","label":"Stop"}"#
        return try! JSONDecoder.ridelog.decode(RideStop.self, from: Data(json.utf8))
    }
}

/// The number of colours the route legend has (UI/SpeedColors lives in the SwiftUI part of the app, which the tests do not compile).
private enum SpeedColorsCount { static let value = 5 }
