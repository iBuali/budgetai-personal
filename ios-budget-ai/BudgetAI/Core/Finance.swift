import Foundation

struct ChartPoint: Identifiable {
    var id: Date { date }
    let date: Date
    let value: Double
}

struct SafeToSpend {
    let spendable: Double
    let billsDue: Double
    let essentials: Double
    let savings: Double
    var liabilities: Double = 0
    let daysLeft: Int

    var monthly: Double { max(0, spendable - billsDue - essentials - savings - liabilities) }
    var daily: Double { daysLeft > 0 ? monthly / Double(daysLeft) : monthly }
    var isShort: Bool { spendable - billsDue - essentials - savings - liabilities < 0 }
}

struct MonthTotal: Identifiable {
    var id: Date { month }
    let month: Date
    let income: Double
    let expenses: Double
}

struct RecurringCandidate: Identifiable {
    var id: String { key }
    let key: String
    let name: String
    let amount: Double
    let lastDate: Date
    let category: SpendCategory
    let occurrences: Int
}

enum ChartRange: String, CaseIterable, Identifiable {
    case week = "Week", month = "Month", year = "Year"
    var id: String { rawValue }
}

/// Pure calculations over the user's data. Pre-indexes approved transactions for fast rendering.
struct Finance {
    let transactions: [MoneyTransaction]
    let approvedTransactions: [MoneyTransaction]
    let spendingTransactions: [MoneyTransaction]
    let ordinaryIncomeTransactions: [MoneyTransaction]
    let accounts: [Account]
    let budgets: [Budget]
    let goals: [SavingsGoal]
    let bills: [Bill]
    let now: Date
    let cal = Calendar.current
    let thisMonth: DateInterval

    init(transactions: [MoneyTransaction], accounts: [Account] = [], budgets: [Budget] = [],
         goals: [SavingsGoal] = [], bills: [Bill] = [], now: Date = .now) {
        var approved: [MoneyTransaction] = []
        var spending: [MoneyTransaction] = []
        var income: [MoneyTransaction] = []
        approved.reserveCapacity(transactions.count)
        for tx in transactions where !tx.isPending {
            approved.append(tx)
            if tx.isSpending {
                spending.append(tx)
            }
            if tx.isOrdinaryIncome {
                income.append(tx)
            }
        }
        self.transactions = approved
        self.approvedTransactions = approved
        self.spendingTransactions = spending
        self.ordinaryIncomeTransactions = income
        self.accounts = accounts
        self.budgets = budgets
        self.goals = goals
        self.bills = bills
        self.now = now
        self.thisMonth = Cycle.interval(containing: now)
    }

    // MARK: Balances

    var liquidBalance: Double { accounts.filter { $0.kind.isLiquid }.reduce(0) { $0 + $1.balance } }
    var totalAssets: Double { accounts.filter { $0.includeInNetWorth && !$0.kind.isLiability }.reduce(0) { $0 + $1.balance } }
    var totalLiabilities: Double { accounts.filter { $0.includeInNetWorth && $0.kind.isLiability }.reduce(0) { $0 + $1.balance } }
    var netWorth: Double { totalAssets - totalLiabilities }

    /// Liability amount deducted in Safe to Spend for an account.
    /// Loans count only their monthly installment payment rather than the full remaining loan balance.
    func safeToSpendLiability(for account: Account) -> Double {
        guard account.includeInNetWorth, account.kind.isLiability, account.balance > 0 else { return 0 }
        if account.kind == .loan {
            return min(account.balance, max(0, account.loanMonthlyInstallment))
        }
        return max(0, account.balance)
    }

    var safeToSpendLiabilities: Double {
        accounts.reduce(0) { $0 + safeToSpendLiability(for: $1) }
    }

    // MARK: Periods

    /// Budget cycle containing `date` (custom start day aware).
    func monthInterval(_ date: Date) -> DateInterval {
        Cycle.interval(containing: date)
    }

    var lastMonth: DateInterval {
        monthInterval(cal.date(byAdding: .month, value: -1, to: now) ?? now)
    }

    func rangeInterval(_ range: ChartRange) -> DateInterval {
        let today = cal.startOfDay(for: now)
        let endOfToday = cal.date(byAdding: .day, value: 1, to: today) ?? now.addingTimeInterval(86_400)
        switch range {
        case .week:
            let start = cal.date(byAdding: .day, value: -6, to: today) ?? today
            return DateInterval(start: start, end: endOfToday)
        case .month:
            return thisMonth
        case .year:
            let firstMonth = cal.date(byAdding: .month, value: -11, to: now) ?? now
            let start = monthInterval(firstMonth).start
            let end = max(thisMonth.end, endOfToday)
            return DateInterval(start: start, end: end)
        }
    }

