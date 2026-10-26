import Foundation
import SwiftData

struct LedgerResult {
    var flaggedDuplicate = false
    var alerts: [String] = []
    /// Set when the account balance was corrected to match the bank SMS.
    var balanceSynced: Double?
}

/// All writes that touch balances go through here so accounts, alerts and history stay consistent.
enum Ledger {
    @discardableResult
    static func add(_ tx: MoneyTransaction, context: ModelContext, checkDuplicates: Bool = true) -> LedgerResult {
        var result = LedgerResult()
        if checkDuplicates, isLikelyDuplicate(tx, context: context) {
            tx.isPossibleDuplicate = true
            result.flaggedDuplicate = true
        }
        context.insert(tx)
        if tx.isPending {
            try? context.save()
            return result
        }
        applyBalance(tx, sign: 1, context: context)
        result.balanceSynced = syncBalanceFromSMS(tx, context: context)
        if tx.isSpending {
            result.alerts = checkBudgetAlerts(for: tx.category, context: context)
        }
        recordSnapshot(context: context)
        try? context.save()
        return result
    }

    /// Approve an imported SMS transaction: it now counts toward balances and budgets.
    @discardableResult
    static func approve(_ tx: MoneyTransaction, context: ModelContext) -> LedgerResult {
        guard tx.isPending else { return LedgerResult() }
        var result = LedgerResult()
        tx.isPending = false
        applyBalance(tx, sign: 1, context: context)
        result.balanceSynced = syncBalanceFromSMS(tx, context: context)
        result.flaggedDuplicate = tx.isPossibleDuplicate
        if tx.isSpending { result.alerts = checkBudgetAlerts(for: tx.category, context: context) }
        recordSnapshot(context: context)
        try? context.save()
        return result
    }

    /// Approves oldest first so bank balance syncing ends on the latest message.
    static func approveAll(_ txs: [MoneyTransaction], context: ModelContext) -> [LedgerResult] {
        txs.sorted { $0.date < $1.date }.map { approve($0, context: context) }
    }

    static func delete(_ tx: MoneyTransaction, context: ModelContext) {
        if !tx.isPending {
            applyBalance(tx, sign: -1, context: context)
            if tx.balanceAdjustment != 0, let id = tx.accountID, let account = account(id, context: context) {
                account.balance -= tx.balanceAdjustment
            }
        }
        context.delete(tx)
        recordSnapshot(context: context)
        try? context.save()
    }

    /// Reverse the old effect, mutate, then apply the new one.
    static func edit(_ tx: MoneyTransaction, context: ModelContext, change: (MoneyTransaction) -> Void) {
        if tx.isPending {
            change(tx)
            try? context.save()
            return
        }
        applyBalance(tx, sign: -1, context: context)
        change(tx)
        applyBalance(tx, sign: 1, context: context)
        recordSnapshot(context: context)
        try? context.save()
    }

    static func applyBalance(_ tx: MoneyTransaction, sign: Double, context: ModelContext) {
        if let id = tx.accountID, let account = account(id, context: context) {
            if account.kind.isLiability {
                account.balance += (tx.isIncome ? -tx.amount : tx.amount) * sign
            } else {
                account.balance += tx.signedAmount * sign
            }
        }
        // Transfers credit the destination account (paying down a loan or card reduces what's owed).
        if tx.isTransfer, let to = tx.toAccountID, let dest = account(to, context: context) {
            dest.balance += (dest.kind.isLiability ? -tx.amount : tx.amount) * sign
        }
    }

    /// Records a transfer between two accounts.
    @discardableResult
    static func transfer(amount: Double, from: Account, to: Account, date: Date, note: String, context: ModelContext) -> LedgerResult {
        let tx = MoneyTransaction(amount: amount, isIncome: false, merchant: "\(from.name) → \(to.name)", category: .transfers,
                                  date: date, note: note, source: .transfer, accountID: from.id)
        tx.toAccountID = to.id
        return add(tx, context: context, checkDuplicates: false)
    }

