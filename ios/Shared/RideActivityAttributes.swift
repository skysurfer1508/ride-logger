import ActivityKit
import Foundation

/// The Live Activity (Lock Screen banner and Dynamic Island) of a ride being recorded. Compiled into both the app and the widget extension.
struct RideActivityAttributes: ActivityAttributes {
    typealias ContentState = LiveSnapshot

    /// When the ride started; the timer on screen counts up from here without the app having to send anything.
    var startedAt: Date
}
