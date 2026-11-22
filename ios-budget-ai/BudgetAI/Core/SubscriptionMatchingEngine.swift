import Foundation
import SwiftData

// MARK: - Extracted SMS Signal

/// Structured transaction data extracted from a bank SMS or expense for subscription matching.
struct SMSSubscriptionSignal: Sendable {
    let provider: String
    let merchantNormalized: String
    let amount: Double
    let currency: String
    let transactionType: SMSTransactionType
    let date: Date
    let referenceNumber: String?
    let identifierTokens: [String]
    let rawTextLower: String
}

// MARK: - Learning Rules Store

/// Learned positive association between an SMS merchant/provider pattern and a specific recurring `Bill`.
struct SubscriptionMatchRule: Codable, Identifiable, Equatable, Sendable {
    var id: UUID = UUID()
    var billID: UUID
    var billName: String
    var providerNormalized: String
    var merchantNormalized: String
    var referenceTokens: [String] = []
    var confirmedAmounts: [Double] = []
    var typicalDayOfMonth: Int?
    var confirmCount: Int = 1
    var lastConfirmedAt: Date = Date()
}

/// Learned negative decision remembering that a merchant/provider is NOT a recurring bill or subscription.
struct RejectedBillMerchantRule: Codable, Identifiable, Equatable, Sendable {
    var id: UUID = UUID()
    var merchantNormalized: String
    var providerNormalized: String
    var rejectedAt: Date = Date()
}

/// Persistent store for user-confirmed subscription rules and rejected bill suggestions.
final class SubscriptionLearningStore: @unchecked Sendable {
    static let shared = SubscriptionLearningStore()

    private let positiveKey = "falak_subscription_match_rules_v1"
    private let rejectedKey = "falak_rejected_bill_merchants_v1"
    private let lock = NSLock()
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var positiveRules: [SubscriptionMatchRule] {
        lock.lock()
        defer { lock.unlock() }
        guard let data = defaults.data(forKey: positiveKey),
              let decoded = try? JSONDecoder().decode([SubscriptionMatchRule].self, from: data) else {
            return []
        }
        return decoded
    }

    var rejectedRules: [RejectedBillMerchantRule] {
        lock.lock()
        defer { lock.unlock() }
        guard let data = defaults.data(forKey: rejectedKey),
              let decoded = try? JSONDecoder().decode([RejectedBillMerchantRule].self, from: data) else {
            return []
        }
        return decoded
    }

    func recordConfirmation(
        bill: Bill,
        signal: SMSSubscriptionSignal
    ) {
        lock.lock()
        defer { lock.unlock() }

        var rules = loadPositiveLocked()
        let day = Calendar.current.component(.day, from: signal.date)

        if let idx = rules.firstIndex(where: {
            $0.billID == bill.id && ($0.merchantNormalized == signal.merchantNormalized || $0.providerNormalized == signal.provider)
        }) {
            var rule = rules[idx]
            rule.billName = bill.name
            rule.confirmCount += 1
            rule.lastConfirmedAt = Date()
            rule.typicalDayOfMonth = day
            if !rule.confirmedAmounts.contains(where: { abs($0 - signal.amount) < 0.01 }) {
                rule.confirmedAmounts.append(signal.amount)
                if rule.confirmedAmounts.count > 8 {
                    rule.confirmedAmounts.removeFirst(rule.confirmedAmounts.count - 8)
                }
            }
            for token in signal.identifierTokens where !token.isEmpty && !rule.referenceTokens.contains(token) {
                rule.referenceTokens.append(token)
            }
            if rule.referenceTokens.count > 12 {
                rule.referenceTokens = Array(rule.referenceTokens.suffix(12))
            }
            rules[idx] = rule
        } else {
            let rule = SubscriptionMatchRule(
                billID: bill.id,
                billName: bill.name,
                providerNormalized: signal.provider,
                merchantNormalized: signal.merchantNormalized,
                referenceTokens: Array(signal.identifierTokens.prefix(12)),
                confirmedAmounts: [signal.amount],
                typicalDayOfMonth: day,
                confirmCount: 1,
                lastConfirmedAt: Date()
            )
            rules.append(rule)
        }
        savePositiveLocked(rules)

        // If this merchant was previously rejected, remove the rejection since the user confirmed it now.
        var rejected = loadRejectedLocked()
        rejected.removeAll {
            (!signal.merchantNormalized.isEmpty && $0.merchantNormalized == signal.merchantNormalized)
            || (!signal.provider.isEmpty && $0.providerNormalized == signal.provider && $0.merchantNormalized.isEmpty)
        }
        saveRejectedLocked(rejected)
    }

