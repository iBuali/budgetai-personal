import Foundation

// MARK: - SMS Testing Lab · Statistics, pattern detection & rule generation

struct LabBankStat: Identifiable {
    var id: String { bank }
    var bank: String
    var total = 0
    var labeled = 0
    var passed = 0
    var failed = 0
    var accuracy: Double? { labeled > 0 ? Double(passed) / Double(labeled) : nil }
}

struct LabTypeStat: Identifiable {
    var id: String { type }
    var type: String
    var total = 0
    var labeled = 0
    var failed = 0
    var title: String { SMSTransactionType(rawValue: type)?.title ?? (type == "skip" ? "Not a transaction" : type) }
}

struct LabFieldStat: Identifiable {
    var id: LabField { field }
    var field: LabField
    var correct = 0
    var total = 0
    var accuracy: Double? { total > 0 ? Double(correct) / Double(total) : nil }
}

struct LabStats {
    var total = 0
    var evaluated = 0
    var transactions = 0
    var skipped = 0
    var labeled = 0
    var passed = 0
    var failed = 0
    var testCases = 0
    var improvements = 0
    var byBank: [LabBankStat] = []
    var byType: [LabTypeStat] = []
    var fields: [LabFieldStat] = []
    var coveredBanks: [String] = []
    var catalogBanks: [String] = BahrainBankCatalog.bahrainBanks

    var accuracy: Double? { labeled > 0 ? Double(passed) / Double(labeled) : nil }
    var coverage: Double { catalogBanks.isEmpty ? 0 : Double(coveredBanks.count) / Double(catalogBanks.count) }

    static func compute(samples: [LabSample], results: [UUID: LabSnapshot]) -> LabStats {
        var s = LabStats()
        s.total = samples.count
        var banks: [String: LabBankStat] = [:]
        var types: [String: LabTypeStat] = [:]
        var fields: [LabField: LabFieldStat] = [:]
        var detected = Set<String>()

        for sample in samples {
            if sample.isTestCase { s.testCases += 1 }
            guard let snap = results[sample.id] else { continue }
            s.evaluated += 1
            if snap.isTransaction { s.transactions += 1 } else { s.skipped += 1 }
            if let b = snap.bank, snap.isTransaction { detected.insert(b.lowercased()) }

            let status = LabCompare.status(sample, snap)
            let bankKey = sample.expected.bank ?? snap.bank ?? "Unknown"
            let typeKey = sample.expected.nonTransaction == true ? "skip" : (sample.expected.type ?? (snap.isTransaction ? (snap.type ?? "unknown") : "skip"))
            var bs = banks[bankKey] ?? LabBankStat(bank: bankKey)
            var ts = types[typeKey] ?? LabTypeStat(type: typeKey)
            bs.total += 1
            ts.total += 1

            if status == .passed || status == .failed {
                s.labeled += 1
                bs.labeled += 1
                ts.labeled += 1
                if status == .passed {
                    s.passed += 1
                    bs.passed += 1
                    if sample.baselinePassed == false { s.improvements += 1 }
                } else {
                    s.failed += 1
                    bs.failed += 1
                    ts.failed += 1
                }
                for v in LabCompare.verdicts(expected: sample.expected, snapshot: snap) {
                    var fs = fields[v.field] ?? LabFieldStat(field: v.field)
                    fs.total += 1
                    if v.isCorrect { fs.correct += 1 }
                    fields[v.field] = fs
                }
            }
            banks[bankKey] = bs
            types[typeKey] = ts
        }

        s.byBank = banks.values.sorted { $0.total > $1.total }
        s.byType = types.values.sorted { $0.total > $1.total }
        s.fields = LabField.allCases.compactMap { fields[$0] }
        s.coveredBanks = s.catalogBanks.filter { detected.contains($0.lowercased()) }
        return s
    }
}

// MARK: - Recurring mistakes

struct LabMistakeCluster: Identifiable {
    var id: String
    var bank: String
    var field: LabField
    var expected: String
    var actual: String
    var sampleIDs: [UUID]
    var formats: Int
}

enum LabMistakes {
    static func template(_ text: String) -> String {
        SMSKnowledge.matchText(text).replacingOccurrences(of: "[0-9]+(?:[.,][0-9]+)*", with: "#", options: .regularExpression)
    }

