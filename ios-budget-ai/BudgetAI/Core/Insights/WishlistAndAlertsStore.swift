import Foundation
import Observation

// MARK: - Wishlist Models & Store

enum WishlistPriority: String, CaseIterable, Identifiable, Codable {
    case high = "High"
    case medium = "Medium"
    case low = "Low"

    var id: String { rawValue }

    var sortRank: Int {
        switch self {
        case .high: return 0
        case .medium: return 1
        case .low: return 2
        }
    }
}

enum WishlistSuitability: String, Codable, Hashable {
    case goodTimeToBuy = "Good time to buy"
    case considerWaiting = "Consider waiting"
    case saveFirst = "Save first"
    case notSuitableNow = "Not financially suitable right now"

    var status: SimulationStatus {
        switch self {
        case .goodTimeToBuy: return .safe
        case .considerWaiting, .saveFirst: return .caution
        case .notSuitableNow: return .risk
        }
    }
}

struct WishlistPricePoint: Codable, Hashable, Identifiable {
    var id: UUID = UUID()
    var price: Double
    var date: Date = Date()
}

struct WishlistItem: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String
    var productURL: String? = nil
    var currentPrice: Double
    var originalPrice: Double
    var targetPrice: Double? = nil
    var imageURL: String? = nil
    var priority: WishlistPriority = .medium
    var desiredDate: Date? = nil
    var categoryRaw: String = SpendCategory.shopping.rawValue
    var notes: String = ""
    var priceHistory: [WishlistPricePoint] = []
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    var priceReductionPercent: Double {
        guard originalPrice > 0.005, currentPrice < originalPrice else { return 0 }
        return ((originalPrice - currentPrice) / originalPrice) * 100.0
    }

    var hasReachedTargetPrice: Bool {
        guard let target = targetPrice, target > 0 else { return false }
        return currentPrice <= target + 0.005
    }
}

struct WishlistEvaluation: Hashable {
    let itemID: UUID
    let suitability: WishlistSuitability
    let reason: String
    let recommendation: String
    let recommendedMonthlySaving: Double?
    let simulation: BuyNowSimulationResult
}

@Observable
final class WishlistStore {
    static let shared = WishlistStore()

    private let defaults: UserDefaults
    private let storageKey: String
    private(set) var items: [WishlistItem] = []

    init(defaults: UserDefaults = .standard, storageKey: String = "falak.insights.wishlist.v1") {
        self.defaults = defaults
        self.storageKey = storageKey
        load()
    }

    func add(_ item: WishlistItem) {
        var copy = item
        if copy.priceHistory.isEmpty && copy.currentPrice > 0 {
            copy.priceHistory = [WishlistPricePoint(price: copy.currentPrice, date: copy.createdAt)]
        }
        items.insert(copy, at: 0)
        save()
    }

    func update(_ item: WishlistItem) {
        guard let idx = items.firstIndex(where: { $0.id == item.id }) else { return }
        var copy = item
        if copy.priceHistory.count < items[idx].priceHistory.count {
            copy.priceHistory = items[idx].priceHistory
        }
        copy.updatedAt = Date()
        if abs(items[idx].currentPrice - copy.currentPrice) >= 0.005 && copy.currentPrice > 0 {
            copy.priceHistory.append(WishlistPricePoint(price: copy.currentPrice, date: Date()))
        }
        items[idx] = copy
        save()
    }

    func delete(id: UUID) {
        items.removeAll { $0.id == id }
        save()
    }

    func clearAll() {
        items = []
        defaults.removeObject(forKey: storageKey)
    }

    private func load() {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([WishlistItem].self, from: data) else {
            items = []
            return
        }
        items = decoded
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) {
            defaults.set(data, forKey: storageKey)
        }
    }
}