    func rangeSubtitle(_ range: ChartRange) -> String {
        switch range {
        case .week: "Last 7 days"
        case .month: Cycle.label(thisMonth)
        case .year: "Last 12 months"
        }
    }

    func transactions(in interval: DateInterval) -> [MoneyTransaction] {
        approvedTransactions.filter { $0.date >= interval.start && $0.date < interval.end }
    }

    func income(in interval: DateInterval) -> Double {
        ordinaryIncomeTransactions.reduce(0) {
            ($1.date >= interval.start && $1.date < interval.end) ? $0 + $1.amount : $0
        }
    }

    func expenses(in interval: DateInterval) -> Double {
        spendingTransactions.reduce(0) {
            ($1.date >= interval.start && $1.date < interval.end) ? $0 + $1.amount : $0
        }
    }

    func spent(_ category: SpendCategory, in interval: DateInterval) -> Double {
        spendingTransactions.reduce(0) {
            ($1.date >= interval.start && $1.date < interval.end && $1.categoryRaw == category.rawValue) ? $0 + $1.amount : $0
        }
    }

    func spent(for budget: Budget, in interval: DateInterval) -> Double {
        let keys = Set(budget.categories.map(\.rawValue))
        return spendingTransactions.reduce(0) {
            ($1.date >= interval.start && $1.date < interval.end && keys.contains($1.categoryRaw)) ? $0 + $1.amount : $0
        }
    }

    var monthIncome: Double { income(in: thisMonth) }
    var monthExpenses: Double { expenses(in: thisMonth) }
    var monthNet: Double { monthIncome - monthExpenses }

    var daysLeftInMonth: Int {
        let today = cal.startOfDay(for: now)
        let days = cal.dateComponents([.day], from: today, to: thisMonth.end).day ?? 1
        return max(1, days)
    }

    var daysElapsed: Int {
        max(1, (cal.dateComponents([.day], from: thisMonth.start, to: now).day ?? 0) + 1)
    }

    // MARK: Budgets

    var totalBudget: Double { budgets.reduce(0) { $0 + $1.limit } }

    func budgetSpent(in interval: DateInterval) -> Double {
        let keys = Set(budgets.flatMap(\.categories).map(\.rawValue))
        return spendingTransactions.reduce(0) {
            ($1.date >= interval.start && $1.date < interval.end && keys.contains($1.categoryRaw)) ? $0 + $1.amount : $0
        }
    }

    var budgetLeft: Double { totalBudget - budgetSpent(in: thisMonth) }
    var budgetUsed: Double { totalBudget > 0 ? budgetSpent(in: thisMonth) / totalBudget : 0 }

    // MARK: Bills

    var upcomingBills: [Bill] {
        bills.filter { !$0.isPaidForCurrentCycle(now: now) }.sorted { $0.nextDueDate < $1.nextDueDate }
    }

    var billsDueRestOfMonth: Double {
        bills.filter { !$0.isPaidForCurrentCycle(now: now) && $0.nextDueDate < thisMonth.end }.reduce(0) { $0 + $1.amount }
    }

    var subscriptionsMonthly: Double { bills.filter(\.isSubscription).reduce(0) { $0 + $1.monthlyCost } }
    var billsMonthly: Double { bills.reduce(0) { $0 + $1.monthlyCost } }

    // MARK: Safe to spend

    var essentialsRemaining: Double {
        budgets.filter { $0.categories.contains(where: \.isEssential) }.reduce(0) { total, b in
            total + max(0, b.limit - spent(for: b, in: thisMonth))
        }
    }

    var savingsRemaining: Double { goals.reduce(0) { $0 + $1.remainingCommitment(now: now) } }

    var safeToSpend: SafeToSpend {
        SafeToSpend(spendable: totalAssets, billsDue: billsDueRestOfMonth, essentials: essentialsRemaining,
                    savings: savingsRemaining, liabilities: safeToSpendLiabilities, daysLeft: daysLeftInMonth)
    }

    // MARK: Forecast

    var avgDailyDiscretionary: Double {
        let spend = spendingTransactions.reduce(0) {
            ($1.date >= thisMonth.start && $1.date < thisMonth.end && $1.source != .bill) ? $0 + $1.amount : $0
        }
        return spend / Double(daysElapsed)
    }

    var projectedRemainingSpend: Double { avgDailyDiscretionary * Double(max(0, daysLeftInMonth - 1)) }
    var forecastEndOfMonth: Double { liquidBalance - billsDueRestOfMonth - projectedRemainingSpend }
    var projectedSavings: Double { monthIncome - monthExpenses - billsDueRestOfMonth - projectedRemainingSpend }

