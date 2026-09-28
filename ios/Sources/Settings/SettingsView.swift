import SwiftUI

struct SettingsView: View {
    let api: APIClient
    @ObservedObject var auth: AuthService

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

    struct Banner: Equatable {
        let text: String
        let isError: Bool
    }

    init(api: APIClient, auth: AuthService) {
        self.api = api
        self.auth = auth
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
                    overlandPanel
                    detectionPanel
                    aboutPanel
                }
                .padding(16)
            }
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("Settings")
            .task {
                await me.loadIfNeeded()
                await server.loadIfNeeded()
                fillDetection()
            }
            .confirmationDialog("Regenerate the upload token?", isPresented: $confirmRegenerate, titleVisibility: .visible) {
                Button("Regenerate", role: .destructive) { Task { await regenerate() } }
            } message: {
                Text("The current token stops working. Overland needs the new one before it can upload again.")
            }
            .confirmationDialog("Sign out of RideLog?", isPresented: $confirmSignOut, titleVisibility: .visible) {
                Button("Sign out", role: .destructive) { Task { await auth.signOut() } }
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
            Button("Sign out", role: .destructive) { confirmSignOut = true }
        }
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