    static func clusters(samples: [LabSample], results: [UUID: LabSnapshot]) -> [LabMistakeCluster] {
        var groups: [String: (bank: String, field: LabField, expected: String, actual: String, ids: [UUID], templates: Set<String>)] = [:]
        for sample in samples where sample.expected.isLabeled {
            guard let snap = results[sample.id] else { continue }
            let bank = sample.expected.bank ?? snap.bank ?? "Unknown"
            for v in LabCompare.verdicts(expected: sample.expected, snapshot: snap) where !v.isCorrect {
                let actual = v.field == .amount || v.field == .account ? (snap.isTransaction ? "wrong value" : "not parsed") : v.actual
                let expected = v.field == .amount || v.field == .account ? "correct value" : v.expected
                let key = "\(bank.lowercased())|\(v.field.rawValue)|\(expected)|\(actual)"
                var g = groups[key] ?? (bank, v.field, expected, actual, [], [])
                g.ids.append(sample.id)
                g.templates.insert(template(sample.text))
                groups[key] = g
            }
        }
        return groups.map { key, g in
            LabMistakeCluster(id: key, bank: g.bank, field: g.field, expected: g.expected, actual: g.actual,
                              sampleIDs: g.ids, formats: g.templates.count)
        }
        .sorted { $0.sampleIDs.count != $1.sampleIDs.count ? $0.sampleIDs.count > $1.sampleIDs.count : $0.id < $1.id }
    }
}

// MARK: - Rule generation from approved corrections

struct LabRuleProposal {
    var senderBanks: [SMSSenderBankRule] = []
    var patterns: [SMSPatternRule] = []
    var keywords: [SMSCategoryKeywordRule] = []
    var notes: [String] = []
    var count: Int { senderBanks.count + patterns.count + keywords.count }
}

enum SMSRuleGenerator {
    static let numPattern = "[0-9]+(?:[.,][0-9]+)*"
    private static let numberRun = try! NSRegularExpression(pattern: "[0-9]+(?:[.,][0-9]+)*")
    private static let wildcard = "\\S+"
    private static let genericMerchants = ["iban ending", "transfer", "unknown", "payment", "purchase", "bank fee", "fawri", "salary", "card", "account", "own account"]

