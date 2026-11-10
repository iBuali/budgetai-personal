import Foundation
import SwiftData
import SwiftUI

// MARK: - Categories

/// A category key. Built-ins are static constants; custom categories and sub-categories
/// are user-created (`CustomCategory`) and resolved through `CategoryRegistry`.
struct SpendCategory: Hashable, Identifiable {
    let rawValue: String
    var id: String { rawValue }

    private init(key: String) { rawValue = key }

    /// Returns nil for unknown keys (e.g. a deleted custom category).
    init?(rawValue: String) {
        guard SpendCategory.builtInInfo[rawValue] != nil || CategoryRegistry.shared.info(rawValue) != nil else { return nil }
        self.rawValue = rawValue
    }

    static func unchecked(_ key: String) -> SpendCategory { SpendCategory(key: key) }

    static let groceries = SpendCategory(key: "groceries")
    static let dining = SpendCategory(key: "dining")
    static let transport = SpendCategory(key: "transport")
    static let shopping = SpendCategory(key: "shopping")
    static let bills = SpendCategory(key: "bills")
    static let housing = SpendCategory(key: "housing")
    static let health = SpendCategory(key: "health")
    static let entertainment = SpendCategory(key: "entertainment")
    static let subscriptions = SpendCategory(key: "subscriptions")
    static let education = SpendCategory(key: "education")
    static let travel = SpendCategory(key: "travel")
    static let visaTransfer = SpendCategory(key: "visa_transfer")
    static let internalTransfer = SpendCategory(key: "internal_transfer")
    static let transfers = SpendCategory(key: "transfers")
    static let income = SpendCategory(key: "income")
    static let other = SpendCategory(key: "other")

    static let builtIns: [SpendCategory] = [.groceries, .dining, .transport, .shopping, .bills, .housing, .health,
                                            .entertainment, .subscriptions, .education, .travel, .visaTransfer, .internalTransfer, .transfers, .income, .other]

    struct Info {
        var title: String
        var shortTitle: String
        var symbol: String
        var emoji: String
        var color: Color
        var isEssential: Bool
        var isIncome: Bool
        var parentKey: String
    }

    static let builtInHex: [String: Int] = [
        "groceries": 0x22A565,
        "dining": 0xF08A24,
        "transport": 0x2F6BFF,
        "shopping": 0x8B5CF6,
        "bills": 0xE9A23B,
        "housing": 0x0EA5A4,
        "health": 0xEC4899,
        "entertainment": 0x6366F1,
        "subscriptions": 0xF05252,
        "education": 0x0891B2,
        "travel": 0x0EA5E9,
        "visa_transfer": 0xF08A24,
        "internal_transfer": 0x1E3FAE,
        "transfers": 0x6B7385,
        "income": 0x2BB673,
        "other": 0x8A93A6,
    ]

    static let builtInInfo: [String: Info] = [
        "groceries": Info(title: "Groceries", shortTitle: "Groceries", symbol: "cart.fill", emoji: "", color: Color(hex: 0x22A565), isEssential: true, isIncome: false, parentKey: ""),
        "dining": Info(title: "Food & Dining", shortTitle: "Food", symbol: "fork.knife", emoji: "", color: Color(hex: 0xF08A24), isEssential: false, isIncome: false, parentKey: ""),
        "transport": Info(title: "Transport", shortTitle: "Transport", symbol: "car.fill", emoji: "", color: Color(hex: 0x2F6BFF), isEssential: true, isIncome: false, parentKey: ""),
        "shopping": Info(title: "Shopping", shortTitle: "Shopping", symbol: "bag.fill", emoji: "", color: Color(hex: 0x8B5CF6), isEssential: false, isIncome: false, parentKey: ""),
        "bills": Info(title: "Bills & Utilities", shortTitle: "Bills", symbol: "bolt.fill", emoji: "", color: Color(hex: 0xE9A23B), isEssential: true, isIncome: false, parentKey: ""),
        "housing": Info(title: "Rent & Housing", shortTitle: "Housing", symbol: "house.fill", emoji: "", color: Color(hex: 0x0EA5A4), isEssential: true, isIncome: false, parentKey: ""),
        "health": Info(title: "Health", shortTitle: "Health", symbol: "cross.case.fill", emoji: "", color: Color(hex: 0xEC4899), isEssential: true, isIncome: false, parentKey: ""),
        "entertainment": Info(title: "Entertainment", shortTitle: "Entertainment", symbol: "popcorn.fill", emoji: "", color: Color(hex: 0x6366F1), isEssential: false, isIncome: false, parentKey: ""),
        "subscriptions": Info(title: "Subscriptions", shortTitle: "Subscriptions", symbol: "play.rectangle.fill", emoji: "", color: Color(hex: 0xF05252), isEssential: false, isIncome: false, parentKey: ""),
        "education": Info(title: "Education", shortTitle: "Education", symbol: "graduationcap.fill", emoji: "", color: Color(hex: 0x0891B2), isEssential: true, isIncome: false, parentKey: ""),
        "travel": Info(title: "Travel", shortTitle: "Travel", symbol: "airplane", emoji: "", color: Color(hex: 0x0EA5E9), isEssential: false, isIncome: false, parentKey: ""),
        "visa_transfer": Info(title: "Transfer to Visa Card", shortTitle: "Visa Card", symbol: "creditcard.fill", emoji: "", color: Color(hex: 0xF08A24), isEssential: false, isIncome: false, parentKey: ""),
        "internal_transfer": Info(title: "Internal Transfer", shortTitle: "Internal", symbol: "arrow.left.arrow.right.circle.fill", emoji: "", color: Theme.cobalt, isEssential: false, isIncome: false, parentKey: ""),
        "transfers": Info(title: "Transfers", shortTitle: "Transfers", symbol: "arrow.left.arrow.right", emoji: "", color: Color(hex: 0x6B7385), isEssential: false, isIncome: false, parentKey: ""),
        "income": Info(title: "Income", shortTitle: "Income", symbol: "arrow.down", emoji: "", color: Color(hex: 0x2BB673), isEssential: false, isIncome: true, parentKey: ""),
        "other": Info(title: "Other", shortTitle: "Other", symbol: "square.grid.2x2.fill", emoji: "", color: Color(hex: 0x8A93A6), isEssential: false, isIncome: false, parentKey: ""),
    ]