enum WishlistEvaluator {
    static func evaluate(
        item: WishlistItem,
        finance f: Finance,
        projection: FinancialProjectionResult,
        currency: String = AppSettings.currency
    ) -> WishlistEvaluation {
        let cat = SpendCategory(rawValue: item.categoryRaw) ?? .shopping
        let sim = FinancialProjectionEngine.simulateBuyNow(
            input: BuyNowSimulationInput(amount: item.currentPrice, name: item.name, date: f.now, category: cat),
            finance: f,
            currency: currency,
            cachedProjection: projection
        )

        let suitability: WishlistSuitability
        let reason: String
        let recommendation: String
        var monthlySaving: Double? = nil

        if sim.overallStatus == .safe {
            if let target = item.targetPrice, !item.hasReachedTargetPrice {
                suitability = .considerWaiting
                reason = "You can afford it now, though the price (\(Money.format(item.currentPrice, currency))) is still above your target of \(Money.format(target, currency))."
                recommendation = "Wait for a price drop to \(Money.format(target, currency)), or simulate in Buy Now? if you want it sooner."
            } else {
                suitability = .goodTimeToBuy
                reason = item.hasReachedTargetPrice
                    ? "Target price reached and the purchase fits safely inside your Safe to Spend and bills."
                    : "Fits comfortably within your Safe to Spend, budget, and upcoming bills."
                recommendation = "Good window to buy — run Buy Now? to double-check exact budget impact."
            }
        } else if sim.overallStatus == .caution {
            suitability = .considerWaiting
            reason = sim.summaryReason
            if let nextIncome = projection.events.first(where: { $0.kind == .expectedIncome }) {
                recommendation = "Consider waiting until after your expected income around \(nextIncome.date.formatted(.dateTime.month(.abbreviated).day()))."
            } else {
                recommendation = "Consider waiting for a discount or until your next cycle."
            }
        } else {
            // Risk: distinguish Save First vs Not Suitable Now
            let monthlySurplus = max(0, projection.expectedMonthlyIncome - projection.expectedMonthlyExpenses)
            if monthlySurplus > 5 || f.safeToSpend.monthly > 0 {
                suitability = .saveFirst
                let monthsNeeded = max(2, Int(ceil(item.currentPrice / max(monthlySurplus * 0.5, max(1, f.safeToSpend.monthly * 0.5)))))
                let cappedMonths = min(24, monthsNeeded)
                let perMonth = item.currentPrice / Double(cappedMonths)
                monthlySaving = perMonth
                reason = "Buying outright right now would strain your budget or Safe to Spend."
                recommendation = "Save about \(Money.format(perMonth, currency))/mo for \(cappedMonths) months to buy comfortably."
            } else {
                suitability = .notSuitableNow
                reason = sim.summaryReason
                recommendation = "Hold off for now — focus on covering upcoming bills and building your Safe to Spend buffer."
            }
        }

        return WishlistEvaluation(
            itemID: item.id,
            suitability: suitability,
            reason: reason,
            recommendation: recommendation,
            recommendedMonthlySaving: monthlySaving,
            simulation: sim
        )
    }
}

// MARK: - Insights & Alerts Engine & State Store

enum FinancialAlertPriority: String, Codable, CaseIterable, Comparable {
    case critical = "Critical"
    case high = "High"
    case medium = "Medium"
    case low = "Low"

    var rank: Int {
        switch self {
        case .critical: return 0
        case .high: return 1
        case .medium: return 2
        case .low: return 3
        }
    }

    static func < (lhs: FinancialAlertPriority, rhs: FinancialAlertPriority) -> Bool {
        lhs.rank < rhs.rank
    }
}

enum FinancialAlertCategory: String, Codable {
    case billDue = "Bills & Installments"
    case balanceShortage = "Balance Risk"
    case budgetWarning = "Budget"
    case goalProgress = "Savings Goal"
    case goalDelay = "Goal Delay"
    case unusualSpending = "Unusual Spending"
    case subscriptionPriceChange = "Subscription Change"
    case recurringChange = "Recurring Expense"
    case wishlistOpportunity = "Wishlist"
    case milestone = "Milestone"
    case timeMachineObservation = "Time Machine"

