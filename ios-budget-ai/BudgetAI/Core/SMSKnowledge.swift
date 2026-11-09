import Foundation

// MARK: - Published SMS Knowledge
//
// A versioned "knowledge pack" of curated bank formats, SMS patterns and classification rules.
// Packs are authored and regression-tested in the SMS Testing Lab, then published here.
// The production `SMSParser` reads the live pack on every parse, so publishing improves the
// real parser (Shortcuts automation, paste import, batch import) — not just the lab dashboard.
//
// Precedence inside the parser (highest first):
//   1. Built-in verified rules (e.g. BisB Fawri+ "credited to IBAN ending")
//   2. The user's own personal corrections (`SMSUserRules`)
//   3. Published knowledge (this file)
//   4. Built-in heuristics (`classifyTransaction`, keyword categorizer)

enum SMSRuleStatus: String, Codable, CaseIterable, Identifiable {
    case draft, approved, rejected
    var id: String { rawValue }
    var title: String {
        switch self {
        case .draft: "Draft"
        case .approved: "Approved"
        case .rejected: "Rejected"
        }
    }
}

/// Bank format: maps an SMS sender ID (e.g. "BBK", "NBB-ALERT", "17515151") to a bank.
struct SMSSenderBankRule: Codable, Equatable, Hashable, Identifiable {
    var id: String = UUID().uuidString
    var sender: String
    var bank: String
    var status: SMSRuleStatus = .draft
    var createdAt: Date = .now
    var note: String = ""
}

/// SMS pattern: a regular expression matched against the normalized, lower-cased, single-line SMS.
/// Optional named capture groups `(?<amount>...)` and `(?<account>...)` override amount / account extraction.
struct SMSPatternRule: Codable, Equatable, Hashable, Identifiable {
    var id: String = UUID().uuidString
    var name: String
    var pattern: String
    /// Only applies when the detected bank equals this value (case-insensitive). Empty / nil = any bank.
    var bankScope: String? = nil
    var setBank: String? = nil
    /// `SMSTransactionType` raw value.
    var setType: String? = nil
    /// `SpendCategory` raw value.
    var setCategory: String? = nil
    var setMerchant: String? = nil
    /// Marks matching messages as non-transactions (promotions, notices, OTP variants…).
    var skipAsNonTransaction: Bool = false
    /// Higher priority rules are evaluated first.
    var priority: Int = 0
    var status: SMSRuleStatus = .draft
    var createdAt: Date = .now
    var sourceCaseIDs: [String] = []
    var note: String = ""

    var capturesAmount: Bool { pattern.contains("(?<amount>") }
    var capturesAccount: Bool { pattern.contains("(?<account>") }

    var transactionType: SMSTransactionType? { setType.flatMap(SMSTransactionType.init(rawValue:)) }
    var category: SpendCategory? { setCategory.flatMap(SpendCategory.init(rawValue:)) }

    /// True when the rule changes classification / extraction (not only bank identification or skipping).
    var affectsClassification: Bool {
        !skipAsNonTransaction && (
            transactionType != nil || category != nil
                || (setMerchant?.isEmpty == false) || capturesAmount || capturesAccount
        )
    }

    var identifiesBank: Bool { !skipAsNonTransaction && setBank?.isEmpty == false }
}

/// Classification rule: merchant / text keyword → category.
struct SMSCategoryKeywordRule: Codable, Equatable, Hashable, Identifiable {
    var id: String = UUID().uuidString
    var keyword: String
    var category: String
    var status: SMSRuleStatus = .draft
    var createdAt: Date = .now
    var note: String = ""
}

struct SMSKnowledgePack: Codable, Equatable {
    var version: Int = 0
    var publishedAt: Date? = nil
    var notes: String = ""
    var senderBanks: [SMSSenderBankRule] = []
    var patterns: [SMSPatternRule] = []
    var categoryKeywords: [SMSCategoryKeywordRule] = []

    static let empty = SMSKnowledgePack()

    var ruleCount: Int { senderBanks.count + patterns.count + categoryKeywords.count }

