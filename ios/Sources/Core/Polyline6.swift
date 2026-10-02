import Foundation

/// Valhalla's encoded line (the polyline algorithm at 1e-6 degrees): a whole route in a few kilobytes. The server's `shape6`.
enum Polyline6 {
    /// The points of an encoded line. A damaged or cut-off string gives the points before the damage, never a crash or a half point.
    static func decode(_ text: String) -> [RoadPoint] {
        let bytes = Array(text.utf8)
        var index = 0
        var lat = 0, lon = 0
        var points: [RoadPoint] = []

        func nextValue() -> Int? {
            var shift = 0, result = 0
            while index < bytes.count {
                let byte = Int(bytes[index]) - 63
                index += 1
                guard byte >= 0, shift < 60 else { return nil }
                result |= (byte & 0x1F) << shift
                shift += 5
                if byte < 0x20 { return (result & 1) != 0 ? ~(result >> 1) : (result >> 1) }
            }
            return nil
        }

        while index < bytes.count {
            guard let dLat = nextValue(), let dLon = nextValue() else { break }
            lat += dLat
            lon += dLon
            points.append(RoadPoint(lat: Double(lat) / 1e6, lon: Double(lon) / 1e6))
        }
        return points
    }
}