    /// Generates draft rules from approved test cases that the current engine still gets wrong.
    /// Approved test cases are only read — never modified.
    static func generate(samples: [LabSample], results: [UUID: LabSnapshot], existing: SMSKnowledgePack) -> LabRuleProposal {
        var proposal = LabRuleProposal()
        let approved = samples.filter { $0.isTestCase && $0.expected.isLabeled }

        struct Failure { var sample: LabSample; var snap: LabSnapshot; var failing: Set<LabField> }
        let failures: [Failure] = approved.compactMap { s in
            guard let snap = results[s.id], s.expected.nonTransaction != true else { return nil }
            let f = LabCompare.failingFields(expected: s.expected, snapshot: snap)
            return f.isEmpty ? nil : Failure(sample: s, snap: snap, failing: f)
        }
        guard !failures.isEmpty else {
            proposal.notes.append("All approved test cases pass — nothing to learn.")
            return proposal
        }

        // 1. Bank formats from sender IDs
        var senderVotes: [String: (sender: String, banks: Set<String>, ids: [String])] = [:]
        for f in failures where f.failing.contains(.bank) {
            guard let sender = f.sample.sender?.trimmingCharacters(in: .whitespacesAndNewlines), !sender.isEmpty,
                  let bank = f.sample.expected.bank else { continue }
            let key = SMSUserRules.normalizeSender(sender)
            var v = senderVotes[key] ?? (sender, [], [])
            v.banks.insert(bank)
            v.ids.append(f.sample.id.uuidString)
            senderVotes[key] = v
        }
        var handledBankBySender = Set<UUID>()
        for (key, vote) in senderVotes {
            // Consistency: every approved case from this sender must agree on the bank.
            let allBanks = Set(approved.filter { SMSUserRules.normalizeSender($0.sender ?? "") == key }.compactMap(\.expected.bank))
            guard vote.banks.count == 1, allBanks.count == 1, let bank = vote.banks.first else {
                proposal.notes.append("Sender '\(vote.sender)' maps to several banks in approved cases — no sender rule generated.")
                continue
            }
            if existing.senderBanks.contains(where: { SMSUserRules.normalizeSender($0.sender) == key && $0.status != .rejected }) { continue }
            proposal.senderBanks.append(SMSSenderBankRule(sender: vote.sender, bank: bank, status: .draft,
                                                          note: "Learned from \(vote.ids.count) approved case(s)"))
            for f in failures where SMSUserRules.normalizeSender(f.sample.sender ?? "") == key { handledBankBySender.insert(f.sample.id) }
        }

        // 2. Category keywords from merchants
        var keywordVotes: [String: (category: String, ids: [String])] = [:]
        var handledCategory = Set<UUID>()
        for f in failures where f.failing.contains(.category) {
            guard let cat = f.sample.expected.category,
                  let type = f.snap.type.flatMap(SMSTransactionType.init(rawValue:)), type == .expense || type == .refund,
                  !f.failing.contains(.type) else { continue }
            let keyword = SMSParser.normalizeText(f.snap.merchant ?? "").lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            guard keyword.count >= 3, !genericMerchants.contains(where: { keyword.hasPrefix($0) }) else { continue }
            if let v = keywordVotes[keyword], v.category != cat {
                keywordVotes[keyword] = nil
                continue
            }
            var v = keywordVotes[keyword] ?? (cat, [])
            v.ids.append(f.sample.id.uuidString)
            keywordVotes[keyword] = v
            handledCategory.insert(f.sample.id)
        }
        for (keyword, vote) in keywordVotes {
            let conflicts = approved.contains { s in
                guard let c = s.expected.category, c != vote.category else { return false }
                return SMSKnowledge.matchText(s.text).contains(keyword)
            }
            if conflicts {
                proposal.notes.append("Keyword '\(keyword)' appears in approved cases with different categories — skipped.")
                for f in failures where SMSParser.normalizeText(f.snap.merchant ?? "").lowercased().trimmingCharacters(in: .whitespacesAndNewlines) == keyword {
                    handledCategory.remove(f.sample.id)
                }
                continue
            }
            if existing.categoryKeywords.contains(where: { $0.keyword.lowercased() == keyword && $0.status != .rejected }) { continue }
            proposal.keywords.append(SMSCategoryKeywordRule(keyword: keyword, category: vote.category, status: .draft,
                                                            note: "Learned from \(vote.ids.count) approved case(s)"))
        }

        // 3. SMS patterns for everything else
        struct Spec: Hashable {
            var setBank: String?
            var setType: String?
            var setCategory: String?
            var bankScope: String?
            var amount: Bool
            var account: Bool
        }
        var groups: [Spec: [Failure]] = [:]
        for f in failures {
            var remaining = f.failing
            if handledBankBySender.contains(f.sample.id) { remaining.remove(.bank) }
            if handledCategory.contains(f.sample.id) { remaining.remove(.category) }
            guard !remaining.isEmpty else { continue }
            let e = f.sample.expected
            let wantsType = remaining.contains(.type) || remaining.contains(.direction)
            if wantsType && e.type == nil {
                proposal.notes.append("A case expects direction \(LabFormat.expected(.direction, e)) without a transaction type — set the type to generate a rule.")
            }
            let spec = Spec(
                setBank: remaining.contains(.bank) ? e.bank : nil,
                setType: wantsType ? e.type : nil,
                setCategory: remaining.contains(.category) ? e.category : nil,
                bankScope: (!remaining.contains(.bank) && !f.failing.contains(.bank)) ? f.snap.bank : nil,
                amount: remaining.contains(.amount) && e.amount != nil,
                account: remaining.contains(.account) && !(e.account ?? "").isEmpty
            )
            guard spec.setBank != nil || spec.setType != nil || spec.setCategory != nil || spec.amount || spec.account else { continue }
            groups[spec, default: []].append(f)
        }

        for (spec, members) in groups {
            var clusters: [(tokens: [String], members: [Failure])] = []
            for m in members {
                let tokens = tokenPatterns(text: m.sample.text,
                                           amount: spec.amount ? m.sample.expected.amount : nil,
                                           account: spec.account ? m.sample.expected.account : nil)
                if let i = clusters.firstIndex(where: { merge($0.tokens, tokens) != nil }), let merged = merge(clusters[i].tokens, tokens) {
                    clusters[i].tokens = merged
                    clusters[i].members.append(m)
                } else {
                    clusters.append((tokens, [m]))
                }
            }

            var finalClusters: [(tokens: [String], members: [Failure])] = []
            for c in clusters {
                if validate(c.tokens, members: c.members.map(\.sample), spec.amount, spec.account) {
                    finalClusters.append(c)
                } else if c.members.count > 1 {
                    for m in c.members {
                        let t = tokenPatterns(text: m.sample.text, amount: spec.amount ? m.sample.expected.amount : nil,
                                              account: spec.account ? m.sample.expected.account : nil)
                        if validate(t, members: [m.sample], spec.amount, spec.account) { finalClusters.append((t, [m])) }
                    }
                }
            }

            for c in finalClusters {
                let literalCount = c.tokens.filter { $0 != wildcard && $0 != numPattern && !$0.contains("(?<") }.count
                guard literalCount >= 3 else {
                    proposal.notes.append("A format was too generic to turn into a safe pattern (fewer than 3 fixed words).")
                    continue
                }
                let pattern = c.tokens.joined(separator: "\\s+")
                if existing.patterns.contains(where: { $0.pattern == pattern && $0.status != .rejected })
                    || proposal.patterns.contains(where: { $0.pattern == pattern }) { continue }
                let bankLabel = spec.setBank ?? spec.bankScope ?? c.members.first?.sample.expected.bank ?? "Any bank"
                var effect: [String] = []
                if let t = spec.setType.flatMap(SMSTransactionType.init(rawValue:)) { effect.append(t.title) }
                if let cat = spec.setCategory.flatMap(SpendCategory.init(rawValue:)) { effect.append(cat.title) }
                if spec.setBank != nil { effect.append("bank") }
                if spec.amount { effect.append("amount") }
                if spec.account { effect.append("account") }
                proposal.patterns.append(SMSPatternRule(
                    name: "\(bankLabel) · \(effect.joined(separator: ", ")) · \(c.members.count) case\(c.members.count == 1 ? "" : "s")",
                    pattern: pattern,
                    bankScope: spec.bankScope,
                    setBank: spec.setBank,
                    setType: spec.setType,
                    setCategory: spec.setCategory,
                    priority: 10,
                    status: .draft,
                    sourceCaseIDs: c.members.map(\.sample.id.uuidString),
                    note: "Generated from approved corrections"
                ))
            }
        }

        if proposal.count == 0 && proposal.notes.isEmpty {
            proposal.notes.append("No new rules could be generated from the current failures.")
        }
        return proposal
    }

