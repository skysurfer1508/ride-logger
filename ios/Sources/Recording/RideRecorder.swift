import CoreLocation
import SwiftUI

/// Records a ride: asks CoreLocation for GPS fixes (also with the screen locked), writes every fix to the phone the moment it arrives, keeps the
/// live numbers, and hands the ride to the uploader every 30 seconds and when you stop. The pure rules (which fixes count, distance, what to
/// upload) live in RecordingLogic.swift and are unit-tested; this file is the CoreLocation and lifecycle glue and needs a real iPhone to try.
@MainActor
final class RideRecorder: NSObject, ObservableObject, CLLocationManagerDelegate {
    enum Phase { case idle, recording }

    /// What the last finished ride came to, shown on the Record tab until dismissed.
    struct Summary: Equatable {
        let distanceM: Double
        let durationS: Double
        let avgKmh: Int
        let maxKmh: Int
        let points: Int
        let discarded: Bool
    }

    /// A ride on this phone with its number of fixes, for the list in Settings.
    struct LocalRide: Identifiable {
        let record: TripRecord
        let sampleCount: Int
        var id: String { record.tripId }
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var stats = LiveStats()
    @Published private(set) var latest: LocationSample?
    @Published private(set) var route: [CLLocationCoordinate2D] = []
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var authorization: CLAuthorizationStatus = .notDetermined
    @Published private(set) var isPrecise = true
    /// A ride that was still being recorded when the app was last closed (crash, force-quit, phone restart).
    @Published private(set) var interrupted: TripRecord?
    @Published private(set) var interruptedCanResume = false
    @Published private(set) var summary: Summary?
    @Published var errorMessage: String?

    let uploader: RideUploader
    private let store: TripStore
    private let manager = CLLocationManager()
    private var trip: TripRecord?
    private var backgroundSession: CLBackgroundActivitySession?
    private var timer: Timer?
    private var ticks = 0
    private let liveActivity = LiveActivityController()

    /// A ride older than this cannot be resumed: continuing would draw a straight line across the gap and count it as distance.
    static let resumeWindowSeconds: TimeInterval = 10 * 60

    init(api: APIClient) {
        let store = TripStore()
        self.store = store
        self.uploader = RideUploader(store: store, api: api)
        super.init()
        manager.delegate = self
        LiveActivityController.endLeftovers()          // the app was killed mid-ride last time: its Lock Screen banner would show frozen numbers
        refreshAuthorization()
        UIDevice.current.isBatteryMonitoringEnabled = true
        loadInterrupted()
        Task {
            await uploader.refreshCredentials()
            await uploader.syncAll()
        }
    }

    // MARK: state the screen reads

    var isAuthorized: Bool { authorization == .authorizedWhenInUse || authorization == .authorizedAlways }
    var isDenied: Bool { authorization == .denied || authorization == .restricted }
    var isRecording: Bool { phase == .recording }
    var canStart: Bool { phase == .idle && isAuthorized && uploader.credentials != nil && interrupted == nil }
    /// A ride with nothing on the server yet can be thrown away; one that has been (partly) uploaded cannot, it would reappear as a ride.
    /// (Read from the store: the uploader updates the saved record, not this in-memory copy.)
    var canDiscard: Bool {
        guard let trip else { return false }
        return (store.record(tripId: trip.tripId)?.uploadedCount ?? 1) == 0
    }
    var keepScreenOn: Bool { UserDefaults.standard.object(forKey: "keepScreenOn") as? Bool ?? true }

    static var deviceId: String {
        let key = "ridelog.installId"
        if let saved = UserDefaults.standard.string(forKey: key) { return "ridelog-ios-" + saved }
        let fresh = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).uppercased()
        UserDefaults.standard.set(fresh, forKey: key)
        return "ridelog-ios-" + fresh
    }

    // MARK: permission

    func requestPermission() { manager.requestWhenInUseAuthorization() }

    func requestPreciseLocation() {
        manager.requestTemporaryFullAccuracyAuthorization(withPurposeKey: "RecordRide")
    }

