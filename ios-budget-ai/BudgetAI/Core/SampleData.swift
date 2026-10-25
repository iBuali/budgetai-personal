import Foundation
import SwiftData

/// Optional demo data so people can explore every screen before adding their own.
enum SampleData {
    private struct Rng {
        var state: UInt64
        mutating func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double((state >> 33) % 10_000) / 10_000
        }
    }

    static func load(into context: ModelContext) {
        Ledger.eraseAll(context: context)
        let cal = Calendar.current
        let now = Date()
        let today = cal.startOfDay(for: now)

        let nbb = Account(name: "NBB Current", kind: .bank, institution: "NBB", balance: 3286.750)
        let cash = Account(name: "Cash wallet", kind: .cash, balance: 120.000)
        let bbk = Account(name: "BBK Savings", kind: .bank, institution: "BBK", balance: 880.000)
        let stocks = Account(name: "Stock portfolio", kind: .investment, balance: 6500.000)
        let car = Account(name: "Toyota Camry", kind: .property, balance: 7800.000)
        let loan = Account(name: "Car loan", kind: .loan, institution: "NBB", balance: 4200.000)
        let card = Account(name: "Visa Platinum", kind: .creditCard, institution: "BBK", balance: 340.500)
        for a in [nbb, cash, bbk, stocks, car, loan, card] { context.insert(a) }

        var rng = Rng(state: 42)
        func at(_ day: Date, hour: Int) -> Date { cal.date(bySettingHour: hour, minute: Int(rng.next() * 59), second: 0, of: day) ?? day }
        func add(_ amount: Double, _ merchant: String, _ cat: SpendCategory, _ date: Date, income: Bool = false, source: TxSource = .sms, account: UUID? = nil) {
            let tx = MoneyTransaction(amount: (amount * 1000).rounded() / 1000, isIncome: income, merchant: merchant,
                                      category: cat, date: date, source: source, accountID: account ?? nbb.id)
            tx.aiCategorized = source == .sms
            context.insert(tx)
        }

        let pool: [(String, SpendCategory, ClosedRange<Double>, Double)] = [
            ("Talabat", .dining, 3.5...9.5, 0.45),
            ("Costa Coffee", .dining, 1.8...3.2, 0.35),
            ("Lulu Hypermarket", .groceries, 12...38, 0.22),
            ("Al Jazira Supermarket", .groceries, 6...22, 0.15),
            ("Careem", .transport, 2.2...5.8, 0.35),
            ("Bapco Fuel", .transport, 7...12, 0.12),
            ("Amazon", .shopping, 8...35, 0.08),
            ("Zara", .shopping, 18...45, 0.05),
            ("VOX Cinemas", .entertainment, 6...14, 0.05),
            ("Aster Pharmacy", .health, 3...12, 0.05),
        ]

        // Three months of history, ending today.
        guard let historyStart = cal.date(byAdding: .month, value: -3, to: cal.dateInterval(of: .month, for: now)?.start ?? today) else { return }
        var day = historyStart
        while day <= today {
            let dom = cal.component(.day, from: day)
            if dom == 1 { add(1850, "Salary · NBB", .income, at(day, hour: 8), income: true, source: .bank) }
            if dom == 5 { add(2.5, "Spotify", .subscriptions, at(day, hour: 10), account: card.id) }
            for (merchant, cat, range, chance) in pool where rng.next() < chance {
                let amount = range.lowerBound + rng.next() * (range.upperBound - range.lowerBound)
                add(amount, merchant, cat, at(day, hour: 9 + Int(rng.next() * 12)))
            }
            guard let next = cal.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }

        // Last month's bills as payments.
        if let lastMonth = cal.date(byAdding: .month, value: -1, to: today) {
            add(25, "Batelco Fiber", .bills, at(lastMonth, hour: 11), source: .bill)
            add(41.2, "EWA Electricity", .bills, at(lastMonth, hour: 11), source: .bill)
            add(4.4, "Netflix", .subscriptions, at(lastMonth, hour: 11), source: .bill, account: card.id)
        }

        // Today's activity, including a duplicate SMS.
        add(6.750, "Talabat", .dining, at(today, hour: 13))
        add(23.180, "Lulu Hypermarket", .groceries, at(today, hour: 11))
        let dup = MoneyTransaction(amount: 23.180, isIncome: false, merchant: "Lulu Hypermarket", category: .groceries,
                                   date: at(today, hour: 11), source: .bank, accountID: nbb.id)
        dup.isPossibleDuplicate = true
        context.insert(dup)

        func due(_ days: Int) -> Date { cal.date(byAdding: .day, value: days, to: today) ?? today }
        let bills: [Bill] = [
            Bill(name: "Batelco Fiber", amount: 25, category: .bills, nextDueDate: due(3)),
            Bill(name: "EWA Electricity", amount: 38.6, category: .bills, nextDueDate: due(6)),
            Bill(name: "Netflix", amount: 4.4, category: .subscriptions, nextDueDate: due(9), isSubscription: true),
            Bill(name: "Car loan installment", amount: 185, category: .housing, nextDueDate: due(12)),
            Bill(name: "iCloud+", amount: 1.2, category: .subscriptions, nextDueDate: due(15), isSubscription: true),
            Bill(name: "Fitness First", amount: 30, category: .health, nextDueDate: due(20), isSubscription: true),
        ]
        for b in bills { context.insert(b) }

        let budgets: [(SpendCategory, Double)] = [(.groceries, 220), (.dining, 100), (.transport, 120), (.shopping, 250), (.bills, 120), (.entertainment, 60)]
        for (c, l) in budgets { context.insert(Budget(category: c, limit: l)) }

        context.insert(SavingsGoal(name: "Emergency fund", symbol: "shield.lefthalf.filled", target: 5000, saved: 2400,
                                   targetDate: cal.date(byAdding: .month, value: 8, to: today) ?? today, monthlyCommitment: 150))
        context.insert(SavingsGoal(name: "Umrah trip", symbol: "airplane", target: 1200, saved: 650,
                                   targetDate: cal.date(byAdding: .month, value: 5, to: today) ?? today, monthlyCommitment: 100))

        // A year of net worth history.
        let assets = [nbb, cash, bbk, stocks, car].reduce(0) { $0 + $1.balance }
        let liabilities = loan.balance + card.balance
        for w in stride(from: 52, through: 1, by: -1) {
            guard let d = cal.date(byAdding: .day, value: -w * 7, to: today) else { continue }
            let growth = Double(52 - w) / 52
            let wobble = (rng.next() - 0.5) * 380
            context.insert(NetWorthSnapshot(day: d, assets: assets - 3600 * (1 - growth) + wobble,
                                            liabilities: liabilities + 2100 * (1 - growth)))
        }
        Ledger.recordSnapshot(context: context)
        try? context.save()
        Notifier.rescheduleBills(bills)
    }
}
