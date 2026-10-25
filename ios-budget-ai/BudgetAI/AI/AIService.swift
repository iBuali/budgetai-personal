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
        let recent = transactions.sorted { $0.date > $1.date }.prefix(40).map {
            "\(df.string(from: $0.date)) \($0.merchant) \($0.isIncome ? "+" : "-")\(Money.number($0.amount, decimals: Money.digits(code))) [\($0.category.title)]"
        }
        lines.append("Recent transactions:\n" + recent.joined(separator: "\n"))
        return lines.joined(separator: "\n")
    }

    // MARK: SMS parsing

    static func parseSMS(_ text: String) async throws -> ParsedSMS? {
        let client = try GeminiAccount.client()
        let categories = SpendCategory.allCases.map(\.rawValue)
        let schema: [String: Any] = [
            "type": "OBJECT",
            "properties": [
                "isTransaction": ["type": "BOOLEAN"],
                "amount": ["type": "NUMBER"],
                "currency": ["type": "STRING"],
                "isIncome": ["type": "BOOLEAN"],
                "merchant": ["type": "STRING"],
                "category": ["type": "STRING", "enum": categories],
                "date": ["type": "STRING", "nullable": true],
                "bank": ["type": "STRING", "nullable": true],
            ],
            "required": ["isTransaction", "amount", "isIncome", "merchant", "category"],
        ]
        let system = """
        You read bank SMS alerts from Bahrain and the GCC (English or Arabic) and extract one transaction.
        isTransaction=false for OTPs, promotions, or balance-only messages. merchant is a short clean brand name \
        (e.g. "Lulu Hypermarket", "Talabat"); for incoming money use the sender or "Salary". \
        category must be one of: \(categories.joined(separator: ", ")). Income uses "income". \
        date as yyyy-MM-dd if present. bank is the bank name if present (NBB, BBK, KFH, BisB, ...).
        """
        let reply = try await client.generate(system: system, turns: [GeminiTurn(isUser: true, text: text)], schema: schema, temperature: 0.1)
        let obj = try GeminiClient.decodeObject(reply)
        guard (obj["isTransaction"] as? Bool) == true, let amount = (obj["amount"] as? NSNumber)?.doubleValue, amount > 0 else { return nil }
        let isIncome = obj["isIncome"] as? Bool ?? false
        var category = SpendCategory(rawValue: obj["category"] as? String ?? "") ?? .other
        if isIncome && category != .transfers { category = .income }
        var date: Date?
        if let ds = obj["date"] as? String {
            let df = DateFormatter()
            df.dateFormat = "yyyy-MM-dd"
            if let d = df.date(from: ds), Calendar.current.isDate(d, inSameDayAs: .now) == false, d < .now {
                date = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: d)
            }
        }
        let merchant = (obj["merchant"] as? String)?.trimmingCharacters(in: .whitespaces)
        return ParsedSMS(amount: amount, currency: obj["currency"] as? String, isIncome: isIncome,
                         merchant: (merchant?.isEmpty == false ? merchant! : (isIncome ? "Incoming transfer" : "Card purchase")),
                         category: category, date: date, accountHint: obj["bank"] as? String)
    }

    // MARK: Categorization

    static func categorize(merchants: [String]) async throws -> [String: SpendCategory] {
        guard !merchants.isEmpty else { return [:] }
        let client = try GeminiAccount.client()
        let categories = SpendCategory.expenseCases.map(\.rawValue)
        let schema: [String: Any] = [
            "type": "OBJECT",
            "properties": ["items": ["type": "ARRAY", "items": [
                "type": "OBJECT",
                "properties": ["merchant": ["type": "STRING"], "category": ["type": "STRING", "enum": categories]],
                "required": ["merchant", "category"],
            ]]],
            "required": ["items"],
        ]
        let prompt = "Categorize these merchants (Bahrain/GCC context). Categories: \(categories.joined(separator: ", ")).\n" + merchants.joined(separator: "\n")
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
    var usedAI = false
    var flaggedDuplicate = false
    var alerts: [String] = []
    var message: String
}

enum SMSImporter {
    static func importText(_ text: String, context: ModelContext) async -> SMSImportOutcome {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return SMSImportOutcome(message: "The message was empty.") }
        var parsed: ParsedSMS?
        var usedAI = false
        var aiSaidNotTransaction = false
        if GeminiAccount.isConfigured {
            do {
                parsed = try await AIService.parseSMS(trimmed)
                usedAI = true
                aiSaidNotTransaction = parsed == nil
            } catch {
                parsed = nil
            }
        }
        if parsed == nil && !aiSaidNotTransaction { parsed = SMSParser.parse(trimmed) }
        guard let p = parsed else {
            return SMSImportOutcome(usedAI: usedAI, message: "No transaction found in this message.")
        }
        let tx = MoneyTransaction(amount: p.amount, isIncome: p.isIncome, merchant: p.merchant, category: p.category,
                                  date: p.date ?? .now, source: .sms,
                                  accountID: Ledger.defaultAccountID(context: context, hint: p.accountHint))
        tx.rawText = trimmed
        tx.aiCategorized = usedAI
        let code = AppSettings.currency
        if let c = p.currency, !c.isEmpty, c.uppercased() != code {
            tx.note = "Original currency: \(c.uppercased())"
        }
        let result = Ledger.add(tx, context: context)
        let summary = "\(tx.isIncome ? "Added income" : "Added") \(Money.format(tx.amount, code)) · \(tx.merchant) · \(tx.category.title)"
        return SMSImportOutcome(transaction: tx, usedAI: usedAI, flaggedDuplicate: result.flaggedDuplicate,
                                alerts: result.alerts,
                                message: result.flaggedDuplicate ? summary + " (possible duplicate)" : summary)
    }
}
