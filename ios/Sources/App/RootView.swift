import SwiftUI

@main
struct RideLogApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

struct RootView: View {
    @StateObject private var auth = AuthService()
    @StateObject private var api = APIClient()

    var body: some View {
        Group {
            switch auth.state {
            case .checking:
                ProgressView()
                    .tint(Theme.accent)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.bg.ignoresSafeArea())
                    .task { await auth.restore() }
            case .signedOut:
                LoginView(auth: auth)
            case .signedIn:
                MainTabs(api: api, auth: auth)
            }
        }
        .preferredColorScheme(.dark)
        .animation(.default, value: auth.state)
        .onAppear { api.onUnauthorized = { [auth] in auth.sessionEnded() } }
    }
}

struct MainTabs: View {
    let api: APIClient
    @ObservedObject var auth: AuthService
    /// One recorder for the whole app: a ride keeps recording whichever tab is open.
    @StateObject private var recorder: RideRecorder
    @State private var selected: AppTab = .home
    @ObservedObject private var navigation = AppServices.shared.navigation
    @Environment(\.scenePhase) private var scenePhase

    init(api: APIClient, auth: AuthService) {
        self.api = api
        self.auth = auth
        _recorder = StateObject(wrappedValue: AppServices.shared.recorder)       // the same one a Shortcuts intent uses, so a ride keeps going whichever way it started
    }

    var body: some View {
        TabView(selection: $selected) {
            HomeView(api: api)
                .tabItem { Label(AppTab.home.title, systemImage: AppTab.home.symbol) }
                .tag(AppTab.home)
            RidesView(api: api)
                .tabItem { Label(AppTab.rides.title, systemImage: AppTab.rides.symbol) }
                .tag(AppTab.rides)
            RecordView(recorder: recorder, uploader: recorder.uploader, activeRoute: AppServices.shared.activeRoute)
                .tabItem { Label(AppTab.record.title, systemImage: AppTab.record.symbol) }
                .tag(AppTab.record)
            TrafficView(api: api, activeRoute: AppServices.shared.activeRoute)
                .tabItem { Label(AppTab.traffic.title, systemImage: AppTab.traffic.symbol) }
                .tag(AppTab.traffic)
            SettingsView(api: api, auth: auth, recorder: recorder, uploader: recorder.uploader, autoStart: AppServices.shared.autoStart)
                .tabItem { Label(AppTab.settings.title, systemImage: AppTab.settings.symbol) }
                .tag(AppTab.settings)
        }
        .tint(Theme.accent)
        .fullScreenCover(isPresented: Binding(get: { navigation.isActive }, set: { if !$0 { navigation.end() } })) {
            NavigationScreen(nav: navigation)
        }
        .onChange(of: scenePhase) { _, phase in
            // back in the app: make sure the phone is linked to the account and anything waiting goes up
            if phase == .active {
                Task {
                    await recorder.uploader.refreshCredentials()
                    await recorder.uploader.syncAll()
                }
                Task { await GarageReminders.refresh(api: api) }
                Task { await WatchBridge.shared.refreshStats(api: api) }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .ridesChanged)) { _ in
            Task { await WatchBridge.shared.refreshStats(api: api) }
        }
    }
}
