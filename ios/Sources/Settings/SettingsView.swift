import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    let api: APIClient
    @ObservedObject var auth: AuthService
    @ObservedObject var recorder: RideRecorder
    @ObservedObject var uploader: RideUploader
    @ObservedObject var autoStart: AutoStartCoordinator
    @AppStorage("keepScreenOn") private var keepScreenOn = true
    @AppStorage(InsightsLogic.showLimitsKey) private var showSpeedLimits = true
    @State private var localRides: [RideRecorder.LocalRide] = []
    @State private var deleteTarget: RideRecorder.LocalRide?

    @StateObject private var me: Loader<MeResponse>
    @StateObject private var server: Loader<SettingsResponse>
    @State private var token: String?
    @State private var revealToken = false
    @State private var gap = ""
    @State private var minPoints = ""
    @State private var minDistance = ""
    @State private var stale = ""
    @State private var banner: Banner?
    @State private var confirmRegenerate = false
    @State private var confirmSignOut = false
    @State private var busy = false
    @State private var showImporter = false

    struct Banner: Equatable {
        let text: String
        let isError: Bool
    }

    init(api: APIClient, auth: AuthService, recorder: RideRecorder, uploader: RideUploader, autoStart: AutoStartCoordinator) {
        self.api = api
        self.auth = auth
        self.recorder = recorder
        self.uploader = uploader
        self.autoStart = autoStart
        _me = StateObject(wrappedValue: Loader(api: api, path: "me"))
        _server = StateObject(wrappedValue: Loader(api: api, path: "settings"))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    if let banner {
                        Text(banner.text)
                            .font(.footnote)
                            .foregroundStyle(banner.isError ? Theme.danger : Theme.success)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 6))
                    }
                    accountPanel
                    recordingPanel
                    insightsPanel
                    AutoStartPanel(coordinator: autoStart, recorder: recorder)
                    dataPanel
                    overlandPanel
                    detectionPanel
                    aboutPanel
                }
                .padding(16)
            }
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("Settings")
            .task {
                refreshLocalRides()
                await me.loadIfNeeded()
                await server.loadIfNeeded()
                fillDetection()
            }
            .onChange(of: uploader.unsentPoints) { _, _ in refreshLocalRides() }
            .onChange(of: recorder.phase) { _, _ in refreshLocalRides() }
            .confirmationDialog("Remove this ride from the phone?", isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }),
                                titleVisibility: .visible) {
                Button("Remove", role: .destructive) {
                    if let target = deleteTarget { recorder.deleteLocal(tripId: target.id) }
                    deleteTarget = nil
                    refreshLocalRides()
                }
            } message: {
                Text("Anything not uploaded yet is lost for good.")
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [UTType(filenameExtension: "gpx") ?? .xml, .xml, .data]) { result in
                Task { await importGPX(result) }
            }
            .confirmationDialog("Regenerate the upload token?", isPresented: $confirmRegenerate, titleVisibility: .visible) {
                Button("Regenerate", role: .destructive) { Task { await regenerate() } }
            } message: {
                Text("The current token stops working. Overland needs the new one before it can upload again.")
            }
            .confirmationDialog("Sign out of RideLog?", isPresented: $confirmSignOut, titleVisibility: .visible) {
                Button("Sign out", role: .destructive) {
                    uploader.forgetCredentials()
                    Task { await auth.signOut() }
                }
            } message: {
                Text(uploader.unsentRides > 0
                     ? "\(uploader.unsentRides) ride(s) haven't finished uploading. They stay on this phone and upload after you sign in again."
                     : "You can sign in again any time.")
            }
        }
    }

    // MARK: panels

    private var accountPanel: some View {
        Panel(title: "Account") {
            if let me = me.value {
                Text(me.name).font(.headline).foregroundStyle(Theme.text)
                Text(me.email).font(.subheadline).foregroundStyle(Theme.muted)
            } else {
                ProgressView().tint(Theme.accent)
            }
            Button("Sign out", role: .destructive) {
                if recorder.isRecording {
                    banner = Banner(text: "Finish the ride you are recording before signing out.", isError: true)
                } else {
                    confirmSignOut = true
                }
            }
        }
    }

    private var insightsPanel: some View {
        Panel(title: "Ride insights") {
            Toggle("Show speed against the limit", isOn: $showSpeedLimits)
                .tint(Theme.accent)
                .foregroundStyle(Theme.text)
            Text("On a ride's screen: the stretches ridden over the limit written on the map, in pink. It only changes what this app shows; the server still works it out. Turn it off if you would rather not see it.")
                .font(.footnote).foregroundStyle(Theme.muted)
        }
    }

    private var recordingPanel: some View {
        Panel(title: "Recording") {
            Toggle("Keep the screen on while recording", isOn: $keepScreenOn)
                .tint(Theme.accent)
                .foregroundStyle(Theme.text)
            Text("Recording continues with the screen locked. Keeping it on makes the speed easy to read on a mount but uses more battery.")
                .font(.footnote).foregroundStyle(Theme.muted)
            Text(LiveActivityController.isAvailable
                 ? "Live speed and distance show on the Lock Screen and in the Dynamic Island while you record."
                 : "Live Activities are off for RideLog, so there is no Lock Screen or Dynamic Island display. Turn them on in the iPhone's Settings app > RideLog.")
                .font(.footnote).foregroundStyle(Theme.muted)
            UploadStatus(uploader: uploader)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text("RIDES ON THIS PHONE").font(Theme.label).tracking(1.2).foregroundStyle(Theme.muted).padding(.top, 6)
            if localRides.isEmpty {
                Text("None. Rides are kept here until they have uploaded, then the newest five stay as a backup.")
                    .font(.footnote).foregroundStyle(Theme.muted)
            }
            ForEach(localRides) { ride in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ride.record.startedAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.subheadline).foregroundStyle(Theme.text)
                        Text(status(of: ride)).font(.caption).foregroundStyle(Theme.muted)
                    }
                    Spacer()
                    if !(recorder.isRecording && !ride.record.isFinished) {
                        Button(role: .destructive) { deleteTarget = ride } label: { Image(systemName: "trash") }
                            .accessibilityLabel("Remove this ride from the phone")
                    }
                }
            }
        }
    }

    private var dataPanel: some View {
        Panel(title: "Your data") {
            Text("Bring in a ride recorded with another app (Strava, Komoot, a bike computer) as a GPX file. To get a ride out, open it and tap the share icon.")
                .font(.footnote).foregroundStyle(Theme.muted)
            Button("Import a ride from a GPX file…") { showImporter = true }
                .buttonStyle(.bordered)
                .disabled(busy)
        }
    }

    private func importGPX(_ result: Result<URL, Error>) async {
        guard case .success(let url) = result else { return }                    // the picker was cancelled
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        busy = true
        defer { busy = false }
        do {
            guard let data = try? Data(contentsOf: url) else {
                banner = Banner(text: "That file could not be read.", isError: true)
                return
            }
            let response: ImportResponse = try await api.postFile("import/gpx", field: "file", filename: url.lastPathComponent,
                                                                  mimeType: "application/gpx+xml", data: data)
            banner = Banner(text: ImportSummary.text(response), isError: false)
            if response.imported > 0 { NotificationCenter.default.post(name: .ridesChanged, object: nil) }
        } catch APIError.unauthorized {
            // AuthService takes over
        } catch {
            banner = Banner(text: (error as? LocalizedError)?.errorDescription ?? "Couldn't import the file.", isError: true)
        }
    }

    private func status(of ride: RideRecorder.LocalRide) -> String {
        let record = ride.record
        if !record.isFinished { return recorder.isRecording ? "Recording now · \(ride.sampleCount) points" : "Cut off · \(ride.sampleCount) points" }
        if let mine = uploader.credentials?.email, record.ownerEmail != mine { return "Belongs to \(record.ownerEmail). Sign in as them to upload." }
        if record.markerSent && record.uploadedCount >= ride.sampleCount { return "Uploaded · \(ride.sampleCount) points" }
        return "Waiting to upload · \(max(0, ride.sampleCount - record.uploadedCount)) of \(ride.sampleCount) points"
    }

    private func refreshLocalRides() {
        localRides = recorder.localRides()
    }

    private var overlandPanel: some View {
        Panel(title: "Overland connection") {
            Text("Only needed if you still record with the Overland app. This token is yours alone: data uploaded with it belongs to your account.")
                .font(.footnote).foregroundStyle(Theme.muted)
            if let info = me.value {
                let shownToken = token ?? info.ingestToken
                let url = Logic.ingestURL(base: Config.baseURL, path: info.ingestPath).absoluteString
                field("Server URL", value: url, secret: false)
                field("Access token", value: shownToken, secret: true)
                Button("Regenerate token", role: .destructive) { confirmRegenerate = true }.disabled(busy)
            }
        }
    }

    private func field(_ title: String, value: String, secret: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased()).font(Theme.label).tracking(1.2).foregroundStyle(Theme.muted)
            HStack {
                Text(secret && !revealToken ? String(repeating: "•", count: 16) : value)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(Theme.text)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Spacer()
                if secret {
                    Button { revealToken.toggle() } label: { Image(systemName: revealToken ? "eye.slash" : "eye") }
                        .accessibilityLabel(revealToken ? "Hide token" : "Show token")
                }
                Button {
                    UIPasteboard.general.string = value
                    banner = Banner(text: "\(title) copied.", isError: false)
                } label: { Image(systemName: "doc.on.doc") }
                    .accessibilityLabel("Copy \(title)")
            }
        }
    }

    private var detectionPanel: some View {
        Panel(title: "Ride detection") {
            Text("How the server splits location points into rides. These apply to everyone who uses this server.")
                .font(.footnote).foregroundStyle(Theme.muted)
            numberField("Gap minutes", hint: "A gap this long starts a new ride when no trip is active", text: $gap)
            numberField("Minimum points", hint: "Fewest points a gap-inferred ride needs", text: $minPoints, whole: true)
            numberField("Minimum distance (m)", hint: "Shortest gap-inferred ride that counts", text: $minDistance)
            numberField("Stale trip minutes", hint: "Finish an unfinished trip after this much silence", text: $stale)
            Button("Save") { Task { await saveDetection() } }
                .buttonStyle(.borderedProminent)
                .disabled(busy || server.value == nil)
        }
    }

    private func numberField(_ title: String, hint: String, text: Binding<String>, whole: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline).foregroundStyle(Theme.text)
            TextField(title, text: text)
                .keyboardType(whole ? .numberPad : .decimalPad)
                .textFieldStyle(.roundedBorder)
            Text(hint).font(.caption).foregroundStyle(Theme.muted)
        }
    }

    private var aboutPanel: some View {
        Panel(title: "About") {
            row("Version", Config.versionDescription)
            row("Server", Config.host)
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(Theme.muted)
            Spacer()
            Text(value).foregroundStyle(Theme.text).font(.system(.subheadline, design: .monospaced))
        }
    }

    // MARK: actions

    private func fillDetection() {
        guard let d = server.value?.detection else { return }
        gap = Self.text(d.gapMinutes)
        minPoints = String(d.minPoints)
        minDistance = Self.text(d.minDistanceM)
        stale = Self.text(d.staleTripMinutes)
    }

    private static func text(_ number: Double) -> String {
        number == number.rounded() ? String(Int(number)) : String(number)
    }

    private func saveDetection() async {
        guard let gapValue = Logic.parseDecimal(gap), gapValue > 0,
              let points = Int(minPoints.trimmingCharacters(in: .whitespaces)), points > 0,
              let distance = Logic.parseDecimal(minDistance), distance >= 0,
              let staleValue = Logic.parseDecimal(stale), staleValue > 0 else {
            banner = Banner(text: "Every value must be a positive number (the distance may be 0).", isError: true)
            return
        }
        busy = true
        defer { busy = false }
        do {
            let saved: SettingsResponse = try await api.post("settings/detection", form: [
                "gap_minutes": String(gapValue),
                "min_points": String(points),
                "min_distance_m": String(distance),
                "stale_trip_minutes": String(staleValue),
            ])
            await server.refresh()
            gap = Self.text(saved.detection.gapMinutes)
            minPoints = String(saved.detection.minPoints)
            minDistance = Self.text(saved.detection.minDistanceM)
            stale = Self.text(saved.detection.staleTripMinutes)
            banner = Banner(text: "Ride-detection settings saved.", isError: false)
        } catch APIError.unauthorized {
            // AuthService takes over
        } catch {
            banner = Banner(text: (error as? LocalizedError)?.errorDescription ?? "Couldn't save.", isError: true)
        }
    }

    private func regenerate() async {
        busy = true
        defer { busy = false }
        do {
            let fresh: TokenResponse = try await api.post("settings/regenerate-token")
            token = fresh.ingestToken
            await me.refresh()
            banner = Banner(text: "New token created. Update it in Overland now.", isError: false)
        } catch APIError.unauthorized {
            // AuthService takes over
        } catch {
            banner = Banner(text: (error as? LocalizedError)?.errorDescription ?? "Couldn't regenerate the token.", isError: true)
        }
    }
}
