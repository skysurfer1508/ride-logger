import Foundation

/// The Traffic tab's decisions, free of MapKit and SwiftUI so they can be unit-tested (Tests/TrafficLogicTests.swift).
enum TrafficLogic {
    /// What was last asked of the server for one layer.
    struct Query: Equatable {
        var lat: Double
        var lon: Double
        var radiusKm: Double
        var at: Date
    }

    static func distanceKm(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
        Geo.haversineM(lat1: lat1, lon1: lon1, lat2: lat2, lon2: lon2) / 1000
    }

    /// A search radius that covers the visible map: half its diagonal, in whole kilometres, between 3 and 50 (the server's webcam limit).
    static func radiusKm(latSpan: Double, lonSpan: Double, atLat lat: Double) -> Double {
        let height = abs(latSpan) * 110.54
        let width = abs(lonSpan) * 111.32 * cos(lat * .pi / 180)
        let half = (height * height + width * width).squareRoot() / 2
        return min(max(half.rounded(), 3), 50)
    }

    /// Whether panning or zooming the map is enough to ask the server again: never asked, the answer is old, the map moved a good way (a quarter of
    /// the radius, at least 1 km), or the zoom changed a lot.
    static func needsRefresh(last: Query?, lat: Double, lon: Double, radiusKm: Double, now: Date, maxAge: TimeInterval = 120) -> Bool {
        guard let last else { return true }
        if now.timeIntervalSince(last.at) > maxAge { return true }
        if distanceKm(lat1: last.lat, lon1: last.lon, lat2: lat, lon2: lon) > max(1.0, last.radiusKm * 0.25) { return true }
        let ratio = radiusKm / max(last.radiusKm, 0.1)
        return ratio > 1.4 || ratio < 0.6
    }

    /// The feed lists about 1,700 long-running roadworks and lane closures next to a handful of jams, accidents and hazards. The map shows the
    /// second group by default and the works only when asked.
    static func visibleIncidents(_ incidents: [TrafficIncident], showWorks: Bool) -> [TrafficIncident] {
        showWorks ? incidents : incidents.filter { $0.incidentKind != .roadworks && $0.incidentKind != .closure }
    }

    /// "0.9 km" below 10 km, "12 km" above.
    static func distanceText(_ km: Double) -> String {
        km < 10 ? String(format: "%.1f km", km) : String(format: "%.0f km", km)
    }

    /// "Until 10:00" when the feed says when it ends, else "Since 08:10", else nil. Times are shown in the phone's time zone.
    static func validity(start: String?, end: String?) -> String? {
        if let end, let date = Format.parseISO(end) { return "Until \(Format.time(date))" }
        if let start, let date = Format.parseISO(start) { return "Since \(Format.time(date))" }
        return nil
    }

    /// The text for a severity word from the feed ("high" -> "High severity"); nil when unknown.
    static func severityText(_ severity: String?) -> String? {
        guard let word = severity?.trimmingCharacters(in: .whitespaces), !word.isEmpty else { return nil }
        return word.prefix(1).uppercased() + word.dropFirst().lowercased() + " severity"
    }

    /// The server's reason a layer is off, as a setup hint for the app.
    static func setupHint(layer: String) -> String {
        switch layer {
        case "incidents": return "Official Swiss traffic situations are not set up on your server yet. Add OPENTRANSPORTDATA_API_KEY to its .env file and restart it."
        case "webcams": return "Webcams are not set up on your server yet. Add WINDY_API_KEY to its .env file and restart it."
        default: return "This layer is not set up on your server."
        }
    }
}
