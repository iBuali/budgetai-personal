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

    /// Schedules monthly payment due reminders for Visa / credit card accounts so the user can pay before bank fees apply.
    static func rescheduleCreditCards(_ accounts: [Account]) {
        let center = UNUserNotificationCenter.current()
        struct CardReminderItem {
            let id: String
            let name: String
            let balance: Double
            let daysBefore: Int
            let dueDates: [Date]
        }
        let items: [CardReminderItem] = accounts
            .filter { $0.kind == .creditCard && $0.paymentDueReminder }
            .map {
                CardReminderItem(
                    id: $0.id.uuidString,
                    name: $0.name.isEmpty ? "Visa Card" : $0.name,
                    balance: $0.balance,
                    daysBefore: max(0, $0.paymentReminderDaysBefore),
                    dueDates: $0.upcomingDueDates(count: 6)
                )
            }
        let code = AppSettings.currency
        Task {
            let requests = await center.pendingNotificationRequests()
            let old = requests.map(\.identifier).filter { $0.hasPrefix("cc-due-") }
            center.removePendingNotificationRequests(withIdentifiers: old)
            guard !items.isEmpty else { return }
            let cal = Calendar.current
            let now = Date()
            for item in items {
                for (idx, due) in item.dueDates.enumerated() {
                    let dueLabel = due.formatted(.dateTime.month(.abbreviated).day())
                    if let fireDay = cal.date(byAdding: .day, value: -item.daysBefore, to: due) {
                        var comps = cal.dateComponents([.year, .month, .day], from: fireDay)
                        comps.hour = 9
                        comps.minute = 0
                        if let fire = cal.date(from: comps), fire > now {
                            let content = UNMutableNotificationContent()
                            if item.daysBefore == 0 {
                                content.title = "\(item.name) payment due today"
                            } else {
                                content.title = "\(item.name) payment due in \(item.daysBefore) day\(item.daysBefore == 1 ? "" : "s")"
                            }
                            if idx == 0 && item.balance > 0.0005 {
                                content.body = "Balance owed: \(Money.format(item.balance, code)). Pay by \(dueLabel) before the bank deducts late fees."
                            } else {
                                content.body = "Pay your \(item.name) balance by \(dueLabel) before the bank deducts late fees."
                            }
                            content.sound = .default
                            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
                            try? await center.add(UNNotificationRequest(identifier: "cc-due-\(item.id)-\(idx)", content: content, trigger: trigger))
                        }
                    }
                    // Also add a same-day morning reminder on the due date itself if the primary alert was days earlier
                    if item.daysBefore > 0 {
                        var dueComps = cal.dateComponents([.year, .month, .day], from: due)
                        dueComps.hour = 9
                        dueComps.minute = 0
                        if let dueFire = cal.date(from: dueComps), dueFire > now {
                            let content = UNMutableNotificationContent()
                            content.title = "\(item.name) payment is due today"
                            content.body = "Complete your \(item.name) payment today before the bank deducts fees."
                            content.sound = .default
                            let trigger = UNCalendarNotificationTrigger(dateMatching: dueComps, repeats: false)
                            try? await center.add(UNNotificationRequest(identifier: "cc-due-today-\(item.id)-\(idx)", content: content, trigger: trigger))
                        }
                    }
                }
            }
        }
    }
}
