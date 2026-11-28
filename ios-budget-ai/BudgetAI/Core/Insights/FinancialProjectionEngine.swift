import Foundation

// MARK: - Forecast Period

enum ForecastPeriod: String, CaseIterable, Identifiable, Codable {
    case oneMonth = "1M"
    case threeMonths = "3M"
    case sixMonths = "6M"
    case oneYear = "1Y"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .oneMonth: return "1 Month"
        case .threeMonths: return "3 Months"
        case .sixMonths: return "6 Months"
        case .oneYear: return "1 Year"
        }
    }

    var shortTitle: String { rawValue }

    var days: Int {
        switch self {
        case .oneMonth: return 30
        case .threeMonths: return 90
        case .sixMonths: return 180
        case .oneYear: return 365
        }
    }

    var months: Double {
        switch self {
        case .oneMonth: return 1
        case .threeMonths: return 3
        case .sixMonths: return 6
        case .oneYear: return 12
        }
    }
}

// MARK: - Projection Events & Timeline

enum ProjectionEventKind: String, Codable, CaseIterable, Identifiable {
    case upcomingBill = "bill"
    case loanInstallment = "loan"
    case expectedIncome = "income"
    case recurringExpense = "recurring"
    case plannedSavings = "savings"
    case goalDeadline = "goal_deadline"
    case scheduledExpense = "scheduled"
    case seasonalRamadan = "ramadan"
    case seasonalEid = "eid"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .upcomingBill: return "Upcoming Bill"
        case .loanInstallment: return "Loan / Installment"
        case .expectedIncome: return "Expected Income"
        case .recurringExpense: return "Recurring Expense"
        case .plannedSavings: return "Planned Savings"
        case .goalDeadline: return "Goal Deadline"
        case .scheduledExpense: return "Scheduled Expense"
        case .seasonalRamadan: return "Ramadan Season"
        case .seasonalEid: return "Eid Season"
        }
    }

    var symbol: String {
        switch self {
        case .upcomingBill: return "bolt.fill"
        case .loanInstallment: return "building.columns.fill"
        case .expectedIncome: return "arrow.down.circle.fill"
        case .recurringExpense: return "repeat.circle.fill"
        case .plannedSavings: return "star.circle.fill"
        case .goalDeadline: return "flag.checkered"
        case .scheduledExpense: return "calendar.badge.exclamationmark"
        case .seasonalRamadan: return "moon.stars.fill"
        case .seasonalEid: return "sparkles"
        }
    }
}

struct FinancialProjectionEvent: Identifiable, Hashable {
    let id: String
    let title: String
    let date: Date
    let amount: Double
    /// Positive for expected inflow, negative for outflow, 0 for informational milestones/deadlines.
    let signedImpact: Double
    let kind: ProjectionEventKind
    let accountOrCategory: String?
    let explanation: String
    let isConfirmed: Bool
}

struct FinancialEventGroup: Identifiable, Hashable {
    let id: String
    let bucketDate: Date
    let isWeeklyBucket: Bool
    let categoryKey: String
    let title: String
    let symbol: String
    let primaryKind: ProjectionEventKind
    let totalAmount: Double
    let totalSignedImpact: Double
    let events: [FinancialProjectionEvent]

    var dateLabel: String {
        if isWeeklyBucket {
            return "Week of \(bucketDate.formatted(.dateTime.month(.abbreviated).day()))"
        }
        return bucketDate.formatted(.dateTime.month(.abbreviated).day())
    }
}

struct ProjectionTimelinePoint: Identifiable, Hashable {
    var id: Date { date }
    let date: Date
    let balance: Double
    let isActual: Bool
}

enum ProjectionUncertainty: String, Codable {
    case low, medium, high

    var title: String {
        switch self {
        case .low: return "High Confidence"
        case .medium: return "Moderate Confidence"
        case .high: return "Limited Data"
        }
    }
}

struct PrimaryForecastInsight: Hashable {
    let title: String
    let what: String
    let why: String
    let when: String
    let action: String
    let severity: SimulationStatus
    let isAIEnhanced: Bool
}

struct FinancialProjectionResult {
    let period: ForecastPeriod
    let now: Date
    let startingBalance: Double
    let projectedEndBalance: Double
    let lowestBalance: Double
    let lowestBalanceDate: Date
    let expectedMonthlyIncome: Double
    let expectedMonthlyExpenses: Double
    let expectedMonthlyCommitments: Double
    let expectedMonthlySavings: Double
    let projectedSafeToSpendMonthly: Double
    let actualPoints: [ProjectionTimelinePoint]
    let projectedPoints: [ProjectionTimelinePoint]
    let events: [FinancialProjectionEvent]
    let hasSufficientData: Bool
    let assumptions: [String]
    let missingData: [String]
    let uncertainty: ProjectionUncertainty
    let shortfallDate: Date?
    let shortfallAmount: Double
    let primaryInsight: PrimaryForecastInsight

    var netChange: Double { projectedEndBalance - startingBalance }
}

// MARK: - Simulation Status & Buy Now? Result

enum SimulationStatus: String, Codable, Hashable {
    case safe
    case caution
    case risk

    var title: String {
        switch self {
        case .safe: return "Financially Safe"
        case .caution: return "Proceed with Caution"
        case .risk: return "Financial Risk"
        }
    }
}

struct BuyNowSimulationInput: Hashable {
    let amount: Double
    let name: String
    let date: Date
    let category: SpendCategory?

    init(amount: Double, name: String = "", date: Date = .now, category: SpendCategory? = nil) {
        self.amount = max(0, amount)
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.date = date
        self.category = category
    }
}

struct BuyNowSafeToSpendImpact: Hashable {
    let before: Double
    let after: Double
    let status: SimulationStatus
    let explanation: String
}

struct BuyNowGoalsImpact: Hashable {
    let currentProgress: Double
    let projectedProgress: Double
    let totalSaved: Double
    let totalTarget: Double
    let delayedGoalName: String?
    let estimatedDelayDays: Int?
    let status: SimulationStatus
    let explanation: String
}

struct BuyNowBudgetImpact: Hashable {
    let beforeRemaining: Double
    let afterRemaining: Double
    let categoryTitle: String
    let hasBudgetConfigured: Bool
    let status: SimulationStatus
    let explanation: String
}

struct BuyNowBillsImpact: Hashable {
    let upcomingBillsTotal: Double
    let loanInstallmentsTotal: Double
    let billsCovered: Bool
    let loansCovered: Bool
    let createsCashShortfall: Bool
    let shortfallDate: Date?
    let projectedLowestAfterPurchase: Double
    let status: SimulationStatus
    let explanation: String
}

struct BuyNowSimulationResult: Hashable {
    let input: BuyNowSimulationInput
    let overallStatus: SimulationStatus
    let summaryReason: String
    let safeToSpend: BuyNowSafeToSpendImpact
    let savingGoals: BuyNowGoalsImpact
    let budget: BuyNowBudgetImpact
    let bills: BuyNowBillsImpact
    let recommendations: [String]
}

// MARK: - Saving Goal Simulation Result

