import XCTest

final class LogicTests: XCTestCase {
    // RFC 7636 appendix B; the server's tests (tests/test_native_auth.py) use the same vector.
    private let rfcVerifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
    private let rfcChallenge = "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"

    func testChallengeMatchesTheRFC7636Vector() {
        XCTAssertEqual(PKCE.challenge(for: rfcVerifier), rfcChallenge)
    }

    func testARandomVerifierIsInsideTheServersAcceptedRange() {
        let verifier = PKCE.randomVerifier()
        XCTAssertEqual(verifier.count, 43)
        XCTAssertNotNil(verifier.range(of: "^[A-Za-z0-9_-]{43,128}$", options: .regularExpression))
        XCTAssertNotEqual(verifier, PKCE.randomVerifier())
    }

    func testBase64URLHasNoPaddingOrUnsafeCharacters() {
        XCTAssertEqual(Logic.base64url(Data([0xfb, 0xff, 0xfe])), "-__-")
        XCTAssertEqual(Logic.base64url(Data([0x01])), "AQ")
    }

    func testCodeIsReadFromTheCallback() {
        XCTAssertEqual(Logic.code(fromCallback: URL(string: "ridelogger://auth?code=abc.DEF_-1")!), "abc.DEF_-1")
        XCTAssertNil(Logic.code(fromCallback: URL(string: "ridelogger://auth")!))
    }

    func testIngestURLJoinsTheSiteAndThePath() {
        let base = URL(string: "https://ride.example.org")!
        XCTAssertEqual(Logic.ingestURL(base: base, path: "/api/ingest").absoluteString, "https://ride.example.org/api/ingest")
    }

    func testDecimalNumbersAcceptACommaAndRejectGarbage() {
        XCTAssertEqual(Logic.parseDecimal("7,5"), 7.5)
        XCTAssertEqual(Logic.parseDecimal(" 10 "), 10)
        XCTAssertNil(Logic.parseDecimal(""))
        XCTAssertNil(Logic.parseDecimal("abc"))
        XCTAssertNil(Logic.parseDecimal("inf"))
        XCTAssertNil(Logic.parseDecimal("nan"))
    }

    func testTabsAreInTheExpectedOrder() {
        XCTAssertEqual(AppTab.allCases.map(\.title).first, "Home")
        XCTAssertEqual(Set(AppTab.allCases.map(\.symbol)).count, AppTab.allCases.count)
    }
}

final class RideFiltersTests: XCTestCase {
    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    func testNoFiltersMeansOnlyPaging() {
        let filters = RideFilters()
        XCTAssertFalse(filters.isActive)
        XCTAssertEqual(filters.query(limit: 50, offset: 100, calendar: utc), ["limit": "50", "offset": "100"])
    }

    func testEveryFilterBecomesTheQueryTheServerExpects() {
        var filters = RideFilters()
        filters.dateFrom = Date(timeIntervalSince1970: 1790586900)          // 2026-09-28 09:15 UTC
        filters.dateTo = Date(timeIntervalSince1970: 1790517791)            // 2026-09-27 14:03 UTC
        filters.minKm = "10,5"
        filters.maxKm = " 200 "
        XCTAssertTrue(filters.isActive)
        XCTAssertEqual(filters.query(limit: 20, offset: 0, calendar: utc), [
            "limit": "20", "offset": "0", "date_from": "2026-09-28", "date_to": "2026-09-27", "min_km": "10.5", "max_km": "200",
        ])
    }

    func testANonNumberOrNegativeDistanceIsLeftOut() {
        var filters = RideFilters()
        filters.minKm = "abc"
        filters.maxKm = "-5"
        XCTAssertFalse(filters.isActive)
        XCTAssertNil(filters.query(limit: 1, offset: 0, calendar: utc)["min_km"])
        XCTAssertNil(filters.query(limit: 1, offset: 0, calendar: utc)["max_km"])
    }
}