    var info: Info {
        CategoryRegistry.shared.info(rawValue) ?? SpendCategory.builtInInfo[rawValue]
            ?? Info(title: "Other", shortTitle: "Other", symbol: "square.grid.2x2.fill", emoji: "", color: Color(hex: 0x8A93A6), isEssential: false, isIncome: false, parentKey: "")
    }

    var title: String { info.title }
    var shortTitle: String { info.shortTitle }
    var symbol: String { info.symbol }
    var emoji: String { info.emoji }
    var color: Color { info.color }
    /// Essential spending is protected when calculating Safe to Spend.
    var isEssential: Bool { info.isEssential }
    var isIncomeCategory: Bool { info.isIncome }
    var isBuiltIn: Bool { SpendCategory.builtInInfo[rawValue] != nil }
    var isSubcategory: Bool { false }
    var parent: SpendCategory? { nil }
    var subcategories: [SpendCategory] { [] }

    /// Top-level categories (built-in + custom).
    static var allCases: [SpendCategory] {
        builtIns + CategoryRegistry.shared.topLevel.filter { c in SpendCategory.builtInInfo[c.rawValue] == nil && !c.isIncomeCategory } + CategoryRegistry.shared.topLevel.filter { c in SpendCategory.builtInInfo[c.rawValue] == nil && c.isIncomeCategory }
    }
    static var expenseCases: [SpendCategory] { allCases.filter { !$0.isIncomeCategory } }
    static var incomeCases: [SpendCategory] { allCases.filter(\.isIncomeCategory) }
}

/// User-created category or sub-category (parentKey set).
@Model
final class CustomCategory {
    var id: UUID = UUID()
    var key: String = ""
    var name: String = ""
    var emoji: String = ""
    var colorHex: Int = 0x1E3FAE
    var parentKey: String = ""
    var isIncome: Bool = false
    var isEssential: Bool = false
    var createdAt: Date = Date()

    init(name: String, emoji: String, colorHex: Int, parentKey: String = "", isIncome: Bool = false, isEssential: Bool = false, key: String? = nil) {
        let id = UUID()
        self.id = id
        self.key = key ?? ("c-" + id.uuidString.prefix(8).lowercased())
        self.name = name
        self.emoji = emoji
        self.colorHex = colorHex
        self.parentKey = parentKey
        self.isIncome = isIncome
        self.isEssential = isEssential
        self.createdAt = Date()
    }
}

/// In-memory, observable cache of custom categories so lookups are cheap everywhere.
@Observable
final class CategoryRegistry {
    static let shared = CategoryRegistry()

    private(set) var infos: [String: SpendCategory.Info] = [:]
    private(set) var order: [String] = []

    func info(_ key: String) -> SpendCategory.Info? { infos[key] }

    var topLevel: [SpendCategory] {
        order.filter { infos[$0]?.parentKey.isEmpty == true }.map(SpendCategory.unchecked)
    }

