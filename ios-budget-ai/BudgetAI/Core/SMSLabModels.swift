import Foundation

// MARK: - SMS Testing Lab · Models
//
// Lab data (imported SMS, expectations, results) lives in its own JSON store under
// Application Support/SMSLab. It never touches SwiftData, accounts or live transactions.

enum SMSDirection: String, Codable, CaseIterable, Identifiable {
    case incoming
    case outgoing
    case internalMove = "internal"
    case none

    var id: String { rawValue }

    var title: String {
        switch self {
        case .incoming: "Incoming"
        case .outgoing: "Outgoing"
        case .internalMove: "Internal"
        case .none: "Unknown"
        }
    }

    static func from(_ type: SMSTransactionType?) -> SMSDirection {
        guard let type else { return .none }
        switch type {
        case .income, .transferIn, .refund: return .incoming
        case .expense, .transferOut, .fee: return .outgoing
        case .internalTransfer: return .internalMove
        case .unknown: return .none
        }
    }
}

enum LabField: String, Codable, CaseIterable, Identifiable {
    case bank, amount, type, direction, account, category
    var id: String { rawValue }
    var title: String {
        switch self {
        case .bank: "Bank"
        case .amount: "Amount"
        case .type: "Type"
        case .direction: "Direction"
        case .account: "Account"
        case .category: "Category"
        }
    }
}

/// Manually assigned correct classification. Only fields that are set are compared.
struct LabExpected: Codable, Equatable {
    var nonTransaction: Bool? = nil
    var bank: String? = nil
    var amount: Double? = nil
    /// `SMSTransactionType` raw value.
    var type: String? = nil
    /// `SMSDirection` raw value.
    var direction: String? = nil
    /// Last 4 digits of the source account / card.
    var account: String? = nil
    /// `SpendCategory` raw value.
    var category: String? = nil

    var labeledFields: [LabField] {
        var out: [LabField] = []
        if !(bank ?? "").isEmpty { out.append(.bank) }
        if amount != nil { out.append(.amount) }
        if !(type ?? "").isEmpty { out.append(.type) }
        if !(direction ?? "").isEmpty { out.append(.direction) }
        if !(account ?? "").isEmpty { out.append(.account) }
        if !(category ?? "").isEmpty { out.append(.category) }
        return out
    }

    var isLabeled: Bool { nonTransaction == true || !labeledFields.isEmpty }
}

struct LabSample: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var text: String
    var sender: String? = nil
    var source: String
    var importedAt: Date = .now
    var expected: LabExpected = LabExpected()
    /// Approved, permanent regression test case. Locked against automatic changes.
    var isTestCase: Bool = false
    var approvedAt: Date? = nil
    /// Pass/fail the first time this sample was evaluated with labels (used for "improvements").
    var baselinePassed: Bool? = nil

    var dedupeKey: String {
        SMSKnowledge.matchText(text) + "|" + SMSUserRules.normalizeSender(sender ?? "")
    }
}

struct LabReason: Codable, Equatable, Hashable {
    var kind: String
    var text: String

    var symbol: String {
        switch kind {
        case "filter": "line.3.horizontal.decrease.circle"
        case "bank": "building.columns"
        case "amount": "number"
        case "type": "arrow.left.arrow.right"
        case "account": "creditcard"
        case "category": "square.grid.2x2"
        case "knowledge": "brain"
        case "rule": "person.crop.circle.badge.checkmark"
        default: "info.circle"
        }
    }
}

/// Parser output for one SMS, captured from the production `SMSParser`.
struct LabSnapshot: Codable, Equatable {
    var isTransaction: Bool
    var skipReason: String? = nil
    var bank: String? = nil
    var bankConfidence: String = SMSConfidence.low.rawValue
    var amount: Double? = nil
    var currency: String? = nil
    var type: String? = nil
    var direction: String = SMSDirection.none.rawValue
    var account: String? = nil
    var recipient: String? = nil
    var category: String? = nil
    var merchant: String? = nil
    var confidence: String? = nil
    var note: String? = nil
    var knowledgeRuleID: String? = nil
    var matchedPersonalRule: Bool = false
    var reasoning: [LabReason] = []
    var evaluatedAt: Date = .now
    var engineLabel: String = ""

    func display(_ field: LabField) -> String {
        switch field {
        case .bank: return bank ?? "—"
        case .amount: return amount.map { LabFormat.amount($0, currency) } ?? "—"
        case .type:
            guard isTransaction else { return "Not a transaction" }
            return type.flatMap(SMSTransactionType.init(rawValue:))?.title ?? "—"
        case .direction: return isTransaction ? (SMSDirection(rawValue: direction) ?? .none).title : "—"
        case .account: return account ?? "—"
        case .category: return category.flatMap(SpendCategory.init(rawValue:))?.title ?? category ?? "—"
        }
    }
}

enum LabFormat {
    static func amount(_ value: Double, _ currency: String?) -> String {
        let code = currency ?? "BHD"
        return "\(code) \(Money.number(value, decimals: Money.digits(code)))"
    }