    var symbol: String {
        switch self {
        case .billDue: return "calendar.badge.clock"
        case .balanceShortage: return "exclamationmark.triangle.fill"
        case .budgetWarning: return "chart.bar.fill"
        case .goalProgress, .milestone: return "star.fill"
        case .goalDelay: return "clock.badge.exclamationmark"
        case .unusualSpending: return "flame.fill"
        case .subscriptionPriceChange: return "arrow.up.right.circle.fill"
        case .recurringChange: return "repeat.circle.fill"
        case .wishlistOpportunity: return "heart.circle.fill"
        case .timeMachineObservation: return "clock.arrow.2.circlepath"
        }
    }
}

enum FinancialAlertAction: Codable, Hashable {
    case openTimeMachine
    case openBuyNow(amount: Double, name: String)
    case openWishlist
    case openBills
    case openBudgets
    case openTransactions
    case openAccounts

    var buttonTitle: String {
        switch self {
        case .openTimeMachine: return "Open Time Machine"
        case .openBuyNow: return "Simulate in Buy Now?"
        case .openWishlist: return "Open Wishlist"
        case .openBills: return "View Bills"
        case .openBudgets: return "Adjust Budget"
        case .openTransactions: return "Review Transactions"
        case .openAccounts: return "Review Accounts"
        }
    }
}

struct FinancialAlert: Codable, Identifiable, Hashable {
    let id: String
    let title: String
    let explanation: String
    let amount: Double?
    let timeframe: String
    let category: FinancialAlertCategory
    let priority: FinancialAlertPriority
    let recommendedAction: String
    let action: FinancialAlertAction
    let createdAt: Date
}

@Observable
final class FinancialAlertStateStore {
    static let shared = FinancialAlertStateStore()

    private let defaults: UserDefaults
    private let readKey: String
    private let dismissedKey: String
    private let historyKey: String

    private(set) var readIDs: Set<String> = []
    private(set) var dismissedIDs: Set<String> = []
    private(set) var archivedAlerts: [FinancialAlert] = []

    init(
        defaults: UserDefaults = .standard,
        readKey: String = "falak.insights.alerts.read.v1",
        dismissedKey: String = "falak.insights.alerts.dismissed.v1",
        historyKey: String = "falak.insights.alerts.history.v1"
    ) {
        self.defaults = defaults
        self.readKey = readKey
        self.dismissedKey = dismissedKey
        self.historyKey = historyKey
        load()
    }

    func markRead(_ alert: FinancialAlert) {
        readIDs.insert(alert.id)
        archiveIfNeeded(alert)
        save()
    }

    func dismiss(_ alert: FinancialAlert) {
        dismissedIDs.insert(alert.id)
        readIDs.insert(alert.id)
        archiveIfNeeded(alert)
        save()
    }

    func restore(_ alertID: String) {
        dismissedIDs.remove(alertID)
        save()
    }

    func isRead(_ id: String) -> Bool { readIDs.contains(id) }
    func isDismissed(_ id: String) -> Bool { dismissedIDs.contains(id) }

    func clearAll() {
        readIDs = []
        dismissedIDs = []
        archivedAlerts = []
        defaults.removeObject(forKey: readKey)
        defaults.removeObject(forKey: dismissedKey)
        defaults.removeObject(forKey: historyKey)
    }

    private func archiveIfNeeded(_ alert: FinancialAlert) {
        if let idx = archivedAlerts.firstIndex(where: { $0.id == alert.id }) {
            archivedAlerts[idx] = alert
        } else {
            archivedAlerts.insert(alert, at: 0)
            if archivedAlerts.count > 100 {
                archivedAlerts = Array(archivedAlerts.prefix(100))
            }
        }
    }

    private func load() {
        readIDs = Set(defaults.stringArray(forKey: readKey) ?? [])
        dismissedIDs = Set(defaults.stringArray(forKey: dismissedKey) ?? [])
        if let data = defaults.data(forKey: historyKey),
           let decoded = try? JSONDecoder().decode([FinancialAlert].self, from: data) {
            archivedAlerts = decoded
        }
    }