    func children(of key: String) -> [SpendCategory] {
        order.filter { infos[$0]?.parentKey == key }.map(SpendCategory.unchecked)
    }

    func reload(context: ModelContext) {
        let items = (try? context.fetch(FetchDescriptor<CustomCategory>(sortBy: [SortDescriptor(\.createdAt)]))) ?? []
        var map: [String: SpendCategory.Info] = [:]
        var topKeys: [String] = []
        for c in items where c.parentKey.isEmpty {
            let symbol = SpendCategory.builtInInfo[c.key]?.symbol ?? "tag.fill"
            map[c.key] = SpendCategory.Info(
                title: c.name, shortTitle: c.name, symbol: symbol,
                emoji: c.emoji,
                color: Color(hex: UInt32(c.colorHex)),
                isEssential: c.isEssential,
                isIncome: c.isIncome,
                parentKey: "")
            topKeys.append(c.key)
        }
        infos = map
        order = topKeys
    }
}

// MARK: - Accounts

enum AccountKind: String, CaseIterable, Identifiable {
    case cash, bank, investment, property, otherAsset, loan, creditCard

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cash: "Cash"
        case .bank: "Bank account"
        case .investment: "Investment"
        case .property: "Property & vehicles"
        case .otherAsset: "Other asset"
        case .loan: "Loan"
        case .creditCard: "Credit card"
        }
    }

    var symbol: String {
        switch self {
        case .cash: "banknote.fill"
        case .bank: "building.columns.fill"
        case .investment: "chart.line.uptrend.xyaxis"
        case .property: "car.fill"
        case .otherAsset: "shippingbox.fill"
        case .loan: "doc.text.fill"
        case .creditCard: "creditcard.fill"
        }
    }

    var color: Color {
        switch self {
        case .cash: Color(hex: 0x22A565)
        case .bank: Theme.cobalt
        case .investment: Color(hex: 0x8B5CF6)
        case .property: Color(hex: 0x0EA5A4)
        case .otherAsset: Color(hex: 0x8A93A6)
        case .loan: Theme.negative
        case .creditCard: Color(hex: 0xF08A24)
        }
    }

    var isLiability: Bool { self == .loan || self == .creditCard }
    /// Money that can actually be spent today.
    var isLiquid: Bool { self == .cash || self == .bank }
}

@Model
final class Account {
    var id: UUID = UUID()
    var name: String = ""
    var kindRaw: String = AccountKind.bank.rawValue
    var institution: String = ""
    /// For liabilities this is the amount owed (positive).
    var balance: Double = 0
    var createdAt: Date = Date()
    var emoji: String = ""
    /// Last digits of the card/account as they appear in bank SMS, used to route imports.
    var smsMatch: String = ""
    /// Whether this account's balance is included in Net Worth calculations.
    var includeInNetWorth: Bool = true
    /// Whether to notify the user before the credit card payment due date so they can pay before bank fees apply.
    var paymentDueReminder: Bool = false
    /// Next payment due date for a credit card (repeats monthly).
    var paymentDueDate: Date = Calendar.current.date(byAdding: .day, value: 14, to: .now) ?? .now
    /// How many days before `paymentDueDate` to send the payment reminder notification.
    var paymentReminderDaysBefore: Int = 3

    init(name: String, kind: AccountKind, institution: String = "", balance: Double, emoji: String = "", includeInNetWorth: Bool = true) {
        self.id = UUID()
        self.name = name
        self.kindRaw = kind.rawValue
        self.institution = institution
        self.balance = balance
        self.createdAt = Date()
        self.emoji = emoji
        self.includeInNetWorth = includeInNetWorth
        self.paymentDueDate = Calendar.current.date(byAdding: .day, value: 14, to: .now) ?? .now
    }

    var kind: AccountKind {
        get { AccountKind(rawValue: kindRaw) ?? .bank }
        set { kindRaw = newValue.rawValue }
    }

    /// Returns the next upcoming monthly due date on or after `now` (preserving the chosen day of month).
    func nextUpcomingDueDate(from now: Date = .now, calendar: Calendar = .current) -> Date {
        let today = calendar.startOfDay(for: now)
        let anchorDay = calendar.component(.day, from: paymentDueDate)
        var candidate = calendar.startOfDay(for: paymentDueDate)
        if candidate >= today {
            return candidate
        }
        var monthCursor = calendar.date(from: calendar.dateComponents([.year, .month], from: today)) ?? today
        for _ in 0..<24 {
            let maxDay = calendar.range(of: .day, in: .month, for: monthCursor)?.upperBound.advanced(by: -1) ?? 28
            var comps = calendar.dateComponents([.year, .month], from: monthCursor)
            comps.day = min(max(1, anchorDay), maxDay)
            if let d = calendar.date(from: comps), d >= today {
                candidate = d
                break
            }
            monthCursor = calendar.date(byAdding: .month, value: 1, to: monthCursor) ?? monthCursor
        }
        return candidate
    }

