import Foundation

enum Keys {
    static let currency = "currencyCode"
    static let userName = "userName"
    static let faceID = "faceIDEnabled"
    static let onboarded = "hasOnboarded"
    static let billReminders = "billReminders"
    static let budgetAlerts = "budgetAlerts"
    static let geminiModel = "geminiModel"
    static let cycleStartDay = "cycleStartDay"
    static let smsAutoApprove = "smsAutoApprove"
    static let smsAccountID = "smsAccountID"
    static let smsSyncBalance = "smsSyncBalance"
    static let iCloudAutoBackupEnabled = "iCloudAutoBackupEnabled"
    static let iCloudBackupSchedule = "iCloudBackupSchedule"
    static let iCloudLastBackupDate = "iCloudLastBackupDate"
    static let iCloudLastBackupStatus = "iCloudLastBackupStatus"
    static let homeAccountOrder = "homeAccountOrder"
    static let homeHiddenAccounts = "homeHiddenAccounts"
    static let netWorthChartExcludedAccounts = "netWorthChartExcludedAccounts"
    static let appearanceMode = "appearanceMode"
}

enum AppSettings {
    static var currency: String { UserDefaults.standard.string(forKey: Keys.currency) ?? "BHD" }
    static var billReminders: Bool { UserDefaults.standard.object(forKey: Keys.billReminders) as? Bool ?? true }
    static var budgetAlerts: Bool { UserDefaults.standard.object(forKey: Keys.budgetAlerts) as? Bool ?? true }
    static var smsAutoApprove: Bool { UserDefaults.standard.object(forKey: Keys.smsAutoApprove) as? Bool ?? true }
    static var smsSyncBalance: Bool { UserDefaults.standard.object(forKey: Keys.smsSyncBalance) as? Bool ?? true }
    /// Empty string means "detect automatically".
    static var smsAccountID: UUID? { UUID(uuidString: UserDefaults.standard.string(forKey: Keys.smsAccountID) ?? "") }
}

enum Money {
    private static let threeDecimal: Set<String> = ["BHD", "KWD", "OMR", "JOD", "TND", "LYD", "IQD"]
    private static let zeroDecimal: Set<String> = ["JPY", "KRW", "VND", "CLP", "ISK", "UGX", "PYG", "XAF", "XOF", "IDR"]
    private static let locale = Locale(identifier: "en_US")

    private static func cachedNumberFormatter(decimals: Int) -> NumberFormatter {
        let key = "BudgetAI.NumberFormatter.\(decimals)"
        let dict = Thread.current.threadDictionary
        if let cached = dict[key] as? NumberFormatter {
            return cached
        }
        let f = NumberFormatter()
        f.locale = locale
        f.numberStyle = .decimal
        f.usesGroupingSeparator = true
        f.minimumFractionDigits = decimals
        f.maximumFractionDigits = decimals
        dict[key] = f
        return f
    }

    static func symbol(_ code: String) -> String {
        switch code {
        case "BHD": "BD"
        case "KWD": "KD"
        case "QAR": "QR"
        case "USD": "$"
        case "EUR": "€"
        case "GBP": "£"
        case "INR": "₹"
        case "JPY": "¥"
        case "PKR": "Rs"
        default: code
        }
    }

    static func digits(_ code: String) -> Int {
        if threeDecimal.contains(code) { return 3 }
        if zeroDecimal.contains(code) { return 0 }
        return 2
    }

    static func number(_ value: Double, decimals: Int) -> String {
        let f = cachedNumberFormatter(decimals: decimals)
        return f.string(from: NSNumber(value: abs(value))) ?? "0"
    }

    /// "BD 4,286.750", "−BD 6.750", "+$12.00"
    static func format(_ value: Double, _ code: String, signed: Bool = false, decimals: Int? = nil) -> String {
        let d = decimals ?? digits(code)
        let rounded = (abs(value) * pow(10, Double(d))).rounded() / pow(10, Double(d))
        let num = number(rounded, decimals: d)
        let sign: String
        if value < 0 && rounded > 0 { sign = "−" } else if signed && rounded > 0 { sign = "+" } else { sign = "" }
        let sym = symbol(code)
        let gap = sym.count == 1 ? "" : " "
        return "\(sign)\(sym)\(gap)\(num)"
    }