    // MARK: Tokenisation

    /// Converts an SMS into per-token regex fragments. Numbers become generic number patterns,
    /// reference-like tokens become wildcards, and the expected amount / account become named captures.
    static func tokenPatterns(text: String, amount: Double?, account: String?) -> [String] {
        let tokens = SMSKnowledge.matchText(text).split(separator: " ").map(String.init)
        let accountDigits = String((account ?? "").filter(\.isNumber).suffix(4))

        // Locate capture targets: prefer decimal runs for the amount.
        var runs: [(token: Int, location: Int, value: String)] = []
        for (i, token) in tokens.enumerated() {
            let ns = token as NSString
            for m in numberRun.matches(in: token, range: NSRange(location: 0, length: ns.length)) {
                runs.append((i, m.range.location, ns.substring(with: m.range)))
            }
        }
        func equalsAmount(_ v: String) -> Bool {
            guard let amount, let x = Money.parse(v) else { return false }
            return abs(x - amount) < 0.0005
        }
        let amountTarget = runs.first { $0.value.contains(".") && equalsAmount($0.value) } ?? runs.first { equalsAmount($0.value) }
        let accountTarget: (token: Int, location: Int, value: String)? = accountDigits.count >= 3
            ? runs.first { r in
                let d = r.value.filter(\.isNumber)
                return !r.value.contains(".") && d.count >= accountDigits.count && d.hasSuffix(accountDigits)
            }
            : nil

        return tokens.enumerated().map { i, token in
            let ns = token as NSString
            let matches = numberRun.matches(in: token, range: NSRange(location: 0, length: ns.length))
            if matches.isEmpty { return NSRegularExpression.escapedPattern(for: token) }
            var out = ""
            var cursor = 0
            var captured = false
            for m in matches {
                if m.range.location > cursor {
                    out += NSRegularExpression.escapedPattern(for: ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor)))
                }
                if let a = accountTarget, a.token == i, a.location == m.range.location {
                    out += "(?<account>[0-9]+)"
                    captured = true
                } else if let a = amountTarget, a.token == i, a.location == m.range.location {
                    out += "(?<amount>\(numPattern))"
                    captured = true
                } else {
                    out += numPattern
                }
                cursor = m.range.location + m.range.length
            }
            if cursor < ns.length { out += NSRegularExpression.escapedPattern(for: ns.substring(from: cursor)) }
            if !captured && isReferenceLike(token) { return wildcard }
            return out
        }
    }

    private static func isReferenceLike(_ token: String) -> Bool {
        guard token.count >= 6, !token.contains("."), !token.contains(",") else { return false }
        let digits = token.filter(\.isNumber).count
        let letters = token.filter(\.isLetter).count
        return digits >= 3 && letters >= 1
    }

    static func merge(_ a: [String], _ b: [String]) -> [String]? {
        guard a.count == b.count, !a.isEmpty else { return nil }
        let same = zip(a, b).filter { $0 == $1 }.count
        guard Double(same) / Double(a.count) >= 0.6 else { return nil }
        let merged: [String] = zip(a, b).map { x, y in
            if x == y { return x }
            let xc = x.contains("(?<"), yc = y.contains("(?<")
            if xc && !yc { return x }
            if yc && !xc { return y }
            return wildcard
        }
        let joined = merged.joined()
        if joined.components(separatedBy: "(?<amount>").count > 2 || joined.components(separatedBy: "(?<account>").count > 2 { return nil }
        return merged
    }

    private static func validate(_ tokens: [String], members: [LabSample], _ amount: Bool, _ account: Bool) -> Bool {
        let pattern = tokens.joined(separator: "\\s+")
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return false }
        if amount && !pattern.contains("(?<amount>") { return false }
        if account && !pattern.contains("(?<account>") { return false }
        for s in members {
            let text = SMSKnowledge.matchText(s.text)
            guard let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return false }
            if amount {
                let r = m.range(withName: "amount")
                guard r.location != NSNotFound, let rr = Range(r, in: text), let v = Money.parse(String(text[rr])),
                      let e = s.expected.amount, abs(v - e) < 0.0005 else { return false }
            }
            if account {
                let r = m.range(withName: "account")
                guard r.location != NSNotFound, let rr = Range(r, in: text) else { return false }
                let got = String(text[rr].filter(\.isNumber).suffix(4))
                let want = String((s.expected.account ?? "").filter(\.isNumber).suffix(4))
                if got != want { return false }
            }
        }
        return true
    }
}