    /// Upcoming monthly due dates starting from `nextUpcomingDueDate`, used to schedule notifications across variable-length months.
    func upcomingDueDates(count: Int = 6, from now: Date = .now, calendar: Calendar = .current) -> [Date] {
        guard count > 0 else { return [] }
        let first = nextUpcomingDueDate(from: now, calendar: calendar)
        let anchorDay = max(calendar.component(.day, from: paymentDueDate), calendar.component(.day, from: first))
        let baseMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: first)) ?? first
        var dates: [Date] = []
        for offset in 0..<count {
            guard let targetMonth = calendar.date(byAdding: .month, value: offset, to: baseMonth) else { continue }
            let maxDay = calendar.range(of: .day, in: .month, for: targetMonth)?.upperBound.advanced(by: -1) ?? 28
            var comps = calendar.dateComponents([.year, .month], from: targetMonth)
            comps.day = min(max(1, anchorDay), maxDay)
            if let d = calendar.date(from: comps) {
                dates.append(d)
            }
        }
        return dates
    }

    /// When a credit card's balance is paid in full within 20 days before its upcoming due date, move the due date to next month.
    func advanceDueDateIfPaid(on paymentDate: Date = .now, calendar: Calendar = .current) {
        guard kind == .creditCard, paymentDueReminder, balance <= 0.0005 else { return }
        let payDay = calendar.startOfDay(for: paymentDate)
        let upcoming = nextUpcomingDueDate(from: payDay, calendar: calendar)
        let daysUntilDue = calendar.dateComponents([.day], from: payDay, to: upcoming).day ?? 99
        if daysUntilDue >= 0 && daysUntilDue <= 20 {
            let anchorDay = calendar.component(.day, from: paymentDueDate)
            if let nextMonth = calendar.date(byAdding: .month, value: 1, to: upcoming) {
                let maxDay = calendar.range(of: .day, in: .month, for: nextMonth)?.upperBound.advanced(by: -1) ?? 28
                var comps = calendar.dateComponents([.year, .month], from: nextMonth)
                comps.day = min(max(1, anchorDay), maxDay)
                if let advanced = calendar.date(from: comps) {
                    paymentDueDate = advanced
                }
            }
        }
    }
}

// MARK: - Transactions

enum TxSource: String, CaseIterable {
    case manual, sms, bank, bill, transfer

    var title: String {
        switch self {
        case .manual: "Added manually"
        case .sms: "Imported from bank SMS"
        case .bank: "Synced from bank"
        case .bill: "Bill payment"
        case .transfer: "Transfer"
        }
    }

    var symbol: String {
        switch self {
        case .manual: "hand.tap.fill"
        case .sms: "message.fill"
        case .bank: "building.columns.fill"
        case .bill: "calendar"
        case .transfer: "arrow.left.arrow.right"
        }
    }
}

/// Fine-grained classification for bank SMS transactions.
enum SMSTransactionType: String, CaseIterable, Codable, Identifiable {
    case income = "income"
    case expense = "expense"
    case transferIn = "transfer_in"
    case transferOut = "transfer_out"
    case internalTransfer = "internal_transfer"
    case fee = "fee"
    case refund = "refund"
    case unknown = "unknown"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .income: "Income"
        case .expense: "Expense"
        case .transferIn: "Transfer In"
        case .transferOut: "Transfer Out"
        case .internalTransfer: "Internal Transfer"
        case .fee: "Fee"
        case .refund: "Refund"
        case .unknown: "Unknown (Needs Review)"
        }
    }

    /// Cases shown in the Transaction Type picker (Internal Transfer is selected as a Category instead).
    static let pickerCases: [SMSTransactionType] = [
        .income, .expense, .transferIn, .transferOut, .fee, .refund, .unknown
    ]

    var isTransferType: Bool {
        self == .transferIn || self == .transferOut || self == .internalTransfer
    }

    var isIncomeDirection: Bool {
        self == .income || self == .transferIn || self == .refund
    }

    var countsAsIncome: Bool {
        self == .income
    }

    var countsAsExpense: Bool {
        self == .expense || self == .fee
    }
}

