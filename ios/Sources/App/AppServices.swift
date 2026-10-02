import SwiftUI
import UserNotifications

/// The pieces that must exist whether or not any screen does: a Shortcuts intent or a relaunch after a movement runs without the UI, and still needs
/// the recorder. One of each for the whole process.
@MainActor
final class AppServices {
    static let shared = AppServices()

    let api: APIClient
    let recorder: RideRecorder
    let autoStart: AutoStartCoordinator
    /// The planned route being followed, if any (shown on the Traffic and Record maps).
    let activeRoute = ActiveRouteModel()

    private init() {
        let api = APIClient()
        let recorder = RideRecorder(api: api)
        self.api = api
        self.recorder = recorder
        self.autoStart = AutoStartCoordinator(recorder: recorder)
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        Task { @MainActor in
            AppServices.shared.autoStart.applicationDidLaunch()
            WatchBridge.shared.activate(recorder: AppServices.shared.recorder)       // also on a background launch by the Watch
        }
        return true
    }

    // A notification that arrives while the app is open is still shown.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let identifier = response.notification.request.identifier
        let action = response.actionIdentifier
        Task { @MainActor in
            AppServices.shared.autoStart.handleNotification(identifier: identifier, action: action)
            completionHandler()
        }
    }
}
