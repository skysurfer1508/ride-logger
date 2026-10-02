import XCTest

final class ImportSummaryTests: XCTestCase {
    private func result(_ status: String, reason: String? = nil) -> ImportResult {
        ImportResult(status: status, name: "n", rideId: status == "imported" ? 1 : nil, points: 10, reason: reason)
    }

    func testOneRideImported() {
        XCTAssertEqual(ImportSummary.text(ImportResponse(results: [result("imported")], imported: 1)), "Imported 1 ride.")
    }

    func testSeveralRidesImported() {
        XCTAssertEqual(ImportSummary.text(ImportResponse(results: [result("imported"), result("imported")], imported: 2)), "Imported 2 rides.")
    }

    func testARideThatWasAlreadyThereIsSaidPlainly() {
        XCTAssertEqual(ImportSummary.text(ImportResponse(results: [result("already_imported")], imported: 0)), "1 was already in RideLog.")
        XCTAssertEqual(ImportSummary.text(ImportResponse(results: [result("already_have_this_ride"), result("already_imported")], imported: 0)),
                       "2 were already in RideLog.")
    }

    func testMixedResultsAreAllMentioned() {
        let response = ImportResponse(results: [result("imported"), result("already_imported"), result("skipped", reason: "The track has no movement.")], imported: 1)
        XCTAssertEqual(ImportSummary.text(response), "Imported 1 ride. 1 was already in RideLog. The track has no movement.")
    }

    func testSeveralSkippedTracksAreCounted() {
        let response = ImportResponse(results: [result("skipped", reason: "The track has no movement."), result("skipped", reason: "Other")], imported: 0)
        XCTAssertEqual(ImportSummary.text(response), "The track has no movement. (2 tracks skipped.)")
    }

    func testAnEmptyAnswerIsNotSilent() {
        XCTAssertEqual(ImportSummary.text(ImportResponse(results: [], imported: 0)), "The file had nothing to import.")
    }
}