    func recordRejection(signal: SMSSubscriptionSignal) {
        lock.lock()
        defer { lock.unlock() }

        var rejected = loadRejectedLocked()
        let exists = rejected.contains {
            (!signal.merchantNormalized.isEmpty && $0.merchantNormalized == signal.merchantNormalized)
        }
        if !exists {
            rejected.append(RejectedBillMerchantRule(
                merchantNormalized: signal.merchantNormalized,
                providerNormalized: signal.provider,
                rejectedAt: Date()
            ))
            saveRejectedLocked(rejected)
        }
    }

    func isRejected(signal: SMSSubscriptionSignal) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let rejected = loadRejectedLocked()
        return rejected.contains { rule in
            if !signal.merchantNormalized.isEmpty && rule.merchantNormalized == signal.merchantNormalized {
                return true
            }
            if !signal.provider.isEmpty && rule.merchantNormalized.isEmpty && rule.providerNormalized == signal.provider {
                return true
            }
            return false
        }
    }

    func matchingPositiveRules(for billID: UUID) -> [SubscriptionMatchRule] {
        positiveRules.filter { $0.billID == billID }
    }

    func clearAll() {
        lock.lock()
        defer { lock.unlock() }
        defaults.removeObject(forKey: positiveKey)
        defaults.removeObject(forKey: rejectedKey)
    }

    private func loadPositiveLocked() -> [SubscriptionMatchRule] {
        guard let data = defaults.data(forKey: positiveKey),
              let decoded = try? JSONDecoder().decode([SubscriptionMatchRule].self, from: data) else {
            return []
        }
        return decoded
    }

    private func savePositiveLocked(_ rules: [SubscriptionMatchRule]) {
        if let data = try? JSONEncoder().encode(rules) {
            defaults.set(data, forKey: positiveKey)
        }
    }

    private func loadRejectedLocked() -> [RejectedBillMerchantRule] {
        guard let data = defaults.data(forKey: rejectedKey),
              let decoded = try? JSONDecoder().decode([RejectedBillMerchantRule].self, from: data) else {
            return []
        }
        return decoded
    }

    private func saveRejectedLocked(_ rules: [RejectedBillMerchantRule]) {
        if let data = try? JSONEncoder().encode(rules) {
            defaults.set(data, forKey: rejectedKey)
        }
    }
}

// MARK: - Scoring Breakdown & Match Result

struct SubscriptionScoreBreakdown: Sendable {
    let providerScore: Double      // weight 0.25
    let amountScore: Double        // weight 0.30
    let historyScore: Double       // weight 0.15
    let confirmedRuleScore: Double // weight 0.15
    let referenceScore: Double     // weight 0.10
    let scheduleScore: Double      // weight 0.05

    var totalScore: Double {
        providerScore * 0.25
        + amountScore * 0.30
        + historyScore * 0.15
        + confirmedRuleScore * 0.15
        + referenceScore * 0.10
        + scheduleScore * 0.05
    }

    /// Enforces Requirement 4: never match based solely on provider name OR solely on amount.
    /// Requires both an identity signal (provider, reference, or confirmed rule) AND
    /// at least one corroborating signal (amount, history, confirmed rule, reference, or schedule).
    var passesMultiSignalGate: Bool {
        let hasIdentitySignal = providerScore > 0 || referenceScore > 0 || confirmedRuleScore > 0
        let hasCorroboratingSignal = amountScore > 0 || historyScore > 0 || confirmedRuleScore > 0 || referenceScore > 0 || scheduleScore > 0
        let isOnlyProvider = providerScore > 0 && amountScore == 0 && historyScore == 0 && confirmedRuleScore == 0 && referenceScore == 0 && scheduleScore == 0
        let isOnlyAmount = amountScore > 0 && providerScore == 0 && historyScore == 0 && confirmedRuleScore == 0 && referenceScore == 0 && scheduleScore == 0
        return hasIdentitySignal && hasCorroboratingSignal && !isOnlyProvider && !isOnlyAmount
    }
}

enum SubscriptionPriceChange: Equatable, Sendable {
    case unchanged
    case increased(expected: Double, actual: Double)
    case decreased(expected: Double, actual: Double)
}

enum SubscriptionMatchOutcome {
    case matched(bill: Bill, score: Double, breakdown: SubscriptionScoreBreakdown, priceChange: SubscriptionPriceChange, reason: String)
    case duplicate(existingTxID: UUID)
    case suggestNewBill(provider: String, suggestedName: String, isSubscription: Bool, reason: String)
    case noMatch
}

