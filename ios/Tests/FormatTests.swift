import XCTest

final class FormatTests: XCTestCase {
    func testParsesTheTimestampsTheServerStores() {
        // Python isoformat, Overland's "Z", fractional seconds and a naive timestamp (the server reads naive as UTC)
        XCTAssertEqual(Format.parseISO("2026-09-28T09:15:00+00:00")?.timeIntervalSince1970, 1790586900)
        XCTAssertEqual(Format.parseISO("2026-09-28T09:15:00Z")?.timeIntervalSince1970, 1790586900)
        XCTAssertEqual(Format.parseISO("2026-09-28T09:15:00.250Z")?.timeIntervalSince1970 ?? 0, 1790586900.25, accuracy: 0.001)
        XCTAssertEqual(Format.parseISO("2026-09-28T09:15:00")?.timeIntervalSince1970, 1790586900)
        XCTAssertNil(Format.parseISO("not a date"))
    }

    func testAnUnreadableDateFallsBackToItsFirstTenCharacters() {
        XCTAssertEqual(Format.day(iso: "2026-09-28 garbage"), "2026-09-28")
        XCTAssertEqual(Format.time(iso: "garbage"), "")
    }

    func testClock() {
        XCTAssertEqual(Format.clock(seconds: 0), "0:00")
        XCTAssertEqual(Format.clock(seconds: 5.9), "0:05")
        XCTAssertEqual(Format.clock(seconds: 605), "10:05")
        XCTAssertEqual(Format.clock(seconds: 3725), "1:02:05")
        XCTAssertEqual(Format.clock(seconds: -3), "0:00")
    }

    func testSpeedAndDistance() {
        XCTAssertEqual(Format.kmh(fromMps: 24), 86)
        XCTAssertEqual(Format.kmh(fromMps: 0), 0)
        XCTAssertEqual(Format.kmh(fromMps: -1), 0)          // CoreLocation's "unknown speed"
        XCTAssertEqual(Format.km(fromMeters: 12345), "12.3")
        XCTAssertEqual(Format.km(fromMeters: 0), "0.0")
    }

    func testWeekLabel() {
        XCTAssertEqual(Format.weekLabel("2026-W38"), "W38")
        XCTAssertEqual(Format.weekLabel("W38"), "W38")
    }
}
