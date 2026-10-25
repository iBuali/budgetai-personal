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
    let daysLeft: Int

    var monthly: Double { max(0, spendable - billsDue - essentials - savings) }
    var daily: Double { daysLeft > 0 ? monthly / Double(daysLeft) : monthly }
    var isShort: Bool { spendable - billsDue - essentials - savings < 0 }
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

/// Pure calculations over the user's data. Cheap to rebuild on every render.
struct Finance {
    let transactions: [MoneyTransaction]
    let accounts: [Account]
    let budgets: [Budget]
    let goals: [SavingsGoal]
    let bills: [Bill]
    let now: Date
    let cal = Calendar.current

    init(transactions: [MoneyTransaction], accounts: [Account], budgets: [Budget] = [],
         goals: [SavingsGoal] = [], bills: [Bill] = [], now: Date = .now) {
        self.transactions = transactions
        self.accounts = accounts
        self.budgets = budgets
        self.goals = goals
        self.bills = bills
        self.now = now
    }

    // MARK: Balances

    var liquidBalance: Double { accounts.filter { $0.kind.isLiquid }.reduce(0) { $0 + $1.balance } }
    var totalAssets: Double { accounts.filter { !$0.kind.isLiability }.reduce(0) { $0 + $1.balance } }
    var totalLiabilities: Double { accounts.filter { $0.kind.isLiability }.reduce(0) { $0 + $1.balance } }
    var netWorth: Double { totalAssets - totalLiabilities }

    // MARK: Periods

    func monthInterval(_ date: Date) -> DateInterval {
        cal.dateInterval(of: .month, for: date) ?? DateInterval(start: date, duration: 86_400 * 30)
    }

    var thisMonth: DateInterval { monthInterval(now) }
    var lastMonth: DateInterval {
        monthInterval(cal.date(byAdding: .month, value: -1, to: now) ?? now)
    }

    func transactions(in interval: DateInterval) -> [MoneyTransaction] {
        transactions.filter { $0.date >= interval.start && $0.date < interval.end }
    }

    func income(in interval: DateInterval) -> Double {
        transactions(in: interval).filter { $0.isIncome && $0.category != .transfers }.reduce(0) { $0 + $1.amount }
    }

    func expenses(in interval: DateInterval) -> Double {
        transactions(in: interval).filter(\.isSpending).reduce(0) { $0 + $1.amount }
    }

    func spent(_ category: SpendCategory, in interval: DateInterval) -> Double {
        transactions(in: interval).filter { $0.isSpending && $0.category == category }.reduce(0) { $0 + $1.amount }
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
        let cats = Set(budgets.map(\.category))
        return transactions(in: interval).filter { $0.isSpending && cats.contains($0.category) }.reduce(0) { $0 + $1.amount }
    }

    var budgetLeft: Double { totalBudget - budgetSpent(in: thisMonth) }
    var budgetUsed: Double { totalBudget > 0 ? budgetSpent(in: thisMonth) / totalBudget : 0 }

    // MARK: Bills

    var upcomingBills: [Bill] { bills.sorted { $0.nextDueDate < $1.nextDueDate } }

    var billsDueRestOfMonth: Double {
        bills.filter { $0.nextDueDate < thisMonth.end }.reduce(0) { $0 + $1.amount }
    }

    var subscriptionsMonthly: Double { bills.filter(\.isSubscription).reduce(0) { $0 + $1.monthlyCost } }
    var billsMonthly: Double { bills.reduce(0) { $0 + $1.monthlyCost } }

    // MARK: Safe to spend

    var essentialsRemaining: Double {
        budgets.filter { $0.category.isEssential }.reduce(0) { total, b in
            total + max(0, b.limit - spent(b.category, in: thisMonth))
        }
    }

    var savingsRemaining: Double { goals.reduce(0) { $0 + $1.remainingCommitment(now: now) } }

    var safeToSpend: SafeToSpend {
        SafeToSpend(spendable: liquidBalance, billsDue: billsDueRestOfMonth, essentials: essentialsRemaining,
                    savings: savingsRemaining, daysLeft: daysLeftInMonth)
    }

    // MARK: Forecast

