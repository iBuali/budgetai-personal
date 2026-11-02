import Foundation

// MARK: - Financial Time Machine
//
// Deterministic future-simulation engine. It only READS the user's accounts,
// transactions and bills; it never writes to the model context, so real
// transactions and balances are never modified. No AI is involved in any
// calculation.

enum SimulationScenario: String, CaseIterable, Identifiable, Codable {
    case conservative, expected, optimistic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .conservative: "Conservative"
        case .expected: "Expected"
        case .optimistic: "Optimistic"
        }
    }

    var symbol: String {
        switch self {
        case .conservative: "tortoise.fill"
        case .expected: "scope"
        case .optimistic: "sparkles"
        }
    }
}

/// A future one-time income or expense entered by the user (simulation only).
struct OneTimeEvent: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var title: String
    var amount: Double
    var date: Date
    var isIncome: Bool
}

/// User-editable simulation assumptions. Persisted separately from real data.
struct SimulationAssumptions: Codable, Equatable {
    // Income
    var salaryChangePercent: Double = 0
    var salaryChangeAmount: Double = 0
    var additionalMonthlyIncome: Double = 0
    // Expenses
    var expenseChangePercent: Double = 0
    var expenseChangeAmount: Double = 0
    var categoryChangePercent: [String: Double] = [:]
    var includeCommitments: Bool = true
    // Savings
    var additionalMonthlySavings: Double = 0
    var targetBalance: Double = 0
    // One-time future events
    var events: [OneTimeEvent] = []
    // Scenario tuning (shown to the user, never applied silently)
    var conservativeExpenseBuffer: Double = 10
    var conservativeExtraIncomeShare: Double = 50
    var optimisticDiscretionaryCut: Double = 10
    var optimisticExtraIncomeShare: Double = 100

    init() {}

    enum CodingKeys: String, CodingKey {
        case salaryChangePercent, salaryChangeAmount, additionalMonthlyIncome
        case expenseChangePercent, expenseChangeAmount, categoryChangePercent, includeCommitments
        case additionalMonthlySavings, targetBalance, events
        case conservativeExpenseBuffer, conservativeExtraIncomeShare, optimisticDiscretionaryCut, optimisticExtraIncomeShare
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        salaryChangePercent = try c.decodeIfPresent(Double.self, forKey: .salaryChangePercent) ?? 0
        salaryChangeAmount = try c.decodeIfPresent(Double.self, forKey: .salaryChangeAmount) ?? 0
        additionalMonthlyIncome = try c.decodeIfPresent(Double.self, forKey: .additionalMonthlyIncome) ?? 0
        expenseChangePercent = try c.decodeIfPresent(Double.self, forKey: .expenseChangePercent) ?? 0
        expenseChangeAmount = try c.decodeIfPresent(Double.self, forKey: .expenseChangeAmount) ?? 0
        categoryChangePercent = try c.decodeIfPresent([String: Double].self, forKey: .categoryChangePercent) ?? [:]
        includeCommitments = try c.decodeIfPresent(Bool.self, forKey: .includeCommitments) ?? true
        additionalMonthlySavings = try c.decodeIfPresent(Double.self, forKey: .additionalMonthlySavings) ?? 0
        targetBalance = try c.decodeIfPresent(Double.self, forKey: .targetBalance) ?? 0
        events = try c.decodeIfPresent([OneTimeEvent].self, forKey: .events) ?? []
        conservativeExpenseBuffer = try c.decodeIfPresent(Double.self, forKey: .conservativeExpenseBuffer) ?? 10
        conservativeExtraIncomeShare = try c.decodeIfPresent(Double.self, forKey: .conservativeExtraIncomeShare) ?? 50
        optimisticDiscretionaryCut = try c.decodeIfPresent(Double.self, forKey: .optimisticDiscretionaryCut) ?? 10
        optimisticExtraIncomeShare = try c.decodeIfPresent(Double.self, forKey: .optimisticExtraIncomeShare) ?? 100
    }

    /// True when any what-if adjustment differs from the plain baseline.
    var hasAdjustments: Bool {
        salaryChangePercent != 0 || salaryChangeAmount != 0 || additionalMonthlyIncome != 0
            || expenseChangePercent != 0 || expenseChangeAmount != 0
            || categoryChangePercent.values.contains(where: { $0 != 0 })
            || !includeCommitments || additionalMonthlySavings != 0 || !events.isEmpty
    }
}

// MARK: - Baseline (derived from real data)

struct ScheduledCommitment: Identifiable {
    let id: UUID
    let name: String
    let amount: Double
    let nextDueDate: Date
    let frequency: BillFrequency
    let isSubscription: Bool
}

