import Foundation

/// A route the rider has chosen to follow. Kept on the phone (a file) so it survives the app being closed mid-ride.
struct ActiveRoute: Codable, Equatable {
    var name: String
    var distanceKm: Double
    /// [lat, lon] pairs.
    var points: [[Double]]
    var savedAt: Date
}

/// Where the rider is along a planned route and how far from its line: just distances, no turn-by-turn. Free of MapKit so it can be unit-tested
/// (Tests/RouteFollowTests.swift).
enum RouteFollow {
    /// Further than this from the line is "off route".
    static let offRouteMetres = 100.0
    /// Normally only this many segments around the last known place are looked at (a figure-eight route crosses itself: the nearer crossing is not always the right one).
    static let forwardWindow = 150
    static let backwardWindow = 12
    /// At the start of a loop the start and the end are the same place: among places this close to the nearest, the earliest along the route wins.
    static let tieMetres = 25.0
    private static let metresPerDegree = 111_194.9266

    struct Line: Equatable {
        let lat: [Double]
        let lon: [Double]
        /// Metres along the route at each point.
        let cumulative: [Double]
        var total: Double { cumulative.last ?? 0 }
        var segmentCount: Int { max(0, lat.count - 1) }
    }

    struct Progress: Equatable {
        /// Metres from the start, measured along the route, at the nearest point of the line.
        var alongM: Double
        /// Metres from the rider to that nearest point.
        var offRouteM: Double
        var remainingM: Double
        var fraction: Double
        /// The segment of the line the rider is on; pass it back as `hint` for the next position.
        var segment: Int
        var isOffRoute: Bool
    }

    /// nil unless there are at least two valid points.
    static func line(_ points: [[Double]]) -> Line? {
        let valid = points.filter { $0.count >= 2 && $0[0].isFinite && $0[1].isFinite && abs($0[0]) <= 90 && abs($0[1]) <= 180 }
        guard valid.count >= 2 else { return nil }
        var cumulative = [0.0]
        for i in 1..<valid.count {
            cumulative.append(cumulative[i - 1] + Geo.haversineM(lat1: valid[i - 1][0], lon1: valid[i - 1][1], lat2: valid[i][0], lon2: valid[i][1]))
        }
        return Line(lat: valid.map { $0[0] }, lon: valid.map { $0[1] }, cumulative: cumulative)
    }

    /// The nearest point of segment `i` to the position: (metres away, metres along the whole route).
    static func nearest(on line: Line, segment i: Int, lat: Double, lon: Double) -> (distance: Double, along: Double) {
        let cosLat = cos(line.lat[i] * .pi / 180)
        let bx = (line.lon[i + 1] - line.lon[i]) * cosLat * metresPerDegree
        let by = (line.lat[i + 1] - line.lat[i]) * metresPerDegree
        let px = (lon - line.lon[i]) * cosLat * metresPerDegree
        let py = (lat - line.lat[i]) * metresPerDegree
        let lengthSquared = bx * bx + by * by
        let t = lengthSquared > 0 ? min(1, max(0, (px * bx + py * by) / lengthSquared)) : 0
        let dx = px - t * bx, dy = py - t * by
        return ((dx * dx + dy * dy).squareRoot(), line.cumulative[i] + t * (line.cumulative[i + 1] - line.cumulative[i]))
    }

    private static func best(on line: Line, segments: ClosedRange<Int>, lat: Double, lon: Double) -> (segment: Int, distance: Double, along: Double) {
        var result = (segment: segments.lowerBound, distance: Double.infinity, along: 0.0)
        var candidates: [(segment: Int, distance: Double, along: Double)] = []
        for i in segments {
            let n = nearest(on: line, segment: i, lat: lat, lon: lon)
            candidates.append((i, n.distance, n.along))
            if n.distance < result.distance { result = (i, n.distance, n.along) }
        }
        // among places about as near as the nearest, the one earliest along the route
        let close = candidates.filter { $0.distance <= result.distance + tieMetres }
        if let earliest = close.min(by: { $0.along < $1.along }) { result = earliest }
        return result
    }

    /// Where the rider is on the route. `hint` is the segment from the last call: it keeps the answer moving forward along the route instead of jumping to
    /// another part that merely passes close by. If the rider is not near the line within that window, the whole route is searched (they have rejoined it elsewhere).
    static func progress(lat: Double, lon: Double, on line: Line, hint: Int? = nil) -> Progress {
        let last = line.segmentCount - 1
        var found: (segment: Int, distance: Double, along: Double)?
        if let hint, last >= 0 {
            let lower = max(0, min(last, hint) - backwardWindow)
            let upper = min(last, max(0, hint) + forwardWindow)
            let local = best(on: line, segments: lower...upper, lat: lat, lon: lon)
            if local.distance <= offRouteMetres * 2 { found = local }
        }
        let chosen = found ?? best(on: line, segments: 0...max(0, last), lat: lat, lon: lon)
        let total = line.total
        return Progress(alongM: chosen.along, offRouteM: chosen.distance, remainingM: max(0, total - chosen.along), fraction: total > 0 ? min(1, chosen.along / total) : 0,
                        segment: chosen.segment, isOffRoute: chosen.distance > offRouteMetres)
    }
}

/// The active route in a file, so it is still there after the app has been closed.
struct ActiveRouteFile {
    let url: URL

    static var standard: ActiveRouteFile {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return ActiveRouteFile(url: base.appendingPathComponent("ridelog-active-route.json"))
    }

    func load() -> ActiveRoute? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let route = try? decoder.decode(ActiveRoute.self, from: data), RouteFollow.line(route.points) != nil else { return nil }
        return route
    }

    func save(_ route: ActiveRoute) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(route) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    func clear() {
        try? FileManager.default.removeItem(at: url)
    }
}
