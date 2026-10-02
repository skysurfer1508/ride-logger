import Foundation

/// What travels between the iPhone app and the Apple Watch app (WatchConnectivity). Foundation only: compiled into the phone app, the Watch app, the
/// Watch complication and the unit tests. Everything is sent as property-list dictionaries, which is all WatchConnectivity carries.
enum WatchKeys {
    /// In a message from the Watch: what it wants (a WatchCommand's raw value).
    static let command = "cmd"
    /// In a message or application context from the phone: the live ride numbers.
    static let snapshot = "snapshot"
    /// In the application context from the phone: the totals for the idle screen and the complication.
    static let stats = "stats"
    /// In the phone's answer to a command.
    static let ok = "ok"
    static let text = "text"
}

enum WatchCommand: String {
    case start
    case stop
}

/// The ride in progress, as the Watch shows it.
struct WatchSnapshot: Equatable {
    var recording: Bool
    var speedKmh: Int
    var distanceM: Double
    var maxKmh: Int
    /// False while the phone has no fresh, usable GPS fix.
    var gpsOK: Bool
    /// When the ride started (the Watch draws the running timer from it); nil when not recording.
    var startedAt: Date?
    /// When the phone made this snapshot: a recording snapshot much older than this is not to be believed.
    var sentAt: Date

    func dictionary() -> [String: Any] {
        var out: [String: Any] = ["recording": recording, "speed": speedKmh, "distance": distanceM, "max": maxKmh, "gps": gpsOK, "sent": sentAt.timeIntervalSince1970]
        if let startedAt { out["started"] = startedAt.timeIntervalSince1970 }
        return out
    }

    init(recording: Bool, speedKmh: Int, distanceM: Double, maxKmh: Int, gpsOK: Bool, startedAt: Date?, sentAt: Date) {
        self.recording = recording
        self.speedKmh = speedKmh
        self.distanceM = distanceM
        self.maxKmh = maxKmh
        self.gpsOK = gpsOK
        self.startedAt = startedAt
        self.sentAt = sentAt
    }

    init?(dictionary d: [String: Any]) {
        guard let recording = d["recording"] as? Bool, let speed = (d["speed"] as? NSNumber)?.intValue, let distance = (d["distance"] as? NSNumber)?.doubleValue,
              let max = (d["max"] as? NSNumber)?.intValue, let gps = d["gps"] as? Bool, let sent = (d["sent"] as? NSNumber)?.doubleValue else { return nil }
        self.init(recording: recording, speedKmh: speed, distanceM: distance, maxKmh: max, gpsOK: gps,
                  startedAt: (d["started"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }, sentAt: Date(timeIntervalSince1970: sent))
    }

    var distanceText: String { distanceM < 100_000 ? String(format: "%.1f", distanceM / 1000) : String(format: "%.0f", distanceM / 1000) }
}

/// The totals the idle screen and the complication show.
struct WatchStats: Equatable {
    var weekKm: Double
    var lastRideKm: Double?
    var lastRideAt: Date?
    var updatedAt: Date

    func dictionary() -> [String: Any] {
        var out: [String: Any] = ["week": weekKm, "updated": updatedAt.timeIntervalSince1970]
        if let lastRideKm { out["lastKm"] = lastRideKm }
        if let lastRideAt { out["lastAt"] = lastRideAt.timeIntervalSince1970 }
        return out
    }

    init(weekKm: Double, lastRideKm: Double?, lastRideAt: Date?, updatedAt: Date) {
        self.weekKm = weekKm
        self.lastRideKm = lastRideKm
        self.lastRideAt = lastRideAt
        self.updatedAt = updatedAt
    }

    init?(dictionary d: [String: Any]) {
        guard let week = (d["week"] as? NSNumber)?.doubleValue, let updated = (d["updated"] as? NSNumber)?.doubleValue else { return nil }
        self.init(weekKm: week, lastRideKm: (d["lastKm"] as? NSNumber)?.doubleValue, lastRideAt: (d["lastAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) },
                  updatedAt: Date(timeIntervalSince1970: updated))
    }
}

/// How often the phone talks to the Watch, and how far to believe what it said.
enum WatchPolicy {
    /// A live message at most this often (the Watch screen changes once a second at most).
    static let liveInterval: TimeInterval = 1
    /// The application context (what the Watch has at hand when it wakes) is refreshed this often while recording, and when the state changes.
    static let contextInterval: TimeInterval = 5
    /// While idle the context only needs refreshing now and then (the totals change when a ride ends, which is a state change anyway).
    static let idleContextInterval: TimeInterval = 300
    /// A snapshot that says "recording" but is older than this means the phone has gone quiet (app killed, out of range): the Watch says so instead of showing a frozen speed.
    static let staleAfter: TimeInterval = 12

    static func shouldSendLive(last: Date?, now: Date, stateChanged: Bool) -> Bool {
        guard let last else { return true }
        return stateChanged || now.timeIntervalSince(last) >= liveInterval
    }

    static func shouldSendContext(last: Date?, now: Date, stateChanged: Bool, recording: Bool = true) -> Bool {
        guard let last else { return true }
        return stateChanged || now.timeIntervalSince(last) >= (recording ? contextInterval : idleContextInterval)
    }

    static func isStale(_ snapshot: WatchSnapshot, now: Date) -> Bool {
        snapshot.recording && now.timeIntervalSince(snapshot.sentAt) > staleAfter
    }

    /// "Thu 2 Oct" style short day for the last ride, in the Watch's calendar.
    static func dayText(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) { return "Yesterday" }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = calendar.locale ?? .current
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("EEE d MMM")
        return formatter.string(from: date)
    }

    static func kmText(_ km: Double) -> String { km < 100 ? String(format: "%.1f", km) : String(format: "%.0f", km) }
}

/// The totals in the Watch's own shared storage (an App Group), so the complication, a separate process, can read what the Watch app received.
struct WatchStatsStore {
    static let suiteName = "group.com.skyserver1508.ridelogger.watch"
    private static let key = "ridelog.watch.stats"
    let defaults: UserDefaults

    /// nil when the App Group is not available (the complication then shows dashes; nothing breaks).
    static func shared() -> WatchStatsStore? {
        UserDefaults(suiteName: suiteName).map { WatchStatsStore(defaults: $0) }
    }

    func save(_ stats: WatchStats) {
        defaults.set(stats.dictionary(), forKey: Self.key)
    }

    func load() -> WatchStats? {
        (defaults.dictionary(forKey: Self.key)).flatMap { WatchStats(dictionary: $0) }
    }
}
