import Foundation

/// What the Lock Screen and the Dynamic Island show of a ride in progress. Foundation only: compiled into the app, the widget extension and the
/// tests. (The ride's start time is not here: the system draws the running timer itself from RideActivityAttributes.startedAt.)
struct LiveSnapshot: Codable, Hashable {
    /// Current speed in whole km/h; 0 when no fix has arrived for a few seconds (the bike is standing still).
    var speedKmh: Int
    var distanceM: Double
    var maxKmh: Int
    /// False while there is no fresh, usable GPS fix.
    var gpsOK: Bool

    /// "12.4" below 100 km, "123" from 100 km on: short enough for the Dynamic Island's compact trailing slot.
    var distanceCompact: String {
        distanceM < 100_000 ? String(format: "%.1f", distanceM / 1000) : String(format: "%.0f", distanceM / 1000)
    }

    /// "12.4" always, for the larger displays.
    var distanceKm: String { String(format: "%.1f", distanceM / 1000) }
}