    /// Copy containing only approved rules (what gets published).
    var approvedOnly: SMSKnowledgePack {
        var p = self
        p.senderBanks = senderBanks.filter { $0.status == .approved }
        p.patterns = patterns.filter { $0.status == .approved }
        p.categoryKeywords = categoryKeywords.filter { $0.status == .approved }
        return p
    }

    /// Stable fingerprint of the rule content (ignores version / notes / publish date).
    var contentFingerprint: String {
        var content = self
        content.version = 0
        content.publishedAt = nil
        content.notes = ""
        content.senderBanks.sort { $0.id < $1.id }
        content.patterns.sort { $0.id < $1.id }
        content.categoryKeywords.sort { $0.id < $1.id }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = (try? encoder.encode(content)) ?? Data()
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in data {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(hash, radix: 16)
    }
}

// MARK: - Compiled (ready-to-match) knowledge

struct SMSKnowledgeMatch {
    let rule: SMSPatternRule
    let amount: Double?
    let account: String?

    var type: SMSTransactionType? { rule.transactionType }
    var category: SpendCategory? { rule.category }
    var merchant: String? {
        guard let m = rule.setMerchant?.trimmingCharacters(in: .whitespacesAndNewlines), !m.isEmpty else { return nil }
        return m
    }
}

/// Immutable, pre-compiled form of a pack. Thread-safe (read-only after init).
final class SMSCompiledKnowledge: @unchecked Sendable {
    let pack: SMSKnowledgePack
    /// Human label used in parser reasoning, e.g. "v3" or "draft".
    let label: String
    private let senderMap: [String: String]
    private let patterns: [(rule: SMSPatternRule, regex: NSRegularExpression)]
    private let keywords: [(keyword: String, category: SpendCategory)]

    static let empty = SMSCompiledKnowledge(pack: .empty, label: "built-in")

    init(pack: SMSKnowledgePack, label: String? = nil, includeDrafts: Bool = false) {
        self.pack = pack
        self.label = label ?? (pack.version > 0 ? "v\(pack.version)" : "built-in")
        let allowed: (SMSRuleStatus) -> Bool = { includeDrafts ? $0 != .rejected : $0 == .approved }

        var map: [String: String] = [:]
        for rule in pack.senderBanks where allowed(rule.status) {
            let key = SMSUserRules.normalizeSender(rule.sender)
            let bank = rule.bank.trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty, !bank.isEmpty { map[key] = bank }
        }
        senderMap = map

        patterns = pack.patterns
            .filter { allowed($0.status) }
            .sorted { $0.priority != $1.priority ? $0.priority > $1.priority : $0.createdAt < $1.createdAt }
            .compactMap { rule in
                guard let regex = try? NSRegularExpression(pattern: rule.pattern, options: [.caseInsensitive]) else { return nil }
                return (rule, regex)
            }

        keywords = pack.categoryKeywords
            .filter { allowed($0.status) }
            .compactMap { rule in
                let k = SMSParser.normalizeText(rule.keyword).lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                guard k.count >= 2, let cat = SpendCategory(rawValue: rule.category) else { return nil }
                return (k, cat)
            }
            .sorted { $0.keyword.count > $1.keyword.count }
    }

    var isEmpty: Bool { senderMap.isEmpty && patterns.isEmpty && keywords.isEmpty }

    /// First pattern (by priority) matching `text` (already passed through `SMSKnowledge.matchText`).
    func firstMatch(in text: String, bank: String?, where predicate: (SMSPatternRule) -> Bool) -> SMSKnowledgeMatch? {
        guard !patterns.isEmpty else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        for (rule, regex) in patterns where predicate(rule) {
            if let scope = rule.bankScope?.trimmingCharacters(in: .whitespacesAndNewlines), !scope.isEmpty {
                guard let bank, SMSKnowledge.sameBank(bank, scope) else { continue }
            }
            guard let m = regex.firstMatch(in: text, range: range) else { continue }
            var amount: Double? = nil
            var account: String? = nil
            if rule.capturesAmount {
                let r = m.range(withName: "amount")
                if r.location != NSNotFound, let rr = Range(r, in: text), let v = Money.parse(String(text[rr])), v > 0 {
                    amount = v
                }
            }
            if rule.capturesAccount {
                let r = m.range(withName: "account")
                if r.location != NSNotFound, let rr = Range(r, in: text) {
                    let digits = String(text[rr].filter(\.isNumber))
                    if digits.count >= 3 { account = String(digits.suffix(4)) }
                }
            }
            return SMSKnowledgeMatch(rule: rule, amount: amount, account: account)
        }
        return nil
    }

