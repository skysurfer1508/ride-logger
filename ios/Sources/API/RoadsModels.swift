import Foundation

// GET /api/v1/roads (app/routers/api_roads.py, app/roads.py). Foundation only: also compiled into the test target, and Tests/Fixtures/api_roads.json
// (written by the server's tests) locks the shape decoded here.

struct RoadsResponse: Decodable {
    /// "ok", or "not_built" when nobody has built the road database on the server.
    let status: String
    let roads: [TwistyRoad]
    /// True when the box held more roads than were sent (the best ones are).
    let truncated: Bool
    /// "ok", "updating" (your rides are still being matched to roads: ask again in a moment) or "unavailable" (`ridden` is nil).
    let riddenStatus: String
    let pendingRides: Int?
    let attribution: String

    var isBuilt: Bool { status == "ok" }
}

struct TwistyRoad: Decodable, Identifiable, Equatable {
    let id: Int
    let wayId: Int
    let name: String?
    let ref: String?
    /// OpenStreetMap's road class: primary, secondary, tertiary, unclassified.
    let highway: String
    let surface: String?
    let paved: Bool
    let maxspeed: Int?
    let lengthM: Int
    /// Metres of the stretch that are bendy, and that as a 0 to 100 share of its length.
    let curvyM: Int
    let score: Int
    let geometry: [RoadPoint]
    /// Nil when the server cannot tell (no map matcher).
    let ridden: Bool?
}

/// One point of a road's line, sent as [lat, lon].
struct RoadPoint: Decodable, Equatable {
    let lat: Double
    let lon: Double

    init(lat: Double, lon: Double) {
        self.lat = lat
        self.lon = lon
    }

    init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        lat = try c.decode(Double.self)
        lon = try c.decode(Double.self)
    }
}
