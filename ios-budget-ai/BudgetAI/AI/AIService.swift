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

        var category = SpendCategory(rawValue: obj["category"] as? String ?? "") ?? .other
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

        // Fetch the SMS sender ID / bank phone number from the message first if Shortcuts did not pass it
        let effectiveSender = SMSParser.extractSenderOrPhone(in: trimmed, explicitSender: sender)

        // 1. Deterministic, bank-specific parsing rules first
        let deterministic = SMSParser.parse(trimmed, sender: effectiveSender, context: context)
        var parsed: ParsedSMS? = deterministic
        var usedAI = false

        // 2. Use AI only as a fallback when deterministic parsing is nil or uncertain
        if (deterministic == nil || deterministic?.requiresReview == true) && GeminiAccount.isConfigured {
            do {
                if let aiParsed = try await AIService.parseSMS(trimmed, sender: effectiveSender, context: context) {
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

        let cleanManualBank = manualBank?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedSMSBank = (cleanManualBank?.isEmpty == false ? cleanManualBank : nil)
            ?? p.detectedBank
            ?? SMSUserRules.bank(forSender: effectiveSender, in: trimmed)
        let resolvedSender = effectiveSender ?? p.sender

        // Determine account involved in the transaction (supports multiple accounts e.g. 17515151 -> BisB, 17123456 -> ila).
        let matchingDigits: String? = {
            if p.transactionType == .transferIn {
                return p.accountSuffix ?? p.recipientSuffix
            }
            // For outgoing transfers and card expenses, check accountSuffix or cardDigits
            return p.accountSuffix ?? p.cardDigits
        }()

        // If digits weren't extracted by regex, check if the raw SMS text contains any account's configured smsMatch
        let directAccountFromSMS: Account? = {
            if let d = matchingDigits, let acc = SMSParser.findMatchingAccount(forBank: resolvedSMSBank, senderOrPhone: resolvedSender, digits: d, in: context) {
                return acc
            }
            return SMSParser.findAccountInSMSText(trimmed, detectedBank: resolvedSMSBank, in: context)
        }()

        let savedRuleAccount: UUID? = {
            func isCompatible(_ acc: Account) -> Bool {
                if p.matchedUserRule { return true }
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
            if let senderAccID = SMSUserRules.accountID(forSender: resolvedSender, in: trimmed),
               let acc = Ledger.account(senderAccID, context: context), isCompatible(acc) {
                return senderAccID
            }
            return nil
        }()
        // Never fall back to a default/first account when the SMS bank or account digits do not match any user account.
        var target: UUID? = accountID
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
        if !isCardPayment,
           (rawParsedType.isTransferType
            || p.category == .internalTransfer
            || p.category == .transfers
            || (p.isIncome && (trimmed.lowercased().contains("credit") || trimmed.lowercased().contains("fawri") || trimmed.contains("إيداع") || trimmed.contains("ايداع") || trimmed.contains("وارد")))
            || (!p.isIncome && (trimmed.lowercased().contains("debit") || trimmed.lowercased().contains("transfer") || trimmed.contains("خصم") || trimmed.contains("صادر")))),
           let mergedOutcome = mergeSameTimeTransferIfNeeded(
               parsed: p,
               rawParsedType: rawParsedType,
               rawSMS: trimmed,
               resolvedBank: resolvedSMSBank,
               resolvedSender: resolvedSender,
               targetAccountID: target,
               usedAI: usedAI,
               forceApprove: forceApprove,
               context: context
           ) {
            return mergedOutcome
        }

        // If the SMS was not previously recognized by a saved user rule:
        // - Any Transfer Out is added as an Expense
        // - Any Transfer In is added as Income
        if !p.matchedUserRule {
            if p.transactionType == .transferOut {
                p.transactionType = .expense
                p.isIncome = false
                if p.category == .transfers {
                    if let guessed = Categorizer.guess(p.merchant), guessed != .income, guessed != .transfers, guessed != .internalTransfer {
                        p.category = guessed
                    } else {
                        p.category = .other
                    }
                }
            } else if p.transactionType == .transferIn {
                p.transactionType = .income
                p.isIncome = true
                if p.category == .transfers || !p.category.isIncomeCategory {
                    p.category = .income
                }
            }
        }

        var learnedMerchant = false
        if !p.matchedUserRule && !p.transactionType.isTransferType && p.transactionType != .unknown,
           let learned = Categorizer.learnedMatch(for: p.merchant, in: context, isIncome: p.isIncome) {
            p.category = learned.category
            if learned.subcategory != nil { p.subcategory = learned.subcategory }
            learnedMerchant = true
        }

        // If there is no user rule and categorization is uncertain (.other or low confidence):
        // Let AI search for their categorization, or fallback to .other if no information is found.
        // Transactions with uncertain categorization are NOT put on the list waiting for review.
        if !p.matchedUserRule && !learnedMerchant && !p.transactionType.isTransferType && p.transactionType != .unknown && !p.isIncome {
            if p.category == .other || p.confidence == .low {
                if GeminiAccount.isConfigured {
                    if let aiCats = try? await AIService.categorize(merchants: [p.merchant]),
                       let aiCat = aiCats[p.merchant], aiCat != .income, aiCat != .transfers {
                        p.category = aiCat
                        p.confidence = .high
                        usedAI = true
                    }
                }
                if p.category == .transfers || p.category.isIncomeCategory {
                    p.category = .other
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
        tx.smsAccountSuffix = p.accountSuffix
        tx.smsRecipientSuffix = p.recipientSuffix
        tx.toAccountID = p.toAccountID
        tx.goalID = p.goalID
        tx.smsBalanceIsCardLimit = p.balanceIsCardLimit || isCardPayment

        // Quarantine check:
        // If an SMS has:
        // 1. Unknown sender bank
        // 2. Unmatched account
        // 3. Uncertain classification / low confidence / needs review
        // -> Quarantine: Keep it in the Needs Review filter and DO NOT include in any accounts until approved!
        // (Note: Unmatched balances are not quarantined; balance syncing handles bank balance updates automatically)
        let allAccounts = (try? context.fetch(FetchDescriptor<Account>())) ?? []
        let targetAccount = target.flatMap { id in allAccounts.first(where: { $0.id == id }) }
        let effectiveBank = resolvedSMSBank ?? (targetAccount?.institution.isEmpty == false ? targetAccount?.institution : nil)
        let matchedByDigits = matchingDigits.flatMap { d in
            SMSParser.findMatchingAccount(forBank: resolvedSMSBank, senderOrPhone: resolvedSender, digits: d, in: context)
        } ?? directAccountFromSMS
        let matchedByBankOrSender = savedRuleAccount != nil || SMSParser.findMatchingAccount(forBank: effectiveBank, senderOrPhone: resolvedSender, digits: matchingDigits, in: context) != nil
        let bankUnknown: Bool = {
            if matchedByDigits != nil { return false }
            if targetAccount != nil && (accountID != nil || savedRuleAccount != nil) { return false }
            return effectiveBank == nil || effectiveBank?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true || effectiveBank?.lowercased().contains("unknown") == true
        }()
        let accountUnmatched: Bool = {
            guard let targetAccount else { return true }
            if accountID != nil || p.matchedUserRule { return false }
            if let b = resolvedSMSBank, !b.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               targetAccount.kind != .creditCard,
               !SMSParser.accountMatchesBank(targetAccount, bank: b) {
                return true
            }
            if let suffix = p.accountSuffix, !suffix.isEmpty {
                let targetDigits = targetAccount.smsMatch.trimmingCharacters(in: .whitespacesAndNewlines)
                if !targetDigits.isEmpty && !SMSParser.digitsMatch(accountMatch: targetDigits, query: suffix) {
                    return true
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
        // Uncertain categorization must NOT put transactions on the list waiting for review.
        // Only transactions with an unknown transaction type (.unknown) need review.
        let isUncertain = p.transactionType == .unknown

        let mustQuarantine = bankUnknown || accountUnmatched || isUncertain

        if mustQuarantine {
            tx.isPending = true
        } else {
            tx.isPending = !forceApprove && !AppSettings.smsAutoApprove
        }

        let code = AppSettings.currency
        // Keep the user's note field empty for SMS transactions (do not put SMS reference in it).
        // The SMS reference is preserved in tx.smsReference.
        tx.note = ""

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

    /// When a user transfers between two accounts, they often receive two SMS alerts at the same date & time
    /// (e.g. one is "Transfer between accounts" / `internalTransfer` and the other is "Transfer Out" / `transferOut`,
    /// or one is `transferOut` from Account A and the other is `transferIn` to Account B).
    /// If the date, time, and amount match, this merges them into ONE single transaction instead of creating a duplicate,
    /// while updating each account's balance strictly from its own SMS balance separately.
    private static func mergeSameTimeTransferIfNeeded(
        parsed: ParsedSMS,
        rawParsedType: SMSTransactionType,
        rawSMS: String,
        resolvedBank: String?,
        resolvedSender: String?,
        targetAccountID: UUID?,
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

        for existing in candidates {
            guard abs(existing.amount - parsed.amount) < 0.0005 else { continue }
            guard let existingRole = originalTransferRole(for: existing, context: context) else { continue }

            // Check if date & time are the same:
            // 1. Exact/near-exact timestamp match (within 3 minutes / 180 seconds, e.g. both at 2026/10/27 15:26)
            // 2. Or same calendar day when one of the two SMS messages did not include an explicit HH:mm time
            let timeDiff = abs(existing.date.timeIntervalSince(incomingDate))
            let existingTime = existing.rawText.flatMap { SMSParser.extractDateAndTime(in: $0).time }
            let isSameDateAndTime: Bool = {
                if let t1 = existingTime, let t2 = incomingTime {
                    return t1 == t2 || timeDiff <= 180
                }
                if timeDiff <= 180 {
                    return true
                }
                // One SMS had a date without HH:mm time on the same calendar day
                return Calendar.current.isDate(existing.date, inSameDayAs: incomingDate) && (existingTime == nil || incomingTime == nil)
            }()
            guard isSameDateAndTime else { continue }

            // Check if the pair represents the same transfer between accounts:
            // Case 1: One is .internalTransfer (transfer between accounts) and the other is .transferOut, .transferIn, or .internalTransfer
            let oneIsInternal = (existingRole == .internalTransfer || newRole == .internalTransfer)
            // Case 2: One is .transferOut and the other is .transferIn between two accounts at the same date & time
            let isOppositeTransferLegs = (existingRole == .transferOut && newRole == .transferIn)
                || (existingRole == .transferIn && newRole == .transferOut)
            // Case 3: Both are .transferOut at the same date & time where one has a recipient matching a user account or they are from two different accounts
            let isDualTransferOut: Bool = {
                guard existingRole == .transferOut && newRole == .transferOut else { return false }
                if let exAcc = existing.accountID, let newAcc = targetAccountID, exAcc != newAcc {
                    return true
                }
                if let recip = parsed.recipientSuffix ?? existing.smsRecipientSuffix,
                   SMSParser.findMatchingAccount(suffix: recip, in: context) != nil {
                    return true
                }
                return false
            }()

            guard oneIsInternal || isOppositeTransferLegs || isDualTransferOut else { continue }

            // If both are from the same bank with two different non-empty reference numbers AND neither is an internal transfer
            // nor from a different bank/account, do not merge distinct transfers.
            if !oneIsInternal,
               let r1 = existing.smsReference?.trimmingCharacters(in: .whitespacesAndNewlines), !r1.isEmpty,
               let r2 = parsed.referenceNumber?.trimmingCharacters(in: .whitespacesAndNewlines), !r2.isEmpty,
               r1.caseInsensitiveCompare(r2) != .orderedSame,
               existing.accountID == targetAccountID {
                continue
            }

            // Record each SMS's own bank balance strictly against the account of that SMS's sender bank!
            // This guarantees the two accounts' balances are NEVER merged or applied to one account in both.
            var accountBalances: [UUID: Double] = [:]
            let existingOriginAccID: UUID? = {
                if let bankAcc = SMSParser.findMatchingAccount(forBank: existing.smsBank, senderOrPhone: existing.smsSender, digits: existing.smsAccountSuffix, in: context) {
                    return bankAcc.id
                }
                return existing.accountID
            }()
            if let exOrigin = existingOriginAccID, let exBal = existing.smsBalance {
                accountBalances[exOrigin] = exBal
            }
            if let exTo = existing.toAccountID, let exToBal = existing.smsToBalance {
                accountBalances[exTo] = exToBal
            }
            let incomingOriginAccID: UUID? = {
                if let bankAcc = SMSParser.findMatchingAccount(forBank: resolvedBank, senderOrPhone: resolvedSender, digits: parsed.accountSuffix, in: context) {
                    return bankAcc.id
                }
                return targetAccountID
            }()
            if let inOrigin = incomingOriginAccID, let pBal = parsed.balance {
                accountBalances[inOrigin] = pBal
            }

            // Analyze both SMS messages to determine which is the DEBIT leg (money leaving) and which is the CREDIT leg (money entering)
            let existingRawText = existing.rawText ?? ""
            let existingLegDir = SMSParser.analyzeTransferLegDirection(
                in: existingRawText,
                fallbackIsIncome: existingRole == .transferIn || existing.isIncome
            )
            let incomingLegDir = SMSParser.analyzeTransferLegDirection(
                in: rawSMS,
                fallbackIsIncome: newRole == .transferIn || parsed.isIncome
            )
            let incomingIsCreditLeg: Bool = {
                if incomingLegDir == .credit && existingLegDir != .credit { return true }
                if existingLegDir == .credit && incomingLegDir != .credit { return false }
                if newRole == .transferIn && existingRole != .transferIn { return true }
                if existingRole == .transferIn && newRole != .transferIn { return false }
                if parsed.recipientSuffix != nil && existing.smsRecipientSuffix == nil { return true }
                return true
            }()

            // Resolve source (DEBIT / from) and destination (CREDIT / to) accounts for the single merged Internal Transfer transaction
            var mergedFromID: UUID? = nil
            var mergedToID: UUID? = nil

            let exAcc = existingOriginAccID ?? existing.accountID
            let newAcc = incomingOriginAccID ?? targetAccountID

            if let exAcc, let newAcc, exAcc != newAcc {
                // The two SMS messages belong to two DIFFERENT accounts (e.g., BisB and ila Bank)
                if existingLegDir == .credit || existingRole == .transferIn {
                    mergedFromID = newAcc
                    mergedToID = exAcc
                } else if incomingLegDir == .credit || newRole == .transferIn {
                    mergedFromID = exAcc
                    mergedToID = newAcc
                } else if existingRole == .internalTransfer, existing.toAccountID == newAcc {
                    mergedFromID = exAcc
                    mergedToID = newAcc
                } else if newRole == .internalTransfer, parsed.toAccountID == exAcc {
                    mergedFromID = newAcc
                    mergedToID = exAcc
                } else if existingRole == .internalTransfer {
                    mergedFromID = exAcc
                    mergedToID = existing.toAccountID ?? newAcc
                } else if newRole == .internalTransfer {
                    mergedFromID = newAcc
                    mergedToID = parsed.toAccountID ?? exAcc
                } else {
                    // Both were debit/transferOut on two different accounts: check if recipientSuffix matches one of them
                    if let recip = existing.smsRecipientSuffix ?? parsed.recipientSuffix,
                       let matchedDest = SMSParser.findMatchingAccount(suffix: recip, in: context) {
                        if matchedDest.id == newAcc {
                            mergedFromID = exAcc
                            mergedToID = newAcc
                        } else if matchedDest.id == exAcc {
                            mergedFromID = newAcc
                            mergedToID = exAcc
                        }
                    }
                    mergedFromID = mergedFromID ?? exAcc
                    mergedToID = mergedToID ?? newAcc
                }
            } else {
                // Both SMS messages are from the same source account (or one had nil account)
                mergedFromID = exAcc ?? newAcc
                mergedToID = existing.toAccountID ?? parsed.toAccountID
            }

            // Rule 6: When two SMS match in date & time, if destination account is still nil or equal to source,
            // resolve the credit account from recipientSuffix matching one of the user's accounts
            if mergedToID == nil || mergedToID == mergedFromID {
                if let recipSuffix = parsed.recipientSuffix ?? existing.smsRecipientSuffix,
                   let matchedDest = SMSParser.findMatchingAccount(suffix: recipSuffix, excludingAccountID: mergedFromID, in: context) {
                    mergedToID = matchedDest.id
                }
            }

            // Never allow mergedToID to equal mergedFromID
            if mergedToID == mergedFromID {
                mergedToID = nil
            }

            let mergedGoalID = existing.goalID ?? parsed.goalID
                ?? SMSParser.findMatchingGoal(suffix: parsed.recipientSuffix ?? existing.smsRecipientSuffix, accountID: mergedToID, in: context)?.id

            // Assign each account's balance strictly from its own SMS balance (`accountBalances[accountID]`):
            var sourceBalance: Double? = mergedFromID.flatMap { accountBalances[$0] }
            var destBalance: Double? = mergedToID.flatMap { accountBalances[$0] }

            // Fallback only if account ID wasn't in accountBalances and the SMS clearly belongs to that leg
            if sourceBalance == nil {
                if existingOriginAccID == mergedFromID {
                    sourceBalance = existing.smsBalance
                } else if incomingOriginAccID == mergedFromID {
                    sourceBalance = parsed.balance
                } else if existingRole != .transferIn && existingOriginAccID == nil {
                    sourceBalance = existing.smsBalance
                } else if newRole != .transferIn && incomingOriginAccID == nil {
                    sourceBalance = parsed.balance
                }
            }
            if destBalance == nil, let mergedToID {
                if existingOriginAccID == mergedToID {
                    destBalance = existing.smsBalance
                } else if incomingOriginAccID == mergedToID {
                    destBalance = parsed.balance
                } else if existing.toAccountID == mergedToID, let exToBal = existing.smsToBalance {
                    destBalance = exToBal
                }
            }

            // Determine BOTH banks from the two SMS messages (Debit bank first, Credit bank second)
            // so "SMS sender bank" includes both banks (e.g. "BisB · ila") while primaryBankName matches the Debit account!
            let debitBank: String? = {
                if let fromID = mergedFromID {
                    if incomingOriginAccID == fromID, let b = resolvedBank {
                        return SMSParser.primaryBankName(from: b)
                    }
                    if existingOriginAccID == fromID, let b = existing.smsBank {
                        return SMSParser.primaryBankName(from: b)
                    }
                    if let fromAcc = Ledger.account(fromID, context: context),
                       let accBank = SMSParser.bankName(forAccount: fromAcc) {
                        return accBank
                    }
                }
                return incomingIsCreditLeg
                    ? (SMSParser.primaryBankName(from: existing.smsBank) ?? resolvedBank)
                    : (resolvedBank ?? SMSParser.primaryBankName(from: existing.smsBank))
            }()
            let creditBank: String? = {
                if let toID = mergedToID {
                    if incomingOriginAccID == toID, let b = resolvedBank {
                        return SMSParser.primaryBankName(from: b)
                    }
                    if existingOriginAccID == toID, let b = existing.smsBank {
                        return SMSParser.primaryBankName(from: b)
                    }
                    if let toAcc = Ledger.account(toID, context: context),
                       let accBank = SMSParser.bankName(forAccount: toAcc) {
                        return accBank
                    }
                }
                return incomingIsCreditLeg
                    ? resolvedBank
                    : SMSParser.primaryBankName(from: existing.smsBank)
            }()
            let mergedBank = SMSParser.formatCombinedBanks(debitBank: debitBank, creditBank: creditBank)
            let mergedSender: String? = {
                if let fromID = mergedFromID {
                    if incomingOriginAccID == fromID, let s = resolvedSender, !s.isEmpty {
                        return s
                    }
                    if existingOriginAccID == fromID, let s = existing.smsSender, !s.isEmpty {
                        return s
                    }
                }
                return existing.smsSender ?? resolvedSender
            }()
            let combinedRawSMS: String = {
                let firstSMS = incomingIsCreditLeg ? existingRawText : rawSMS
                let secondSMS = incomingIsCreditLeg ? rawSMS : existingRawText
                if firstSMS.isEmpty { return secondSMS }
                if secondSMS.isEmpty || firstSMS == secondSMS { return firstSMS }
                if firstSMS.contains(secondSMS) { return firstSMS }
                return "\(firstSMS)\n\n---\n\n\(secondSMS)"
            }()

            // Update the existing transaction in-place so there is only ONE transaction in the database
            Ledger.edit(existing, context: context) { tx in
                tx.smsTransactionType = .internalTransfer
                tx.category = .internalTransfer
                tx.isIncome = false
                if let mergedFromID { tx.accountID = mergedFromID }
                tx.toAccountID = mergedToID
                if let mergedGoalID { tx.goalID = mergedGoalID }

                if let toID = tx.toAccountID, let destAcc = Ledger.account(toID, context: context) {
                    if let fromID = tx.accountID, let srcAcc = Ledger.account(fromID, context: context), srcAcc.id != destAcc.id {
                        tx.merchant = "\(srcAcc.name) → \(destAcc.name)"
                    } else {
                        tx.merchant = "Transfer to \(destAcc.name)"
                    }
                } else if newRole == .internalTransfer && !parsed.merchant.isEmpty {
                    tx.merchant = parsed.merchant
                }

                tx.rawText = combinedRawSMS
                tx.smsBank = mergedBank
                tx.smsSender = mergedSender
                if tx.smsReference == nil { tx.smsReference = parsed.referenceNumber }
                if tx.smsRecipientSuffix == nil { tx.smsRecipientSuffix = parsed.recipientSuffix }
                if tx.smsAccountSuffix == nil { tx.smsAccountSuffix = parsed.accountSuffix }
                tx.smsBalance = sourceBalance
                tx.smsToBalance = destBalance
                tx.smsConfidence = .high
                tx.smsClassificationReason = "Rule 6: Merged 2 matching SMS at same date & time (Debit: \(debitBank ?? "Source") → Credit: \(creditBank ?? "Destination"))"
            }

            var syncedBalance: Double? = nil
            if existing.isPending && (forceApprove || AppSettings.smsAutoApprove) && existing.smsBank != nil && existing.accountID != nil {
                let approveRes = Ledger.approve(existing, context: context)
                syncedBalance = approveRes.balanceSynced
            } else if !existing.isPending {
                syncedBalance = Ledger.syncBalanceFromSMS(existing, context: context)
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
                flaggedDuplicate: true,
                alerts: [],
                pending: existing.isPending,
                balanceSynced: syncedBalance,
                message: summary
            )
        }

        return nil
    }
}
