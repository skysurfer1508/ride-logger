import Combine
import Foundation
import WatchConnectivity

/// The iPhone's end of the conversation with the Apple Watch app (RideLogWatch/). While a ride is recorded it sends the live numbers once a second, and keeps
/// the totals for the idle screen and the complication up to date; the Watch can ask it to start or stop the ride.
///
/// Nothing here is needed to record: with no Watch (or no Watch app installed) it does nothing. The Watch app is a separate target that the iPhone app neither
/// depends on nor embeds (see project.yml), so a problem with it can never stop this app from building.
@MainActor
final class WatchBridge: NSObject, ObservableObject, WCSessionDelegate {
    static let shared = WatchBridge()

    /// Whether the watch can be reached right now, for the Settings panel and the Record screen's chip.
    @Published private(set) var link: WatchLinkState = .starting
    /// The last time the watch said anything (a command, or an answer to the test).
    @Published private(set) var lastContact: Date?
    /// The raw answers iOS gives, for the Settings panel (so a surprising state can be understood).
    @Published private(set) var facts = ""
    @Published private(set) var testing = false
    @Published private(set) var testResult: String?

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
        refreshLink()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    // MARK: is the watch there?

    /// Reads what WatchConnectivity knows and turns it into one state.
    func refreshLink() {
        guard WCSession.isSupported() else {
            link = .unsupported
            return
        }
        let session = WCSession.default
        link = WatchLinkState.from(supported: true, activated: session.activationState == .activated, paired: session.isPaired, reachable: session.isReachable)
        facts = "iOS says: paired \(session.isPaired ? "yes" : "no"), watch app installed \(session.isWatchAppInstalled ? "yes" : "no") (not reliable for an app put on the watch from Xcode), reachable \(session.isReachable ? "yes" : "no")"
    }

    /// Sends the watch a ping and says whether and how fast it answered.
    func testConnection() {
        refreshLink()
        testResult = nil
        let session = WCSession.default
        guard session.activationState == .activated, session.isPaired else {
            testResult = link.detail
            return
        }
        guard session.isReachable else {
            testResult = "The watch cannot be reached. Open RideLog on the watch, keep the phone close, and try again."
            return
        }
        testing = true
        let started = Date()
        session.sendMessage([WatchKeys.ping: true], replyHandler: { _ in
            Task { @MainActor in
                self.testing = false
                self.lastContact = Date()
                self.testResult = String(format: "The watch answered in %.1f s.", Date().timeIntervalSince(started))
                self.refreshLink()
            }
        }, errorHandler: { _ in
            Task { @MainActor in
                self.testing = false
                self.testResult = "The watch did not answer. Open RideLog on the watch and try again."
                self.refreshLink()
            }
        })
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
        guard session.activationState == .activated, session.isPaired, let recorder else { return }
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

    /// A tap on the wrist for a turn or a corner. Only while the Watch app is reachable: with the Watch screen asleep it may not be, and a cue that arrives late is worse than none.
    func sendCue(_ cue: TurnCue) {
        guard WCSession.isSupported(), let kind = WatchCue.Kind(rawValue: cue.rawValue) else { return }
        let session = WCSession.default
        guard session.activationState == .activated, session.isPaired, session.isReachable else { return }
        session.sendMessage([WatchKeys.cue: WatchCue(kind: kind, sentAt: Date()).dictionary()], replyHandler: nil, errorHandler: nil)
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
            if let current = snapshot(now: Date()), WCSession.default.activationState == .activated, WCSession.default.isPaired {
                pushContext(current)
                lastContext = Date()
            }
        } catch {
            // the totals are a convenience: the live numbers and Start/Stop do not need them
        }
    }

    // MARK: what the Watch asks for

    private func handle(command raw: String?) async -> [String: Any] {
        lastContact = Date()
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

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor in self.refreshLink() }
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in self.refreshLink() }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in self.refreshLink() }
    }

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