enum SavingGoalPeriodPreset: String, CaseIterable, Identifiable {
    case threeMonths = "3 Months"
    case sixMonths = "6 Months"
    case twelveMonths = "12 Months"
    case twentyFourMonths = "24 Months"
    case customDate = "Custom Date"

    var id: String { rawValue }

    var months: Int? {
        switch self {
        case .threeMonths: return 3
        case .sixMonths: return 6
        case .twelveMonths: return 12
        case .twentyFourMonths: return 24
        case .customDate: return nil
        }
    }
}

struct SavingGoalSimulationInput: Hashable {
    let name: String
    let targetAmount: Double
    let currentSaved: Double
    let targetDate: Date
    let startDate: Date

    init(name: String, targetAmount: Double, currentSaved: Double = 0, targetDate: Date, startDate: Date = .now) {
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.targetAmount = max(0, targetAmount)
        self.currentSaved = max(0, currentSaved)
        self.targetDate = targetDate
        self.startDate = startDate
    }
}

struct SavingGoalSimulationResult: Hashable {
    let input: SavingGoalSimulationInput
    let remainingAmount: Double
    let remainingDays: Int
    let remainingMonths: Double
    let requiredMonthlyContribution: Double
    let requiredWeeklyContribution: Double
    let currentProgress: Double
    let projectedProgressAtTargetDate: Double
    let expectedCompletionDate: Date
    let isAchievable: Bool
    let isSustainable: Bool
    let overallStatus: SimulationStatus
    let summaryReason: String

    // 4-pillar analysis
    let safeToSpendBeforeMonthly: Double
    let safeToSpendAfterMonthly: Double
    let safeToSpendStatus: SimulationStatus
    let safeToSpendExplanation: String

    let goalsOnTrack: Bool
    let goalsStatus: SimulationStatus
    let goalsExplanation: String

    let budgetRemainingBefore: Double
    let budgetRemainingAfter: Double
    let adjustableCategories: [String]
    let budgetStatus: SimulationStatus
    let budgetExplanation: String

    let billsCovered: Bool
    let loansCovered: Bool
    let createsCashShortfall: Bool
    let billsStatus: SimulationStatus
    let billsExplanation: String

    let smartSuggestions: [String]
    let suggestedAffordableMonthly: Double
    let suggestedExtendedMonths: Int?
}

// MARK: - Deterministic Financial Projection Engine

/// Pure, read-only deterministic projection engine for Time Machine, Buy Now?, Saving Goal,
/// Wishlist Intelligence, and Insights & Alerts.
/// - Never writes to SwiftData or modifies real transactions, accounts, budgets, or goals.
/// - Never invents sample figures when real data is missing.
enum FinancialProjectionEngine {
    static let daysPerMonth: Double = 30.4375

    // MARK: 0. Single-Account Scoping & Category/Time Event Grouping

    /// Builds a `Finance` snapshot scoped strictly to a single chosen account and its transactions,
    /// plus any loans/bills/goals tied to that account.
    static func scopedFinance(
        for account: Account,
        transactions: [MoneyTransaction],
        accounts: [Account],
        budgets: [Budget],
        goals: [SavingsGoal],
        bills: [Bill],
        now: Date = .now,
        sharedExpenseOverlay: SharedExpenseOverlay? = nil
    ) -> Finance {
        let primaryLiquidID = accounts.first(where: { $0.kind == .bank })?.id
            ?? accounts.first(where: { $0.kind.isLiquid })?.id
        let isPrimary = (account.id == primaryLiquidID)

        let scopedTxs = transactions.filter { $0.accountID == account.id || $0.toAccountID == account.id }
        let linkedLoans = accounts.filter { $0.kind == .loan && $0.loanAutoDeductAccountID == account.id }
        let scopedAccounts: [Account] = [account] + linkedLoans.filter { $0.id != account.id }
        let txByID = Dictionary(uniqueKeysWithValues: transactions.map { ($0.id, $0) })
        let scopedBills = bills.filter { bill in
            if let lastTxID = bill.lastPaidTxID, let paidAcc = txByID[lastTxID]?.accountID {
                return paidAcc == account.id
            }
            if let linkedTx = transactions.first(where: { $0.billID == bill.id && $0.accountID != nil }) {
                return linkedTx.accountID == account.id
            }
            return isPrimary
        }
        let scopedGoals = goals.filter { goal in
            if let linked = goal.linkedAccountID {
                return linked == account.id
            }
            return isPrimary
        }

        return Finance(
            transactions: scopedTxs,
            accounts: scopedAccounts,
            budgets: budgets,
            goals: scopedGoals,
            bills: scopedBills,
            now: now,
            sharedExpenseOverlay: sharedExpenseOverlay
        )
    }

    /// Groups upcoming financial events by similar category and time bucket:
    /// - For `.oneMonth`: daily buckets (`startOfDay`).
    /// - For `> 1 month` (`.threeMonths`, `.sixMonths`, `.oneYear`): weekly buckets (`weekOfYear` start).
    static func groupEvents(
        _ events: [FinancialProjectionEvent],
        period: ForecastPeriod,
        calendar cal: Calendar = .current
    ) -> [FinancialEventGroup] {
        let isWeekly = (period != .oneMonth)

        struct GroupMeta {
            let key: String
            let title: String
            let symbol: String
            let kind: ProjectionEventKind
        }

        func meta(for ev: FinancialProjectionEvent) -> GroupMeta {
            switch ev.kind {
            case .expectedIncome:
                return GroupMeta(key: "income", title: "Expected Income", symbol: "arrow.down.circle.fill", kind: .expectedIncome)
            case .loanInstallment:
                return GroupMeta(key: "loans", title: "Loan Installments", symbol: "building.columns.fill", kind: .loanInstallment)
            case .plannedSavings, .goalDeadline:
                return GroupMeta(key: "savings", title: "Savings & Goals", symbol: "target", kind: .plannedSavings)
            case .seasonalRamadan, .seasonalEid:
                return GroupMeta(key: "seasonal", title: "Seasonal & Holidays", symbol: "moon.stars.fill", kind: .seasonalRamadan)
            case .upcomingBill, .recurringExpense, .scheduledExpense:
                if let catName = ev.accountOrCategory?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !catName.isEmpty,
                   let spendCat = SpendCategory.allCases.first(where: { $0.title.caseInsensitiveCompare(catName) == .orderedSame || $0.rawValue.caseInsensitiveCompare(catName) == .orderedSame }) {
                    return GroupMeta(key: "cat-\(spendCat.rawValue.lowercased())", title: spendCat.title, symbol: spendCat.symbol, kind: ev.kind)
                }
                return GroupMeta(key: "bills", title: "Bills & Recurring", symbol: "doc.text.fill", kind: ev.kind)
            }
        }

        var buckets: [String: (date: Date, meta: GroupMeta, events: [FinancialProjectionEvent])] = [:]
        for ev in events {
            let bucketDate: Date = isWeekly
                ? (cal.dateInterval(of: .weekOfYear, for: ev.date)?.start ?? cal.startOfDay(for: ev.date))
                : cal.startOfDay(for: ev.date)
            let m = meta(for: ev)
            let dayStamp = Int(bucketDate.timeIntervalSince1970 / 86_400)
            let bucketID = "\(dayStamp)-\(m.key)"
            if var existing = buckets[bucketID] {
                existing.events.append(ev)
                buckets[bucketID] = existing
            } else {
                buckets[bucketID] = (bucketDate, m, [ev])
            }
        }

        return buckets.map { id, entry in
            let sortedEvents = entry.events.sorted { $0.date < $1.date }
            let totalImpact = sortedEvents.reduce(0.0) { $0 + $1.signedImpact }
            let totalAmt = sortedEvents.reduce(0.0) { $0 + $1.amount }
            return FinancialEventGroup(
                id: id,
                bucketDate: entry.date,
                isWeeklyBucket: isWeekly,
                categoryKey: entry.meta.key,
                title: entry.meta.title,
                symbol: entry.meta.symbol,
                primaryKind: entry.meta.kind,
                totalAmount: totalAmt,
                totalSignedImpact: totalImpact,
                events: sortedEvents
            )
        }
        .sorted { lhs, rhs in
            if lhs.bucketDate != rhs.bucketDate { return lhs.bucketDate < rhs.bucketDate }
            return abs(lhs.totalSignedImpact) > abs(rhs.totalSignedImpact)
        }
    }