    /// Short number for chart axes and dense rows: "1,148" / "4.2k"
    static func short(_ value: Double) -> String {
        let v = abs(value)
        if v >= 10_000 { return number(v / 1000, decimals: 1) + "k" }
        return number(v, decimals: 0)
    }

    static func parse(_ text: String) -> Double? {
        let cleaned = text.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces)
        return Double(cleaned)
    }

    static let popularCurrencies = ["BHD", "SAR", "AED", "KWD", "QAR", "OMR", "USD", "EUR", "GBP", "INR", "PKR", "EGP"]
}

enum DateFormatCache {
    static func shortTime(_ date: Date) -> String {
        let key = "BudgetAI.DateFormatter.shortTime"
        let dict = Thread.current.threadDictionary
        let f: DateFormatter
        if let cached = dict[key] as? DateFormatter {
            f = cached
        } else {
            f = DateFormatter()
            f.dateStyle = .none
            f.timeStyle = .short
            dict[key] = f
        }
        return f.string(from: date)
    }

    static func dayHeader(_ date: Date) -> String {
        let key = "BudgetAI.DateFormatter.dayHeader"
        let dict = Thread.current.threadDictionary
        let f: DateFormatter
        if let cached = dict[key] as? DateFormatter {
            f = cached
        } else {
            f = DateFormatter()
            f.setLocalizedDateFormatFromTemplate("EEEEMMMd")
            dict[key] = f
        }
        return f.string(from: date)
    }
}

struct HomeAccountPreferences {
    static func parseIDs(_ raw: String) -> [UUID] {
        raw.split(separator: ",")
            .compactMap { UUID(uuidString: String($0).trimmingCharacters(in: .whitespaces)) }
    }

    static func encodeIDs(_ ids: [UUID]) -> String {
        ids.map(\.uuidString).joined(separator: ",")
    }

    static func hiddenSet(_ hiddenRaw: String) -> Set<UUID> {
        Set(parseIDs(hiddenRaw))
    }

    static func orderedAccounts(
        from accounts: [Account],
        orderRaw: String,
        hiddenRaw: String,
        includeHidden: Bool = false
    ) -> [Account] {
        let orderIDs = parseIDs(orderRaw)
        let hidden = hiddenSet(hiddenRaw)
        let byID = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })

        var result: [Account] = []
        var seen: Set<UUID> = []

        for id in orderIDs {
            if let acc = byID[id], !seen.contains(id) {
                seen.insert(id)
                if includeHidden || !hidden.contains(id) {
                    result.append(acc)
                }
            }
        }

        for acc in accounts where !seen.contains(acc.id) {
            seen.insert(acc.id)
            if includeHidden || !hidden.contains(acc.id) {
                result.append(acc)
            }
        }

        return result
    }

    static func toggleVisibility(for id: UUID, hiddenRaw: String) -> String {
        var current = parseIDs(hiddenRaw)
        if let idx = current.firstIndex(of: id) {
            current.remove(at: idx)
        } else {
            current.append(id)
        }
        return encodeIDs(current)
    }

    static func move(
        from source: IndexSet,
        to destination: Int,
        in accounts: [Account],
        orderRaw: String
    ) -> String {
        var ordered = orderedAccounts(from: accounts, orderRaw: orderRaw, hiddenRaw: "", includeHidden: true).map(\.id)
        let moving = source.sorted().map { ordered[$0] }
        for idx in source.sorted(by: >) {
            ordered.remove(at: idx)
        }
        let adjustedDestination = destination - source.filter { $0 < destination }.count
        let insertIndex = min(max(0, adjustedDestination), ordered.count)
        ordered.insert(contentsOf: moving, at: insertIndex)
        return encodeIDs(ordered)
    }
}
