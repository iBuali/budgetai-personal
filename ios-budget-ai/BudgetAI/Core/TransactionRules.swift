import Foundation
import SwiftData
import Observation

// MARK: - Condition Logic & Fields

enum RuleConditionLogic: String, Codable, CaseIterable, Identifiable {
    case and = "AND"
    case or = "OR"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .and: return "AND — All selected conditions must match"
        case .or:  return "OR — Any selected condition can match"
        }
    }

    var shortTitle: String {
        switch self {
        case .and: return "AND (All match)"
        case .or:  return "OR (Any matches)"
        }
    }
}

enum RuleConditionField: String, Codable, CaseIterable, Identifiable {
    case merchant        = "merchant"
    case recipientIBAN   = "recipientIBAN"
    case accountDigits   = "accountDigits"
    case bank            = "bank"
    case smsSender       = "smsSender"
    case accountID       = "accountID"
    case location        = "location"
    case amount          = "amount"
    case direction       = "direction"
    case reference       = "reference"
    case note            = "note"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .merchant:      return "Merchant / Recipient"
        case .recipientIBAN: return "IBAN / Recipient Digits"
        case .accountDigits: return "Card / Account Digits"
        case .bank:          return "SMS Bank"
        case .smsSender:     return "SMS Sender"
        case .accountID:     return "Account"
        case .location:      return "Location"
        case .amount:        return "Amount"
        case .direction:     return "Transaction Direction"
        case .reference:     return "Reference Code"
        case .note:          return "Note"
        }
    }

    var symbol: String {
        switch self {
        case .merchant:      return "storefront.fill"
        case .recipientIBAN: return "number.square.fill"
        case .accountDigits: return "creditcard.fill"
        case .bank:          return "building.columns.fill"
        case .smsSender:     return "bubble.left.and.bubble.right.fill"
        case .accountID:     return "wallet.bifold.fill"
        case .location:      return "mappin.and.ellipse"
        case .amount:        return "banknote.fill"
        case .direction:     return "arrow.up.arrow.down.circle.fill"
        case .reference:     return "barcode"
        case .note:          return "note.text"
        }
    }
}

struct RuleCondition: Codable, Hashable, Identifiable {
    var id: UUID = UUID()
    var field: RuleConditionField
    /// Raw value used for matching (e.g. UUID string for accountID, numeric string for amount).
    var value: String
    /// Human-readable value captured from the transaction (e.g. account name or formatted BHD amount).
    var displayValue: String
}

// MARK: - Transfer Kind & Rule Actions

enum RuleTransferKind: String, Codable, CaseIterable, Identifiable {
    case internalTransfer = "internal"
    case externalTransfer = "external"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .internalTransfer: return "Internal Transfer"
        case .externalTransfer: return "External Transfer"
        }
    }
}

struct RuleActions: Codable, Hashable {
    /// Default action: Set Category.
    var categoryRaw: String = SpendCategory.other.rawValue
    /// When the rule classifies a transaction as a Transfer, defines whether it is Internal or External.
    var transferKind: RuleTransferKind?
    /// For Internal Transfers (or general account assignment): From Account (`accountID`).
    var fromAccountID: UUID?
    /// For Internal Transfers: To Account (`toAccountID`).
    var toAccountID: UUID?

    // Additional optional actions from available transaction fields:
    var setMerchant: String?
    var setBank: String?
    var setLocationName: String?
    var setLocationAddress: String?
    var setLatitude: Double?
    var setLongitude: Double?
    var setNote: String?
    var setGoalID: UUID?
    var setIsIncome: Bool?

    var category: SpendCategory {
        get { SpendCategory(rawValue: categoryRaw) ?? .other }
        set { categoryRaw = newValue.rawValue }
    }

    var isTransferCategory: Bool {
        let cat = category
        return cat == .transfers || cat == .internalTransfer || transferKind != nil
    }

    var effectiveTransferKind: RuleTransferKind? {
        if let transferKind { return transferKind }
        if category == .internalTransfer { return .internalTransfer }
        if category == .transfers { return .externalTransfer }
        return nil
    }
}

// MARK: - Transaction Rule Model

