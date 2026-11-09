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
        if !tx.isIncome && (tx.source == .sms || tx.source == .manual) {
            _ = matchAndPayBillFromSMS(tx, context: context)
        }
        recordSnapshot(context: context)
        try? context.save()
        if tx.category == .visaTransfer { refreshCardReminders(context: context) }
        return result
    }

    /// Approve an imported SMS transaction: it now counts toward balances and budgets.
    @discardableResult
    static func approve(_ tx: MoneyTransaction, context: ModelContext) -> LedgerResult {
        guard tx.isPending else { return LedgerResult() }
        var result = LedgerResult()
        if tx.accountID == nil {
            if let matched = SMSParser.findMatchingAccount(forBank: tx.smsBank, senderOrPhone: tx.smsSender, digits: tx.smsAccountSuffix, in: context) {
                tx.accountID = matched.id
            } else if tx.smsBank == nil && tx.smsAccountSuffix == nil {
                tx.accountID = defaultAccountID(context: context, hint: nil)
            }
        }
        tx.isPending = false
        applyBalance(tx, sign: 1, context: context)
        result.balanceSynced = syncBalanceFromSMS(tx, context: context)
        result.flaggedDuplicate = tx.isPossibleDuplicate
        if tx.isSpending { result.alerts = checkBudgetAlerts(for: tx.category, context: context) }
        if !tx.isIncome {
            _ = matchAndPayBillFromSMS(tx, context: context)
        }
        recordSnapshot(context: context)
        try? context.save()
        if tx.category == .visaTransfer { refreshCardReminders(context: context) }
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
            if tx.toBalanceAdjustment != 0, let toId = tx.toAccountID, let toAccount = account(toId, context: context) {
                toAccount.balance -= tx.toBalanceAdjustment
            }
        }
        context.delete(tx)
        recordSnapshot(context: context)
        try? context.save()
        reconcileDuplicates(context: context)
    }

    /// Reverse the old effect, mutate, then apply the new one.
    static func edit(_ tx: MoneyTransaction, context: ModelContext, change: (MoneyTransaction) -> Void) {
        if tx.isPending {
            change(tx)
            try? context.save()
            return
        }
        applyBalance(tx, sign: -1, context: context)
        if tx.balanceAdjustment != 0, let id = tx.accountID, let account = account(id, context: context) {
            account.balance -= tx.balanceAdjustment
            tx.balanceAdjustment = 0
        }
        if tx.toBalanceAdjustment != 0, let toId = tx.toAccountID, let toAccount = account(toId, context: context) {
            toAccount.balance -= tx.toBalanceAdjustment
            tx.toBalanceAdjustment = 0
        }
        change(tx)
        applyBalance(tx, sign: 1, context: context)
        _ = syncBalanceFromSMS(tx, context: context)
        recordSnapshot(context: context)
        try? context.save()
        if tx.category == .visaTransfer { refreshCardReminders(context: context) }
    }

    static func applyBalance(_ tx: MoneyTransaction, sign: Double, context: ModelContext) {
        if tx.smsTransactionType == .unknown {
            return
        }
        let isCardPayment = tx.category == .visaTransfer
        let isInternal = tx.smsTransactionType == .internalTransfer || tx.category == .internalTransfer || isCardPayment
        if sign > 0, !isCardPayment, isInternal {
            if tx.toAccountID == nil,
               let recip = tx.smsRecipientSuffix,
               let matchedDest = SMSParser.findMatchingAccount(suffix: recip, excludingAccountID: tx.accountID, in: context) {
                tx.toAccountID = matchedDest.id
            }
            if tx.goalID == nil,
               let matchedGoal = SMSParser.findMatchingGoal(suffix: tx.smsRecipientSuffix, accountID: tx.toAccountID, in: context),
               matchedGoal.linkedAccountID == nil || matchedGoal.linkedAccountID != tx.accountID {
                tx.goalID = matchedGoal.id
                if tx.toAccountID == nil, let linkedAcc = matchedGoal.linkedAccountID, linkedAcc != tx.accountID {
                    tx.toAccountID = linkedAcc
                }
            }
        }
        if isInternal && !isCardPayment && tx.toAccountID == nil && tx.goalID == nil {
            // Do not change net worth on an internal transfer without a destination account or linked savings goal.
            // (Card payments still debit the paying bank account even before a card account is linked.)
            return
        }
        if let id = tx.accountID, let account = account(id, context: context) {
            if account.kind.isLiability {
                account.balance += (tx.isIncome ? -tx.amount : tx.amount) * sign
            } else {
                account.balance += tx.signedAmount * sign
            }
        }
        // Internal transfers credit the destination account (paying down a loan or card reduces what's owed).
        if (isInternal || (tx.smsTransactionType == nil && tx.isTransfer)),
           let to = tx.toAccountID, to != tx.accountID, let dest = account(to, context: context) {
            dest.balance += (dest.kind.isLiability ? -tx.amount : tx.amount) * sign
            if sign > 0 && dest.kind == .creditCard {
                // Paid in full shortly before the due date → move the reminder to next month's due date.
                dest.advanceDueDateIfPaid(on: tx.date)
            }
        }
        // Automatically update the linked savings goal when a transfer contributes to it.
        if let goalID = tx.goalID, let targetGoal = goal(goalID, context: context) {
            let txMonthKey = DateKeys.month(tx.date)
            let currentMonthKey = DateKeys.month(.now)
            if targetGoal.monthKey != currentMonthKey {
                targetGoal.monthKey = currentMonthKey
                targetGoal.monthContributed = 0
            }
            targetGoal.saved = max(0, targetGoal.saved + tx.amount * sign)
            if txMonthKey == currentMonthKey {
                targetGoal.monthContributed = max(0, targetGoal.monthContributed + tx.amount * sign)
            }
        }
    }

    /// Applies a user correction to a transaction's SMS classification, bank, category, or destination account,
    /// updating account balances, budgets, and net worth consistently and optionally saving a scoped user rule.
    @discardableResult
    static func applyUserCorrection(
        to tx: MoneyTransaction,
        newType: SMSTransactionType,
        newBank: String? = nil,
        newCategory: SpendCategory? = nil,
        toAccountID: UUID? = nil,
        approveIfPending: Bool = false,
        rememberRule: Bool = false,
        context: ModelContext
    ) -> LedgerResult {
        let resolvedBank: String? = {
            if let newBank {
                let clean = newBank.trimmingCharacters(in: .whitespacesAndNewlines)
                return clean.isEmpty ? nil : clean
            }
            return tx.smsBank
        }()

        func mutate(_ target: MoneyTransaction) {
            target.smsTransactionType = newType
            target.isIncome = newType.isIncomeDirection
            target.smsBank = resolvedBank
            target.smsConfidence = .high
            target.smsClassificationReason = "Corrected by user to \(newType.title)"
            target.aiCategorized = false

            switch newType {
            case .transferIn, .transferOut:
                target.category = .transfers
                target.subcategory = nil
                target.toAccountID = nil
                target.goalID = nil
            case .internalTransfer:
                target.category = newCategory ?? .internalTransfer
                target.subcategory = nil
                if let toAccountID, toAccountID != target.accountID {
                    target.toAccountID = toAccountID
                } else if target.toAccountID == nil || target.toAccountID == target.accountID,
                          let recip = target.smsRecipientSuffix,
                          let matchedDest = SMSParser.findMatchingAccount(suffix: recip, excludingAccountID: target.accountID, in: context) {
                    target.toAccountID = matchedDest.id
                }
                if target.goalID == nil,
                   let matchedGoal = SMSParser.findMatchingGoal(suffix: target.smsRecipientSuffix, accountID: target.toAccountID, in: context),
                   matchedGoal.linkedAccountID == nil || matchedGoal.linkedAccountID != target.accountID {
                    target.goalID = matchedGoal.id
                }
            case .income:
                target.toAccountID = nil
                target.goalID = nil
                if let newCategory {
                    target.category = newCategory
                } else if !target.category.isIncomeCategory {
                    target.category = .income
                }
            case .fee:
                target.toAccountID = nil
                target.goalID = nil
                if let newCategory {
                    target.category = newCategory
                } else if target.category == .transfers || target.category == .internalTransfer || target.category.isIncomeCategory {
                    target.category = .bills
                }
            case .expense, .refund:
                target.toAccountID = nil
                target.goalID = nil
                if let newCategory {
                    target.category = newCategory
                } else if target.category == .transfers || target.category == .internalTransfer || target.category.isIncomeCategory {
                    target.category = Categorizer.guess(target.merchant) ?? .other
                }
            case .unknown:
                target.toAccountID = nil
                target.goalID = nil
                target.category = .other
                target.smsConfidence = .low
            }
        }

        var result = LedgerResult()
        if tx.isPending && approveIfPending && newType != .unknown {
            mutate(tx)
            result = approve(tx, context: context)
        } else {
            edit(tx, context: context) { target in
                mutate(target)
            }
            if !tx.isPending && tx.isSpending {
                result.alerts = checkBudgetAlerts(for: tx.category, context: context)
            }
        }

        if rememberRule {
            SMSUserRules.rememberTransactionRule(for: tx)
        }
        return result
    }

    /// Records a transfer between two accounts.
    @discardableResult
    static func transfer(amount: Double, from: Account, to: Account, date: Date, note: String, context: ModelContext) -> LedgerResult {
        let matchedGoal = SMSParser.findMatchingGoal(accountID: to.id, in: context)
        let tx = MoneyTransaction(amount: amount, isIncome: false, merchant: "\(from.name) → \(to.name)", category: .internalTransfer,
                                  date: date, note: note, source: .transfer, accountID: from.id)
        tx.toAccountID = to.id
        tx.goalID = matchedGoal?.id
        return add(tx, context: context, checkDuplicates: false)
    }

    /// When the bank SMS includes the available balance, make the app's account match it.
    /// Updates the specified account's balance independently based on the SMS balance.
    @discardableResult
    static func syncBalanceForAccount(id: UUID, balance: Double, on tx: MoneyTransaction, isToAccount: Bool = false, context: ModelContext, force: Bool = false) -> Double? {
        guard force || AppSettings.smsSyncBalance, !tx.isPending, !tx.isCardLimitBalance,
              let account = account(id, context: context), !account.kind.isLiability else { return nil }
        let diff = balance - account.balance
        if abs(diff) >= 0.0005 {
            account.balance = balance
            if isToAccount {
                tx.toBalanceAdjustment += diff
            } else {
                tx.balanceAdjustment += diff
            }
            if force {
                recordSnapshot(context: context)
                try? context.save()
            }
        }
        return balance
    }

    /// When the bank SMS includes the available balance, make the app's account match it.
    /// For internal transfers, matches each account (source `accountID` and destination `toAccountID`)
    /// with its own respective balance from the SMS; balances are never merged or mixed.
    @discardableResult
    static func syncBalanceFromSMS(_ tx: MoneyTransaction, context: ModelContext, force: Bool = false) -> Double? {
        var syncedPrimary: Double? = nil
        if let id = tx.accountID, let bal = tx.smsBalance {
            syncedPrimary = syncBalanceForAccount(id: id, balance: bal, on: tx, isToAccount: false, context: context, force: force)
        }
        if let toId = tx.toAccountID, let toBal = tx.smsToBalance, toId != tx.accountID {
            _ = syncBalanceForAccount(id: toId, balance: toBal, on: tx, isToAccount: true, context: context, force: force)
        }
        return syncedPrimary
    }

    static func account(_ id: UUID, context: ModelContext) -> Account? {
        let descriptor = FetchDescriptor<Account>(predicate: #Predicate { $0.id == id })
        return try? context.fetch(descriptor).first
    }

    static func goal(_ id: UUID, context: ModelContext) -> SavingsGoal? {
        let descriptor = FetchDescriptor<SavingsGoal>(predicate: #Predicate { $0.id == id })
        return try? context.fetch(descriptor).first
    }

    /// Account used for SMS imports: prioritizes card/account digits (e.g. matching a credit card),
    /// then the SMS sender bank (`hint` / `sender`), then the user's fallback choice.
    static func smsAccountID(context: ModelContext, digits: String?, hint: String?, sender: String? = nil) -> UUID? {
        let accounts = (try? context.fetch(FetchDescriptor<Account>(sortBy: [SortDescriptor(\.createdAt)]))) ?? []
        // 1. Try finding by matching digits (prioritizes credit cards and matching bank)
        if let digits, !digits.isEmpty,
           let match = SMSParser.findMatchingAccount(forBank: hint, senderOrPhone: sender, digits: digits, in: context) {
            return match.id
        }
        if let digits, !digits.isEmpty,
           let match = SMSParser.findMatchingAccount(suffix: digits, in: context) {
            return match.id
        }
        // 2. Bank or sender without digits
        if let matchedByBank = SMSParser.findMatchingAccount(forBank: hint, senderOrPhone: sender, in: context) {
            return matchedByBank.id
        }
        if let fixed = AppSettings.smsAccountID, accounts.contains(where: { $0.id == fixed }) { return fixed }
        return defaultAccountID(context: context, hint: hint)
    }

    static func defaultAccountID(context: ModelContext, hint: String? = nil) -> UUID? {
        let accounts = (try? context.fetch(FetchDescriptor<Account>(sortBy: [SortDescriptor(\.createdAt)]))) ?? []
        if let hint, !hint.isEmpty {
            if let matchedByBank = SMSParser.findMatchingAccount(forBank: hint, in: context) {
                return matchedByBank.id
            }
            let h = hint.lowercased()
            if let match = accounts.first(where: { $0.name.lowercased().contains(h) || (!$0.institution.isEmpty && h.contains($0.institution.lowercased())) || $0.institution.lowercased().contains(h) }) {
                return match.id
            }
        }
        return accounts.first(where: { $0.kind == .bank })?.id ?? accounts.first(where: { $0.kind == .cash })?.id
    }

    /// Cash/bank account used to pay a credit card (never a card or loan), matched by bank name when possible.
    static func defaultLiquidAccountID(context: ModelContext, hint: String? = nil) -> UUID? {
        let accounts = ((try? context.fetch(FetchDescriptor<Account>(sortBy: [SortDescriptor(\.createdAt)]))) ?? [])
            .filter { $0.kind.isLiquid }
        if let hint, !hint.isEmpty {
            if let matchedByBank = SMSParser.findMatchingAccount(forBank: hint, in: context), matchedByBank.kind.isLiquid {
                return matchedByBank.id
            }
            let h = hint.lowercased()
            if let match = accounts.first(where: { $0.name.lowercased().contains(h) || (!$0.institution.isEmpty && (h.contains($0.institution.lowercased()) || $0.institution.lowercased().contains(h))) }) {
                return match.id
            }
        }
        if let fixed = AppSettings.smsAccountID, accounts.contains(where: { $0.id == fixed }) { return fixed }
        return accounts.first(where: { $0.kind == .bank })?.id ?? accounts.first?.id
    }

    /// Re-schedules Visa / credit card payment-due reminders (e.g. after a payment moved the due date).
    static func refreshCardReminders(context: ModelContext) {
        let accounts = (try? context.fetch(FetchDescriptor<Account>())) ?? []
        guard accounts.contains(where: { $0.kind == .creditCard && $0.paymentDueReminder }) else { return }
        Notifier.rescheduleCreditCards(accounts)
    }

    // MARK: Duplicates

    /// Extracts the normalized SMS reference code for a transaction (from `smsReference` or `rawText`).
    static func effectiveReference(for tx: MoneyTransaction) -> String? {
        if let direct = tx.smsReference?.trimmingCharacters(in: .whitespacesAndNewlines), !direct.isEmpty {
            return direct
        }
        if let raw = tx.rawText, let parsedRef = SMSParser.referenceNumber(in: raw)?.trimmingCharacters(in: .whitespacesAndNewlines), !parsedRef.isEmpty {
            tx.smsReference = parsedRef
            return parsedRef
        }
        return nil
    }

    /// Strict Reference-Only Duplicate Detection:
    /// A transaction is flagged as a duplicate ONLY if it has a non-empty SMS reference code
    /// that matches the reference code of another transaction. All other conditions (amount, balance, merchant, date, etc.) are ignored.
    static func isLikelyDuplicate(_ tx: MoneyTransaction, context: ModelContext) -> Bool {
        guard let txRef = effectiveReference(for: tx), !txRef.isEmpty else {
            return false
        }
        let all = (try? context.fetch(FetchDescriptor<MoneyTransaction>())) ?? []
        return all.contains { other in
            guard other.id != tx.id,
                  let otherRef = effectiveReference(for: other),
                  !otherRef.isEmpty else {
                return false
            }
            return otherRef.caseInsensitiveCompare(txRef) == .orderedSame
        }
    }

    /// Re-evaluates duplicate status across all stored transactions so that ONLY transactions sharing
    /// an identical non-empty SMS reference code remain flagged as `isPossibleDuplicate`.
    static func reconcileDuplicates(context: ModelContext) {
        let all = (try? context.fetch(FetchDescriptor<MoneyTransaction>(sortBy: [SortDescriptor(\.date)]))) ?? []
        guard !all.isEmpty else { return }

        var refCounts: [String: Int] = [:]
        for tx in all {
            if let ref = effectiveReference(for: tx)?.uppercased(), !ref.isEmpty {
                refCounts[ref, default: 0] += 1
            }
        }

        var seenFirstForRef: Set<String> = []
        var changed = false
        for tx in all {
            guard let ref = effectiveReference(for: tx)?.uppercased(), !ref.isEmpty, (refCounts[ref] ?? 0) > 1 else {
                if tx.isPossibleDuplicate {
                    tx.isPossibleDuplicate = false
                    changed = true
                }
                continue
            }
            if !seenFirstForRef.contains(ref) {
                seenFirstForRef.insert(ref)
                if tx.isPossibleDuplicate {
                    tx.isPossibleDuplicate = false
                    changed = true
                }
            } else {
                if !tx.isPossibleDuplicate {
                    tx.isPossibleDuplicate = true
                    changed = true
                }
            }
        }
        if changed {
            try? context.save()
        }
    }

    // MARK: Budget alerts

    static func checkBudgetAlerts(for category: SpendCategory, context: ModelContext) -> [String] {
        let allBudgets = (try? context.fetch(FetchDescriptor<Budget>())) ?? []
        let matchingBudgets = allBudgets.filter { $0.limit > 0 && $0.includes(category) }
        guard !matchingBudgets.isEmpty else { return [] }
        let interval = Cycle.interval(containing: .now)
        let start = interval.start, end = interval.end
        let txs = (try? context.fetch(FetchDescriptor<MoneyTransaction>(predicate: #Predicate {
            $0.date >= start && $0.date < end && !$0.isIncome && !$0.isPending
        }))) ?? []
        let code = AppSettings.currency
        var messages: [String] = []
        for budget in matchingBudgets {
            let keys = Set(budget.categories.map(\.rawValue))
            let spent = txs.filter { $0.isSpending && keys.contains($0.categoryRaw) }.reduce(0) { $0 + $1.amount }
            let ratio = spent / budget.limit
            for threshold in [1.0, 0.8] where ratio >= threshold {
                let key = "alert-\(budget.id.uuidString)-\(DateKeys.month(.now))-\(Int(threshold * 100))"
                guard !UserDefaults.standard.bool(forKey: key) else { break }
                UserDefaults.standard.set(true, forKey: key)
                let left = budget.limit - spent
                let message = threshold >= 1
                    ? "\(budget.displayName) budget exceeded by \(Money.format(-left, code).replacingOccurrences(of: "−", with: ""))"
                    : "\(budget.displayName) is at \(Int(ratio * 100))% of budget. \(Money.format(left, code)) left."
                messages.append(message)
                if AppSettings.budgetAlerts {
                    Notifier.post(title: threshold >= 1 ? "Budget exceeded" : "Approaching your limit", body: message, id: key)
                }
                break
            }
        }
        return messages
    }

    // MARK: Bills & goals

    static func payBill(_ bill: Bill, accountID: UUID?, context: ModelContext) {
        let tx = MoneyTransaction(amount: bill.amount, isIncome: false, merchant: bill.name, category: bill.category,
                                  date: .now, source: .bill, accountID: accountID)
        add(tx, context: context, checkDuplicates: false)
        bill.markPaid(date: .now, method: .manual, amount: bill.amount, txID: tx.id)
        try? context.save()
        let bills = (try? context.fetch(FetchDescriptor<Bill>())) ?? []
        Notifier.rescheduleBills(bills)
    }

    /// Automatically matches an incoming expense or SMS payment to an active bill or subscription.
    /// Matches keywords in SMS (name) and amounts near the bill's amount.
    @discardableResult
    static func matchAndPayBillFromSMS(_ tx: MoneyTransaction, context: ModelContext) -> Bill? {
        guard !tx.isIncome, tx.amount > 0 else { return nil }
        let bills = (try? context.fetch(FetchDescriptor<Bill>())) ?? []
        guard !bills.isEmpty else { return nil }

        let merchant = tx.merchant.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let raw = (tx.rawText ?? "").lowercased()

        for bill in bills {
            if bill.isPaidForCurrentCycle(now: tx.date) { continue }

            let billName = bill.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !billName.isEmpty else { continue }

            // 1. Check user's custom keywords (highest priority)
            let customMatch = bill.keywords.contains { kw in
                let cleanKw = kw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                guard !cleanKw.isEmpty else { return false }
                return merchant.contains(cleanKw) || (!raw.isEmpty && raw.contains(cleanKw)) || (tx.smsReference?.lowercased().contains(cleanKw) ?? false)
            }

            // 2. Keyword matching on bill name
            let isNameInMerchant = merchant.contains(billName) || billName.contains(merchant)
            let isNameInRaw = !raw.isEmpty && raw.contains(billName)

            let ignoredWords: Set<String> = ["the", "bill", "subscription", "monthly", "payment", "fee", "plan", "card", "pay", "services", "bh", "bhd", "app"]
            let billKeywords = billName.components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count >= 3 && !ignoredWords.contains($0) }

            let keywordMatch: Bool = {
                if customMatch { return true }
                if isNameInMerchant || isNameInRaw { return true }
                guard !billKeywords.isEmpty else { return false }
                return billKeywords.contains { kw in
                    merchant.contains(kw) || (!raw.isEmpty && raw.contains(kw))
                }
            }()

            guard keywordMatch else { continue }

            // Amount proximity check: exact or within ±15% (or ±2.0 currency units)
            let diff = abs(tx.amount - bill.amount)
            let maxAllowedDiff = max(2.0, bill.amount * 0.15)
            let isNearAmount = bill.amount <= 0 || diff <= maxAllowedDiff

            guard isNearAmount else { continue }

            bill.markPaid(date: tx.date, method: .autoSMS, amount: tx.amount, txID: tx.id)
            if tx.category == .bills || tx.category == .other || tx.category == .subscriptions {
                tx.category = bill.category
            }
            try? context.save()
            Notifier.rescheduleBills(bills)
            return bill
        }
        return nil
    }

    static func contribute(to goal: SavingsGoal, amount: Double, fromAccountID: UUID?, context: ModelContext) {
        if let fromAccountID {
            let tx = MoneyTransaction(amount: amount, isIncome: false, merchant: "Saved to \(goal.name)",
                                      category: .internalTransfer, source: .transfer, accountID: fromAccountID)
            tx.goalID = goal.id
            if let linkedAcc = goal.linkedAccountID, linkedAcc != fromAccountID {
                tx.toAccountID = linkedAcc
            }
            add(tx, context: context, checkDuplicates: false)
        } else {
            let key = DateKeys.month(.now)
            if goal.monthKey != key {
                goal.monthKey = key
                goal.monthContributed = 0
            }
            goal.monthContributed += amount
            goal.saved += amount
            try? context.save()
        }
    }

    // MARK: Net worth history

    static func recordSnapshot(context: ModelContext) {
        let accounts = (try? context.fetch(FetchDescriptor<Account>())) ?? []
        let included = accounts.filter(\.includeInNetWorth)
        let assets = included.filter { !$0.kind.isLiability }.reduce(0) { $0 + $1.balance }
        let liabilities = included.filter { $0.kind.isLiability }.reduce(0) { $0 + $1.balance }
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
        SMSUserRules.clearAll()
        CategoryRegistry.shared.reload(context: context)
        Notifier.rescheduleBills([])
    }
}
