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

    var id: String { name }
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
