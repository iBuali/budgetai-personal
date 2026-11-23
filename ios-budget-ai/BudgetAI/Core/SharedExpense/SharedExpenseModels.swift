import Foundation
import CryptoKit
import Observation

// MARK: - Enums & Core Types

enum SharedExpenseConfidenceLevel: String, Codable, Hashable, CaseIterable {
    case high = "high"
    case medium = "medium"
    case low = "low"
    case insufficient = "insufficient"

    var title: String {
        switch self {
        case .high: return "High"
        case .medium: return "Medium"
        case .low: return "Low"
        case .insufficient: return "Insufficient"
        }
    }

    static func from(score: Double) -> SharedExpenseConfidenceLevel {
        if score >= 0.85 { return .high }
        if score >= 0.60 { return .medium }
        if score >= 0.40 { return .low }
        return .insufficient
    }
}

enum SharedExpenseConfirmationSource: String, Codable, Hashable {
    case automatic = "automatic"
    case userConfirmed = "user_confirmed"

    var title: String {
        switch self {
        case .automatic: return "Automatic"
        case .userConfirmed: return "User Confirmed"
        }
    }
}

enum SharedExpenseRelationshipType: String, Codable, Hashable {
    case sharedExpense = "shared_expense"
    case personalExpense = "personal_expense"
    case rejectedSuggestion = "rejected_suggestion"
    case reimbursementPattern = "reimbursement_pattern"
}

enum SharedExpenseSuggestionStatus: String, Codable, Hashable {
    case pending = "pending"
    case confirmed = "confirmed"
    case rejected = "rejected"
}

// MARK: - AI Prediction (Isolated from Transaction Classification)

/// Structured output from the AI Shared Expense Detector.
/// Stored completely separately from `MoneyTransaction` classification fields.
struct SharedExpensePrediction: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var transactionID: UUID
    var sharedProbability: Double
    var estimatedPersonalAmount: Double
    var estimatedReimbursableAmount: Double
    var confidence: Double
    var confidenceLevel: SharedExpenseConfidenceLevel
    var explanation: String
    var suggestedCategoryRaw: String
    var signals: [String] = []
    var createdAt: Date = Date()

    var clampedProbability: Double { min(1, max(0, sharedProbability)) }
    var clampedConfidence: Double { min(1, max(0, confidence)) }
}

// MARK: - Contextual Suggestion (Medium / Low Confidence)

/// Non-mutating contextual suggestion presented to the user when confidence is uncertain.
struct SharedExpenseSuggestion: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var expenseTransactionID: UUID
    var candidateReimbursementIDs: [UUID] = []
    var originalExpenseAmount: Double
    var suggestedCategoryRaw: String
    var suggestedPersonalAmount: Double
    var suggestedReimbursableAmount: Double
    var potentialReimbursementAmount: Double?
    var expectedBudgetImpact: Double
    var confidence: Double
    var confidenceLevel: SharedExpenseConfidenceLevel
    var explanation: String
    var promptMessage: String
    var status: SharedExpenseSuggestionStatus = .pending
    var createdAt: Date = Date()
    var resolvedAt: Date? = nil
}

// MARK: - Reimbursement Allocation & Reversible Adjustment Audit Record

/// Links a specific non-overlapping portion of an incoming reimbursement transaction to an expense.
struct ReimbursementAllocation: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var reimbursementTransactionID: UUID
    var allocatedAmount: Double
    var linkedAt: Date = Date()
    var senderToken: String? = nil
}

