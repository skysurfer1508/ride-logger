import AppIntents

/// "Start ride": what the Shortcuts automation for the helmet (Bluetooth > helmet > Is Connected) runs, and also Siri and the Action button.
/// openAppWhenRun is false on purpose: with the phone locked in a bag the app cannot be opened, so the intent starts the recorder itself and the
/// coordinator schedules a notification as a safety net (see AutoStartCoordinator).
struct StartRideIntent: AppIntent {
    static let title: LocalizedStringResource = "Start ride"
    static let description = IntentDescription("Starts recording a ride in RideLog.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        _ = await AppServices.shared.autoStart.startFromIntent(trigger: "shortcut")
        return .result()
    }
}

struct StopRideIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop ride"
    static let description = IntentDescription("Stops the ride RideLog is recording and uploads it.")
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        _ = await AppServices.shared.autoStart.stopFromIntent()
        return .result()
    }
}

/// Makes both available in the Shortcuts app and to Siri without any setup.
struct RideLogShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StartRideIntent(), phrases: ["Start a ride in \(.applicationName)", "Start recording in \(.applicationName)"],
                    shortTitle: "Start ride", systemImageName: "record.circle")
        AppShortcut(intent: StopRideIntent(), phrases: ["Stop the ride in \(.applicationName)", "Stop recording in \(.applicationName)"],
                    shortTitle: "Stop ride", systemImageName: "stop.circle")
    }
}
