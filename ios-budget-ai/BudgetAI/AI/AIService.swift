import Foundation
import SwiftData

struct AIFinding: Codable, Identifiable, Hashable {
    var id: String { title }
    let title: String
    let detail: String
    let kind: String   // saving | warning | tip | positive

    var symbol: String {
        switch kind {
        case "warning": "chart.line.uptrend.xyaxis"
        case "positive": "checkmark.seal.fill"
        case "saving": "scissors"
        default: "lightbulb.fill"
        }
    }
}

enum AIService {
    // MARK: Context

    static func financialContext(_ f: Finance, transactions: [MoneyTransaction]) -> String {
        let code = AppSettings.currency
        func m(_ v: Double) -> String { Money.format(v, code) }
        var lines: [String] = []
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        lines.append("Today: \(df.string(from: f.now)). Currency: \(code). Days left in month: \(f.daysLeftInMonth).")
        lines.append("Spendable balance (cash + bank): \(m(f.liquidBalance)). Net worth: \(m(f.netWorth)). Assets: \(m(f.totalAssets)). Liabilities: \(m(f.totalLiabilities)).")
        lines.append("Accounts: " + f.accounts.map { "\($0.name) [\($0.kind.title)] \(m($0.balance))" }.joined(separator: "; "))
        lines.append("This month income \(m(f.monthIncome)), spending \(m(f.monthExpenses)). Last month income \(m(f.income(in: f.lastMonth))), spending \(m(f.expenses(in: f.lastMonth))).")
        let thisCats = f.categoryBreakdown(in: f.thisMonth).map { "\($0.category.title) \(m($0.amount))" }.joined(separator: ", ")
        let lastCats = f.categoryBreakdown(in: f.lastMonth).map { "\($0.category.title) \(m($0.amount))" }.joined(separator: ", ")
        lines.append("Spending by category this month: \(thisCats.isEmpty ? "none" : thisCats).")
        lines.append("Spending by category last month: \(lastCats.isEmpty ? "none" : lastCats).")
        if !f.budgets.isEmpty {
            lines.append("Budgets: " + f.budgets.map { "\($0.category.title) \(m(f.spent($0.category, in: f.thisMonth))) of \(m($0.limit))" }.joined(separator: "; "))
        }
        if !f.bills.isEmpty {
            lines.append("Bills & subscriptions: " + f.bills.map { "\($0.name) \(m($0.amount)) \($0.frequency.title.lowercased())\($0.isSubscription ? " (subscription)" : ""), next due \(df.string(from: $0.nextDueDate))" }.joined(separator: "; "))
        }
        if !f.goals.isEmpty {
            lines.append("Savings goals: " + f.goals.map { "\($0.name) \(m($0.saved)) of \(m($0.target)) by \(df.string(from: $0.targetDate)), commits \(m($0.monthlyCommitment))/month" }.joined(separator: "; "))
        }
        let s = f.safeToSpend
        lines.append("Safe to spend: \(m(s.monthly)) for the rest of the month, \(m(s.daily)) per day.")
        lines.append("Forecast end-of-month spendable balance: \(m(f.forecastEndOfMonth)). Projected savings this month: \(m(f.projectedSavings)).")
        let recurring = f.recurringCandidates().map { "\($0.name) ~\(m($0.amount))" }.joined(separator: ", ")
        if !recurring.isEmpty { lines.append("Untracked recurring payments detected: \(recurring).") }
        let recent = transactions.filter { !$0.isPending }.sorted { $0.date > $1.date }.prefix(40).map {
            "\(df.string(from: $0.date)) \($0.merchant) \($0.isIncome ? "+" : "-")\(Money.number($0.amount, decimals: Money.digits(code))) [\($0.displayCategory.title)]"
        }
        lines.append("Recent transactions:\n" + recent.joined(separator: "\n"))
        return lines.joined(separator: "\n")
    }

    // MARK: SMS parsing

