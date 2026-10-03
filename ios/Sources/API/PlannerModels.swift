import Foundation

// POST /api/v1/planner/loop and /planner/route, and the saved routes under /api/v1/planner/routes (app/routers/api_planner.py, app/planner.py). Foundation only:
// also compiled into the test target, and Tests/Fixtures/api_planner_*.json (written by the server's tests) lock the shapes decoded here.

struct PlanResponse: Decodable {
    /// "ok", "unavailable" (the routing service is off, down or busy) or "no_route" (nothing found: `message` says what to try).
    let status: String
    let message: String?
    let routes: [PlannedRoute]
    /// How many routes the server tried to find these.
    let tried: Int?
    /// False when the server has no twisty-road database: loops were still made, but not steered through twisty roads.
    let roadsData: Bool?
    /// Something the person should know about the answer (for example that a twisty trip fell back to the relaxed route).
    var note: String? = nil

    var isOk: Bool { status == "ok" }
}

struct PlannedRoute: Decodable, Identifiable, Equatable {
    let name: String
    let distanceKm: Double
    let durationMin: Int
    let twistyKm: Double
    /// 0 to 100, the same measure as the Roads layer.
    let twistiness: Int
    /// Percent of the route that goes back over road it already used.
    let retracedPct: Int
    /// Percent of the route on roads you have not ridden (100 when nothing is known about your rides).
    let newPct: Int
    let shape: [RoadPoint]
    /// "ultra_fast", "fast", "relaxed", "twisty" or "loop".
    var mode: String? = nil
    /// The stops that make the route: asking the server for them again gives the same route, with its turns.
    var waypoints: [RouteWaypoint]? = nil
    /// The route's full-resolution line, encoded (see Polyline6), and its turns: present when the route was asked for with directions.
    var shape6: String? = nil
    var maneuvers: [Maneuver]? = nil
    /// The sharp corners and hairpins along the line, for warnings (with directions only).
    var corners: [RouteCorner]? = nil

    var id: String { name }
}

/// A stop of a trip, as sent to and from the server.
struct RouteWaypoint: Codable, Equatable {
    var lat: Double
    var lon: Double
    /// "break" (a stop of the trip) or "through" (a point the route must pass without stopping).
    var type: String = "break"
}

/// One turn of a route (Valhalla's maneuver). `pre`, `alert` and `post` are the sentences meant to be spoken before, at and after it.
struct Maneuver: Decodable, Equatable {
    /// Valhalla's maneuver type code (see GuidanceText).
    let type: Int
    let instruction: String
    let pre: String
    let alert: String?
    let post: String?
    let street: String?
    let lengthM: Double
    let timeS: Double
    /// Metres from the start of the whole route to this maneuver.
    let alongM: Double
    let lat: Double
    let lon: Double
    /// Which stretch between stops it belongs to (0 for the first).
    let leg: Int
    let roundaboutExit: Int?
}

/// A sharp corner or hairpin on a planned route (app/corners.py).
struct RouteCorner: Decodable, Equatable {
    /// Metres from the start of the route to where the corner begins.
    let alongM: Double
    let lat: Double
    let lon: Double
    /// "left" or "right".
    let dir: String
    /// "sharp" or "hairpin".
    let kind: String
    let radiusM: Double
    let angleDeg: Double
    let lengthM: Double
    /// The speed a corner this tight is comfortably taken at, in km/h.
    let advisoryKmh: Int
    /// "start" for the first of three or more sharp corners close together, "in" for the others, nil for a corner on its own.
    let series: String?
}

/// POST /api/v1/planner/limits: where the tagged speed limit of the route changes (`kmh` nil where the map has none).
struct LimitChange: Decodable, Equatable {
    let alongM: Double
    let kmh: Int?
}

struct LimitsResponse: Decodable {
    let status: String
    let message: String?
    let limits: [LimitChange]?
}

/// Rain, snow, storm, ice or strong gusts ahead (`kind`), told as "In 12 kilometers, <label>".
struct RouteAlert: Decodable, Equatable {
    let alongM: Double
    let kind: String
    let label: String
}

/// The evening of a planned ride: clock times in the rider's time zone.
struct RouteLight: Decodable, Equatable {
    let sunset: String?
    let dusk: String?
    let darkMin: Int
}

struct RouteWeather: Decodable, Equatable {
    let temperatureMinC: Int
    let temperatureMaxC: Int
}

/// POST /api/v1/planner/conditions: what the ride will meet, with one spoken `summary`.
struct ConditionsResponse: Decodable {
    let status: String
    let message: String?
    let alerts: [RouteAlert]?
    let light: RouteLight?
    let summary: String?
    let weather: RouteWeather?
}

struct SavedRouteSummary: Decodable, Identifiable, Equatable {
    let id: Int
    let name: String
    /// "loop" or "route".
    let kind: String
    let distanceKm: Double
    let durationMin: Int
    let twistyKm: Double
    let twistiness: Int
    let createdAt: String
    var mode: String? = nil
}

struct SavedRoutesResponse: Decodable {
    let routes: [SavedRouteSummary]
}

struct SavedRouteDetail: Decodable, Equatable {
    let id: Int
    let name: String
    let kind: String
    let distanceKm: Double
    let durationMin: Int
    let twistyKm: Double
    let twistiness: Int
    let createdAt: String
    let shape: [RoadPoint]
    var mode: String? = nil
    var waypoints: [RouteWaypoint]? = nil
}

struct SavedRouteDetailResponse: Decodable {
    let route: SavedRouteDetail
}

/// The answer to saving a route.
struct SavedRouteResponse: Decodable {
    let route: SavedRouteSummary
}

struct DeletedRouteResponse: Decodable {
    let deleted: Int
}
