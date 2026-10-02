import AVFoundation
import CoreLocation
import CoreMotion
import SwiftUI
import UserNotifications

/// Starts and stops recording without the app being open. Three ways in, all written to the diary (Settings > Auto-start):
///   1. A Shortcuts automation ("when the helmet connects") runs StartRideIntent. iOS may not let a background intent keep the GPS running, so a
///      notification is scheduled at the same moment ("tap to start") and cancelled when the first fix arrives: if the start worked nobody sees it,
///      if it did not, the phone shows it even though the app was stopped.
///   2. Motion fallback (needs "Always" location): a significant movement wakes the app, the GPS is watched for up to two minutes, and a ride that
///      looks like riding (15 km/h for 20 s, with the helmet connected if that is required) is started, or offered in a notification.
///   3. A tap on the notification, or the Watch.
/// What can and cannot work with a locked phone is only known by trying: the diary exists so the result is visible.
@MainActor
final class AutoStartCoordinator: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let promptId = "ridelog.autostart.prompt"
    static let askId = "ridelog.autostart.ask"
    static let categoryId = "ridelog.autostart.category"
    static let startActionId = "ridelog.autostart.start"

    private enum Keys {
        static let enabled = "autostart.motion"
        static let mode = "autostart.mode"
        static let helmet = "autostart.helmet"
        static let requireHelmet = "autostart.requireHelmet"
        static let autoStop = "autostart.autoStop"
    }

    @Published private(set) var entries: [AutoStartLogEntry] = []
    @Published private(set) var probing = false
    @Published var motionEnabled: Bool { didSet { defaults.set(motionEnabled, forKey: Keys.enabled); applyArming() } }
    @Published var mode: AutoStartMode { didSet { defaults.set(mode.rawValue, forKey: Keys.mode) } }
    @Published var helmetName: String { didSet { defaults.set(helmetName, forKey: Keys.helmet) } }
    @Published var requireHelmet: Bool { didSet { defaults.set(requireHelmet, forKey: Keys.requireHelmet) } }
    @Published var autoStopEnabled: Bool { didSet { defaults.set(autoStopEnabled, forKey: Keys.autoStop) } }
    @Published private(set) var notificationsAllowed = false

    private let recorder: RideRecorder
    private let store: AutoStartLogStore
    private let defaults: UserDefaults
    private let manager = CLLocationManager()
    private let activity = CMMotionActivityManager()
    private var readings: [SpeedReading] = []
    private var probeStartedAt: Date?
    private var lastMovingAt = Date()
    private var autoStopTimer: Timer?
    private var attemptStartedAt: Date?
    private var promptScheduled = false

    init(recorder: RideRecorder, defaults: UserDefaults = .standard, store: AutoStartLogStore = AutoStartLogStore()) {
        self.recorder = recorder
        self.defaults = defaults
        self.store = store
        motionEnabled = defaults.bool(forKey: Keys.enabled)
        mode = AutoStartMode(rawValue: defaults.string(forKey: Keys.mode) ?? "") ?? .askFirst
        helmetName = defaults.string(forKey: Keys.helmet) ?? ""
        requireHelmet = defaults.object(forKey: Keys.requireHelmet) as? Bool ?? true
        autoStopEnabled = defaults.object(forKey: Keys.autoStop) as? Bool ?? true
        super.init()
        entries = store.entries(limit: 30)
        recorder.onFix = { [weak self] sample in self?.fixArrived(sample) }
        refreshNotificationPermission()
    }

    // MARK: launch

    /// Called when the app process starts (also when iOS relaunched it in the background after a significant movement).
    func applicationDidLaunch() {
        manager.delegate = self
        applyArming()
    }

    private func applyArming() {
        manager.delegate = self
        if motionEnabled && manager.authorizationStatus == .authorizedAlways {
            manager.pausesLocationUpdatesAutomatically = false
            manager.startMonitoringSignificantLocationChanges()
        } else {
            manager.stopMonitoringSignificantLocationChanges()
            stopProbing()
        }
    }

    // MARK: 1. the Shortcuts intent (Bluetooth automation, Siri, Action button)

    /// Returns the sentence the intent answers with.
    func startFromIntent(trigger: String) async -> String {
        defer { refreshEntries() }
        if recorder.isRecording {
            record(trigger, "already recording")
            return "RideLog is already recording."
        }
        guard recorder.uploader.credentials != nil else {
            record(trigger, "not started", "This phone is not signed in to RideLog yet.")
            return "Open RideLog once and sign in first."
        }
        if recorder.interrupted != nil {
            recorder.finishInterrupted()
            record(trigger, "closed an earlier ride that was cut off", "It was finished at its last fix and uploaded.")
        }
        guard recorder.isAuthorized else {
            record(trigger, "not started", "Location permission is not given.")
            return "Allow location for RideLog first."
        }
        attemptStartedAt = Date()
        scheduleFallbackPrompt()
        recorder.start(automatic: true)
        guard recorder.isRecording else {
            cancelFallbackPrompt()
            record(trigger, "could not start", "The recorder refused to start.")
            return "RideLog could not start recording."
        }
        lastMovingAt = Date()
        armAutoStop()
        record(trigger, "started, waiting for the first fix", "location permission: \(permissionName); audio: \(routeDescription())")
        return "Recording started."
    }

    func stopFromIntent() async -> String {
        defer { refreshEntries() }
        guard recorder.isRecording else { return "RideLog is not recording." }
        recorder.stop()
        record("stop", "stopped by shortcut")
        return "Ride stopped."
    }

    // MARK: first fix, the prompt that was waiting, auto-stop

    private func fixArrived(_ sample: LocationSample) {
        if sample.speed * 3.6 >= AutoStartLogic.stopSpeedKmh { lastMovingAt = sample.timestamp }
        guard let began = attemptStartedAt else { return }
        attemptStartedAt = nil
        cancelFallbackPrompt()
        record("shortcut", "first location fix", String(format: "%.0f s after the start", Date().timeIntervalSince(began)))
        refreshEntries()
    }

    private func armAutoStop() {
        autoStopTimer?.invalidate()
        guard autoStopEnabled else { return }
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in Task { @MainActor in self?.autoStopTick() } }
        RunLoop.main.add(timer, forMode: .common)
        autoStopTimer = timer
    }

    private func autoStopTick() {
        guard recorder.isRecording, recorder.startedAutomatically, autoStopEnabled else {
            autoStopTimer?.invalidate()
            autoStopTimer = nil
            return
        }
        if AutoStartLogic.shouldAutoStop(lastMovingAt: lastMovingAt, now: Date()) {
            recorder.stop()
            autoStopTimer?.invalidate()
            autoStopTimer = nil
            record("stop", "stopped automatically", "The bike stood still for 10 minutes.")
            post(title: "Ride finished", body: "RideLog stopped recording after 10 minutes without moving. The ride is being uploaded.")
            refreshEntries()
        }
    }

    // MARK: 2. motion fallback

    private func handle(_ locations: [CLLocation]) {
        guard motionEnabled, !recorder.isRecording else {
            stopProbing()
            return
        }
        guard probing else {
            beginProbingIfRiding()
            return
        }
        let now = Date()
        for l in locations where l.horizontalAccuracy >= 0 && l.speed >= 0 { readings.append(SpeedReading(time: l.timestamp, kmh: l.speed * 3.6)) }
        readings = AutoStartLogic.pruned(readings, now: now)
        if let started = probeStartedAt, AutoStartLogic.probeExpired(startedAt: started, now: now) {
            stopProbing()
            record("motion", "gave up", "No ride-like movement within two minutes.")
            refreshEntries()
            return
        }
        switch AutoStartLogic.decideStart(readings: readings, now: now, helmetRequired: requireHelmet,
                                          helmetPresent: AutoStartLogic.helmetPresent(routeNames: audioNames(), helmetName: helmetName), mode: mode) {
        case .keepWatching:
            break
        case .ignore(let why):
            stopProbing()
            record("motion", "ignored", why + " audio: \(routeDescription())")
            refreshEntries()
        case .start:
            stopProbing()
            startAutomatically(trigger: "motion")
        case .askToStart:
            stopProbing()
            record("motion", "asked", "A notification asks whether to start.")
            post(title: "Riding?", body: "It looks like you started riding. Tap to start recording.", id: Self.askId, withActions: true)
            refreshEntries()
        }
    }

    private func beginProbingIfRiding() {
        guard CMMotionActivityManager.isActivityAvailable() else { startProbing(reason: "motion data unavailable"); return }
        activity.queryActivityStarting(from: Date().addingTimeInterval(-300), to: Date(), to: .main) { [weak self] activities, _ in
            let automotive = activities?.last(where: { $0.confidence != .low })?.automotive
            Task { @MainActor in
                guard let self else { return }
                if automotive == false {
                    self.record("motion", "movement ignored", "The phone's motion sensor says you are not in a vehicle.")
                    self.refreshEntries()
                } else {
                    self.startProbing(reason: automotive == true ? "vehicle motion detected" : "motion permission not given, checking speed instead")
                }
            }
        }
    }

    private func startProbing(reason: String) {
        guard !probing else { return }
        probing = true
        probeStartedAt = Date()
        readings = []
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.allowsBackgroundLocationUpdates = true
        manager.startUpdatingLocation()
        record("motion", "watching the GPS", reason)
        refreshEntries()
    }

    private func stopProbing() {
        guard probing else { return }
        probing = false
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
        probeStartedAt = nil
        readings = []
    }

    // MARK: 3. notification taps, Watch

    func handleNotification(identifier: String, action: String) {
        guard identifier == Self.promptId || identifier == Self.askId else { return }
        if action == UNNotificationDismissActionIdentifier || action == "ridelog.autostart.ignore" {
            record("notification", "dismissed")
            refreshEntries()
            return
        }
        startAutomatically(trigger: "notification")
    }

    func startFromWatch() -> String {
        guard !recorder.isRecording else { return "Already recording." }
        startAutomatically(trigger: "watch")
        return recorder.isRecording ? "Recording started." : "Could not start."
    }

    private func startAutomatically(trigger: String) {
        guard !recorder.isRecording else { return }
        if recorder.interrupted != nil { recorder.finishInterrupted() }
        recorder.start(automatic: true)
        if recorder.isRecording {
            lastMovingAt = Date()
            armAutoStop()
            record(trigger, "started", "location permission: \(permissionName)")
        } else {
            record(trigger, "could not start", "Location permission or sign-in is missing.")
        }
        refreshEntries()
    }

    // MARK: notifications

    func requestNotificationPermission() {
        let center = UNUserNotificationCenter.current()
        let start = UNNotificationAction(identifier: Self.startActionId, title: "Start recording", options: [.foreground])
        let ignore = UNNotificationAction(identifier: "ridelog.autostart.ignore", title: "Not now", options: [])
        center.setNotificationCategories([UNNotificationCategory(identifier: Self.categoryId, actions: [start, ignore], intentIdentifiers: [], options: [])])
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            Task { @MainActor in self?.notificationsAllowed = granted }
        }
    }

    private func refreshNotificationPermission() {
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            let allowed = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
            Task { @MainActor in self?.notificationsAllowed = allowed }
        }
    }

    private func scheduleFallbackPrompt() {
        let content = UNMutableNotificationContent()
        content.title = "RideLog"
        content.body = "Recording did not start by itself. Tap to start."
        content.sound = .default
        content.categoryIdentifier = Self.categoryId
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: AutoStartLogic.fixWatchdogSeconds, repeats: false)
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: Self.promptId, content: content, trigger: trigger))
        promptScheduled = true
    }

    private func cancelFallbackPrompt() {
        guard promptScheduled else { return }
        promptScheduled = false
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [Self.promptId])
        center.removeDeliveredNotifications(withIdentifiers: [Self.promptId])
    }

    private func post(title: String, body: String, id: String = UUID().uuidString, withActions: Bool = false) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if withActions { content.categoryIdentifier = Self.categoryId }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)))
    }

    // MARK: audio route (is the helmet connected?)

    /// Names of the audio devices iOS reports right now. A classic Bluetooth helmet only appears here while audio is routed to it, so this is
    /// best-effort: the diary records what was seen at each start, so a helmet that never shows up can be told apart from one that does.
    func audioNames() -> [String] {
        let session = AVAudioSession.sharedInstance()
        let route = session.currentRoute
        return Array(Set(route.outputs.map(\.portName) + route.inputs.map(\.portName) + (session.availableInputs ?? []).map(\.portName))).sorted()
    }

    /// For the "look for my helmet" button: also lets iOS list Bluetooth hands-free devices (changes the app's audio category, nothing is played).
    func detectAudioDevices() -> [String] {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetooth, .allowBluetoothA2DP])
        return audioNames()
    }

    private func routeDescription() -> String {
        let names = audioNames()
        return names.isEmpty ? "none" : names.joined(separator: ", ")
    }

    // MARK: diary

    func record(_ trigger: String, _ outcome: String, _ detail: String = "") {
        store.append(trigger: trigger, outcome: outcome, detail: detail)
    }

    func refreshEntries() { entries = store.entries(limit: 30) }

    func clearLog() {
        store.clear()
        entries = []
    }

    private var permissionName: String {
        switch manager.authorizationStatus {
        case .authorizedAlways: return "always"
        case .authorizedWhenInUse: return "while using"
        case .denied, .restricted: return "denied"
        default: return "not asked"
        }
    }

    // MARK: CLLocationManagerDelegate

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in self.handle(locations) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in self.applyArming() }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}
