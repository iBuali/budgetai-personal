import Foundation
import SwiftData
import SwiftUI

// MARK: - Categories

enum SpendCategory: String, CaseIterable, Identifiable {
    case groceries, dining, transport, shopping, bills, housing, health, entertainment
    case subscriptions, education, travel, transfers, income, other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .groceries: "Groceries"
        case .dining: "Food & Dining"
        case .transport: "Transport"
        case .shopping: "Shopping"
        case .bills: "Bills & Utilities"
        case .housing: "Rent & Housing"
        case .health: "Health"
        case .entertainment: "Entertainment"
        case .subscriptions: "Subscriptions"
        case .education: "Education"
        case .travel: "Travel"
        case .transfers: "Transfers"
        case .income: "Income"
        case .other: "Other"
        }
    }

    var shortTitle: String {
        switch self {
        case .dining: "Food"
        case .bills: "Bills"
        case .housing: "Housing"
        default: title
        }
    }

    var symbol: String {
        switch self {
        case .groceries: "cart.fill"
        case .dining: "fork.knife"
        case .transport: "car.fill"
        case .shopping: "bag.fill"
        case .bills: "bolt.fill"
        case .housing: "house.fill"
        case .health: "cross.case.fill"
        case .entertainment: "popcorn.fill"
        case .subscriptions: "play.rectangle.fill"
        case .education: "graduationcap.fill"
        case .travel: "airplane"
        case .transfers: "arrow.left.arrow.right"
        case .income: "arrow.down"
        case .other: "square.grid.2x2.fill"
        }
    }

    var color: Color {
        switch self {
        case .groceries: Color(hex: 0x22A565)
        case .dining: Color(hex: 0xF08A24)
        case .transport: Color(hex: 0x2F6BFF)
        case .shopping: Color(hex: 0x8B5CF6)
        case .bills: Color(hex: 0xE9A23B)
        case .housing: Color(hex: 0x0EA5A4)
        case .health: Color(hex: 0xEC4899)
        case .entertainment: Color(hex: 0x6366F1)
        case .subscriptions: Color(hex: 0xF05252)
        case .education: Color(hex: 0x0891B2)
        case .travel: Color(hex: 0x0EA5E9)
        case .transfers: Color(hex: 0x6B7385)
        case .income: Color(hex: 0x2BB673)
        case .other: Color(hex: 0x8A93A6)
        }
    }

    /// Essential spending is protected when calculating Safe to Spend.
    var isEssential: Bool {
        switch self {
        case .groceries, .transport, .bills, .housing, .health, .education: true
        default: false
        }
    }

    static var expenseCases: [SpendCategory] { allCases.filter { $0 != .income } }
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

    init(name: String, kind: AccountKind, institution: String = "", balance: Double) {
        self.id = UUID()
        self.name = name
        self.kindRaw = kind.rawValue
        self.institution = institution
        self.balance = balance
        self.createdAt = Date()
    }

    var kind: AccountKind {
        get { AccountKind(rawValue: kindRaw) ?? .bank }
        set { kindRaw = newValue.rawValue }
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

    var source: TxSource {
        get { TxSource(rawValue: sourceRaw) ?? .manual }
        set { sourceRaw = newValue.rawValue }
    }

    var signedAmount: Double { isIncome ? amount : -amount }
    var isSpending: Bool { !isIncome && category != .transfers }
}

// MARK: - Budgets & goals

@Model
final class Budget {
    var id: UUID = UUID()
    var categoryRaw: String = SpendCategory.groceries.rawValue
    var limit: Double = 0
    var createdAt: Date = Date()

    init(category: SpendCategory, limit: Double) {
        self.id = UUID()
        self.categoryRaw = category.rawValue
        self.limit = limit
        self.createdAt = Date()
    }

    var category: SpendCategory {
        get { SpendCategory(rawValue: categoryRaw) ?? .other }
        set { categoryRaw = newValue.rawValue }
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

    init(name: String, symbol: String, target: Double, saved: Double, targetDate: Date, monthlyCommitment: Double) {
        self.id = UUID()
        self.name = name
        self.symbol = symbol
        self.target = target
        self.saved = saved
        self.targetDate = targetDate
        self.monthlyCommitment = monthlyCommitment
        self.createdAt = Date()
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

    init(name: String, amount: Double, category: SpendCategory, nextDueDate: Date,
         frequency: BillFrequency = .monthly, isSubscription: Bool = false) {
        self.id = UUID()
        self.name = name
        self.amount = amount
        self.categoryRaw = category.rawValue
        self.nextDueDate = nextDueDate
        self.frequencyRaw = frequency.rawValue
        self.isSubscription = isSubscription
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
    static func month(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month], from: date)
        return "\(c.year ?? 0)-\(c.month ?? 0)"
    }
}