struct CategoryBaseline: Identifiable {
    var id: String { category.rawValue }
    let category: SpendCategory
    let monthly: Double
}

struct RecurringIncomeSource: Identifiable {
    var id: String { name }
    let name: String
    let monthly: Double
    let day: Int
}

struct FinancialBaseline {
    var startingBalance: Double
    var recurringIncome: Double
    var recurringIncomeDay: Int
    var recurringSources: [RecurringIncomeSource]
    var otherIncome: Double
    var categories: [CategoryBaseline]
    var refundsMonthly: Double
    var commitments: [ScheduledCommitment]
    var historyDays: Int
    var isDemo: Bool

    var grossSpending: Double { categories.reduce(0) { $0 + $1.monthly } }
    var variableSpending: Double { max(0, grossSpending - refundsMonthly) }
    var commitmentsMonthly: Double { commitments.reduce(0) { $0 + $1.amount * $1.frequency.monthlyFactor } }
    var monthlyIncome: Double { recurringIncome + otherIncome }
}

// MARK: - Results

struct ProjectionPoint: Identifiable {
    var id: Date { date }
    let date: Date
    let balance: Double
}

struct MonthProjection: Identifiable {
    let id: Int
    let month: Date
    var income: Double = 0
    var expenses: Double = 0
    var commitments: Double = 0
    var endBalance: Double = 0
    var net: Double { income - expenses - commitments }
}

/// Effective monthly figures used by one scenario (shown to the user).
struct ScenarioInputs {
    let salary: Double
    let otherIncome: Double
    let extraIncome: Double
    let essentialSpending: Double
    let discretionarySpending: Double
    let variableSpending: Double
    let savingsFunded: Double
    let incomeEventShare: Double
    let includeCommitments: Bool
}

struct SimulationResult {
    let scenario: SimulationScenario
    let days: Int
    let inputs: ScenarioInputs
    let startBalance: Double
    let endBalance: Double
    let totalIncome: Double
    let variableExpenses: Double
    let commitmentsTotal: Double
    let oneTimeExpenses: Double
    let setAside: Double
    let lowestBalance: Double
    let lowestDate: Date
    let targetReachedDate: Date?
    let points: [ProjectionPoint]
    let months: [MonthProjection]

    var totalExpenses: Double { variableExpenses + commitmentsTotal + oneTimeExpenses }
    /// Net change of the balance over the period (income − all expenses).
    var estimatedSavings: Double { endBalance - startBalance }
    var coversCommitments: Bool { lowestBalance >= 0 }
}

// MARK: - Engine

enum TimeMachineEngine {
    static let daysPerMonth = 30.4375
    static let periods = [30, 90, 180, 365]

    // MARK: Baseline