    /// Liquid balance per day this month, plus a dashed projection to month end.
    func balanceSeries() -> (actual: [ChartPoint], projected: [ChartPoint]) {
        let liquidIDs = Set(accounts.filter { $0.kind.isLiquid }.map(\.id))
        func liquidEffect(_ tx: MoneyTransaction) -> Double {
            if tx.smsTransactionType == .unknown { return 0 }
            if tx.smsTransactionType == .internalTransfer && tx.toAccountID == nil && tx.category != .visaTransfer { return 0 }
            var effect = 0.0
            if let id = tx.accountID { if liquidIDs.contains(id) { effect += tx.signedAmount } } else if !tx.isTransfer { effect += tx.signedAmount }
            if let to = tx.toAccountID, liquidIDs.contains(to) { effect += tx.amount }
            return effect
        }
        let today = cal.startOfDay(for: now)
        var days: [Date] = []
        var day = thisMonth.start
        while day <= today {
            days.append(day)
            guard let next = cal.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }

        // Group transaction effects by start-of-day in a single pass, then accumulate suffix totals.
        var effectByDay: [Date: Double] = [:]
        if let firstNext = days.first.flatMap({ cal.date(byAdding: .day, value: 1, to: $0) }) {
            for tx in approvedTransactions where tx.date >= firstNext && tx.date <= now {
                let dStart = cal.startOfDay(for: tx.date)
                effectByDay[dStart, default: 0] += liquidEffect(tx)
            }
        }
        var actual = Array(repeating: ChartPoint(date: today, value: liquidBalance), count: days.count)
        var runningAfter = 0.0
        for idx in stride(from: days.count - 1, through: 0, by: -1) {
            let d = days[idx]
            actual[idx] = ChartPoint(date: d, value: liquidBalance - runningAfter)
            runningAfter += effectByDay[d, default: 0]
        }

        var projected: [ChartPoint] = []
        if let last = actual.last {
            projected.append(last)
            let remainingDays = max(0, daysLeftInMonth - 1)
            let billsByDay = Dictionary(grouping: bills.filter { $0.nextDueDate < thisMonth.end }) {
                cal.startOfDay(for: $0.nextDueDate)
            }
            var running = last.value
            for i in stride(from: 1, through: remainingDays, by: 1) {
                guard let d = cal.date(byAdding: .day, value: i, to: today) else { continue }
                running -= avgDailyDiscretionary
                let dStart = cal.startOfDay(for: d)
                running -= (billsByDay[dStart] ?? []).reduce(0) { $0 + $1.amount }
                projected.append(ChartPoint(date: d, value: running))
            }
            // Overdue bills land on the last day.
            let overdue = bills.filter { $0.nextDueDate < today }.reduce(0) { $0 + $1.amount }
            if overdue > 0, let lastP = projected.popLast() {
                projected.append(ChartPoint(date: lastP.date, value: lastP.value - overdue))
            }
        }
        return (actual, projected)
    }

    // MARK: Charts

    func spendingSeries(_ range: ChartRange) -> [ChartPoint] {
        let today = cal.startOfDay(for: now)
        switch range {
        case .week:
            guard let start = cal.date(byAdding: .day, value: -6, to: today),
                  let end = cal.date(byAdding: .day, value: 1, to: today) else { return [] }
            var byDay: [Date: Double] = [:]
            for tx in spendingTransactions where tx.date >= start && tx.date < end {
                byDay[cal.startOfDay(for: tx.date), default: 0] += tx.amount
            }
            return (0..<7).reversed().compactMap { offset in
                guard let d = cal.date(byAdding: .day, value: -offset, to: today) else { return nil }
                return ChartPoint(date: d, value: byDay[d, default: 0])
            }
        case .month:
            guard let end = cal.date(byAdding: .day, value: 1, to: today) else { return [] }
            var byDay: [Date: Double] = [:]
            for tx in spendingTransactions where tx.date >= thisMonth.start && tx.date < end {
                byDay[cal.startOfDay(for: tx.date), default: 0] += tx.amount
            }
            var points: [ChartPoint] = []
            var d = thisMonth.start
            while d <= today {
                guard let e = cal.date(byAdding: .day, value: 1, to: d) else { break }
                points.append(ChartPoint(date: d, value: byDay[d, default: 0]))
                d = e
            }
            return points
        case .year:
            let intervals: [DateInterval] = (0..<12).reversed().compactMap { offset in
                guard let m = cal.date(byAdding: .month, value: -offset, to: now) else { return nil }
                return monthInterval(m)
            }
            guard let minStart = intervals.first?.start, let maxEnd = intervals.last?.end else { return [] }
            var bucketTotals = Array(repeating: 0.0, count: intervals.count)
            for tx in spendingTransactions where tx.date >= minStart && tx.date < maxEnd {
                for idx in intervals.indices where tx.date >= intervals[idx].start && tx.date < intervals[idx].end {
                    bucketTotals[idx] += tx.amount
                    break
                }
            }
            return intervals.indices.map { idx in
                ChartPoint(date: intervals[idx].start, value: bucketTotals[idx])
            }
        }
    }