/// Confidence level assigned by the SMS parser or user rule.
enum SMSConfidence: String, CaseIterable, Codable, Identifiable {
    case high = "high"
    case medium = "medium"
    case low = "low"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .high: "High"
        case .medium: "Medium"
        case .low: "Low (Review Required)"
        }
    }
}

@Model
final class MoneyTransaction {
    var id: UUID = UUID()
    var amount: Double = 0
    var isIncome: Bool = false
    var merchant: String = ""
    var categoryRaw: String = SpendCategory.other.rawValue
    var date: Date = Date()
    var note: String = ""
    var sourceRaw: String = TxSource.manual.rawValue
    var accountID: UUID?
    var isPossibleDuplicate: Bool = false
    var aiCategorized: Bool = false
    var rawText: String?
    /// Imported from SMS and waiting for the user's approval; not applied to balances yet.
    var isPending: Bool = false
    /// Destination account for transfers.
    var toAccountID: UUID?
    var subcategoryKey: String = ""
    /// Available balance reported by the bank SMS for the source account (accountID), if any.
    var smsBalance: Double?
    /// Available balance reported by the bank SMS for the destination account (toAccountID), if any.
    var smsToBalance: Double?
    /// How much the source account balance was corrected to match the bank SMS.
    var balanceAdjustment: Double = 0
    /// How much the destination account balance was corrected to match the bank SMS.
    var toBalanceAdjustment: Double = 0
    /// Detected or user-assigned SMS sender bank (kept separate from the accountID involved in the transaction).
    var smsBank: String?
    /// Raw SMS sender ID or phone number, if provided.
    var smsSender: String?
    /// Stored raw value of `SMSTransactionType`.
    var smsTransactionTypeRaw: String = ""
    /// Stored raw value of `SMSConfidence`.
    var smsConfidenceRaw: String = ""
    /// Human-readable reason explaining how the transaction was classified.
    var smsClassificationReason: String = ""
    /// Transaction reference number extracted from the SMS (e.g. BIB103KAK000KZUM).
    var smsReference: String?
    /// Card or source account suffix extracted from the SMS.
    var smsAccountSuffix: String?
    /// Recipient IBAN or destination account suffix extracted from the SMS (e.g. 0846).
    var smsRecipientSuffix: String?
    /// Linked savings goal that receives this transfer's amount automatically.
    var goalID: UUID?
    /// True when `smsBalance` in the SMS represents a credit card's available credit limit rather than a bank deposit balance.
    var smsBalanceIsCardLimit: Bool = false
    /// Name of the place of purchase or location (e.g. "City Centre Bahrain", "Manama").
    var locationName: String?
    /// Formatted street/city address for the transaction location, if available.
    var locationAddress: String?
    /// Latitude coordinate for the transaction location.
    var latitude: Double?
    /// Longitude coordinate for the transaction location.
    var longitude: Double?