/// Separate, reversible adjustment layer record with full audit trail.
/// Original `MoneyTransaction` records are never mutated or deleted.
struct SharedExpenseAdjustment: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var originalTransactionID: UUID
    var reimbursementAllocations: [ReimbursementAllocation] = []
    var originalExpenseAmount: Double
    var personalAmount: Double
    var reimbursableAmount: Double
    var effectiveCategoryRaw: String? = nil
    var aiConfidence: Double
    var explanation: String
    var timestamp: Date = Date()
    var confirmationSource: SharedExpenseConfirmationSource
    var isReversed: Bool = false
    var reversedAt: Date? = nil
    var reversalReason: String? = nil

    var relatedReimbursementTransactionIDs: [UUID] {
        reimbursementAllocations.map(\.reimbursementTransactionID)
    }

    var totalReceivedReimbursementAmount: Double {
        reimbursementAllocations.reduce(0) { $0 + max(0, $1.allocatedAmount) }
    }

    var outstandingReimbursementAmount: Double {
        max(0, reimbursableAmount - totalReceivedReimbursementAmount)
    }

    var isActive: Bool { !isReversed }
}

// MARK: - Dedicated Learning Memory Record

/// Persistent learning memory record isolated from `TransactionRuleStore`.
/// Matches the canonical schema while keeping sensitive data minimized.
struct SharedExpenseMemoryRecord: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var transactionID: String
    var relationshipType: SharedExpenseRelationshipType
    var confirmedCategory: String
    var personalAmount: Double
    var reimbursableAmount: Double
    var confirmationSource: SharedExpenseConfirmationSource
    var confidence: Double

    // Minimized behavioral signals (no raw phone/IBAN PII stored)
    var merchantKey: String = ""
    var senderToken: String? = nil
    var reimbursementDelayHours: Double? = nil
    var wasPartialRepayment: Bool = false
    var createdAt: Date = Date()
    var isReversed: Bool = false

    enum CodingKeys: String, CodingKey {
        case id
        case transactionID = "transaction_id"
        case relationshipType = "relationship_type"
        case confirmedCategory = "confirmed_category"
        case personalAmount = "personal_amount"
        case reimbursableAmount = "reimbursable_amount"
        case confirmationSource = "confirmation_source"
        case confidence
        case merchantKey = "merchant_key"
        case senderToken = "sender_token"
        case reimbursementDelayHours = "reimbursement_delay_hours"
        case wasPartialRepayment = "was_partial_repayment"
        case createdAt = "created_at"
        case isReversed = "is_reversed"
    }
}

// MARK: - Safe Anonymization & Normalization Helpers

enum SharedExpensePrivacy {
    /// Normalizes a merchant name into a stable lowercase key without branch/reference noise.
    static func normalizedMerchantKey(_ merchant: String) -> String {
        let lowered = merchant.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = lowered.unicodeScalars.map { scalar -> Character in
            if CharacterSet.letters.contains(scalar) || CharacterSet.whitespaces.contains(scalar) {
                return Character(scalar)
            }
            return " "
        }
        let tokens = String(allowed)
            .split(separator: " ")
            .filter { $0.count >= 2 }
            .prefix(3)
        return tokens.joined(separator: " ")
    }