    private func refreshAuthorization() {
        authorization = manager.authorizationStatus
        isPrecise = manager.accuracyAuthorization == .fullAccuracy
    }

    // MARK: start / stop

    func start() {
        guard canStart, let creds = uploader.credentials else { return }
        summary = nil
        errorMessage = nil
        let now = Self.wholeSecond(Date())
        let suffix = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased()
        let record = TripRecord(tripId: TripRecord.makeId(start: now, suffix: suffix), deviceId: Self.deviceId, ownerEmail: creds.email, startedAt: now)
        do {
            try store.begin(record)
        } catch {
            errorMessage = "Couldn't create the ride on this phone. Is the storage full?"
            return
        }
        trip = record
        stats = LiveStats()
        latest = nil
        route = []
        elapsed = 0
        beginTracking()
    }

    /// Ends the ride. A ride that never got going (fewer than two fixes) or that you chose to discard is removed, but only if the server has none of it.
    func stop(discard: Bool = false) {
        guard phase == .recording, let current = trip else { return }
        var record = store.record(tripId: current.tripId) ?? current      // the saved copy knows how much the uploader has sent
        endTracking()
        let samples = store.samples(tripId: record.tripId)
        let worthKeeping = RecordingLogic.isWorthKeeping(sampleCount: samples.count)
        if (discard || !worthKeeping) && record.uploadedCount == 0 {
            store.delete(tripId: record.tripId)
            summary = Summary(distanceM: 0, durationS: 0, avgKmh: 0, maxKmh: 0, points: samples.count, discarded: true)
        } else {
            record.endedAt = latest?.timestamp ?? Self.wholeSecond(Date())
            do {
                try store.save(record)
            } catch {
                errorMessage = "Couldn't save the end of the ride. It will be closed by the server after an hour."
            }
            let duration = max(0, (record.endedAt ?? record.startedAt).timeIntervalSince(record.startedAt))
            summary = Summary(distanceM: stats.distanceM, durationS: duration,
                              avgKmh: RecordingLogic.averageKmh(distanceM: stats.distanceM, elapsed: duration),
                              maxKmh: Format.kmh(fromMps: stats.maxSpeedMps), points: samples.count, discarded: false)
            Task { await uploader.syncAll() }
        }
        trip = nil
    }

    func dismissSummary() { summary = nil }

    // MARK: a ride cut off by a crash or a restart

    private func loadInterrupted() {
        guard let record = store.records().first(where: { !$0.isFinished }) else { return }
        interrupted = record
        let last = store.samples(tripId: record.tripId).last?.timestamp ?? record.startedAt
        interruptedCanResume = Date().timeIntervalSince(last) <= Self.resumeWindowSeconds
    }

    func resumeInterrupted() {
        guard phase == .idle, let shown = interrupted, let record = store.record(tripId: shown.tripId) else { return }
        guard isAuthorized else {
            errorMessage = "Allow location access first, then resume."
            return
        }
        store.repairTail(tripId: record.tripId)
        let samples = store.samples(tripId: record.tripId)
        trip = record
        stats = LiveStats.from(samples)
        latest = samples.last
        route = samples.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
        elapsed = Date().timeIntervalSince(record.startedAt)
        interrupted = nil
        summary = nil
        beginTracking()
    }

    /// Closes a cut-off ride at its last fix and uploads it.
    func finishInterrupted() {
        guard let shown = interrupted else { return }
        interrupted = nil
        guard var record = store.record(tripId: shown.tripId) else { return }       // re-read: the uploader may have sent part of it at launch
        let samples = store.samples(tripId: record.tripId)
        if !RecordingLogic.isWorthKeeping(sampleCount: samples.count) && record.uploadedCount == 0 {
            store.delete(tripId: record.tripId)
            return
        }
        record.endedAt = samples.last?.timestamp ?? record.startedAt
        try? store.save(record)
        Task { await uploader.syncAll() }
    }

    func discardInterrupted() {
        guard let shown = interrupted, let record = store.record(tripId: shown.tripId), record.uploadedCount == 0 else { return }
        store.delete(tripId: record.tripId)
        interrupted = nil
    }

