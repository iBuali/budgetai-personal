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
            lines.append("Budgets: " + f.budgets.map { "\($0.displayName) \(m(f.spent(for: $0, in: f.thisMonth))) of \(m($0.limit))" }.joined(separator: "; "))
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
        2b. "Thank you for paying BHD ... for your VISA ... card. Available Bal BHD ..." is a credit card bill payment from the user's bank \
        account -> transactionType="internal_transfer", isIncome=false, category="visa_transfer". The Available Bal is the card's available limit.
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

        var category = SpendCategory.resolve(obj["category"] as? String)
        if category == .visaTransfer {
            // Keep the credit card payment category; it's handled as a transfer to the card.
        } else if txType.isTransferType {
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
            toAccountID: fallbackParsed?.toAccountID,
            goalID: fallbackParsed?.goalID
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
        You are FALAK, a friendly, direct personal finance advisor inside a budgeting app used mainly in Bahrain and the GCC. \
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
        manualBank: String? = nil,
        location: String? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil,
        autoCaptureLocation: Bool = false
    ) async -> SMSImportOutcome {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return SMSImportOutcome(message: "The message was empty.") }
        CategoryRegistry.shared.reload(context: context)

        let chunks = SMSParser.splitBatch(trimmed)
        if chunks.count > 1 {
            return await importBatch(
                chunks,
                context: context,
                forceApprove: forceApprove,
                accountID: accountID,
                sender: sender,
                manualBank: manualBank,
                location: location,
                latitude: latitude,
                longitude: longitude,
                autoCaptureLocation: autoCaptureLocation
            )
        }

        return await importSingle(
            trimmed,
            context: context,
            forceApprove: forceApprove,
            accountID: accountID,
            sender: sender,
            manualBank: manualBank,
            location: location,
            latitude: latitude,
            longitude: longitude,
            autoCaptureLocation: autoCaptureLocation
        )
    }

    private static func importBatch(
        _ chunks: [String],
        context: ModelContext,
        forceApprove: Bool,
        accountID: UUID?,
        sender: String?,
        manualBank: String?,
        location: String? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil,
        autoCaptureLocation: Bool = false
    ) async -> SMSImportOutcome {
        var imported: [MoneyTransaction] = []
        var anyAI = false
        var anyLearned = false
        var anyDuplicate = false
        var allAlerts: [String] = []
        var lastSynced: Double?
        var skippedCount = 0

        for chunk in chunks {
            let single = await importSingle(
                chunk,
                context: context,
                forceApprove: forceApprove,
                accountID: accountID,
                sender: sender,
                manualBank: manualBank,
                location: location,
                latitude: latitude,
                longitude: longitude,
                autoCaptureLocation: autoCaptureLocation
            )
            if let tx = single.transaction {
                if !imported.contains(where: { $0.id == tx.id }) {
                    imported.append(tx)
                }
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
        manualBank: String?,
        location: String? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil,
        autoCaptureLocation: Bool = false
    ) async -> SMSImportOutcome {
        if let reason = SMSParser.nonTransactionReason(trimmed) {
            return SMSImportOutcome(message: reason)
        }

        // Fetch the SMS sender ID / bank phone number from the message first if Shortcuts did not pass it
        let effectiveSender = SMSParser.extractSenderOrPhone(in: trimmed, explicitSender: sender)

        // 1. Deterministic, bank-specific parsing rules first
        let deterministic = SMSParser.parse(trimmed, sender: effectiveSender, context: context)
        var parsed: ParsedSMS? = deterministic
        var usedAI = false

        // 2. Use AI only as a fallback when deterministic parsing is nil or uncertain (bounded to 1.5s to avoid Shortcuts watchdog timeouts)
        if (deterministic == nil || deterministic?.requiresReview == true) && GeminiAccount.isConfigured {
            do {
                let aiParsed: ParsedSMS? = try await withThrowingTaskGroup(of: ParsedSMS?.self) { group in
                    group.addTask {
                        try await AIService.parseSMS(trimmed, sender: effectiveSender, context: context)
                    }
                    group.addTask {
                        try await Task.sleep(nanoseconds: 1_500_000_000)
                        return nil
                    }
                    let res = try await group.next() ?? nil
                    group.cancelAll()
                    return res
                }
                if let aiParsed {
                    parsed = aiParsed
                    usedAI = true
                }
            } catch {
                // Keep deterministic result on AI error or timeout
            }
        }

        guard var p = parsed else {
            return SMSImportOutcome(usedAI: usedAI, message: "No transaction found in this message.")
        }

        let cleanManualBank = manualBank?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedSMSBank = (cleanManualBank?.isEmpty == false ? cleanManualBank : nil)
            ?? p.detectedBank
        let resolvedSender = effectiveSender ?? p.sender

        // Determine account involved in the transaction (supports multiple accounts e.g. 17515151 -> BisB, 17123456 -> ila).
        // Never use `recipientSuffix` as `matchingDigits` because `recipientSuffix` is always the external counterparty's IBAN/account!
        let matchingDigits: String? = p.accountSuffix ?? p.cardDigits

        // Highest-priority check: did the SMS match an account's configured `smsMatch` (card or account digits)?
        let explicitDigitMatchedAccount: Account? = {
            if let d = matchingDigits, let acc = SMSParser.findMatchingAccount(suffix: d, in: context) {
                return acc
            }
            if let acc = SMSParser.findAccountInSMSText(trimmed, detectedBank: resolvedSMSBank, in: context) {
                if let b = resolvedSMSBank, !b.isEmpty, acc.kind != .creditCard,
                   let accBank = SMSParser.bankName(forAccount: acc),
                   accBank.caseInsensitiveCompare(b) != .orderedSame,
                   !((accBank == "ila" && b == "Bank ABC") || (accBank == "Bank ABC" && b == "ila")),
                   SMSParser.findMatchingAccount(forBank: b, senderOrPhone: resolvedSender, digits: nil, in: context) != nil {
                    return nil
                }
                return acc
            }
            return nil
        }()

        // If digits weren't extracted by regex, check if the raw SMS text contains any account's configured smsMatch
        let directAccountFromSMS: Account? = explicitDigitMatchedAccount ?? {
            if let d = matchingDigits, let acc = SMSParser.findMatchingAccount(forBank: resolvedSMSBank, senderOrPhone: resolvedSender, digits: d, in: context) {
                return acc
            }
            return nil
        }()

        let savedRuleAccount: UUID? = {
            func isCompatible(_ acc: Account) -> Bool {
                if p.matchedUserRule { return true }
                if let explicit = explicitDigitMatchedAccount, explicit.id == acc.id { return true }
                if let b = resolvedSMSBank, !b.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   acc.kind != .creditCard,
                   SMSParser.bankName(forAccount: acc) != nil,
                   !SMSParser.accountMatchesBank(acc, bank: b) {
                    return false
                }
                if let d = matchingDigits, !d.isEmpty,
                   !acc.smsMatch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   !SMSParser.digitsMatch(accountMatch: acc.smsMatch, query: d) {
                    return false
                }
                return true
            }
            if let ruleAccID = p.accountID, let acc = Ledger.account(ruleAccID, context: context), isCompatible(acc) {
                return ruleAccID
            }
            return nil
        }()
        // Never fall back to a default/first account when the SMS bank or account digits do not match any user account.
        var target: UUID? = accountID
            ?? (p.matchedUserRule ? savedRuleAccount : nil)
            ?? explicitDigitMatchedAccount?.id
            ?? savedRuleAccount
            ?? directAccountFromSMS?.id
            ?? SMSParser.findMatchingAccount(forBank: resolvedSMSBank, senderOrPhone: resolvedSender, digits: matchingDigits, in: context)?.id

        // Visa / credit card payments come out of a bank account and pay down the card.
        let isCardPayment = p.category == .visaTransfer
        if isCardPayment {
            if p.toAccountID == nil || Ledger.account(p.toAccountID!, context: context) == nil {
                p.toAccountID = SMSParser.findCreditCardAccount(cardName: nil, in: context)?.id
            }
            let targetAccount = target.flatMap { Ledger.account($0, context: context) }
            if accountID == nil, targetAccount == nil || targetAccount?.kind.isLiquid == false || target == p.toAccountID {
                if let matchedBankAcc = SMSParser.findMatchingAccount(forBank: resolvedSMSBank, senderOrPhone: resolvedSender, in: context), matchedBankAcc.kind.isLiquid {
                    target = matchedBankAcc.id
                } else if resolvedSMSBank == nil {
                    target = Ledger.defaultLiquidAccountID(context: context, hint: nil)
                }
            }
        }

        // NOTE: Rule 6 (Internal Transfer between own accounts or matching recipient IBAN/account)
        // ONLY applies when TWO SMS messages match in date & time (handled below in `mergeSameTimeTransferIfNeeded`).
        // A single SMS with a matching recipient IBAN/account is never marked as `.internalTransfer` on its own.
        // Savings Goal Link works automatically ONLY if it is marked as internal transfer (or manually added).
        if p.goalID == nil, !isCardPayment,
           (p.category == .internalTransfer || p.transactionType == .internalTransfer),
           let matchedGoal = SMSParser.findMatchingGoal(suffix: p.recipientSuffix, accountID: p.toAccountID, in: context),
           matchedGoal.linkedAccountID == nil || matchedGoal.linkedAccountID != target {
            p.goalID = matchedGoal.id
            if p.toAccountID == nil, let linkedAcc = matchedGoal.linkedAccountID, linkedAcc != target {
                p.toAccountID = linkedAcc
            }
        }

        // Preserve the pre-conversion transfer type so we can detect & merge simultaneous transfer SMS
        // (e.g., when a transfer between two accounts generates one "Internal Transfer" SMS and one "Transfer Out" SMS at the same date & time).
        let rawParsedType = p.transactionType

        // Automatically resolve purchase location:
        // 1. Explicit coordinates / address from Shortcuts automation ("Get Current Location")
        // 2. Real-time GPS capture when triggered by live SMS automation (AddBankSMSIntent)
        // 3. Fallback inference from SMS text & merchant keywords
        let resolvedLocationData = await LocationService.shared.resolveLocation(
            rawInput: location,
            latitude: latitude,
            longitude: longitude,
            rawSMS: trimmed,
            merchant: p.merchant,
            autoCaptureGPS: autoCaptureLocation
        )

        if !isCardPayment,
           let sameRefMerged = mergeSameReferenceSameAccountSMSIfNeeded(
               parsed: p,
               rawSMS: trimmed,
               resolvedBank: resolvedSMSBank,
               resolvedSender: resolvedSender,
               matchingDigits: matchingDigits,
               targetAccountID: target,
               resolvedLocation: resolvedLocationData,
               usedAI: usedAI,
               forceApprove: forceApprove,
               context: context
           ) {
            return sameRefMerged
        }

        if !isCardPayment,
           (rawParsedType.isTransferType
            || p.category == .internalTransfer
            || p.category == .transfers
            || (p.referenceNumber?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            || (p.isIncome && (trimmed.lowercased().contains("credit") || trimmed.lowercased().contains("fawri") || trimmed.contains("إيداع") || trimmed.contains("ايداع") || trimmed.contains("وارد")))
            || (!p.isIncome && (trimmed.lowercased().contains("debit") || trimmed.lowercased().contains("transfer") || trimmed.contains("خصم") || trimmed.contains("صادر")))),
           let mergedOutcome = mergeSameTimeTransferIfNeeded(
               parsed: p,
               rawParsedType: rawParsedType,
               rawSMS: trimmed,
               resolvedBank: resolvedSMSBank,
               resolvedSender: resolvedSender,
               targetAccountID: target,
               resolvedLocation: resolvedLocationData,
               usedAI: usedAI,
               forceApprove: forceApprove,
               context: context
           ) {
            return mergedOutcome
        }

        // Keep unidentified transfers / debit / credit / Visa payments in the Transfers tab
        // unless a user rule, learned history, or AI identifies a specific expense/income category.
        var learnedMerchant = false
        if !p.matchedUserRule && p.transactionType != .internalTransfer && !isCardPayment,
           let learned = Categorizer.learnedMatch(for: p.merchant, in: context, isIncome: p.isIncome) {
            p.category = learned.category
            if learned.subcategory != nil { p.subcategory = learned.subcategory }
            if learned.category == .transferIn {
                p.transactionType = .transferIn
                p.isIncome = true
            } else if learned.category == .transfers || learned.category.isTransferCategory {
                p.transactionType = .transferOut
                p.isIncome = false
            } else if learned.category.isIncomeCategory {
                p.transactionType = .income
                p.isIncome = true
            } else {
                p.transactionType = .expense
                p.isIncome = false
            }
            learnedMerchant = true
        }

        // If there is no user rule and no learned history:
        // Let AI identify a specific expense category if the merchant is a real name (not generic IBAN/transfer wording).
        // Otherwise, keep transfers and unidentified debit/credit alerts in the Transfers tab.
        if !p.matchedUserRule && !learnedMerchant && p.transactionType != .internalTransfer && !isCardPayment {
            let lowerSMS = trimmed.lowercased()
            let isGenericTransferLabel = isGenericSMSMerchant(p.merchant)
                || p.merchant.lowercased().hasPrefix("iban ")
                || p.merchant.lowercased().hasPrefix("fawri")
            let hasExplicitIncomeCue =
                lowerSMS.contains("salary") || lowerSMS.contains("payroll") || lowerSMS.contains("wage")
                || lowerSMS.contains("bonus") || lowerSMS.contains("dividend") || lowerSMS.contains("interest")
                || lowerSMS.contains("profit") || lowerSMS.contains("cashback") || lowerSMS.contains("commission")
                || lowerSMS.contains("allowance") || lowerSMS.contains("pension") || lowerSMS.contains("stipend")
                || lowerSMS.contains("راتب") || lowerSMS.contains("مكافأة") || lowerSMS.contains("أرباح")
                || lowerSMS.contains("ارباح")
            let looksLikeGenericCredit = p.transactionType == .income && isGenericTransferLabel && !hasExplicitIncomeCue
            let looksLikeGenericDebit = p.transactionType == .expense && p.category == .other && isGenericTransferLabel
                && (lowerSMS.contains("debit") || lowerSMS.contains("transfer") || lowerSMS.contains("fawri")
                    || lowerSMS.contains("iban") || lowerSMS.contains("خصم") || lowerSMS.contains("تحويل"))

            let needsAICheck = p.category == .other
                || p.confidence == .low
                || p.transactionType == .transferOut
                || p.transactionType == .transferIn
                || p.transactionType == .unknown
                || looksLikeGenericCredit
                || looksLikeGenericDebit
            if needsAICheck {
                if !p.isIncome && !isGenericTransferLabel && GeminiAccount.isConfigured {
                    if let aiCats = try? await AIService.categorize(merchants: [p.merchant]),
                       let aiCat = aiCats[p.merchant],
                       aiCat != .other, !aiCat.isTransferCategory, !aiCat.isIncomeCategory {
                        p.category = aiCat
                        p.transactionType = .expense
                        p.isIncome = false
                        p.confidence = .high
                        usedAI = true
                    }
                }
                if !usedAI {
                    if p.transactionType == .transferOut || looksLikeGenericDebit {
                        p.transactionType = .transferOut
                        p.isIncome = false
                        if !p.category.isTransferCategory { p.category = .transfers }
                    } else if p.transactionType == .transferIn || looksLikeGenericCredit {
                        p.transactionType = .transferIn
                        p.isIncome = true
                        if !p.category.isTransferCategory { p.category = .transferIn }
                    } else if p.transactionType == .unknown && !p.requiresReview {
                        let looksLikeTransferOrGenericDebitCredit =
                            lowerSMS.contains("transfer") || lowerSMS.contains("fawri") || lowerSMS.contains("iban")
                            || lowerSMS.contains("debit") || lowerSMS.contains("credit") || lowerSMS.contains("visa")
                            || lowerSMS.contains("تحويل") || lowerSMS.contains("حوالة")
                            || lowerSMS.contains("خصم") || lowerSMS.contains("إيداع") || lowerSMS.contains("ايداع")
                        if looksLikeTransferOrGenericDebitCredit {
                            p.transactionType = p.isIncome ? .transferIn : .transferOut
                            p.category = p.isIncome ? .transferIn : .transfers
                        }
                    }
                }
            }
        }

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
        tx.smsSender = resolvedSender?.trimmingCharacters(in: .whitespacesAndNewlines)
        tx.smsTransactionType = p.transactionType
        tx.smsConfidence = p.confidence
        tx.smsClassificationReason = p.classificationReason
        tx.smsReference = p.referenceNumber
        tx.smsAccountSuffix = p.accountSuffix ?? matchingDigits
        tx.smsRecipientSuffix = p.recipientSuffix
        tx.toAccountID = p.toAccountID
        tx.goalID = p.goalID
        tx.smsBalanceIsCardLimit = p.balanceIsCardLimit || isCardPayment

        // Attach automatically resolved purchase location
        if let loc = resolvedLocationData ?? LocationService.inferLocation(from: trimmed, merchant: tx.merchant) {
            tx.locationName = loc.name
            tx.locationAddress = loc.address
            tx.latitude = loc.latitude
            tx.longitude = loc.longitude
        }

        // Highest Priority: Apply user-defined Transaction Rules to future matching transactions.
        let matchedHighPriorityRule = TransactionRuleStore.shared.applyHighestPriorityRuleIfMatching(to: tx, context: context)
        if matchedHighPriorityRule != nil {
            p.matchedUserRule = true
            p.category = tx.category
            p.isIncome = tx.isIncome
            if let ruleTxType = tx.smsTransactionType {
                p.transactionType = ruleTxType
            }
            if let ruleAcc = tx.accountID {
                target = ruleAcc
            }
        }

        // Quarantine check:
        // If an SMS has:
        // 1. Unknown sender bank
        // 2. Unmatched account
        // 3. Uncertain classification / low confidence / needs review
        // -> Quarantine: Keep it in the Needs Review filter and DO NOT include in any accounts until approved!
        // (Note: Unmatched balances are not quarantined; balance syncing handles bank balance updates automatically)
        let allAccounts = (try? context.fetch(FetchDescriptor<Account>())) ?? []
        let targetAccount = target.flatMap { id in allAccounts.first(where: { $0.id == id }) }
        let effectiveBank = resolvedSMSBank ?? (targetAccount.flatMap { SMSParser.bankName(forAccount: $0) })
        let isExplicitDigitMatch: Bool = {
            if let explicit = explicitDigitMatchedAccount, targetAccount?.id == explicit.id {
                return true
            }
            if let targetAccount, let d = matchingDigits, !d.isEmpty,
               SMSParser.digitsMatch(accountMatch: targetAccount.smsMatch, query: d) {
                return true
            }
            return false
        }()
        let matchedByDigits = explicitDigitMatchedAccount ?? (matchingDigits.flatMap { d in
            SMSParser.findMatchingAccount(forBank: resolvedSMSBank, senderOrPhone: resolvedSender, digits: d, in: context)
        } ?? directAccountFromSMS)
        let matchedByBankOrSender = isExplicitDigitMatch
            || savedRuleAccount != nil
            || SMSParser.findMatchingAccount(forBank: effectiveBank, senderOrPhone: resolvedSender, digits: matchingDigits, in: context) != nil
        let bankUnknown: Bool = {
            if isExplicitDigitMatch || matchedByDigits != nil || p.matchedUserRule { return false }
            if resolvedSMSBank == nil && p.transactionType == .unknown && savedRuleAccount == nil { return true }
            if targetAccount != nil && (accountID != nil || savedRuleAccount != nil) { return false }
            return effectiveBank == nil || effectiveBank?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true || effectiveBank?.lowercased().contains("unknown") == true
        }()
        let accountUnmatched: Bool = {
            guard let targetAccount else { return true }
            if accountID != nil || isExplicitDigitMatch || p.matchedUserRule { return false }
            if let b = resolvedSMSBank, !b.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               targetAccount.kind != .creditCard,
               !SMSParser.accountMatchesBank(targetAccount, bank: b) {
                return true
            }
            if let suffix = p.accountSuffix, !suffix.isEmpty {
                let targetDigits = targetAccount.smsMatch.trimmingCharacters(in: .whitespacesAndNewlines)
                if !targetDigits.isEmpty && !SMSParser.digitsMatch(accountMatch: targetDigits, query: suffix) {
                    let sameBankAccounts = allAccounts.filter { acc in
                        guard let b = effectiveBank else { return false }
                        return SMSParser.accountMatchesBank(acc, bank: b)
                    }
                    if sameBankAccounts.count != 1 || sameBankAccounts.first?.id != targetAccount.id {
                        return true
                    }
                }
                if targetDigits.isEmpty && !matchedByBankOrSender {
                    return true
                }
            }
            return false
        }()
        if accountUnmatched && accountID == nil {
            target = nil
            tx.accountID = nil
        }
        // Uncertain categorization or uncertain SMS format / ambiguous direction must NOT put transactions on the list waiting for review;
        // keep them categorized as Other (.other) unless the bank is unknown or the account is unmatched.
        if p.transactionType == .unknown && tx.category != .internalTransfer {
            p.category = .other
            tx.category = .other
        }

        let mustQuarantine = bankUnknown || accountUnmatched

        if mustQuarantine {
            tx.isPending = true
        } else {
            tx.isPending = !forceApprove && !AppSettings.smsAutoApprove
        }

        let code = AppSettings.currency
        // Keep the user's note field empty for SMS transactions unless set by a user Transaction Rule.
        // The SMS reference is preserved in tx.smsReference.
        if matchedHighPriorityRule?.actions.setNote == nil {
            tx.note = ""
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
        if let goalID = tx.goalID, let linkedGoal = Ledger.goal(goalID, context: context) {
            summary += " · Goal: \(linkedGoal.name) (\(Money.format(linkedGoal.saved, code))/\(Money.format(linkedGoal.target, code)))"
        }
        if isCardPayment, let cardID = tx.toAccountID, let card = Ledger.account(cardID, context: context), !tx.isPending {
            summary += " · \(card.name) owed: \(Money.format(card.balance, code))"
        }
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

    // MARK: - Same-Reference, Same-Time, Same-Account Merging (Highest Amount + Lowest Balance)

    private static func isGenericSMSMerchant(_ merchant: String) -> Bool {
        let lower = merchant.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let generics: Set<String> = [
            "fawri+ transfer", "fawri transfer", "benefitpay · fawri+ transfer", "benefitpay · fawri transfer",
            "bank transfer", "transfer", "expense", "card purchase", "income", "bank fee", "outgoing charges",
            "outgoing transfer", "incoming transfer", "incoming credit", "internal transfer"
        ]
        return lower.isEmpty || generics.contains(lower) || lower.hasSuffix(" fee")
            || lower.hasSuffix(" transfer out") || lower.hasSuffix(" transfer in")
            || lower.hasSuffix("(needs review)")
    }

    /// When two SMS messages share the same reference number, same date & time, and belong to the same account
    /// (for example, one debit alert with BHD 170.110 inc VAT + intermediate balance BHD 5,392.064,
    /// and a second Fawri+ completion alert with BHD 170.000 + final balance BHD 5,222.064),
    /// automatically merges them into a single transaction using the highest debited/transfer amount
    /// and the lowest balance amount.
    private static func mergeSameReferenceSameAccountSMSIfNeeded(
        parsed: ParsedSMS,
        rawSMS: String,
        resolvedBank: String?,
        resolvedSender: String?,
        matchingDigits: String?,
        targetAccountID: UUID?,
        resolvedLocation: TransactionLocationData? = nil,
        usedAI: Bool,
        forceApprove: Bool,
        context: ModelContext
    ) -> SMSImportOutcome? {
        let incomingRef = parsed.referenceNumber?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !incomingRef.isEmpty else { return nil }

        let incomingDate = parsed.date ?? .now
        let startWindow = incomingDate.addingTimeInterval(-86_400)
        let endWindow = incomingDate.addingTimeInterval(86_400)
        let descriptor = FetchDescriptor<MoneyTransaction>(
            predicate: #Predicate { $0.date >= startWindow && $0.date <= endWindow },
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        let candidates = (try? context.fetch(descriptor)) ?? []
        guard !candidates.isEmpty else { return nil }

        let incomingTime = parsed.timeString ?? SMSParser.extractDateAndTime(in: rawSMS).time
        let incomingIsIncome = parsed.transactionType.isIncomeDirection

        for existing in candidates where existing.source == .sms {
            let existingRef = existing.smsReference?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !existingRef.isEmpty,
                  existingRef.caseInsensitiveCompare(incomingRef) == .orderedSame else { continue }

            // Must have the same transaction direction (e.g., both outgoing debits/transfers from the same account)
            guard existing.isIncome == incomingIsIncome,
                  existing.smsTransactionType != .internalTransfer,
                  existing.category != .internalTransfer else { continue }

            // Check same date & time
            let timeDiff = abs(existing.date.timeIntervalSince(incomingDate))
            let existingTime = existing.rawText.flatMap { SMSParser.extractDateAndTime(in: $0).time }
            let isSameDateAndTime: Bool = {
                if let t1 = existingTime, let t2 = incomingTime {
                    return (t1 == t2 && Calendar.current.isDate(existing.date, inSameDayAs: incomingDate)) || timeDiff <= 180
                }
                if timeDiff <= 180 {
                    return true
                }
                return Calendar.current.isDate(existing.date, inSameDayAs: incomingDate) && (existingTime == nil || incomingTime == nil)
            }()
            guard isSameDateAndTime else { continue }

            // Never merge SMS from two different banks as "same account" — those belong to cross-bank transfer matching.
            let b1 = SMSParser.primaryBankName(from: existing.smsBank)
            let b2 = SMSParser.primaryBankName(from: resolvedBank)
            let isBankABCIlaPair = (b1 == "Bank ABC" && b2 == "ila") || (b1 == "ila" && b2 == "Bank ABC")
            if let b1, let b2, !isBankABCIlaPair, b1.caseInsensitiveCompare(b2) != .orderedSame {
                continue
            }

            // Must belong to the same account (if one SMS has an explicit account suffix like "1101" and the other has none,
            // prefer the account matched by the explicit account suffix)
            let s1 = existing.smsAccountSuffix?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let s2 = (parsed.accountSuffix ?? matchingDigits)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !s1.isEmpty && !s2.isEmpty && !SMSParser.digitsMatch(accountMatch: s1, query: s2) {
                continue
            }
            if let exAcc = existing.accountID, let newAcc = targetAccountID, exAcc != newAcc {
                if s1.isEmpty == s2.isEmpty || (b1 != nil && b2 != nil && !isBankABCIlaPair) {
                    continue
                }
            }

            let amountDiffers = abs(existing.amount - parsed.amount) >= 0.0005
            let balanceDiffers: Bool = {
                guard let b1 = existing.smsBalance, let b2 = parsed.balance else { return false }
                return abs(b1 - b2) >= 0.0005
            }()
            guard amountDiffers || balanceDiffers else { continue }

            let highestAmount = max(existing.amount, parsed.amount)
            let lowestBalance: Double? = {
                if let b1 = existing.smsBalance, let b2 = parsed.balance {
                    return min(b1, b2)
                }
                return existing.smsBalance ?? parsed.balance
            }()
            let mergedAccountSuffix = (!s1.isEmpty ? s1 : nil) ?? (!s2.isEmpty ? s2 : nil)
            let digitMatchedAccountID = mergedAccountSuffix.flatMap { SMSParser.findMatchingAccount(suffix: $0, in: context)?.id }
            let mergedAccountID: UUID? = {
                if let digitMatchedAccountID { return digitMatchedAccountID }
                if !s1.isEmpty, let exAcc = existing.accountID { return exAcc }
                if !s2.isEmpty, let newAcc = targetAccountID { return newAcc }
                return existing.accountID ?? targetAccountID
            }()
            let mergedBank: String? = {
                if existing.smsBank == "Bank ABC", resolvedBank == "ila" {
                    return "ila"
                }
                return existing.smsBank ?? resolvedBank
            }()
            let mergedSender = existing.smsSender ?? resolvedSender?.trimmingCharacters(in: .whitespacesAndNewlines)
            let mergedRecipientSuffix = existing.smsRecipientSuffix ?? parsed.recipientSuffix

            let existingRawText = existing.rawText ?? ""
            let combinedRawSMS: String = {
                if existingRawText.isEmpty { return rawSMS }
                if rawSMS.isEmpty || existingRawText == rawSMS { return existingRawText }
                if existingRawText.contains(rawSMS) { return existingRawText }
                return "\(existingRawText)\n\n---\n\n\(rawSMS)"
            }()

            Ledger.edit(existing, context: context) { tx in
                tx.amount = highestAmount
                tx.smsBalance = lowestBalance
                if let mergedAccountID { tx.accountID = mergedAccountID }
                if let mergedBank { tx.smsBank = mergedBank }
                if let mergedSender { tx.smsSender = mergedSender }
                if let mergedAccountSuffix { tx.smsAccountSuffix = mergedAccountSuffix }
                if let mergedRecipientSuffix { tx.smsRecipientSuffix = mergedRecipientSuffix }

                if isGenericSMSMerchant(tx.merchant) && !isGenericSMSMerchant(parsed.merchant) {
                    tx.merchant = parsed.merchant
                } else if isGenericSMSMerchant(tx.merchant), let recip = mergedRecipientSuffix {
                    tx.merchant = "IBAN ending \(recip)"
                }

                if (tx.locationName == nil || tx.latitude == nil), let loc = resolvedLocation {
                    tx.locationName = loc.name
                    tx.locationAddress = loc.address
                    tx.latitude = loc.latitude
                    tx.longitude = loc.longitude
                }

                tx.rawText = combinedRawSMS
                tx.isPossibleDuplicate = false
                tx.smsConfidence = .high
                tx.smsClassificationReason = "Merged SMS with same reference (\(incomingRef)), date & time, and account using highest amount and lowest balance"
            }

            var syncedBalance: Double? = nil
            let allAccounts = (try? context.fetch(FetchDescriptor<Account>())) ?? []
            let mergedTargetAccount = existing.accountID.flatMap { id in allAccounts.first(where: { $0.id == id }) }
            let hasValidAccountAndBank = mergedTargetAccount != nil
                && ((existing.smsBank?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
                    || !(mergedTargetAccount?.smsMatch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true))

            if existing.isPending && hasValidAccountAndBank && existing.smsTransactionType != .unknown && (forceApprove || AppSettings.smsAutoApprove) {
                let approveRes = Ledger.approve(existing, context: context)
                syncedBalance = approveRes.balanceSynced
            } else if !existing.isPending {
                syncedBalance = Ledger.syncBalanceFromSMS(existing, context: context)
            }

            let code = AppSettings.currency
            let typeLabel = (existing.smsTransactionType ?? parsed.transactionType).title
            var summary = "\(typeLabel) \(Money.format(existing.amount, code)) · \(existing.merchant)"
            if let synced = syncedBalance {
                summary += ". Balance matched to bank: \(Money.format(synced, code))"
            }
            summary += " (merged same-reference SMS)"
            return SMSImportOutcome(
                transaction: existing,
                batchTransactions: [existing],
                usedAI: usedAI,
                learnedMerchant: false,
                flaggedDuplicate: false,
                alerts: [],
                pending: existing.isPending,
                balanceSynced: syncedBalance,
                message: summary
            )
        }

        return nil
    }

    // MARK: - Simultaneous Inter-Account Transfer Deduplication & Merging

    /// Determines the original transfer role of an already-saved transaction (even if `transferOut` was converted to `.expense` or `transferIn` to `.income`).
    private static func originalTransferRole(for tx: MoneyTransaction, context: ModelContext? = nil) -> SMSTransactionType? {
        if tx.smsTransactionType == .internalTransfer || tx.category == .internalTransfer {
            return .internalTransfer
        }
        if tx.smsTransactionType == .transferOut {
            return .transferOut
        }
        if tx.smsTransactionType == .transferIn {
            return .transferIn
        }
        guard tx.source == .sms || tx.source == .transfer else { return nil }
        if tx.category == .transfers {
            return tx.isIncome ? .transferIn : .transferOut
        }
        if let raw = tx.rawText, let reparsed = SMSParser.parse(raw, sender: tx.smsSender, context: context), reparsed.transactionType.isTransferType {
            return reparsed.transactionType
        }
        let reasonLower = tx.smsClassificationReason.lowercased()
        if reasonLower.contains("transfer") || reasonLower.contains("fawri") {
            return tx.isIncome ? .transferIn : .transferOut
        }
        if let raw = tx.rawText?.lowercased() {
            if raw.contains("debit") || raw.contains("outward") || raw.contains("خصم") || raw.contains("صادر") {
                return .transferOut
            }
            if raw.contains("credit") || raw.contains("inward") || raw.contains("إيداع") || raw.contains("ايداع") || raw.contains("وارد") {
                return .transferIn
            }
        }
        return nil
    }

    private struct TransferLegInput {
        let rawText: String
        let explicitBank: String?
        let sender: String?
        let explicitAccountSuffix: String?
        let explicitRecipientSuffix: String?
        let explicitBalance: Double?
        let fallbackAccountID: UUID?
        let fallbackToAccountID: UUID?
        let explicitRole: SMSTransactionType?
        let fallbackIsIncome: Bool?
    }

    private struct ResolvedTwoLegTransfer {
        let fromID: UUID
        let toID: UUID
        let sourceSuffix: String?
        let destSuffix: String?
        let sourceBalance: Double?
        let destBalance: Double?
        let debitBank: String?
        let creditBank: String?
        let combinedBank: String?
        let combinedRaw: String
        let debitSender: String?
        let matchedGoalID: UUID?
    }

    /// Parses and resolves a two-SMS internal transfer strictly per leg so suffixes, banks, accounts,
    /// and balances from one leg can never overwrite or corrupt the opposite leg.
    private static func resolveTwoLegInternalTransfer(
        _ legA: TransferLegInput,
        _ legB: TransferLegInput,
        allAccounts: [Account],
        context: ModelContext,
        fallbackDebitID: UUID? = nil,
        fallbackCreditID: UUID? = nil
    ) -> ResolvedTwoLegTransfer? {
        struct ParsedTransferLeg {
            let input: TransferLegInput
            let parsed: ParsedSMS?
            let direction: SMSParser.TransferLegDirection
            let suffixes: (accountSuffix: String?, recipientSuffix: String?)
            let bank: String?
            let balance: Double?
            let isIncome: Bool
        }

        func makeParsedLeg(_ leg: TransferLegInput) -> ParsedTransferLeg {
            let parsed = leg.rawText.isEmpty ? nil : SMSParser.parse(leg.rawText, sender: leg.sender, context: context)
            let rawSuffixes: (accountSuffix: String?, recipientSuffix: String?) = leg.rawText.isEmpty
                ? (leg.explicitAccountSuffix, leg.explicitRecipientSuffix)
                : SMSParser.extractSuffixes(in: leg.rawText)
            let accSuffix: String? = {
                if let s = rawSuffixes.accountSuffix, !s.isEmpty { return s }
                if let ex = leg.explicitAccountSuffix, !ex.isEmpty, ex != rawSuffixes.recipientSuffix { return ex }
                return nil
            }()
            let recSuffix: String? = {
                if let s = rawSuffixes.recipientSuffix, !s.isEmpty { return s }
                if let ex = leg.explicitRecipientSuffix, !ex.isEmpty, ex != rawSuffixes.accountSuffix { return ex }
                return nil
            }()
            let bank = SMSParser.primaryBankName(from: leg.explicitBank) ?? parsed?.detectedBank
            let balance = leg.explicitBalance ?? parsed?.balance
            let isIncome = leg.fallbackIsIncome ?? parsed?.isIncome ?? (leg.explicitRole == .transferIn)
            let direction = SMSParser.analyzeTransferLegDirection(in: leg.rawText, fallbackIsIncome: isIncome)
            return ParsedTransferLeg(
                input: leg,
                parsed: parsed,
                direction: direction,
                suffixes: (accSuffix, recSuffix),
                bank: bank,
                balance: balance,
                isIncome: isIncome
            )
        }

        let leg1 = makeParsedLeg(legA)
        let leg2 = makeParsedLeg(legB)

        let firstIsDebit: Bool = {
            if leg1.direction == .debit && leg2.direction != .debit { return true }
            if leg2.direction == .debit && leg1.direction != .debit { return false }
            if leg1.direction == .credit && leg2.direction != .credit { return false }
            if leg2.direction == .credit && leg1.direction != .credit { return true }
            if leg1.input.explicitRole == .transferOut && leg2.input.explicitRole != .transferOut { return true }
            if leg2.input.explicitRole == .transferOut && leg1.input.explicitRole != .transferOut { return false }
            if leg1.input.explicitRole == .transferIn && leg2.input.explicitRole != .transferIn { return false }
            if leg2.input.explicitRole == .transferIn && leg1.input.explicitRole != .transferIn { return true }
            if !leg1.isIncome && leg2.isIncome { return true }
            if !leg2.isIncome && leg1.isIncome { return false }
            return true
        }()

        let debitLeg = firstIsDebit ? leg1 : leg2
        let creditLeg = firstIsDebit ? leg2 : leg1

        func accountBySuffix(_ suffix: String?, preferredBank: String?, excluding excludedID: UUID?) -> Account? {
            guard let suffix, !suffix.isEmpty else { return nil }
            if let preferredBank, !preferredBank.isEmpty,
               let bankScoped = allAccounts.first(where: {
                   $0.id != excludedID
                       && SMSParser.digitsMatch(accountMatch: $0.smsMatch, query: suffix)
                       && SMSParser.accountMatchesBank($0, bank: preferredBank)
               }) {
                return bankScoped
            }
            return SMSParser.findMatchingAccount(suffix: suffix, excludingAccountID: excludedID, in: allAccounts)
        }

        func fallbackAccount(_ id: UUID?, preferredBank: String?, excluding excludedID: UUID?) -> Account? {
            guard let id, id != excludedID, let acc = allAccounts.first(where: { $0.id == id }) else { return nil }
            if let preferredBank, !preferredBank.isEmpty,
               SMSParser.bankName(forAccount: acc) != nil,
               !SMSParser.accountMatchesBank(acc, bank: preferredBank) {
                return nil
            }
            return acc
        }

        // Pass 1a: Resolve each leg by its own explicit account/card suffix first
        var debitAcc = accountBySuffix(debitLeg.suffixes.accountSuffix, preferredBank: debitLeg.bank, excluding: nil)
        var creditAcc = accountBySuffix(creditLeg.suffixes.accountSuffix, preferredBank: creditLeg.bank, excluding: debitAcc?.id)

        // Pass 1b: Resolve any remaining leg from the counterparty IBAN/account suffix stated in the opposite SMS
        if debitAcc == nil {
            debitAcc = accountBySuffix(creditLeg.suffixes.recipientSuffix, preferredBank: debitLeg.bank, excluding: creditAcc?.id)
        }
        if creditAcc == nil {
            creditAcc = accountBySuffix(debitLeg.suffixes.recipientSuffix, preferredBank: creditLeg.bank, excluding: debitAcc?.id)
        }

        let bDebit = debitLeg.bank
        let bCredit = creditLeg.bank
        let isDifferentBanks: Bool = {
            guard let bDebit, let bCredit, !bDebit.isEmpty, !bCredit.isEmpty else { return false }
            return bDebit.caseInsensitiveCompare(bCredit) != .orderedSame
        }()
        let hasOppositeDirection = (debitLeg.direction == .debit && creditLeg.direction == .credit) || (!debitLeg.isIncome && creditLeg.isIncome)

        // Pass 2: Match by each leg's own bank / SMS sender when account digits weren't configured
        if debitAcc == nil, let bDebit, !bDebit.isEmpty {
            let pool = creditAcc.map { c in allAccounts.filter { $0.id != c.id } } ?? allAccounts
            debitAcc = SMSParser.findMatchingAccount(forBank: bDebit, senderOrPhone: debitLeg.input.sender, digits: nil, in: pool)
        }
        if creditAcc == nil, let bCredit, !bCredit.isEmpty, (isDifferentBanks || hasOppositeDirection) {
            let pool = debitAcc.map { d in allAccounts.filter { $0.id != d.id } } ?? allAccounts
            creditAcc = SMSParser.findMatchingAccount(forBank: bCredit, senderOrPhone: creditLeg.input.sender, digits: nil, in: pool)
        }

        // Pass 3: Safe fallback IDs (only if compatible with the leg's bank and distinct from the opposite leg)
        if debitAcc == nil {
            debitAcc = fallbackAccount(debitLeg.input.fallbackAccountID, preferredBank: bDebit, excluding: creditAcc?.id)
                ?? fallbackAccount(fallbackDebitID, preferredBank: bDebit, excluding: creditAcc?.id)
        }
        if creditAcc == nil {
            creditAcc = fallbackAccount(creditLeg.input.fallbackAccountID, preferredBank: bCredit, excluding: debitAcc?.id)
                ?? fallbackAccount(debitLeg.input.fallbackToAccountID, preferredBank: bCredit, excluding: debitAcc?.id)
                ?? fallbackAccount(creditLeg.input.fallbackToAccountID, preferredBank: bCredit, excluding: debitAcc?.id)
                ?? fallbackAccount(fallbackCreditID, preferredBank: bCredit, excluding: debitAcc?.id)
        }

        guard let fromAcc = debitAcc, let toAcc = creditAcc, fromAcc.id != toAcc.id else {
            return nil
        }

        let sourceSuffix: String? = {
            if let s = debitLeg.suffixes.accountSuffix, !s.isEmpty { return s }
            if let s = creditLeg.suffixes.recipientSuffix, !s.isEmpty,
               SMSParser.digitsMatch(accountMatch: fromAcc.smsMatch, query: s) || !SMSParser.digitsMatch(accountMatch: toAcc.smsMatch, query: s) {
                return s
            }
            return nil
        }()

        let destSuffix: String? = {
            if let s = creditLeg.suffixes.accountSuffix, !s.isEmpty { return s }
            if let s = debitLeg.suffixes.recipientSuffix, !s.isEmpty,
               SMSParser.digitsMatch(accountMatch: toAcc.smsMatch, query: s) || !SMSParser.digitsMatch(accountMatch: fromAcc.smsMatch, query: s) {
                return s
            }
            return nil
        }()

        let resolvedDebitBank = bDebit ?? SMSParser.bankName(forAccount: fromAcc)
        let resolvedCreditBank = bCredit ?? SMSParser.bankName(forAccount: toAcc)
        let combinedBank = SMSParser.formatCombinedBanks(debitBank: resolvedDebitBank, creditBank: resolvedCreditBank)

        let dRaw = debitLeg.input.rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        let cRaw = creditLeg.input.rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        let combinedRaw: String = {
            if dRaw.isEmpty { return cRaw }
            if cRaw.isEmpty || dRaw == cRaw || dRaw.contains(cRaw) { return dRaw }
            return "\(dRaw)\n\n---\n\n\(cRaw)"
        }()

        let debitSender: String? = {
            if let s = debitLeg.input.sender, !s.isEmpty { return s }
            if let s = creditLeg.input.sender, !s.isEmpty { return s }
            return nil
        }()

        let matchedGoalID: UUID? = {
            if let goal = SMSParser.findMatchingGoal(suffix: destSuffix, accountID: toAcc.id, in: context),
               goal.linkedAccountID == nil || goal.linkedAccountID != fromAcc.id {
                return goal.id
            }
            return nil
        }()

        return ResolvedTwoLegTransfer(
            fromID: fromAcc.id,
            toID: toAcc.id,
            sourceSuffix: sourceSuffix,
            destSuffix: destSuffix,
            sourceBalance: debitLeg.balance,
            destBalance: creditLeg.balance,
            debitBank: resolvedDebitBank,
            creditBank: resolvedCreditBank,
            combinedBank: combinedBank,
            combinedRaw: combinedRaw,
            debitSender: debitSender,
            matchedGoalID: matchedGoalID
        )
    }

    /// When a user transfers between two accounts, they often receive two SMS alerts at the same date & time
    /// (e.g. one is "Transfer between accounts" / `internalTransfer` and the other is "Transfer Out" / `transferOut`,
    /// or one is `transferOut` from Account A and the other is `transferIn` to Account B).
    /// If the date, time, and amount match, this merges them into ONE single transaction instead of creating a duplicate,
    /// while preserving each account's balance strictly per SMS leg.
    private static func mergeSameTimeTransferIfNeeded(
        parsed: ParsedSMS,
        rawParsedType: SMSTransactionType,
        rawSMS: String,
        resolvedBank: String?,
        resolvedSender: String?,
        targetAccountID: UUID?,
        resolvedLocation: TransactionLocationData? = nil,
        usedAI: Bool,
        forceApprove: Bool,
        context: ModelContext
    ) -> SMSImportOutcome? {
        let incomingDate = parsed.date ?? .now
        let startWindow = incomingDate.addingTimeInterval(-86_400)
        let endWindow = incomingDate.addingTimeInterval(86_400)
        let descriptor = FetchDescriptor<MoneyTransaction>(
            predicate: #Predicate { $0.date >= startWindow && $0.date <= endWindow },
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        let candidates = (try? context.fetch(descriptor)) ?? []
        guard !candidates.isEmpty else { return nil }

        let allAccounts = (try? context.fetch(FetchDescriptor<Account>(sortBy: [SortDescriptor(\.createdAt)]))) ?? []
        let accountsByID = Dictionary(uniqueKeysWithValues: allAccounts.map { ($0.id, $0) })

        let incomingTime = parsed.timeString ?? SMSParser.extractDateAndTime(in: rawSMS).time
        let newRole: SMSTransactionType = {
            if parsed.category == .internalTransfer || parsed.toAccountID != nil { return .internalTransfer }
            if rawParsedType.isTransferType { return rawParsedType }
            let lower = rawSMS.lowercased()
            if lower.contains("debit") || lower.contains("outward") || lower.contains("خصم") || lower.contains("صادر") {
                return .transferOut
            }
            if lower.contains("credit") || lower.contains("inward") || lower.contains("إيداع") || lower.contains("ايداع") || lower.contains("وارد") {
                return .transferIn
            }
            return parsed.isIncome ? .transferIn : .transferOut
        }()

        let incomingRef = parsed.referenceNumber?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !incomingRef.isEmpty else { return nil }

        for existing in candidates {
            // 1. Exact same transaction amount
            guard abs(existing.amount - parsed.amount) < 0.0005 else { continue }

            // 2. Both messages contain the same transaction reference number
            let existingRef = existing.smsReference?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !existingRef.isEmpty, existingRef.caseInsensitiveCompare(incomingRef) == .orderedSame else { continue }

            // 3. Both messages have the exact same transaction date and time
            let existingTime = existing.rawText.flatMap { SMSParser.extractDateAndTime(in: $0).time }
            let isSameCalendarDay = Calendar.current.isDate(existing.date, inSameDayAs: incomingDate)
            let isSameDateAndTime: Bool = {
                guard isSameCalendarDay else { return false }
                if let t1 = existingTime, let t2 = incomingTime {
                    if t1 == t2 { return true }
                    // Also compare HH:mm prefix in case one includes seconds (e.g. "20:53:00" vs "20:53")
                    if t1.prefix(5) == t2.prefix(5) { return true }
                }
                guard existingTime != nil, incomingTime != nil else { return false }
                let cal = Calendar.current
                return cal.dateComponents([.year, .month, .day, .hour, .minute], from: existing.date)
                    == cal.dateComponents([.year, .month, .day, .hour, .minute], from: incomingDate)
            }()
            guard isSameDateAndTime else { continue }

            let existingRawText = existing.rawText ?? ""
            let trimmedIncomingRaw = rawSMS.trimmingCharacters(in: .whitespacesAndNewlines)
            if (existing.smsTransactionType == .internalTransfer || existing.category == .internalTransfer),
               existingRawText.contains("\n\n---\n\n") {
                if !trimmedIncomingRaw.isEmpty && existingRawText.contains(trimmedIncomingRaw) {
                    let code = AppSettings.currency
                    return SMSImportOutcome(
                        transaction: existing,
                        batchTransactions: [existing],
                        usedAI: usedAI,
                        learnedMerchant: false,
                        flaggedDuplicate: false,
                        alerts: [],
                        pending: existing.isPending,
                        balanceSynced: nil,
                        message: "Internal Transfer \(Money.format(existing.amount, code)) · \(existing.merchant) (already merged)"
                    )
                }
                continue
            }

            let existingRole = originalTransferRole(for: existing, context: context) ?? (existing.isIncome ? .transferIn : .transferOut)
            let existingInput = TransferLegInput(
                rawText: existingRawText,
                explicitBank: SMSParser.primaryBankName(from: existing.smsBank),
                sender: existing.smsSender,
                explicitAccountSuffix: existing.smsAccountSuffix,
                explicitRecipientSuffix: existing.smsRecipientSuffix,
                explicitBalance: existing.smsBalance,
                fallbackAccountID: existing.accountID,
                fallbackToAccountID: existing.toAccountID,
                explicitRole: existingRole,
                fallbackIsIncome: existingRole == .transferIn || existing.isIncome
            )
            let incomingInput = TransferLegInput(
                rawText: rawSMS,
                explicitBank: SMSParser.primaryBankName(from: resolvedBank),
                sender: resolvedSender,
                explicitAccountSuffix: parsed.accountSuffix,
                explicitRecipientSuffix: parsed.recipientSuffix,
                explicitBalance: parsed.balance,
                fallbackAccountID: targetAccountID,
                fallbackToAccountID: parsed.toAccountID,
                explicitRole: newRole,
                fallbackIsIncome: newRole == .transferIn || parsed.isIncome
            )

            guard let resolved = resolveTwoLegInternalTransfer(existingInput, incomingInput, allAccounts: allAccounts, context: context) else {
                continue
            }

            let safeExistingGoalID: UUID? = {
                if let gid = existing.goalID, let g = Ledger.goal(gid, context: context),
                   g.linkedAccountID == nil || g.linkedAccountID != resolved.fromID {
                    return gid
                }
                if let gid = parsed.goalID, let g = Ledger.goal(gid, context: context),
                   g.linkedAccountID == nil || g.linkedAccountID != resolved.fromID {
                    return gid
                }
                return resolved.matchedGoalID
            }()

            // Update the existing transaction in-place so there is only ONE transaction in the database
            Ledger.edit(existing, context: context) { tx in
                tx.smsTransactionType = .internalTransfer
                tx.category = .internalTransfer
                tx.isIncome = false
                tx.accountID = resolved.fromID
                tx.toAccountID = resolved.toID
                tx.goalID = safeExistingGoalID

                if let srcAcc = accountsByID[resolved.fromID] ?? Ledger.account(resolved.fromID, context: context),
                   let dstAcc = accountsByID[resolved.toID] ?? Ledger.account(resolved.toID, context: context) {
                    tx.merchant = "\(srcAcc.name) → \(dstAcc.name)"
                } else if newRole == .internalTransfer && !parsed.merchant.isEmpty {
                    tx.merchant = parsed.merchant
                }

                tx.rawText = resolved.combinedRaw
                tx.smsBank = resolved.combinedBank
                if let s = resolved.debitSender { tx.smsSender = s }
                if tx.smsReference == nil { tx.smsReference = parsed.referenceNumber }
                tx.smsAccountSuffix = resolved.sourceSuffix
                tx.smsRecipientSuffix = resolved.destSuffix
                tx.smsBalance = resolved.sourceBalance
                tx.smsToBalance = resolved.destBalance
                tx.isPossibleDuplicate = false

                if (tx.locationName == nil || tx.latitude == nil), let loc = resolvedLocation {
                    tx.locationName = loc.name
                    tx.locationAddress = loc.address
                    tx.latitude = loc.latitude
                    tx.longitude = loc.longitude
                }

                tx.smsConfidence = .high
                tx.smsClassificationReason = "Merged 2 matching SMS at same date & time (Debit: \(resolved.debitBank ?? "Source") → Credit: \(resolved.creditBank ?? "Destination"))"
            }

            var syncedBalance: Double? = nil
            if existing.isPending && (forceApprove || AppSettings.smsAutoApprove) && existing.smsBank != nil && existing.accountID != nil {
                let approveRes = Ledger.approve(existing, context: context)
                syncedBalance = approveRes.balanceSynced
            } else if !existing.isPending {
                syncedBalance = Ledger.syncBalanceFromSMS(existing, context: context, force: false)
            }

            let code = AppSettings.currency
            var balanceParts: [String] = []
            if let sBal = existing.smsBalance, let fromID = existing.accountID, let fromAcc = Ledger.account(fromID, context: context) {
                balanceParts.append("\(fromAcc.name): \(Money.format(sBal, code))")
            }
            if let dBal = existing.smsToBalance, let toID = existing.toAccountID, let toAcc = Ledger.account(toID, context: context) {
                balanceParts.append("\(toAcc.name): \(Money.format(dBal, code))")
            }
            let balSummary = balanceParts.isEmpty ? "" : " · [Balances: \(balanceParts.joined(separator: ", "))]"
            let summary = "Internal Transfer \(Money.format(existing.amount, code)) · \(existing.merchant)\(balSummary) (merged duplicate transfer SMS)"
            return SMSImportOutcome(
                transaction: existing,
                batchTransactions: [existing],
                usedAI: usedAI,
                learnedMerchant: false,
                flaggedDuplicate: false,
                alerts: [],
                pending: existing.isPending,
                balanceSynced: syncedBalance,
                message: summary
            )
        }

        return nil
    }

    // MARK: - Reconcile Existing Transactions (Account Digit Matching, Same-Reference Merging, and Duplicate Cleanup)

    private static let reconcileCacheLock = NSLock()
    private static var lastReconcileSignature: [ObjectIdentifier: Int] = [:]

    private static func reconcileSignature(
        accounts: [Account],
        transactions: [MoneyTransaction]
    ) -> Int {
        var hasher = Hasher()
        hasher.combine(AppSettings.smsAutoApprove)
        for bank in BahrainBankCatalog.customBanks {
            hasher.combine(bank)
        }
        hasher.combine(accounts.count)
        for acc in accounts {
            hasher.combine(acc.id)
            hasher.combine(acc.name)
            hasher.combine(acc.kindRaw)
            hasher.combine(acc.smsMatch)
        }
        hasher.combine(transactions.count)
        for tx in transactions {
            hasher.combine(tx.id)
            hasher.combine(tx.source == .sms)
            hasher.combine(tx.isPending)
            hasher.combine(tx.isPossibleDuplicate)
            hasher.combine(tx.isIncome)
            hasher.combine(tx.amount)
            hasher.combine(tx.date)
            hasher.combine(tx.accountID)
            hasher.combine(tx.toAccountID)
            hasher.combine(tx.categoryRaw)
            hasher.combine(tx.smsTransactionTypeRaw)
            hasher.combine(tx.smsBank)
            hasher.combine(tx.smsReference)
            hasher.combine(tx.smsAccountSuffix)
            hasher.combine(tx.smsRecipientSuffix)
            hasher.combine(tx.smsSender)
            hasher.combine(tx.smsBalance)
            hasher.combine(tx.smsToBalance)
            hasher.combine(tx.rawText?.count)
        }
        return hasher.finalize()
    }

    /// Reconciles already-stored transactions in SwiftData so existing items on the user's device
    /// immediately reflect account digit matching, cross-bank internal transfer merging,
    /// same-reference SMS merging (highest amount + lowest balance), and strict reference-only duplicate detection.
    static func reconcileExistingTransactions(context: ModelContext) {
        let allAccounts = (try? context.fetch(FetchDescriptor<Account>(sortBy: [SortDescriptor(\.createdAt)]))) ?? []
        let allTxs = (try? context.fetch(FetchDescriptor<MoneyTransaction>(sortBy: [SortDescriptor(\.date)]))) ?? []
        guard !allTxs.isEmpty else { return }

        let ctxKey = ObjectIdentifier(context)
        let signature = reconcileSignature(accounts: allAccounts, transactions: allTxs)
        reconcileCacheLock.lock()
        let isUnchanged = lastReconcileSignature[ctxKey] == signature
        reconcileCacheLock.unlock()
        if isUnchanged { return }

        let accountsByID = Dictionary(uniqueKeysWithValues: allAccounts.map { ($0.id, $0) })
        var suffixCache: [UUID: (accountSuffix: String?, recipientSuffix: String?)] = [:]
        var timeCache: [UUID: String] = [:]

        func cachedSuffixes(for tx: MoneyTransaction) -> (accountSuffix: String?, recipientSuffix: String?) {
            if let cached = suffixCache[tx.id] { return cached }
            guard let raw = tx.rawText, !raw.isEmpty else {
                suffixCache[tx.id] = (nil, nil)
                return (nil, nil)
            }
            let parsed = SMSParser.extractSuffixes(in: raw)
            suffixCache[tx.id] = parsed
            return parsed
        }

        func cachedTime(for tx: MoneyTransaction) -> String? {
            if let cached = timeCache[tx.id] { return cached.isEmpty ? nil : cached }
            let parsed = tx.rawText.flatMap { SMSParser.extractDateAndTime(in: $0).time }
            timeCache[tx.id] = parsed ?? ""
            return parsed
        }

        var modified = false

        // 1. Backfill missing reference/suffix metadata from rawText, fix misclassified counterparty suffixes,
        // and auto-approve uncertain-format transactions that were kept as Other when bank & account are known.
        for tx in allTxs where tx.source == .sms {
            guard let raw = tx.rawText, !raw.isEmpty else { continue }
            if (tx.smsReference?.isEmpty ?? true), let ref = SMSParser.referenceNumber(in: raw) {
                tx.smsReference = ref
                modified = true
            }

            let legs = raw.components(separatedBy: "\n\n---\n\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            // Repair already-merged 2-SMS internal transfers strictly per leg so counterparty/credit suffixes
            // are never re-parsed across combined rawText and applied to the wrong account.
            if legs.count >= 2 && (tx.smsTransactionType == .internalTransfer || tx.category == .internalTransfer) {
                let idsWereDistinct = tx.accountID != tx.toAccountID
                let leg1Input = TransferLegInput(
                    rawText: legs[0],
                    explicitBank: nil,
                    sender: nil,
                    explicitAccountSuffix: nil,
                    explicitRecipientSuffix: nil,
                    explicitBalance: nil,
                    fallbackAccountID: nil,
                    fallbackToAccountID: nil,
                    explicitRole: nil,
                    fallbackIsIncome: nil
                )
                let leg2Input = TransferLegInput(
                    rawText: legs[1],
                    explicitBank: nil,
                    sender: nil,
                    explicitAccountSuffix: nil,
                    explicitRecipientSuffix: nil,
                    explicitBalance: nil,
                    fallbackAccountID: nil,
                    fallbackToAccountID: nil,
                    explicitRole: nil,
                    fallbackIsIncome: nil
                )
                if let resolved = resolveTwoLegInternalTransfer(
                    leg1Input,
                    leg2Input,
                    allAccounts: allAccounts,
                    context: context,
                    fallbackDebitID: idsWereDistinct ? tx.accountID : nil,
                    fallbackCreditID: idsWereDistinct ? tx.toAccountID : nil
                ) {
                    let srcAcc = accountsByID[resolved.fromID] ?? Ledger.account(resolved.fromID, context: context)
                    let dstAcc = accountsByID[resolved.toID] ?? Ledger.account(resolved.toID, context: context)
                    let expectedMerchant: String? = {
                        if let srcAcc, let dstAcc, srcAcc.id != dstAcc.id {
                            return "\(srcAcc.name) → \(dstAcc.name)"
                        }
                        return nil
                    }()
                    let expectedReason = "Merged 2 matching SMS at same date & time (Debit: \(resolved.debitBank ?? "Source") → Credit: \(resolved.creditBank ?? "Destination"))"
                    let accountsChanged = tx.accountID != resolved.fromID || tx.toAccountID != resolved.toID
                    let clearWrongSourceSuffix = resolved.sourceSuffix == nil
                        && (tx.smsAccountSuffix.map { cur in dstAcc.map { SMSParser.digitsMatch(accountMatch: $0.smsMatch, query: cur) } ?? false } ?? false)
                    let sourceBalChanged: Bool = {
                        guard let expected = resolved.sourceBalance else { return false }
                        guard let current = tx.smsBalance else { return true }
                        return abs(current - expected) >= 0.0005
                    }()
                    let destBalChanged: Bool = {
                        guard let expected = resolved.destBalance else { return false }
                        guard let current = tx.smsToBalance else { return true }
                        return abs(current - expected) >= 0.0005
                    }()
                    let shouldUpdateReason = accountsChanged || tx.smsClassificationReason.hasPrefix("Merged 2 matching SMS") || tx.smsClassificationReason.isEmpty

                    let needsRepair = accountsChanged
                        || (resolved.sourceSuffix != nil && tx.smsAccountSuffix != resolved.sourceSuffix)
                        || clearWrongSourceSuffix
                        || (resolved.destSuffix != nil && tx.smsRecipientSuffix != resolved.destSuffix)
                        || sourceBalChanged
                        || destBalChanged
                        || (resolved.combinedBank != nil && tx.smsBank != resolved.combinedBank)
                        || tx.rawText != resolved.combinedRaw
                        || (accountsChanged && expectedMerchant != nil && tx.merchant != expectedMerchant)
                        || (shouldUpdateReason && tx.smsClassificationReason != expectedReason)

                    if needsRepair {
                        if !tx.isPending {
                            if tx.accountID == resolved.fromID, sourceBalChanged, tx.balanceAdjustment != 0, let srcAcc {
                                srcAcc.balance -= tx.balanceAdjustment
                                tx.balanceAdjustment = 0
                            }
                            if tx.toAccountID == resolved.toID, destBalChanged, tx.toBalanceAdjustment != 0, let dstAcc {
                                dstAcc.balance -= tx.toBalanceAdjustment
                                tx.toBalanceAdjustment = 0
                            }
                        }
                        Ledger.edit(tx, context: context) { target in
                            target.smsTransactionType = .internalTransfer
                            target.category = .internalTransfer
                            target.isIncome = false
                            target.accountID = resolved.fromID
                            target.toAccountID = resolved.toID
                            if let expectedMerchant, (accountsChanged || target.merchant.contains("→") || isGenericSMSMerchant(target.merchant)) {
                                target.merchant = expectedMerchant
                            }
                            if accountsChanged, target.goalID == nil, let gid = resolved.matchedGoalID {
                                target.goalID = gid
                            }
                            target.rawText = resolved.combinedRaw
                            if let combinedBank = resolved.combinedBank { target.smsBank = combinedBank }
                            if let s = resolved.sourceSuffix {
                                target.smsAccountSuffix = s
                            } else if clearWrongSourceSuffix {
                                target.smsAccountSuffix = nil
                            }
                            if let d = resolved.destSuffix { target.smsRecipientSuffix = d }
                            if let sb = resolved.sourceBalance { target.smsBalance = sb }
                            if let db = resolved.destBalance { target.smsToBalance = db }
                            target.isPossibleDuplicate = false
                            target.smsConfidence = .high
                            if shouldUpdateReason {
                                target.smsClassificationReason = expectedReason
                            }
                        }
                        if !tx.isPending {
                            _ = Ledger.syncBalanceFromSMS(tx, context: context, force: false, onlyIfLatest: true)
                        }
                        modified = true
                    }
                }
                continue
            }

            let suffixes: (accountSuffix: String?, recipientSuffix: String?) = {
                if legs.count >= 2 {
                    let perLeg = legs.map { SMSParser.extractSuffixes(in: $0) }
                    return (
                        perLeg.compactMap(\.accountSuffix).first(where: { !$0.isEmpty }),
                        perLeg.compactMap(\.recipientSuffix).first(where: { !$0.isEmpty })
                    )
                }
                return cachedSuffixes(for: tx)
            }()
            if let recSuf = suffixes.recipientSuffix, tx.smsRecipientSuffix != recSuf {
                tx.smsRecipientSuffix = recSuf
                modified = true
            }
            if suffixes.accountSuffix == nil, let recSuf = suffixes.recipientSuffix, tx.smsAccountSuffix == recSuf {
                tx.smsAccountSuffix = nil
                modified = true
            } else if (tx.smsAccountSuffix?.isEmpty ?? true), let accSuf = suffixes.accountSuffix {
                tx.smsAccountSuffix = accSuf
                modified = true
            }

            if tx.smsClassificationReason.localizedCaseInsensitiveContains("marked for user review") {
                tx.smsClassificationReason = tx.smsClassificationReason.replacingOccurrences(
                    of: "marked for user review",
                    with: "categorized as Other",
                    options: .caseInsensitive
                )
                modified = true
            }
            if tx.smsTransactionType == .unknown {
                if tx.category != .internalTransfer && !tx.aiCategorized && tx.categoryRaw.isEmpty {
                    tx.category = .other
                }
                if tx.isPending,
                   tx.accountID != nil,
                   let bank = tx.smsBank?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !bank.isEmpty,
                   AppSettings.smsAutoApprove {
                    _ = Ledger.approve(tx, context: context)
                    modified = true
                }
            }

            let querySuffix: String? = tx.smsAccountSuffix ?? suffixes.accountSuffix

            let matchedAcc: Account? = {
                if let q = querySuffix, !q.isEmpty, let m = SMSParser.findMatchingAccount(suffix: q, in: allAccounts) {
                    return m
                }
                if legs.count == 1, let m = SMSParser.findAccountInSMSText(raw, detectedBank: tx.smsBank, in: allAccounts) {
                    if let b = tx.smsBank, !b.isEmpty, m.kind != .creditCard,
                       let accBank = SMSParser.bankName(forAccount: m),
                       accBank.caseInsensitiveCompare(b) != .orderedSame,
                       !((accBank == "ila" && b == "Bank ABC") || (accBank == "Bank ABC" && b == "ila")),
                       SMSParser.findMatchingAccount(forBank: b, senderOrPhone: tx.smsSender, digits: nil, in: allAccounts) != nil {
                        return nil
                    }
                    return m
                }
                if querySuffix == nil, let b = tx.smsBank, !b.isEmpty {
                    return SMSParser.findMatchingAccount(forBank: b, senderOrPhone: tx.smsSender, digits: nil, in: allAccounts)
                }
                return nil
            }()

            if let matchedAcc, tx.accountID != matchedAcc.id, matchedAcc.id != tx.toAccountID {
                let currentAcc = tx.accountID.flatMap { accountsByID[$0] }
                let shouldAssign: Bool = {
                    guard let currentAcc else { return true }
                    // Only reassign an existing account if the SMS has explicit digits that match `matchedAcc.smsMatch`
                    // and do NOT match `currentAcc.smsMatch`, or if `currentAcc` conflicts with `tx.smsBank`.
                    if let q = querySuffix, !q.isEmpty,
                       SMSParser.digitsMatch(accountMatch: matchedAcc.smsMatch, query: q),
                       !SMSParser.digitsMatch(accountMatch: currentAcc.smsMatch, query: q) {
                        return true
                    }
                    if let b = tx.smsBank, !b.isEmpty,
                       SMSParser.accountMatchesBank(matchedAcc, bank: b),
                       !SMSParser.accountMatchesBank(currentAcc, bank: b) {
                        return true
                    }
                    return false
                }()
                if shouldAssign {
                    if tx.isPending {
                        tx.accountID = matchedAcc.id
                        if AppSettings.smsAutoApprove {
                            _ = Ledger.approve(tx, context: context)
                        }
                    } else {
                        Ledger.edit(tx, context: context) { $0.accountID = matchedAcc.id }
                    }
                    modified = true
                }
            }
        }

        // Reuse fetched allTxs (already sorted by date) and bucket by normalized reference code
        // so cross-bank and same-reference pairing run in linear time instead of O(N^2).
        let smsTxs = allTxs.filter { $0.source == .sms }
        let cal = Calendar.current

        // 1b. Merge existing cross-bank / inter-account transfer SMS pairs that share the same reference, same amount, and same date & time
        var crossBankBuckets: [String: [MoneyTransaction]] = [:]
        var crossBankKeys: [String] = []
        for tx in smsTxs {
            guard tx.smsTransactionType != .internalTransfer,
                  tx.category != .internalTransfer,
                  let ref = Ledger.effectiveReference(for: tx),
                  !ref.isEmpty else { continue }
            let key = ref.uppercased()
            if crossBankBuckets[key] == nil { crossBankKeys.append(key) }
            crossBankBuckets[key, default: []].append(tx)
        }

        var deletedCrossBankIDs: Set<UUID> = []
        for key in crossBankKeys {
            guard let bucket = crossBankBuckets[key], bucket.count >= 2 else { continue }
            for i in 0..<bucket.count {
                let first = bucket[i]
                guard !deletedCrossBankIDs.contains(first.id) else { continue }
                guard let ref1 = Ledger.effectiveReference(for: first), !ref1.isEmpty else { continue }
                guard first.smsTransactionType != .internalTransfer && first.category != .internalTransfer else { continue }

                for j in (i + 1)..<bucket.count {
                    let second = bucket[j]
                    guard !deletedCrossBankIDs.contains(second.id) else { continue }
                    guard let ref2 = Ledger.effectiveReference(for: second), !ref2.isEmpty,
                          ref1.caseInsensitiveCompare(ref2) == .orderedSame else { continue }
                    guard second.smsTransactionType != .internalTransfer && second.category != .internalTransfer else { continue }
                    guard abs(first.amount - second.amount) < 0.0005 else { continue }

                    let t1 = cachedTime(for: first)
                    let t2 = cachedTime(for: second)
                    let isSameDay = cal.isDate(first.date, inSameDayAs: second.date)
                    guard isSameDay, let t1, let t2, (t1 == t2 || t1.prefix(5) == t2.prefix(5)) else { continue }

                    let raw1 = first.rawText ?? ""
                    let raw2 = second.rawText ?? ""
                    let suf1 = cachedSuffixes(for: first)
                    let suf2 = cachedSuffixes(for: second)
                    let leg1Role = originalTransferRole(for: first, context: context) ?? (first.isIncome ? .transferIn : .transferOut)
                    let leg2Role = originalTransferRole(for: second, context: context) ?? (second.isIncome ? .transferIn : .transferOut)

                    let leg1Input = TransferLegInput(
                        rawText: raw1,
                        explicitBank: SMSParser.primaryBankName(from: first.smsBank),
                        sender: first.smsSender,
                        explicitAccountSuffix: suf1.accountSuffix ?? first.smsAccountSuffix,
                        explicitRecipientSuffix: suf1.recipientSuffix ?? first.smsRecipientSuffix,
                        explicitBalance: first.smsBalance,
                        fallbackAccountID: first.accountID,
                        fallbackToAccountID: first.toAccountID,
                        explicitRole: leg1Role,
                        fallbackIsIncome: leg1Role == .transferIn || first.isIncome
                    )
                    let leg2Input = TransferLegInput(
                        rawText: raw2,
                        explicitBank: SMSParser.primaryBankName(from: second.smsBank),
                        sender: second.smsSender,
                        explicitAccountSuffix: suf2.accountSuffix ?? second.smsAccountSuffix,
                        explicitRecipientSuffix: suf2.recipientSuffix ?? second.smsRecipientSuffix,
                        explicitBalance: second.smsBalance,
                        fallbackAccountID: second.accountID,
                        fallbackToAccountID: second.toAccountID,
                        explicitRole: leg2Role,
                        fallbackIsIncome: leg2Role == .transferIn || second.isIncome
                    )

                    guard let resolved = resolveTwoLegInternalTransfer(leg1Input, leg2Input, allAccounts: allAccounts, context: context) else {
                        continue
                    }

                    let safeGoalID: UUID? = {
                        if let gid = first.goalID ?? second.goalID, let g = Ledger.goal(gid, context: context),
                           g.linkedAccountID == nil || g.linkedAccountID != resolved.fromID {
                            return gid
                        }
                        return resolved.matchedGoalID
                    }()

                    deletedCrossBankIDs.insert(second.id)
                    Ledger.delete(second, context: context)

                    Ledger.edit(first, context: context) { tx in
                        tx.smsTransactionType = .internalTransfer
                        tx.category = .internalTransfer
                        tx.isIncome = false
                        tx.accountID = resolved.fromID
                        tx.toAccountID = resolved.toID
                        tx.goalID = safeGoalID
                        if let srcAcc = accountsByID[resolved.fromID] ?? Ledger.account(resolved.fromID, context: context),
                           let dstAcc = accountsByID[resolved.toID] ?? Ledger.account(resolved.toID, context: context) {
                            tx.merchant = "\(srcAcc.name) → \(dstAcc.name)"
                        }
                        tx.rawText = resolved.combinedRaw
                        tx.smsBank = resolved.combinedBank
                        if let s = resolved.debitSender { tx.smsSender = s }
                        tx.smsAccountSuffix = resolved.sourceSuffix
                        tx.smsRecipientSuffix = resolved.destSuffix
                        tx.smsBalance = resolved.sourceBalance
                        tx.smsToBalance = resolved.destBalance
                        tx.isPossibleDuplicate = false
                        tx.smsConfidence = .high
                        tx.smsClassificationReason = "Merged 2 matching SMS at same date & time (Debit: \(resolved.debitBank ?? "Source") → Credit: \(resolved.creditBank ?? "Destination"))"
                    }

                    if first.isPending && AppSettings.smsAutoApprove {
                        _ = Ledger.approve(first, context: context)
                    } else if !first.isPending {
                        _ = Ledger.syncBalanceFromSMS(first, context: context, force: false, onlyIfLatest: true)
                    }
                    modified = true
                    break
                }
            }
        }

        // 2. Merge existing SMS transactions that share the same reference, same date & time, and same direction/account
        var sameRefBuckets: [String: [MoneyTransaction]] = [:]
        var sameRefKeys: [String] = []
        for tx in smsTxs {
            guard !deletedCrossBankIDs.contains(tx.id),
                  tx.smsTransactionType != .internalTransfer,
                  tx.category != .internalTransfer,
                  let ref = Ledger.effectiveReference(for: tx),
                  !ref.isEmpty else { continue }
            let key = ref.uppercased()
            if sameRefBuckets[key] == nil { sameRefKeys.append(key) }
            sameRefBuckets[key, default: []].append(tx)
        }

        var deletedIDs: Set<UUID> = []
        for key in sameRefKeys {
            guard let bucket = sameRefBuckets[key], bucket.count >= 2 else { continue }
            for i in 0..<bucket.count {
                let primary = bucket[i]
                guard !deletedIDs.contains(primary.id) else { continue }
                guard let ref1 = Ledger.effectiveReference(for: primary), !ref1.isEmpty else { continue }
                guard primary.smsTransactionType != .internalTransfer && primary.category != .internalTransfer else { continue }

                for j in (i + 1)..<bucket.count {
                    let secondary = bucket[j]
                    guard !deletedIDs.contains(secondary.id) else { continue }
                    guard let ref2 = Ledger.effectiveReference(for: secondary), !ref2.isEmpty,
                          ref1.caseInsensitiveCompare(ref2) == .orderedSame else { continue }
                    guard primary.isIncome == secondary.isIncome,
                          secondary.smsTransactionType != .internalTransfer,
                          secondary.category != .internalTransfer else { continue }

                    let timeDiff = abs(primary.date.timeIntervalSince(secondary.date))
                    let t1 = cachedTime(for: primary)
                    let t2 = cachedTime(for: secondary)
                    let isSameDateAndTime: Bool = {
                        if let t1, let t2 {
                            return (t1 == t2 && cal.isDate(primary.date, inSameDayAs: secondary.date)) || timeDiff <= 180
                        }
                        if timeDiff <= 180 { return true }
                        return cal.isDate(primary.date, inSameDayAs: secondary.date) && (t1 == nil || t2 == nil)
                    }()
                    guard isSameDateAndTime else { continue }

                    let s1 = primary.smsAccountSuffix?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let s2 = secondary.smsAccountSuffix?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if !s1.isEmpty && !s2.isEmpty && !SMSParser.digitsMatch(accountMatch: s1, query: s2) {
                        continue
                    }
                    if s1.isEmpty == s2.isEmpty {
                        if let a1 = primary.accountID, let a2 = secondary.accountID, a1 != a2 {
                            continue
                        }
                    }

                    let amountDiffers = abs(primary.amount - secondary.amount) >= 0.0005
                    let balanceDiffers: Bool = {
                        guard let b1 = primary.smsBalance, let b2 = secondary.smsBalance else { return false }
                        return abs(b1 - b2) >= 0.0005
                    }()
                    guard amountDiffers || balanceDiffers else { continue }

                    let highestAmount = max(primary.amount, secondary.amount)
                    let lowestBalance: Double? = {
                        if let b1 = primary.smsBalance, let b2 = secondary.smsBalance {
                            return min(b1, b2)
                        }
                        return primary.smsBalance ?? secondary.smsBalance
                    }()
                    let mergedSuffix = (!s1.isEmpty ? s1 : nil) ?? (!s2.isEmpty ? s2 : nil)
                    let digitAccID = mergedSuffix.flatMap { SMSParser.findMatchingAccount(suffix: $0, in: context)?.id }
                    let mergedAccID: UUID? = {
                        if let digitAccID { return digitAccID }
                        if !s1.isEmpty, let a1 = primary.accountID { return a1 }
                        if !s2.isEmpty, let a2 = secondary.accountID { return a2 }
                        return primary.accountID ?? secondary.accountID
                    }()
                    let mergedBank = primary.smsBank ?? secondary.smsBank
                    let mergedSender = primary.smsSender ?? secondary.smsSender
                    let mergedRecip = primary.smsRecipientSuffix ?? secondary.smsRecipientSuffix
                    let raw1 = primary.rawText ?? ""
                    let raw2 = secondary.rawText ?? ""
                    let combinedRaw: String = {
                        if raw1.isEmpty { return raw2 }
                        if raw2.isEmpty || raw1 == raw2 || raw1.contains(raw2) { return raw1 }
                        return "\(raw1)\n\n---\n\n\(raw2)"
                    }()

                    deletedIDs.insert(secondary.id)
                    Ledger.delete(secondary, context: context)

                    Ledger.edit(primary, context: context) { tx in
                        tx.amount = highestAmount
                        tx.smsBalance = lowestBalance
                        if let mergedAccID { tx.accountID = mergedAccID }
                        if let mergedBank { tx.smsBank = mergedBank }
                        if let mergedSender { tx.smsSender = mergedSender }
                        if let mergedSuffix { tx.smsAccountSuffix = mergedSuffix }
                        if let mergedRecip { tx.smsRecipientSuffix = mergedRecip }
                        if isGenericSMSMerchant(tx.merchant) && !isGenericSMSMerchant(secondary.merchant) {
                            tx.merchant = secondary.merchant
                        } else if isGenericSMSMerchant(tx.merchant), let recip = mergedRecip {
                            tx.merchant = "IBAN ending \(recip)"
                        }
                        tx.rawText = combinedRaw
                        tx.isPossibleDuplicate = false
                        tx.smsConfidence = .high
                        tx.smsClassificationReason = "Merged SMS with same reference (\(ref1)), date & time, and account using highest amount and lowest balance"
                    }
                    timeCache.removeValue(forKey: primary.id)

                    if !primary.isPending {
                        _ = Ledger.syncBalanceFromSMS(primary, context: context)
                    }
                    modified = true
                }
            }
        }

        if modified {
            Ledger.recordSnapshot(context: context)
            try? context.save()
        }

        // 3. Reconcile duplicates strictly by reference code
        Ledger.reconcileDuplicates(context: context)

        let postTxs = (try? context.fetch(FetchDescriptor<MoneyTransaction>(sortBy: [SortDescriptor(\.date)]))) ?? allTxs
        let postSig = reconcileSignature(accounts: allAccounts, transactions: postTxs)
        reconcileCacheLock.lock()
        lastReconcileSignature[ctxKey] = postSig
        reconcileCacheLock.unlock()
    }
}

extension AIService {

    // MARK: - Option 2: AI-Assisted Bank Statement Recognition (Fallback Mechanism)

    static func analyzeBankStatement(
        rawText: String,
        filename: String,
        detectedHeaders: [String] = []
    ) async throws -> AIStatementRecognitionResult {
        let client = try GeminiAccount.client()
        let categories = SpendCategory.allCases.map(\.rawValue)

        let schema: [String: Any] = [
            "type": "OBJECT",
            "properties": [
                "bankName": ["type": "STRING", "nullable": true],
                "docType": ["type": "STRING", "enum": ["Bank Account Statement", "Credit Card Statement", "General Financial Statement"]],
                "currency": ["type": "STRING"],
                "accountIBAN": ["type": "STRING", "nullable": true],
                "cardLast4": ["type": "STRING", "nullable": true],
                "signNotation": ["type": "STRING", "enum": ["parentheses_signed", "columnar_debit_credit", "credit_card_negative_payment", "standard_signed"]],
                "dateFormat": ["type": "STRING", "nullable": true],
                "confidence": ["type": "NUMBER"],
                "isMappingUncertain": ["type": "BOOLEAN"],
                "uncertaintyNotes": [
                    "type": "ARRAY",
                    "items": ["type": "STRING"]
                ],
                "openingBalance": ["type": "NUMBER", "nullable": true],
                "closingBalance": ["type": "NUMBER", "nullable": true],
                "columnMapping": [
                    "type": "OBJECT",
                    "properties": [
                        "dateColumnHeader": ["type": "STRING", "nullable": true],
                        "descriptionColumnHeader": ["type": "STRING", "nullable": true],
                        "debitColumnHeader": ["type": "STRING", "nullable": true],
                        "creditColumnHeader": ["type": "STRING", "nullable": true],
                        "amountColumnHeader": ["type": "STRING", "nullable": true],
                        "balanceColumnHeader": ["type": "STRING", "nullable": true],
                        "referenceColumnHeader": ["type": "STRING", "nullable": true],
                        "currencyColumnHeader": ["type": "STRING", "nullable": true]
                    ]
                ],
                "transactions": [
                    "type": "ARRAY",
                    "items": [
                        "type": "OBJECT",
                        "properties": [
                            "date": ["type": "STRING"],
                            "merchant": ["type": "STRING"],
                            "rawDescription": ["type": "STRING"],
                            "debit": ["type": "NUMBER", "nullable": true],
                            "credit": ["type": "NUMBER", "nullable": true],
                            "amount": ["type": "NUMBER"],
                            "isIncome": ["type": "BOOLEAN"],
                            "balance": ["type": "NUMBER", "nullable": true],
                            "reference": ["type": "STRING", "nullable": true],
                            "category": ["type": "STRING", "enum": categories]
                        ],
                        "required": ["date", "merchant", "rawDescription", "amount", "isIncome", "category"]
                    ]
                ]
            ],
            "required": ["docType", "currency", "signNotation", "confidence", "isMappingUncertain", "uncertaintyNotes", "columnMapping", "transactions"]
        ]

        let headerHint = detectedHeaders.isEmpty ? "None pre-detected" : detectedHeaders.joined(separator: " | ")
        let truncatedText = String(rawText.prefix(24000))
        let system = """
        You are an expert bank statement structure analyzer and financial transaction extractor.
        Analyze the provided bank statement text (from PDF, Excel, or CSV, in any language including English and Arabic) and:
        1. Identify the document structure and column mapping (date, description, debit, credit, amount, balance, reference, currency).
        2. Identify the bank name, statement type (Bank Account Statement vs Credit Card Statement), currency, IBAN, last 4 digits of card number, date format, and amount sign notation.
        3. Extract every real transaction row in chronological or table order without missing, duplicating, or reversing debit/credit polarity.
        CRITICAL RULES:
        - NEVER silently guess or fabricate missing or uncertain financial values. If any column mapping or direction is ambiguous, set isMappingUncertain=true and explain clearly in uncertaintyNotes.
        - Exclude Opening Balance, Closing Balance, Carried Forward, Brought Forward, and summary/subtotal lines from the transactions array.
        - For Bank Account Statements: deposits, salary, inward transfers, and credits have isIncome=true; withdrawals, purchases, outward transfers, fees, and debits have isIncome=false.
        - For Credit Card Statements: card payments received and refunds have isIncome=true; card purchases and fees have isIncome=false.
        - Format every transaction date as YYYY-MM-DD when unambiguous, or keep its exact date string if needed.
        - Amount must always be a positive number (> 0).
        """

        let prompt = "Filename: \(filename)\nDetected column headers: \(headerHint)\n\nStatement Content:\n\(truncatedText)"
        let reply = try await client.generate(
            system: system,
            turns: [GeminiTurn(isUser: true, text: prompt)],
            schema: schema,
            temperature: 0.1
        )
        return try decodeBankStatementAIResponse(reply)
    }

    static func decodeBankStatementAIResponse(_ jsonString: String) throws -> AIStatementRecognitionResult {
        let obj = try GeminiClient.decodeObject(jsonString)

        let bankName = (obj["bankName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let docTypeStr = (obj["docType"] as? String) ?? StatementDocType.generic.rawValue
        let docType: StatementDocType = {
            if let exact = StatementDocType(rawValue: docTypeStr) { return exact }
            let low = docTypeStr.lowercased()
            if low.contains("credit") || low.contains("card") { return .creditCard }
            if low.contains("bank") || low.contains("account") { return .bankAccount }
            return .generic
        }()
        let currency = ((obj["currency"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? AppSettings.currency
        let accountIBAN = (obj["accountIBAN"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cardLast4 = (obj["cardLast4"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let signStr = (obj["signNotation"] as? String) ?? AmountSignNotation.standardSigned.rawValue
        let signNotation: AmountSignNotation = {
            if let exact = AmountSignNotation(rawValue: signStr) { return exact }
            let low = signStr.lowercased()
            if low.contains("columnar") || (low.contains("debit") && low.contains("credit")) { return .columnarDebitCredit }
            if low.contains("parenthes") { return .parenthesesSigned }
            if low.contains("credit_card") || low.contains("creditcard") { return .creditCardNegativePayment }
            return .standardSigned
        }()
        let dateFormat = (obj["dateFormat"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let confidence = (obj["confidence"] as? NSNumber)?.doubleValue ?? 0.85
        let isMappingUncertain = (obj["isMappingUncertain"] as? Bool) ?? false
        let uncertaintyNotes = (obj["uncertaintyNotes"] as? [String]) ?? []
        let openingBalance = (obj["openingBalance"] as? NSNumber)?.doubleValue
        let closingBalance = (obj["closingBalance"] as? NSNumber)?.doubleValue

        let mapDict = obj["columnMapping"] as? [String: Any] ?? [:]
        func cleanHeader(_ key: String) -> String? {
            guard let v = (mapDict[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else { return nil }
            return v
        }
        let columnMapping = StatementColumnMapping(
            dateColumnHeader: cleanHeader("dateColumnHeader"),
            descriptionColumnHeader: cleanHeader("descriptionColumnHeader"),
            debitColumnHeader: cleanHeader("debitColumnHeader"),
            creditColumnHeader: cleanHeader("creditColumnHeader"),
            amountColumnHeader: cleanHeader("amountColumnHeader"),
            balanceColumnHeader: cleanHeader("balanceColumnHeader"),
            referenceColumnHeader: cleanHeader("referenceColumnHeader"),
            currencyColumnHeader: cleanHeader("currencyColumnHeader")
        )

        var parsedItems: [ParsedStatementItem] = []
        let txArray = obj["transactions"] as? [[String: Any]] ?? []
        for txObj in txArray {
            let dateStr = (txObj["date"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard let date = StatementService.parseDate(dateStr) else { continue }

            let debitVal = (txObj["debit"] as? NSNumber)?.doubleValue ?? 0
            let creditVal = (txObj["credit"] as? NSNumber)?.doubleValue ?? 0
            let rawAmt = (txObj["amount"] as? NSNumber)?.doubleValue ?? 0
            let amount = rawAmt > 0 ? abs(rawAmt) : max(abs(debitVal), abs(creditVal))
            guard amount > 0 else { continue }

            let isIncome: Bool = {
                if creditVal > 0 && debitVal == 0 { return true }
                if debitVal > 0 && creditVal == 0 { return false }
                return (txObj["isIncome"] as? Bool) ?? false
            }()

            let rawDesc = (txObj["rawDescription"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let rawMerch = (txObj["merchant"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? rawDesc
            let cleaned = BankProfileRegistry.cleanMerchantDescription(rawMerch.isEmpty ? rawDesc : rawMerch, docType: docType)
            let finalMerchant = cleaned.merchant.isEmpty ? (rawMerch.isEmpty ? "Statement Transaction" : rawMerch) : cleaned.merchant
            let ref = ((txObj["reference"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? cleaned.ref
            let cat = cleaned.category ?? SpendCategory.resolve(txObj["category"] as? String)

            parsedItems.append(ParsedStatementItem(
                date: date,
                merchant: finalMerchant,
                amount: amount,
                isIncome: isIncome,
                reference: ref,
                category: cat,
                rawDescription: rawDesc.isEmpty ? finalMerchant : rawDesc,
                isSelected: !isMappingUncertain,
                aiSuggestedCategory: true
            ))
        }

        return AIStatementRecognitionResult(
            detectedBank: bankName?.isEmpty == false ? bankName : nil,
            docType: docType,
            currency: currency,
            accountIBAN: accountIBAN?.isEmpty == false ? accountIBAN : nil,
            cardLast4: cardLast4?.isEmpty == false ? cardLast4 : nil,
            signNotation: signNotation,
            dateFormat: dateFormat?.isEmpty == false ? dateFormat : nil,
            columnMapping: columnMapping,
            confidence: confidence,
            isMappingUncertain: isMappingUncertain,
            uncertaintyNotes: uncertaintyNotes,
            openingBalance: openingBalance,
            closingBalance: closingBalance,
            items: parsedItems
        )
    }
}