    /// Produces a short irreversible SHA-256 token for a sender identifier so repeated
    /// reimbursement patterns can be recognized without storing raw sensitive identifiers.
    static func anonymizedSenderToken(rawSender: String?) -> String? {
        guard let raw = rawSender?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        let normalized = raw.lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
        guard normalized.count >= 3 else { return nil }
        let digest = SHA256.hash(data: Data(("falak.se.v1." + normalized).utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Extracts a minimized sender hint from an incoming transfer transaction when safely available.
    static func extractSenderToken(from tx: MoneyTransaction) -> String? {
        let merchant = tx.merchant.trimmingCharacters(in: .whitespacesAndNewlines)
        let genericIncoming: Set<String> = [
            "incoming transfer", "transfer in", "fawri+ transfer", "fawri transfer",
            "benefitpay · fawri+ transfer", "benefitpay · fawri transfer",
            "bank transfer", "transfer", "incoming credit", "credit"
        ]
        if !merchant.isEmpty, !genericIncoming.contains(merchant.lowercased()) {
            return anonymizedSenderToken(rawSender: "m:" + merchant)
        }
        if let raw = tx.rawText {
            // Check for explicit "from <Name>" pattern in bank transfer SMS
            let patterns = [
                #"(?i)\bfrom\s+([A-Za-z][A-Za-z\s]{2,28}?)(?=\s+(?:on|ref|via|iban|acc|for|bhd|bd|amount)\b|[.,\n]|$)"#,
                #"(?i)\bby\s+([A-Za-z][A-Za-z\s]{2,28}?)(?=\s+(?:on|ref|via|iban|acc|for|bhd|bd|amount)\b|[.,\n]|$)"#
            ]
            for pattern in patterns {
                if let regex = try? NSRegularExpression(pattern: pattern),
                   let match = regex.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)),
                   match.numberOfRanges > 1,
                   let range = Range(match.range(at: 1), in: raw) {
                    let candidate = String(raw[range]).trimmingCharacters(in: .whitespacesAndNewlines)
                    let low = candidate.lowercased()
                    if !candidate.isEmpty && !low.contains("your") && !low.contains("account") && !low.contains("iban") && !low.contains("card") {
                        return anonymizedSenderToken(rawSender: "s:" + candidate)
                    }
                }
            }
        }
        if let suffix = tx.smsRecipientSuffix?.trimmingCharacters(in: .whitespacesAndNewlines), !suffix.isEmpty {
            return anonymizedSenderToken(rawSender: "x:" + suffix)
        }
        return nil
    }
}

// MARK: - Deterministic Financial Validator

enum FinancialValidationError: Error, Equatable {
    case invalidExpenseAmount
    case invalidReimbursementAmount
    case invalidSplitAmounts
    case duplicateReimbursementLink
    case reimbursementExceedsCapacity(available: Double, requested: Double)
    case expenseExceedsOutstanding(outstanding: Double, requested: Double)
    case reimbursementPredatesExpense
    case selfReferenceNotAllowed
}

/// Deterministic financial invariants enforced before any automatic or user-confirmed adjustment.
/// AI confidence alone can NEVER bypass these rules.
enum SharedExpenseFinancialValidator {
    static let epsilon: Double = 0.0005
    /// Allow up to 10 minutes of bank SMS timestamp skew between card auth and instant Fawri+ arrival.
    static let maxClockSkewSeconds: TimeInterval = 600

    static func validateSplit(originalAmount: Double, personalAmount: Double, reimbursableAmount: Double) -> Result<Void, FinancialValidationError> {
        guard originalAmount > epsilon else { return .failure(.invalidExpenseAmount) }
        guard personalAmount >= -epsilon, reimbursableAmount >= -epsilon else {
            return .failure(.invalidSplitAmounts)
        }
        guard reimbursableAmount <= originalAmount + epsilon else {
            return .failure(.invalidSplitAmounts)
        }
        guard abs((personalAmount + reimbursableAmount) - originalAmount) <= 0.01 else {
            return .failure(.invalidSplitAmounts)
        }
        return .success(())
    }

