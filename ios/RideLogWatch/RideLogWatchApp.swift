import SwiftUI

@main
struct RideLogWatchApp: App {
    @StateObject private var session = WatchSession.shared

    init() {
        WatchSession.shared.activate()
    }

    var body: some Scene {
        WindowGroup {
            WatchRootView(session: session)
        }
    }
}
