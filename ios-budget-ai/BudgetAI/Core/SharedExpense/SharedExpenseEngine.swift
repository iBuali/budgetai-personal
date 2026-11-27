import Foundation
import SwiftData

// MARK: - AI Provider Protocol (Gemini + Deterministic Testable Fallback)

struct SharedExpenseAIExpenseContext: Sendable {
    let transactionID: UUID
    let merchant: String
    let categoryRaw: String
    let amount: Double
    let currency: String
    let date: Date
    let note: String
    let categoryMedianAmount: Double?
    let categorySampleCount: Int
    let merchantMedianAmount: Double?
    let merchantSampleCount: Int
    let confirmedSharedCountForMerchant: Int
    let rejectedCountForMerchant: Int
    let confirmedPersonalCountForMerchant: Int
    let averagePersonalRatio: Double?
}

struct SharedExpenseAIExpenseAssessment: Sendable {
    let sharedProbability: Double
    let estimatedPersonalAmount: Double
    let estimatedReimbursableAmount: Double
    let confidence: Double
    let explanation: String
    let suggestedCategoryRaw: String
}

struct SharedExpenseAIReimbursementCandidate: Sendable {
    let expenseID: UUID
    let merchant: String
    let categoryRaw: String
    let expenseAmount: Double
    let expenseDate: Date
    let priorSharedProbability: Double?
    let outstandingReimbursableAmount: Double?
    let hasActiveSharedAdjustment: Bool
}

struct SharedExpenseAIReimbursementContext: Sendable {
    let incomingID: UUID
    let incomingAmount: Double
    let availableCapacity: Double
    let incomingDate: Date
    let incomingCategoryRaw: String
    let incomingNote: String
    let hasKnownSenderPattern: Bool
    let knownSenderConfirmationCount: Int
    let candidates: [SharedExpenseAIReimbursementCandidate]
}

struct SharedExpenseAIReimbursementLink: Sendable {
    let expenseID: UUID
    let allocatedAmount: Double
}

struct SharedExpenseAIReimbursementAssessment: Sendable {
    let links: [SharedExpenseAIReimbursementLink]
    let confidence: Double
    let explanation: String
}

protocol SharedExpenseAIProvider: Sendable {
    func assessExpense(_ context: SharedExpenseAIExpenseContext) async -> SharedExpenseAIExpenseAssessment?
    func assessReimbursement(_ context: SharedExpenseAIReimbursementContext) async -> SharedExpenseAIReimbursementAssessment?
}

/// Live Gemini provider using structured JSON output. Returns `nil` when Gemini is unconfigured
/// or unreachable so deterministic local intelligence can still operate safely.
struct GeminiSharedExpenseAIProvider: SharedExpenseAIProvider {
    func assessExpense(_ context: SharedExpenseAIExpenseContext) async -> SharedExpenseAIExpenseAssessment? {
        guard GeminiAccount.isConfigured, let client = try? GeminiAccount.client() else { return nil }
        let categories = SpendCategory.expenseCases.map(\.rawValue)
        let schema: [String: Any] = [
            "type": "OBJECT",
            "properties": [
                "sharedProbability": ["type": "NUMBER"],
                "estimatedPersonalAmount": ["type": "NUMBER"],
                "estimatedReimbursableAmount": ["type": "NUMBER"],
                "confidence": ["type": "NUMBER"],
                "explanation": ["type": "STRING"],
                "suggestedCategory": ["type": "STRING", "enum": categories]
            ],
            "required": ["sharedProbability", "estimatedPersonalAmount", "estimatedReimbursableAmount", "confidence", "explanation", "suggestedCategory"]
        ]
        let system = """
        You are FALAK's Shared Expense Intelligence analyzer.
        Estimate whether an expense transaction may be a shared expense paid on behalf of a group or another person.
        CRITICAL RULES:
        - Never assume every large transaction is a shared expense.
        - Respect the user's historical median spending and prior confirmed personal or rejected patterns.
        - Without a linked reimbursement, confidence must stay below 0.80 (never trigger silent auto-adjustment from a single expense alone).
        - Ensure estimatedPersonalAmount + estimatedReimbursableAmount == amount, both >= 0.
        """
        let catMedianStr = context.categoryMedianAmount.map { String(format: "%.3f", $0) } ?? "unknown"
        let merchMedianStr = context.merchantMedianAmount.map { String(format: "%.3f", $0) } ?? "unknown"
        let prompt = """
        Merchant: \(context.merchant)
        Category: \(context.categoryRaw)
        Amount: \(String(format: "%.3f", context.amount)) \(context.currency)
        Note: \(context.note.isEmpty ? "none" : context.note)
        Category historical median: \(catMedianStr) (\(context.categorySampleCount) past transactions)
        Merchant historical median: \(merchMedianStr) (\(context.merchantSampleCount) past transactions)
        Confirmed shared history at merchant: \(context.confirmedSharedCountForMerchant)
        Rejected suggestion history at merchant: \(context.rejectedCountForMerchant)
        Confirmed personal history at merchant: \(context.confirmedPersonalCountForMerchant)
        """
        guard let reply = try? await client.generate(system: system, turns: [GeminiTurn(isUser: true, text: prompt)], schema: schema, temperature: 0.1),
              let obj = try? GeminiClient.decodeObject(reply),
              let prob = (obj["sharedProbability"] as? NSNumber)?.doubleValue,
              let conf = (obj["confidence"] as? NSNumber)?.doubleValue,
              let explanation = obj["explanation"] as? String else {
            return nil
        }
        let rawPersonal = (obj["estimatedPersonalAmount"] as? NSNumber)?.doubleValue ?? context.amount
        let rawReimb = (obj["estimatedReimbursableAmount"] as? NSNumber)?.doubleValue ?? 0
        let clampedReimb = min(context.amount, max(0, rawReimb))
        let clampedPersonal = max(0, context.amount - clampedReimb)
        let cat = (obj["suggestedCategory"] as? String) ?? context.categoryRaw
        return SharedExpenseAIExpenseAssessment(
            sharedProbability: min(1, max(0, prob)),
            estimatedPersonalAmount: rawPersonal >= 0 && abs((rawPersonal + clampedReimb) - context.amount) <= 0.02 ? rawPersonal : clampedPersonal,
            estimatedReimbursableAmount: clampedReimb,
            confidence: min(0.79, max(0, conf)), // Expense alone cannot bypass reimbursement validation
            explanation: explanation.trimmingCharacters(in: .whitespacesAndNewlines),
            suggestedCategoryRaw: cat
        )
    }