    // MARK: 1. Main Forecast Projection

    static func project(
        finance f: Finance,
        period: ForecastPeriod,
        currency: String = AppSettings.currency
    ) -> FinancialProjectionResult {
        let cal = Calendar.current
        let now = f.now
        let today = cal.startOfDay(for: now)
        let horizonEnd = cal.date(byAdding: .day, value: period.days, to: today) ?? today.addingTimeInterval(Double(period.days) * 86_400)

        let startingBalance = f.liquidBalance > 0 || f.accounts.contains(where: { $0.kind.isLiquid })
            ? f.liquidBalance
            : f.totalAssets

        // Lookback window (up to 90 days) for historical income & discretionary spending averages
        let lookbackStart = cal.date(byAdding: .day, value: -90, to: today) ?? today
        let recentApproved = f.approvedTransactions.filter { $0.date >= lookbackStart && $0.date <= now }
        let historySpanDays: Double = {
            guard let earliest = recentApproved.map(\.date).min() else { return 0 }
            let span = cal.dateComponents([.day], from: cal.startOfDay(for: earliest), to: today).day ?? 0
            return Double(max(1, min(90, span + 1)))
        }()
        let monthsObserved = max(1.0, historySpanDays / daysPerMonth)

        let observedIncome = f.ordinaryIncomeTransactions
            .filter { $0.date >= lookbackStart && $0.date <= now }
            .reduce(0.0) { $0 + f.sharedExpenseOverlay.effectiveIncomeAmount(for: $1) }
        let expectedMonthlyIncome = historySpanDays > 0 ? (observedIncome / monthsObserved) : 0

        // Separate bill/recurring spending from variable discretionary spending to avoid double-counting
        let nonBillSpending = f.spendingTransactions
            .filter { $0.date >= lookbackStart && $0.date <= now && $0.source != .bill && $0.billID == nil }
            .reduce(0.0) { $0 + f.sharedExpenseOverlay.effectiveSpendingAmount(for: $1) }
        let expectedMonthlyDiscretionary = historySpanDays > 0 ? (nonBillSpending / monthsObserved) : 0
        let dailyDiscretionary = expectedMonthlyDiscretionary / daysPerMonth

        let monthlyBills = f.billsMonthly
        let monthlyLoans = f.accounts
            .filter { $0.kind == .loan && $0.balance > 0 && $0.loanMonthlyInstallment > 0 }
            .reduce(0.0) { $0 + min($1.balance, $1.loanMonthlyInstallment) }
        let monthlyGoals = f.goals
            .filter { !$0.isComplete && $0.monthlyCommitment > 0 }
            .reduce(0.0) { $0 + $1.monthlyCommitment }

        let expectedMonthlyCommitments = monthlyBills + monthlyLoans
        let expectedMonthlyExpenses = expectedMonthlyDiscretionary + expectedMonthlyCommitments

        // Build deterministic future events (no fabricated amounts!)
        var events: [FinancialProjectionEvent] = []
        var cashflowByDay: [Date: Double] = [:]

        func addEvent(_ event: FinancialProjectionEvent, affectsBalance: Bool) {
            events.append(event)
            if affectsBalance && abs(event.signedImpact) > 0.0005 {
                let d = cal.startOfDay(for: event.date)
                cashflowByDay[d, default: 0] += event.signedImpact
            }
        }

        // A. Upcoming Bills & Subscriptions
        for bill in f.bills where bill.amount > 0 {
            var due = cal.startOfDay(for: bill.nextDueDate)
            if due < today {
                if bill.isPaidForCurrentCycle(now: now) {
                    due = cal.startOfDay(for: bill.frequency.next(after: due, calendar: cal))
                } else {
                    due = today
                }
            }
            var occurrence = 0
            while due <= horizonEnd && occurrence < 60 {
                let id = "bill-\(bill.id.uuidString)-\(occurrence)"
                addEvent(FinancialProjectionEvent(
                    id: id,
                    title: bill.name,
                    date: due,
                    amount: bill.amount,
                    signedImpact: -bill.amount,
                    kind: .upcomingBill,
                    accountOrCategory: bill.category.title,
                    explanation: bill.isSubscription
                        ? "Scheduled \(bill.frequency.title.lowercased()) subscription renewal."
                        : "Scheduled \(bill.frequency.title.lowercased()) bill payment.",
                    isConfirmed: true
                ), affectsBalance: true)
                let next = cal.startOfDay(for: bill.frequency.next(after: due, calendar: cal))
                if next <= due { break }
                due = next
                occurrence += 1
            }
        }

        // B. Loan Installments & Credit Card Due Dates
        for acc in f.accounts where acc.kind == .loan && acc.balance > 0 && acc.loanMonthlyInstallment > 0 {
            let dueDates = acc.upcomingDueDates(count: Int(ceil(period.months)) + 1, from: now, calendar: cal)
            var remainingLoan = acc.balance
            for (idx, d) in dueDates.enumerated() where d <= horizonEnd && remainingLoan > 0.005 {
                if idx == 0 && acc.isLoanInstallmentPaidForCurrentCycle(now: now) { continue }
                let installment = min(remainingLoan, acc.loanMonthlyInstallment)
                remainingLoan -= installment
                addEvent(FinancialProjectionEvent(
                    id: "loan-\(acc.id.uuidString)-\(idx)",
                    title: "\(acc.name) Installment",
                    date: d,
                    amount: installment,
                    signedImpact: -installment,
                    kind: .loanInstallment,
                    accountOrCategory: acc.name,
                    explanation: "Monthly loan installment for \(acc.name).",
                    isConfirmed: true
                ), affectsBalance: true)
            }
        }

        for card in f.accounts where card.kind == .creditCard && card.balance > 0 && card.paymentDueReminder {
            let due = card.nextUpcomingDueDate(from: now, calendar: cal)
            if due <= horizonEnd {
                addEvent(FinancialProjectionEvent(
                    id: "card-\(card.id.uuidString)",
                    title: "\(card.name) Statement Due",
                    date: due,
                    amount: card.balance,
                    signedImpact: -card.balance,
                    kind: .scheduledExpense,
                    accountOrCategory: card.name,
                    explanation: "Current credit card balance due on \(card.name).",
                    isConfirmed: true
                ), affectsBalance: true)
            }
        }

        // C. Expected Income (inferred from actual historical income transactions)
        let incomeTxs = f.ordinaryIncomeTransactions.filter { $0.date >= lookbackStart && $0.date <= now }
        if expectedMonthlyIncome > 0 {
            let typicalPayDay: Int = {
                let days = incomeTxs.map { cal.component(.day, from: $0.date) }
                guard !days.isEmpty else { return f.cycleStartDay }
                // Use the day of the largest income deposit (usually salary)
                if let largest = incomeTxs.max(by: { $0.amount < $1.amount }) {
                    return min(28, max(1, cal.component(.day, from: largest.date)))
                }
                return min(28, max(1, days.reduce(0, +) / days.count))
            }()
            var cursor = cal.date(from: cal.dateComponents([.year, .month], from: today)) ?? today
            for mOffset in 0...(Int(ceil(period.months)) + 1) {
                guard let mDate = cal.date(byAdding: .month, value: mOffset, to: cursor) else { continue }
                let maxDay = cal.range(of: .day, in: .month, for: mDate)?.upperBound.advanced(by: -1) ?? 28
                var comps = cal.dateComponents([.year, .month], from: mDate)
                comps.day = min(typicalPayDay, maxDay)
                if let payDate = cal.date(from: comps), payDate > today, payDate <= horizonEnd {
                    addEvent(FinancialProjectionEvent(
                        id: "income-\(mOffset)",
                        title: "Expected Income",
                        date: payDate,
                        amount: expectedMonthlyIncome,
                        signedImpact: expectedMonthlyIncome,
                        kind: .expectedIncome,
                        accountOrCategory: "Income",
                        explanation: "Estimated from your recent \(Int(round(historySpanDays)))-day income average.",
                        isConfirmed: false
                    ), affectsBalance: true)
                }
            }
        }

        // D. Detected Recurring Expenses (not already tracked as Bills)
        let recurring = f.recurringCandidates()
        for cand in recurring where cand.amount > 0 {
            var nextDate = cal.date(byAdding: .month, value: 1, to: cal.startOfDay(for: cand.lastDate)) ?? today
            while nextDate < today {
                nextDate = cal.date(byAdding: .month, value: 1, to: nextDate) ?? horizonEnd.addingTimeInterval(86_400)
            }
            var idx = 0
            while nextDate <= horizonEnd && idx < 13 {
                addEvent(FinancialProjectionEvent(
                    id: "rec-\(cand.key)-\(idx)",
                    title: cand.name,
                    date: nextDate,
                    amount: cand.amount,
                    signedImpact: 0, // already reflected in daily discretionary baseline; marker avoids double-deduction
                    kind: .recurringExpense,
                    accountOrCategory: cand.category.title,
                    explanation: "Detected recurring payment (\(cand.occurrences) past occurrences; already included in your spending pace).",
                    isConfirmed: false
                ), affectsBalance: false)
                nextDate = cal.date(byAdding: .month, value: 1, to: nextDate) ?? horizonEnd.addingTimeInterval(86_400)
                idx += 1
            }
        }

        // E. Planned Savings Contributions & Savings Goal Deadlines
        for goal in f.goals where !goal.isComplete {
            if goal.monthlyCommitment > 0 {
                let firstDate = cal.date(byAdding: .day, value: 7, to: today) ?? today
                var cursor = firstDate
                var idx = 0
                while cursor <= horizonEnd && idx < 13 {
                    addEvent(FinancialProjectionEvent(
                        id: "save-\(goal.id.uuidString)-\(idx)",
                        title: "Save for \(goal.name)",
                        date: cursor,
                        amount: goal.monthlyCommitment,
                        signedImpact: -goal.monthlyCommitment,
                        kind: .plannedSavings,
                        accountOrCategory: goal.name,
                        explanation: "Planned monthly savings contribution toward \(goal.name).",
                        isConfirmed: true
                    ), affectsBalance: true)
                    cursor = cal.date(byAdding: .month, value: 1, to: cursor) ?? horizonEnd.addingTimeInterval(86_400)
                    idx += 1
                }
            }
            let deadline = cal.startOfDay(for: goal.targetDate)
            if deadline >= today && deadline <= horizonEnd {
                let rem = max(0, goal.target - goal.saved)
                addEvent(FinancialProjectionEvent(
                    id: "goal-deadline-\(goal.id.uuidString)",
                    title: "\(goal.name) Target Date",
                    date: deadline,
                    amount: rem,
                    signedImpact: 0,
                    kind: .goalDeadline,
                    accountOrCategory: goal.name,
                    explanation: rem > 0
                        ? "\(Money.format(rem, currency)) remaining to reach your \(Money.format(goal.target, currency)) goal."
                        : "Goal target reached.",
                    isConfirmed: true
                ), affectsBalance: false)
            }
        }

        // F. Seasonal Events (Ramadan & Eid Al-Fitr / Eid Al-Adha via Umm al-Qura calendar)
        // Informational markers only — never invent fake spending amounts!
        let seasonalMarkers = upcomingIslamicSeasonalEvents(from: today, to: horizonEnd)
        for marker in seasonalMarkers {
            addEvent(marker, affectsBalance: false)
        }

        events.sort { $0.date < $1.date }

        // Build Actual Past Timeline (last 14–30 days from real Finance balanceSeries)
        let rawActual = f.balanceSeries().actual
        let actualPoints: [ProjectionTimelinePoint] = rawActual.map {
            ProjectionTimelinePoint(date: $0.date, balance: $0.value, isActual: true)
        }

        // Build Projected Timeline (day-by-day simulation, downsampled cleanly for 6M/1Y chart smoothness)
        var projectedDaily: [ProjectionTimelinePoint] = [
            ProjectionTimelinePoint(date: today, balance: startingBalance, isActual: false)
        ]
        var runningBalance = startingBalance
        var lowestBalance = startingBalance
        var lowestBalanceDate = today
        var shortfallDate: Date? = nil
        var shortfallAmount: Double = 0

        for dayOffset in 1...period.days {
            guard let d = cal.date(byAdding: .day, value: dayOffset, to: today) else { continue }
            runningBalance -= dailyDiscretionary
            runningBalance += (cashflowByDay[d] ?? 0)
            projectedDaily.append(ProjectionTimelinePoint(date: d, balance: runningBalance, isActual: false))
            if runningBalance < lowestBalance {
                lowestBalance = runningBalance
                lowestBalanceDate = d
            }
            if runningBalance < 0 && shortfallDate == nil {
                shortfallDate = d
                shortfallAmount = abs(runningBalance)
            }
        }

        let projectedPoints: [ProjectionTimelinePoint] = {
            let step = period.days <= 90 ? 1 : (period.days <= 180 ? 3 : 7)
            guard step > 1 else { return projectedDaily }
            var sampled: [ProjectionTimelinePoint] = []
            for (idx, pt) in projectedDaily.enumerated() {
                if idx == 0 || idx == projectedDaily.count - 1 || idx % step == 0 || cal.isDate(pt.date, inSameDayAs: lowestBalanceDate) {
                    sampled.append(pt)
                }
            }
            return sampled
        }()

        // Assumptions, Missing Data & Uncertainty
        var assumptions: [String] = []
        var missingData: [String] = []

        if f.accounts.isEmpty {
            missingData.append("No accounts added yet — starting balance is 0.")
        }
        if incomeTxs.isEmpty {
            missingData.append("No recent income transactions found — projected income is treated as 0.")
        } else {
            assumptions.append("Expected monthly income of \(Money.format(expectedMonthlyIncome, currency)) based on your recent history.")
        }
        if nonBillSpending <= 0 {
            missingData.append("Limited spending history — variable daily spending could not be estimated accurately.")
        } else {
            assumptions.append("Variable spending pace of \(Money.format(expectedMonthlyDiscretionary, currency))/mo excluding bills.")
        }
        if !f.bills.isEmpty {
            assumptions.append("\(f.bills.count) scheduled bill\(f.bills.count == 1 ? "" : "s") totaling \(Money.format(monthlyBills, currency))/mo included.")
        }
        if monthlyLoans > 0 {
            assumptions.append("Loan installments of \(Money.format(monthlyLoans, currency))/mo included.")
        }
        if monthlyGoals > 0 {
            assumptions.append("Planned savings commitments of \(Money.format(monthlyGoals, currency))/mo included.")
        }

        let hasSufficientData = !f.accounts.isEmpty && (historySpanDays >= 7 || !f.bills.isEmpty || !f.goals.isEmpty)
        let uncertainty: ProjectionUncertainty = {
            if !hasSufficientData || missingData.count >= 2 { return .high }
            if historySpanDays < 25 || incomeTxs.isEmpty { return .medium }
            return .low
        }()

        let primaryInsight = buildPrimaryInsight(
            period: period,
            startingBalance: startingBalance,
            projectedEndBalance: runningBalance,
            lowestBalance: lowestBalance,
            lowestBalanceDate: lowestBalanceDate,
            expectedMonthlyIncome: expectedMonthlyIncome,
            expectedMonthlyExpenses: expectedMonthlyExpenses,
            monthlyCommitments: expectedMonthlyCommitments,
            shortfallDate: shortfallDate,
            events: events,
            goals: f.goals,
            hasSufficientData: hasSufficientData,
            currency: currency
        )

        return FinancialProjectionResult(
            period: period,
            now: now,
            startingBalance: startingBalance,
            projectedEndBalance: runningBalance,
            lowestBalance: lowestBalance,
            lowestBalanceDate: lowestBalanceDate,
            expectedMonthlyIncome: expectedMonthlyIncome,
            expectedMonthlyExpenses: expectedMonthlyExpenses,
            expectedMonthlyCommitments: expectedMonthlyCommitments,
            expectedMonthlySavings: monthlyGoals,
            projectedSafeToSpendMonthly: f.safeToSpend.monthly,
            actualPoints: actualPoints,
            projectedPoints: projectedPoints,
            events: events,
            hasSufficientData: hasSufficientData,
            assumptions: assumptions,
            missingData: missingData,
            uncertainty: uncertainty,
            shortfallDate: shortfallDate,
            shortfallAmount: shortfallAmount,
            primaryInsight: primaryInsight
        )
    }