    /// All pattern rules that match `text` (used by the lab for reasoning / impact analysis).
    func matchingRuleIDs(in text: String) -> [String] {
        let range = NSRange(text.startIndex..., in: text)
        return patterns.filter { $0.regex.firstMatch(in: text, range: range) != nil }.map(\.rule.id)
    }

    func bank(forSender sender: String?) -> String? {
        guard let sender, !senderMap.isEmpty else { return nil }
        let key = SMSUserRules.normalizeSender(sender)
        guard !key.isEmpty else { return nil }
        if let exact = senderMap[key] { return exact }
        let digits = SMSUserRules.normalizePhoneDigits(key)
        if digits.count >= 6 {
            for (saved, bank) in senderMap where SMSUserRules.normalizePhoneDigits(saved) == digits {
                return bank
            }
        }
        return nil
    }

    /// Published keyword → category (longest keyword wins).
    func category(forText lowerText: String) -> (keyword: String, category: SpendCategory)? {
        guard !keywords.isEmpty else { return nil }
        return keywords.first { lowerText.contains($0.keyword) }
    }
}

// MARK: - Active knowledge resolution

enum SMSKnowledge {
    /// Lab-only: evaluate the production parser against a candidate pack without publishing it.
    @TaskLocal static var evaluationOverride: SMSCompiledKnowledge? = nil
    /// Lab-only: ignore the device owner's personal SMS corrections so test results are reproducible.
    @TaskLocal static var excludePersonalRules: Bool = false

    /// Knowledge used by `SMSParser` right now.
    static var active: SMSCompiledKnowledge {
        evaluationOverride ?? SMSKnowledgeStore.liveCompiled
    }

    /// Canonical text the pattern rules are matched against: normalized digits, lower-cased, single line, single spaces.
    static func matchText(_ raw: String) -> String {
        SMSParser.normalizeText(raw)
            .lowercased()
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func sameBank(_ a: String, _ b: String) -> Bool {
        func key(_ s: String) -> String {
            s.lowercased().replacingOccurrences(of: "[^a-z0-9\\u0600-\\u06FF]", with: "", options: .regularExpression)
        }
        let ka = key(a), kb = key(b)
        return !ka.isEmpty && ka == kb
    }
}

// MARK: - Versioned store (publish / history / rollback)

struct SMSKnowledgeVersionEntry: Codable, Equatable, Identifiable {
    enum Action: String, Codable { case publish, rollback }
    var id: Int { version }
    var version: Int
    var publishedAt: Date
    var action: Action
    var notes: String
    /// For rollbacks: the version whose content was restored.
    var restoredFrom: Int?
    var senderCount: Int
    var patternCount: Int
    var keywordCount: Int
    var regressionPassed: Int?
    var regressionTotal: Int?
    var fingerprint: String
}

enum SMSKnowledgeError: LocalizedError {
    case versionNotFound(Int)
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .versionNotFound(let v): "Knowledge version v\(v) was not found."
        case .writeFailed(let m): "Could not save knowledge: \(m)"
        }
    }
}

enum SMSKnowledgeStore {
    /// Tests can point the store at a temporary directory.
    nonisolated(unsafe) static var baseDirectoryOverride: URL? = nil

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cachedLive: SMSCompiledKnowledge?

    static var directory: URL {
        if let baseDirectoryOverride { return baseDirectoryOverride }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("BudgetAIKnowledge", isDirectory: true)
    }

    private static var liveURL: URL { directory.appendingPathComponent("live.json") }
    private static var historyURL: URL { directory.appendingPathComponent("history.json") }
    private static func versionURL(_ v: Int) -> URL { directory.appendingPathComponent("v\(v).json") }

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    // MARK: Reading

