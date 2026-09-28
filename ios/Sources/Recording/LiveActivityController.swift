import ActivityKit
import Foundation

/// Keeps the Lock Screen / Dynamic Island Live Activity in step with the ride being recorded. If Live Activities are off or unavailable nothing
/// happens and recording works exactly the same.
@MainActor
final class LiveActivityController {
    private var activity: Activity<RideActivityAttributes>?
    private var lastPush = Date.distantPast

    /// The system limits how often an app may update a Live Activity, so pushes are spaced out (the running timer needs none).
    static let minInterval: TimeInterval = 3
    /// If the app stops updating (it crashed or was killed), the system marks the activity stale after this long and the widget shows dashes
    /// instead of a frozen speed.
    static let staleAfter: TimeInterval = 20

    static var isAvailable: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    /// A Live Activity from an earlier run (the app was killed mid-ride) would keep showing frozen numbers: end it.
    static func endLeftovers() {
        for leftover in Activity<RideActivityAttributes>.activities {
            Task { await leftover.end(nil, dismissalPolicy: .immediate) }
        }
    }

    func start(startedAt: Date, snapshot: LiveSnapshot) {
        Self.endLeftovers()
        guard Self.isAvailable else { return }
        let content = ActivityContent(state: snapshot, staleDate: Date().addingTimeInterval(Self.staleAfter))
        activity = try? Activity.request(attributes: RideActivityAttributes(startedAt: startedAt), content: content, pushType: nil)
        lastPush = Date()
    }

    func update(_ snapshot: LiveSnapshot) {
        guard let activity, Date().timeIntervalSince(lastPush) >= Self.minInterval else { return }
        lastPush = Date()
        let content = ActivityContent(state: snapshot, staleDate: Date().addingTimeInterval(Self.staleAfter))
        Task { await activity.update(content) }
    }

    func end() {
        guard let running = activity else { return }
        activity = nil
        Task { await running.end(nil, dismissalPolicy: .immediate) }
    }
}