    var hasLocation: Bool {
        if let lat = latitude, let lon = longitude, abs(lat) > 0.0001 || abs(lon) > 0.0001 {
            return true
        }
        if let name = locationName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return true
        }
        return false
    }

    init(amount: Double, isIncome: Bool, merchant: String, category: SpendCategory, date: Date = .now,
         note: String = "", source: TxSource = .manual, accountID: UUID? = nil) {
        self.id = UUID()
        self.amount = abs(amount)
        self.isIncome = isIncome
        self.merchant = merchant
        self.categoryRaw = category.rawValue
        self.date = date
        self.note = note
        self.sourceRaw = source.rawValue
        self.accountID = accountID
    }

    var category: SpendCategory {
        get { SpendCategory(rawValue: categoryRaw) ?? .other }
        set { categoryRaw = newValue.rawValue }
    }

    var subcategory: SpendCategory? {
        get { nil }
        set { subcategoryKey = "" }
    }

    var smsTransactionType: SMSTransactionType? {
        get { smsTransactionTypeRaw.isEmpty ? nil : SMSTransactionType(rawValue: smsTransactionTypeRaw) }
        set { smsTransactionTypeRaw = newValue?.rawValue ?? "" }
    }

    var smsConfidence: SMSConfidence? {
        get { smsConfidenceRaw.isEmpty ? nil : SMSConfidence(rawValue: smsConfidenceRaw) }
        set { smsConfidenceRaw = newValue?.rawValue ?? "" }
    }

    var effectiveTransactionType: SMSTransactionType {
        if category == .internalTransfer || category == .visaTransfer { return .internalTransfer }
        if let t = smsTransactionType { return t }
        if category == .transfers {
            if toAccountID != nil { return .internalTransfer }
            return isIncome ? .transferIn : .transferOut
        }
        return isIncome ? .income : .expense
    }

    /// Most specific category for display (sub-category if set).
    var displayCategory: SpendCategory { subcategory ?? category }

    var isCardLimitBalance: Bool {
        smsBalanceIsCardLimit || category == .visaTransfer
    }

    var isTransfer: Bool {
        if category == .internalTransfer || category == .visaTransfer || category == .transfers { return true }
        if let t = smsTransactionType { return t.isTransferType }
        return false
    }

    var source: TxSource {
        get { TxSource(rawValue: sourceRaw) ?? .manual }
        set { sourceRaw = newValue.rawValue }
    }

    var signedAmount: Double { isIncome ? amount : -amount }

    var isSpending: Bool {
        if category == .internalTransfer || category == .visaTransfer || category == .transfers { return false }
        if let t = smsTransactionType { return t.countsAsExpense }
        return !isIncome
    }

    var isOrdinaryIncome: Bool {
        if category == .internalTransfer || category == .visaTransfer || category == .transfers { return false }
        if let t = smsTransactionType { return t.countsAsIncome }
        return isIncome
    }

    /// Specific review reasons if this SMS transaction needs attention before approval.
    func reviewReasons(accounts: [Account]) -> [String] {
        guard source == .sms else { return isPending ? ["Waiting for approval"] : [] }
        var reasons: [String] = []
        let hasMatchedAccount = accountID != nil && (accounts.isEmpty || accounts.contains(where: { $0.id == accountID }))

        // Unknown bank sender (only if no user account matched)
        let bankClean = smsBank?.trimmingCharacters(in: .whitespacesAndNewlines)
        if !hasMatchedAccount && (bankClean == nil || bankClean?.isEmpty == true || bankClean?.lowercased().contains("unknown") == true) {
            reasons.append("Unknown sender bank")
        }

        // Unmatched account
        if accountID == nil {
            reasons.append("Unmatched account")
        }

        // Unknown transaction type
        if smsTransactionType == .unknown {
            reasons.append("Unknown transaction type")
        }

        if reasons.isEmpty && isPending {
            reasons.append("Waiting for approval")
        }
        return reasons
    }

    /// True if this transaction meets the quarantine criteria (unknown bank, unmatched account/balance, or uncertain).
    var isUnmatchedOrUncertain: Bool {
        guard source == .sms else { return isPending }
        let bankClean = smsBank?.trimmingCharacters(in: .whitespacesAndNewlines)
        let bankUnknown = accountID == nil && (bankClean == nil || bankClean?.isEmpty == true || bankClean?.lowercased().contains("unknown") == true)
        let accountUnmatched = accountID == nil
        let uncertain = smsConfidence == .low || smsTransactionType == .unknown
        return bankUnknown || accountUnmatched || uncertain || isPending
    }
}

// MARK: - Budgets & goals

@Model
final class Budget {
    var id: UUID = UUID()
    var name: String = ""
    var categoryRaw: String = SpendCategory.groceries.rawValue
    /// Comma-separated list of SpendCategory rawValues assigned to this budget.
    var categoryKeysRaw: String = ""
    var limit: Double = 0
    var createdAt: Date = Date()

    init(name: String = "", categories: [SpendCategory], limit: Double) {
        self.id = UUID()
        let list = categories.isEmpty ? [.other] : categories
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.categoryRaw = list[0].rawValue
        self.categoryKeysRaw = list.map(\.rawValue).joined(separator: ",")
        self.limit = limit
        self.createdAt = Date()
    }

    convenience init(category: SpendCategory, limit: Double) {
        self.init(name: category.title, categories: [category], limit: limit)
    }

    var category: SpendCategory {
        get { categories.first ?? SpendCategory(rawValue: categoryRaw) ?? .other }
        set {
            categoryRaw = newValue.rawValue
            if categoryKeysRaw.isEmpty {
                categoryKeysRaw = newValue.rawValue
            }
        }
    }

    var categories: [SpendCategory] {
        get {
            let parsed = categoryKeysRaw
                .split(separator: ",")
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .compactMap { SpendCategory(rawValue: $0) }
            if !parsed.isEmpty { return parsed }
            if let single = SpendCategory(rawValue: categoryRaw) { return [single] }
            return [.other]
        }
        set {
            let unique = Array(NSOrderedSet(array: newValue)) as? [SpendCategory] ?? newValue
            let list = unique.isEmpty ? [.other] : unique
            categoryRaw = list[0].rawValue
            categoryKeysRaw = list.map(\.rawValue).joined(separator: ",")
        }
    }

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        let cats = categories
        if cats.count == 1 { return cats[0].title }
        return cats.map(\.shortTitle).joined(separator: " & ")
    }

    func includes(_ cat: SpendCategory) -> Bool {
        categories.contains(cat)
    }
}