// MARK: - Subscription Matching Engine

enum SubscriptionMatchingEngine {
    static let minimumMatchScore: Double = 0.42

    private static let ignoredTokens: Set<String> = [
        "the", "bill", "subscription", "monthly", "payment", "fee", "plan", "package",
        "pack", "card", "pay", "services", "service", "bh", "bhd", "app", "online",
        "pos", "purchase", "debit", "credit", "auto", "recurring", "telecom", "mobile",
        "home", "line", "account", "invoice", "ref", "bahrain", "manama", "com", "www"
    ]

    /// Known bill and subscription providers (Bahrain + global) used when the user hasn't created a bill yet.
    private static let knownBillProviders: [(keyword: String, displayName: String, isSubscription: Bool)] = [
        ("batelco", "Batelco", true),
        ("zain", "Zain", true),
        ("stc", "STC", true),
        ("viva", "STC", true),
        ("kalaam", "Kalaam Telecom", true),
        ("etisalcom", "Etisalcom", true),
        ("ewa", "EWA Electricity & Water", false),
        ("electricity", "Electricity & Water", false),
        ("municipality", "Municipality Bill", false),
        ("sadad", "SADAD Bill", false),
        ("netflix", "Netflix", true),
        ("spotify", "Spotify", true),
        ("apple.com/bill", "Apple Subscription", true),
        ("icloud", "iCloud+", true),
        ("youtube", "YouTube Premium", true),
        ("shahid", "Shahid", true),
        ("osn", "OSN+", true),
        ("disney", "Disney+", true),
        ("bein", "beIN", true),
        ("amazon prime", "Amazon Prime", true),
        ("prime video", "Prime Video", true),
        ("openai", "ChatGPT", true),
        ("chatgpt", "ChatGPT", true),
        ("claude", "Claude", true),
        ("anthropic", "Claude", true),
        ("adobe", "Adobe", true),
        ("microsoft", "Microsoft 365", true),
        ("office 365", "Microsoft 365", true),
        ("google one", "Google One", true),
        ("google storage", "Google One", true),
        ("dropbox", "Dropbox", true),
        ("canva", "Canva", true),
        ("notion", "Notion", true),
        ("github", "GitHub", true),
        ("playstation", "PlayStation", true),
        ("xbox", "Xbox", true),
        ("anghami", "Anghami", true),
        ("fitness first", "Fitness First", true),
        ("gym", "Gym Membership", true),
        ("insurance", "Insurance", false),
        ("takaful", "Takaful Insurance", false),
        ("rent", "Rent", false),
        ("fiber", "Fiber Internet", true),
        ("broadband", "Broadband", true),
        ("internet", "Internet", true)
    ]

    // MARK: 1. Signal Extraction

    static func extractSignal(
        from tx: MoneyTransaction,
        currency: String = UserDefaults.standard.string(forKey: Keys.currency) ?? "BHD"
    ) -> SMSSubscriptionSignal {
        let raw = tx.rawText ?? ""
        let rawLower = raw.lowercased()
        let merchantNorm = normalizeText(tx.merchant)
        let provider = inferProvider(merchant: tx.merchant, rawText: raw)
        let tokens = extractIdentifierTokens(reference: tx.smsReference, rawText: raw)

        return SMSSubscriptionSignal(
            provider: provider,
            merchantNormalized: merchantNorm,
            amount: tx.amount,
            currency: currency,
            transactionType: tx.effectiveTransactionType,
            date: tx.date,
            referenceNumber: tx.smsReference?.trimmingCharacters(in: .whitespacesAndNewlines),
            identifierTokens: tokens,
            rawTextLower: rawLower
        )
    }

    static func normalizeText(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9\\u0600-\\u06FF\\s\\.]", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func inferProvider(merchant: String, rawText: String = "", explicitProvider: String = "") -> String {
        let explicit = normalizeText(explicitProvider)
        if !explicit.isEmpty { return explicit }

        let combined = "\(normalizeText(merchant)) \(normalizeText(rawText))"
        for entry in knownBillProviders {
            if combined.contains(entry.keyword) {
                return entry.keyword
            }
        }