    /// Validates adding `requestedAmount` from `reimbursementTxID` (total `reimbursementTotalAmount`)
    /// onto `expenseTxID` (with target `expenseReimbursableCap`) against all currently active adjustments.
    static func validateAllocation(
        expenseTxID: UUID,
        expenseDate: Date,
        expenseTotalAmount: Double,
        expenseReimbursableCap: Double,
        reimbursementTxID: UUID,
        reimbursementDate: Date,
        reimbursementTotalAmount: Double,
        requestedAmount: Double,
        existingActiveAdjustments: [SharedExpenseAdjustment]
    ) -> Result<Void, FinancialValidationError> {
        guard expenseTxID != reimbursementTxID else {
            return .failure(.selfReferenceNotAllowed)
        }
        guard expenseTotalAmount > epsilon else {
            return .failure(.invalidExpenseAmount)
        }
        guard reimbursementTotalAmount > epsilon, requestedAmount > epsilon else {
            return .failure(.invalidReimbursementAmount)
        }
        guard reimbursementDate.timeIntervalSince(expenseDate) >= -maxClockSkewSeconds else {
            return .failure(.reimbursementPredatesExpense)
        }

        // Prevent duplicate reimbursement matching for the same (reimbursement, expense) pair
        let alreadyLinked = existingActiveAdjustments.contains { adj in
            adj.isActive
                && adj.originalTransactionID == expenseTxID
                && adj.reimbursementAllocations.contains { $0.reimbursementTransactionID == reimbursementTxID }
        }
        if alreadyLinked {
            return .failure(.duplicateReimbursementLink)
        }

        // Global conservation: reimbursement cannot allocate more than its total amount across all expenses
        let alreadyAllocatedFromReimbursement = existingActiveAdjustments
            .filter(\.isActive)
            .flatMap(\.reimbursementAllocations)
            .filter { $0.reimbursementTransactionID == reimbursementTxID }
            .reduce(0.0) { $0 + max(0, $1.allocatedAmount) }
        let availableReimbursement = max(0, reimbursementTotalAmount - alreadyAllocatedFromReimbursement)
        if requestedAmount > availableReimbursement + epsilon {
            return .failure(.reimbursementExceedsCapacity(available: availableReimbursement, requested: requestedAmount))
        }

        // Expense conservation: cannot exceed expense's reimbursable cap or total amount
        let effectiveCap = min(expenseTotalAmount, max(0, expenseReimbursableCap))
        let alreadyAllocatedToExpense = existingActiveAdjustments
            .filter { $0.isActive && $0.originalTransactionID == expenseTxID }
            .reduce(0.0) { $0 + $1.totalReceivedReimbursementAmount }
        let outstandingExpense = max(0, effectiveCap - alreadyAllocatedToExpense)
        if requestedAmount > outstandingExpense + epsilon {
            return .failure(.expenseExceedsOutstanding(outstanding: outstandingExpense, requested: requestedAmount))
        }

        return .success(())
    }
}

// MARK: - Dedicated Shared Expense Learning Memory Store

struct SharedExpensePrior {
    let confirmedSharedCount: Int
    let rejectedSuggestionCount: Int
    let confirmedPersonalCount: Int
    let knownSenderConfirmationCount: Int
    let averageReimbursementDelayHours: Double?
    let averagePersonalRatio: Double?
    let partialRepaymentRate: Double

    /// Bounded score adjustment (-0.45 ... +0.30).
    /// Deliberately damped so a single confirmation never turns into a universal rule.
    var probabilityDelta: Double {
        let positiveEvidence = Double(confirmedSharedCount) * 0.08 + Double(knownSenderConfirmationCount) * 0.12
        let negativeEvidence = Double(rejectedSuggestionCount) * 0.18 + Double(confirmedPersonalCount) * 0.12
        return min(0.30, max(-0.45, positiveEvidence - negativeEvidence))
    }

    var isRepeatedlyRejected: Bool {
        rejectedSuggestionCount >= 1 && confirmedSharedCount == 0
    }
}

@Observable
final class SharedExpenseMemoryStore {
    static let shared = SharedExpenseMemoryStore()

    private let defaults: UserDefaults
    private let storageKey: String

    private(set) var records: [SharedExpenseMemoryRecord] = []

    init(defaults: UserDefaults = .standard, storageKey: String = "falak.sharedExpense.memory.v1") {
        self.defaults = defaults
        self.storageKey = storageKey
        load()
    }

    var activeRecords: [SharedExpenseMemoryRecord] {
        records.filter { !$0.isReversed }
    }

    func record(_ entry: SharedExpenseMemoryRecord) {
        // Avoid duplicating identical active transaction records of the same relationship type
        if let idx = records.firstIndex(where: {
            $0.transactionID == entry.transactionID && $0.relationshipType == entry.relationshipType && !$0.isReversed
        }) {
            records[idx] = entry
        } else {
            records.insert(entry, at: 0)
        }
        // Keep memory bounded and performant
        if records.count > 1000 {
            records = Array(records.prefix(1000))
        }
        save()
    }