    var avgDailyDiscretionary: Double {
        let spend = transactions(in: thisMonth).filter { $0.isSpending && $0.source != .bill }.reduce(0) { $0 + $1.amount }
        return spend / Double(daysElapsed)
    }

    var projectedRemainingSpend: Double { avgDailyDiscretionary * Double(max(0, daysLeftInMonth - 1)) }
    var forecastEndOfMonth: Double { liquidBalance - billsDueRestOfMonth - projectedRemainingSpend }
    var projectedSavings: Double { monthIncome - monthExpenses - billsDueRestOfMonth - projectedRemainingSpend }

    /// Liquid balance per day this month, plus a dashed projection to month end.
    func balanceSeries() -> (actual: [ChartPoint], projected: [ChartPoint]) {
        let liquidIDs = Set(accounts.filter { $0.kind.isLiquid }.map(\.id))
        let relevant = transactions.filter { tx in
            guard let id = tx.accountID else { return true }
            return liquidIDs.contains(id)
        }
        let today = cal.startOfDay(for: now)
        var actual: [ChartPoint] = []
        var day = thisMonth.start
        while day <= today {
            guard let next = cal.date(byAdding: .day, value: 1, to: day) else { break }
            let after = relevant.filter { $0.date >= next && $0.date <= now }.reduce(0) { $0 + $1.signedAmount }
            actual.append(ChartPoint(date: day, value: liquidBalance - after))
            day = next
        }
        var projected: [ChartPoint] = []
        if let last = actual.last {
            projected.append(last)
            let remainingDays = max(0, daysLeftInMonth - 1)
            let billsByDay = bills.filter { $0.nextDueDate < thisMonth.end }
            var running = last.value
            for i in stride(from: 1, through: remainingDays, by: 1) {
                guard let d = cal.date(byAdding: .day, value: i, to: today) else { continue }
                running -= avgDailyDiscretionary
                running -= billsByDay.filter { cal.isDate($0.nextDueDate, inSameDayAs: d) }.reduce(0) { $0 + $1.amount }
                projected.append(ChartPoint(date: d, value: running))
            }
            // Overdue bills land on the last day.
            let overdue = billsByDay.filter { $0.nextDueDate < today }.reduce(0) { $0 + $1.amount }
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
            return (0..<7).reversed().compactMap { offset in
                guard let d = cal.date(byAdding: .day, value: -offset, to: today),
                      let e = cal.date(byAdding: .day, value: 1, to: d) else { return nil }
                return ChartPoint(date: d, value: expenses(in: DateInterval(start: d, end: e)))
            }
        case .month:
            var points: [ChartPoint] = []
            var d = thisMonth.start
            while d <= today {
                guard let e = cal.date(byAdding: .day, value: 1, to: d) else { break }
                points.append(ChartPoint(date: d, value: expenses(in: DateInterval(start: d, end: e))))
                d = e
            }
            return points
        case .year:
            return (0..<12).reversed().compactMap { offset in
                guard let m = cal.date(byAdding: .month, value: -offset, to: now) else { return nil }
                let interval = monthInterval(m)
                return ChartPoint(date: interval.start, value: expenses(in: interval))
            }
        }
    }

    func spendingTotal(_ range: ChartRange) -> Double {
        spendingSeries(range).reduce(0) { $0 + $1.value }
    }

    func categoryBreakdown(in interval: DateInterval) -> [(category: SpendCategory, amount: Double)] {
        var totals: [SpendCategory: Double] = [:]
        for tx in transactions(in: interval) where tx.isSpending {
            totals[tx.category, default: 0] += tx.amount
        }
        return totals.map { ($0.key, $0.value) }.sorted { $0.1 > $1.1 }
    }

    func monthlyTotals(months: Int = 6) -> [MonthTotal] {
        (0..<months).reversed().compactMap { offset in
            guard let m = cal.date(byAdding: .month, value: -offset, to: now) else { return nil }
            let interval = monthInterval(m)
            return MonthTotal(month: interval.start, income: income(in: interval), expenses: expenses(in: interval))
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
        let recent = transactions.filter { $0.isSpending && $0.date >= start && $0.source != .bill }
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