@Model
final class SavingsGoal {
    var id: UUID = UUID()
    var name: String = ""
    var symbol: String = "star.fill"
    var target: Double = 0
    var saved: Double = 0
    var targetDate: Date = Date()
    var monthlyCommitment: Double = 0
    var monthKey: String = ""
    var monthContributed: Double = 0
    var createdAt: Date = Date()
    /// Optional savings account linked to this goal so transfers into that account automatically add to `saved`.
    var linkedAccountID: UUID?
    /// Optional IBAN or account suffix (e.g. "0846") so SMS transfers to this suffix automatically add to `saved`.
    var smsMatch: String = ""

    init(name: String, symbol: String, target: Double, saved: Double, targetDate: Date, monthlyCommitment: Double,
         linkedAccountID: UUID? = nil, smsMatch: String = "") {
        self.id = UUID()
        self.name = name
        self.symbol = symbol
        self.target = target
        self.saved = saved
        self.targetDate = targetDate
        self.monthlyCommitment = monthlyCommitment
        self.createdAt = Date()
        self.linkedAccountID = linkedAccountID
        self.smsMatch = smsMatch
    }

    var progress: Double { target > 0 ? min(saved / target, 1) : 0 }
    var isComplete: Bool { saved >= target && target > 0 }

    func contributedThisMonth(now: Date = .now) -> Double {
        monthKey == DateKeys.month(now) ? monthContributed : 0
    }

    func remainingCommitment(now: Date = .now) -> Double {
        guard !isComplete else { return 0 }
        return max(0, monthlyCommitment - contributedThisMonth(now: now))
    }
}

// MARK: - Bills

enum BillFrequency: String, CaseIterable, Identifiable {
    case weekly, monthly, quarterly, yearly
    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    func next(after date: Date, calendar: Calendar = .current) -> Date {
        switch self {
        case .weekly: calendar.date(byAdding: .day, value: 7, to: date) ?? date
        case .monthly: calendar.date(byAdding: .month, value: 1, to: date) ?? date
        case .quarterly: calendar.date(byAdding: .month, value: 3, to: date) ?? date
        case .yearly: calendar.date(byAdding: .year, value: 1, to: date) ?? date
        }
    }

    /// Normalised monthly cost multiplier.
    var monthlyFactor: Double {
        switch self {
        case .weekly: 52.0 / 12.0
        case .monthly: 1
        case .quarterly: 1.0 / 3.0
        case .yearly: 1.0 / 12.0
        }
    }
}

enum BillPaymentMethod: String, Codable {
    case autoSMS = "auto_sms"
    case manual = "manual"

    var title: String {
        switch self {
        case .autoSMS: return "Auto-paid via SMS"
        case .manual: return "Manually paid"
        }
    }

    var badgeText: String {
        switch self {
        case .autoSMS: return "Auto-paid via SMS"
        case .manual: return "Manually paid"
        }
    }

    var icon: String {
        switch self {
        case .autoSMS: return "sparkles"
        case .manual: return "checkmark.circle.fill"
        }
    }
}

@Model
final class Bill {
    var id: UUID = UUID()
    var name: String = ""
    var amount: Double = 0
    var categoryRaw: String = SpendCategory.bills.rawValue
    var nextDueDate: Date = Date()
    var frequencyRaw: String = BillFrequency.monthly.rawValue
    var isSubscription: Bool = false
    var remindersOn: Bool = true
    var lastPaidAt: Date?
    var lastPaidMethodRaw: String?
    var lastPaidAmount: Double?
    var lastPaidTxID: UUID?
    /// Comma-separated custom keywords to match in incoming bank SMS (e.g. "Batelco, Fiber, SADAD").
    var keywordsRaw: String = ""

    init(name: String, amount: Double, category: SpendCategory, nextDueDate: Date,
         frequency: BillFrequency = .monthly, isSubscription: Bool = false, keywords: String = "") {
        self.id = UUID()
        self.name = name
        self.amount = amount
        self.categoryRaw = category.rawValue
        self.nextDueDate = nextDueDate
        self.frequencyRaw = frequency.rawValue
        self.isSubscription = isSubscription
        self.keywordsRaw = keywords
    }