    static var livePack: SMSKnowledgePack { liveCompiled.pack }

    static var liveCompiled: SMSCompiledKnowledge {
        lock.lock()
        defer { lock.unlock() }
        if let cachedLive { return cachedLive }
        let pack = (try? Data(contentsOf: liveURL)).flatMap { try? decoder.decode(SMSKnowledgePack.self, from: $0) } ?? .empty
        let compiled = SMSCompiledKnowledge(pack: pack)
        cachedLive = compiled
        return compiled
    }

    static func history() -> [SMSKnowledgeVersionEntry] {
        guard let data = try? Data(contentsOf: historyURL),
              let list = try? decoder.decode([SMSKnowledgeVersionEntry].self, from: data) else { return [] }
        return list.sorted { $0.version > $1.version }
    }

    static func pack(version: Int) -> SMSKnowledgePack? {
        if version == 0 { return .empty }
        guard let data = try? Data(contentsOf: versionURL(version)) else { return nil }
        return try? decoder.decode(SMSKnowledgePack.self, from: data)
    }

    // MARK: Writing

    /// Publishes the approved rules of `pack` as a new live version.
    @discardableResult
    static func publish(_ pack: SMSKnowledgePack, notes: String, regressionPassed: Int? = nil, regressionTotal: Int? = nil) throws -> SMSKnowledgeVersionEntry {
        try write(pack.approvedOnly, action: .publish, notes: notes, restoredFrom: nil,
                  regressionPassed: regressionPassed, regressionTotal: regressionTotal)
    }

    /// Restores the content of an earlier version as a new live version (history is never rewritten).
    @discardableResult
    static func rollback(to version: Int, notes: String = "") throws -> SMSKnowledgeVersionEntry {
        guard let old = pack(version: version) else { throw SMSKnowledgeError.versionNotFound(version) }
        let text = notes.isEmpty ? "Rollback to v\(version)" : notes
        return try write(old, action: .rollback, notes: text, restoredFrom: version, regressionPassed: nil, regressionTotal: nil)
    }

    private static func write(
        _ content: SMSKnowledgePack,
        action: SMSKnowledgeVersionEntry.Action,
        notes: String,
        restoredFrom: Int?,
        regressionPassed: Int?,
        regressionTotal: Int?
    ) throws -> SMSKnowledgeVersionEntry {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            var list = history()
            let next = (list.map(\.version).max() ?? 0) + 1
            var pack = content
            pack.version = next
            pack.publishedAt = .now
            pack.notes = notes
            let data = try encoder.encode(pack)
            try data.write(to: versionURL(next), options: .atomic)
            try data.write(to: liveURL, options: .atomic)

            let entry = SMSKnowledgeVersionEntry(
                version: next,
                publishedAt: pack.publishedAt ?? .now,
                action: action,
                notes: notes,
                restoredFrom: restoredFrom,
                senderCount: pack.senderBanks.count,
                patternCount: pack.patterns.count,
                keywordCount: pack.categoryKeywords.count,
                regressionPassed: regressionPassed,
                regressionTotal: regressionTotal,
                fingerprint: pack.contentFingerprint
            )
            list.append(entry)
            try encoder.encode(list).write(to: historyURL, options: .atomic)
            invalidateCache()
            return entry
        } catch {
            throw SMSKnowledgeError.writeFailed(error.localizedDescription)
        }
    }

    static func exportURL(for version: Int? = nil) throws -> URL {
        let exportPack = version.flatMap { pack(version: $0) } ?? livePack
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("BudgetAI-SMS-Knowledge-v\(exportPack.version).json")
        try encoder.encode(exportPack).write(to: url, options: .atomic)
        return url
    }

    static func decodePack(from data: Data) throws -> SMSKnowledgePack {
        try decoder.decode(SMSKnowledgePack.self, from: data)
    }

    static func invalidateCache() {
        lock.lock()
        cachedLive = nil
        lock.unlock()
    }

    /// Test-only helper: deletes all published knowledge in the current directory.
    static func resetAll() {
        try? FileManager.default.removeItem(at: directory)
        invalidateCache()
    }
}
