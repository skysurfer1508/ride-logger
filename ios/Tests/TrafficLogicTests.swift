import XCTest

final class TrafficLogicTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_790_586_900)

    private func last(radius: Double = 10, lat: Double = 47.0, lon: Double = 8.0) -> TrafficLogic.Query {
        TrafficLogic.Query(lat: lat, lon: lon, radiusKm: radius, at: t0)
    }

    // MARK: how big an area to ask for

    func testTheRadiusCoversTheVisibleMap() {
        XCTAssertEqual(TrafficLogic.radiusKm(latSpan: 0.1, lonSpan: 0.15, atLat: 47.38), 8)        // half the diagonal is 7.9 km
        XCTAssertEqual(TrafficLogic.radiusKm(latSpan: 0.2, lonSpan: 0.2, atLat: 0), 16)
    }

    func testTheRadiusStaysBetweenThreeAndFiftyKilometres() {
        XCTAssertEqual(TrafficLogic.radiusKm(latSpan: 0.001, lonSpan: 0.001, atLat: 47.38), 3)
        XCTAssertEqual(TrafficLogic.radiusKm(latSpan: 2, lonSpan: 3, atLat: 47.38), 50)            // the server's webcam limit
        XCTAssertEqual(TrafficLogic.radiusKm(latSpan: -0.1, lonSpan: -0.15, atLat: 47.38), 8)      // spans are lengths: a sign never matters
    }

    // MARK: when to ask again

    func testTheFirstTimeAlwaysAsks() {
        XCTAssertTrue(TrafficLogic.needsRefresh(last: nil, lat: 47, lon: 8, radiusKm: 10, now: t0))
    }

    func testAnUnchangedMapDoesNotAskAgainUntilTheAnswerIsOld() {
        XCTAssertFalse(TrafficLogic.needsRefresh(last: last(), lat: 47, lon: 8, radiusKm: 10, now: t0.addingTimeInterval(60)))
        XCTAssertFalse(TrafficLogic.needsRefresh(last: last(), lat: 47, lon: 8, radiusKm: 10, now: t0.addingTimeInterval(120)))
        XCTAssertTrue(TrafficLogic.needsRefresh(last: last(), lat: 47, lon: 8, radiusKm: 10, now: t0.addingTimeInterval(121)))
        XCTAssertTrue(TrafficLogic.needsRefresh(last: last(), lat: 47, lon: 8, radiusKm: 10, now: t0.addingTimeInterval(200), maxAge: 120))
        XCTAssertFalse(TrafficLogic.needsRefresh(last: last(), lat: 47, lon: 8, radiusKm: 10, now: t0.addingTimeInterval(200), maxAge: 300))
    }

    func testPanningFarEnoughAsksAgain() {
        // a quarter of a 10 km radius is 2.5 km
        XCTAssertFalse(TrafficLogic.needsRefresh(last: last(), lat: 47.018, lon: 8, radiusKm: 10, now: t0))      // about 2.0 km
        XCTAssertTrue(TrafficLogic.needsRefresh(last: last(), lat: 47.03, lon: 8, radiusKm: 10, now: t0))        // about 3.3 km
    }

    func testASmallMapStillNeedsAtLeastOneKilometreOfPanning() {
        XCTAssertFalse(TrafficLogic.needsRefresh(last: last(radius: 2), lat: 47.005, lon: 8, radiusKm: 2, now: t0))   // 0.55 km
        XCTAssertTrue(TrafficLogic.needsRefresh(last: last(radius: 2), lat: 47.01, lon: 8, radiusKm: 2, now: t0))     // 1.1 km
    }

    func testZoomingALotAsksAgain() {
        XCTAssertTrue(TrafficLogic.needsRefresh(last: last(), lat: 47, lon: 8, radiusKm: 15, now: t0))
        XCTAssertFalse(TrafficLogic.needsRefresh(last: last(), lat: 47, lon: 8, radiusKm: 13, now: t0))
        XCTAssertTrue(TrafficLogic.needsRefresh(last: last(), lat: 47, lon: 8, radiusKm: 5, now: t0))
        XCTAssertFalse(TrafficLogic.needsRefresh(last: last(), lat: 47, lon: 8, radiusKm: 7, now: t0))
    }

    // MARK: words

    func testDistanceText() {
        XCTAssertEqual(TrafficLogic.distanceText(0.94), "0.9 km")
        XCTAssertEqual(TrafficLogic.distanceText(12.4), "12 km")
        XCTAssertEqual(TrafficLogic.distanceText(0), "0.0 km")
    }

    func testValidityPrefersTheEndThenTheStart() throws {
        let end = try XCTUnwrap(Format.parseISO("2026-10-02T10:00:00Z"))
        let start = try XCTUnwrap(Format.parseISO("2026-10-02T08:10:00Z"))
        XCTAssertEqual(TrafficLogic.validity(start: "2026-10-02T08:10:00Z", end: "2026-10-02T10:00:00Z"), "Until " + Format.time(end))
        XCTAssertEqual(TrafficLogic.validity(start: "2026-10-02T08:10:00Z", end: nil), "Since " + Format.time(start))
        XCTAssertEqual(TrafficLogic.validity(start: nil, end: "garbage"), nil)
        XCTAssertNil(TrafficLogic.validity(start: nil, end: nil))
    }

    func testSeverityText() {
        XCTAssertEqual(TrafficLogic.severityText("high"), "High severity")
        XCTAssertEqual(TrafficLogic.severityText("MEDIUM"), "Medium severity")
        XCTAssertNil(TrafficLogic.severityText(""))
        XCTAssertNil(TrafficLogic.severityText("  "))
        XCTAssertNil(TrafficLogic.severityText(nil))
    }

    func testSetupHintsNameTheServerSetting() {
        XCTAssertTrue(TrafficLogic.setupHint(layer: "incidents").contains("OPENTRANSPORTDATA_API_KEY"))
        XCTAssertTrue(TrafficLogic.setupHint(layer: "webcams").contains("WINDY_API_KEY"))
        XCTAssertFalse(TrafficLogic.setupHint(layer: "anything else").isEmpty)
    }

    func testIncidentKindsMapToSymbolsAndUnknownIsOther() {
        XCTAssertEqual(IncidentKind(serverKind: "accident"), .accident)
        XCTAssertEqual(IncidentKind(serverKind: "congestion"), .congestion)
        XCTAssertEqual(IncidentKind(serverKind: "roadworks"), .roadworks)
        XCTAssertEqual(IncidentKind(serverKind: "closure"), .closure)
        XCTAssertEqual(IncidentKind(serverKind: "hazard"), .hazard)
        XCTAssertEqual(IncidentKind(serverKind: "something new"), .other)
        let all: [IncidentKind] = [.accident, .congestion, .roadworks, .closure, .hazard, .other]
        XCTAssertEqual(Set(all.map(\.symbol)).count, all.count)
    }
}