    var keywords: [String] {
        get {
            keywordsRaw.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        set {
            keywordsRaw = newValue.joined(separator: ", ")
        }
    }

    var category: SpendCategory {
        get { SpendCategory(rawValue: categoryRaw) ?? .bills }
        set { categoryRaw = newValue.rawValue }
    }

    var frequency: BillFrequency {
        get { BillFrequency(rawValue: frequencyRaw) ?? .monthly }
        set { frequencyRaw = newValue.rawValue }
    }

    var monthlyCost: Double { amount * frequency.monthlyFactor }

    var lastPaidMethod: BillPaymentMethod? {
        get { lastPaidMethodRaw.flatMap(BillPaymentMethod.init(rawValue:)) }
        set { lastPaidMethodRaw = newValue?.rawValue }
    }

    /// Returns true if this bill has already been paid for the current cycle / period.
    func isPaidForCurrentCycle(now: Date = .now) -> Bool {
        guard let lastPaidAt else { return false }
        let calendar = Calendar.current
        switch frequency {
        case .weekly:
            if let interval = calendar.dateInterval(of: .weekOfYear, for: now) {
                return interval.contains(lastPaidAt)
            }
            return now.timeIntervalSince(lastPaidAt) < 7 * 86400
        case .monthly:
            let interval = Cycle.interval(containing: now)
            return interval.contains(lastPaidAt)
        case .quarterly:
            if let interval = calendar.dateInterval(of: .quarter, for: now) {
                return interval.contains(lastPaidAt)
            }
            return now.timeIntervalSince(lastPaidAt) < 90 * 86400
        case .yearly:
            if let interval = calendar.dateInterval(of: .year, for: now) {
                return interval.contains(lastPaidAt)
            }
            return now.timeIntervalSince(lastPaidAt) < 365 * 86400
        }
    }

    func markPaid(date: Date = .now, method: BillPaymentMethod, amount: Double? = nil, txID: UUID? = nil) {
        lastPaidAt = date
        lastPaidMethod = method
        lastPaidAmount = amount ?? self.amount
        lastPaidTxID = txID
        var next = frequency.next(after: nextDueDate)
        while next <= date { next = frequency.next(after: next) }
        nextDueDate = next
    }

    func unmarkPaid() {
        lastPaidAt = nil
        lastPaidMethod = nil
        lastPaidAmount = nil
        lastPaidTxID = nil
    }
}

// MARK: - Net worth history & chat

@Model
final class NetWorthSnapshot {
    var id: UUID = UUID()
    var day: Date = Date()
    var assets: Double = 0
    var liabilities: Double = 0

    init(day: Date, assets: Double, liabilities: Double) {
        self.id = UUID()
        self.day = day
        self.assets = assets
        self.liabilities = liabilities
    }

    var netWorth: Double { assets - liabilities }
}

@Model
final class ChatMessage {
    var id: UUID = UUID()
    var isUser: Bool = true
    var text: String = ""
    var date: Date = Date()
    var isError: Bool = false

    init(isUser: Bool, text: String, isError: Bool = false) {
        self.id = UUID()
        self.isUser = isUser
        self.text = text
        self.date = Date()
        self.isError = isError
    }
}

enum DateKeys {
    /// Key of the budget cycle containing `date` (respects the custom cycle start day).
    static func month(_ date: Date) -> String {
        let start = Cycle.interval(containing: date).start
        let c = Calendar.current.dateComponents([.year, .month, .day], from: start)
        return "\(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 1)"
    }
}

/// Budget month that starts on a user-chosen day (e.g. payday on the 25th).
enum Cycle {
    static var startDay: Int {
        let d = UserDefaults.standard.integer(forKey: Keys.cycleStartDay)
        return d >= 1 && d <= 28 ? d : 1
    }

    static func interval(containing date: Date, startDay: Int = Cycle.startDay) -> DateInterval {
        let cal = Calendar.current
        var comps = cal.dateComponents([.year, .month], from: date)
        comps.day = startDay
        var start = cal.date(from: comps) ?? cal.startOfDay(for: date)
        if start > date { start = cal.date(byAdding: .month, value: -1, to: start) ?? start }
        let end = cal.date(byAdding: .month, value: 1, to: start) ?? start.addingTimeInterval(86_400 * 30)
        return DateInterval(start: start, end: end)
    }

    /// "October" when cycles follow calendar months, otherwise "25 Oct – 24 Nov".
    static func label(_ interval: DateInterval, short: Bool = false) -> String {
        if startDay == 1 {
            return interval.start.formatted(short ? .dateTime.month(.abbreviated).year() : .dateTime.month(.wide))
        }
        let last = interval.end.addingTimeInterval(-1)
        return "\(interval.start.formatted(.dateTime.day().month(.abbreviated))) – \(last.formatted(.dateTime.day().month(.abbreviated)))"
    }
}