struct TransactionRule: Codable, Hashable, Identifiable {
    var id: UUID = UUID()
    var name: String
    var isEnabled: Bool = true
    var logic: RuleConditionLogic = .and
    var conditions: [RuleCondition]
    var actions: RuleActions
    var sourceTransactionID: UUID?
    var createdAt: Date = .now

    /// Normalized signature of this rule's conditions used to detect conflicting/duplicate rules.
    var conditionSignature: String {
        let sorted = conditions
            .map { "\($0.field.rawValue)=\($0.value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())" }
            .sorted()
            .joined(separator: "&")
        return "\(logic.rawValue):\(sorted)"
    }
}

// MARK: - Candidate Context for Matching Future Transactions

struct RuleEvaluationContext {
    var merchant: String
    var recipientIBAN: String?
    var accountDigits: String?
    var bank: String?
    var smsSender: String?
    var accountID: UUID?
    var locationName: String?
    var amount: Double
    var isIncome: Bool
    var reference: String?
    var note: String
    var rawText: String?

    init(from tx: MoneyTransaction) {
        self.merchant = tx.merchant
        self.recipientIBAN = tx.smsRecipientSuffix
        self.accountDigits = tx.smsAccountSuffix
        self.bank = tx.smsBank
        self.smsSender = tx.smsSender
        self.accountID = tx.accountID
        self.locationName = tx.locationName
        self.amount = tx.amount
        self.isIncome = tx.isIncome
        self.reference = tx.smsReference
        self.note = tx.note
        self.rawText = tx.rawText
    }

    init(
        merchant: String,
        recipientIBAN: String? = nil,
        accountDigits: String? = nil,
        bank: String? = nil,
        smsSender: String? = nil,
        accountID: UUID? = nil,
        locationName: String? = nil,
        amount: Double,
        isIncome: Bool,
        reference: String? = nil,
        note: String = "",
        rawText: String? = nil
    ) {
        self.merchant = merchant
        self.recipientIBAN = recipientIBAN
        self.accountDigits = accountDigits
        self.bank = bank
        self.smsSender = smsSender
        self.accountID = accountID
        self.locationName = locationName
        self.amount = amount
        self.isIncome = isIncome
        self.reference = reference
        self.note = note
        self.rawText = rawText
    }
}

// MARK: - Transaction Rule Store

@Observable
final class TransactionRuleStore {
    static let shared = TransactionRuleStore()

    private static let storageKey = "transaction_rules_v1"

    private(set) var rules: [TransactionRule] = []

    init() {
        load()
    }