    static func parseSMS(_ text: String, sender: String? = nil, context: ModelContext? = nil) async throws -> ParsedSMS? {
        let normalized = SMSParser.normalizeText(text)
        if SMSParser.nonTransactionReason(normalized) != nil { return nil }

        let client = try GeminiAccount.client()
        let categories = SpendCategory.allCases.map(\.rawValue)
        let txTypes = SMSTransactionType.allCases.map(\.rawValue)
        let names = SpendCategory.allCases.map { cat -> String in
            let subs = cat.subcategories.map { "\($0.rawValue) (\($0.title))" }.joined(separator: ", ")
            return subs.isEmpty ? "\(cat.rawValue) (\(cat.title))" : "\(cat.rawValue) (\(cat.title); subcategories: \(subs))"
        }.joined(separator: "; ")

        var learnedSection = ""
        if let context {
            let examples = Categorizer.learnedExamples(in: context, limit: 40)
            if !examples.isEmpty {
                let lines = examples.map { "\($0.key) -> \($0.value)" }.sorted().joined(separator: "\n")
                learnedSection = "\nUser's past merchant categorizations (prefer these for matching merchants):\n" + lines
            }
        }

        let schema: [String: Any] = [
            "type": "OBJECT",
            "properties": [
                "isTransaction": ["type": "BOOLEAN"],
                "transactionType": ["type": "STRING", "enum": txTypes],
                "confidence": ["type": "STRING", "enum": ["high", "medium", "low"]],
                "classificationReason": ["type": "STRING"],
                "amount": ["type": "NUMBER"],
                "currency": ["type": "STRING"],
                "isIncome": ["type": "BOOLEAN"],
                "merchant": ["type": "STRING"],
                "category": ["type": "STRING", "enum": categories],
                "subcategory": ["type": "STRING", "nullable": true],
                "paymentMethod": ["type": "STRING", "nullable": true],
                "referenceNumber": ["type": "STRING", "nullable": true],
                "recipientSuffix": ["type": "STRING", "nullable": true],
                "date": ["type": "STRING", "nullable": true],
                "bank": ["type": "STRING", "nullable": true],
                "cardLast4": ["type": "STRING", "nullable": true],
                "availableBalance": ["type": "NUMBER", "nullable": true],
            ],
            "required": ["isTransaction", "transactionType", "confidence", "amount", "isIncome", "merchant", "category"],
        ]
        let system = """
        You read bank and wallet SMS alerts from Bahrain and the GCC in English or Arabic (including NBB, BBK, BisB, ila Bank, \
        KFH, Al Salam Bank, BenefitPay, Fawri+, Fawri) and extract one financial transaction.
        CRITICAL RULES:
        1. Set isTransaction=false for OTPs, verification codes, declined/failed alerts, promotional offers, or balance-only inquiries.
        2. Fawri+ is an interbank transfer service in Bahrain. Do NOT classify Fawri+ as ordinary income or ordinary expense. \
        Specifically, "Fawri+ payment BHD..., ref: BIB... was credited to IBAN ending XXXX ... Balance BHD..." is a sender notification \
        meaning the outgoing transfer was credited to the recipient's IBAN -> transactionType="transfer_out", isIncome=false, category="transfers".
        3. Use transactionType="transfer_in" for incoming bank/Fawri+ transfers, "transfer_out" for outgoing bank/Fawri+ transfers, \
        "internal_transfer" for transfers between the user's own accounts, "fee" for bank fees/charges, "refund" for purchase refunds/reversals, \
        "income" for salary/payroll/dividends, "expense" for card/POS/bill purchases, and "unknown" (with confidence="low") when direction or type is ambiguous.
        4. Never guess a bank when confidence is low (return bank=null if uncertain).
        5. Distinguish the transaction amount from the reported account balance (availableBalance).
        category must be one of these keys: \(names).\(learnedSection)
        """
        let reply = try await client.generate(system: system, turns: [GeminiTurn(isUser: true, text: normalized)], schema: schema, temperature: 0.1)
        let obj = try GeminiClient.decodeObject(reply)
        guard (obj["isTransaction"] as? Bool) == true, let amount = (obj["amount"] as? NSNumber)?.doubleValue, amount > 0 else { return nil }

        let fallbackParsed = SMSParser.parse(normalized, sender: sender, context: context)
        let txType = SMSTransactionType(rawValue: obj["transactionType"] as? String ?? "") ?? fallbackParsed?.transactionType ?? .unknown
        let confidence = SMSConfidence(rawValue: obj["confidence"] as? String ?? "") ?? (txType == .unknown ? .low : .medium)
        let isIncome = txType.isIncomeDirection

        var category = SpendCategory(rawValue: obj["category"] as? String ?? "") ?? .other
        if txType.isTransferType {
            category = .transfers
        } else if txType == .income && !category.isIncomeCategory {
            category = .income
        } else if txType == .unknown {
            category = .other
        }

        var subcategory: SpendCategory?
        if !txType.isTransferType,
           let subRaw = (obj["subcategory"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !subRaw.isEmpty {
            let candidates = category.subcategories
            subcategory = candidates.first(where: { $0.rawValue.caseInsensitiveCompare(subRaw) == .orderedSame || $0.title.caseInsensitiveCompare(subRaw) == .orderedSame })
        }

        let (fallbackDate, fallbackTime) = SMSParser.extractDateAndTime(in: normalized)
        var date: Date? = fallbackDate
        if date == nil, let ds = obj["date"] as? String {
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.dateFormat = "yyyy-MM-dd"
            if let d = df.date(from: ds) {
                date = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: d)
            }
        }

        let rawMerchant = (obj["merchant"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanMerchant = (rawMerchant?.isEmpty == false ? rawMerchant! : (fallbackParsed?.merchant ?? "Bank SMS"))

        if !txType.isTransferType, let context, let learned = Categorizer.learnedMatch(for: cleanMerchant, in: context, isIncome: isIncome) {
            category = learned.category
            if learned.subcategory != nil { subcategory = learned.subcategory }
        }

        let bankInfo = SMSParser.identifyBank(in: normalized, sender: sender)
        let resolvedBank = bankInfo.bank
        let suffixes = SMSParser.extractSuffixes(in: normalized)
        let ref = (obj["referenceNumber"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? SMSParser.referenceNumber(in: normalized)
        let reason = (obj["classificationReason"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "AI fallback classification"

        return ParsedSMS(
            amount: amount,
            currency: (obj["currency"] as? String) ?? fallbackParsed?.currency,
            isIncome: isIncome,
            merchant: cleanMerchant,
            category: category,
            subcategory: subcategory ?? fallbackParsed?.subcategory,
            date: date,
            accountHint: resolvedBank,
            cardDigits: suffixes.accountSuffix ?? (obj["cardLast4"] as? String),
            balance: (obj["availableBalance"] as? NSNumber)?.doubleValue ?? SMSParser.balance(in: normalized),
            note: fallbackParsed?.note ?? (obj["paymentMethod"] as? String),
            transactionType: txType,
            detectedBank: resolvedBank,
            bankConfidence: bankInfo.confidence,
            confidence: confidence,
            classificationReason: reason,
            referenceNumber: ref,
            accountSuffix: suffixes.accountSuffix ?? (obj["cardLast4"] as? String),
            recipientSuffix: suffixes.recipientSuffix ?? (obj["recipientSuffix"] as? String),
            timeString: fallbackTime,
            sender: sender,
            toAccountID: fallbackParsed?.toAccountID
        )
    }

    // MARK: Categorization

    static func categorize(merchants: [String]) async throws -> [String: SpendCategory] {
        guard !merchants.isEmpty else { return [:] }
        let client = try GeminiAccount.client()
        let categories = SpendCategory.expenseCases.map(\.rawValue)
        let names = SpendCategory.expenseCases.map { "\($0.rawValue) (\($0.title))" }.joined(separator: ", ")
        let schema: [String: Any] = [
            "type": "OBJECT",
            "properties": ["items": ["type": "ARRAY", "items": [
                "type": "OBJECT",
                "properties": ["merchant": ["type": "STRING"], "category": ["type": "STRING", "enum": categories]],
                "required": ["merchant", "category"],
            ]]],
            "required": ["items"],
        ]
        let prompt = "Categorize these merchants (Bahrain/GCC context). Category keys: \(names).\n" + merchants.joined(separator: "\n")
        let reply = try await client.generate(system: nil, turns: [GeminiTurn(isUser: true, text: prompt)], schema: schema, temperature: 0.1)
        let obj = try GeminiClient.decodeObject(reply)
        var out: [String: SpendCategory] = [:]
        for item in obj["items"] as? [[String: Any]] ?? [] {
            if let name = item["merchant"] as? String, let cat = SpendCategory(rawValue: item["category"] as? String ?? "") {
                out[name] = cat
            }
        }
        return out
    }

    // MARK: Insights

    static func findings(context: String) async throws -> [AIFinding] {
        let client = try GeminiAccount.client()
        let schema: [String: Any] = [
            "type": "OBJECT",
            "properties": ["findings": ["type": "ARRAY", "items": [
                "type": "OBJECT",
                "properties": [
                    "title": ["type": "STRING"],
                    "detail": ["type": "STRING"],
                    "kind": ["type": "STRING", "enum": ["saving", "warning", "tip", "positive"]],
                ],
                "required": ["title", "detail", "kind"],
            ]]],
            "required": ["findings"],
        ]
        let system = """
        You are a sharp, warm personal finance advisor. From the user's data, return 4 findings: unnecessary or rising \
        expenses, subscriptions worth cancelling, concrete saving moves with amounts, and one positive note when deserved. \
        Titles under 60 characters, specific with amounts in the user's currency. Details one or two short sentences. \
        Never invent data that isn't present.
        """
        let reply = try await client.generate(system: system, turns: [GeminiTurn(isUser: true, text: context)], schema: schema, temperature: 0.5)
        let obj = try GeminiClient.decodeObject(reply)
        let items = obj["findings"] as? [[String: Any]] ?? []
        return items.compactMap {
            guard let t = $0["title"] as? String, let d = $0["detail"] as? String else { return nil }
            return AIFinding(title: t, detail: d, kind: $0["kind"] as? String ?? "tip")
        }
    }

    /// Rule-based findings so Insights is useful even before Gemini is connected.
    static func localFindings(_ f: Finance) -> [AIFinding] {
        let code = AppSettings.currency
        var out: [AIFinding] = []
        let now = f.categoryBreakdown(in: f.thisMonth)
        let last = Dictionary(uniqueKeysWithValues: f.categoryBreakdown(in: f.lastMonth).map { ($0.category, $0.amount) })
        let progress = Double(f.daysElapsed) / Double(f.daysElapsed + f.daysLeftInMonth - 1)
        if let rising = now.first(where: { item in
            guard let prev = last[item.category], prev > 0 else { return false }
            return item.amount / max(progress, 0.1) > prev * 1.2
        }), let prev = last[rising.category] {
            let pace = rising.amount / max(progress, 0.1)
            out.append(AIFinding(title: "\(rising.category.title) on pace for +\(Int((pace / prev - 1) * 100))% vs last month",
                                 detail: "You've spent \(Money.format(rising.amount, code)) so far. Last month's total was \(Money.format(prev, code)).",
                                 kind: "warning"))
        }
        if f.subscriptionsMonthly > 0 {
            let count = f.bills.filter(\.isSubscription).count
            out.append(AIFinding(title: "\(count) subscriptions cost \(Money.format(f.subscriptionsMonthly, code))/mo",
                                 detail: "That's \(Money.format(f.subscriptionsMonthly * 12, code)) a year. Cancel any you haven't used in a month.",
                                 kind: "saving"))
        }
        for c in f.recurringCandidates().prefix(1) {
            out.append(AIFinding(title: "\(c.name) looks like a recurring charge",
                                 detail: "\(c.occurrences) payments of about \(Money.format(c.amount, code)). Track it as a bill so Safe to Spend accounts for it.",
                                 kind: "tip"))
        }
        if f.projectedSavings > 0, let goal = f.goals.first(where: { !$0.isComplete }) {
            let move = (f.projectedSavings * 0.3).rounded()
            if move > 0 {
                out.append(AIFinding(title: "Move \(Money.format(move, code, decimals: 0)) to \(goal.name)",
                                     detail: "You're projected to finish the month \(Money.format(f.projectedSavings, code)) ahead.",
                                     kind: "positive"))
            }
        } else if f.projectedSavings < 0 {
            out.append(AIFinding(title: "Projected shortfall of \(Money.format(-f.projectedSavings, code))",
                                 detail: "Keep daily spending under \(Money.format(f.safeToSpend.daily, code)) to stay on track.",
                                 kind: "warning"))
        }
        return out
    }

    // MARK: Chat

    static func advisorReply(history: [ChatMessage], context: String) async throws -> String {
        let client = try GeminiAccount.client()
        let system = """
        You are Budget AI, a friendly, direct personal finance advisor inside a budgeting app used mainly in Bahrain and the GCC. \
        Use ONLY the user's data below for numbers; if something isn't in the data, say so. Use their currency. \
        Be concise: short paragraphs or up to 5 bullets, bold key amounts with **double asterisks**. \
        Give concrete, actionable steps. You are not a licensed advisor; for investments keep it general.

        USER DATA:
        \(context)
        """
        let turns = history.filter { !$0.isError }.suffix(20).map { GeminiTurn(isUser: $0.isUser, text: $0.text) }
        return try await client.generate(system: system, turns: Array(turns), temperature: 0.6)
    }

    static func testConnection(key: String, model: String) async throws {
        let client = GeminiClient(apiKey: key, model: model)
        _ = try await client.generate(system: nil, turns: [GeminiTurn(isUser: true, text: "Reply with the single word OK.")], temperature: 0)
    }
}

// MARK: - SMS import pipeline (used by the app and the Shortcuts automation)

struct SMSImportOutcome {
    var transaction: MoneyTransaction?
    var batchTransactions: [MoneyTransaction] = []
    var usedAI = false
    var learnedMerchant = false
    var flaggedDuplicate = false
    var alerts: [String] = []
    var pending = false
    var balanceSynced: Double?
    var message: String
}

enum SMSImporter {
    /// - Parameter forceApprove: manual paste from inside the app is applied immediately when confidence is high/medium.
    ///   Uncertain/unknown messages (`requiresReview == true`) are always kept pending for user review.
    static func importText(
        _ text: String,
        context: ModelContext,
        forceApprove: Bool = false,
        accountID: UUID? = nil,
        sender: String? = nil,
        manualBank: String? = nil
    ) async -> SMSImportOutcome {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return SMSImportOutcome(message: "The message was empty.") }
        CategoryRegistry.shared.reload(context: context)

        if let manualBank, !manualBank.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let sender, !sender.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            SMSUserRules.rememberBank(manualBank, forSender: sender)
        }

        let chunks = SMSParser.splitBatch(trimmed)
        if chunks.count > 1 {
            return await importBatch(chunks, context: context, forceApprove: forceApprove, accountID: accountID, sender: sender, manualBank: manualBank)
        }

        return await importSingle(trimmed, context: context, forceApprove: forceApprove, accountID: accountID, sender: sender, manualBank: manualBank)
    }

    private static func importBatch(
        _ chunks: [String],
        context: ModelContext,
        forceApprove: Bool,
        accountID: UUID?,
        sender: String?,
        manualBank: String?
    ) async -> SMSImportOutcome {
        var imported: [MoneyTransaction] = []
        var anyAI = false
        var anyLearned = false
        var anyDuplicate = false
        var allAlerts: [String] = []
        var lastSynced: Double?
        var skippedCount = 0

        for chunk in chunks {
            let single = await importSingle(chunk, context: context, forceApprove: forceApprove, accountID: accountID, sender: sender, manualBank: manualBank)
            if let tx = single.transaction {
                imported.append(tx)
                if single.usedAI { anyAI = true }
                if single.learnedMerchant { anyLearned = true }
                if single.flaggedDuplicate { anyDuplicate = true }
                allAlerts.append(contentsOf: single.alerts)
                if let synced = single.balanceSynced { lastSynced = synced }
            } else {
                skippedCount += 1
            }
        }

        guard let first = imported.first else {
            return SMSImportOutcome(usedAI: anyAI, message: "No transactions found in the \(chunks.count) pasted messages.")
        }

        let code = AppSettings.currency
        let totalNet = imported.reduce(0.0) { $0 + ($1.isIncome ? $1.amount : -$1.amount) }
        var msg = "Imported \(imported.count) transaction\(imported.count == 1 ? "" : "s")"
        if skippedCount > 0 { msg += " (\(skippedCount) skipped)" }
        msg += " · Net \(Money.format(abs(totalNet), code))"

        return SMSImportOutcome(
            transaction: first,
            batchTransactions: imported,
            usedAI: anyAI,
            learnedMerchant: anyLearned,
            flaggedDuplicate: anyDuplicate,
            alerts: allAlerts,
            pending: imported.contains(where: \.isPending),
            balanceSynced: lastSynced,
            message: msg
        )
    }

    private static func importSingle(
        _ trimmed: String,
        context: ModelContext,
        forceApprove: Bool,
        accountID: UUID?,
        sender: String?,
        manualBank: String?
    ) async -> SMSImportOutcome {
        if let reason = SMSParser.nonTransactionReason(trimmed) {
            return SMSImportOutcome(message: reason)
        }

        // 1. Deterministic, bank-specific parsing rules first
        let deterministic = SMSParser.parse(trimmed, sender: sender, context: context)
        var parsed: ParsedSMS? = deterministic
        var usedAI = false

        // 2. Use AI only as a fallback when deterministic parsing is nil or uncertain
        if (deterministic == nil || deterministic?.requiresReview == true) && GeminiAccount.isConfigured {
            do {
                if let aiParsed = try await AIService.parseSMS(trimmed, sender: sender, context: context) {
                    parsed = aiParsed
                    usedAI = true
                }
            } catch {
                // Keep deterministic result on AI error
            }
        }

        guard var p = parsed else {
            return SMSImportOutcome(usedAI: usedAI, message: "No transaction found in this message.")
        }

        var learnedMerchant = false
        if !p.transactionType.isTransferType && p.transactionType != .unknown,
           let learned = Categorizer.learnedMatch(for: p.merchant, in: context, isIncome: p.isIncome) {
            p.category = learned.category
            if learned.subcategory != nil { p.subcategory = learned.subcategory }
            learnedMerchant = true
        }

        let cleanManualBank = manualBank?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedSMSBank = (cleanManualBank?.isEmpty == false ? cleanManualBank : nil) ?? p.detectedBank

        // Determine account involved in the transaction (kept separate from smsBank)
        let matchingDigits: String? = {
            if p.transactionType == .transferIn {
                return p.accountSuffix ?? p.recipientSuffix
            }
            // For outgoing transfers, never match recipientSuffix as the source account
            return p.accountSuffix
        }()
        let target = accountID ?? Ledger.smsAccountID(context: context, digits: matchingDigits, hint: resolvedSMSBank)

        let tx = MoneyTransaction(
            amount: p.amount,
            isIncome: p.isIncome,
            merchant: p.merchant,
            category: p.category,
            date: p.date ?? .now,
            source: .sms,
            accountID: target
        )
        tx.subcategory = p.subcategory
        tx.rawText = trimmed
        tx.aiCategorized = usedAI
        tx.smsBalance = p.balance
        tx.smsBank = resolvedSMSBank
        tx.smsSender = sender?.trimmingCharacters(in: .whitespacesAndNewlines)
        tx.smsTransactionType = p.transactionType
        tx.smsConfidence = p.confidence
        tx.smsClassificationReason = p.classificationReason
        tx.smsReference = p.referenceNumber
        tx.smsAccountSuffix = p.accountSuffix
        tx.smsRecipientSuffix = p.recipientSuffix
        tx.toAccountID = p.toAccountID

        // Uncertain transactions are ALWAYS marked pending for user review rather than silently applied
        if p.requiresReview {
            tx.isPending = true
        } else {
            tx.isPending = !forceApprove && !AppSettings.smsAutoApprove
        }

        let code = AppSettings.currency
        var notes: [String] = []
        if let rail = p.note, !rail.isEmpty { notes.append(rail) }
        if let c = p.currency, !c.isEmpty, c.uppercased() != code {
            notes.append("Original currency: \(c.uppercased())")
            tx.smsBalance = nil
        }
        if !notes.isEmpty {
            tx.note = notes.joined(separator: " · ")
        }

        let result = Ledger.add(tx, context: context)
        let typeLabel = p.transactionType.title
        var summary = "\(typeLabel) \(Money.format(tx.amount, code)) · \(tx.merchant)"
        if p.requiresReview {
            summary = "Needs review: " + summary
        } else if tx.isPending {
            summary = "Waiting for approval: " + summary
        }
        if result.flaggedDuplicate { summary += " (possible duplicate)" }
        if let synced = result.balanceSynced { summary += ". Balance matched to bank: \(Money.format(synced, code))" }
        return SMSImportOutcome(
            transaction: tx,
            batchTransactions: [tx],
            usedAI: usedAI,
            learnedMerchant: learnedMerchant,
            flaggedDuplicate: result.flaggedDuplicate,
            alerts: result.alerts,
            pending: tx.isPending,
            balanceSynced: result.balanceSynced,
            message: summary
        )
    }
}