    // MARK: 2. Buy Now? Purchase Simulation (Strictly Hypothetical)

    static func simulateBuyNow(
        input: BuyNowSimulationInput,
        finance f: Finance,
        currency: String = AppSettings.currency,
        cachedProjection: FinancialProjectionResult? = nil
    ) -> BuyNowSimulationResult {
        let amount = input.amount
        let safe = f.safeToSpend
        let projection = cachedProjection ?? project(finance: f, period: .threeMonths, currency: currency)

        // 1. SAFE TO SPEND
        let safeBefore = safe.monthly
        let safeAfter = safeBefore - amount
        let safeStatus: SimulationStatus = {
            if safeAfter < 0 { return .risk }
            if safeBefore > 0 && safeAfter < safeBefore * 0.25 { return .caution }
            return .safe
        }()
        let safeExplanation: String = {
            switch safeStatus {
            case .safe:
                return "Leaves \(Money.format(safeAfter, currency)) in Safe to Spend after bills, essential budgets, and savings."
            case .caution:
                return "Uses over 75% of your remaining Safe to Spend buffer for this cycle."
            case .risk:
                return "Exceeds your Safe to Spend buffer by \(Money.format(abs(safeAfter), currency)) and may squeeze essential spending or bills."
            }
        }()

        // 2. SAVING GOALS
        let activeGoals = f.goals.filter { !$0.isComplete && $0.target > 0 }
        let totalSaved = activeGoals.reduce(0.0) { $0 + $1.saved }
        let totalTarget = activeGoals.reduce(0.0) { $0 + $1.target }
        let currentProgress = totalTarget > 0 ? min(1, totalSaved / totalTarget) : 0

        let monthlySurplus = max(0, projection.expectedMonthlyIncome - projection.expectedMonthlyExpenses)
        let primaryGoal = activeGoals.sorted { $0.targetDate < $1.targetDate }.first
        let goalContributionRate = max(primaryGoal?.monthlyCommitment ?? 0, monthlySurplus)

        var delayedGoalName: String? = nil
        var estimatedDelayDays: Int? = nil
        let projectedProgress: Double
        let goalStatus: SimulationStatus
        let goalExplanation: String

        if activeGoals.isEmpty {
            projectedProgress = 0
            goalStatus = .safe
            goalExplanation = "No active savings goals are currently configured."
        } else if safeAfter >= 0 {
            projectedProgress = currentProgress
            goalStatus = .safe
            goalExplanation = "Your existing savings goal commitments remain funded."
        } else {
            let shortfall = abs(safeAfter)
            let effectiveSavedAfter = max(0, totalSaved - shortfall)
            projectedProgress = totalTarget > 0 ? min(1, effectiveSavedAfter / totalTarget) : 0
            delayedGoalName = primaryGoal?.name
            if goalContributionRate > 0 {
                let delayDays = Int(ceil((shortfall / goalContributionRate) * daysPerMonth))
                estimatedDelayDays = max(1, delayDays)
                goalStatus = delayDays >= 30 ? .risk : .caution
                goalExplanation = "May delay \(primaryGoal?.name ?? "your savings goal") by about \(delayDays) day\(delayDays == 1 ? "" : "s") if funded from savings."
            } else {
                goalStatus = .caution
                goalExplanation = "Could slow down progress toward \(primaryGoal?.name ?? "your savings goals")."
            }
        }

        // 3. BUDGET
        let totalsByCat = f.spendingTotalsByCategory(in: f.thisMonth)
        let matchingBudget: Budget? = {
            if let cat = input.category {
                return f.budgets.first(where: { $0.includes(cat) })
            }
            return nil
        }()
        let hasBudgetConfigured = !f.budgets.isEmpty
        let budgetTitle: String
        let budgetBefore: Double
        if let mb = matchingBudget {
            budgetTitle = mb.displayName
            let spent = Set(mb.categories.map(\.rawValue)).reduce(0.0) { $0 + (totalsByCat[$1] ?? 0) }
            budgetBefore = mb.limit - spent
        } else {
            budgetTitle = "Total Monthly Budget"
            budgetBefore = f.budgetLeft
        }
        let budgetAfter = budgetBefore - amount
        let budgetStatus: SimulationStatus = {
            guard hasBudgetConfigured else { return .safe }
            if budgetAfter < 0 { return .risk }
            if budgetBefore > 0 && budgetAfter < budgetBefore * 0.20 { return .caution }
            return .safe
        }()
        let budgetExplanation: String = {
            guard hasBudgetConfigured else { return "No monthly budget limits are configured yet." }
            switch budgetStatus {
            case .safe:
                return "Fits comfortably within \(budgetTitle)."
            case .caution:
                return "Leaves less than 20% remaining in \(budgetTitle)."
            case .risk:
                return "Exceeds \(budgetTitle) by \(Money.format(abs(budgetAfter), currency))."
            }
        }()

        // 4. BILLS & INSTALLMENTS
        let upcomingBillsTotal = f.billsDueRestOfMonth
        let loanInstallmentsTotal = f.safeToSpendLiabilities
        let lowestAfter = projection.lowestBalance - amount
        let liquidAfter = projection.startingBalance - amount
        let billsCovered = liquidAfter >= upcomingBillsTotal
        let loansCovered = liquidAfter >= (upcomingBillsTotal + loanInstallmentsTotal)
        let createsCashShortfall = lowestAfter < 0
        let billsStatus: SimulationStatus = {
            if !billsCovered || !loansCovered || createsCashShortfall { return .risk }
            if lowestAfter < max(20, (upcomingBillsTotal + loanInstallmentsTotal) * 0.15) { return .caution }
            return .safe
        }()
        let billsExplanation: String = {
            if !billsCovered {
                return "Upcoming bills (\(Money.format(upcomingBillsTotal, currency))) may not be fully covered."
            }
            if !loansCovered {
                return "Upcoming bills and loan/card liabilities (\(Money.format(upcomingBillsTotal + loanInstallmentsTotal, currency))) exceed remaining balance."
            }
            if createsCashShortfall {
                let dStr = projection.lowestBalanceDate.formatted(.dateTime.month(.abbreviated).day())
                return "May create a projected cash shortfall of \(Money.format(abs(lowestAfter), currency)) around \(dStr)."
            }
            return "All upcoming bills and loan installments remain covered."
        }()

        // Overall status (worst of 4 pillars)
        let statuses = [safeStatus, goalStatus, budgetStatus, billsStatus]
        let overallStatus: SimulationStatus = statuses.contains(.risk) ? .risk : (statuses.contains(.caution) ? .caution : .safe)

        let summaryReason: String = {
            switch overallStatus {
            case .safe:
                return "This purchase fits within your Safe to Spend, budget, and upcoming commitments."
            case .caution:
                return "You can cover this purchase, but it leaves a tight buffer for the rest of the cycle."
            case .risk:
                if !billsCovered || !loansCovered || createsCashShortfall {
                    return "This purchase puts upcoming bills, installments, or your future balance at risk."
                }
                return "This purchase exceeds your Safe to Spend or remaining monthly budget."
            }
        }()

        var recs: [String] = []
        switch overallStatus {
        case .safe:
            recs.append("You can proceed comfortably without disturbing bills or savings goals.")
        case .caution:
            if let nextIncome = projection.events.first(where: { $0.kind == .expectedIncome }) {
                recs.append("Consider waiting until your next expected income around \(nextIncome.date.formatted(.dateTime.month(.abbreviated).day())).")
            }
            recs.append("Trimming a non-essential category this month would keep your buffer healthy.")
        case .risk:
            if safeBefore > 0 {
                recs.append("Keep the purchase under \(Money.format(safeBefore, currency)) to stay within Safe to Spend.")
            }
            if let nextIncome = projection.events.first(where: { $0.kind == .expectedIncome }) {
                recs.append("Wait until after your expected income on \(nextIncome.date.formatted(.dateTime.month(.abbreviated).day())).")
            }
            recs.append("Save for this item in a short-term goal or track it in your Wishlist until your balance recovers.")
        }

        return BuyNowSimulationResult(
            input: input,
            overallStatus: overallStatus,
            summaryReason: summaryReason,
            safeToSpend: BuyNowSafeToSpendImpact(before: safeBefore, after: safeAfter, status: safeStatus, explanation: safeExplanation),
            savingGoals: BuyNowGoalsImpact(
                currentProgress: currentProgress,
                projectedProgress: projectedProgress,
                totalSaved: totalSaved,
                totalTarget: totalTarget,
                delayedGoalName: delayedGoalName,
                estimatedDelayDays: estimatedDelayDays,
                status: goalStatus,
                explanation: goalExplanation
            ),
            budget: BuyNowBudgetImpact(beforeRemaining: budgetBefore, afterRemaining: budgetAfter, categoryTitle: budgetTitle, hasBudgetConfigured: hasBudgetConfigured, status: budgetStatus, explanation: budgetExplanation),
            bills: BuyNowBillsImpact(
                upcomingBillsTotal: upcomingBillsTotal,
                loanInstallmentsTotal: loanInstallmentsTotal,
                billsCovered: billsCovered,
                loansCovered: loansCovered,
                createsCashShortfall: createsCashShortfall,
                shortfallDate: createsCashShortfall ? projection.lowestBalanceDate : nil,
                projectedLowestAfterPurchase: lowestAfter,
                status: billsStatus,
                explanation: billsExplanation
            ),
            recommendations: recs
        )
    }