    static func baseline(from f: Finance, now: Date = .now) -> FinancialBaseline {
        if f.transactions.isEmpty && f.accounts.isEmpty { return demoBaseline(now: now) }

        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        let txs = f.transactions // already excludes pending/unapproved SMS
        let earliest = txs.map(\.date).min() ?? today
        let available = max(1, cal.dateComponents([.day], from: cal.startOfDay(for: earliest), to: today).day ?? 1)
        let lookback = min(90, max(30, available))
        let windowStart = cal.date(byAdding: .day, value: -lookback, to: today) ?? today
        let months = Double(lookback) / daysPerMonth
        let window = txs.filter { $0.date >= windowStart && $0.date <= now }

        // Income: ordinary income only (transfers, internal moves and refunds are excluded).
        let incomeTx = window.filter(\.isOrdinaryIncome)
        let totalIncome = incomeTx.reduce(0) { $0 + $1.amount }
        let groups = Dictionary(grouping: incomeTx) { Finance.merchantKey($0.merchant) }
        var sources: [RecurringIncomeSource] = []
        var recurringInWindow = 0.0
        for (key, items) in groups where !key.isEmpty {
            let monthsSeen = Set(items.map { tx -> Int in
                let c = cal.dateComponents([.year, .month], from: tx.date)
                return (c.year ?? 0) * 12 + (c.month ?? 0)
            })
            guard monthsSeen.count >= 2 else { continue }
            let sum = items.reduce(0) { $0 + $1.amount }
            let avg = sum / Double(items.count)
            let perMonth = Double(items.count) / Double(monthsSeen.count)
            guard let last = items.max(by: { $0.date < $1.date }) else { continue }
            recurringInWindow += sum
            sources.append(RecurringIncomeSource(name: last.merchant, monthly: avg * perMonth,
                                                 day: cal.component(.day, from: last.date)))
        }
        sources.sort { $0.monthly > $1.monthly }
        let recurring = sources.reduce(0) { $0 + $1.monthly }
        let other = max(0, totalIncome - recurringInWindow) / months

        // Spending baseline: real spending only. Bills are scheduled separately,
        // so payments already linked to a bill are excluded to avoid double counting.
        let billTxIDs = Set(f.bills.compactMap(\.lastPaidTxID))
        let billKeys = Set(f.bills.map { Finance.merchantKey($0.name) }).subtracting([""])
        var byCategory: [SpendCategory: Double] = [:]
        for tx in window where tx.isSpending && tx.source != .bill && !billTxIDs.contains(tx.id) {
            if billKeys.contains(Finance.merchantKey(tx.merchant)) { continue }
            byCategory[tx.category, default: 0] += tx.amount
        }
        let categories = byCategory
            .map { CategoryBaseline(category: $0.key, monthly: $0.value / months) }
            .sorted { $0.monthly > $1.monthly }
        let refunds = window
            .filter { $0.smsTransactionType == .refund && !$0.isTransfer }
            .reduce(0) { $0 + $1.amount } / months

        let commitments = f.bills.map {
            ScheduledCommitment(id: $0.id, name: $0.name, amount: $0.amount, nextDueDate: $0.nextDueDate,
                                frequency: $0.frequency, isSubscription: $0.isSubscription)
        }

        return FinancialBaseline(startingBalance: f.liquidBalance,
                                 recurringIncome: recurring,
                                 recurringIncomeDay: sources.first?.day ?? 1,
                                 recurringSources: sources,
                                 otherIncome: other,
                                 categories: categories,
                                 refundsMonthly: refunds,
                                 commitments: commitments,
                                 historyDays: lookback,
                                 isDemo: false)
    }

    /// Clearly-labelled sample data used only when the user has no accounts or transactions.
    static func demoBaseline(now: Date = .now) -> FinancialBaseline {
        let cal = Calendar.current
        func inDays(_ d: Int) -> Date { cal.date(byAdding: .day, value: d, to: now) ?? now }
        return FinancialBaseline(
            startingBalance: 2500,
            recurringIncome: 1200,
            recurringIncomeDay: 25,
            recurringSources: [RecurringIncomeSource(name: "Salary (demo)", monthly: 1200, day: 25)],
            otherIncome: 50,
            categories: [
                CategoryBaseline(category: .groceries, monthly: 180),
                CategoryBaseline(category: .dining, monthly: 120),
                CategoryBaseline(category: .shopping, monthly: 90),
                CategoryBaseline(category: .transport, monthly: 60),
                CategoryBaseline(category: .entertainment, monthly: 40),
            ],
            refundsMonthly: 0,
            commitments: [
                ScheduledCommitment(id: UUID(), name: "Rent (demo)", amount: 350, nextDueDate: inDays(5), frequency: .monthly, isSubscription: false),
                ScheduledCommitment(id: UUID(), name: "Phone (demo)", amount: 15, nextDueDate: inDays(12), frequency: .monthly, isSubscription: false),
                ScheduledCommitment(id: UUID(), name: "Streaming (demo)", amount: 4, nextDueDate: inDays(20), frequency: .monthly, isSubscription: true),
            ],
            historyDays: 90,
            isDemo: true)
    }

    // MARK: Scenario inputs

    static func inputs(_ b: FinancialBaseline, _ a: SimulationAssumptions, scenario: SimulationScenario) -> ScenarioInputs {
        func adjustIncome(_ v: Double) -> Double {
            max(0, v * (1 + a.salaryChangePercent / 100) + a.salaryChangeAmount)
        }
        // Salary adjustments apply to detected recurring income; if none was found, to total income.
        let salary = b.recurringIncome > 0 ? adjustIncome(b.recurringIncome) : 0
        let other = b.recurringIncome > 0 ? b.otherIncome : adjustIncome(b.otherIncome)

        let extraShare: Double
        switch scenario {
        case .conservative: extraShare = a.conservativeExtraIncomeShare / 100
        case .expected: extraShare = 1
        case .optimistic: extraShare = a.optimisticExtraIncomeShare / 100
        }
        let extra = max(0, a.additionalMonthlyIncome) * max(0, extraShare)

        var essential = 0.0
        var discretionary = 0.0
        for c in b.categories {
            let pct = a.categoryChangePercent[c.category.rawValue] ?? 0
            let v = max(0, c.monthly * (1 + pct / 100))
            if c.category.isEssential { essential += v } else { discretionary += v }
        }
        if scenario == .optimistic {
            discretionary *= max(0, 1 - a.optimisticDiscretionaryCut / 100)
        }
        var variable = (essential + discretionary) * (1 + a.expenseChangePercent / 100) + a.expenseChangeAmount - b.refundsMonthly
        if scenario == .conservative {
            variable *= 1 + a.conservativeExpenseBuffer / 100
        }
        variable = max(0, variable)
        // Extra savings are funded by spending less, so they are never counted twice.
        let saved = min(max(0, a.additionalMonthlySavings), variable)
        variable -= saved

        return ScenarioInputs(salary: salary, otherIncome: other, extraIncome: extra,
                              essentialSpending: essential, discretionarySpending: discretionary,
                              variableSpending: variable, savingsFunded: saved,
                              incomeEventShare: max(0, extraShare), includeCommitments: a.includeCommitments)
    }

