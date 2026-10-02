import Foundation

// The rules for starting and stopping a ride without a button press. Foundation only (no CoreLocation, no UIKit), so all of it is unit-tested
// (Tests/AutoStartLogicTests.swift). The platform side (Shortcuts intent, notifications, motion, audio route) is in AutoStartCoordinator.swift.

enum AutoStartMode: String, CaseIterable, Identifiable, Codable {
    case askFirst, silent

    var id: String { rawValue }
    var title: String { self == .askFirst ? "Ask me first" : "Start silently" }
}

struct SpeedReading: Equatable {
    let time: Date
    let kmh: Double
}

enum StartDecision: Equatable {
    /// Not enough yet: keep looking.
    case keepWatching
    /// Riding for long enough: start recording now.
    case start
    /// Riding for long enough, but the person wants to be asked.
    case askToStart
    /// Do not start, and stop looking. The text says why (it goes in the diary).
    case ignore(String)
}

enum AutoStartLogic {
    /// Moving at least this fast ...
    static let startSpeedKmh = 15.0
    /// ... for this long (every reading in the window must be at least that fast) counts as the start of a ride.
    static let startSustainedSeconds = 20.0
    /// Readings come about once a second; a window may fall this short of the full length and still count.
    static let windowSlackSeconds = 3.0
    /// Slower than this counts as standing still.
    static let stopSpeedKmh = 3.0
    /// A ride that was started automatically is ended after this long standing still (parked).
    static let stopIdleSeconds = 600.0
    /// How long the phone may look at the GPS after being woken by a movement before giving up (a tram ride must not drain the battery).
    static let probeMaxSeconds = 120.0
    /// After a Shortcuts start, if no location fix has arrived by then, a notification asks to tap and start (see AutoStartCoordinator).
    static let fixWatchdogSeconds = 25.0

    /// Decides from the recent speed readings (oldest first) whether this is the start of a ride.
    static func decideStart(readings: [SpeedReading], now: Date, helmetRequired: Bool, helmetPresent: Bool, mode: AutoStartMode) -> StartDecision {
        if helmetRequired && !helmetPresent { return .ignore("The helmet is not connected.") }
        let window = readings.filter { now.timeIntervalSince($0.time) <= startSustainedSeconds && $0.time <= now }.sorted { $0.time < $1.time }
        guard let first = window.first, let last = window.last,
              last.time.timeIntervalSince(first.time) >= startSustainedSeconds - windowSlackSeconds else { return .keepWatching }
        guard window.allSatisfy({ $0.kmh >= startSpeedKmh }) else { return .keepWatching }
        return mode == .silent ? .start : .askToStart
    }

    /// Whether the helmet is among the named audio devices (compared ignoring case and accents, as a part of the name: "Cardo" matches "Cardo PACKTALK").
    /// An empty helmet name never matches.
    static func helmetPresent(routeNames: [String], helmetName: String) -> Bool {
        let wanted = normalize(helmetName)
        guard !wanted.isEmpty else { return false }
        return routeNames.contains { normalize($0).contains(wanted) }
    }

    static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True once the bike has been still for the whole idle time.
    static func shouldAutoStop(lastMovingAt: Date, now: Date) -> Bool {
        now.timeIntervalSince(lastMovingAt) >= stopIdleSeconds
    }

    static func probeExpired(startedAt: Date, now: Date) -> Bool {
        now.timeIntervalSince(startedAt) >= probeMaxSeconds
    }

    /// Keeps only the readings of the last minute (the decision only ever looks at the last 20 seconds).
    static func pruned(_ readings: [SpeedReading], now: Date) -> [SpeedReading] {
        readings.filter { now.timeIntervalSince($0.time) <= 60 }
    }
}
