import Foundation
import WatchConnectivity

/// The iPhone's end of the conversation with the Apple Watch app (RideLogWatch/). While a ride is recorded it sends the live numbers once a second, and keeps
/// the totals for the idle screen and the complication up to date; the Watch can ask it to start or stop the ride.
///
/// Nothing here is needed to record: with no Watch (or no Watch app installed) it does nothing. The Watch app is a separate target that the iPhone app neither
/// depends on nor embeds (see project.yml), so a problem with it can never stop this app from building.
@MainActor
final class WatchBridge: NSObject, WCSessionDelegate {
    static let shared = WatchBridge()

    private var recorder: RideRecorder?
    private var timer: Timer?
    private var activated = false
    private var lastLive: Date?
    private var lastContext: Date?
    private var lastRecording = false
    private var stats: WatchStats?

    func activate(recorder: RideRecorder) {
        guard WCSession.isSupported(), !activated else { return }
        activated = true
        self.recorder = recorder
        let session = WCSession.default
        session.delegate = self
        session.activate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    // MARK: sending

    private func snapshot(now: Date) -> WatchSnapshot? {
        guard let recorder else { return nil }
        let recording = recorder.isRecording
        let live = recorder.liveSnapshot
        return WatchSnapshot(recording: recording, speedKmh: recording ? live.speedKmh : 0, distanceM: recording ? live.distanceM : 0, maxKmh: recording ? live.maxKmh : 0,
                             gpsOK: live.gpsOK, startedAt: recorder.rideStartedAt, sentAt: now)
    }

    private func tick() {
        let session = WCSession.default
        guard session.activationState == .activated, session.isWatchAppInstalled, let recorder else { return }
        let now = Date()
        let recording = recorder.isRecording
        let changed = recording != lastRecording
        guard let current = snapshot(now: now) else { return }
        if (recording || changed), session.isReachable, WatchPolicy.shouldSendLive(last: lastLive, now: now, stateChanged: changed) {
            session.sendMessage([WatchKeys.snapshot: current.dictionary()], replyHandler: nil, errorHandler: nil)
            lastLive = now
        }
        if WatchPolicy.shouldSendContext(last: lastContext, now: now, stateChanged: changed, recording: recording) {
            pushContext(current)
            lastContext = now
        }
        lastRecording = recording
    }

    private func pushContext(_ snapshot: WatchSnapshot) {
        var context: [String: Any] = [WatchKeys.snapshot: snapshot.dictionary()]
        if let stats { context[WatchKeys.stats] = stats.dictionary() }
        try? WCSession.default.updateApplicationContext(context)
    }

    /// Fetches this week's distance and the last ride from the server and hands them to the Watch. Called when the app comes forward and when rides change.
    func refreshStats(api: APIClient) async {
        guard WCSession.isSupported(), activated else { return }
        do {
            let home: HomeResponse = try await api.get("home")
            stats = WatchStats(weekKm: home.weekKm ?? 0, lastRideKm: home.latest?.distanceKm, lastRideAt: home.latest.flatMap { Format.parseISO($0.startTime) }, updatedAt: Date())
            if let current = snapshot(now: Date()), WCSession.default.activationState == .activated, WCSession.default.isWatchAppInstalled {
                pushContext(current)
                lastContext = Date()
            }
        } catch {
            // the totals are a convenience: the live numbers and Start/Stop do not need them
        }
    }

    // MARK: what the Watch asks for

    private func handle(command raw: String?) async -> [String: Any] {
        guard let raw, let command = WatchCommand(rawValue: raw), let recorder else {
            return [WatchKeys.ok: false, WatchKeys.text: "RideLog did not understand that."]
        }
        let coordinator = AppServices.shared.autoStart
        switch command {
        case .start:
            let text = await coordinator.startFromIntent(trigger: "watch")
            tick()
            return [WatchKeys.ok: recorder.isRecording, WatchKeys.text: text]
        case .stop:
            guard recorder.isRecording else { return [WatchKeys.ok: true, WatchKeys.text: "Not recording."] }
            recorder.stop()
            coordinator.record("watch", "stopped from the watch")
            tick()
            return [WatchKeys.ok: true, WatchKeys.text: "Ride stopped."]
        }
    }

    // MARK: WCSessionDelegate

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {}

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()                      // the user switched to another Apple Watch
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        let raw = message[WatchKeys.command] as? String
        Task { @MainActor in
            let answer = await self.handle(command: raw)
            replyHandler(answer)
        }
    }
}