    static func expected(_ field: LabField, _ e: LabExpected) -> String {
        switch field {
        case .bank: return e.bank ?? "—"
        case .amount: return e.amount.map { amount($0, nil) } ?? "—"
        case .type: return e.type.flatMap(SMSTransactionType.init(rawValue:))?.title ?? "—"
        case .direction: return e.direction.flatMap(SMSDirection.init(rawValue:))?.title ?? "—"
        case .account: return e.account ?? "—"
        case .category: return e.category.flatMap(SpendCategory.init(rawValue:))?.title ?? e.category ?? "—"
        }
    }

    static func percent(_ v: Double?) -> String {
        guard let v else { return "—" }
        return "\(Int((v * 100).rounded()))%"
    }
}

// MARK: - Expected vs Actual

struct LabFieldVerdict: Identifiable, Equatable {
    var id: LabField { field }
    var field: LabField
    var expected: String
    var actual: String
    var isCorrect: Bool
}

enum LabStatus: String {
    case notEvaluated, unlabeled, passed, failed
}

enum LabCompare {
    static func verdicts(expected e: LabExpected, snapshot s: LabSnapshot) -> [LabFieldVerdict] {
        if e.nonTransaction == true {
            return [LabFieldVerdict(field: .type, expected: "Not a transaction",
                                    actual: s.isTransaction ? s.display(.type) : "Not a transaction",
                                    isCorrect: !s.isTransaction)]
        }
        return e.labeledFields.map { field in
            LabFieldVerdict(field: field, expected: LabFormat.expected(field, e), actual: s.display(field),
                            isCorrect: s.isTransaction && matches(field, e, s))
        }
    }

    static func failingFields(expected: LabExpected, snapshot: LabSnapshot) -> Set<LabField> {
        Set(verdicts(expected: expected, snapshot: snapshot).filter { !$0.isCorrect }.map(\.field))
    }

    static func status(_ sample: LabSample, _ snapshot: LabSnapshot?) -> LabStatus {
        guard let snapshot else { return .notEvaluated }
        guard sample.expected.isLabeled else { return .unlabeled }
        return verdicts(expected: sample.expected, snapshot: snapshot).allSatisfy(\.isCorrect) ? .passed : .failed
    }

    static func passes(_ sample: LabSample, _ snapshot: LabSnapshot) -> Bool {
        status(sample, snapshot) == .passed
    }

    private static func matches(_ field: LabField, _ e: LabExpected, _ s: LabSnapshot) -> Bool {
        switch field {
        case .bank:
            guard let eb = e.bank, let ab = s.bank else { return false }
            return SMSKnowledge.sameBank(eb, ab)
        case .amount:
            guard let ea = e.amount, let aa = s.amount else { return false }
            return abs(ea - aa) < 0.0005
        case .type:
            return e.type == s.type
        case .direction:
            return e.direction == s.direction
        case .account:
            let ed = String((e.account ?? "").filter(\.isNumber).suffix(4))
            let ad = String((s.account ?? "").filter(\.isNumber).suffix(4))
            return !ed.isEmpty && ed == ad
        case .category:
            return e.category == s.category
        }
    }
}

// MARK: - Evaluator (production parser, sandboxed)

@MainActor
enum SMSLabEvaluator {
    /// Runs the production `SMSParser` against `knowledge` with no SwiftData context (no live accounts,
    /// no transaction history), optionally ignoring the device owner's personal SMS corrections.
    static func snapshot(text: String, sender: String?, knowledge: SMSCompiledKnowledge, includePersonalRules: Bool) -> LabSnapshot {
        SMSKnowledge.$evaluationOverride.withValue(knowledge) {
            SMSKnowledge.$excludePersonalRules.withValue(!includePersonalRules) {
                compute(text: text, sender: sender, knowledge: knowledge)
            }
        }
    }

