import UserNotifications

/// Reminds about services that are overdue or due soon. Runs whenever the app comes to the front: looks at the garage, and if something is due and no reminder
/// went out in the last three days, schedules one notification for the next evening at 17:00 (replacing any earlier one). Nothing is scheduled while
/// nothing is due, and nothing without the notification permission.
@MainActor
enum GarageReminders {
    private static let lastKey = "garage.lastReminder"
    private static let requestId = "ridelog.garage.reminder"

    static func refresh(api: APIClient) async {
        guard let overview: GarageOverview = try? await api.get("garage") else { return }
        let overdue = overview.bikes.reduce(0) { $0 + $1.overdue }
        let soon = overview.bikes.reduce(0) { $0 + $1.soon }
        let center = UNUserNotificationCenter.current()
        if overdue + soon == 0 {
            center.removePendingNotificationRequests(withIdentifiers: [requestId])
            return
        }
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
        let now = Date()
        let last = UserDefaults.standard.object(forKey: lastKey) as? Date
        guard ReminderPolicy.shouldNotify(due: overdue + soon, lastNotified: last, now: now) else { return }

        var when = Calendar.current.dateComponents([.year, .month, .day], from: now.addingTimeInterval(86_400))
        when.hour = 17
        when.minute = 0
        let content = UNMutableNotificationContent()
        content.title = "Service reminder"
        content.body = ReminderPolicy.text(overdue: overdue, soon: soon) + " Open the Garage in RideLog."
        content.sound = .default
        let request = UNNotificationRequest(identifier: requestId, content: content, trigger: UNCalendarNotificationTrigger(dateMatching: when, repeats: false))
        try? await center.add(request)
        UserDefaults.standard.set(now, forKey: lastKey)
    }
}