    // MARK: 3. Saving Goal Simulation (Strictly Hypothetical Until Confirmed)

    static func simulateSavingGoal(
        input: SavingGoalSimulationInput,
        finance f: Finance,
        currency: String = AppSettings.currency
    ) -> SavingGoalSimulationResult {
        let cal = Calendar.current
        let start = cal.startOfDay(for: input.startDate)
        let target = cal.startOfDay(for: input.targetDate)
        let remainingDays = max(1, cal.dateComponents([.day], from: start, to: target).day ?? 30)
        let remainingMonths = max(1.0 / 30.0, Double(remainingDays) / daysPerMonth)

        let remainingAmount = max(0, input.targetAmount - input.currentSaved)
        let requiredMonthly = remainingAmount > 0 ? (remainingAmount / remainingMonths) : 0
        let requiredWeekly = remainingAmount > 0 ? (remainingAmount / max(1.0, Double(remainingDays) / 7.0)) : 0
        let currentProgress = input.targetAmount > 0 ? min(1, input.currentSaved / input.targetAmount) : 0

        let projection = project(finance: f, period: remainingMonths > 6 ? .oneYear : .sixMonths, currency: currency)
        let safeBefore = f.safeToSpend.monthly
        let monthlyNetSurplus = max(0, projection.expectedMonthlyIncome - projection.expectedMonthlyExpenses - projection.expectedMonthlySavings)
        let affordableMonthlyCapacity = max(monthlyNetSurplus, max(0, safeBefore * 0.65))
        let safeAfter = safeBefore - requiredMonthly

        let isAchievable = remainingAmount <= 0.005 || (requiredMonthly <= max(safeBefore, monthlyNetSurplus) && safeAfter >= 0)
        let isSustainable = remainingAmount <= 0.005 || (monthlyNetSurplus > 0 ? requiredMonthly <= monthlyNetSurplus * 0.85 : requiredMonthly <= safeBefore * 0.50)

        let expectedCompletionDate: Date = {
            if remainingAmount <= 0.005 { return start }
            if isAchievable { return target }
            let realisticMonthly = max(1, affordableMonthlyCapacity)
            let neededDays = Int(ceil((remainingAmount / realisticMonthly) * daysPerMonth))
            return cal.date(byAdding: .day, value: min(neededDays, 3650), to: start) ?? target
        }()

        let projectedProgressAtTargetDate: Double = {
            guard input.targetAmount > 0 else { return 0 }
            if isAchievable { return 1.0 }
            let projectedAdded = affordableMonthlyCapacity * remainingMonths
            return min(1.0, (input.currentSaved + projectedAdded) / input.targetAmount)
        }()

        // 1. Safe to Spend
        let safeStatus: SimulationStatus = {
            if safeAfter < 0 { return .risk }
            if !isSustainable { return .caution }
            return .safe
        }()
        let safeExplanation: String = {
            switch safeStatus {
            case .safe:
                return "Affordable monthly contribution leaving \(Money.format(safeAfter, currency)) in Safe to Spend."
            case .caution:
                return "Achievable, but commits a large share of your monthly surplus."
            case .risk:
                return "Required \(Money.format(requiredMonthly, currency))/mo exceeds your available Safe to Spend."
            }
        }()

        // 2. Saving Goals
        let goalsOnTrack = isAchievable && isSustainable
        let goalsStatus: SimulationStatus = goalsOnTrack ? .safe : (isAchievable ? .caution : .risk)
        let goalsExplanation: String = remainingAmount <= 0.005
            ? "You have already saved enough to reach this goal."
            : (goalsOnTrack
                ? "On track to reach \(Money.format(input.targetAmount, currency)) by \(target.formatted(.dateTime.month(.abbreviated).year()))."
                : "At your current surplus, completion is closer to \(expectedCompletionDate.formatted(.dateTime.month(.abbreviated).year())).")

        // 3. Budget
        let budgetBefore = f.budgetLeft
        let budgetAfter = budgetBefore - requiredMonthly
        let breakdown = f.categoryBreakdown(in: f.thisMonth)
        let adjustableCategories = breakdown
            .filter { !$0.category.isEssential && $0.amount > 0 }
            .prefix(3)
            .map { $0.category.title }
        let budgetStatus: SimulationStatus = {
            if f.budgets.isEmpty { return safeStatus }
            if budgetAfter < 0 { return .risk }
            if budgetBefore > 0 && budgetAfter < budgetBefore * 0.20 { return .caution }
            return .safe
        }()
        let budgetExplanation: String = {
            if f.budgets.isEmpty { return "No monthly budgets configured; evaluated against Safe to Spend." }
            if budgetAfter < 0 {
                let cats = adjustableCategories.isEmpty ? "discretionary categories" : adjustableCategories.joined(separator: ", ")
                return "Creates a monthly budget shortage of \(Money.format(abs(budgetAfter), currency)). Consider trimming \(cats)."
            }
            return "Fits within your remaining monthly budget."
        }()

        // 4. Bills & Installments
        let billsCovered = (projection.startingBalance - requiredMonthly) >= f.billsDueRestOfMonth
        let loansCovered = (projection.startingBalance - requiredMonthly) >= (f.billsDueRestOfMonth + f.safeToSpendLiabilities)
        let createsShortfall = (projection.lowestBalance - requiredMonthly) < 0
        let billsStatus: SimulationStatus = (!billsCovered || !loansCovered || createsShortfall) ? .risk : .safe
        let billsExplanation: String = billsStatus == .safe
            ? "Upcoming bills and installments remain covered with this saving plan."
            : "This monthly saving amount could strain upcoming bills or create a projected cash shortfall."

        let statuses = [safeStatus, goalsStatus, budgetStatus, billsStatus]
        let overallStatus: SimulationStatus = statuses.contains(.risk) ? .risk : (statuses.contains(.caution) ? .caution : .safe)

        let summaryReason: String = {
            switch overallStatus {
            case .safe:
                return "This goal is achievable and sustainable at \(Money.format(requiredMonthly, currency))/mo."
            case .caution:
                return "Achievable, though \(Money.format(requiredMonthly, currency))/mo will keep your monthly buffer tight."
            case .risk:
                return "Saving \(Money.format(requiredMonthly, currency))/mo is higher than your current safe monthly capacity."
            }
        }()

        let suggestedAffordable = max(0, (affordableMonthlyCapacity * 0.85))
        let suggestedExtendedMonths: Int? = {
            guard !isAchievable, suggestedAffordable > 1 else { return nil }
            return max(Int(ceil(remainingMonths)) + 1, Int(ceil(remainingAmount / suggestedAffordable)))
        }()

        var suggestions: [String] = []
        if !isAchievable || !isSustainable {
            if let ext = suggestedExtendedMonths {
                suggestions.append("Extend the saving period to \(ext) months to lower the monthly amount to \(Money.format(remainingAmount / Double(ext), currency))/mo.")
            }
            if suggestedAffordable > 0 {
                let lowerTarget = input.currentSaved + (suggestedAffordable * remainingMonths)
                suggestions.append("Or reduce the target to \(Money.format(lowerTarget, currency)) to stay within \(Money.format(suggestedAffordable, currency))/mo.")
            }
            if !adjustableCategories.isEmpty {
                suggestions.append("Adjusting \(adjustableCategories.joined(separator: " or ")) spending could free up extra monthly savings.")
            }
        } else {
            suggestions.append("Setting aside \(Money.format(requiredMonthly, currency))/mo (\(Money.format(requiredWeekly, currency))/wk) keeps you on schedule.")
        }

        return SavingGoalSimulationResult(
            input: input,
            remainingAmount: remainingAmount,
            remainingDays: remainingDays,
            remainingMonths: remainingMonths,
            requiredMonthlyContribution: requiredMonthly,
            requiredWeeklyContribution: requiredWeekly,
            currentProgress: currentProgress,
            projectedProgressAtTargetDate: projectedProgressAtTargetDate,
            expectedCompletionDate: expectedCompletionDate,
            isAchievable: isAchievable,
            isSustainable: isSustainable,
            overallStatus: overallStatus,
            summaryReason: summaryReason,
            safeToSpendBeforeMonthly: safeBefore,
            safeToSpendAfterMonthly: safeAfter,
            safeToSpendStatus: safeStatus,
            safeToSpendExplanation: safeExplanation,
            goalsOnTrack: goalsOnTrack,
            goalsStatus: goalsStatus,
            goalsExplanation: goalsExplanation,
            budgetRemainingBefore: budgetBefore,
            budgetRemainingAfter: budgetAfter,
            adjustableCategories: adjustableCategories,
            budgetStatus: budgetStatus,
            budgetExplanation: budgetExplanation,
            billsCovered: billsCovered,
            loansCovered: loansCovered,
            createsCashShortfall: createsShortfall,
            billsStatus: billsStatus,
            billsExplanation: billsExplanation,
            smartSuggestions: suggestions,
            suggestedAffordableMonthly: suggestedAffordable,
            suggestedExtendedMonths: suggestedExtendedMonths
        )
    }