    func spendingTotal(_ range: ChartRange) -> Double {
        spendingSeries(range).reduce(0) { $0 + $1.value }
    }

    func spent(_ range: ChartRange) -> Double {
        expenses(in: rangeInterval(range))
    }

    func categoryBreakdown(in interval: DateInterval) -> [(category: SpendCategory, amount: Double)] {
        var totals: [SpendCategory: Double] = [:]
        for tx in spendingTransactions where tx.date >= interval.start && tx.date < interval.end {
            totals[tx.category, default: 0] += tx.amount
        }
        return totals.map { ($0.key, $0.value) }.sorted { $0.1 > $1.1 }
    }

    func categoryBreakdown(_ range: ChartRange) -> [(category: SpendCategory, amount: Double)] {
        categoryBreakdown(in: rangeInterval(range))
    }

    func monthlyTotals(months: Int = 6) -> [MonthTotal] {
        let intervals: [DateInterval] = (0..<months).reversed().compactMap { offset in
            guard let m = cal.date(byAdding: .month, value: -offset, to: now) else { return nil }
            return monthInterval(m)
        }
        guard let minStart = intervals.first?.start, let maxEnd = intervals.last?.end else { return [] }
        var incomes = Array(repeating: 0.0, count: intervals.count)
        var expenses = Array(repeating: 0.0, count: intervals.count)
        for tx in ordinaryIncomeTransactions where tx.date >= minStart && tx.date < maxEnd {
            for idx in intervals.indices where tx.date >= intervals[idx].start && tx.date < intervals[idx].end {
                incomes[idx] += tx.amount
                break
            }
        }
        for tx in spendingTransactions where tx.date >= minStart && tx.date < maxEnd {
            for idx in intervals.indices where tx.date >= intervals[idx].start && tx.date < intervals[idx].end {
                expenses[idx] += tx.amount
                break
            }
        }
        return intervals.indices.map { idx in
            MonthTotal(month: intervals[idx].start, income: incomes[idx], expenses: expenses[idx])
        }
    }

    // MARK: Recurring detection

    static func merchantKey(_ name: String) -> String {
        let lowered = name.lowercased()
        let letters = lowered.unicodeScalars.map { CharacterSet.letters.contains($0) || $0 == " " ? Character($0) : " " }
        let words = String(letters).split(separator: " ").prefix(2)
        return words.joined(separator: " ")
    }

    func recurringCandidates() -> [RecurringCandidate] {
        guard let start = cal.date(byAdding: .day, value: -150, to: now) else { return [] }
        let recent = spendingTransactions.filter { $0.date >= start && $0.source != .bill }
        let groups = Dictionary(grouping: recent) { Finance.merchantKey($0.merchant) }
        let billKeys = Set(bills.map { Finance.merchantKey($0.name) })
        var results: [RecurringCandidate] = []
        for (key, txs) in groups where !key.isEmpty && txs.count >= 2 && !billKeys.contains(key) {
            let sorted = txs.sorted { $0.date < $1.date }
            let months = Set(sorted.map { DateKeys.month($0.date) })
            guard months.count >= 2, months.count >= sorted.count - 1 else { continue }
            let amounts = sorted.map(\.amount)
            let avg = amounts.reduce(0, +) / Double(amounts.count)
            guard avg > 0, amounts.allSatisfy({ abs($0 - avg) / avg < 0.15 }) else { continue }
            var gaps: [Int] = []
            for i in 1..<sorted.count {
                gaps.append(cal.dateComponents([.day], from: sorted[i - 1].date, to: sorted[i].date).day ?? 0)
            }
            guard gaps.allSatisfy({ (24...38).contains($0) }) else { continue }
            if let last = sorted.last {
                results.append(RecurringCandidate(key: key, name: last.merchant, amount: avg, lastDate: last.date,
                                                  category: last.category, occurrences: sorted.count))
            }
        }
        return results.sorted { $0.amount > $1.amount }
    }
}