    private func save() {
        defaults.set(Array(readIDs), forKey: readKey)
        defaults.set(Array(dismissedIDs), forKey: dismissedKey)
        if let data = try? JSONEncoder().encode(archivedAlerts) {
            defaults.set(data, forKey: historyKey)
        }
    }
}

enum FinancialAlertsEngine {
    static func generate(
        finance f: Finance,
        projection: FinancialProjectionResult,
        wishlistItems: [WishlistItem],
        currency: String = AppSettings.currency
    ) -> [FinancialAlert] {
        var alerts: [FinancialAlert] = []
        let cal = Calendar.current
        let now = f.now
        let today = cal.startOfDay(for: now)
        let soon = cal.date(byAdding: .day, value: 7, to: today) ?? today

        // 1. Projected Balance Shortfall (Critical)
        if let sDate = projection.shortfallDate {
            let dateStr = sDate.formatted(.dateTime.month(.abbreviated).day())
            alerts.append(FinancialAlert(
                id: "shortfall-\(DateKeys.month(sDate))",
                title: "Projected Balance Shortfall",
                explanation: "Your balance may drop to \(Money.format(projection.lowestBalance, currency)) around \(dateStr) due to upcoming commitments.",
                amount: projection.shortfallAmount,
                timeframe: "Around \(dateStr)",
                category: .balanceShortage,
                priority: .critical,
                recommendedAction: "Review your Time Machine forecast and reserve funds before \(dateStr).",
                action: .openTimeMachine,
                createdAt: now
            ))
        }

        // 2. Upcoming Bills & Subscriptions within 7 days + Subscription Price Changes
        for bill in f.bills {
            if let delta = bill.lastPaidPriceDelta, delta > 0.05 {
                alerts.append(FinancialAlert(
                    id: "bill-price-\(bill.id.uuidString)-\(DateKeys.month(now))",
                    title: "\(bill.name) Price Increased",
                    explanation: "Last payment was \(Money.format(delta, currency)) higher than your expected \(Money.format(bill.amount, currency)).",
                    amount: delta,
                    timeframe: "This cycle",
                    category: .subscriptionPriceChange,
                    priority: .high,
                    recommendedAction: "Review this subscription or update its expected bill amount.",
                    action: .openBills,
                    createdAt: now
                ))
            }
            if !bill.isPaidForCurrentCycle(now: now) && bill.nextDueDate <= soon {
                let days = cal.dateComponents([.day], from: today, to: cal.startOfDay(for: bill.nextDueDate)).day ?? 0
                let when = days < 0 ? "Overdue by \(-days)d" : (days == 0 ? "Due today" : "Due in \(days)d")
                alerts.append(FinancialAlert(
                    id: "bill-due-\(bill.id.uuidString)-\(DateKeys.month(bill.nextDueDate))",
                    title: "\(bill.name) \(days < 0 ? "Overdue" : "Due Soon")",
                    explanation: "\(Money.format(bill.amount, currency)) scheduled for \(bill.nextDueDate.formatted(.dateTime.month(.abbreviated).day())).",
                    amount: bill.amount,
                    timeframe: when,
                    category: .billDue,
                    priority: days <= 1 ? .high : .medium,
                    recommendedAction: "Ensure funds are ready or mark the bill paid once settled.",
                    action: .openBills,
                    createdAt: now
                ))
            }
        }

        // 3. Loan & Credit Card Due Dates within 7 days
        for acc in f.accounts where acc.kind.isLiability && acc.balance > 0 && acc.paymentDueReminder {
            let days = acc.daysUntilDue(from: now)
            if days <= 7 {
                let dueAmt = acc.kind == .loan && acc.loanMonthlyInstallment > 0 ? min(acc.balance, acc.loanMonthlyInstallment) : acc.balance
                alerts.append(FinancialAlert(
                    id: "liability-due-\(acc.id.uuidString)-\(DateKeys.month(now))",
                    title: "\(acc.name) Payment Due",
                    explanation: "\(Money.format(dueAmt, currency)) due in \(max(0, days)) day\(days == 1 ? "" : "s").",
                    amount: dueAmt,
                    timeframe: days <= 0 ? "Today" : "In \(days)d",
                    category: .billDue,
                    priority: days <= 2 ? .high : .medium,
                    recommendedAction: "Check your account balance so this installment clears smoothly.",
                    action: .openAccounts,
                    createdAt: now
                ))
            }
        }

        // 4. Budget Warnings (>= 85% or Exceeded)
        let spentByCat = f.spendingTotalsByCategory(in: f.thisMonth)
        for budget in f.budgets where budget.limit > 0 {
            let spent = Set(budget.categories.map(\.rawValue)).reduce(0.0) { $0 + (spentByCat[$1] ?? 0) }
            let pct = Int((spent / budget.limit) * 100)
            if pct >= 100 {
                alerts.append(FinancialAlert(
                    id: "budget-over-\(budget.id.uuidString)-\(DateKeys.month(now))",
                    title: "\(budget.displayName) Budget Exceeded",
                    explanation: "Spent \(Money.format(spent, currency)) of \(Money.format(budget.limit, currency)) (\(pct)%).",
                    amount: spent - budget.limit,
                    timeframe: "This cycle",
                    category: .budgetWarning,
                    priority: .high,
                    recommendedAction: "Pause non-essential spending in \(budget.displayName) or adjust the limit.",
                    action: .openBudgets,
                    createdAt: now
                ))
            } else if pct >= 85 {
                alerts.append(FinancialAlert(
                    id: "budget-near-\(budget.id.uuidString)-\(DateKeys.month(now))",
                    title: "\(budget.displayName) at \(pct)%",
                    explanation: "Only \(Money.format(max(0, budget.limit - spent), currency)) left for the next \(f.daysLeftInMonth) day\(f.daysLeftInMonth == 1 ? "" : "s").",
                    amount: max(0, budget.limit - spent),
                    timeframe: "\(f.daysLeftInMonth)d left",
                    category: .budgetWarning,
                    priority: .medium,
                    recommendedAction: "Keep an eye on \(budget.displayName) purchases this week.",
                    action: .openBudgets,
                    createdAt: now
                ))
            }
        }

        // 5. Unusual Spending Patterns (category pacing > 30% higher than last month)
        let thisMonthCats = f.categoryBreakdown(in: f.thisMonth)
        let lastMonthMap = Dictionary(uniqueKeysWithValues: f.categoryBreakdown(in: f.lastMonth).map { ($0.category, $0.amount) })
        let cycleProgress = max(0.25, Double(f.daysElapsed) / Double(f.daysElapsed + f.daysLeftInMonth - 1))
        if let spike = thisMonthCats.first(where: { item in
            guard let prev = lastMonthMap[item.category], prev >= 10 else { return false }
            return (item.amount / cycleProgress) > prev * 1.30 && item.amount > prev * 0.65
        }), let prev = lastMonthMap[spike.category] {
            let projectedCat = spike.amount / cycleProgress
            let pctUp = Int(((projectedCat / prev) - 1) * 100)
            alerts.append(FinancialAlert(
                id: "spike-\(spike.category.rawValue)-\(DateKeys.month(now))",
                title: "Higher \(spike.category.title) Spending",
                explanation: "On pace for +\(pctUp)% vs last month (\(Money.format(spike.amount, currency)) so far vs \(Money.format(prev, currency)) last month).",
                amount: spike.amount,
                timeframe: "This cycle",
                category: .unusualSpending,
                priority: .medium,
                recommendedAction: "Review recent \(spike.category.title) transactions to spot any one-off or shared charges.",
                action: .openTransactions,
                createdAt: now
            ))
        }

        // 6. Savings Goal Progress & Delays
        for goal in f.goals where goal.target > 0 {
            if goal.isComplete {
                alerts.append(FinancialAlert(
                    id: "goal-done-\(goal.id.uuidString)",
                    title: "\(goal.name) Reached!",
                    explanation: "You reached your \(Money.format(goal.target, currency)) target.",
                    amount: goal.target,
                    timeframe: "Milestone",
                    category: .milestone,
                    priority: .low,
                    recommendedAction: "Celebrate your milestone or set your next savings goal in Time Machine.",
                    action: .openBudgets,
                    createdAt: now
                ))
            } else if goal.progress >= 0.75 {
                alerts.append(FinancialAlert(
                    id: "goal-close-\(goal.id.uuidString)",
                    title: "\(goal.name) is \(Int(goal.progress * 100))% Funded",
                    explanation: "Only \(Money.format(goal.target - goal.saved, currency)) left to complete this goal.",
                    amount: goal.target - goal.saved,
                    timeframe: "Target \(goal.targetDate.formatted(.dateTime.month(.abbreviated).year()))",
                    category: .goalProgress,
                    priority: .low,
                    recommendedAction: "Stay consistent with your monthly savings contribution.",
                    action: .openBudgets,
                    createdAt: now
                ))
            } else {
                let daysLeft = max(1, cal.dateComponents([.day], from: today, to: cal.startOfDay(for: goal.targetDate)).day ?? 1)
                let monthsLeft = max(0.5, Double(daysLeft) / FinancialProjectionEngine.daysPerMonth)
                let neededMonthly = (goal.target - goal.saved) / monthsLeft
                if goal.monthlyCommitment > 0 && neededMonthly > goal.monthlyCommitment * 1.25 {
                    alerts.append(FinancialAlert(
                        id: "goal-delay-\(goal.id.uuidString)-\(DateKeys.month(now))",
                        title: "\(goal.name) May Be Delayed",
                        explanation: "Needs \(Money.format(neededMonthly, currency))/mo to finish on time, vs your current \(Money.format(goal.monthlyCommitment, currency))/mo plan.",
                        amount: neededMonthly - goal.monthlyCommitment,
                        timeframe: "Target \(goal.targetDate.formatted(.dateTime.month(.abbreviated).year()))",
                        category: .goalDelay,
                        priority: .medium,
                        recommendedAction: "Adjust the goal timeline or monthly contribution in Saving Goal simulation.",
                        action: .openTimeMachine,
                        createdAt: now
                    ))
                }
            }
        }

        // 7. Detected Recurring Expense Not Tracked as a Bill
        if let rec = f.recurringCandidates().first {
            alerts.append(FinancialAlert(
                id: "recurring-\(rec.key)",
                title: "Recurring Payment Detected: \(rec.name)",
                explanation: "\(rec.occurrences) similar payments around \(Money.format(rec.amount, currency)).",
                amount: rec.amount,
                timeframe: "Monthly pattern",
                category: .recurringChange,
                priority: .low,
                recommendedAction: "Track it under Bills so Time Machine reserves it automatically.",
                action: .openBills,
                createdAt: now
            ))
        }

        // 8. Wishlist Opportunities (Target Price Reached or Good Time to Buy)
        for item in wishlistItems {
            let eval = WishlistEvaluator.evaluate(item: item, finance: f, projection: projection, currency: currency)
            if item.hasReachedTargetPrice || eval.suitability == .goodTimeToBuy {
                alerts.append(FinancialAlert(
                    id: "wishlist-opp-\(item.id.uuidString)-\(Int(item.currentPrice))",
                    title: item.hasReachedTargetPrice ? "\(item.name) Hit Target Price" : "Good Time to Buy \(item.name)",
                    explanation: eval.reason,
                    amount: item.currentPrice,
                    timeframe: "Wishlist",
                    category: .wishlistOpportunity,
                    priority: item.hasReachedTargetPrice ? .medium : .low,
                    recommendedAction: "Run Buy Now? to verify exact budget impact before purchasing.",
                    action: .openBuyNow(amount: item.currentPrice, name: item.name),
                    createdAt: now
                ))
            }
        }

        // Deduplicate by stable ID and sort by priority (Critical -> Low), then amount descending
        var seen: Set<String> = []
        let unique = alerts.filter { seen.insert($0.id).inserted }
        return unique.sorted { lhs, rhs in
            if lhs.priority != rhs.priority { return lhs.priority < rhs.priority }
            return (lhs.amount ?? 0) > (rhs.amount ?? 0)
        }
    }
}