    func markReversed(transactionID: UUID) {
        let idStr = transactionID.uuidString
        var changed = false
        for i in records.indices where records[i].transactionID == idStr && !records[i].isReversed {
            records[i].isReversed = true
            changed = true
        }
        if changed { save() }
    }

    func deleteRecord(id: UUID) {
        records.removeAll { $0.id == id }
        save()
    }

    func clearAll() {
        records = []
        defaults.removeObject(forKey: storageKey)
    }

    /// Computes a damped prior from confirmed user feedback and reliable historical records.
    func prior(merchant: String, categoryRaw: String, senderToken: String? = nil) -> SharedExpensePrior {
        let mKey = SharedExpensePrivacy.normalizedMerchantKey(merchant)
        let active = activeRecords

        var sharedCount = 0
        var rejectedCount = 0
        var personalCount = 0
        var senderHits = 0
        var delays: [Double] = []
        var personalRatios: [Double] = []
        var partialCount = 0
        var reimbursementRecords = 0

        for r in active {
            let merchantMatches = !mKey.isEmpty && !r.merchantKey.isEmpty && r.merchantKey == mKey
            let categoryMatches = r.confirmedCategory == categoryRaw

            if let token = senderToken, let rToken = r.senderToken, !token.isEmpty, token == rToken {
                if r.relationshipType == .sharedExpense || r.relationshipType == .reimbursementPattern {
                    senderHits += 1
                }
            }

            if merchantMatches {
                switch r.relationshipType {
                case .sharedExpense:
                    sharedCount += 1
                    let total = r.personalAmount + r.reimbursableAmount
                    if total > 0 { personalRatios.append(r.personalAmount / total) }
                case .rejectedSuggestion:
                    rejectedCount += 1
                case .personalExpense:
                    personalCount += 1
                case .reimbursementPattern:
                    reimbursementRecords += 1
                    if r.wasPartialRepayment { partialCount += 1 }
                    if let d = r.reimbursementDelayHours, d >= 0 { delays.append(d) }
                }
            } else if categoryMatches {
                if r.relationshipType == .reimbursementPattern {
                    reimbursementRecords += 1
                    if r.wasPartialRepayment { partialCount += 1 }
                    if let d = r.reimbursementDelayHours, d >= 0 { delays.append(d) }
                }
            }
        }

        let avgDelay = delays.isEmpty ? nil : delays.reduce(0, +) / Double(delays.count)
        let avgPersonalRatio = personalRatios.isEmpty ? nil : personalRatios.reduce(0, +) / Double(personalRatios.count)
        let partialRate = reimbursementRecords > 0 ? Double(partialCount) / Double(reimbursementRecords) : 0

        return SharedExpensePrior(
            confirmedSharedCount: sharedCount,
            rejectedSuggestionCount: rejectedCount,
            confirmedPersonalCount: personalCount,
            knownSenderConfirmationCount: senderHits,
            averageReimbursementDelayHours: avgDelay,
            averagePersonalRatio: avgPersonalRatio,
            partialRepaymentRate: partialRate
        )
    }

    func typicalReimbursementWindowDays() -> Double {
        let delays = activeRecords.compactMap(\.reimbursementDelayHours).filter { $0 >= 0 }
        guard !delays.isEmpty else { return 14.0 }
        let maxLearnedDays = (delays.max() ?? 72.0) / 24.0
        return min(30.0, max(14.0, maxLearnedDays + 5.0))
    }

    private func load() {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([SharedExpenseMemoryRecord].self, from: data) else {
            records = []
            return
        }
        records = decoded
    }

    private func save() {
        if let data = try? JSONEncoder().encode(records) {
            defaults.set(data, forKey: storageKey)
        }
    }
}

// MARK: - Adjustment, Prediction & Suggestion Store

@Observable
final class SharedExpenseAdjustmentStore {
    static let shared = SharedExpenseAdjustmentStore()