    // MARK: Simulation

    static func simulate(_ b: FinancialBaseline, _ a: SimulationAssumptions, scenario: SimulationScenario,
                         days: Int, now: Date = .now) -> SimulationResult {
        let cal = Calendar.current
        let horizon = max(1, days)
        let start = cal.startOfDay(for: now)
        let end = cal.date(byAdding: .day, value: horizon, to: start) ?? start
        let inp = inputs(b, a, scenario: scenario)

        func index(of date: Date) -> Int {
            cal.dateComponents([.day], from: start, to: cal.startOfDay(for: date)).day ?? 0
        }

        // Scheduled bills, subscriptions and installments.
        var scheduled: [Int: Double] = [:]
        if inp.includeCommitments {
            for c in b.commitments where c.amount > 0 {
                var due = cal.startOfDay(for: c.nextDueDate)
                if due < start {
                    // Overdue: counted once, right away.
                    scheduled[1, default: 0] += c.amount
                    var guardCount = 0
                    while due < start && guardCount < 600 {
                        due = cal.startOfDay(for: c.frequency.next(after: due)); guardCount += 1
                    }
                    if cal.isDate(due, inSameDayAs: start) { due = cal.startOfDay(for: c.frequency.next(after: due)) }
                }
                var guardCount = 0
                while due <= end && guardCount < 600 {
                    let idx = max(1, index(of: due))
                    if idx <= horizon { scheduled[idx, default: 0] += c.amount }
                    due = cal.startOfDay(for: c.frequency.next(after: due))
                    guardCount += 1
                }
            }
        }

        // One-time future events.
        var eventIncome: [Int: Double] = [:]
        var eventExpense: [Int: Double] = [:]
        for e in a.events where e.amount > 0 {
            let idx = index(of: e.date)
            guard idx >= 0, idx <= horizon else { continue }
            let day = max(1, idx)
            if e.isIncome {
                eventIncome[day, default: 0] += e.amount * inp.incomeEventShare
            } else {
                eventExpense[day, default: 0] += e.amount
            }
        }

        let dailyIncome = (inp.otherIncome + inp.extraIncome) / daysPerMonth
        let dailySpend = inp.variableSpending / daysPerMonth
        let payday = max(1, b.recurringIncomeDay)

        var balance = b.startingBalance
        var points = [ProjectionPoint(date: start, balance: balance)]
        var monthMap: [Int: MonthProjection] = [:]
        var order: [Int] = []
        var totalIncome = 0.0, totalVariable = 0.0, totalCommit = 0.0, totalOneTime = 0.0
        var lowest = balance
        var lowestDate = start
        var reached: Date? = (a.targetBalance > 0 && balance >= a.targetBalance) ? start : nil

        for i in 1...horizon {
            guard let d = cal.date(byAdding: .day, value: i, to: start) else { continue }
            var income = dailyIncome + (eventIncome[i] ?? 0)
            if inp.salary > 0 {
                let daysInMonth = cal.range(of: .day, in: .month, for: d)?.count ?? 30
                if cal.component(.day, from: d) == min(payday, daysInMonth) { income += inp.salary }
            }
            let oneTime = eventExpense[i] ?? 0
            let commit = scheduled[i] ?? 0
            balance += income - dailySpend - oneTime - commit

            totalIncome += income
            totalVariable += dailySpend
            totalOneTime += oneTime
            totalCommit += commit
            if balance < lowest { lowest = balance; lowestDate = d }
            if reached == nil, a.targetBalance > 0, balance >= a.targetBalance { reached = d }
            points.append(ProjectionPoint(date: d, balance: balance))

            let comps = cal.dateComponents([.year, .month], from: d)
            let key = (comps.year ?? 0) * 12 + (comps.month ?? 0)
            if monthMap[key] == nil {
                monthMap[key] = MonthProjection(id: key, month: cal.date(from: comps) ?? d)
                order.append(key)
            }
            monthMap[key]?.income += income
            monthMap[key]?.expenses += dailySpend + oneTime
            monthMap[key]?.commitments += commit
            monthMap[key]?.endBalance = balance
        }

        return SimulationResult(scenario: scenario, days: horizon, inputs: inp,
                                startBalance: b.startingBalance, endBalance: balance,
                                totalIncome: totalIncome, variableExpenses: totalVariable,
                                commitmentsTotal: totalCommit, oneTimeExpenses: totalOneTime,
                                setAside: inp.savingsFunded / daysPerMonth * Double(horizon),
                                lowestBalance: lowest, lowestDate: lowestDate, targetReachedDate: reached,
                                points: points, months: order.compactMap { monthMap[$0] })
    }