// MARK: - Knowledge diff (unpublished changes)

struct LabKnowledgeChange: Identifiable {
    enum Kind: String { case added = "Added", modified = "Modified", removed = "Removed" }
    var id: String
    var kind: Kind
    var area: String
    var title: String
}

enum LabKnowledgeDiff {
    static func describe(_ r: SMSSenderBankRule) -> String { "Sender \(r.sender) → \(r.bank)" }
    static func describe(_ r: SMSCategoryKeywordRule) -> String {
        "'\(r.keyword)' → \(SpendCategory(rawValue: r.category)?.title ?? r.category)"
    }
    static func describe(_ r: SMSPatternRule) -> String { r.name }

    static func changes(live: SMSKnowledgePack, candidate: SMSKnowledgePack) -> [LabKnowledgeChange] {
        var out: [LabKnowledgeChange] = []
        func diff<T: Identifiable & Equatable>(_ old: [T], _ new: [T], area: String, title: (T) -> String) where T.ID == String {
            let oldMap = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let newMap = Dictionary(new.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            for n in new {
                if let o = oldMap[n.id] {
                    if o != n { out.append(LabKnowledgeChange(id: "m-\(n.id)", kind: .modified, area: area, title: title(n))) }
                } else {
                    out.append(LabKnowledgeChange(id: "a-\(n.id)", kind: .added, area: area, title: title(n)))
                }
            }
            for o in old where newMap[o.id] == nil {
                out.append(LabKnowledgeChange(id: "r-\(o.id)", kind: .removed, area: area, title: title(o)))
            }
        }
        diff(live.senderBanks, candidate.senderBanks, area: "Bank format", title: describe)
        diff(live.patterns, candidate.patterns, area: "SMS pattern", title: describe)
        diff(live.categoryKeywords, candidate.categoryKeywords, area: "Classification", title: describe)
        return out
    }
}