    func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode([TransactionRule].self, from: data) else {
            rules = []
            return
        }
        rules = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(rules) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }

    // MARK: Capture Available Fields from a Selected Transaction

    /// Automatically captures all non-empty fields available in the selected transaction.
    static func captureAvailableConditions(from tx: MoneyTransaction, accounts: [Account]) -> [RuleCondition] {
        var captured: [RuleCondition] = []
        let cleanMerchant = tx.merchant.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanMerchant.isEmpty {
            captured.append(RuleCondition(
                field: .merchant,
                value: cleanMerchant,
                displayValue: cleanMerchant
            ))
        }

        if let recip = tx.smsRecipientSuffix?.trimmingCharacters(in: .whitespacesAndNewlines), !recip.isEmpty {
            captured.append(RuleCondition(
                field: .recipientIBAN,
                value: recip,
                displayValue: "**\(recip)"
            ))
        }

        if let acctDigits = tx.smsAccountSuffix?.trimmingCharacters(in: .whitespacesAndNewlines), !acctDigits.isEmpty {
            captured.append(RuleCondition(
                field: .accountDigits,
                value: acctDigits,
                displayValue: "**\(acctDigits)"
            ))
        }

        if let bank = tx.smsBank?.trimmingCharacters(in: .whitespacesAndNewlines), !bank.isEmpty {
            captured.append(RuleCondition(
                field: .bank,
                value: bank,
                displayValue: bank
            ))
        }

        if let sender = tx.smsSender?.trimmingCharacters(in: .whitespacesAndNewlines), !sender.isEmpty {
            captured.append(RuleCondition(
                field: .smsSender,
                value: sender,
                displayValue: sender
            ))
        }

        if let accountID = tx.accountID,
           let account = accounts.first(where: { $0.id == accountID }) {
            captured.append(RuleCondition(
                field: .accountID,
                value: accountID.uuidString,
                displayValue: account.name
            ))
        }

        if let loc = tx.locationName?.trimmingCharacters(in: .whitespacesAndNewlines), !loc.isEmpty {
            captured.append(RuleCondition(
                field: .location,
                value: loc,
                displayValue: loc
            ))
        }

        if tx.amount > 0 {
            captured.append(RuleCondition(
                field: .amount,
                value: String(format: "%.3f", tx.amount),
                displayValue: Money.format(tx.amount, tx.currency)
            ))
        }

        captured.append(RuleCondition(
            field: .direction,
            value: tx.isIncome ? "in" : "out",
            displayValue: tx.isIncome ? "Money In (Income / Credit)" : "Money Out (Expense / Debit)"
        ))

        if let ref = tx.smsReference?.trimmingCharacters(in: .whitespacesAndNewlines), !ref.isEmpty {
            captured.append(RuleCondition(
                field: .reference,
                value: ref,
                displayValue: ref
            ))
        }

        let cleanNote = tx.note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanNote.isEmpty {
            captured.append(RuleCondition(
                field: .note,
                value: cleanNote,
                displayValue: cleanNote
            ))
        }

        return captured
    }

    // MARK: Conflict & Duplicate Rule Prevention

    /// Returns an existing rule if it has the exact same condition signature (excluding `excludingRuleID`).
    func conflictingRule(for candidate: TransactionRule, excludingRuleID: UUID? = nil) -> TransactionRule? {
        let sig = candidate.conditionSignature
        return rules.first { existing in
            if let excludingRuleID, existing.id == excludingRuleID { return false }
            return existing.conditionSignature == sig
        }
    }

    // MARK: CRUD & Priority Management

    /// Adds a user-approved rule. If a rule with identical conditions already exists, updates it instead of creating a duplicate.
    @discardableResult
    func addRule(_ rule: TransactionRule) -> TransactionRule {
        guard !rule.conditions.isEmpty else { return rule }
        if let conflictIdx = rules.firstIndex(where: { $0.id == rule.id || $0.conditionSignature == rule.conditionSignature }) {
            var updated = rule
            updated.id = rules[conflictIdx].id
            rules[conflictIdx] = updated
            save()
            return updated
        }
        rules.append(rule)
        save()
        return rule
    }

    func updateRule(_ rule: TransactionRule) {
        guard let idx = rules.firstIndex(where: { $0.id == rule.id }) else { return }
        rules[idx] = rule
        save()
    }

    func toggleRule(id: UUID) {
        guard let idx = rules.firstIndex(where: { $0.id == id }) else { return }
        rules[idx].isEnabled.toggle()
        save()
    }

    func setRuleEnabled(id: UUID, isEnabled: Bool) {
        guard let idx = rules.firstIndex(where: { $0.id == id }) else { return }
        rules[idx].isEnabled = isEnabled
        save()
    }

    func deleteRule(id: UUID) {
        rules.removeAll { $0.id == id }
        save()
    }

    func deleteRules(at offsets: IndexSet) {
        for index in offsets.sorted(by: >) {
            if rules.indices.contains(index) {
                rules.remove(at: index)
            }
        }
        save()
    }

    func moveRules(from source: IndexSet, to destination: Int) {
        var copy = rules
        let moving = source.map { copy[$0] }
        for index in source.sorted(by: >) {
            copy.remove(at: index)
        }
        let adjustedDestination = destination - source.filter { $0 < destination }.count
        let safeDestination = max(0, min(copy.count, adjustedDestination))
        copy.insert(contentsOf: moving, at: safeDestination)
        rules = copy
        save()
    }

    func moveRuleUp(id: UUID) {
        guard let idx = rules.firstIndex(where: { $0.id == id }), idx > 0 else { return }
        rules.swapAt(idx, idx - 1)
        save()
    }

    func moveRuleDown(id: UUID) {
        guard let idx = rules.firstIndex(where: { $0.id == id }), idx < rules.count - 1 else { return }
        rules.swapAt(idx, idx + 1)
        save()
    }

    func deleteAll() {
        rules.removeAll()
        UserDefaults.standard.removeObject(forKey: Self.storageKey)
    }

    /// Returns the 1-based priority index (`Rule 1`, `Rule 2`, ...) for a given rule ID.
    func priorityNumber(for id: UUID) -> Int? {
        guard let idx = rules.firstIndex(where: { $0.id == id }) else { return nil }
        return idx + 1
    }

    /// Returns all rules associated with or matching a transaction, preserving global priority order (`Rule 1`, `Rule 2`, ...).
    func rulesForTransaction(_ tx: MoneyTransaction) -> [TransactionRule] {
        let context = RuleEvaluationContext(from: tx)
        return rules.filter { rule in
            rule.sourceTransactionID == tx.id || matches(rule: rule, context: context, ignoreEnabledState: true)
        }
    }

    // MARK: Priority Evaluation & Matching

    /// Evaluates enabled rules in strict priority order (`Rule 1`, `Rule 2`, `Rule 3`, ...).
    /// When multiple rules match, the higher-priority rule takes precedence.
    func firstMatchingRule(for context: RuleEvaluationContext) -> TransactionRule? {
        for rule in rules where rule.isEnabled {
            if matches(rule: rule, context: context, ignoreEnabledState: false) {
                return rule
            }
        }
        return nil
    }

    func firstMatchingRule(for tx: MoneyTransaction) -> TransactionRule? {
        firstMatchingRule(for: RuleEvaluationContext(from: tx))
    }

    func matches(rule: TransactionRule, context: RuleEvaluationContext, ignoreEnabledState: Bool = false) -> Bool {
        if !ignoreEnabledState && !rule.isEnabled { return false }
        guard !rule.conditions.isEmpty else { return false }

        switch rule.logic {
        case .and:
            return rule.conditions.allSatisfy { conditionMatches($0, context: context) }
        case .or:
            return rule.conditions.contains { conditionMatches($0, context: context) }
        }
    }

    private func conditionMatches(_ condition: RuleCondition, context: RuleEvaluationContext) -> Bool {
        let target = condition.value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return false }
        let targetLower = target.lowercased()
        let rawLower = (context.rawText ?? "").lowercased()

        switch condition.field {
        case .merchant:
            let m = context.merchant.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !m.isEmpty && (m == targetLower || m.contains(targetLower) || targetLower.contains(m)) {
                return true
            }
            return !rawLower.isEmpty && rawLower.contains(targetLower)

        case .recipientIBAN:
            let cleanTarget = targetLower.replacingOccurrences(of: "*", with: "")
            if let recip = context.recipientIBAN?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !recip.isEmpty {
                let cleanRecip = recip.replacingOccurrences(of: "*", with: "")
                if cleanRecip == cleanTarget || cleanRecip.hasSuffix(cleanTarget) || cleanTarget.hasSuffix(cleanRecip) {
                    return true
                }
            }
            return !rawLower.isEmpty && !cleanTarget.isEmpty && rawLower.contains(cleanTarget)

        case .accountDigits:
            let cleanTarget = targetLower.replacingOccurrences(of: "*", with: "")
            if let digits = context.accountDigits?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !digits.isEmpty {
                let cleanDigits = digits.replacingOccurrences(of: "*", with: "")
                if cleanDigits == cleanTarget || cleanDigits.hasSuffix(cleanTarget) || cleanTarget.hasSuffix(cleanDigits) {
                    return true
                }
            }
            return !rawLower.isEmpty && !cleanTarget.isEmpty && rawLower.contains(cleanTarget)

        case .bank:
            guard let bank = context.bank?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !bank.isEmpty else {
                return false
            }
            return bank == targetLower || bank.contains(targetLower) || targetLower.contains(bank)

        case .smsSender:
            guard let sender = context.smsSender?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !sender.isEmpty else {
                return false
            }
            return sender == targetLower || sender.contains(targetLower) || targetLower.contains(sender)

        case .accountID:
            guard let acct = context.accountID else { return false }
            return acct.uuidString.caseInsensitiveCompare(target) == .orderedSame

        case .location:
            if let loc = context.locationName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !loc.isEmpty {
                if loc == targetLower || loc.contains(targetLower) || targetLower.contains(loc) {
                    return true
                }
            }
            return !rawLower.isEmpty && rawLower.contains(targetLower)

        case .amount:
            guard let expected = Double(target) else { return false }
            return abs(context.amount - expected) < 0.001

        case .direction:
            let expectedIncome = (targetLower == "in" || targetLower == "income" || targetLower == "true")
            return context.isIncome == expectedIncome

        case .reference:
            if let ref = context.reference?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !ref.isEmpty {
                return ref == targetLower || ref.contains(targetLower)
            }
            return !rawLower.isEmpty && rawLower.contains(targetLower)

        case .note:
            let n = context.note.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return !n.isEmpty && (n == targetLower || n.contains(targetLower))
        }
    }

    // MARK: Applying Highest-Priority Rule to a Future Transaction

    /// Applies the highest-priority matching rule to a newly created/imported transaction.
    /// Returns the matched rule if one was applied.
    @discardableResult
    func applyHighestPriorityRuleIfMatching(to tx: MoneyTransaction, context: ModelContext? = nil) -> TransactionRule? {
        guard let rule = firstMatchingRule(for: tx) else { return nil }
        apply(rule: rule, to: tx, priorityNumber: priorityNumber(for: rule.id) ?? 1)
        return rule
    }

    func apply(rule: TransactionRule, to tx: MoneyTransaction, priorityNumber: Int = 1) {
        let actions = rule.actions

        // 1. Optional direction override
        if let setIsIncome = actions.setIsIncome {
            tx.isIncome = setIsIncome
        }

        // 2. Category & Transfer handling (Internal vs External Transfer)
        if let transferKind = actions.effectiveTransferKind {
            switch transferKind {
            case .internalTransfer:
                tx.category = .internalTransfer
                tx.smsTransactionType = .internalTransfer
                tx.isIncome = false
                if let fromID = actions.fromAccountID {
                    tx.accountID = fromID
                }
                if let toID = actions.toAccountID, toID != tx.accountID {
                    tx.toAccountID = toID
                }
            case .externalTransfer:
                tx.category = .transfers
                tx.smsTransactionType = tx.isIncome ? .transferIn : .transferOut
                tx.toAccountID = nil
                tx.goalID = nil
                if let fromID = actions.fromAccountID {
                    tx.accountID = fromID
                }
            }
        } else {
            tx.category = actions.category
            if actions.category.isIncomeCategory {
                tx.isIncome = true
                if tx.source == .sms {
                    tx.smsTransactionType = .income
                }
            } else if tx.source == .sms && (tx.smsTransactionType == nil || tx.smsTransactionType == .unknown || tx.smsTransactionType == .internalTransfer || tx.smsTransactionType == .transferOut) {
                tx.smsTransactionType = tx.isIncome ? .income : .expense
            }
            if let fromID = actions.fromAccountID {
                tx.accountID = fromID
            }
            if actions.category != .internalTransfer && actions.category != .visaTransfer {
                tx.toAccountID = nil
            }
        }

        // 3. Additional field actions
        if let merchant = actions.setMerchant?.trimmingCharacters(in: .whitespacesAndNewlines), !merchant.isEmpty {
            tx.merchant = merchant
        }
        if let bank = actions.setBank?.trimmingCharacters(in: .whitespacesAndNewlines), !bank.isEmpty {
            tx.smsBank = bank
        }
        if let locName = actions.setLocationName?.trimmingCharacters(in: .whitespacesAndNewlines), !locName.isEmpty {
            tx.locationName = locName
            if let addr = actions.setLocationAddress {
                tx.locationAddress = addr
            }
            if let lat = actions.setLatitude, let lon = actions.setLongitude {
                tx.latitude = lat
                tx.longitude = lon
            }
        }
        if let note = actions.setNote?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
            tx.note = note
        }
        if let goalID = actions.setGoalID {
            tx.goalID = goalID
        }

        tx.smsConfidence = .high
        tx.smsClassificationReason = "Matched Rule \(priorityNumber): \(rule.name)"
        tx.aiCategorized = false
    }
}
