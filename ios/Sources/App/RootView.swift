import SwiftUI

@main
struct RideLogApp: App {
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
    @State private var selected: AppTab = .home

    var body: some View {
        TabView(selection: $selected) {
            HomeView(api: api)
                .tabItem { Label(AppTab.home.title, systemImage: AppTab.home.symbol) }
                .tag(AppTab.home)
            RidesView(api: api)
                .tabItem { Label(AppTab.rides.title, systemImage: AppTab.rides.symbol) }
                .tag(AppTab.rides)
            OverviewView(api: api)
                .tabItem { Label(AppTab.overview.title, systemImage: AppTab.overview.symbol) }
                .tag(AppTab.overview)
            SettingsView(api: api, auth: auth)
                .tabItem { Label(AppTab.settings.title, systemImage: AppTab.settings.symbol) }
                .tag(AppTab.settings)
        }
        .tint(Theme.accent)
    }
}
