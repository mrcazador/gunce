import Foundation
import UserNotifications

/// Local notifications for reminders and due times. The set is rebuilt from the task list
/// after every change, so it never drifts from what the app shows.
enum Reminders {
    static let category = "pickup.task"
    static let resumeAction = "resume"
    static let snoozeAction = "snooze"
    static let doneAction = "done"
    private static let prefix = "pickup."

    struct Item {
        let taskID: String
        let title: String
        let body: String?
        let date: Date
        let isDue: Bool
    }

    static func registerCategories() {
        let actions = [
            UNNotificationAction(identifier: resumeAction, title: "Devam et", options: [.foreground]),
            UNNotificationAction(identifier: snoozeAction, title: "1 saat ertele", options: []),
            UNNotificationAction(identifier: doneAction, title: "Bitti", options: []),
        ]
        let taskCategory = UNNotificationCategory(
            identifier: category, actions: actions, intentIdentifiers: [], options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([taskCategory])
    }

    static func status() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    /// Asks once, in context (when the person first sets a reminder). Returns whether allowed.
    @discardableResult
    static func requestPermission() async -> Bool {
        switch await status() {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined:
            let granted = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            return granted ?? false
        default:
            return false
        }
    }

    /// Replaces every pending PickUp notification with `items` (the soonest 60; iOS keeps 64).
    static func reschedule(_ items: [Item]) async {
        let allowed = await status()
        guard allowed == .authorized || allowed == .provisional else { return }
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        center.removePendingNotificationRequests(
            withIdentifiers: pending.map(\.identifier).filter { $0.hasPrefix(prefix) }
        )
        let upcoming = items.filter { $0.date > .now }.sorted { $0.date < $1.date }.prefix(60)
        for item in upcoming {
            try? await center.add(request(for: item))
        }
    }

    private static func request(for item: Item) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = item.title
        content.subtitle = item.isDue ? "Zamanı geldi" : "Hatırlatma"
        if let body = item.body { content.body = body }
        content.sound = .default
        content.categoryIdentifier = category
        content.threadIdentifier = item.taskID
        content.userInfo = ["taskID": item.taskID]
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: item.date)
        let trigger = UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)
        let kind = item.isDue ? "due" : "remind"
        return UNNotificationRequest(identifier: "\(prefix)\(kind).\(item.taskID)", content: content, trigger: trigger)
    }

    /// Quick reminder choices offered when parking a task.
    enum Preset: String, CaseIterable, Identifiable {
        case none, inAnHour, evening, tomorrowMorning

        var id: String { rawValue }

        var title: String {
            switch self {
            case .none: "Yok"
            case .inAnHour: "1 saat sonra"
            case .evening: "Akşam"
            case .tomorrowMorning: "Yarın sabah"
            }
        }

        /// Evening is 19:00 today (or tomorrow if that has passed); morning is 09:00 tomorrow.
        func date(from now: Date = .now) -> Date? {
            let calendar = Calendar.current
            switch self {
            case .none:
                return nil
            case .inAnHour:
                return now.addingTimeInterval(3600)
            case .evening:
                let today = calendar.date(bySettingHour: 19, minute: 0, second: 0, of: now) ?? now
                return today > now ? today : calendar.date(byAdding: .day, value: 1, to: today)
            case .tomorrowMorning:
                let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) ?? now
                return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow)
            }
        }
    }
}