    /// When the bank SMS includes the available balance, make the app's account match it.
    /// Only applied for cash/bank accounts and only when this is the newest transaction on that account.
    static func syncBalanceFromSMS(_ tx: MoneyTransaction, context: ModelContext, force: Bool = false) -> Double? {
        guard force || AppSettings.smsSyncBalance, !tx.isPending, let bankBalance = tx.smsBalance, let id = tx.accountID,
              let account = account(id, context: context), !account.kind.isLiability else { return nil }
        let date = tx.date
        let txID = tx.id
        let newer = (try? context.fetch(FetchDescriptor<MoneyTransaction>(predicate: #Predicate {
            $0.accountID == id && $0.date > date && $0.isPending == false && $0.id != txID
        }))) ?? []
        guard force || newer.isEmpty else { return nil }
        let diff = bankBalance - account.balance
        guard abs(diff) >= 0.0005 else { return nil }
        account.balance = bankBalance
        tx.balanceAdjustment += diff
        if force {
            recordSnapshot(context: context)
            try? context.save()
        }
        return bankBalance
    }

    static func account(_ id: UUID, context: ModelContext) -> Account? {
        let descriptor = FetchDescriptor<Account>(predicate: #Predicate { $0.id == id })
        return try? context.fetch(descriptor).first
    }

    /// Account used for SMS imports: the user's fixed choice, otherwise matched by card digits or bank name.
    static func smsAccountID(context: ModelContext, digits: String?, hint: String?) -> UUID? {
        let accounts = (try? context.fetch(FetchDescriptor<Account>(sortBy: [SortDescriptor(\.createdAt)]))) ?? []
        if let fixed = AppSettings.smsAccountID, accounts.contains(where: { $0.id == fixed }) { return fixed }
        if let digits, !digits.isEmpty,
           let match = accounts.first(where: { !$0.smsMatch.isEmpty && (digits.hasSuffix($0.smsMatch) || $0.smsMatch.hasSuffix(digits)) }) {
            return match.id
        }
        return defaultAccountID(context: context, hint: hint)
    }

    static func defaultAccountID(context: ModelContext, hint: String? = nil) -> UUID? {
        let accounts = (try? context.fetch(FetchDescriptor<Account>(sortBy: [SortDescriptor(\.createdAt)]))) ?? []
        if let hint, !hint.isEmpty {
            let h = hint.lowercased()
            if let match = accounts.first(where: { $0.name.lowercased().contains(h) || (!$0.institution.isEmpty && h.contains($0.institution.lowercased())) || $0.institution.lowercased().contains(h) }) {
                return match.id
            }
        }
        return accounts.first(where: { $0.kind == .bank })?.id ?? accounts.first(where: { $0.kind == .cash })?.id
    }

    // MARK: Duplicates

    static func isLikelyDuplicate(_ tx: MoneyTransaction, context: ModelContext) -> Bool {
        let start = tx.date.addingTimeInterval(-2 * 86_400)
        let end = tx.date.addingTimeInterval(2 * 86_400)
        let descriptor = FetchDescriptor<MoneyTransaction>(predicate: #Predicate { $0.date >= start && $0.date <= end })
        let candidates = (try? context.fetch(descriptor)) ?? []
        let key = Finance.merchantKey(tx.merchant)
        return candidates.contains { other in
            guard other.id != tx.id, other.isIncome == tx.isIncome, abs(other.amount - tx.amount) < 0.0005 else { return false }
            let otherKey = Finance.merchantKey(other.merchant)
            if key.isEmpty || otherKey.isEmpty { return true }
            return key == otherKey || key.contains(otherKey) || otherKey.contains(key)
        }
    }

    // MARK: Budget alerts

    static func checkBudgetAlerts(for category: SpendCategory, context: ModelContext) -> [String] {
        let raw = category.rawValue
        let budgets = (try? context.fetch(FetchDescriptor<Budget>(predicate: #Predicate { $0.categoryRaw == raw }))) ?? []
        guard let budget = budgets.first, budget.limit > 0 else { return [] }
        let interval = Cycle.interval(containing: .now)
        let start = interval.start, end = interval.end
        let txs = (try? context.fetch(FetchDescriptor<MoneyTransaction>(predicate: #Predicate {
            $0.date >= start && $0.date < end && $0.categoryRaw == raw && !$0.isIncome && !$0.isPending
        }))) ?? []
        let spent = txs.reduce(0) { $0 + $1.amount }
        let ratio = spent / budget.limit
        let code = AppSettings.currency
        var messages: [String] = []
        for threshold in [1.0, 0.8] where ratio >= threshold {
            let key = "alert-\(raw)-\(DateKeys.month(.now))-\(Int(threshold * 100))"
            guard !UserDefaults.standard.bool(forKey: key) else { break }
            UserDefaults.standard.set(true, forKey: key)
            let left = budget.limit - spent
            let message = threshold >= 1
                ? "\(category.title) budget exceeded by \(Money.format(-left, code).replacingOccurrences(of: "−", with: ""))"
                : "\(category.title) is at \(Int(ratio * 100))% of budget. \(Money.format(left, code)) left."
            messages.append(message)
            if AppSettings.budgetAlerts {
                Notifier.post(title: threshold >= 1 ? "Budget exceeded" : "Approaching your limit", body: message, id: key)
            }
            break
        }
        return messages
    }

    // MARK: Bills & goals

    static func payBill(_ bill: Bill, accountID: UUID?, context: ModelContext) {
        let tx = MoneyTransaction(amount: bill.amount, isIncome: false, merchant: bill.name, category: bill.category,
                                  date: .now, source: .bill, accountID: accountID)
        add(tx, context: context, checkDuplicates: false)
        bill.lastPaidAt = .now
        var next = bill.frequency.next(after: bill.nextDueDate)
        while next < Calendar.current.startOfDay(for: .now) { next = bill.frequency.next(after: next) }
        bill.nextDueDate = next
        try? context.save()
    }

    static func contribute(to goal: SavingsGoal, amount: Double, fromAccountID: UUID?, context: ModelContext) {
        let key = DateKeys.month(.now)
        if goal.monthKey != key {
            goal.monthKey = key
            goal.monthContributed = 0
        }
        goal.monthContributed += amount
        goal.saved += amount
        if let fromAccountID {
            let tx = MoneyTransaction(amount: amount, isIncome: false, merchant: "Saved to \(goal.name)",
                                      category: .transfers, source: .transfer, accountID: fromAccountID)
            add(tx, context: context, checkDuplicates: false)
        } else {
            try? context.save()
        }
    }

    // MARK: Net worth history

    static func recordSnapshot(context: ModelContext) {
        let accounts = (try? context.fetch(FetchDescriptor<Account>())) ?? []
        let assets = accounts.filter { !$0.kind.isLiability }.reduce(0) { $0 + $1.balance }
        let liabilities = accounts.filter { $0.kind.isLiability }.reduce(0) { $0 + $1.balance }
        let day = Calendar.current.startOfDay(for: .now)
        let existing = (try? context.fetch(FetchDescriptor<NetWorthSnapshot>(predicate: #Predicate { $0.day == day }))) ?? []
        if let snap = existing.first {
            snap.assets = assets
            snap.liabilities = liabilities
        } else if !accounts.isEmpty {
            context.insert(NetWorthSnapshot(day: day, assets: assets, liabilities: liabilities))
        }
    }

    static func eraseAll(context: ModelContext) {
        try? context.delete(model: MoneyTransaction.self)
        try? context.delete(model: Account.self)
        try? context.delete(model: Budget.self)
        try? context.delete(model: SavingsGoal.self)
        try? context.delete(model: Bill.self)
        try? context.delete(model: NetWorthSnapshot.self)
        try? context.delete(model: ChatMessage.self)
        try? context.delete(model: CustomCategory.self)
        try? context.save()
        CategoryRegistry.shared.reload(context: context)
        Notifier.rescheduleBills([])
    }
}