    // MARK: Helpers

    private static func upcomingIslamicSeasonalEvents(from start: Date, to end: Date) -> [FinancialProjectionEvent] {
        let hijri = Calendar(identifier: .islamicUmmAlQura)
        let startYear = hijri.component(.year, from: start)
        let endYear = hijri.component(.year, from: end)
        var out: [FinancialProjectionEvent] = []

        for year in startYear...endYear {
            // Ramadan: 1 Ramadan (month 9, day 1)
            if let ramadan = hijri.date(from: DateComponents(year: year, month: 9, day: 1)),
               ramadan >= start && ramadan <= end {
                out.append(FinancialProjectionEvent(
                    id: "seasonal-ramadan-\(year)",
                    title: "Ramadan",
                    date: ramadan,
                    amount: 0,
                    signedImpact: 0,
                    kind: .seasonalRamadan,
                    accountOrCategory: "Seasonal Planning",
                    explanation: "Ramadan begins around this date. Plan ahead for seasonal groceries, dining, and family gifting.",
                    isConfirmed: false
                ))
            }
            // Eid Al-Fitr: 1 Shawwal (month 10, day 1)
            if let eidFitr = hijri.date(from: DateComponents(year: year, month: 10, day: 1)),
               eidFitr >= start && eidFitr <= end {
                out.append(FinancialProjectionEvent(
                    id: "seasonal-eid-fitr-\(year)",
                    title: "Eid Al-Fitr",
                    date: eidFitr,
                    amount: 0,
                    signedImpact: 0,
                    kind: .seasonalEid,
                    accountOrCategory: "Seasonal Planning",
                    explanation: "Eid Al-Fitr falls within your selected period. Consider reserving a buffer for gifts and celebrations.",
                    isConfirmed: false
                ))
            }
            // Eid Al-Adha: 10 Dhul Hijjah (month 12, day 10)
            if let eidAdha = hijri.date(from: DateComponents(year: year, month: 12, day: 10)),
               eidAdha >= start && eidAdha <= end {
                out.append(FinancialProjectionEvent(
                    id: "seasonal-eid-adha-\(year)",
                    title: "Eid Al-Adha",
                    date: eidAdha,
                    amount: 0,
                    signedImpact: 0,
                    kind: .seasonalEid,
                    accountOrCategory: "Seasonal Planning",
                    explanation: "Eid Al-Adha falls within your selected period. Plan ahead for travel or holiday spending.",
                    isConfirmed: false
                ))
            }
        }
        return out
    }