    func assessReimbursement(_ context: SharedExpenseAIReimbursementContext) async -> SharedExpenseAIReimbursementAssessment? {
        guard !context.candidates.isEmpty, GeminiAccount.isConfigured, let client = try? GeminiAccount.client() else { return nil }
        let schema: [String: Any] = [
            "type": "OBJECT",
            "properties": [
                "links": [
                    "type": "ARRAY",
                    "items": [
                        "type": "OBJECT",
                        "properties": [
                            "expenseID": ["type": "STRING"],
                            "allocatedAmount": ["type": "NUMBER"]
                        ],
                        "required": ["expenseID", "allocatedAmount"]
                    ]
                ],
                "confidence": ["type": "NUMBER"],
                "explanation": ["type": "STRING"]
            ],
            "required": ["links", "confidence", "explanation"]
        ]
        let system = """
        You are FALAK's Reimbursement Relationship matcher.
        Given an incoming transfer and recent eligible expenses, identify whether the transfer is a reimbursement for one or more of those expenses.
        CRITICAL RULES:
        - Do not match unrelated transfers based only on amount or timing.
        - Return an empty links array if there is insufficient corroborating evidence.
        - Sum of allocatedAmount across links must not exceed availableCapacity.
        """
        let candLines = context.candidates.map { c in
            let daysAgo = max(0, context.incomingDate.timeIntervalSince(c.expenseDate) / 86_400)
            let priorStr = c.priorSharedProbability.map { String(format: "%.2f", $0) } ?? "none"
            let outStr = c.outstandingReimbursableAmount.map { String(format: "%.3f", $0) } ?? "unknown"
            return "- ID=\(c.expenseID.uuidString) | merchant=\(c.merchant) | cat=\(c.categoryRaw) | amount=\(String(format: "%.3f", c.expenseAmount)) | daysAgo=\(String(format: "%.1f", daysAgo)) | priorSharedProb=\(priorStr) | outstanding=\(outStr) | activeShared=\(c.hasActiveSharedAdjustment)"
        }.joined(separator: "\n")
        let prompt = """
        Incoming Transfer: amount=\(String(format: "%.3f", context.incomingAmount)), availableCapacity=\(String(format: "%.3f", context.availableCapacity)), category=\(context.incomingCategoryRaw), note=\(context.incomingNote.isEmpty ? "none" : context.incomingNote), knownReimbursementSender=\(context.hasKnownSenderPattern) (confirmations=\(context.knownSenderConfirmationCount))
        Candidate Expenses:
        \(candLines)
        """
        guard let reply = try? await client.generate(system: system, turns: [GeminiTurn(isUser: true, text: prompt)], schema: schema, temperature: 0.1),
              let obj = try? GeminiClient.decodeObject(reply),
              let conf = (obj["confidence"] as? NSNumber)?.doubleValue,
              let explanation = obj["explanation"] as? String else {
            return nil
        }
        let rawLinks = obj["links"] as? [[String: Any]] ?? []
        let links: [SharedExpenseAIReimbursementLink] = rawLinks.compactMap { item in
            guard let idStr = item["expenseID"] as? String,
                  let uuid = UUID(uuidString: idStr),
                  let amt = (item["allocatedAmount"] as? NSNumber)?.doubleValue,
                  amt > SharedExpenseFinancialValidator.epsilon else { return nil }
            return SharedExpenseAIReimbursementLink(expenseID: uuid, allocatedAmount: amt)
        }
        return SharedExpenseAIReimbursementAssessment(
            links: links,
            confidence: min(1, max(0, conf)),
            explanation: explanation.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}

// MARK: - Eligibility & Signal Classification Helpers

enum SharedExpenseClassifier {
    /// Core focus categories for Shared Expense Intelligence.
    static let focusCategoryKeys: Set<String> = [
        SpendCategory.dining.rawValue,
        SpendCategory.groceries.rawValue,
        SpendCategory.travel.rawValue,
        SpendCategory.shopping.rawValue,
        SpendCategory.entertainment.rawValue
    ]

    private static let diningKeywords = [
        "restaurant", "cafe", "coffee", "bistro", "grill", "kitchen", "bakery", "diner",
        "pizza", "burger", "sushi", "shawarma", "talabat", "jahez", "deliveroo",
        "starbucks", "costa", "caribou", "lumee", "maki", "nandos", "chilis", "مطعم", "كافيه", "قهوة"
    ]
    private static let groceryKeywords = [
        "supermarket", "hypermarket", "grocery", "lulu", "carrefour", "aljazira", "danube",
        "tamimi", "mega mart", "nesto", "ramez", "سوبرماركت", "بقالة", "تموينات"
    ]
    private static let travelKeywords = [
        "hotel", "resort", "airbnb", "booking", "airline", "airways", "gulf air", "emirates",
        "flight", "expedia", "agoda", "فندق", "طيران", "سفر"
    ]
    private static let entertainmentKeywords = [
        "cinema", "vox", "cineco", "bowling", "arcade", "ticket", "event", "concert",
        "park", "karting", "padel", "escape", "سينما", "تذاكر"
    ]
    private static let shoppingKeywords = [
        "mall", "store", "shop", "ikea", "zara", "hm", "sephora", "apple", "amazon", "noon", "متجر"
    ]

    private static let sharedNoteKeywords = [
        "split", "shared", "group", "friends", "colleagues", "team", "dinner with", "lunch with",
        "with friends", "for everyone", "we ate", "reimburse", "pay me back", "owed", "قطة", "مشترك", "الشباب", "مع الربع"
    ]

    private static let refundKeywords = [
        "refund", "reversal", "reversed", "chargeback", "cashback", "credit memo",
        "return credit", "cancelled order", "canceled order", "مرتجع", "استرجاع", "استرداد"
    ]

    private static let salaryIncomeKeywords = [
        "salary", "payroll", "wages", "stipend", "dividend", "pension", "allowance",
        "bonus", "commission", "راتب", "مكافأة", "علاوة"
    ]

    private static let reimbursementNoteKeywords = [
        "dinner", "lunch", "food", "coffee", "cafe", "split", "share", "reimburse", "reimbursement",
        "bill", "trip", "hotel", "grocery", "groceries", "cinema", "padel", "ticket", "owed",
        "thanks for", "my share", "for last night", "عشاء", "غداء", "قطة", "حساب", "قهوة"
    ]

    static func inferFocusCategoryRaw(for tx: MoneyTransaction) -> String? {
        if focusCategoryKeys.contains(tx.categoryRaw) {
            return tx.categoryRaw
        }
        let text = "\(tx.merchant) \(tx.note)".lowercased()
        if diningKeywords.contains(where: { text.contains($0) }) { return SpendCategory.dining.rawValue }
        if groceryKeywords.contains(where: { text.contains($0) }) { return SpendCategory.groceries.rawValue }
        if travelKeywords.contains(where: { text.contains($0) }) { return SpendCategory.travel.rawValue }
        if entertainmentKeywords.contains(where: { text.contains($0) }) { return SpendCategory.entertainment.rawValue }
        if shoppingKeywords.contains(where: { text.contains($0) }) { return SpendCategory.shopping.rawValue }
        return nil
    }

    static func hasMissingContext(_ tx: MoneyTransaction) -> Bool {
        let trimmedMerchant = tx.merchant.trimmingCharacters(in: .whitespacesAndNewlines)
        let genericNames: Set<String> = [
            "", "unknown", "expense", "transaction", "card purchase", "pos", "purchase",
            "transfer", "bank transfer", "fawri+ transfer", "fawri transfer", "other", "payment"
        ]
        let merchantIsGeneric = genericNames.contains(trimmedMerchant.lowercased())
        let noteIsEmpty = tx.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return merchantIsGeneric && noteIsEmpty && !focusCategoryKeys.contains(tx.categoryRaw)
    }

    static func isEligibleExpense(_ tx: MoneyTransaction) -> Bool {
        guard !tx.isPending, tx.amount > SharedExpenseFinancialValidator.epsilon else { return false }
        guard tx.isSpending, !tx.isIncome, !tx.isTransfer else { return false }
        guard tx.source != .bill, tx.billID == nil else { return false }
        guard tx.smsTransactionType != .refund, tx.smsTransactionType != .fee, tx.smsTransactionType != .internalTransfer else { return false }
        guard !hasMissingContext(tx) else { return false }
        return inferFocusCategoryRaw(for: tx) != nil
    }

    static func isInternalTransfer(_ tx: MoneyTransaction) -> Bool {
        tx.category == .internalTransfer
            || tx.category == .visaTransfer
            || tx.smsTransactionType == .internalTransfer
            || tx.toAccountID != nil
    }

    static func isLikelyMerchantRefund(_ tx: MoneyTransaction, recentExpenses: [MoneyTransaction]) -> Bool {
        if tx.smsTransactionType == .refund { return true }
        let combined = "\(tx.merchant) \(tx.note) \(tx.rawText ?? "")".lowercased()
        if refundKeywords.contains(where: { combined.contains($0) }) {
            return true
        }
        // If an incoming credit comes from the exact same merchant key as a recent expense (e.g., LUMEE / AMAZON / TALABAT),
        // treat it as a merchant refund rather than a person-to-person reimbursement.
        let inKey = SharedExpensePrivacy.normalizedMerchantKey(tx.merchant)
        if !inKey.isEmpty {
            let genericTransferWords: Set<String> = ["fawri", "transfer", "incoming", "benefitpay", "bank", "credit", "payment"]
            let tokens = Set(inKey.split(separator: " ").map(String.init))
            let isNonGenericMerchant = !tokens.isSubset(of: genericTransferWords)
            if isNonGenericMerchant {
                let matchesMerchant = recentExpenses.contains { exp in
                    let expKey = SharedExpensePrivacy.normalizedMerchantKey(exp.merchant)
                    return !expKey.isEmpty && (expKey == inKey || expKey.contains(inKey) || inKey.contains(expKey))
                }
                if matchesMerchant { return true }
            }
        }
        return false
    }

    static func isLikelySalaryOrOrdinaryIncome(_ tx: MoneyTransaction) -> Bool {
        let combined = "\(tx.merchant) \(tx.note) \(tx.rawText ?? "")".lowercased()
        return salaryIncomeKeywords.contains(where: { combined.contains($0) })
    }

    static func isEligibleIncomingReimbursement(_ tx: MoneyTransaction, recentExpenses: [MoneyTransaction]) -> Bool {
        guard !tx.isPending, tx.amount > SharedExpenseFinancialValidator.epsilon else { return false }
        guard !isInternalTransfer(tx) else { return false }
        guard tx.isTransferIn || tx.isIncome else { return false }
        guard !isLikelyMerchantRefund(tx, recentExpenses: recentExpenses) else { return false }
        guard !isLikelySalaryOrOrdinaryIncome(tx) else { return false }
        return true
    }

    static func hasExplicitSharedNoteCue(_ tx: MoneyTransaction) -> Bool {
        let text = "\(tx.note) \(tx.merchant)".lowercased()
        return sharedNoteKeywords.contains(where: { text.contains($0) })
    }

    static func hasReimbursementCue(_ tx: MoneyTransaction) -> Bool {
        let text = "\(tx.note) \(tx.rawText ?? "")".lowercased()
        return reimbursementNoteKeywords.contains(where: { text.contains($0) })
    }

    static func isCleanSplitRatio(reimbursement: Double, expense: Double) -> (isClean: Bool, peopleCount: Int?) {
        guard expense > SharedExpenseFinancialValidator.epsilon,
              reimbursement > SharedExpenseFinancialValidator.epsilon,
              reimbursement <= expense + 0.01 else {
            return (false, nil)
        }
        let ratio = reimbursement / expense
        // Check exact 100% reimbursement (paid fully on someone else's behalf)
        if abs(ratio - 1.0) <= 0.02 { return (true, 1) }
        // Check common group splits: 1/2, 1/3, 2/3, 1/4, 2/4, 3/4, 1/5..4/5, 1/6..5/6
        for denom in 2...6 {
            for numer in 1..<denom {
                let target = Double(numer) / Double(denom)
                if abs(ratio - target) <= 0.035 {
                    return (true, denom)
                }
            }
        }
        return (false, nil)
    }

    static func median(of values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count % 2 == 0 {
            return (sorted[mid - 1] + sorted[mid]) / 2.0
        }
        return sorted[mid]
    }
}

// MARK: - Analysis Outcome Types

enum SharedExpenseAnalysisOutcome: Equatable {
    case disabled
    case ignored(reason: String)
    case waitingForMoreContext(prediction: SharedExpensePrediction?)
    case suggested(SharedExpenseSuggestion)
    case automaticallyAdjusted([SharedExpenseAdjustment])
}

// MARK: - Shared Expense Intelligence Service

/// Independent AI intelligence layer for shared expenses and reimbursements.
/// - Never mutates `MoneyTransaction` amount, date, account, or bank reference.
/// - Never alters `TransactionRuleStore` or SMS parsing behavior.
/// - Safely disableable via `AppSettings.sharedExpenseIntelligenceEnabled`.
final class SharedExpenseIntelligenceService {
    static let shared = SharedExpenseIntelligenceService()

    let adjustmentStore: SharedExpenseAdjustmentStore
    let memoryStore: SharedExpenseMemoryStore
    let aiProvider: any SharedExpenseAIProvider
    let isEnabledProvider: () -> Bool
    let hasExistingRuleProvider: (MoneyTransaction) -> Bool

    init(
        adjustmentStore: SharedExpenseAdjustmentStore = .shared,
        memoryStore: SharedExpenseMemoryStore = .shared,
        aiProvider: any SharedExpenseAIProvider = GeminiSharedExpenseAIProvider(),
        isEnabledProvider: @escaping () -> Bool = { AppSettings.sharedExpenseIntelligenceEnabled },
        hasExistingRuleProvider: @escaping (MoneyTransaction) -> Bool = { TransactionRuleStore.shared.bestMatchingRule(for: $0) != nil }
    ) {
        self.adjustmentStore = adjustmentStore
        self.memoryStore = memoryStore
        self.aiProvider = aiProvider
        self.isEnabledProvider = isEnabledProvider
        self.hasExistingRuleProvider = hasExistingRuleProvider
    }

    // MARK: - Public Orchestration Entry Points

    /// Safe post-import observer hook for SwiftData contexts.
    @discardableResult
    func analyzeNewTransaction(_ tx: MoneyTransaction, context: ModelContext, currency: String = AppSettings.currency) async -> SharedExpenseAnalysisOutcome {
        guard isEnabledProvider() else { return .disabled }
        guard !tx.isPending else { return .ignored(reason: "Transaction is pending approval") }
        let all = (try? context.fetch(FetchDescriptor<MoneyTransaction>(sortBy: [SortDescriptor(\.date, order: .reverse)]))) ?? []
        return await analyzeTransaction(tx, allTransactions: all, currency: currency)
    }

    /// Pure, context-free analysis entry point suitable for both live runs and isolated unit tests.
    @discardableResult
    func analyzeTransaction(_ tx: MoneyTransaction, allTransactions: [MoneyTransaction], currency: String = AppSettings.currency) async -> SharedExpenseAnalysisOutcome {
        guard isEnabledProvider() else { return .disabled }
        guard !tx.isPending else { return .ignored(reason: "Transaction is pending approval") }

        // Route incoming transactions (excluding internal transfers & merchant refunds) to the Reimbursement Matcher.
        if tx.isTransferIn || tx.isIncome {
            return await analyzeIncomingReimbursement(tx, allTransactions: allTransactions, currency: currency)
        }

        // Route eligible spending transactions to the Shared Expense Detector.
        return await analyzeExpense(tx, allTransactions: allTransactions, currency: currency)
    }

    // MARK: - 1. AI Shared Expense Detection

    @discardableResult
    func analyzeExpense(_ tx: MoneyTransaction, allTransactions: [MoneyTransaction], currency: String = AppSettings.currency) async -> SharedExpenseAnalysisOutcome {
        guard isEnabledProvider() else { return .disabled }

        if SharedExpenseClassifier.hasMissingContext(tx) {
            return .waitingForMoreContext(prediction: nil)
        }
        guard SharedExpenseClassifier.isEligibleExpense(tx),
              let suggestedCatRaw = SharedExpenseClassifier.inferFocusCategoryRaw(for: tx) else {
            return .ignored(reason: "Transaction is not an eligible shared expense category")
        }

        // Historical spending baselines (excluding the target transaction itself)
        let historicalExpenses = allTransactions.filter {
            $0.id != tx.id && !$0.isPending && $0.isSpending && $0.amount > 0
        }
        let categoryAmounts = historicalExpenses
            .filter { $0.categoryRaw == suggestedCatRaw }
            .map(\.amount)
        let targetMerchantKey = SharedExpensePrivacy.normalizedMerchantKey(tx.merchant)
        let merchantAmounts = historicalExpenses
            .filter { !targetMerchantKey.isEmpty && SharedExpensePrivacy.normalizedMerchantKey($0.merchant) == targetMerchantKey }
            .map(\.amount)

        let catMedian = SharedExpenseClassifier.median(of: categoryAmounts)
        let merchMedian = SharedExpenseClassifier.median(of: merchantAmounts)
        let prior = memoryStore.prior(merchant: tx.merchant, categoryRaw: suggestedCatRaw)
        let hasRule = hasExistingRuleProvider(tx)

        // Check suppression from prior rejections (avoid repeating rejected patterns unless strong new cue appears)
        let hasExplicitSharedCue = SharedExpenseClassifier.hasExplicitSharedNoteCue(tx)
        if prior.isRepeatedlyRejected && !hasExplicitSharedCue {
            let suppressed = SharedExpensePrediction(
                transactionID: tx.id,
                sharedProbability: 0.10,
                estimatedPersonalAmount: tx.amount,
                estimatedReimbursableAmount: 0,
                confidence: 0.15,
                confidenceLevel: .insufficient,
                explanation: "Previously marked as a personal expense pattern; keeping unchanged.",
                suggestedCategoryRaw: suggestedCatRaw,
                signals: ["suppressed_by_user_rejection"]
            )
            adjustmentStore.savePrediction(suppressed)
            return .waitingForMoreContext(prediction: suppressed)
        }

        // Deterministic statistical assessment (never assumes every large transaction is shared)
        var signals: [String] = []
        var prob = 0.08
        var confidence = 0.15

        let referenceMedian = (merchantAmounts.count >= 2 ? merchMedian : nil) ?? (categoryAmounts.count >= 3 ? catMedian : nil)
        let sampleCount = (merchantAmounts.count >= 2 ? merchantAmounts.count : categoryAmounts.count)
        let ratioToNormal: Double? = referenceMedian.flatMap { $0 > 0 ? tx.amount / $0 : nil }

        if let ratio = ratioToNormal, sampleCount >= 3 {
            if ratio >= 2.6 && tx.amount >= 15.0 {
                // Noticeably above user's normal baseline — possible shared bill, but NOT automatically assumed shared
                prob += 0.34
                confidence += 0.28
                signals.append(String(format: "unusual_amount_%.1fx_median", ratio))
            } else if ratio >= 1.9 && tx.amount >= 12.0 {
                prob += 0.22
                confidence += 0.18
                signals.append(String(format: "elevated_amount_%.1fx_median", ratio))
            } else {
                // Consistent with normal personal spending
                signals.append("within_normal_spending_range")
            }
        } else if categoryAmounts.isEmpty && merchantAmounts.isEmpty {
            signals.append("insufficient_history")
        }

        if hasExplicitSharedCue {
            prob += 0.42
            confidence += 0.34
            signals.append("explicit_shared_note_cue")
        }

        if prior.confirmedSharedCount > 0 {
            // Modest boost from prior confirmations (never a universal rule from a single confirmation)
            let boost = min(0.26, Double(prior.confirmedSharedCount) * 0.11)
            prob += boost
            confidence += min(0.22, Double(prior.confirmedSharedCount) * 0.09)
            signals.append("prior_shared_memory_\(prior.confirmedSharedCount)")
        }

        if prior.confirmedPersonalCount > 0 {
            let penalty = min(0.35, Double(prior.confirmedPersonalCount) * 0.16)
            prob -= penalty
            confidence -= min(0.25, Double(prior.confirmedPersonalCount) * 0.12)
            signals.append("prior_personal_memory_\(prior.confirmedPersonalCount)")
        }

        if hasRule {
            // Respect existing TransactionRule: never aggressively flag rule-governed transactions without strong new cues
            confidence = min(confidence, 0.55)
            signals.append("existing_transaction_rule_present")
        }

        // Optional AI enrichment (injected or Gemini)
        let aiContext = SharedExpenseAIExpenseContext(
            transactionID: tx.id,
            merchant: tx.merchant,
            categoryRaw: suggestedCatRaw,
            amount: tx.amount,
            currency: currency,
            date: tx.date,
            note: tx.note,
            categoryMedianAmount: catMedian,
            categorySampleCount: categoryAmounts.count,
            merchantMedianAmount: merchMedian,
            merchantSampleCount: merchantAmounts.count,
            confirmedSharedCountForMerchant: prior.confirmedSharedCount,
            rejectedCountForMerchant: prior.rejectedSuggestionCount,
            confirmedPersonalCountForMerchant: prior.confirmedPersonalCount,
            averagePersonalRatio: prior.averagePersonalRatio
        )

        var explanationParts: [String] = []
        var finalPersonalAmount: Double
        var finalReimbursableAmount: Double
        var finalCategoryRaw = suggestedCatRaw

        if let ai = await aiProvider.assessExpense(aiContext) {
            // Blend AI judgment conservatively with statistical/memory priors
            prob = min(1, max(0, (prob * 0.45) + (ai.sharedProbability * 0.55) + prior.probabilityDelta * 0.5))
            // An expense alone without a reimbursement NEVER auto-adjusts (cap below 0.85)
            confidence = min(0.80, max(0, (confidence * 0.30) + (ai.confidence * 0.70)))
            if prior.confirmedPersonalCount > 0 {
                confidence = min(confidence, 0.50)
            }
            if hasRule {
                confidence = min(confidence, 0.55)
            }
            finalReimbursableAmount = min(tx.amount, max(0, ai.estimatedReimbursableAmount))
            finalPersonalAmount = max(0, tx.amount - finalReimbursableAmount)
            if !ai.suggestedCategoryRaw.isEmpty, SpendCategory(rawValue: ai.suggestedCategoryRaw) != nil {
                finalCategoryRaw = ai.suggestedCategoryRaw
            }
            if !ai.explanation.isEmpty {
                explanationParts.append(ai.explanation)
            }
            signals.append("ai_assessed")
        } else {
            prob = min(1, max(0, prob + prior.probabilityDelta * 0.5))
            // Cap expense-only confidence below high threshold so budgets are never silently altered without reimbursement
            confidence = min(0.76, max(0, confidence))
            if let learnedRatio = prior.averagePersonalRatio, learnedRatio > 0.05, learnedRatio < 0.95 {
                finalPersonalAmount = roundMoney(tx.amount * learnedRatio, currency: currency)
                finalReimbursableAmount = max(0, roundMoney(tx.amount - finalPersonalAmount, currency: currency))
            } else if let refMedian = referenceMedian, refMedian > 0, refMedian < tx.amount * 0.85 {
                finalPersonalAmount = roundMoney(refMedian, currency: currency)
                finalReimbursableAmount = max(0, roundMoney(tx.amount - finalPersonalAmount, currency: currency))
            } else {
                // Default 50/50 estimate when shared probability is meaningful
                finalPersonalAmount = roundMoney(tx.amount / 2.0, currency: currency)
                finalReimbursableAmount = max(0, roundMoney(tx.amount - finalPersonalAmount, currency: currency))
            }
            if let ratio = ratioToNormal, ratio >= 1.9 {
                explanationParts.append("This \(SpendCategory.resolve(finalCategoryRaw).title.lowercased()) payment is \(String(format: "%.1f×", ratio)) your usual spending at this level.")
            }
            if hasExplicitSharedCue {
                explanationParts.append("The transaction description mentions a shared or group expense.")
            }
            if prior.confirmedSharedCount > 0 {
                explanationParts.append("You previously confirmed \(prior.confirmedSharedCount) shared expense(s) at \(tx.merchant).")
            }
        }

        // If probability is low or there isn't enough evidence, zero out reimbursable estimate and wait for reimbursements
        let level = SharedExpenseConfidenceLevel.from(score: confidence)
        if prob < 0.42 || level == .insufficient {
            let prediction = SharedExpensePrediction(
                transactionID: tx.id,
                sharedProbability: prob,
                estimatedPersonalAmount: tx.amount,
                estimatedReimbursableAmount: 0,
                confidence: confidence,
                confidenceLevel: .insufficient,
                explanation: explanationParts.isEmpty ? "Looks like a regular personal expense; waiting for any reimbursement context." : explanationParts.joined(separator: " "),
                suggestedCategoryRaw: finalCategoryRaw,
                signals: signals
            )
            adjustmentStore.savePrediction(prediction)
            return .waitingForMoreContext(prediction: prediction)
        }

        let explanation = explanationParts.isEmpty
            ? "Detected a potential shared \(SpendCategory.resolve(finalCategoryRaw).title.lowercased()) expense."
            : explanationParts.joined(separator: " ")

        let prediction = SharedExpensePrediction(
            transactionID: tx.id,
            sharedProbability: prob,
            estimatedPersonalAmount: finalPersonalAmount,
            estimatedReimbursableAmount: finalReimbursableAmount,
            confidence: confidence,
            confidenceLevel: level,
            explanation: explanation,
            suggestedCategoryRaw: finalCategoryRaw,
            signals: signals
        )
        adjustmentStore.savePrediction(prediction)

        // Medium or Low confidence -> NEVER modify transaction or budget automatically; create contextual suggestion.
        let catTitle = SpendCategory.resolve(finalCategoryRaw).title
        let prompt = "FALAK noticed that this \(tx.merchant) payment (\(Money.format(tx.amount, currency))) may have been a shared expense. Would you like to link it to your \(catTitle) category and exclude the reimbursable portion (\(Money.format(finalReimbursableAmount, currency))) from your personal spending?"
        let suggestion = SharedExpenseSuggestion(
            expenseTransactionID: tx.id,
            candidateReimbursementIDs: [],
            originalExpenseAmount: tx.amount,
            suggestedCategoryRaw: finalCategoryRaw,
            suggestedPersonalAmount: finalPersonalAmount,
            suggestedReimbursableAmount: finalReimbursableAmount,
            potentialReimbursementAmount: nil,
            expectedBudgetImpact: -finalReimbursableAmount,
            confidence: confidence,
            confidenceLevel: level,
            explanation: explanation,
            promptMessage: prompt
        )
        adjustmentStore.upsertSuggestion(suggestion)
        return .suggested(suggestion)
    }

    // MARK: - 2. Reimbursement Relationship Intelligence

    @discardableResult
    func analyzeIncomingReimbursement(_ incomingTx: MoneyTransaction, allTransactions: [MoneyTransaction], currency: String = AppSettings.currency) async -> SharedExpenseAnalysisOutcome {
        guard isEnabledProvider() else { return .disabled }

        let lookbackDays = memoryStore.typicalReimbursementWindowDays()
        let windowStart = incomingTx.date.addingTimeInterval(-lookbackDays * 86_400)
        let maxExpenseDate = incomingTx.date.addingTimeInterval(SharedExpenseFinancialValidator.maxClockSkewSeconds)

        let recentExpenses = allTransactions.filter {
            $0.id != incomingTx.id
                && !$0.isPending
                && $0.isSpending
                && $0.date >= windowStart
                && $0.date <= maxExpenseDate
        }

        // Guard: internal transfers, merchant refunds, and salary/ordinary income are never matched as reimbursements
        guard SharedExpenseClassifier.isEligibleIncomingReimbursement(incomingTx, recentExpenses: recentExpenses) else {
            return .ignored(reason: "Incoming transaction is an internal transfer, merchant refund, or ordinary income")
        }

        let availableCapacity = adjustmentStore.remainingCapacity(forReimbursementID: incomingTx.id, totalAmount: incomingTx.amount)
        guard availableCapacity > SharedExpenseFinancialValidator.epsilon else {
            return .ignored(reason: "Incoming transfer is already fully allocated")
        }

        let senderToken = SharedExpensePrivacy.extractSenderToken(from: incomingTx)
        let incomingHasCue = SharedExpenseClassifier.hasReimbursementCue(incomingTx)
        let incomingHasRule = hasExistingRuleProvider(incomingTx)

        // Gather eligible candidate expenses across ANY real spending category
        // (supports 100% purchases paid for someone else in any category, plus active/predicted shared expenses).
        let candidates: [MoneyTransaction] = recentExpenses.filter { exp in
            guard exp.source != .bill, exp.billID == nil else { return false }
            guard !exp.isIncome, !exp.isTransfer else { return false }
            guard exp.smsTransactionType != .refund, exp.smsTransactionType != .fee, exp.smsTransactionType != .internalTransfer else { return false }
            return true
        }

        guard !candidates.isEmpty else {
            return .waitingForMoreContext(prediction: nil)
        }

        // Build AI context for optional AI relationship reasoning
        let aiCandidates: [SharedExpenseAIReimbursementCandidate] = candidates.prefix(12).map { exp in
            let pred = adjustmentStore.prediction(forTransactionID: exp.id)
            let activeAdj = adjustmentStore.activeAdjustment(forExpenseID: exp.id)
            return SharedExpenseAIReimbursementCandidate(
                expenseID: exp.id,
                merchant: exp.merchant,
                categoryRaw: activeAdj?.effectiveCategoryRaw ?? SharedExpenseClassifier.inferFocusCategoryRaw(for: exp) ?? exp.categoryRaw,
                expenseAmount: exp.amount,
                expenseDate: exp.date,
                priorSharedProbability: pred?.sharedProbability,
                outstandingReimbursableAmount: activeAdj?.outstandingReimbursementAmount,
                hasActiveSharedAdjustment: activeAdj != nil
            )
        }
        let senderPrior = memoryStore.prior(merchant: "", categoryRaw: "", senderToken: senderToken)
        let aiContext = SharedExpenseAIReimbursementContext(
            incomingID: incomingTx.id,
            incomingAmount: incomingTx.amount,
            availableCapacity: availableCapacity,
            incomingDate: incomingTx.date,
            incomingCategoryRaw: incomingTx.categoryRaw,
            incomingNote: incomingTx.note,
            hasKnownSenderPattern: senderPrior.knownSenderConfirmationCount > 0,
            knownSenderConfirmationCount: senderPrior.knownSenderConfirmationCount,
            candidates: aiCandidates
        )
        let aiAssessment = await aiProvider.assessReimbursement(aiContext)

        // Score candidate matches: (a) multi-expense bundled reimbursement, (b) single-expense full/partial reimbursement
        struct ScoredPlan {
            let links: [(expense: MoneyTransaction, amount: Double)]
            let confidence: Double
            let corroborationCount: Int
            let explanation: String
            let anyRuleConflict: Bool
        }

        var bestPlan: ScoredPlan?

        // (A) Evaluate single-expense relationships (exact split, partial repayment, or additional partial repayment)
        for exp in candidates {
            let activeAdj = adjustmentStore.activeAdjustment(forExpenseID: exp.id)
            let pred = adjustmentStore.prediction(forTransactionID: exp.id)
            let expCatRaw = activeAdj?.effectiveCategoryRaw ?? SharedExpenseClassifier.inferFocusCategoryRaw(for: exp) ?? exp.categoryRaw
            let prior = memoryStore.prior(merchant: exp.merchant, categoryRaw: expCatRaw, senderToken: senderToken)

            // Skip if user previously rejected shared suggestions at this merchant and there is no strong sender/active link
            if prior.isRepeatedlyRejected && activeAdj == nil && senderPrior.knownSenderConfirmationCount == 0 && !incomingHasCue {
                continue
            }

            // Compute maximum valid allocation for this expense
            let maxForExpense: Double = {
                if let adj = activeAdj {
                    // If user/system already set a reimbursable target with remaining balance, cap to remaining;
                    // if additional partial reimbursement arrives beyond initial estimate but still < expense total, cap to expense - alreadyReceived.
                    let alreadyReceived = adj.totalReceivedReimbursementAmount
                    if adj.outstandingReimbursementAmount > SharedExpenseFinancialValidator.epsilon {
                        return adj.outstandingReimbursementAmount
                    }
                    return max(0, exp.amount - alreadyReceived)
                }
                return exp.amount
            }()
            guard maxForExpense > SharedExpenseFinancialValidator.epsilon else { continue }
            guard availableCapacity <= maxForExpense + 0.01 else { continue }

            let allocAmount = min(availableCapacity, maxForExpense)
            let validation = SharedExpenseFinancialValidator.validateAllocation(
                expenseTxID: exp.id,
                expenseDate: exp.date,
                expenseTotalAmount: exp.amount,
                expenseReimbursableCap: max(activeAdj?.reimbursableAmount ?? exp.amount, (activeAdj?.totalReceivedReimbursementAmount ?? 0) + allocAmount),
                reimbursementTxID: incomingTx.id,
                reimbursementDate: incomingTx.date,
                reimbursementTotalAmount: incomingTx.amount,
                requestedAmount: allocAmount,
                existingActiveAdjustments: adjustmentStore.activeAdjustments
            )
            guard case .success = validation else { continue }

            // Compute multi-signal score — NEVER match unrelated transfers solely on amount or timing!
            var score = 0.0
            var corroborations = 0
            var reasons: [String] = []

            let hoursDelta = max(0, incomingTx.date.timeIntervalSince(exp.date) / 3600.0)
            let daysDelta = hoursDelta / 24.0

            // 1. Existing active shared expense with outstanding balance (strongest signal for multiple partial reimbursements!)
            if let adj = activeAdj {
                if adj.outstandingReimbursementAmount > SharedExpenseFinancialValidator.epsilon {
                    score += 0.42
                    corroborations += 2
                    if abs(allocAmount - adj.outstandingReimbursementAmount) <= 0.05 {
                        score += 0.16
                        reasons.append("matches the remaining reimbursable balance (\(Money.format(adj.outstandingReimbursementAmount, currency)))")
                    } else if allocAmount < adj.outstandingReimbursementAmount {
                        score += 0.10
                        reasons.append("covers part of the remaining reimbursable balance on \(exp.merchant)")
                    }
                } else {
                    score += 0.25
                    corroborations += 1
                    reasons.append("links to existing shared expense at \(exp.merchant)")
                }
            }

            // 2. Prior AI shared expense prediction on this expense
            if let pred, pred.sharedProbability >= 0.45 {
                score += 0.28 * pred.sharedProbability
                corroborations += 1
                reasons.append("matches a flagged potential shared expense at \(exp.merchant)")
                if pred.estimatedReimbursableAmount > 0 && abs(allocAmount - pred.estimatedReimbursableAmount) <= max(0.25, pred.estimatedReimbursableAmount * 0.12) {
                    score += 0.12
                    reasons.append("closely aligns with the estimated reimbursable share")
                }
            }

            let isTrustedSender = memoryStore.isSenderTrusted(senderToken)
            let isExactFullMatch = abs(allocAmount - exp.amount) <= 0.01 && activeAdj == nil

            // 3. Trusted / learned repeated reimbursement sender pattern (anonymized token)
            if isTrustedSender {
                score += 0.36
                corroborations += 2
                reasons.append("from a trusted reimbursement sender")
            } else if prior.knownSenderConfirmationCount > 0 {
                score += min(0.28, 0.18 + Double(prior.knownSenderConfirmationCount - 1) * 0.05)
                corroborations += 1
                reasons.append("from a previously confirmed reimbursement sender")
            }

            // 3b. Exact 100% reimbursement ("not my purchase, paid for someone else")
            if isExactFullMatch && daysDelta <= 3.0 {
                if isTrustedSender || prior.knownSenderConfirmationCount > 0 {
                    score += 0.34
                    corroborations += 1
                    reasons.append("matches 100% of \(exp.merchant)")
                } else if corroborations == 0 {
                    // First time seeing an exact 100% transfer back with unknown sender -> never auto-adjust; suggest once for confirmation!
                    score = max(score, 0.66)
                    corroborations = max(corroborations, 1)
                    reasons.append("exact 100% match for your recent \(exp.merchant) purchase")
                }
            }

            // 4. Learned shared merchant pattern
            if prior.confirmedSharedCount > 0 {
                score += min(0.18, Double(prior.confirmedSharedCount) * 0.09)
                corroborations += 1
                reasons.append("at a merchant with prior confirmed shared bills")
            }

            // 5. Explicit note/SMS reimbursement cue
            if incomingHasCue {
                score += 0.24
                corroborations += 1
                reasons.append("transfer description references a shared expense reimbursement")
            }

            // 6. Clean mathematical split ratio (supporting signal, NEVER sufficient by itself!)
            let splitCheck = SharedExpenseClassifier.isCleanSplitRatio(reimbursement: allocAmount, expense: exp.amount)
            if splitCheck.isClean {
                score += 0.16
                if let people = splitCheck.peopleCount, people > 1 {
                    reasons.append("represents a clean \(people)-way split of \(Money.format(exp.amount, currency))")
                } else {
                    reasons.append("matches the full expense amount (\(Money.format(exp.amount, currency)))")
                }
            }

            // 7. Timing proximity (supporting signal, NEVER sufficient by itself!)
            if daysDelta <= 1.0 {
                score += 0.14
            } else if daysDelta <= 4.0 {
                score += 0.10
            } else if daysDelta <= 10.0 {
                score += 0.06
            } else {
                score += 0.02
            }

            // 8. AI corroboration (if available)
            if let ai = aiAssessment,
               let aiLink = ai.links.first(where: { $0.expenseID == exp.id }),
               abs(aiLink.allocatedAmount - allocAmount) <= max(0.25, allocAmount * 0.10) {
                score = (score * 0.65) + (ai.confidence * 0.35) + 0.10
                if ai.confidence >= 0.65 {
                    corroborations += 1
                }
                if !ai.explanation.isEmpty {
                    reasons.append(ai.explanation)
                }
            }

            // CRITICAL GUARD: Never match unrelated incoming transfers based ONLY on amount or timing.
            // Require at least 1 real corroborating signal beyond amount/timing!
            guard corroborations >= 1 else { continue }

            let finalConf = min(0.98, max(0, score))
            let ruleConflict = incomingHasRule || hasExistingRuleProvider(exp)
            let explanation = reasons.isEmpty
                ? "Incoming transfer of \(Money.format(allocAmount, currency)) appears to reimburse \(exp.merchant)."
                : "Incoming transfer of \(Money.format(allocAmount, currency)) " + reasons.joined(separator: "; ") + "."

            let plan = ScoredPlan(
                links: [(exp, allocAmount)],
                confidence: finalConf,
                corroborationCount: corroborations,
                explanation: explanation,
                anyRuleConflict: ruleConflict
            )
            if bestPlan == nil || plan.confidence > (bestPlan?.confidence ?? 0) {
                bestPlan = plan
            }
        }

        // (B) Always evaluate 1-reimbursement-covering-multiple-expenses (recent shared expenses whose expected shares sum exactly to incoming amount)
        if let multiPlan = findMultiExpenseBundlePlan(
            incomingTx: incomingTx,
            availableCapacity: availableCapacity,
            candidates: Array(candidates.prefix(8)),
            senderToken: senderToken,
            incomingHasCue: incomingHasCue,
            incomingHasRule: incomingHasRule,
            aiAssessment: aiAssessment,
            currency: currency
        ) {
            if bestPlan == nil || multiPlan.confidence >= (bestPlan?.confidence ?? 0) {
                bestPlan = ScoredPlan(
                    links: multiPlan.links,
                    confidence: multiPlan.confidence,
                    corroborationCount: multiPlan.corroborationCount,
                    explanation: multiPlan.explanation,
                    anyRuleConflict: multiPlan.anyRuleConflict
                )
            }
        }

        guard let plan = bestPlan else {
            return .waitingForMoreContext(prediction: nil)
        }

        // Respect existing TransactionRule: downgrade to suggestion if any participating tx is governed by a rule.
        let effectiveConfidence = plan.anyRuleConflict ? min(plan.confidence, 0.75) : plan.confidence
        let level = SharedExpenseConfidenceLevel.from(score: effectiveConfidence)

        // HIGH CONFIDENCE + multi-signal corroboration (>= 2) + deterministic validation -> Auto-link & record adjustment
        if level == .high && plan.corroborationCount >= 2 && !plan.anyRuleConflict {
            var applied: [SharedExpenseAdjustment] = []
            var workingActive = adjustmentStore.activeAdjustments

            // First validate ALL links atomically before writing any adjustment
            var validatedLinks: [(expense: MoneyTransaction, amount: Double, targetReimbursable: Double, effectiveCatRaw: String)] = []
            for (exp, allocAmt) in plan.links {
                let existingAdj = workingActive.first { $0.isActive && $0.originalTransactionID == exp.id }
                let alreadyReceived = existingAdj?.totalReceivedReimbursementAmount ?? 0
                let targetReimbursable = max(existingAdj?.reimbursableAmount ?? allocAmt, alreadyReceived + allocAmt)
                let clampedReimbursable = min(exp.amount, targetReimbursable)

                let vAlloc = SharedExpenseFinancialValidator.validateAllocation(
                    expenseTxID: exp.id,
                    expenseDate: exp.date,
                    expenseTotalAmount: exp.amount,
                    expenseReimbursableCap: clampedReimbursable,
                    reimbursementTxID: incomingTx.id,
                    reimbursementDate: incomingTx.date,
                    reimbursementTotalAmount: incomingTx.amount,
                    requestedAmount: allocAmt,
                    existingActiveAdjustments: workingActive
                )
                guard case .success = vAlloc else {
                    return .waitingForMoreContext(prediction: nil)
                }
                let effectiveCat = existingAdj?.effectiveCategoryRaw
                    ?? SharedExpenseClassifier.inferFocusCategoryRaw(for: exp)
                    ?? exp.categoryRaw
                validatedLinks.append((exp, allocAmt, clampedReimbursable, effectiveCat))

                // Simulate updated active list so multi-expense bundle checks cumulative reimbursement capacity accurately
                let tempAlloc = ReimbursementAllocation(reimbursementTransactionID: incomingTx.id, allocatedAmount: allocAmt, senderToken: senderToken)
                if let idx = workingActive.firstIndex(where: { $0.isActive && $0.originalTransactionID == exp.id }) {
                    workingActive[idx].reimbursementAllocations.append(tempAlloc)
                    workingActive[idx].reimbursableAmount = clampedReimbursable
                    workingActive[idx].personalAmount = max(0, exp.amount - clampedReimbursable)
                } else {
                    workingActive.append(SharedExpenseAdjustment(
                        originalTransactionID: exp.id,
                        reimbursementAllocations: [tempAlloc],
                        originalExpenseAmount: exp.amount,
                        personalAmount: max(0, exp.amount - clampedReimbursable),
                        reimbursableAmount: clampedReimbursable,
                        effectiveCategoryRaw: effectiveCat,
                        aiConfidence: effectiveConfidence,
                        explanation: plan.explanation,
                        confirmationSource: .automatic
                    ))
                }
            }

            // Persist validated adjustments and update learning memory
            for item in validatedLinks {
                let alloc = ReimbursementAllocation(
                    reimbursementTransactionID: incomingTx.id,
                    allocatedAmount: item.amount,
                    senderToken: senderToken
                )
                let adjustment: SharedExpenseAdjustment
                if var existing = adjustmentStore.activeAdjustment(forExpenseID: item.expense.id) {
                    existing.reimbursementAllocations.append(alloc)
                    existing.reimbursableAmount = item.targetReimbursable
                    existing.personalAmount = max(0, roundMoney(item.expense.amount - item.targetReimbursable, currency: currency))
                    existing.aiConfidence = max(existing.aiConfidence, effectiveConfidence)
                    existing.explanation = plan.explanation
                    existing.timestamp = Date()
                    adjustment = existing
                } else {
                    adjustment = SharedExpenseAdjustment(
                        originalTransactionID: item.expense.id,
                        reimbursementAllocations: [alloc],
                        originalExpenseAmount: item.expense.amount,
                        personalAmount: max(0, roundMoney(item.expense.amount - item.targetReimbursable, currency: currency)),
                        reimbursableAmount: item.targetReimbursable,
                        effectiveCategoryRaw: item.effectiveCatRaw,
                        aiConfidence: effectiveConfidence,
                        explanation: plan.explanation,
                        timestamp: Date(),
                        confirmationSource: .automatic
                    )
                }
                adjustmentStore.upsertAdjustment(adjustment)
                // Resolve any pending suggestion on this expense
                if let pending = adjustmentStore.pendingSuggestion(forTransactionID: item.expense.id) {
                    adjustmentStore.markSuggestion(pending.id, status: .confirmed)
                }
                // Record reliable reimbursement pattern in learning memory
                let delayHours = max(0, incomingTx.date.timeIntervalSince(item.expense.date) / 3600.0)
                let wasPartial = item.amount < (item.targetReimbursable - 0.01)
                memoryStore.record(SharedExpenseMemoryRecord(
                    transactionID: item.expense.id.uuidString,
                    relationshipType: .reimbursementPattern,
                    confirmedCategory: item.effectiveCatRaw,
                    personalAmount: adjustment.personalAmount,
                    reimbursableAmount: adjustment.reimbursableAmount,
                    confirmationSource: .automatic,
                    confidence: effectiveConfidence,
                    merchantKey: SharedExpensePrivacy.normalizedMerchantKey(item.expense.merchant),
                    senderToken: senderToken,
                    reimbursementDelayHours: delayHours,
                    wasPartialRepayment: wasPartial
                ))
                applied.append(adjustment)
            }

            Ledger.notifyDataChanged()
            return .automaticallyAdjusted(applied)
        }

        // MEDIUM / LOW CONFIDENCE -> Create contextual suggestion without touching budget
        if level == .medium || level == .low {
            guard let primary = plan.links.first else { return .waitingForMoreContext(prediction: nil) }
            let exp = primary.expense
            let existingAdj = adjustmentStore.activeAdjustment(forExpenseID: exp.id)
            let suggestedCatRaw = existingAdj?.effectiveCategoryRaw
                ?? SharedExpenseClassifier.inferFocusCategoryRaw(for: exp)
                ?? exp.categoryRaw
            let catTitle = SpendCategory.resolve(suggestedCatRaw).title
            let reimbAmt = min(exp.amount, (existingAdj?.totalReceivedReimbursementAmount ?? 0) + primary.amount)
            let personalAmt = max(0, roundMoney(exp.amount - reimbAmt, currency: currency))
            let isFullExclusion = abs(reimbAmt - exp.amount) <= 0.01
            let prompt: String = isFullExclusion
                ? "You spent \(Money.format(exp.amount, currency)) at \(exp.merchant) and received \(Money.format(incomingTx.amount, currency)). Was this purchase paid for someone else? Confirm to remove it from your \(catTitle) budget."
                : "FALAK noticed an incoming transfer of \(Money.format(incomingTx.amount, currency)) that may reimburse your \(exp.merchant) payment (\(Money.format(exp.amount, currency))). Would you like to link it to \(catTitle) and exclude \(Money.format(reimbAmt, currency)) from your personal spending?"
            let suggestion = SharedExpenseSuggestion(
                expenseTransactionID: exp.id,
                candidateReimbursementIDs: [incomingTx.id],
                originalExpenseAmount: exp.amount,
                suggestedCategoryRaw: suggestedCatRaw,
                suggestedPersonalAmount: personalAmt,
                suggestedReimbursableAmount: reimbAmt,
                potentialReimbursementAmount: primary.amount,
                expectedBudgetImpact: -primary.amount,
                confidence: effectiveConfidence,
                confidenceLevel: level,
                explanation: plan.explanation,
                promptMessage: prompt
            )
            adjustmentStore.upsertSuggestion(suggestion)
            return .suggested(suggestion)
        }

        return .waitingForMoreContext(prediction: nil)
    }

    // MARK: - 3. User Confirmation, Rejection & Reversal

    /// Confirms a medium/low-confidence suggestion, validates financial invariants,
    /// writes the reversible adjustment overlay, and updates dedicated learning memory.
    @discardableResult
    func confirmSuggestion(
        _ suggestion: SharedExpenseSuggestion,
        allTransactions: [MoneyTransaction],
        chosenCategoryRaw: String? = nil,
        customPersonalAmount: Double? = nil,
        customReimbursableAmount: Double? = nil,
        trustSender: Bool = false,
        currency: String = AppSettings.currency
    ) -> Result<SharedExpenseAdjustment, FinancialValidationError> {
        guard let expenseTx = allTransactions.first(where: { $0.id == suggestion.expenseTransactionID }) else {
            return .failure(.invalidExpenseAmount)
        }

        let finalCategoryRaw = (chosenCategoryRaw?.isEmpty == false ? chosenCategoryRaw! : suggestion.suggestedCategoryRaw)
        let reimbursableAmount: Double
        let personalAmount: Double
        if let customReimb = customReimbursableAmount {
            reimbursableAmount = min(expenseTx.amount, max(0, roundMoney(customReimb, currency: currency)))
            personalAmount = max(0, roundMoney(expenseTx.amount - reimbursableAmount, currency: currency))
        } else if let customPers = customPersonalAmount {
            personalAmount = min(expenseTx.amount, max(0, roundMoney(customPers, currency: currency)))
            reimbursableAmount = max(0, roundMoney(expenseTx.amount - personalAmount, currency: currency))
        } else {
            reimbursableAmount = min(expenseTx.amount, max(0, roundMoney(suggestion.suggestedReimbursableAmount, currency: currency)))
            personalAmount = max(0, roundMoney(expenseTx.amount - reimbursableAmount, currency: currency))
        }

        if case .failure(let err) = SharedExpenseFinancialValidator.validateSplit(
            originalAmount: expenseTx.amount,
            personalAmount: personalAmount,
            reimbursableAmount: reimbursableAmount
        ) {
            return .failure(err)
        }

        // Validate and build any linked candidate reimbursement allocations
        var newAllocations: [ReimbursementAllocation] = adjustmentStore.activeAdjustment(forExpenseID: expenseTx.id)?.reimbursementAllocations ?? []
        var workingActive = adjustmentStore.activeAdjustments
        var firstDelayHours: Double? = nil
        var firstSenderToken: String? = nil

        var remainingNeed = max(0, reimbursableAmount - newAllocations.reduce(0) { $0 + $1.allocatedAmount })
        for reimbID in suggestion.candidateReimbursementIDs where remainingNeed > SharedExpenseFinancialValidator.epsilon {
            guard let reimbTx = allTransactions.first(where: { $0.id == reimbID }) else { continue }
            // Skip if already linked
            if newAllocations.contains(where: { $0.reimbursementTransactionID == reimbID }) { continue }
            let capacity = adjustmentStore.remainingCapacity(forReimbursementID: reimbID, totalAmount: reimbTx.amount)
            let desired = min(remainingNeed, min(capacity, suggestion.potentialReimbursementAmount ?? capacity))
            guard desired > SharedExpenseFinancialValidator.epsilon else { continue }

            let check = SharedExpenseFinancialValidator.validateAllocation(
                expenseTxID: expenseTx.id,
                expenseDate: expenseTx.date,
                expenseTotalAmount: expenseTx.amount,
                expenseReimbursableCap: reimbursableAmount,
                reimbursementTxID: reimbTx.id,
                reimbursementDate: reimbTx.date,
                reimbursementTotalAmount: reimbTx.amount,
                requestedAmount: desired,
                existingActiveAdjustments: workingActive
            )
            if case .failure(let err) = check {
                return .failure(err)
            }
            let sToken = SharedExpensePrivacy.extractSenderToken(from: reimbTx)
            if firstSenderToken == nil { firstSenderToken = sToken }
            if firstDelayHours == nil {
                firstDelayHours = max(0, reimbTx.date.timeIntervalSince(expenseTx.date) / 3600.0)
            }
            let alloc = ReimbursementAllocation(reimbursementTransactionID: reimbTx.id, allocatedAmount: desired, senderToken: sToken)
            newAllocations.append(alloc)
            remainingNeed = max(0, remainingNeed - desired)
            workingActive.append(SharedExpenseAdjustment(
                originalTransactionID: expenseTx.id,
                reimbursementAllocations: [alloc],
                originalExpenseAmount: expenseTx.amount,
                personalAmount: personalAmount,
                reimbursableAmount: reimbursableAmount,
                effectiveCategoryRaw: finalCategoryRaw,
                aiConfidence: suggestion.confidence,
                explanation: suggestion.explanation,
                confirmationSource: .userConfirmed
            ))
        }

        let adjustment = SharedExpenseAdjustment(
            id: adjustmentStore.activeAdjustment(forExpenseID: expenseTx.id)?.id ?? UUID(),
            originalTransactionID: expenseTx.id,
            reimbursementAllocations: newAllocations,
            originalExpenseAmount: expenseTx.amount,
            personalAmount: personalAmount,
            reimbursableAmount: reimbursableAmount,
            effectiveCategoryRaw: finalCategoryRaw,
            aiConfidence: max(suggestion.confidence, 1.0),
            explanation: suggestion.explanation,
            timestamp: Date(),
            confirmationSource: .userConfirmed
        )
        adjustmentStore.upsertAdjustment(adjustment)
        adjustmentStore.markSuggestion(suggestion.id, status: .confirmed)

        // Save confirmed decision in dedicated learning memory (never touching TransactionRuleStore)
        let merchantKey = SharedExpensePrivacy.normalizedMerchantKey(expenseTx.merchant)
        memoryStore.record(SharedExpenseMemoryRecord(
            transactionID: expenseTx.id.uuidString,
            relationshipType: .sharedExpense,
            confirmedCategory: finalCategoryRaw,
            personalAmount: personalAmount,
            reimbursableAmount: reimbursableAmount,
            confirmationSource: .userConfirmed,
            confidence: 1.0,
            merchantKey: merchantKey,
            senderToken: firstSenderToken,
            reimbursementDelayHours: firstDelayHours,
            wasPartialRepayment: adjustment.outstandingReimbursementAmount > SharedExpenseFinancialValidator.epsilon
        ))

        if trustSender {
            memoryStore.setSenderTrusted(firstSenderToken, trusted: true)
        }

        Ledger.notifyDataChanged()
        return .success(adjustment)
    }

    // MARK: - 3b. Manual Controls (Paid for Someone Else / Link Incoming Transfer)

    /// Manually marks an expense as shared or 100% paid for someone else (even before reimbursement arrives),
    /// immediately protecting the category budget via the reversible adjustment layer.
    @discardableResult
    func applyManualAdjustment(
        for expenseTx: MoneyTransaction,
        personalAmount: Double,
        reimbursableAmount: Double,
        effectiveCategoryRaw: String? = nil,
        linkedReimbursements: [(tx: MoneyTransaction, amount: Double)] = [],
        trustSender: Bool = false,
        explanation: String? = nil,
        currency: String = AppSettings.currency
    ) -> Result<SharedExpenseAdjustment, FinancialValidationError> {
        let clampedReimb = min(expenseTx.amount, max(0, roundMoney(reimbursableAmount, currency: currency)))
        let clampedPersonal = max(0, roundMoney(expenseTx.amount - clampedReimb, currency: currency))

        if case .failure(let err) = SharedExpenseFinancialValidator.validateSplit(
            originalAmount: expenseTx.amount,
            personalAmount: clampedPersonal,
            reimbursableAmount: clampedReimb
        ) {
            return .failure(err)
        }

        let existingAdj = adjustmentStore.activeAdjustment(forExpenseID: expenseTx.id)
        var newAllocations = existingAdj?.reimbursementAllocations ?? []
        var workingActive = adjustmentStore.activeAdjustments
        var firstDelayHours: Double? = nil
        var firstSenderToken: String? = nil

        for item in linkedReimbursements where item.amount > SharedExpenseFinancialValidator.epsilon {
            if newAllocations.contains(where: { $0.reimbursementTransactionID == item.tx.id }) { continue }
            let check = SharedExpenseFinancialValidator.validateAllocation(
                expenseTxID: expenseTx.id,
                expenseDate: expenseTx.date,
                expenseTotalAmount: expenseTx.amount,
                expenseReimbursableCap: clampedReimb,
                reimbursementTxID: item.tx.id,
                reimbursementDate: item.tx.date,
                reimbursementTotalAmount: item.tx.amount,
                requestedAmount: item.amount,
                existingActiveAdjustments: workingActive
            )
            if case .failure(let err) = check {
                return .failure(err)
            }
            let sToken = SharedExpensePrivacy.extractSenderToken(from: item.tx)
            if firstSenderToken == nil { firstSenderToken = sToken }
            if firstDelayHours == nil {
                firstDelayHours = max(0, item.tx.date.timeIntervalSince(expenseTx.date) / 3600.0)
            }
            let alloc = ReimbursementAllocation(reimbursementTransactionID: item.tx.id, allocatedAmount: item.amount, senderToken: sToken)
            newAllocations.append(alloc)
            workingActive.append(SharedExpenseAdjustment(
                originalTransactionID: expenseTx.id,
                reimbursementAllocations: [alloc],
                originalExpenseAmount: expenseTx.amount,
                personalAmount: clampedPersonal,
                reimbursableAmount: clampedReimb,
                effectiveCategoryRaw: effectiveCategoryRaw ?? existingAdj?.effectiveCategoryRaw ?? expenseTx.categoryRaw,
                aiConfidence: 1.0,
                explanation: explanation ?? "Manually marked",
                confirmationSource: .userConfirmed
            ))
        }

        let finalCategory = (effectiveCategoryRaw?.isEmpty == false ? effectiveCategoryRaw! : nil)
            ?? existingAdj?.effectiveCategoryRaw
            ?? expenseTx.categoryRaw
        let defaultReason = clampedPersonal <= SharedExpenseFinancialValidator.epsilon
            ? "Manually marked as 100% paid for someone else."
            : "Manually split personal and reimbursable portions."

        let adjustment = SharedExpenseAdjustment(
            id: existingAdj?.id ?? UUID(),
            originalTransactionID: expenseTx.id,
            reimbursementAllocations: newAllocations,
            originalExpenseAmount: expenseTx.amount,
            personalAmount: clampedPersonal,
            reimbursableAmount: clampedReimb,
            effectiveCategoryRaw: finalCategory,
            aiConfidence: 1.0,
            explanation: explanation ?? defaultReason,
            timestamp: Date(),
            confirmationSource: .userConfirmed
        )
        adjustmentStore.upsertAdjustment(adjustment)
        if let pending = adjustmentStore.pendingSuggestion(forTransactionID: expenseTx.id) {
            adjustmentStore.markSuggestion(pending.id, status: .confirmed)
        }

        memoryStore.record(SharedExpenseMemoryRecord(
            transactionID: expenseTx.id.uuidString,
            relationshipType: .sharedExpense,
            confirmedCategory: finalCategory,
            personalAmount: clampedPersonal,
            reimbursableAmount: clampedReimb,
            confirmationSource: .userConfirmed,
            confidence: 1.0,
            merchantKey: SharedExpensePrivacy.normalizedMerchantKey(expenseTx.merchant),
            senderToken: firstSenderToken,
            reimbursementDelayHours: firstDelayHours,
            wasPartialRepayment: adjustment.outstandingReimbursementAmount > SharedExpenseFinancialValidator.epsilon
        ))

        if trustSender {
            memoryStore.setSenderTrusted(firstSenderToken, trusted: true)
        }

        Ledger.notifyDataChanged()
        return .success(adjustment)
    }

    /// Manually links an incoming transfer transaction to one or more purchases as a reimbursement.
    @discardableResult
    func linkReimbursementManually(
        reimbursementTx: MoneyTransaction,
        allocations: [(expenseTx: MoneyTransaction, amount: Double)],
        trustSender: Bool = false,
        currency: String = AppSettings.currency
    ) -> Result<[SharedExpenseAdjustment], FinancialValidationError> {
        guard !allocations.isEmpty else { return .failure(.invalidReimbursementAmount) }

        var workingActive = adjustmentStore.activeAdjustments
        let senderToken = SharedExpensePrivacy.extractSenderToken(from: reimbursementTx)
        var prepared: [(expense: MoneyTransaction, amount: Double, targetReimbursable: Double)] = []

        for item in allocations {
            let existingAdj = workingActive.first { $0.isActive && $0.originalTransactionID == item.expenseTx.id }
            let alreadyReceived = existingAdj?.totalReceivedReimbursementAmount ?? 0
            let targetReimb = min(item.expenseTx.amount, max(existingAdj?.reimbursableAmount ?? item.amount, alreadyReceived + item.amount))

            let check = SharedExpenseFinancialValidator.validateAllocation(
                expenseTxID: item.expenseTx.id,
                expenseDate: item.expenseTx.date,
                expenseTotalAmount: item.expenseTx.amount,
                expenseReimbursableCap: targetReimb,
                reimbursementTxID: reimbursementTx.id,
                reimbursementDate: reimbursementTx.date,
                reimbursementTotalAmount: reimbursementTx.amount,
                requestedAmount: item.amount,
                existingActiveAdjustments: workingActive
            )
            if case .failure(let err) = check {
                return .failure(err)
            }
            prepared.append((item.expenseTx, item.amount, targetReimb))

            let tempAlloc = ReimbursementAllocation(reimbursementTransactionID: reimbursementTx.id, allocatedAmount: item.amount, senderToken: senderToken)
            if let idx = workingActive.firstIndex(where: { $0.isActive && $0.originalTransactionID == item.expenseTx.id }) {
                workingActive[idx].reimbursementAllocations.append(tempAlloc)
                workingActive[idx].reimbursableAmount = targetReimb
                workingActive[idx].personalAmount = max(0, item.expenseTx.amount - targetReimb)
            } else {
                workingActive.append(SharedExpenseAdjustment(
                    originalTransactionID: item.expenseTx.id,
                    reimbursementAllocations: [tempAlloc],
                    originalExpenseAmount: item.expenseTx.amount,
                    personalAmount: max(0, item.expenseTx.amount - targetReimb),
                    reimbursableAmount: targetReimb,
                    effectiveCategoryRaw: item.expenseTx.categoryRaw,
                    aiConfidence: 1.0,
                    explanation: "Manually linked reimbursement",
                    confirmationSource: .userConfirmed
                ))
            }
        }

        var results: [SharedExpenseAdjustment] = []
        for item in prepared {
            let alloc = ReimbursementAllocation(reimbursementTransactionID: reimbursementTx.id, allocatedAmount: item.amount, senderToken: senderToken)
            let adjustment: SharedExpenseAdjustment
            if var existing = adjustmentStore.activeAdjustment(forExpenseID: item.expense.id) {
                existing.reimbursementAllocations.append(alloc)
                existing.reimbursableAmount = item.targetReimbursable
                existing.personalAmount = max(0, roundMoney(item.expense.amount - item.targetReimbursable, currency: currency))
                existing.aiConfidence = 1.0
                existing.timestamp = Date()
                adjustment = existing
            } else {
                adjustment = SharedExpenseAdjustment(
                    originalTransactionID: item.expense.id,
                    reimbursementAllocations: [alloc],
                    originalExpenseAmount: item.expense.amount,
                    personalAmount: max(0, roundMoney(item.expense.amount - item.targetReimbursable, currency: currency)),
                    reimbursableAmount: item.targetReimbursable,
                    effectiveCategoryRaw: item.expense.categoryRaw,
                    aiConfidence: 1.0,
                    explanation: "Manually linked reimbursement of \(Money.format(item.amount, currency)).",
                    timestamp: Date(),
                    confirmationSource: .userConfirmed
                )
            }
            adjustmentStore.upsertAdjustment(adjustment)
            if let pending = adjustmentStore.pendingSuggestion(forTransactionID: item.expense.id) {
                adjustmentStore.markSuggestion(pending.id, status: .confirmed)
            }
            let delayHours = max(0, reimbursementTx.date.timeIntervalSince(item.expense.date) / 3600.0)
            memoryStore.record(SharedExpenseMemoryRecord(
                transactionID: item.expense.id.uuidString,
                relationshipType: .reimbursementPattern,
                confirmedCategory: adjustment.effectiveCategoryRaw ?? item.expense.categoryRaw,
                personalAmount: adjustment.personalAmount,
                reimbursableAmount: adjustment.reimbursableAmount,
                confirmationSource: .userConfirmed,
                confidence: 1.0,
                merchantKey: SharedExpensePrivacy.normalizedMerchantKey(item.expense.merchant),
                senderToken: senderToken,
                reimbursementDelayHours: delayHours,
                wasPartialRepayment: adjustment.outstandingReimbursementAmount > SharedExpenseFinancialValidator.epsilon
            ))
            results.append(adjustment)
        }

        if trustSender {
            memoryStore.setSenderTrusted(senderToken, trusted: true)
        }

        Ledger.notifyDataChanged()
        return .success(results)
    }

    /// Rejects a suggestion, keeps original transaction and budget unchanged,
    /// and records negative feedback in learning memory to suppress repeat false suggestions.
    func rejectSuggestion(_ suggestion: SharedExpenseSuggestion, expenseTransaction: MoneyTransaction?) {
        adjustmentStore.markSuggestion(suggestion.id, status: .rejected)
        let merchantKey = expenseTransaction.map { SharedExpensePrivacy.normalizedMerchantKey($0.merchant) } ?? ""
        memoryStore.record(SharedExpenseMemoryRecord(
            transactionID: suggestion.expenseTransactionID.uuidString,
            relationshipType: .rejectedSuggestion,
            confirmedCategory: suggestion.suggestedCategoryRaw,
            personalAmount: suggestion.originalExpenseAmount,
            reimbursableAmount: 0,
            confirmationSource: .userConfirmed,
            confidence: 1.0,
            merchantKey: merchantKey
        ))
        Ledger.notifyDataChanged()
    }

    /// Reverses an automatic or user-confirmed adjustment without modifying any original bank transaction.
    @discardableResult
    func reverseAdjustment(id: UUID, reason: String = "Reversed by user") -> SharedExpenseAdjustment? {
        let reversed = adjustmentStore.reverseAdjustment(id: id, reason: reason, memoryStore: memoryStore)
        if reversed != nil {
            Ledger.notifyDataChanged()
        }
        return reversed
    }

    // MARK: - Multi-Expense Bundle Helper (1 Reimbursement Covering Multiple Expenses)

    private struct MultiExpenseBundleResult {
        let links: [(expense: MoneyTransaction, amount: Double)]
        let confidence: Double
        let corroborationCount: Int
        let explanation: String
        let anyRuleConflict: Bool
    }

    private func findMultiExpenseBundlePlan(
        incomingTx: MoneyTransaction,
        availableCapacity: Double,
        candidates: [MoneyTransaction],
        senderToken: String?,
        incomingHasCue: Bool,
        incomingHasRule: Bool,
        aiAssessment: SharedExpenseAIReimbursementAssessment?,
        currency: String
    ) -> MultiExpenseBundleResult? {
        guard candidates.count >= 2 else { return nil }

        // First check if AI explicitly proposed a multi-expense bundle and validate it deterministically
        if let ai = aiAssessment, ai.links.count >= 2 {
            var resolved: [(expense: MoneyTransaction, amount: Double)] = []
            var sum = 0.0
            for l in ai.links {
                if let exp = candidates.first(where: { $0.id == l.expenseID }), l.allocatedAmount <= exp.amount + 0.01 {
                    resolved.append((exp, l.allocatedAmount))
                    sum += l.allocatedAmount
                }
            }
            if resolved.count >= 2 && abs(sum - availableCapacity) <= 0.10 {
                let anyRule = incomingHasRule || resolved.contains { hasExistingRuleProvider($0.expense) }
                return MultiExpenseBundleResult(
                    links: resolved,
                    confidence: min(0.95, ai.confidence),
                    corroborationCount: 2,
                    explanation: ai.explanation.isEmpty ? "Incoming transfer covers multiple recent shared expenses." : ai.explanation,
                    anyRuleConflict: anyRule
                )
            }
        }

        // Deterministic check: 2-expense subset whose outstanding/predicted reimbursable shares sum to availableCapacity
        struct ShareCandidate {
            let expense: MoneyTransaction
            let share: Double
            let hasStrongPrior: Bool
        }
        let shareCandidates: [ShareCandidate] = candidates.compactMap { exp in
            if let adj = adjustmentStore.activeAdjustment(forExpenseID: exp.id),
               adj.outstandingReimbursementAmount > SharedExpenseFinancialValidator.epsilon {
                return ShareCandidate(expense: exp, share: adj.outstandingReimbursementAmount, hasStrongPrior: true)
            }
            if let pred = adjustmentStore.prediction(forTransactionID: exp.id),
               pred.sharedProbability >= 0.45,
               pred.estimatedReimbursableAmount > SharedExpenseFinancialValidator.epsilon {
                return ShareCandidate(expense: exp, share: pred.estimatedReimbursableAmount, hasStrongPrior: true)
            }
            return nil
        }
        guard shareCandidates.count >= 2 else { return nil }

        let senderPrior = memoryStore.prior(merchant: "", categoryRaw: "", senderToken: senderToken)
        for i in 0..<shareCandidates.count {
            for j in (i + 1)..<shareCandidates.count {
                let a = shareCandidates[i]
                let b = shareCandidates[j]
                let sum = a.share + b.share
                if abs(sum - availableCapacity) <= 0.08 {
                    var corroborations = 2 // both expenses have explicit shared predictions / outstanding shares
                    var conf = 0.80
                    if senderPrior.knownSenderConfirmationCount > 0 {
                        conf += 0.12
                        corroborations += 1
                    }
                    if incomingHasCue {
                        conf += 0.10
                        corroborations += 1
                    }
                    let anyRule = incomingHasRule || hasExistingRuleProvider(a.expense) || hasExistingRuleProvider(b.expense)
                    let desc = "Incoming transfer of \(Money.format(availableCapacity, currency)) matches the combined reimbursable shares of \(a.expense.merchant) (\(Money.format(a.share, currency))) and \(b.expense.merchant) (\(Money.format(b.share, currency)))."
                    return MultiExpenseBundleResult(
                        links: [(a.expense, a.share), (b.expense, b.share)],
                        confidence: min(0.97, conf),
                        corroborationCount: corroborations,
                        explanation: desc,
                        anyRuleConflict: anyRule
                    )
                }
            }
        }
        return nil
    }

    private func roundMoney(_ value: Double, currency: String) -> Double {
        let factor = pow(10.0, Double(Money.digits(currency)))
        return (value * factor).rounded() / factor
    }
}
