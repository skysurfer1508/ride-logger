import Foundation
import WatchConnectivity
import WatchKit
import WidgetKit

/// The Watch's end of the conversation with the iPhone app: it receives the live ride numbers and the totals, and sends Start and Stop. The iPhone stays the only
/// recorder (GPS on the wrist would flatten the Watch battery in a couple of hours); the Watch is a remote control and a glanceable display.
@MainActor
final class WatchSession: NSObject, ObservableObject {
    static let shared = WatchSession()

    @Published private(set) var snapshot: WatchSnapshot?
    @Published private(set) var stats: WatchStats?
    @Published private(set) var reachable = false
    @Published private(set) var busy = false
    @Published private(set) var message: String?

    private var activated = false

    func activate() {
        guard WCSession.isSupported(), !activated else { return }
        activated = true
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    /// Asks the iPhone to start or stop the ride. It answers with a sentence, shown as it is.
    func send(_ command: WatchCommand) {
        let session = WCSession.default
        guard session.isReachable else {
            message = "Your iPhone is out of reach. Keep it close, with RideLog installed."
            WKInterfaceDevice.current().play(.failure)
            return
        }
        busy = true
        message = nil
        session.sendMessage([WatchKeys.command: command.rawValue], replyHandler: { reply in
            Task { @MainActor in
                self.busy = false
                self.message = reply[WatchKeys.text] as? String
                if (reply[WatchKeys.ok] as? Bool) != true { WKInterfaceDevice.current().play(.failure) }
            }
        }, errorHandler: { _ in
            Task { @MainActor in
                self.busy = false
                self.message = "The iPhone did not answer. Open RideLog on it once, then try again."
                WKInterfaceDevice.current().play(.failure)
            }
        })
    }

    private func apply(_ payload: [String: Any]) {
        if let dictionary = payload[WatchKeys.snapshot] as? [String: Any], let new = WatchSnapshot(dictionary: dictionary) {
            if let old = snapshot, old.recording != new.recording {
                WKInterfaceDevice.current().play(new.recording ? .start : .stop)
            }
            snapshot = new
        }
        if let dictionary = payload[WatchKeys.stats] as? [String: Any], let new = WatchStats(dictionary: dictionary) {
            stats = new
            WatchStatsStore.shared()?.save(new)
            WidgetCenter.shared.reloadAllTimelines()
        }
    }
}

extension WatchSession: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        let reachable = session.isReachable
        let context = session.receivedApplicationContext
        Task { @MainActor in
            self.reachable = reachable
            self.apply(context)
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in self.reachable = reachable }
    }

    /// A live message from the iPhone, once a second while recording.
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        Task { @MainActor in self.apply(message) }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        Task { @MainActor in self.apply(applicationContext) }
    }
}