    private let defaults: UserDefaults
    private let adjustmentsKey: String
    private let predictionsKey: String
    private let suggestionsKey: String

    private(set) var adjustments: [SharedExpenseAdjustment] = []
    private(set) var predictions: [SharedExpensePrediction] = []
    private(set) var suggestions: [SharedExpenseSuggestion] = []

    init(
        defaults: UserDefaults = .standard,
        adjustmentsKey: String = "falak.sharedExpense.adjustments.v1",
        predictionsKey: String = "falak.sharedExpense.predictions.v1",
        suggestionsKey: String = "falak.sharedExpense.suggestions.v1"
    ) {
        self.defaults = defaults
        self.adjustmentsKey = adjustmentsKey
        self.predictionsKey = predictionsKey
        self.suggestionsKey = suggestionsKey
        loadAll()
    }

    var activeAdjustments: [SharedExpenseAdjustment] {
        adjustments.filter(\.isActive)
    }

    var pendingSuggestions: [SharedExpenseSuggestion] {
        suggestions.filter { $0.status == .pending }
    }

    func activeAdjustment(forExpenseID id: UUID) -> SharedExpenseAdjustment? {
        adjustments.first { $0.isActive && $0.originalTransactionID == id }
    }

    func activeAdjustments(forReimbursementID id: UUID) -> [SharedExpenseAdjustment] {
        adjustments.filter { adj in
            adj.isActive && adj.reimbursementAllocations.contains { $0.reimbursementTransactionID == id }
        }
    }

    func pendingSuggestion(forTransactionID id: UUID) -> SharedExpenseSuggestion? {
        suggestions.first {
            $0.status == .pending && ($0.expenseTransactionID == id || $0.candidateReimbursementIDs.contains(id))
        }
    }

    func prediction(forTransactionID id: UUID) -> SharedExpensePrediction? {
        predictions.first { $0.transactionID == id }
    }

    func remainingCapacity(forReimbursementID id: UUID, totalAmount: Double) -> Double {
        let allocated = activeAdjustments
            .flatMap(\.reimbursementAllocations)
            .filter { $0.reimbursementTransactionID == id }
            .reduce(0.0) { $0 + max(0, $1.allocatedAmount) }
        return max(0, totalAmount - allocated)
    }

    func savePrediction(_ prediction: SharedExpensePrediction) {
        if let idx = predictions.firstIndex(where: { $0.transactionID == prediction.transactionID }) {
            predictions[idx] = prediction
        } else {
            predictions.insert(prediction, at: 0)
        }
        if predictions.count > 500 {
            predictions = Array(predictions.prefix(500))
        }
        persistPredictions()
    }

    func upsertSuggestion(_ suggestion: SharedExpenseSuggestion) {
        if let idx = suggestions.firstIndex(where: {
            $0.expenseTransactionID == suggestion.expenseTransactionID && $0.status == .pending
        }) {
            suggestions[idx] = suggestion
        } else {
            suggestions.insert(suggestion, at: 0)
        }
        if suggestions.count > 300 {
            suggestions = Array(suggestions.prefix(300))
        }
        persistSuggestions()
    }

    func markSuggestion(_ id: UUID, status: SharedExpenseSuggestionStatus) {
        guard let idx = suggestions.firstIndex(where: { $0.id == id }) else { return }
        suggestions[idx].status = status
        suggestions[idx].resolvedAt = Date()
        persistSuggestions()
    }

    func upsertAdjustment(_ adjustment: SharedExpenseAdjustment) {
        if let idx = adjustments.firstIndex(where: { $0.id == adjustment.id }) {
            adjustments[idx] = adjustment
        } else if let activeIdx = adjustments.firstIndex(where: {
            $0.isActive && $0.originalTransactionID == adjustment.originalTransactionID
        }) {
            adjustments[activeIdx] = adjustment
        } else {
            adjustments.insert(adjustment, at: 0)
        }
        persistAdjustments()
    }