    private static func buildPrimaryInsight(
        period: ForecastPeriod,
        startingBalance: Double,
        projectedEndBalance: Double,
        lowestBalance: Double,
        lowestBalanceDate: Date,
        expectedMonthlyIncome: Double,
        expectedMonthlyExpenses: Double,
        monthlyCommitments: Double,
        shortfallDate: Date?,
        events: [FinancialProjectionEvent],
        goals: [SavingsGoal],
        hasSufficientData: Bool,
        currency: String
    ) -> PrimaryForecastInsight {
        if !hasSufficientData {
            return PrimaryForecastInsight(
                title: "Add more activity for sharper forecasts",
                what: "Your \(period.title.lowercased()) projection is based on limited history.",
                why: "Adding your bank accounts, recent transactions, or recurring bills gives FALAK a reliable baseline.",
                when: "Over the next \(period.title.lowercased())",
                action: "Import bank SMS or add your regular bills to unlock accurate cashflow forecasts.",
                severity: .caution,
                isAIEnhanced: false
            )
        }

        if let sDate = shortfallDate {
            let dateStr = sDate.formatted(.dateTime.month(.abbreviated).day())
            return PrimaryForecastInsight(
                title: "Possible cash shortfall ahead",
                what: "Your projected balance may dip below zero to \(Money.format(lowestBalance, currency)).",
                why: "Upcoming bills, installments, and your current spending pace outpace expected inflows.",
                when: "Around \(dateStr)",
                action: "Reserve extra cash before \(dateStr) or reduce discretionary spending this cycle.",
                severity: .risk,
                isAIEnhanced: false
            )
        }

        if expectedMonthlyIncome > 0 && expectedMonthlyExpenses > expectedMonthlyIncome * 1.05 {
            let gap = expectedMonthlyExpenses - expectedMonthlyIncome
            return PrimaryForecastInsight(
                title: "Spending pace exceeds usual income",
                what: "Projected monthly outflow exceeds income by about \(Money.format(gap, currency))/mo.",
                why: "Variable spending plus \(Money.format(monthlyCommitments, currency))/mo in bills and installments is higher than recent income.",
                when: "Across the next \(period.title.lowercased())",
                action: "Review non-essential category budgets or test adjustments before making big purchases.",
                severity: .caution,
                isAIEnhanced: false
            )
        }

        if lowestBalance < startingBalance * 0.40 && startingBalance > 0 {
            let dateStr = lowestBalanceDate.formatted(.dateTime.month(.abbreviated).day())
            let nextIncome = events.first(where: { $0.kind == .expectedIncome && $0.date > lowestBalanceDate })
            let whyText = nextIncome != nil
                ? "Scheduled bills and installments hit before your next expected income."
                : "Upcoming scheduled bills and spending lower your cash buffer."
            return PrimaryForecastInsight(
                title: "Balance dips before recovering",
                what: "Your balance is projected to dip to \(Money.format(lowestBalance, currency)).",
                why: whyText,
                when: "Around \(dateStr)",
                action: "Keep a cushion for upcoming bills until your balance rebounds.",
                severity: .caution,
                isAIEnhanced: false
            )
        }

        if let nextGoal = goals.first(where: { !$0.isComplete && $0.target > 0 }),
           projectedEndBalance > startingBalance + (nextGoal.target - nextGoal.saved) * 0.25 {
            return PrimaryForecastInsight(
                title: "Positive momentum toward your goals",
                what: "Your projected balance grows by \(Money.format(projectedEndBalance - startingBalance, currency)) over \(period.title.lowercased()).",
                why: "Your expected income comfortably covers bills, installments, and current spending.",
                when: "Over the next \(period.title.lowercased())",
                action: "Consider allocating part of this surplus to reach \(nextGoal.name) earlier.",
                severity: .safe,
                isAIEnhanced: false
            )
        }

        return PrimaryForecastInsight(
            title: "Steady financial outlook",
            what: "Your balance is projected to finish at \(Money.format(projectedEndBalance, currency)).",
            why: "Upcoming bills and installments remain covered based on your current pace.",
            when: "Over the next \(period.title.lowercased())",
            action: "Use Buy Now? or Saving Goal below to test any upcoming plans safely.",
            severity: .safe,
            isAIEnhanced: false
        )
    }
}
