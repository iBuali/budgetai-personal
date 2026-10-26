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
        abs(value).formatted(.number.precision(.fractionLength(decimals)).locale(locale))
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
        if v >= 10_000 { return (v / 1000).formatted(.number.precision(.fractionLength(1)).locale(locale)) + "k" }
        return v.formatted(.number.precision(.fractionLength(0)).locale(locale))
    }

    static func parse(_ text: String) -> Double? {
        let cleaned = text.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces)
        return Double(cleaned)
    }

    static let popularCurrencies = ["BHD", "SAR", "AED", "KWD", "QAR", "OMR", "USD", "EUR", "GBP", "INR", "PKR", "EGP"]
}
