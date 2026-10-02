import Foundation

/// What the ride screen says about the insights, kept free of SwiftUI so it can be unit-tested (Tests/InsightsLogicTests.swift).
enum InsightsLogic {
    /// UserDefaults key of the Settings switch for speed against the limit (it is private to the person, so it can be hidden).
    static let showLimitsKey = "showSpeedLimits"

    // MARK: roads

    /// The road at `time`: the last name change at or before it. Nil before the first name is known, or without any.
    static func roadName(at time: Double, in names: [RoadName]) -> String? {
        var found: String?
        for entry in names {
            if entry.t <= time { found = entry.name } else { break }
        }
        return found
    }

    // MARK: finding places on the track

    /// The fixes from `from` to `to` seconds (both ends included, a fix before and after so the line has no gap), for drawing a stretch on the map.
    static func points(from start: Double, to end: Double, in points: [TrackPoint]) -> [TrackPoint] {
        guard points.count >= 2, end >= start else { return [] }
        let first = TrackMath.index(atOrBefore: start, in: points)
        var last = TrackMath.index(atOrBefore: end, in: points)
        if last + 1 < points.count && points[last].t < end { last += 1 }
        return Array(points[first...last])
    }

    /// The moment the rider had covered `metres` (for tapping the elevation chart). Clamped to the ride.
    static func time(atDistance metres: Double, in points: [TrackPoint]) -> Double? {
        guard let first = points.first, let last = points.last else { return nil }
        if metres <= first.dist { return first.t }
        if metres >= last.dist { return last.t }
        var lo = 0, hi = points.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if points[mid].dist <= metres { lo = mid } else { hi = mid - 1 }
        }
        let a = points[lo], b = points[min(lo + 1, points.count - 1)]
        let span = b.dist - a.dist
        return span <= 0 ? a.t : a.t + (b.t - a.t) * (metres - a.dist) / span
    }

    /// The stretch over the limit that contains `time`, if any.
    static func stretch(at time: Double, in stretches: [LimitStretch]) -> LimitStretch? {
        stretches.first { $0.tStart <= time && time <= $0.tEnd }
    }

    // MARK: words

    /// "2:00 over the limit, 43 % of the time on roads with a limit on the map".
    static func overLimitSummary(_ totals: LimitTotals) -> String {
        guard totals.seconds > 0 else { return "No road with a limit written on the map." }
        guard totals.overSeconds > 0 else { return "Never over the limit on roads with a limit on the map." }
        let share = totals.overShare.map { String(format: "%.0f %%", $0) } ?? "-"
        return "\(Format.clock(seconds: Double(totals.overSeconds))) over the limit, \(share) of the time on roads with a limit on the map."
    }

    /// "+10 km/h on Hardstrasse (90 in an 80 zone)".
    static func worstText(_ worst: WorstOver) -> String {
        let road = worst.name.map { " on \($0)" } ?? ""
        return "+\(worst.overKmh) km/h\(road) (\(worst.kmh) in a \(worst.limitKmh) zone)"
    }

    /// Why a part has nothing to show, in words for the person. Nil when it is "ok".
    static func limitsStatusText(_ status: String) -> String? {
        switch status {
        case "ok": return nil
        case "disabled": return "Speed against the limit is switched off on the server."
        case "unavailable": return "The map service is not answering right now. Pull down to try again."
        case "no_match": return "This track could not be matched to roads, so there are no limits to compare with."
        case "no_data": return "This ride is too short."
        default: return "Speed against the limit is not available for this ride."
        }
    }

    /// "12° to 16°", or one number when it did not change by a degree.
    static func temperatureText(_ weather: WeatherInfo) -> String? {
        guard let low = weather.temperatureMinC, let high = weather.temperatureMaxC else { return weather.temperatureStartC.map { "\(Int($0.rounded()))°" } }
        let l = Int(low.rounded()), h = Int(high.rounded())
        return l == h ? "\(l)°" : "\(l)° to \(h)°"
    }

    /// "Rain 1.5 mm" or "Dry".
    static func rainText(_ weather: WeatherInfo) -> String {
        guard let mm = weather.precipitationMm else { return weather.wet == true ? "Wet" : "Dry" }
        return mm >= 0.1 ? String(format: "Rain %.1f mm", mm) : (weather.wet == true ? "Wet" : "Dry")
    }

    /// An SF Symbol for the worst condition of the ride.
    static func weatherSymbol(_ weather: WeatherInfo) -> String {
        let text = (weather.condition ?? "").lowercased()
        if text.contains("thunder") { return "cloud.bolt.rain.fill" }
        if text.contains("snow") { return "cloud.snow.fill" }
        if text.contains("rain") || text.contains("shower") || text.contains("drizzle") { return "cloud.rain.fill" }
        if text.contains("fog") { return "cloud.fog.fill" }
        if text.contains("overcast") { return "cloud.fill" }
        if text.contains("partly") { return "cloud.sun.fill" }
        return "sun.max.fill"
    }

    /// "Braking from 90 to 11 km/h".
    static func eventText(_ event: SmoothnessEvent) -> String {
        "\(event.isBraking ? "Hard braking" : "Hard acceleration") from \(event.fromKmh) to \(event.toKmh) km/h"
    }

    /// A one-word reading of the 0 to 100 smoothness score.
    static func scoreWord(_ score: Int) -> String {
        switch score {
        case 85...: return "Very smooth"
        case 70..<85: return "Smooth"
        case 50..<70: return "Lively"
        default: return "Hard"
        }
    }
}
