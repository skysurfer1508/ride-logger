import Foundation

/// The Roads layer's decisions, free of MapKit and SwiftUI so they can be unit-tested (Tests/RoadsLogicTests.swift).
enum RoadsLogic {
    /// The most the server answers for in one request (app/roads.py MAX_LAT_SPAN / MAX_LON_SPAN).
    static let maxLatSpan = 1.0
    static let maxLonSpan = 1.5
    /// Ask for a box this much bigger than the screen, so a small pan does not need a new answer.
    static let margin = 1.6
    static let maxAge: TimeInterval = 300

    struct Box: Equatable {
        var south: Double
        var west: Double
        var north: Double
        var east: Double

        var latSpan: Double { north - south }
        var lonSpan: Double { east - west }

        func contains(_ other: Box) -> Bool {
            other.south >= south && other.north <= north && other.west >= west && other.east <= east
        }
    }

    struct Fetched: Equatable {
        var box: Box
        var at: Date
    }

    static func box(centerLat: Double, centerLon: Double, latSpan: Double, lonSpan: Double) -> Box {
        Box(south: max(-90, centerLat - abs(latSpan) / 2), west: max(-180, centerLon - abs(lonSpan) / 2),
            north: min(90, centerLat + abs(latSpan) / 2), east: min(180, centerLon + abs(lonSpan) / 2))
    }

    /// Whether the screen shows little enough map to ask for roads (zoomed out over a whole country there are far too many).
    static func canQuery(_ visible: Box) -> Bool {
        visible.latSpan > 0 && visible.lonSpan > 0 && visible.latSpan <= maxLatSpan / margin && visible.lonSpan <= maxLonSpan / margin
    }

    /// The box to ask for: the screen with a margin around it, never more than the server accepts.
    static func queryBox(for visible: Box) -> Box {
        let latSpan = min(visible.latSpan * margin, maxLatSpan)
        let lonSpan = min(visible.lonSpan * margin, maxLonSpan)
        return box(centerLat: (visible.south + visible.north) / 2, centerLon: (visible.west + visible.east) / 2, latSpan: latSpan, lonSpan: lonSpan)
    }

    /// Ask again when nothing was fetched yet, the answer is old, the screen has moved outside what was fetched, or zoomed in so far that the fetched
    /// box is more than 4 times too big (the best roads of a big box can all be elsewhere).
    static func needsRefresh(last: Fetched?, visible: Box, now: Date) -> Bool {
        guard let last else { return true }
        if now.timeIntervalSince(last.at) > maxAge { return true }
        if !last.box.contains(visible) { return true }
        return last.box.latSpan > visible.latSpan * margin * 4
    }

    // MARK: words

    /// "Klausenstrasse (17)", "Klausenstrasse", "17", or "Road without a name".
    static func title(_ road: TwistyRoad) -> String {
        switch (road.name, road.ref) {
        case let (name?, ref?): return "\(name) (\(ref))"
        case let (name?, nil): return name
        case let (nil, ref?): return ref
        default: return "Road without a name"
        }
    }

    static func lengthText(_ metres: Int) -> String {
        metres < 1000 ? "\(metres) m" : String(format: "%.1f km", Double(metres) / 1000)
    }

    /// How twisty a 0 to 100 score is, in a word.
    static func scoreWord(_ score: Int) -> String {
        switch score {
        case 85...: return "Very twisty"
        case 65..<85: return "Twisty"
        case 45..<65: return "Lively"
        default: return "Gentle bends"
        }
    }

    static func highwayText(_ highway: String) -> String {
        switch highway {
        case "primary": return "Main road"
        case "secondary": return "Secondary road"
        case "tertiary": return "Minor road"
        case "unclassified": return "Minor road"
        default: return "Road"
        }
    }

    static func riddenText(_ ridden: Bool?) -> String {
        switch ridden {
        case .some(true): return "You have ridden this"
        case .some(false): return "Not ridden yet"
        case .none: return "Not known whether you have ridden this"
        }
    }

    /// "12 stretches in view (8 not ridden yet)", with the reasons the list may be short or unfinished.
    static func summary(_ response: RoadsResponse, shown: Int) -> String {
        guard response.isBuilt else { return "The twisty-road database has not been built on your server yet." }
        if shown == 0 { return "No twisty roads in view. Move the map or zoom out a little." }
        var text = "\(shown) twisty stretch\(shown == 1 ? "" : "es") in view"
        if response.riddenStatus == "ok" {
            text += " (\(response.roads.filter { $0.ridden == false }.count) not ridden yet)"
        } else if response.riddenStatus == "updating" {
            text += ", working out which you have ridden…"
        }
        if response.truncated { text += ". Zoom in to see more." }
        return text
    }

    /// The roads to draw: all of them, or only the ones not ridden yet (a road whose status is unknown stays visible).
    static func visible(_ roads: [TwistyRoad], onlyUnridden: Bool) -> [TwistyRoad] {
        onlyUnridden ? roads.filter { $0.ridden != true } : roads
    }

    /// The point halfway along a road's line, where its badge sits.
    static func midpoint(_ road: TwistyRoad) -> RoadPoint? {
        road.geometry.isEmpty ? nil : road.geometry[road.geometry.count / 2]
    }

    /// An Apple Maps link to the middle of the road.
    static func mapsURL(_ road: TwistyRoad) -> URL? {
        guard let mid = midpoint(road) else { return nil }
        var parts = URLComponents(string: "https://maps.apple.com/")
        parts?.queryItems = [URLQueryItem(name: "ll", value: String(format: "%.5f,%.5f", mid.lat, mid.lon)), URLQueryItem(name: "q", value: title(road))]
        return parts?.url
    }
}
