import Foundation

/// The map screen's arithmetic, kept free of MapKit and SwiftUI so it can be unit-tested (Tests/TrackMathTests.swift).
enum TrackMath {
    /// Same meaning as the server's GAP_S / GAP_MAX_MOVE_M (app/track.py): no fix for this long while barely moving is a rider standing still.
    static let standstillGapSeconds = 6.0
    static let standstillMaxMoveM = 20.0

    /// Where the rider is at one moment: a real fix, or a point between two.
    struct Sample: Equatable {
        var t: Double
        var lat: Double
        var lon: Double
        var mps: Double
        var dist: Double
        var altitude: Double?
        /// The fix at or before this moment.
        var index: Int

        var kmh: Int { Format.kmh(fromMps: mps) }

        init(_ p: TrackPoint, index: Int) {
            t = p.t; lat = p.lat; lon = p.lon; mps = p.mps; dist = p.dist; altitude = p.altitude; self.index = index
        }

        init(t: Double, lat: Double, lon: Double, mps: Double, dist: Double, altitude: Double?, index: Int) {
            self.t = t; self.lat = lat; self.lon = lon; self.mps = mps; self.dist = dist; self.altitude = altitude; self.index = index
        }
    }

    // MARK: finding a moment

    /// Index of the last fix at or before `time` (0 when `time` is before the first one). The points must be sorted by time.
    static func index(atOrBefore time: Double, in points: [TrackPoint]) -> Int {
        guard !points.isEmpty else { return 0 }
        var lo = 0, hi = points.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if points[mid].t <= time { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    /// Two fixes that are far apart in time but close in space: the phone sent nothing because the rider was standing still (the recorder's
    /// distance filter), so the bike did not drift from one to the other.
    static func isStandstill(_ a: TrackPoint, _ b: TrackPoint) -> Bool {
        b.t - a.t >= standstillGapSeconds && (b.dist - a.dist) < standstillMaxMoveM
    }

    /// The position and speed at `time`, between fixes interpolated in a straight line, except during a standstill, where the bike stays
    /// where it was at speed 0 (interpolating there would show it creeping along and the speed ramping up for no reason).
    static func sample(at time: Double, in points: [TrackPoint]) -> Sample? {
        guard let first = points.first, let last = points.last else { return nil }
        if time <= first.t { return Sample(first, index: 0) }
        if time >= last.t { return Sample(last, index: points.count - 1) }
        let i = index(atOrBefore: time, in: points)
        let a = points[i], b = points[i + 1]
        let span = b.t - a.t
        if span <= 0 { return Sample(a, index: i) }
        if isStandstill(a, b) {
            return Sample(t: time, lat: a.lat, lon: a.lon, mps: 0, dist: a.dist, altitude: a.altitude, index: i)
        }
        let f = (time - a.t) / span
        func mix(_ x: Double, _ y: Double) -> Double { x + (y - x) * f }
        var altitude: Double?
        if let x = a.altitude, let y = b.altitude { altitude = mix(x, y) } else { altitude = a.altitude ?? b.altitude }
        return Sample(t: time, lat: mix(a.lat, b.lat), lon: mix(a.lon, b.lon), mps: mix(a.mps, b.mps), dist: mix(a.dist, b.dist),
                      altitude: altitude, index: i)
    }

    /// The fix closest to a tapped spot, or nil if none is within `maxMeters`.
    static func nearestIndex(lat: Double, lon: Double, in points: [TrackPoint], maxMeters: Double = .infinity) -> Int? {
        let metersPerDegLat = 110_540.0
        let metersPerDegLon = 111_320.0 * cos(lat * .pi / 180)
        var best: Int?
        var bestSquared = Double.infinity
        for (i, p) in points.enumerated() {
            let dx = (p.lon - lon) * metersPerDegLon
            let dy = (p.lat - lat) * metersPerDegLat
            let squared = dx * dx + dy * dy
            if squared < bestSquared { bestSquared = squared; best = i }
        }
        guard let found = best, bestSquared.squareRoot() <= maxMeters else { return nil }
        return found
    }

    // MARK: colouring the route by speed

    /// 0 (under 15 km/h) ... 4 (100 km/h and more).
    static let bucketLimitsKmh: [Double] = [15, 40, 70, 100]

    static func speedBucket(kmh: Double) -> Int {
        bucketLimitsKmh.firstIndex { kmh < $0 } ?? bucketLimitsKmh.count
    }

    /// A run of the route drawn in one colour: the fixes `range` (both ends included, so neighbouring runs join up without a gap).
    struct Segment: Equatable {
        let bucket: Int
        let range: ClosedRange<Int>
    }

    /// Speeds averaged over a few neighbouring fixes, so one noisy reading doesn't cut the line into many tiny pieces.
    static func smoothedKmh(_ points: [TrackPoint], window: Int = 5) -> [Double] {
        guard !points.isEmpty else { return [] }
        let half = max(0, window / 2)
        return points.indices.map { i in
            let lo = max(0, i - half), hi = min(points.count - 1, i + half)
            let slice = points[lo...hi]
            return slice.reduce(0) { $0 + $1.kmh } / Double(slice.count)
        }
    }

    static func segments(_ points: [TrackPoint]) -> [Segment] {
        guard points.count > 1 else { return [] }
        let speeds = smoothedKmh(points)
        var out: [Segment] = []
        for i in 0..<(points.count - 1) {
            let bucket = speedBucket(kmh: (speeds[i] + speeds[i + 1]) / 2)
            if let last = out.last, last.bucket == bucket {
                out[out.count - 1] = Segment(bucket: bucket, range: last.range.lowerBound...(i + 1))
            } else {
                out.append(Segment(bucket: bucket, range: i...(i + 1)))
            }
        }
        return out
    }

    // MARK: stops

    static func stop(at time: Double, in stops: [RideStop]) -> RideStop? {
        stops.first { time >= $0.tStart && time <= $0.tEnd }
    }

    /// "3 stops · 2:10 standing" / "No stops".
    static func stopsSummary(count: Int, standingSeconds: Double) -> String {
        guard count > 0 else { return "No stops" }
        return "\(count) stop\(count == 1 ? "" : "s") · \(Format.clock(seconds: standingSeconds)) standing"
    }
}