        let words = normalizeText(merchant)
            .split(separator: " ")
            .map(String.init)
            .filter { $0.count >= 2 && !ignoredTokens.contains($0) && Int($0) == nil }
        return words.first ?? normalizeText(merchant)
    }

    /// Extracts unique identifiers (reference number, subscriber/account/plan IDs) from SMS text.
    static func extractIdentifierTokens(reference: String?, rawText: String) -> [String] {
        var result: [String] = []
        if let ref = reference?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !ref.isEmpty {
            result.append(ref)
        }

        let patterns = [
            "(?i)(?:sub(?:scriber)?|acct|account|inv(?:oice)?|bill|line|mobile|plan|pkg|package|contract|id)\\s*(?:no\\.?|number|#|:)?\\s*([a-z0-9\\-]{4,18})",
            "(?i)\\b(pkg\\d+|pack\\d+|plan\\d+)\\b"
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let nsRange = NSRange(rawText.startIndex..., in: rawText)
            for match in regex.matches(in: rawText, range: nsRange) {
                if match.numberOfRanges > 1, let r = Range(match.range(at: 1), in: rawText) {
                    let token = String(rawText[r]).lowercased()
                    if !token.isEmpty && !result.contains(token) {
                        result.append(token)
                    }
                }
            }
        }
        return result
    }

    // MARK: 2. Provider Candidate Search

    /// Finds all active (unpaid in the current billing cycle) bills/subscriptions belonging to the same provider.
    static func findProviderCandidates(
        signal: SMSSubscriptionSignal,
        bills: [Bill],
        store: SubscriptionLearningStore = .shared
    ) -> [Bill] {
        bills.filter { bill in
            guard !bill.isPaidForCurrentCycle(now: signal.date) else { return false }
            let billProvider = providerForBill(bill)
            let billNorm = normalizeText(bill.name)
            guard !billNorm.isEmpty else { return false }

            // Same provider match
            if !signal.provider.isEmpty && !billProvider.isEmpty && signal.provider == billProvider {
                return true
            }
            // Custom keywords match
            let customMatch = bill.keywords.contains { kw in
                let clean = normalizeText(kw)
                guard !clean.isEmpty else { return false }
                return signal.merchantNormalized.contains(clean)
                    || (!signal.rawTextLower.isEmpty && signal.rawTextLower.contains(clean))
                    || signal.identifierTokens.contains(where: { $0.contains(clean) || clean.contains($0) })
            }
            if customMatch { return true }

            // Significant token overlap between bill name and merchant/SMS
            let billTokens = significantTokens(from: bill.name)
            if billTokens.contains(where: { signal.merchantNormalized.contains($0) || signal.rawTextLower.contains($0) }) {
                return true
            }

            // Learned positive rule match
            let rules = store.matchingPositiveRules(for: bill.id)
            if rules.contains(where: {
                (!signal.merchantNormalized.isEmpty && $0.merchantNormalized == signal.merchantNormalized)
                || (!signal.provider.isEmpty && $0.providerNormalized == signal.provider)
            }) {
                return true
            }

            return false
        }
    }

    static func providerForBill(_ bill: Bill) -> String {
        if !bill.providerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return normalizeText(bill.providerName)
        }
        let kwText = bill.keywords.joined(separator: " ")
        return inferProvider(merchant: bill.name, rawText: kwText)
    }

    private static func significantTokens(from text: String) -> [String] {
        normalizeText(text)
            .split(separator: " ")
            .map(String.init)
            .filter { $0.count >= 3 && !ignoredTokens.contains($0) && Int($0) == nil }
    }

    // MARK: 3. Weighted Scoring System

    static func scoreCandidate(
        bill: Bill,
        signal: SMSSubscriptionSignal,
        history: [MoneyTransaction],
        store: SubscriptionLearningStore = .shared
    ) -> SubscriptionScoreBreakdown {
        // 1. Provider / merchant / custom keyword match (0.0 ... 1.0)
        let providerScore: Double = {
            let billNorm = normalizeText(bill.name)
            let billProvider = providerForBill(bill)

            if !billNorm.isEmpty && (signal.merchantNormalized == billNorm || signal.merchantNormalized.contains(billNorm) || signal.rawTextLower.contains(billNorm)) {
                return 1.0
            }
            let customHit = bill.keywords.contains { kw in
                let clean = normalizeText(kw)
                return !clean.isEmpty && (signal.merchantNormalized.contains(clean) || signal.rawTextLower.contains(clean))
            }
            if customHit { return 0.92 }
            if !signal.provider.isEmpty && signal.provider == billProvider {
                return 0.85
            }
            let billTokens = significantTokens(from: bill.name)
            let overlap = billTokens.filter { signal.merchantNormalized.contains($0) || signal.rawTextLower.contains($0) }
            if !overlap.isEmpty {
                return min(0.8, 0.55 + 0.15 * Double(overlap.count))
            }
            return 0.0
        }()

        // 2. Exact or approximate amount match (0.0 ... 1.0)
        let amountScore: Double = {
            guard bill.amount > 0, signal.amount > 0 else { return 0.0 }
            let diff = abs(signal.amount - bill.amount)
            let relDiff = diff / max(bill.amount, 0.001)

            if diff <= 0.01 { return 1.0 }
            // Possible price increase/decrease (e.g. 7 BHD -> 8 BHD = 14.3% / 1 BHD)
            if relDiff <= 0.20 || diff <= 2.0 {
                let ratio = min(relDiff / 0.20, diff / 2.0)
                return max(0.50, 0.88 - 0.35 * ratio)
            }
            if relDiff <= 0.35 || diff <= 3.5 {
                let ratio = min((relDiff - 0.20) / 0.15, (diff - 2.0) / 1.5)
                return max(0.18, 0.45 - 0.25 * max(0, ratio))
            }
            return 0.0
        }()

        // 3. Historical payment patterns (0.0 ... 1.0)
        let historyScore: Double = {
            let pastForBill = history.filter { $0.billID == bill.id && !$0.isPending }
            var pastAmounts = pastForBill.map(\.amount)
            if let lastAmt = bill.lastPaidAmount, lastAmt > 0 {
                pastAmounts.append(lastAmt)
            }
            guard !pastAmounts.isEmpty else { return 0.0 }

            let avg = pastAmounts.reduce(0, +) / Double(pastAmounts.count)
            let diff = abs(signal.amount - avg)
            let rel = diff / max(avg, 0.001)
            if diff <= 0.01 { return 1.0 }
            if rel <= 0.18 || diff <= 1.5 { return 0.75 }
            if rel <= 0.30 || diff <= 3.0 { return 0.40 }
            return 0.10
        }()

        // 4. Previous user-confirmed subscription matches (0.0 ... 1.0)
        let confirmedRuleScore: Double = {
            let rules = store.matchingPositiveRules(for: bill.id)
            guard !rules.isEmpty else { return 0.0 }

            var best = 0.0
            for rule in rules {
                let merchantMatch = !signal.merchantNormalized.isEmpty && rule.merchantNormalized == signal.merchantNormalized
                let providerMatch = !signal.provider.isEmpty && rule.providerNormalized == signal.provider
                guard merchantMatch || providerMatch else { continue }

                var s = merchantMatch ? 0.65 : 0.40
                if rule.confirmedAmounts.contains(where: { abs($0 - signal.amount) <= max(1.5, $0 * 0.18) }) {
                    s += 0.25
                }
                if let typicalDay = rule.typicalDayOfMonth {
                    let txDay = Calendar.current.component(.day, from: signal.date)
                    if dayDistance(txDay, typicalDay) <= 5 {
                        s += 0.10
                    }
                }
                best = max(best, min(1.0, s))
            }
            return best
        }()

        // 5. Transaction reference or unique identifiers (0.0 ... 1.0)
        let referenceScore: Double = {
            let hints = bill.referenceHints.map { $0.lowercased() }
            let ruleTokens = store.matchingPositiveRules(for: bill.id).flatMap(\.referenceTokens)
            let allHints = Set(hints + ruleTokens)
            guard !allHints.isEmpty, !signal.identifierTokens.isEmpty else { return 0.0 }

            for token in signal.identifierTokens {
                if allHints.contains(token) { return 1.0 }
                if allHints.contains(where: { $0.count >= 4 && (token.contains($0) || $0.contains(token)) }) {
                    return 0.75
                }
            }
            return 0.0
        }()

        // 6. Subscription billing frequency and date proximity (0.0 ... 1.0)
        let scheduleScore: Double = {
            let days = abs(Calendar.current.dateComponents([.day], from: signal.date, to: bill.nextDueDate).day ?? 999)
            let window: Int
            switch bill.frequency {
            case .weekly: window = 3
            case .monthly: window = 8
            case .quarterly: window = 14
            case .yearly: window = 21
            }
            if days <= 2 { return 1.0 }
            if days <= window { return max(0.35, 1.0 - (Double(days) / Double(window)) * 0.65) }
            // Also check same day-of-month for monthly subscriptions (e.g. paid early/late)
            if bill.frequency == .monthly {
                let dueDay = Calendar.current.component(.day, from: bill.nextDueDate)
                let txDay = Calendar.current.component(.day, from: signal.date)
                if dayDistance(txDay, dueDay) <= 5 { return 0.60 }
            }
            return 0.0
        }()

        return SubscriptionScoreBreakdown(
            providerScore: providerScore,
            amountScore: amountScore,
            historyScore: historyScore,
            confirmedRuleScore: confirmedRuleScore,
            referenceScore: referenceScore,
            scheduleScore: scheduleScore
        )
    }

    private static func dayDistance(_ d1: Int, _ d2: Int) -> Int {
        let raw = abs(d1 - d2)
        return min(raw, 30 - raw)
    }

    // MARK: 4. Duplicate Prevention

    /// Checks whether a transaction is a duplicate of an already-recorded bill/subscription payment
    /// using reference number, identifier tokens, or same-day identical amount + provider.
    static func findDuplicatePayment(
        for tx: MoneyTransaction,
        signal: SMSSubscriptionSignal,
        existingTransactions: [MoneyTransaction]
    ) -> MoneyTransaction? {
        for other in existingTransactions where other.id != tx.id {
            // 1. Exact reference number match
            if let ref = signal.referenceNumber, !ref.isEmpty,
               let otherRef = other.smsReference?.trimmingCharacters(in: .whitespacesAndNewlines), !otherRef.isEmpty,
               ref.caseInsensitiveCompare(otherRef) == .orderedSame {
                return other
            }
            // 2. Same provider + exact amount + within 24 hours (when linked to a bill)
            if other.billID != nil,
               abs(other.amount - tx.amount) < 0.005,
               abs(other.date.timeIntervalSince(tx.date)) <= 86400 {
                let otherProvider = inferProvider(merchant: other.merchant, rawText: other.rawText ?? "")
                if !signal.provider.isEmpty && signal.provider == otherProvider {
                    return other
                }
            }
        }
        return nil
    }

    // MARK: 5. Full Evaluation & Application

    static func evaluate(
        tx: MoneyTransaction,
        bills: [Bill],
        history: [MoneyTransaction],
        currency: String = UserDefaults.standard.string(forKey: Keys.currency) ?? "BHD",
        store: SubscriptionLearningStore = .shared,
        aiDetectedBill: Bool = false
    ) -> SubscriptionMatchOutcome {
        guard !tx.isIncome, tx.amount > 0, !tx.isTransfer else { return .noMatch }

        let signal = extractSignal(from: tx, currency: currency)

        // Prevent duplicate bill payments
        if let dup = findDuplicatePayment(for: tx, signal: signal, existingTransactions: history) {
            return .duplicate(existingTxID: dup.id)
        }

        // Search all active subscriptions belonging to the same provider
        let candidates = findProviderCandidates(signal: signal, bills: bills, store: store)

        let scored: [(bill: Bill, breakdown: SubscriptionScoreBreakdown, total: Double)] = candidates
            .map { bill in
                let bd = scoreCandidate(bill: bill, signal: signal, history: history, store: store)
                return (bill, bd, bd.totalScore)
            }
            .filter { $0.breakdown.passesMultiSignalGate && $0.total >= minimumMatchScore }
            .sorted { lhs, rhs in
                if abs(lhs.total - rhs.total) > 0.001 { return lhs.total > rhs.total }
                // Tie-breaker: closer amount to expected subscription price
                return abs(lhs.bill.amount - signal.amount) < abs(rhs.bill.amount - signal.amount)
            }

        if let best = scored.first {
            // If two subscriptions from the same provider have virtually identical scores AND identical expected amounts
            // with no distinguishing reference/rule signal, avoid guessing blindly.
            if scored.count > 1 {
                let second = scored[1]
                let nearlyTied = abs(best.total - second.total) < 0.02
                let sameExpected = abs(best.bill.amount - second.bill.amount) < 0.01
                if nearlyTied && sameExpected && best.breakdown.referenceScore == 0 && best.breakdown.confirmedRuleScore == 0 {
                    return .noMatch
                }
            }

            let priceChange: SubscriptionPriceChange
            let delta = tx.amount - best.bill.amount
            if best.bill.amount > 0 && delta >= 0.005 {
                priceChange = .increased(expected: best.bill.amount, actual: tx.amount)
            } else if best.bill.amount > 0 && delta <= -0.005 {
                priceChange = .decreased(expected: best.bill.amount, actual: tx.amount)
            } else {
                priceChange = .unchanged
            }

            let reason: String
            switch priceChange {
            case .unchanged:
                reason = "Matched \(best.bill.name) (exact amount)"
            case .increased(let expected, let actual):
                reason = "Matched \(best.bill.name) · Possible price increase (\(Money.format(expected, currency)) → \(Money.format(actual, currency)))"
            case .decreased(let expected, let actual):
                reason = "Matched \(best.bill.name) · Price decreased (\(Money.format(expected, currency)) → \(Money.format(actual, currency)))"
            }

            return .matched(
                bill: best.bill,
                score: best.total,
                breakdown: best.breakdown,
                priceChange: priceChange,
                reason: reason
            )
        }

        // No existing bill matched -> check if this should be flagged in Review to add as a new recurring bill
        if !store.isRejected(signal: signal),
           let detection = detectUnregisteredBillOrSubscription(tx: tx, signal: signal, history: history, aiDetectedBill: aiDetectedBill) {
            return .suggestNewBill(
                provider: detection.provider,
                suggestedName: detection.suggestedName,
                isSubscription: detection.isSubscription,
                reason: detection.reason
            )
        }

        return .noMatch
    }

    /// Runs the engine against a transaction inside `ModelContext`, marking matched bills paid
    /// or flagging unregistered bills/subscriptions for Review.
    @discardableResult
    static func matchAndApply(
        tx: MoneyTransaction,
        context: ModelContext,
        currency: String = UserDefaults.standard.string(forKey: Keys.currency) ?? "BHD",
        store: SubscriptionLearningStore = .shared,
        aiDetectedBill: Bool = false
    ) -> Bill? {
        guard !tx.isIncome, tx.amount > 0, !tx.isTransfer else { return nil }
        let bills = (try? context.fetch(FetchDescriptor<Bill>())) ?? []
        let history = (try? context.fetch(FetchDescriptor<MoneyTransaction>())) ?? []

        let outcome = evaluate(
            tx: tx,
            bills: bills,
            history: history,
            currency: currency,
            store: store,
            aiDetectedBill: aiDetectedBill
        )

        switch outcome {
        case .matched(let bill, let score, _, _, let reason):
            bill.markPaid(date: tx.date, method: .autoSMS, amount: tx.amount, txID: tx.id)
            tx.billID = bill.id
            tx.billExpectedAmount = bill.amount
            tx.billMatchConfidence = score
            tx.billMatchReason = reason
            tx.billReviewStatusRaw = "confirmedBill"
            if tx.category == .bills || tx.category == .other || tx.category == .subscriptions {
                tx.category = bill.category
            }
            try? context.save()
            Notifier.rescheduleBills(bills)
            return bill

        case .suggestNewBill(_, _, _, let reason):
            if tx.billID == nil && tx.billReviewStatusRaw.isEmpty {
                tx.billReviewStatusRaw = "suggestedNewBill"
                tx.billMatchReason = reason
                try? context.save()
            }
            return nil

        case .duplicate:
            tx.isPossibleDuplicate = true
            try? context.save()
            return nil

        case .noMatch:
            return nil
        }
    }

    // MARK: 6. Unregistered Bill / Subscription Detection

    private static func detectUnregisteredBillOrSubscription(
        tx: MoneyTransaction,
        signal: SMSSubscriptionSignal,
        history: [MoneyTransaction],
        aiDetectedBill: Bool
    ) -> (provider: String, suggestedName: String, isSubscription: Bool, reason: String)? {
        // 1. Known bill/subscription provider match from app catalog
        let combined = "\(signal.merchantNormalized) \(signal.rawTextLower)"
        for entry in knownBillProviders {
            if combined.contains(entry.keyword) {
                return (
                    provider: entry.keyword,
                    suggestedName: entry.displayName,
                    isSubscription: entry.isSubscription,
                    reason: "Detected recurring \(entry.isSubscription ? "subscription" : "bill") provider (\(entry.displayName))"
                )
            }
        }

        // 2. Transaction already categorized as Bills or Subscriptions
        if tx.category == .bills || tx.category == .subscriptions {
            let cleanName = tx.merchant.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanName.isEmpty, cleanName.lowercased() != "card purchase", cleanName.lowercased() != "expense" else {
                return nil
            }
            let isSub = tx.category == .subscriptions
            return (
                provider: signal.provider,
                suggestedName: cleanName,
                isSubscription: isSub,
                reason: "Categorized as \(tx.category.title) — add as recurring \(isSub ? "subscription" : "bill")?"
            )
        }

        // 3. Recurring payment pattern in history (same merchant paid in a prior month with similar amount)
        if !signal.merchantNormalized.isEmpty {
            let priorMatches = history.filter { other in
                other.id != tx.id
                && !other.isPending
                && !other.isIncome
                && normalizeText(other.merchant) == signal.merchantNormalized
                && abs(other.date.timeIntervalSince(tx.date)) >= 18 * 86400
                && abs(other.amount - tx.amount) <= max(2.0, tx.amount * 0.25)
            }
            if !priorMatches.isEmpty {
                return (
                    provider: signal.provider,
                    suggestedName: tx.merchant,
                    isSubscription: true,
                    reason: "Recurring payment pattern detected for \(tx.merchant)"
                )
            }
        }

        // 4. AI identified the merchant as a recurring bill or subscription
        if aiDetectedBill {
            let cleanName = tx.merchant.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanName.isEmpty else { return nil }
            return (
                provider: signal.provider,
                suggestedName: cleanName,
                isSubscription: true,
                reason: "AI identified \(cleanName) as a recurring bill or subscription"
            )
        }

        return nil
    }

    // MARK: 7. User Confirmation, Correction & Rejection (Learning Loop)

    /// Confirms an unmatched transaction as a brand-new recurring bill/subscription and saves a learning rule.
    @discardableResult
    static func confirmAsNewRecurringBill(
        tx: MoneyTransaction,
        name: String? = nil,
        isSubscription: Bool = true,
        frequency: BillFrequency = .monthly,
        category: SpendCategory? = nil,
        context: ModelContext,
        store: SubscriptionLearningStore = .shared
    ) -> Bill {
        let signal = extractSignal(from: tx)
        let billName = (name?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            ?? tx.merchant.trimmingCharacters(in: .whitespacesAndNewlines)
        let billCategory = category ?? (isSubscription ? .subscriptions : .bills)

        let nextDue = frequency.next(after: tx.date)
        let keywords = Array(Set([billName, tx.merchant, signal.provider].filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }))
            .joined(separator: ", ")

        let newBill = Bill(
            name: billName,
            amount: tx.amount,
            category: billCategory,
            nextDueDate: nextDue,
            frequency: frequency,
            isSubscription: isSubscription,
            keywords: keywords,
            providerName: signal.provider
        )
        newBill.referenceHints = signal.identifierTokens
        newBill.markPaid(date: tx.date, method: tx.source == .sms ? .autoSMS : .manual, amount: tx.amount, txID: tx.id)
        context.insert(newBill)

        tx.billID = newBill.id
        tx.billExpectedAmount = newBill.amount
        tx.billMatchConfidence = 1.0
        tx.billMatchReason = "Confirmed and added as recurring \(isSubscription ? "subscription" : "bill")"
        tx.billReviewStatusRaw = "confirmedBill"
        if tx.category == .other {
            tx.category = billCategory
        }

        store.recordConfirmation(bill: newBill, signal: signal)

        try? context.save()
        let allBills = (try? context.fetch(FetchDescriptor<Bill>())) ?? []
        Notifier.rescheduleBills(allBills)
        Ledger.notifyDataChanged()
        return newBill
    }

    /// Links a transaction to an existing bill/subscription (or corrects a wrong match) and saves a learning rule.
    static func confirmExistingBill(
        tx: MoneyTransaction,
        bill: Bill,
        context: ModelContext,
        store: SubscriptionLearningStore = .shared
    ) {
        let allBills = (try? context.fetch(FetchDescriptor<Bill>())) ?? []
        // If previously linked to a different bill whose lastPaidTxID was this transaction, unmark that bill
        if let oldBillID = tx.billID, oldBillID != bill.id,
           let oldBill = allBills.first(where: { $0.id == oldBillID }),
           oldBill.lastPaidTxID == tx.id {
            oldBill.unmarkPaid()
        }

        let signal = extractSignal(from: tx)
        if bill.providerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !signal.provider.isEmpty {
            bill.providerName = signal.provider
        }
        var hints = bill.referenceHints
        for token in signal.identifierTokens where !hints.contains(token) {
            hints.append(token)
        }
        bill.referenceHints = Array(hints.suffix(12))

        bill.markPaid(date: tx.date, method: tx.source == .sms ? .autoSMS : .manual, amount: tx.amount, txID: tx.id)

        tx.billID = bill.id
        tx.billExpectedAmount = bill.amount
        tx.billMatchConfidence = 1.0
        tx.billMatchReason = "Confirmed match for \(bill.name)"
        tx.billReviewStatusRaw = "confirmedBill"

        store.recordConfirmation(bill: bill, signal: signal)

        try? context.save()
        Notifier.rescheduleBills(allBills)
        Ledger.notifyDataChanged()
    }

    /// Rejects a bill/subscription suggestion and remembers the decision so this merchant isn't suggested again.
    static func rejectBillSuggestion(
        tx: MoneyTransaction,
        context: ModelContext,
        store: SubscriptionLearningStore = .shared
    ) {
        let signal = extractSignal(from: tx)
        tx.billReviewStatusRaw = "rejectedBill"
        tx.billMatchReason = ""
        store.recordRejection(signal: signal)
        try? context.save()
        Ledger.notifyDataChanged()
    }
}
