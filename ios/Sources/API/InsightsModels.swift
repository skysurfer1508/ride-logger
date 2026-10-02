import Foundation

// GET /api/v1/rides/{id}/insights (app/routers/api_v1.py, app/extras.py). Foundation only: also compiled into the test target, and
// Tests/Fixtures/api_insights.json (written by the server's tests) locks the shape decoded here. Every part has its own status, so one
// service being down never hides the rest.

struct RideInsights: Decodable {
    let rideId: Int
    let elevation: ElevationProfile?
    let smoothness: Smoothness?
    let weather: WeatherInfo
    let limits: LimitsInfo
    /// The road the rider was on, each time it changed: [[seconds into the ride, name], ...].
    let roadNames: [RoadName]
}

struct RoadName: Decodable, Equatable {
    let t: Double
    let name: String

    init(t: Double, name: String) {
        self.t = t
        self.name = name
    }

    init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        t = try c.decode(Double.self)
        name = try c.decode(String.self)
    }
}

struct ElevationProfile: Decodable {
    /// Distance (metres into the ride) and smoothed altitude (metres).
    let points: [ElevationPoint]
    let ascentM: Int
    let descentM: Int
    let minM: Int
    let maxM: Int
}

struct ElevationPoint: Decodable, Equatable, Identifiable {
    let dist: Double
    let altitude: Double
    var id: Double { dist }

    init(dist: Double, altitude: Double) {
        self.dist = dist
        self.altitude = altitude
    }

    init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        dist = try c.decode(Double.self)
        altitude = try c.decode(Double.self)
    }
}

struct Smoothness: Decodable {
    let events: [SmoothnessEvent]
    let hardBraking: Int
    let hardAcceleration: Int
    let eventsPer10km: Double
    /// 0 to 100, higher is smoother.
    let score: Int
}

struct SmoothnessEvent: Decodable, Identifiable, Equatable {
    /// "braking" or "acceleration".
    let kind: String
    let tStart: Double
    let tEnd: Double
    let peakMps2: Double
    let fromKmh: Int
    let toKmh: Int
    let lat: Double
    let lon: Double
    let distM: Double

    var id: Double { tStart }
    var isBraking: Bool { kind == "braking" }
}

struct WeatherInfo: Decodable {
    /// ok | disabled | unavailable
    let status: String
    let message: String?
    let temperatureStartC: Double?
    let temperatureEndC: Double?
    let temperatureMinC: Double?
    let temperatureMaxC: Double?
    let precipitationMm: Double?
    let windMaxKmh: Int?
    let gustMaxKmh: Int?
    let condition: String?
    let conditionStart: String?
    let wet: Bool?
    let attribution: String?
}

struct LimitsInfo: Decodable {
    /// ok | disabled | unavailable | no_match | no_data
    let status: String
    let tagged: LimitTotals?
    let estimated: LimitTotals?
    let worst: WorstOver?
    let stretches: [LimitStretch]?
    /// Percent of the ride (by time) that was matched to a road with any limit, and with a limit written on the map.
    let matchedShare: Double?
    let taggedShare: Double?

    var isOk: Bool { status == "ok" }
}

struct LimitTotals: Decodable, Equatable {
    let seconds: Int
    let overSeconds: Int
    let notableSeconds: Int
    let overMetres: Int
    let overShare: Double?
}

struct WorstOver: Decodable, Equatable {
    let t: Double
    let overKmh: Int
    let kmh: Int
    let limitKmh: Int
    let name: String?
}

struct LimitStretch: Decodable, Identifiable, Equatable {
    let tStart: Double
    let tEnd: Double
    let limitKmh: Int
    let maxKmh: Int
    let maxOverKmh: Int
    let name: String?
    let distStartM: Double

    var id: Double { tStart }
}
