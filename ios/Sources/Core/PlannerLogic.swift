import Foundation

/// The route planner's words and request building, free of SwiftUI so they can be unit-tested (Tests/PlannerLogicTests.swift).
enum PlannerLogic {
    static let minKm = 20.0
    static let maxKm = 400.0
    static let stepKm = 10.0
    static let defaultKm = 100.0
    /// A loop that doubles back over this much of its road is worth a warning.
    static let retraceWarningPct = 15

    /// "45 min", "2 h", "3 h 17 min".
    static func durationText(minutes: Int) -> String {
        let m = max(0, minutes)
        if m < 60 { return "\(m) min" }
        return m % 60 == 0 ? "\(m / 60) h" : "\(m / 60) h \(m % 60) min"
    }

    static func kmText(_ km: Double) -> String {
        km < 100 ? String(format: "%.1f km", km) : String(format: "%.0f km", km)
    }

    /// "121 km, 3 h 17 min, 25 km of it twisty".
    static func summary(distanceKm: Double, durationMin: Int, twistyKm: Double) -> String {
        "\(kmText(distanceKm)) · \(durationText(minutes: durationMin)) · \(kmText(twistyKm)) twisty"
    }

    static func summary(_ route: PlannedRoute) -> String {
        summary(distanceKm: route.distanceKm, durationMin: route.durationMin, twistyKm: route.twistyKm)
    }

    static func summary(_ route: SavedRouteSummary) -> String {
        summary(distanceKm: route.distanceKm, durationMin: route.durationMin, twistyKm: route.twistyKm)
    }

    /// A warning when much of the route is the same road twice (a valley with no other way back), else nil.
    static func retraceWarning(_ route: PlannedRoute) -> String? {
        route.retracedPct >= retraceWarningPct ? "Goes back over \(route.retracedPct)% of its own road: there may be no other way round here." : nil
    }

    /// How much of the route is new to you, when that is known to be interesting.
    static func newText(_ route: PlannedRoute) -> String? {
        route.newPct < 100 ? "\(route.newPct)% roads you have not ridden" : nil
    }

    /// What to tell the person when planning did not give routes (nil when it did).
    static func problem(_ response: PlanResponse) -> String? {
        if response.isOk { return response.routes.isEmpty ? "No route came back." : nil }
        if let message = response.message, !message.isEmpty { return message }
        return response.status == "unavailable" ? "The routing service is not available right now." : "No route could be found."
    }

    /// Something the person can read in the saved list: "Loop, 2 Oct".
    static func defaultName(kind: String, km: Double, now: Date, calendar: Calendar = .current) -> String {
        let day = calendar.component(.day, from: now)
        let month = calendar.shortMonthSymbols[calendar.component(.month, from: now) - 1]
        return "\(kind == "loop" ? "Loop" : "Route") \(Int(km.rounded())) km, \(day) \(month)"
    }

    // MARK: requests

    static func loopForm(lat: Double, lon: Double, km: Double, avoidMotorways: Bool, pavedOnly: Bool, preferNew: Bool) -> [String: String] {
        ["lat": String(format: "%.5f", lat), "lon": String(format: "%.5f", lon), "distance_km": String(Int(min(max(km, minKm), maxKm).rounded())),
         "avoid_motorways": avoidMotorways ? "true" : "false", "paved_only": pavedOnly ? "true" : "false", "prefer_new": preferNew ? "true" : "false"]
    }

    /// The form that saves a planned route: its line as JSON text (the server works out the length and twistiness itself).
    static func saveForm(name: String, kind: String, route: PlannedRoute) -> [String: String] {
        let shape = "[" + route.shape.map { String(format: "[%.5f,%.5f]", $0.lat, $0.lon) }.joined(separator: ",") + "]"
        var form = ["name": name, "kind": kind, "shape": shape, "duration_s": String(route.durationMin * 60)]
        if let waypoints = route.waypoints, !waypoints.isEmpty {                         // so the saved route can be navigated later
            form["waypoints"] = TripLogic.directionsForm(waypoints: waypoints, mode: route.mode ?? "loop")["locations"]
            if let mode = route.mode { form["mode"] = mode }
        }
        return form
    }

    // MARK: following

    static func activeRoute(from route: PlannedRoute, name: String, now: Date) -> ActiveRoute {
        // the full-resolution line when the route has one: following (and later navigating) is only as exact as the line
        let line = route.shape6.map { Polyline6.decode($0) }.flatMap { $0.count >= 2 ? $0 : nil } ?? route.shape
        return ActiveRoute(name: name, distanceKm: route.distanceKm, points: line.map { [$0.lat, $0.lon] }, savedAt: now)
    }

    static func activeRoute(from saved: SavedRouteDetail, now: Date) -> ActiveRoute {
        ActiveRoute(name: saved.name, distanceKm: saved.distanceKm, points: saved.shape.map { [$0.lat, $0.lon] }, savedAt: now)
    }

    /// "31.2 of 118 km", or "118 km to go" at the very start.
    static func progressText(_ progress: RouteFollow.Progress, totalKm: Double) -> String {
        let done = progress.alongM / 1000
        return done < 0.1 ? "\(kmText(totalKm)) to ride" : String(format: "%.1f of %.0f km", done, totalKm)
    }

    /// "On the route" or "Off the route by 340 m".
    static func offRouteText(_ progress: RouteFollow.Progress) -> String {
        guard progress.isOffRoute else { return "On the route" }
        let m = Int(progress.offRouteM.rounded())
        return m >= 1000 ? String(format: "Off the route by %.1f km", progress.offRouteM / 1000) : "Off the route by \(m) m"
    }
}
