import XCTest

/// Decodes the golden JSON the server's own tests keep current (Tests/Fixtures/api_*.json, see tests/test_api_fixtures.py).
/// If the API changes shape and a Swift model no longer matches, this fails.
final class ModelDecodingTests: XCTestCase {
    private func load<T: Decodable>(_ name: String, as type: T.Type = T.self) throws -> T {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "json"), "missing fixture \(name).json")
        return try JSONDecoder.ridelog.decode(T.self, from: Data(contentsOf: url))
    }

    func testMe() throws {
        let me: MeResponse = try load("api_me")
        XCTAssertEqual(me.name, "Alice")
        XCTAssertEqual(me.email, "alice@example.com")
        XCTAssertEqual(me.ingestPath, "/api/ingest")
        XCTAssertFalse(me.ingestToken.isEmpty)
    }

    func testHome() throws {
        let home: HomeResponse = try load("api_home")
        XCTAssertEqual(home.rideCount, 3)
        XCTAssertEqual(home.totalDistanceDisplay, "361")
        let latest = try XCTUnwrap(home.latest)
        XCTAssertEqual(latest.distanceKm, 12.4)
        XCTAssertEqual(latest.durationHm, "0:22")
        XCTAssertEqual(latest.source, "trip_marker")
        XCTAssertEqual(home.recentRoutes.count, 3)
        XCTAssertEqual(home.recentRoutes[0].polyline.coordinates.count, 4)
    }

    func testRidesPage() throws {
        let page: RidesResponse = try load("api_rides")
        XCTAssertEqual(page.rides.count, 3)
        XCTAssertFalse(page.hasMore)
        XCTAssertEqual(page.limit, 100)
        XCTAssertEqual(page.offset, 0)
        XCTAssertEqual(Set(page.rides.map(\.id)).count, 3)          // Identifiable: no duplicate ids
    }

    func testRideDetail() throws {
        let detail: RideDetailResponse = try load("api_ride_detail")
        XCTAssertEqual(detail.ride.distanceKm, 88.0)
        XCTAssertEqual(detail.ride.elevationGainM, 610)
        XCTAssertEqual(detail.ride.maxKmh, 139)
        XCTAssertEqual(detail.polyline.count, 4)
        XCTAssertEqual(detail.polyline[0], [47.3769, 8.5417])
    }

    func testOverview() throws {
        let overview: OverviewResponse = try load("api_overview")
        XCTAssertEqual(overview.rideCount, 3)
        XCTAssertEqual(overview.longestRideDisplay, "260")
        XCTAssertEqual(overview.weekly.count, 3)
        XCTAssertEqual(overview.weekly.reduce(0) { $0 + $1.km }, 360.7, accuracy: 0.001)
        XCTAssertEqual(overview.calendar.count, 90)
        XCTAssertTrue(overview.calendar.allSatisfy { (0...4).contains($0.level) })
        XCTAssertEqual(overview.records.longest?.distanceKm, 260.3)
        XCTAssertEqual(overview.records.mostClimb?.elevationGainM, 1500)
        XCTAssertNotNil(overview.records.fastestAvg)
        XCTAssertNotNil(overview.records.fastestTop)
        XCTAssertNotNil(overview.records.longestTime)
    }

    func testMap() throws {
        let map: MapResponse = try load("api_map")
        XCTAssertEqual(map.rideCount, 3)
        XCTAssertEqual(map.routes.count, 3)
        XCTAssertFalse(map.routes[0].label.contains("&middot;"))
    }

    func testSettings() throws {
        let settings: SettingsResponse = try load("api_settings")
        XCTAssertEqual(settings.detection.gapMinutes, 10)
        XCTAssertEqual(settings.detection.minPoints, 5)
        XCTAssertEqual(settings.detection.minDistanceM, 200)
        XCTAssertEqual(settings.detection.staleTripMinutes, 60)
    }

    func testAnEmptyAccountDecodes() throws {
        let json = #"{"api":1,"ride_count":0,"total_distance_display":"0","avg_speed_display":"0","latest":null,"recent_routes":[]}"#
        let home = try JSONDecoder.ridelog.decode(HomeResponse.self, from: Data(json.utf8))
        XCTAssertNil(home.latest)
        XCTAssertTrue(home.recentRoutes.isEmpty)
    }
}

// The route helper lives in the SwiftUI part of the app (UI/RouteMap.swift); this is the same rule, checked without MapKit.
private extension Array where Element == [Double] {
    var coordinates: [(Double, Double)] { compactMap { $0.count >= 2 ? ($0[0], $0[1]) : nil } }
}
