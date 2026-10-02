import Foundation

/// The four ways to ride from A to B.
enum RouteMode: String, CaseIterable, Identifiable {
    case ultraFast = "ultra_fast"
    case fast
    case relaxed
    case twisty

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ultraFast: return "Ultra fast"
        case .fast: return "Fast"
        case .relaxed: return "Relaxed"
        case .twisty: return "Twisty"
        }
    }

    /// One line on what the style means (the numbers behind it were measured on Swiss trips: see app/planner.py).
    var blurb: String {
        switch self {
        case .ultraFast: return "Motorways and main roads, the quickest way."
        case .fast: return "Quick, with a motorway only where it saves a lot."
        case .relaxed: return "No motorways and fewer turns: a calm ride, a bit longer."
        case .twisty: return "Steered through twisty roads, within the extra time you allow."
        }
    }

    var symbol: String {
        switch self {
        case .ultraFast: return "bolt.fill"
        case .fast: return "speedometer"
        case .relaxed: return "leaf.fill"
        case .twisty: return "arrow.triangle.swap"
        }
    }
}

/// A place the rider chose: an address, a shop, a spot dropped on the map.
struct Place: Codable, Equatable, Identifiable {
    var name: String
    var subtitle: String
    var lat: Double
    var lon: Double

    var id: String { String(format: "%.5f,%.5f", lat, lon) }
    /// "Hardstrasse 10, Zürich": the name and, when it adds something, where.
    var line: String { subtitle.isEmpty || name.contains(subtitle) ? name : "\(name), \(subtitle)" }
}

/// The places the rider used lately and the ones they pinned as Home and Work, kept on the phone.
struct PlaceStore {
    static let recentLimit = 8
    /// A place within this many metres of a recent one is the same place.
    static let sameSpotMetres = 60.0

    let defaults: UserDefaults
    private let recentKey = "ridelog.places.recent"
    private let savedKey = "ridelog.places.saved"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var recents: [Place] { read([Place].self, key: recentKey) ?? [] }
    /// "home" and "work".
    var saved: [String: Place] { read([String: Place].self, key: savedKey) ?? [:] }

    func addRecent(_ place: Place) {
        var list = recents.filter { Geo.haversineM(lat1: $0.lat, lon1: $0.lon, lat2: place.lat, lon2: place.lon) > Self.sameSpotMetres }
        list.insert(place, at: 0)
        write(Array(list.prefix(Self.recentLimit)), key: recentKey)
    }

    func removeRecent(_ place: Place) {
        write(recents.filter { $0.id != place.id }, key: recentKey)
    }

    func clearRecents() { defaults.removeObject(forKey: recentKey) }

    func save(_ place: Place?, as kind: String) {
        var all = saved
        all[kind] = place
        write(all, key: savedKey)
    }

    private func read<T: Decodable>(_ type: T.Type, key: String) -> T? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    private func write<T: Encodable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }
}

/// A place offered before the rider types anything: Home, Work (with that label) or a recent place (no label).
struct PlaceSuggestion: Identifiable, Equatable {
    var label: String?
    var place: Place
    var id: String { (label ?? "recent") + place.id }
}

/// What the trip screen decides, free of SwiftUI and MapKit so it can be unit-tested (Tests/TripLogicTests.swift).
enum TripLogic {
    static let maxStops = 5
    static let detourRange: ClosedRange<Double> = 5...120
    static let defaultDetour = 30.0
    static let detourStep = 5.0

    /// "+30 min" or "+1 h 15 min".
    static func detourText(minutes: Double) -> String {
        let m = Int(minutes.rounded())
        return m < 60 ? "+\(m) min" : (m % 60 == 0 ? "+\(m / 60) h" : "+\(m / 60) h \(m % 60) min")
    }

    /// The stops as the server reads them: start, the stops in between, finish.
    static func locationsJSON(start: (lat: Double, lon: Double), stops: [Place], finish: Place) -> String {
        let points = [(start.lat, start.lon)] + stops.map { ($0.lat, $0.lon) } + [(finish.lat, finish.lon)]
        return "[" + points.map { String(format: "{\"lat\":%.6f,\"lon\":%.6f}", $0.0, $0.1) }.joined(separator: ",") + "]"
    }

    static func tripForm(start: (lat: Double, lon: Double), stops: [Place], finish: Place, mode: RouteMode, detourMin: Double, pavedOnly: Bool,
                         alternatives: Bool, heading: Double? = nil) -> [String: String] {
        var form = ["locations": locationsJSON(start: start, stops: Array(stops.prefix(maxStops)), finish: finish), "mode": mode.rawValue,
                    "paved_only": pavedOnly ? "true" : "false",
                    "alternatives": alternatives && stops.isEmpty && mode != .twisty ? "2" : "0"]
        if mode == .twisty { form["detour_min"] = String(Int(min(max(detourMin, detourRange.lowerBound), detourRange.upperBound).rounded())) }
        if let heading, heading >= 0 { form["heading"] = String(Int(heading.rounded()) % 360) }
        return form
    }

    /// The same stops asked for again, with the turns (starting navigation, rerouting, a saved route).
    static func directionsForm(waypoints: [RouteWaypoint], mode: String, pavedOnly: Bool = true, heading: Double? = nil) -> [String: String] {
        let json = "[" + waypoints.map { String(format: "{\"lat\":%.6f,\"lon\":%.6f,\"type\":\"%@\"}", $0.lat, $0.lon, $0.type) }.joined(separator: ",") + "]"
        var form = ["locations": json, "mode": mode, "paved_only": pavedOnly ? "true" : "false"]
        if let heading, heading >= 0 { form["heading"] = String(Int(heading.rounded()) % 360) }
        return form
    }

    /// Whether there is enough to ask for a route.
    static func canPlan(finish: Place?, stops: [Place]) -> Bool { finish != nil && stops.count <= maxStops }

    /// "Home" / "Work" shortcuts first, then recents (newest first), with no place twice.
    static func suggestions(saved: [String: Place], recents: [Place]) -> [PlaceSuggestion] {
        var out: [PlaceSuggestion] = []
        if let home = saved["home"] { out.append(PlaceSuggestion(label: "Home", place: home)) }
        if let work = saved["work"] { out.append(PlaceSuggestion(label: "Work", place: work)) }
        for place in recents where !out.contains(where: { $0.place.id == place.id }) { out.append(PlaceSuggestion(label: nil, place: place)) }
        return out
    }
}