    // MARK: rides on this phone (Settings)

    func localRides() -> [LocalRide] {
        store.records().reversed().map { LocalRide(record: $0, sampleCount: store.samples(tripId: $0.tripId).count) }
    }

    /// Only a ride that is not being recorded right now can be removed from the phone.
    func deleteLocal(tripId: String) {
        guard trip?.tripId != tripId else { return }
        store.delete(tripId: tripId)
        if interrupted?.tripId == tripId { interrupted = nil }
        uploader.refreshCounts()
    }

    // MARK: CoreLocation

    private func beginTracking() {
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.distanceFilter = 5                       // metres: no stream of jitter while standing at a light (it would add fake distance), still a fix every second at speed
        manager.activityType = .automotiveNavigation
        manager.pausesLocationUpdatesAutomatically = false
        manager.allowsBackgroundLocationUpdates = true    // needs UIBackgroundModes: location (project.yml)
        manager.showsBackgroundLocationIndicator = true   // the blue pill: the phone is telling you it is recording
        manager.startUpdatingLocation()
        backgroundSession = CLBackgroundActivitySession()
        phase = .recording
        ticks = 0
        startTimer()
        UIApplication.shared.isIdleTimerDisabled = keepScreenOn
        if let trip { liveActivity.start(startedAt: trip.startedAt, snapshot: currentSnapshot()) }
    }

    private func currentSnapshot() -> LiveSnapshot {
        RecordingLogic.snapshot(latest: latest, stats: stats, now: Date())
    }

    private func endTracking() {
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
        backgroundSession?.invalidate()
        backgroundSession = nil
        timer?.invalidate()
        timer = nil
        UIApplication.shared.isIdleTimerDisabled = false
        liveActivity.end()
        phase = .idle
    }

    private func startTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        guard let trip else { return }
        elapsed = Date().timeIntervalSince(trip.startedAt)
        liveActivity.update(currentSnapshot())           // spaced out by the controller
        ticks += 1
        if ticks % 30 == 0 { Task { await uploader.syncAll() } }
    }

    private static func wholeSecond(_ date: Date) -> Date {
        Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
    }

    private func handle(_ locations: [CLLocation]) {
        guard phase == .recording, let trip else { return }
        for location in locations.sorted(by: { $0.timestamp < $1.timestamp }) {
            guard location.horizontalAccuracy >= 0 else { continue }                     // no valid position
            let stamp = Self.wholeSecond(location.timestamp)
            guard stamp >= trip.startedAt else { continue }                              // a cached fix from before Start
            if let last = latest, stamp.timeIntervalSince(last.timestamp) < 1 { continue }   // one fix per second: unique timestamps on the wire
            let speed = RecordingLogic.trustedSpeed(
                reported: location.speed, speedAccuracy: location.speedAccuracy, horizontalAccuracy: location.horizontalAccuracy,
                latitude: location.coordinate.latitude, longitude: location.coordinate.longitude, at: stamp, previous: latest)
            let sample = LocationSample(
                timestamp: stamp,
                latitude: location.coordinate.latitude, longitude: location.coordinate.longitude,
                speed: speed, altitude: location.altitude,
                horizontalAccuracy: location.horizontalAccuracy, verticalAccuracy: location.verticalAccuracy,
                batteryLevel: Double(UIDevice.current.batteryLevel), speedAccuracy: location.speedAccuracy)
            do {
                try store.append(sample, tripId: trip.tripId)
            } catch {
                errorMessage = "Can't write to this phone's storage. Is it full?"
                continue
            }
            stats.add(sample)
            latest = sample
            route.append(location.coordinate)
        }
    }

    // MARK: CLLocationManagerDelegate

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in self.handle(locations) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        if let clError = error as? CLError, clError.code == .locationUnknown { return }      // "no fix yet": keeps trying by itself
        let message = error.localizedDescription
        Task { @MainActor in self.errorMessage = "Location problem: \(message)" }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            self.refreshAuthorization()
            if self.phase == .recording && !self.isAuthorized {
                self.errorMessage = "Location access was turned off. Recording has stopped receiving positions."
            }
        }
    }
}