    private static func compute(text: String, sender: String?, knowledge: SMSCompiledKnowledge) -> LabSnapshot {
        let cleanSender = sender?.trimmingCharacters(in: .whitespacesAndNewlines)
        let explicitSender = (cleanSender?.isEmpty == false) ? cleanSender : nil
        let normalized = SMSParser.normalizeText(text).trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveSender = SMSParser.extractSenderOrPhone(in: normalized, explicitSender: explicitSender)
        let bankInfo = SMSParser.identifyBank(in: normalized, sender: effectiveSender)
        var reasons: [LabReason] = []

        if let skip = SMSParser.nonTransactionReason(normalized) {
            reasons.append(LabReason(kind: "filter", text: skip))
            if let r = bankInfo.reason { reasons.append(LabReason(kind: "bank", text: r)) }
            return LabSnapshot(isTransaction: false, skipReason: skip, bank: bankInfo.bank,
                               bankConfidence: bankInfo.confidence.rawValue, reasoning: reasons,
                               engineLabel: knowledge.label)
        }

        guard let parsed = SMSParser.parse(normalized, sender: explicitSender, context: nil) else {
            let why = "Parser returned no transaction (no amount could be extracted)."
            reasons.append(LabReason(kind: "filter", text: why))
            if let r = bankInfo.reason { reasons.append(LabReason(kind: "bank", text: r)) }
            return LabSnapshot(isTransaction: false, skipReason: why, bank: bankInfo.bank,
                               bankConfidence: bankInfo.confidence.rawValue, reasoning: reasons,
                               engineLabel: knowledge.label)
        }

        reasons.append(LabReason(kind: "filter", text: "Recognised as a transaction SMS."))

        // Bank
        if parsed.matchedUserRule, parsed.detectedBank != bankInfo.bank, let b = parsed.detectedBank {
            reasons.append(LabReason(kind: "bank", text: "Bank \(b) supplied by a personal classification rule."))
        } else if let r = bankInfo.reason {
            reasons.append(LabReason(kind: "bank", text: r))
        } else {
            reasons.append(LabReason(kind: "bank", text: "No reliable bank evidence (IBAN code, bank name, helpline or sender) — bank left empty."))
        }

        // Knowledge rule
        let rule = parsed.knowledgeRuleID.flatMap { id in knowledge.pack.patterns.first { $0.id == id } }

        // Amount
        if let rule, rule.capturesAmount {
            reasons.append(LabReason(kind: "amount", text: "Amount \(LabFormat.amount(parsed.amount, parsed.currency)) captured by pattern '\(rule.name)'."))
        } else {
            reasons.append(LabReason(kind: "amount", text: "Amount \(LabFormat.amount(parsed.amount, parsed.currency)) extracted by the built-in amount reader (balance clauses excluded)."))
        }

        // Type
        let reasonText = parsed.classificationReason.isEmpty ? "No classification reason recorded." : parsed.classificationReason
        reasons.append(LabReason(kind: parsed.matchedUserRule ? "rule" : "type",
                                 text: "\(parsed.transactionType.title) (\(parsed.confidence.rawValue) confidence): \(reasonText)"))

        // Account
        if let a = parsed.accountSuffix {
            let via = (rule?.capturesAccount == true) ? " captured by pattern '\(rule?.name ?? "")'" : " from account/card wording"
            reasons.append(LabReason(kind: "account", text: "Source account ending \(a)\(via)."))
        } else if let r = parsed.recipientSuffix {
            reasons.append(LabReason(kind: "account", text: "No source account; recipient account ending \(r)."))
        } else {
            reasons.append(LabReason(kind: "account", text: "No account or card digits found."))
        }

        // Category
        reasons.append(LabReason(kind: "category", text: categoryReason(parsed, rule: rule, knowledge: knowledge)))

        if let rule {
            reasons.append(LabReason(kind: "knowledge", text: "Shaped by knowledge rule '\(rule.name)' (\(knowledge.label))."))
        }

        return LabSnapshot(
            isTransaction: true,
            bank: parsed.detectedBank,
            bankConfidence: parsed.bankConfidence.rawValue,
            amount: parsed.amount,
            currency: parsed.currency,
            type: parsed.transactionType.rawValue,
            direction: SMSDirection.from(parsed.transactionType).rawValue,
            account: parsed.accountSuffix,
            recipient: parsed.recipientSuffix,
            category: parsed.category.rawValue,
            merchant: parsed.merchant,
            confidence: parsed.confidence.rawValue,
            note: parsed.note,
            knowledgeRuleID: parsed.knowledgeRuleID,
            matchedPersonalRule: parsed.matchedUserRule,
            reasoning: reasons,
            engineLabel: knowledge.label
        )
    }

    private static func categoryReason(_ p: ParsedSMS, rule: SMSPatternRule?, knowledge: SMSCompiledKnowledge) -> String {
        let title = p.category.title
        if p.matchedUserRule { return "\(title) — from a personal classification rule." }
        if let rule, rule.category != nil { return "\(title) — set by knowledge rule '\(rule.name)'." }
        switch p.transactionType {
        case .internalTransfer: return "\(title) — internal transfers always use Internal Transfer."
        case .transferIn, .transferOut: return "\(title) — transfers are categorised as Transfers."
        case .fee: return "\(title) — bank fees are categorised as Bills."
        case .unknown: return "\(title) — type unknown, category left as Other."
        case .income:
            return "\(title) — incoming income."
        case .expense, .refund:
            let merchant = SMSParser.normalizeText(p.merchant).lowercased()
            if let k = knowledge.category(forText: merchant) {
                return "\(title) — published keyword '\(k.keyword)' found in merchant '\(p.merchant)'."
            }
            for (cat, words) in Categorizer.rules {
                if let w = words.first(where: { merchant.contains($0) }) {
                    return "\(cat.title) — built-in keyword '\(w)' found in merchant '\(p.merchant)'."
                }
            }
            if p.category == .other {
                return "Other — no category keyword matched merchant '\(p.merchant)'."
            }
            return "\(title) — keyword matched in the SMS text."
        }
    }
}