    @discardableResult
    func reverseAdjustment(id: UUID, reason: String = "Reversed by user", memoryStore: SharedExpenseMemoryStore = .shared) -> SharedExpenseAdjustment? {
        guard let idx = adjustments.firstIndex(where: { $0.id == id && $0.isActive }) else { return nil }
        adjustments[idx].isReversed = true
        adjustments[idx].reversedAt = Date()
        adjustments[idx].reversalReason = reason
        let reversed = adjustments[idx]
        persistAdjustments()

        // Update learning memory so future predictions reflect the correction
        memoryStore.markReversed(transactionID: reversed.originalTransactionID)
        memoryStore.record(SharedExpenseMemoryRecord(
            transactionID: reversed.originalTransactionID.uuidString,
            relationshipType: .personalExpense,
            confirmedCategory: reversed.effectiveCategoryRaw ?? SpendCategory.other.rawValue,
            personalAmount: reversed.originalExpenseAmount,
            reimbursableAmount: 0,
            confirmationSource: .userConfirmed,
            confidence: 1.0,
            merchantKey: "",
            senderToken: reversed.reimbursementAllocations.first?.senderToken
        ))
        return reversed
    }

    /// Removes orphaned adjustments, predictions, and suggestions when an underlying transaction is deleted.
    func cleanupDeletedTransaction(_ txID: UUID) {
        var adjChanged = false
        for i in adjustments.indices {
            if adjustments[i].originalTransactionID == txID {
                if adjustments[i].isActive {
                    adjustments[i].isReversed = true
                    adjustments[i].reversedAt = Date()
                    adjustments[i].reversalReason = "Original transaction deleted"
                    adjChanged = true
                }
            } else if adjustments[i].reimbursementAllocations.contains(where: { $0.reimbursementTransactionID == txID }) {
                adjustments[i].reimbursementAllocations.removeAll { $0.reimbursementTransactionID == txID }
                // If an automatic reimbursement-driven adjustment loses all linked reimbursements, reverse it cleanly.
                if adjustments[i].reimbursementAllocations.isEmpty && adjustments[i].confirmationSource == .automatic {
                    adjustments[i].isReversed = true
                    adjustments[i].reversedAt = Date()
                    adjustments[i].reversalReason = "Linked reimbursement deleted"
                }
                adjChanged = true
            }
        }
        if adjChanged { persistAdjustments() }

        let oldPredCount = predictions.count
        predictions.removeAll { $0.transactionID == txID }
        if predictions.count != oldPredCount { persistPredictions() }

        let oldSugCount = suggestions.count
        suggestions.removeAll { $0.expenseTransactionID == txID || $0.candidateReimbursementIDs.contains(txID) }
        if suggestions.count != oldSugCount { persistSuggestions() }
    }

    func clearAll() {
        adjustments = []
        predictions = []
        suggestions = []
        defaults.removeObject(forKey: adjustmentsKey)
        defaults.removeObject(forKey: predictionsKey)
        defaults.removeObject(forKey: suggestionsKey)
    }

    func makeOverlay(isEnabled: Bool = AppSettings.sharedExpenseIntelligenceEnabled) -> SharedExpenseOverlay {
        guard isEnabled else { return .empty }
        return SharedExpenseOverlay(adjustments: activeAdjustments)
    }

    private func loadAll() {
        if let data = defaults.data(forKey: adjustmentsKey),
           let decoded = try? JSONDecoder().decode([SharedExpenseAdjustment].self, from: data) {
            adjustments = decoded
        }
        if let data = defaults.data(forKey: predictionsKey),
           let decoded = try? JSONDecoder().decode([SharedExpensePrediction].self, from: data) {
            predictions = decoded
        }
        if let data = defaults.data(forKey: suggestionsKey),
           let decoded = try? JSONDecoder().decode([SharedExpenseSuggestion].self, from: data) {
            suggestions = decoded
        }
    }

