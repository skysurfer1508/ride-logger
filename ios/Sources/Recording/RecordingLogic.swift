import Foundation

// The recorder's pure rules: what a location fix is, which fixes count, how far a ride went, what to upload next. Foundation only (no
// CoreLocation, no UIKit), so all of it is unit-tested (Tests/RecordingLogicTests.swift). The CoreLocation glue is in RideRecorder.swift.

/// One location fix, as kept on the phone and uploaded.
struct LocationSample: Codable, Equatable {
    var timestamp: Date
    var latitude: Double
    var longitude: Double
    /// m/s. CoreLocation reports a negative number when the speed is unknown.
    var speed: Double
    var altitude: Double
    var horizontalAccuracy: Double
    /// Negative when the altitude is not valid.
    var verticalAccuracy: Double
    /// 0...1, or negative when unknown.
    var batteryLevel: Double
    /// How far off `speed` may be, in m/s (CoreLocation's speedAccuracy). Negative when unknown, which is also what rides saved by an older
    /// version of the app have.
    var speedAccuracy: Double = -1

    init(timestamp: Date, latitude: Double, longitude: Double, speed: Double, altitude: Double, horizontalAccuracy: Double,
         verticalAccuracy: Double, batteryLevel: Double, speedAccuracy: Double = -1) {
        self.timestamp = timestamp
        self.latitude = latitude
        self.longitude = longitude
        self.speed = speed
        self.altitude = altitude
        self.horizontalAccuracy = horizontalAccuracy
        self.verticalAccuracy = verticalAccuracy
        self.batteryLevel = batteryLevel
        self.speedAccuracy = speedAccuracy
    }

    // Written by hand: the synthesized decoder demands every key, and a ride recorded before `speedAccuracy` existed (and still waiting on the
    // phone to upload) has none. Without this its fixes would all be skipped as unreadable.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        timestamp = try c.decode(Date.self, forKey: .timestamp)
        latitude = try c.decode(Double.self, forKey: .latitude)
        longitude = try c.decode(Double.self, forKey: .longitude)
        speed = try c.decode(Double.self, forKey: .speed)
        altitude = try c.decode(Double.self, forKey: .altitude)
        horizontalAccuracy = try c.decode(Double.self, forKey: .horizontalAccuracy)
        verticalAccuracy = try c.decode(Double.self, forKey: .verticalAccuracy)
        batteryLevel = try c.decode(Double.self, forKey: .batteryLevel)
        speedAccuracy = try c.decodeIfPresent(Double.self, forKey: .speedAccuracy) ?? -1
    }
}

/// A ride on this phone: what identifies it, whose it is, and how much of it the server has.
struct TripRecord: Codable, Equatable {
    /// "<start time>#<8 random hex digits>": every uploaded point carries it and the trip marker's `start` repeats it. The server closes a ride
    /// from the marker by matching this text, and its ride table needs it to be unique across all users, hence the random part.
    var tripId: String
    var deviceId: String
    /// Only the account that started the ride may upload it (a sign-out and another person signing in must not hand it over).
    var ownerEmail: String
    var startedAt: Date
    /// Set when the rider stops; nil while recording (or when the app was closed mid-ride).
    var endedAt: Date?
    /// How many of this ride's samples the server has confirmed.
    var uploadedCount = 0
    var markerSent = false

    var isFinished: Bool { endedAt != nil }

    init(tripId: String, deviceId: String, ownerEmail: String, startedAt: Date, endedAt: Date? = nil, uploadedCount: Int = 0, markerSent: Bool = false) {
        self.tripId = tripId
        self.deviceId = deviceId
        self.ownerEmail = ownerEmail
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.uploadedCount = uploadedCount
        self.markerSent = markerSent
    }

    // Written by hand so a file saved by an older version of the app (without a newer field) still loads.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tripId = try c.decode(String.self, forKey: .tripId)
        deviceId = try c.decode(String.self, forKey: .deviceId)
        ownerEmail = try c.decode(String.self, forKey: .ownerEmail)
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        endedAt = try c.decodeIfPresent(Date.self, forKey: .endedAt)
        uploadedCount = try c.decodeIfPresent(Int.self, forKey: .uploadedCount) ?? 0
        markerSent = try c.decodeIfPresent(Bool.self, forKey: .markerSent) ?? false
    }

    static func makeId(start: Date, suffix: String) -> String {
        WireTime.string(start) + "#" + suffix
    }
}

enum WireTime {
    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// "2026-09-28T09:15:00Z": whole seconds, UTC, exactly how Overland writes timestamps.
    static func string(_ date: Date) -> String { formatter.string(from: date) }
    static func date(_ text: String) -> Date? { formatter.date(from: text) }
}

enum Geo {
    static let earthRadiusM = 6_371_000.0
    /// The server drops fixes worse than this, and jumps faster than this, before it measures a ride (app/geo.py). The live numbers use
    /// the same two rules so the screen and the website agree.
    static let maxAccuracyM = 50.0
    static let maxPlausibleSpeedMps = 80.0

    static func haversineM(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
        let p1 = lat1 * .pi / 180, p2 = lat2 * .pi / 180
        let dphi = (lat2 - lat1) * .pi / 180, dlambda = (lon2 - lon1) * .pi / 180
        let a = sin(dphi / 2) * sin(dphi / 2) + cos(p1) * cos(p2) * sin(dlambda / 2) * sin(dlambda / 2)
        return 2 * earthRadiusM * asin(min(1, a.squareRoot()))
    }
}

