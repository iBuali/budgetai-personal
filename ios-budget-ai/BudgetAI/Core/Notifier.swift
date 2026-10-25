import Foundation
import UserNotifications

enum Notifier {
    @discardableResult
    static func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    static func post(title: String, body: String, id: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: id, content: content,
                                            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false))
        UNUserNotificationCenter.current().add(request)
    }

    /// One reminder per bill at 9:00 the day before it's due.
    static func rescheduleBills(_ bills: [Bill]) {
        let center = UNUserNotificationCenter.current()
        let items = bills.map { (id: $0.id.uuidString, name: $0.name, amount: $0.amount, due: $0.nextDueDate, on: $0.remindersOn) }
        let enabled = AppSettings.billReminders
        let code = AppSettings.currency
        Task {
            let requests = await center.pendingNotificationRequests()
            let old = requests.map(\.identifier).filter { $0.hasPrefix("bill-") }
            center.removePendingNotificationRequests(withIdentifiers: old)
            guard enabled else { return }
            let cal = Calendar.current
            for item in items where item.on {
                guard let dayBefore = cal.date(byAdding: .day, value: -1, to: item.due) else { continue }
                var comps = cal.dateComponents([.year, .month, .day], from: dayBefore)
                comps.hour = 9
                guard let fire = cal.date(from: comps), fire > Date() else { continue }
                let content = UNMutableNotificationContent()
                content.title = "\(item.name) is due tomorrow"
                content.body = "\(Money.format(item.amount, code)) will be due. Tap to review your bills."
                content.sound = .default
                let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
                try? await center.add(UNNotificationRequest(identifier: "bill-\(item.id)", content: content, trigger: trigger))
            }
        }
    }
}