    private func persistAdjustments() {
        if let data = try? JSONEncoder().encode(adjustments) {
            defaults.set(data, forKey: adjustmentsKey)
        }
    }

    private func persistPredictions() {
        if let data = try? JSONEncoder().encode(predictions) {
            defaults.set(data, forKey: predictionsKey)
        }
    }

    private func persistSuggestions() {
        if let data = try? JSONEncoder().encode(suggestions) {
            defaults.set(data, forKey: suggestionsKey)
        }
    }
}

// MARK: - Reversible Budget & Spending Overlay (Used by Finance)

/// Pure value-type overlay consumed by `Finance`.
/// When the feature is disabled, `SharedExpenseOverlay.current` returns `.empty`,
/// ensuring zero change to any existing budget or spending calculation.
struct SharedExpenseOverlay {
    static let empty = SharedExpenseOverlay(adjustments: [])

    static var current: SharedExpenseOverlay {
        SharedExpenseAdjustmentStore.shared.makeOverlay(isEnabled: AppSettings.sharedExpenseIntelligenceEnabled)
    }

    let isActive: Bool
    private let expenseAdjustmentsByID: [UUID: SharedExpenseAdjustment]
    private let reimbursementDeductionsByID: [UUID: Double]

    init(adjustments: [SharedExpenseAdjustment]) {
        let active = adjustments.filter(\.isActive)
        self.isActive = !active.isEmpty
        var byExpense: [UUID: SharedExpenseAdjustment] = [:]
        var byReimb: [UUID: Double] = [:]
        for adj in active {
            byExpense[adj.originalTransactionID] = adj
            for alloc in adj.reimbursementAllocations where alloc.allocatedAmount > 0 {
                byReimb[alloc.reimbursementTransactionID, default: 0] += alloc.allocatedAmount
            }
        }
        self.expenseAdjustmentsByID = byExpense
        self.reimbursementDeductionsByID = byReimb
    }

    /// Personal spending amount counted toward budgets/charts for `tx`.
    /// Original `tx.amount` is never modified.
    func effectiveSpendingAmount(for tx: MoneyTransaction) -> Double {
        guard isActive, let adj = expenseAdjustmentsByID[tx.id] else { return tx.amount }
        let excluded = min(tx.amount, max(0, adj.reimbursableAmount))
        return max(0, tx.amount - excluded)
    }

    /// Effective category key for budget attribution when the user linked a shared expense to a category.
    func effectiveCategoryRaw(for tx: MoneyTransaction) -> String {
        guard isActive, let adj = expenseAdjustmentsByID[tx.id],
              let catRaw = adj.effectiveCategoryRaw, !catRaw.isEmpty else {
            return tx.categoryRaw
        }
        return catRaw
    }

    /// Effective ordinary income amount for `tx` (excludes portions linked as reimbursements so
    /// reimbursements are never counted as new income).
    func effectiveIncomeAmount(for tx: MoneyTransaction) -> Double {
        guard isActive, let deducted = reimbursementDeductionsByID[tx.id], deducted > 0 else {
            return tx.amount
        }
        return max(0, tx.amount - deducted)
    }

    /// Returns true if an active confirmed/automatic adjustment explicitly includes `tx` as a personal shared expense
    /// even if its underlying bank SMS type was originally a transfer (never mutating `tx`).
    func isIncludedAsAdjustedExpense(_ tx: MoneyTransaction) -> Bool {
        guard isActive, let adj = expenseAdjustmentsByID[tx.id] else { return false }
        return adj.personalAmount > 0 || adj.effectiveCategoryRaw != nil
    }

    func activeAdjustment(for txID: UUID) -> SharedExpenseAdjustment? {
        expenseAdjustmentsByID[txID]
    }

    func allocatedReimbursementAmount(for txID: UUID) -> Double {
        reimbursementDeductionsByID[txID] ?? 0
    }
}
