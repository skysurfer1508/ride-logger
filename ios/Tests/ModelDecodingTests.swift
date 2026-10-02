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

    func testTrack() throws {
        let track: TrackResponse = try load("api_track")
        XCTAssertEqual(track.points.count, 64)
        XCTAssertEqual(track.pointCount, 64)
        XCTAssertEqual(track.points[0].t, 0)
        XCTAssertEqual(track.points[0].altitude, 410)
        XCTAssertEqual(track.durationS, 164)
        XCTAssertEqual(track.distanceM, 1260)
        XCTAssertEqual(track.points.last?.dist, 1260)
        XCTAssertEqual(track.maxSpeed?.kmh, 50)                                     // 14 m/s
        XCTAssertEqual(track.stops.count, 2)
        XCTAssertEqual(track.stops[0].durationS, 22)
        XCTAssertEqual(track.stops[1].tStart, 94)
        XCTAssertEqual(track.stops[0].stopKind, .unknown)
        XCTAssertEqual(track.stoppedS, 62)
        XCTAssertEqual(track.ride.distanceKm, 88.0)
        XCTAssertEqual(track.points.map(\.t), track.points.map(\.t).sorted())
    }

    func testTrackPointsDecodeFromTheCompactArrays() throws {
        let with = try JSONDecoder().decode(TrackPoint.self, from: Data("[12.5,47.1,8.2,5.5,410,100]".utf8))
        XCTAssertEqual(with, TrackPoint(t: 12.5, lat: 47.1, lon: 8.2, mps: 5.5, altitude: 410, dist: 100))
        let without = try JSONDecoder().decode(TrackPoint.self, from: Data("[12.5,47.1,8.2,5.5,null,100]".utf8))
        XCTAssertNil(without.altitude)
        XCTAssertEqual(without.dist, 100)                                           // the element after a null is still read correctly
        XCTAssertEqual(with.kmh, 19.8, accuracy: 1e-9)
        XCTAssertThrowsError(try JSONDecoder().decode(TrackPoint.self, from: Data("[1,2,3]".utf8)))
    }

    func testAnEmptyTrackDecodes() throws {
        let json = #"{"api":1,"ride":{"id":1,"start_time":"2026-09-30T08:00:00+00:00","end_time":"2026-09-30T08:10:00+00:00","distance_m":1000,"distance_km":1.0,"duration_s":600,"duration_hm":"0:10","avg_kmh":6,"max_kmh":9,"elevation_gain_m":0,"point_count":0,"source":"trip_marker"},"start":null,"duration_s":0,"distance_m":0,"points":[],"max_speed":null,"stops":[],"stopped_s":0,"point_count":0}"#
        let track = try JSONDecoder.ridelog.decode(TrackResponse.self, from: Data(json.utf8))
        XCTAssertTrue(track.points.isEmpty)
        XCTAssertNil(track.maxSpeed)
        XCTAssertNil(track.start)
        XCTAssertNil(track.featuresStatus)
    }

    func testTrafficConfig() throws {
        let config: TrafficConfig = try load("api_traffic_config")
        XCTAssertEqual(config, TrafficConfig(incidents: true, webcams: true))
    }

    func testTrafficIncidents() throws {
        let result: IncidentsResponse = try load("api_traffic_incidents")
        XCTAssertEqual(result.incidents.count, 4)
        XCTAssertEqual(result.unlocated, 1)
        XCTAssertEqual(result.total, 5)
        XCTAssertEqual(result.incidents.map(\.distanceKm), result.incidents.map(\.distanceKm).sorted())      // nearest first
        let accident = try XCTUnwrap(result.incidents.first { $0.id == "S1-R1" })
        XCTAssertEqual(accident.incidentKind, .accident)
        XCTAssertEqual(accident.severity, "high")
        XCTAssertEqual(accident.comment, "Accident on the A1, right lane closed.")
        XCTAssertEqual(accident.end, "2026-10-02T10:00:00Z")
        let jam = try XCTUnwrap(result.incidents.first { $0.id == "S2-R1" })
        XCTAssertEqual(jam.incidentKind, .congestion)
        XCTAssertEqual(jam.title, "Queuing traffic")
        XCTAssertNil(jam.severity)
        XCTAssertNil(jam.end)
        XCTAssertEqual(jam.comment, "")
        let closure = try XCTUnwrap(result.incidents.first { $0.id == "S11-R1" })
        XCTAssertEqual(closure.incidentKind, .closure)
        XCTAssertEqual(closure.title, "Road closed")
        let bare = try XCTUnwrap(result.incidents.first { $0.id == "S5-R1" })
        XCTAssertEqual(bare.incidentKind, .other)
        XCTAssertNil(bare.road)
    }

    func testTrafficWebcams() throws {
        let result: WebcamsResponse = try load("api_traffic_webcams")
        XCTAssertEqual(result.webcams.map(\.id), ["111", "222"])
        let first = result.webcams[0]
        XCTAssertEqual(first.title, "Hardbrucke")
        XCTAssertEqual(first.preview, "https://img.example/111.jpg")
        XCTAssertEqual(first.detailUrl, "https://windy.example/111")
        XCTAssertEqual(first.playerUrl, "https://player.example/111")
        XCTAssertEqual(first.category, "traffic")                                   // the fake answers every category with the same list: the first label wins
        XCTAssertTrue(first.isTrafficCamera)
        XCTAssertNil(result.webcams[1].preview)
        XCTAssertNil(result.webcams[1].detailUrl)
    }

    func testDeleteResponse() throws {
        let json = #"{"api":1,"deleted":42}"#
        XCTAssertEqual(try JSONDecoder.ridelog.decode(DeleteResponse.self, from: Data(json.utf8)).deleted, 42)
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
