import Foundation
import Network

/// Sends the rides on this phone to the server with the account's ingest token, the same way Overland does, so the server builds the ride
/// exactly as before. Safe to run again and again: the server ignores a point it already has, and a ride only closes on its trip marker.
///
/// It only ever uploads rides that belong to the signed-in account (TripRecord.ownerEmail), so signing out and someone else signing in can
/// never hand them your ride.
@MainActor
final class RideUploader: ObservableObject {
    enum UploadError: LocalizedError {
        case offline
        case rejected(Int)
        case noCredentials

        var errorDescription: String? {
            switch self {
            case .offline: return "No connection to the server. The ride is safe on this phone and will upload when you're back online."
            case .rejected(let code): return "The server refused the upload (\(code)). The ride is safe on this phone."
            case .noCredentials: return "This phone isn't linked to your account yet. Open the app while online."
            }
        }
    }

    @Published private(set) var credentials: CredentialVault.Credentials?
    @Published private(set) var unsentPoints = 0
    @Published private(set) var unsentRides = 0
    @Published private(set) var isSending = false
    @Published private(set) var lastError: String?

    private let store: TripStore
    private let api: APIClient
    private let session: URLSession
    private let monitor = NWPathMonitor()

    init(store: TripStore, api: APIClient) {
        self.store = store
        self.api = api
        // Uploads authenticate with the bearer token only: never send the website's session cookie to the ingest endpoint.
        let config = URLSessionConfiguration.default
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.timeoutIntervalForRequest = 30
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config)
        self.credentials = CredentialVault.load()
        refreshCounts()

        monitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor in await self?.syncAll() }
        }
        monitor.start(queue: DispatchQueue(label: "ridelog.network"))
    }

    deinit { monitor.cancel() }

    // MARK: credentials

    /// Asks the server who is signed in and for their ingest token (created on first use). Keeps the saved copy if the server can't be reached.
    func refreshCredentials() async {
        do {
            let me: MeResponse = try await api.get("me")
            let fresh = CredentialVault.Credentials(token: me.ingestToken, email: me.email)
            if fresh != credentials {
                CredentialVault.save(fresh)
                credentials = fresh
            }
        } catch {
            // offline or signed out: keep whatever is saved
        }
        refreshCounts()
    }

    /// On sign-out: the token is removed from the Keychain. Rides not yet uploaded stay on the phone and upload after that account signs in again.
    func forgetCredentials() {
        CredentialVault.clear()
        credentials = nil
        refreshCounts()
    }

    // MARK: sync

    func syncAll() async {
        guard !isSending, let creds = credentials else {
            refreshCounts()
            return
        }
        isSending = true
        defer {
            isSending = false
            refreshCounts()
        }
        var failure: String?
        var finishedARide = false
        for record in store.records() where record.ownerEmail == creds.email {
            do {
                if try await upload(record.tripId) { finishedARide = true }
            } catch {
                failure = (error as? LocalizedError)?.errorDescription ?? "Upload failed."
                break
            }
        }
        lastError = failure
        if failure == nil { store.purgeUploaded(keeping: 5) }
        // a ride just became complete on the server: Home, Rides, Overview and the map reload (not on every mid-ride batch)
        if finishedARide { NotificationCenter.default.post(name: .ridesChanged, object: nil) }
    }

    func refreshCounts() {
        guard let creds = credentials else {
            unsentPoints = 0
            unsentRides = 0
            return
        }
        var points = 0
        var rides = 0
        for record in store.records() where record.ownerEmail == creds.email {
            let pending = max(0, store.samples(tripId: record.tripId).count - record.uploadedCount)
            if pending > 0 || (record.isFinished && !record.markerSent) { rides += 1 }
            points += pending
        }
        unsentPoints = points
        unsentRides = rides
    }

    // MARK: one ride

    /// Sends what the server doesn't have of one ride. Returns true if this call delivered the trip marker (the ride is now complete on the server).
    @discardableResult
    private func upload(_ tripId: String) async throws -> Bool {
        var completed = false
        while true {
            // Re-read the ride every round: the recorder keeps adding fixes, and Stop can finish it while a batch is in flight.
            guard let record = store.record(tripId: tripId) else { return completed }
            let samples = store.samples(tripId: tripId)
            if samples.isEmpty {
                if record.isFinished && !record.markerSent {
                    var done = record
                    done.markerSent = true            // nothing to say about a ride with no fixes
                    try store.save(done)
                }
                return completed
            }
            let range = UploadPlan.nextRange(total: samples.count, uploaded: record.uploadedCount)
            let carriesMarker = UploadPlan.carriesMarker(range: range, total: samples.count, finished: record.isFinished, markerSent: record.markerSent)
            if range.isEmpty && !carriesMarker { return completed }

            var marker: IngestPayload.Marker?
            if carriesMarker, let end = record.endedAt, let last = samples.last {
                marker = IngestPayload.Marker(end: end, durationS: max(0, end.timeIntervalSince(record.startedAt)),
                                              distanceM: LiveStats.from(samples).distanceM, latitude: last.latitude, longitude: last.longitude)
            }
            let body = try IngestPayload.body(samples: Array(samples[range]), trip: record, marker: marker)
            try await post(body)

            if marker != nil { completed = true }
            guard var latest = store.record(tripId: tripId) else { return completed }
            latest.uploadedCount = max(latest.uploadedCount, range.upperBound)
            if marker != nil { latest.markerSent = true }
            try store.save(latest)
        }
    }

    private func post(_ body: Data, retrying: Bool = true) async throws {
        guard let creds = credentials else { throw UploadError.noCredentials }
        var request = URLRequest(url: Logic.ingestURL(base: Config.baseURL, path: Config.ingestPath))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(creds.token)", forHTTPHeaderField: "Authorization")
        request.httpBody = body

        let response: URLResponse
        do {
            (_, response) = try await session.data(for: request)
        } catch {
            throw UploadError.offline
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 200 { return }
        if status == 401 && retrying {
            // the token was regenerated on the website: fetch the new one (needs the signed-in session) and try once more
            let old = creds.token
            await refreshCredentials()
            if let fresh = credentials, fresh.token != old {
                try await post(body, retrying: false)
                return
            }
        }
        throw UploadError.rejected(status)
    }
}
