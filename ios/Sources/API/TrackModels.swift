import Foundation

// GET /api/v1/rides/{id}/track (app/routers/api_v1.py, app/track.py). Foundation only: also compiled into the test target, and
// Tests/Fixtures/api_track.json (written by the server's tests) locks the shape decoded here.

/// One GPS fix. The server sends it as a compact array: [seconds since start, lat, lon, speed m/s, altitude or null, metres so far].
struct TrackPoint: Decodable, Equatable {
    let t: Double
    let lat: Double
    let lon: Double
    let mps: Double
    let altitude: Double?
    let dist: Double

    var kmh: Double { mps * 3.6 }

    init(t: Double, lat: Double, lon: Double, mps: Double, altitude: Double? = nil, dist: Double) {
        self.t = t
        self.lat = lat
        self.lon = lon
        self.mps = mps
        self.altitude = altitude
        self.dist = dist
    }

    init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        t = try c.decode(Double.self)
        lat = try c.decode(Double.self)
        lon = try c.decode(Double.self)
        mps = try c.decode(Double.self)
        if try c.decodeNil() {                                               // decodeNil only consumes the element when it is null
            altitude = nil
        } else {
            altitude = try c.decode(Double.self)
        }
        dist = try c.decode(Double.self)
    }
}

struct TopSpeed: Decodable, Equatable {
    let t: Double
    let mps: Double
    let lat: Double
    let lon: Double
    var kmh: Int { Format.kmh(fromMps: mps) }
}

/// A time the rider stood still (a light, a sign, a crossing, or just traffic).
struct RideStop: Decodable, Identifiable, Hashable {
    let tStart: Double
    let tEnd: Double
    let durationS: Double
    let lat: Double
    let lon: Double
    let distFromStartM: Double
    /// The server's classification: traffic_light, stop_sign, rail_crossing, give_way, other, unknown.
    let kind: String
    let label: String

    var id: Double { tStart }
    var stopKind: StopKind { StopKind(serverKind: kind) }
}

enum StopKind: Equatable {
    case trafficLight, stopSign, railCrossing, crossing, traffic, unknown

    init(serverKind: String) {
        switch serverKind {
        case "traffic_light": self = .trafficLight
        case "stop_sign": self = .stopSign
        case "rail_crossing": self = .railCrossing
        case "give_way": self = .crossing
        case "other": self = .traffic
        default: self = .unknown
        }
    }
}

struct TrackResponse: Decodable {
    let ride: RideSummary
    /// ISO timestamp of the first fix (nil with no points).
    let start: String?
    let durationS: Double
    let distanceM: Double
    let points: [TrackPoint]
    let maxSpeed: TopSpeed?
    let stops: [RideStop]
    let stoppedS: Double
    let pointCount: Int
    /// "ok" when stops were matched against OpenStreetMap, "unavailable" when the lookup failed (stops are then plain "Stop").
    let featuresStatus: String?
}