    // MARK: Actual history

    /// Actual liquid (cash + bank) balance for the last `days` days, rebuilt from real transactions.
    static func actualHistory(_ f: Finance, days: Int = 30, now: Date = .now) -> [ProjectionPoint] {
        let cal = Calendar.current
        let liquidIDs = Set(f.accounts.filter { $0.kind.isLiquid }.map(\.id))
        func effect(_ tx: MoneyTransaction) -> Double {
            if tx.smsTransactionType == .unknown { return 0 }
            if tx.smsTransactionType == .internalTransfer && tx.toAccountID == nil && tx.category != .visaTransfer { return 0 }
            var value = 0.0
            if let id = tx.accountID {
                if liquidIDs.contains(id) { value += tx.signedAmount }
            } else if !tx.isTransfer {
                value += tx.signedAmount
            }
            if let to = tx.toAccountID, liquidIDs.contains(to) { value += tx.amount }
            return value
        }
        let today = cal.startOfDay(for: now)
        let from = cal.date(byAdding: .day, value: -days, to: today) ?? today
        let recent = f.transactions.filter { $0.date >= from && $0.date <= now }
        var out: [ProjectionPoint] = []
        for offset in stride(from: days, through: 0, by: -1) {
            guard let day = cal.date(byAdding: .day, value: -offset, to: today),
                  let next = cal.date(byAdding: .day, value: 1, to: day) else { continue }
            let after = recent.filter { $0.date >= next }.reduce(0) { $0 + effect($1) }
            out.append(ProjectionPoint(date: day, balance: f.liquidBalance - after))
        }
        return out
    }

    // MARK: Transparency

    /// Human-readable list of every assumption used by a scenario.
    static func assumptionLines(_ b: FinancialBaseline, _ a: SimulationAssumptions,
                                scenario: SimulationScenario, currency: String) -> [String] {
        let inp = inputs(b, a, scenario: scenario)
        func m(_ v: Double) -> String { Money.format(v, currency) }
        var lines: [String] = []
        switch scenario {
        case .conservative:
            lines.append("Spending \(pct(a.conservativeExpenseBuffer)) higher than usual as a safety buffer")
            lines.append("Additional & one-time income counted at \(Int(a.conservativeExtraIncomeShare))%")
        case .expected:
            lines.append("Your current income and spending patterns, plus your adjustments")
        case .optimistic:
            lines.append("Non-essential spending \(pct(-a.optimisticDiscretionaryCut)) lower")
            lines.append("Additional & one-time income counted at \(Int(a.optimisticExtraIncomeShare))%")
        }
        if inp.salary > 0 { lines.append("Regular income \(m(inp.salary))/mo on day \(b.recurringIncomeDay)") }
        if inp.otherIncome > 0 { lines.append("Other income \(m(inp.otherIncome))/mo (average)") }
        if inp.extraIncome > 0 { lines.append("Additional income \(m(inp.extraIncome))/mo") }
        lines.append("Day-to-day spending \(m(inp.variableSpending))/mo (from last \(b.historyDays) days)")
        if inp.includeCommitments {
            lines.append("Bills & subscriptions \(m(b.commitmentsMonthly))/mo on their due dates")
        } else {
            lines.append("Bills & subscriptions not included")
        }
        if inp.savingsFunded > 0 { lines.append("Extra savings \(m(inp.savingsFunded))/mo by spending less") }
        if !a.events.isEmpty { lines.append("\(a.events.count) one-time event\(a.events.count == 1 ? "" : "s")") }
        return lines
    }

    static func pct(_ v: Double) -> String {
        let n = Int(v.rounded())
        return n > 0 ? "+\(n)%" : "\(n)%"
    }
}
