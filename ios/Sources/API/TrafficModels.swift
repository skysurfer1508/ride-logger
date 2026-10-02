import Foundation

// GET /api/v1/traffic/* (app/routers/api_v1.py, app/traffic.py). Foundation only: also compiled into the test target, and
// Tests/Fixtures/api_traffic_*.json (written by the server's tests) lock the shapes decoded here.

/// Which Traffic-tab layers the server has keys for. (Apple's traffic colours need no key.)
struct TrafficConfig: Decodable, Equatable {
    let incidents: Bool
    let webcams: Bool
}

/// An accident, congestion, roadworks or closure from the official Swiss traffic situations feed.
struct TrafficIncident: Decodable, Identifiable, Hashable {
    let id: String
    /// accident | congestion | roadworks | closure | hazard | other
    let kind: String
    let title: String
    let severity: String?
    let comment: String
    let road: String?
    /// ISO timestamps from the feed.
    let start: String?
    let end: String?
    let lat: Double
    let lon: Double
    let distanceKm: Double

    var incidentKind: IncidentKind { IncidentKind(serverKind: kind) }
}

struct IncidentsResponse: Decodable {
    let incidents: [TrafficIncident]
    /// Situations the feed describes without a map position (they cannot be shown on the map).
    let unlocated: Int
    let total: Int
}

struct TrafficWebcam: Decodable, Identifiable, Hashable {
    let id: String
    let title: String
    let lat: Double
    let lon: Double
    /// A picture link that expires after about 15 minutes, so it is shown once and never stored.
    let preview: String?
    let detailUrl: String?
    let playerUrl: String?
    /// "traffic" (a camera Windy files under traffic) or "city" (a city camera: it may or may not show a street).
    let category: String
    let distanceKm: Double

    var isTrafficCamera: Bool { category == "traffic" }
}

struct WebcamsResponse: Decodable {
    let webcams: [TrafficWebcam]
}

enum IncidentKind: Equatable {
    case accident, congestion, roadworks, closure, hazard, other

    init(serverKind: String) {
        switch serverKind {
        case "accident": self = .accident
        case "congestion": self = .congestion
        case "roadworks": self = .roadworks
        case "closure": self = .closure
        case "hazard": self = .hazard
        default: self = .other
        }
    }

    /// SF Symbols that exist on iOS 17.
    var symbol: String {
        switch self {
        case .accident: return "exclamationmark.triangle.fill"
        case .congestion: return "car.2.fill"
        case .roadworks: return "hammer.fill"
        case .closure: return "nosign"
        case .hazard: return "exclamationmark.octagon.fill"
        case .other: return "info.circle.fill"
        }
    }
}
