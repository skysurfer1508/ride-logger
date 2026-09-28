import Foundation

// The JSON the server's /api/v1 sends (app/routers/api_v1.py). Foundation only: this file is also compiled into the test target,
// and Tests/Fixtures/api_*.json (written by the server's tests) lock the shapes decoded here.

extension JSONDecoder {
    /// snake_case -> camelCase: "avg_kmh" -> avgKmh, "total_distance_display" -> totalDistanceDisplay.
    static let ridelog: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()
}

/// One ride as listed (no route).
struct RideSummary: Decodable, Identifiable, Hashable {
    let id: Int
    let startTime: String
    let endTime: String
    let distanceM: Double
    let distanceKm: Double
    let durationS: Double
    let durationHm: String
    let avgKmh: Int
    let maxKmh: Int
    let elevationGainM: Int
    let pointCount: Int
    /// "trip_marker" (started and stopped in the app) or "gap_inferred" (found from a gap in the points).
    let source: String
}

/// A route to draw: [[latitude, longitude], ...].
struct Route: Decodable, Identifiable, Hashable {
    let id: Int
    let label: String
    let polyline: [[Double]]
}

struct MeResponse: Decodable {
    let name: String
    let email: String
    let ingestToken: String
    let ingestPath: String
}

struct HomeResponse: Decodable {
    let rideCount: Int
    let totalDistanceDisplay: String
    let avgSpeedDisplay: String
    let latest: RideSummary?
    let recentRoutes: [Route]
}

struct RidesResponse: Decodable {
    let rides: [RideSummary]
    let limit: Int
    let offset: Int
    let hasMore: Bool
}

struct RideDetailResponse: Decodable {
    let ride: RideSummary
    let polyline: [[Double]]
}

struct WeekTotal: Decodable, Identifiable, Hashable {
    let week: String
    let km: Double
    var id: String { week }
}

struct CalendarCell: Decodable, Identifiable, Hashable {
    let date: String
    let km: Double
    /// 0 (no ride) ... 4 (120 km or more).
    let level: Int
    var id: String { date }
}

struct Records: Decodable {
    let longest: RideSummary?
    let fastestAvg: RideSummary?
    let fastestTop: RideSummary?
    let mostClimb: RideSummary?
    let longestTime: RideSummary?
}

struct OverviewResponse: Decodable {
    let rideCount: Int
    let totalDistanceDisplay: String
    let avgSpeedDisplay: String
    let longestRideDisplay: String
    let weekly: [WeekTotal]
    let records: Records
    let calendar: [CalendarCell]
}

struct MapResponse: Decodable {
    let rideCount: Int
    let routes: [Route]
}

struct Detection: Decodable, Equatable {
    var gapMinutes: Double
    var minPoints: Int
    var minDistanceM: Double
    var staleTripMinutes: Double
}

struct SettingsResponse: Decodable {
    let detection: Detection
}

struct TokenResponse: Decodable {
    let ingestToken: String
    let ingestPath: String
}