/// The running numbers of a ride, built one fix at a time in the order they arrive.
struct LiveStats: Equatable {
    private(set) var distanceM = 0.0
    private(set) var maxSpeedMps = 0.0
    /// Fixes that counted (good accuracy, no impossible jump).
    private(set) var acceptedCount = 0
    private(set) var receivedCount = 0
    private(set) var last: LocationSample?

    mutating func add(_ sample: LocationSample) {
        receivedCount += 1
        if sample.horizontalAccuracy < 0 || sample.horizontalAccuracy > Geo.maxAccuracyM { return }
        if let prev = last {
            let d = Geo.haversineM(lat1: prev.latitude, lon1: prev.longitude, lat2: sample.latitude, lon2: sample.longitude)
            let dt = sample.timestamp.timeIntervalSince(prev.timestamp)
            if dt > 0 && d / dt > Geo.maxPlausibleSpeedMps { return }
            distanceM += d
        }
        if sample.speed >= 0 { maxSpeedMps = max(maxSpeedMps, sample.speed) }
        acceptedCount += 1
        last = sample
    }

    static func from(_ samples: [LocationSample]) -> LiveStats {
        var stats = LiveStats()
        for s in samples { stats.add(s) }
        return stats
    }
}

enum RecordingLogic {
    /// iPhones in the open report a speed accurate to well under 1 m/s. A reading worse than this is not used as it is.
    static let maxTrustedSpeedAccuracyMps = 1.5
    /// Positions this good are worth working a speed out of when the reported one is not usable.
    static let goodPositionAccuracyM = 10.0
    /// Fixes further apart in time than this are not used to work out a speed.
    static let maxDerivedGapS = 5.0

    /// The speed to keep for a fix, in m/s. The phone's own speed comes from the GPS signal's Doppler shift (not from the accelerometer, and not from
    /// positions), and is the most precise thing there is, so it is used whenever it is valid and its stated accuracy is good. When it is missing
    /// (negative) or poor, in order: the speed between this fix and the previous one if both positions are accurate, else the previous speed carried
    /// on for a moment, else whatever was reported (0 if unknown). Never invents a speed from poor positions: that is worse than the poor reading.
    static func trustedSpeed(reported: Double, speedAccuracy: Double, horizontalAccuracy: Double, latitude: Double, longitude: Double,
                             at time: Date, previous: LocationSample?) -> Double {
        if reported >= 0 && (speedAccuracy < 0 || speedAccuracy <= maxTrustedSpeedAccuracyMps) { return reported }
        if let previous {
            let dt = time.timeIntervalSince(previous.timestamp)
            if dt > 0 && dt <= maxDerivedGapS {
                if horizontalAccuracy >= 0 && horizontalAccuracy <= goodPositionAccuracyM
                    && previous.horizontalAccuracy >= 0 && previous.horizontalAccuracy <= goodPositionAccuracyM {
                    return Geo.haversineM(lat1: previous.latitude, lon1: previous.longitude, lat2: latitude, lon2: longitude) / dt
                }
                return max(previous.speed, 0)
            }
        }
        return max(reported, 0)
    }

    /// The speed to show: a fix older than this means the bike has stopped (with a distance filter CoreLocation sends nothing while standing
    /// still, so the last reading would otherwise stay on screen at a red light).
    static let speedFreshSeconds = 4.0

    static func displayedSpeedKmh(latest: LocationSample?, now: Date) -> Int {
        guard let latest, now.timeIntervalSince(latest.timestamp) <= speedFreshSeconds else { return 0 }
        return Format.kmh(fromMps: latest.speed)
    }

    /// Average speed over the ride so far, km/h.
    static func averageKmh(distanceM: Double, elapsed: TimeInterval) -> Int {
        elapsed > 0 ? Int((distanceM / elapsed * 3.6).rounded()) : 0
    }

    /// GPS quality for the chip: the accuracy the phone reports, in words.
    enum GPSQuality: Equatable { case none, good, fair, weak }

    static func quality(of sample: LocationSample?, now: Date) -> GPSQuality {
        guard let sample, now.timeIntervalSince(sample.timestamp) <= 15 else { return .none }
        if sample.horizontalAccuracy < 0 { return .none }
        if sample.horizontalAccuracy <= 20 { return .good }
        return sample.horizontalAccuracy <= Geo.maxAccuracyM ? .fair : .weak
    }

    /// The numbers for the Lock Screen / Dynamic Island right now.
    static func snapshot(latest: LocationSample?, stats: LiveStats, now: Date) -> LiveSnapshot {
        let q = quality(of: latest, now: now)
        return LiveSnapshot(speedKmh: displayedSpeedKmh(latest: latest, now: now), distanceM: stats.distanceM,
                            maxKmh: Format.kmh(fromMps: stats.maxSpeedMps), gpsOK: q == .good || q == .fair)
    }

    /// Rides this short are not worth keeping: the rider pressed Start by mistake.
    static func isWorthKeeping(sampleCount: Int) -> Bool { sampleCount >= 2 }
}

enum UploadPlan {
    static let batchSize = 100

    /// The slice of samples to send next: everything after what the server has, at most `batchSize` of it.
    static func nextRange(total: Int, uploaded: Int, batchSize: Int = UploadPlan.batchSize) -> Range<Int> {
        let start = max(0, min(uploaded, total))
        let end = min(total, start + max(1, batchSize))
        return start..<end
    }

    /// Whether the batch ending at `range.upperBound` also carries the trip marker (the last batch of a finished ride, sent once).
    static func carriesMarker(range: Range<Int>, total: Int, finished: Bool, markerSent: Bool) -> Bool {
        finished && !markerSent && range.upperBound >= total
    }
}
