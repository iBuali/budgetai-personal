import Foundation
import Observation

// MARK: - SMS Testing Lab · Regression Report & Isolated Lab Store

struct LabCaseRegression: Identifiable, Equatable {
    var id: UUID { sample.id }
    var sample: LabSample
    var liveSnapshot: LabSnapshot
    var candidateSnapshot: LabSnapshot
    var livePassed: Bool
    var candidatePassed: Bool
    var failingFields: [LabFieldVerdict]

    var isRegression: Bool { livePassed && !candidatePassed }
    var isNewlyFixed: Bool { !livePassed && candidatePassed }
}

struct LabRegressionReport: Equatable {
    var ranAt: Date = .now
    var totalApprovedCases: Int = 0
    var livePassed: Int = 0
    var candidatePassed: Int = 0
    var regressions: [LabCaseRegression] = []
    var newlyFixed: [LabCaseRegression] = []
    var stillFailing: [LabCaseRegression] = []

    var allPassed: Bool { candidatePassed == totalApprovedCases }
    var isSafeToPublish: Bool { regressions.isEmpty }
}

/// Observable store for the SMS Testing Lab.
/// All lab samples and candidate rules are persisted in `Application Support/SMSLab` — completely separate
/// from SwiftData and live financial transactions.
@Observable
@MainActor
final class SMSLabStore {
    static let shared = SMSLabStore()

    nonisolated(unsafe) static var baseDirectoryOverride: URL? = nil

    private(set) var samples: [LabSample] = []
    /// Latest evaluation snapshot per sample ID (using `workingKnowledge`).
    private(set) var results: [UUID: LabSnapshot] = [:]
    /// Working knowledge pack in the lab (contains both `draft` and `approved` rules).
    private(set) var workingPack: SMSKnowledgePack = .empty
    /// Whether lab evaluation includes the candidate working rules (approved + draft) vs only published live rules.
    var evaluateWithDrafts: Bool = true {
        didSet { evaluateAllAndRunRegression() }
    }
    /// Whether lab evaluation includes the user's personal `SMSUserRules` or runs clean.
    var includePersonalRules: Bool = false {
        didSet { evaluateAllAndRunRegression() }
    }
    private(set) var regressionReport: LabRegressionReport = LabRegressionReport()
    private(set) var lastLearningNotes: [String] = []
    private(set) var versionHistory: [SMSKnowledgeVersionEntry] = []

    init(loadFromDisk: Bool = true) {
        if loadFromDisk {
            reloadFromDisk()
        }
    }

    // MARK: Persistence Paths

    static var directory: URL {
        if let baseDirectoryOverride { return baseDirectoryOverride }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("BudgetAISMSLab", isDirectory: true)
    }

    private var samplesURL: URL { Self.directory.appendingPathComponent("samples.json") }
    private var workingPackURL: URL { Self.directory.appendingPathComponent("working_pack.json") }

    private var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    private var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    func reloadFromDisk() {
        let loadedSamples = (try? Data(contentsOf: samplesURL)).flatMap { try? decoder.decode([LabSample].self, from: $0) } ?? []
        let live = SMSKnowledgeStore.livePack
        let loadedWorking = (try? Data(contentsOf: workingPackURL)).flatMap { try? decoder.decode(SMSKnowledgePack.self, from: $0) }
        samples = loadedSamples
        workingPack = loadedWorking ?? live
        versionHistory = SMSKnowledgeStore.history()
        evaluateAllAndRunRegression()
    }

    private func saveSamples() {
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        if let data = try? encoder.encode(samples) {
            try? data.write(to: samplesURL, options: .atomic)
        }
    }

    private func saveWorkingPack() {
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        if let data = try? encoder.encode(workingPack) {
            try? data.write(to: workingPackURL, options: .atomic)
        }
    }

    // MARK: Computed Dashboard & Diff Metrics

    var stats: LabStats {
        LabStats.compute(samples: samples, results: results)
    }

    var mistakeClusters: [LabMistakeCluster] {
        LabMistakes.clusters(samples: samples, results: results)
    }

    var livePack: SMSKnowledgePack {
        SMSKnowledgeStore.livePack
    }

    /// Unpublished changes between the live published knowledge and the approved rules in `workingPack`.
    var unpublishedChanges: [LabKnowledgeChange] {
        LabKnowledgeDiff.changes(live: livePack, candidate: workingPack.approvedOnly)
    }

    var draftRulesCount: Int {
        workingPack.senderBanks.filter { $0.status == .draft }.count
            + workingPack.patterns.filter { $0.status == .draft }.count
            + workingPack.categoryKeywords.filter { $0.status == .draft }.count
    }

    var approvedRulesCount: Int {
        workingPack.approvedOnly.ruleCount
    }

    // MARK: Evaluation & Automatic Regression Testing

    /// Compiled knowledge currently used by the lab's interactive inspector.
    var activeLabKnowledge: SMSCompiledKnowledge {
        let label: String = {
            let v = livePack.version
            if evaluateWithDrafts {
                return v > 0 ? "v\(v)+lab" : "lab"
            } else {
                return v > 0 ? "v\(v)" : "built-in"
            }
        }()
        return SMSCompiledKnowledge(pack: workingPack, label: label, includeDrafts: evaluateWithDrafts)
    }

    /// Candidate knowledge that would be published if the user taps "Publish to Budget AI" (approved rules only).
    var publishCandidateKnowledge: SMSCompiledKnowledge {
        let nextV = (versionHistory.map(\.version).max() ?? 0) + 1
        return SMSCompiledKnowledge(pack: workingPack.approvedOnly, label: "v\(nextV)-candidate", includeDrafts: false)
    }

    /// Evaluates every SMS in the lab using the actual `SMSParser` and runs the regression suite on all approved test cases.
    func evaluateAllAndRunRegression() {
        let compiled = activeLabKnowledge
        let liveCompiled = SMSKnowledgeStore.liveCompiled
        var newResults: [UUID: LabSnapshot] = [:]
        var baselineUpdated = false

        for idx in samples.indices {
            let sample = samples[idx]
            let snap = SMSLabEvaluator.snapshot(
                text: sample.text,
                sender: sample.sender,
                knowledge: compiled,
                includePersonalRules: includePersonalRules
            )
            newResults[sample.id] = snap

            // Record baseline pass/fail on the built-in/live engine the first time a sample is labeled
            if sample.expected.isLabeled && sample.baselinePassed == nil {
                let baseSnap = SMSLabEvaluator.snapshot(
                    text: sample.text,
                    sender: sample.sender,
                    knowledge: liveCompiled,
                    includePersonalRules: false
                )
                samples[idx].baselinePassed = LabCompare.passes(sample, baseSnap)
                baselineUpdated = true
            }
        }

        if baselineUpdated { saveSamples() }
        results = newResults
        regressionReport = computeRegressionReport()
    }

    /// Runs regression tests comparing the live published parser against the candidate pack across all permanent test cases.
    func computeRegressionReport(candidateOverride: SMSCompiledKnowledge? = nil) -> LabRegressionReport {
        let liveCompiled = SMSKnowledgeStore.liveCompiled
        let candidate = candidateOverride ?? (evaluateWithDrafts ? activeLabKnowledge : publishCandidateKnowledge)
        let approvedCases = samples.filter { $0.isTestCase && $0.expected.isLabeled }

        var report = LabRegressionReport(
            ranAt: .now,
            totalApprovedCases: approvedCases.count
        )

        for sample in approvedCases {
            let liveSnap = SMSLabEvaluator.snapshot(
                text: sample.text,
                sender: sample.sender,
                knowledge: liveCompiled,
                includePersonalRules: false
            )
            let candSnap = SMSLabEvaluator.snapshot(
                text: sample.text,
                sender: sample.sender,
                knowledge: candidate,
                includePersonalRules: false
            )
            let liveOK = LabCompare.passes(sample, liveSnap)
            let candOK = LabCompare.passes(sample, candSnap)
            if liveOK { report.livePassed += 1 }
            if candOK { report.candidatePassed += 1 }

            let failing = LabCompare.verdicts(expected: sample.expected, snapshot: candSnap).filter { !$0.isCorrect }
            let item = LabCaseRegression(
                sample: sample,
                liveSnapshot: liveSnap,
                candidateSnapshot: candSnap,
                livePassed: liveOK,
                candidatePassed: candOK,
                failingFields: failing
            )
            if item.isRegression {
                report.regressions.append(item)
            } else if item.isNewlyFixed {
                report.newlyFixed.append(item)
            } else if !candOK {
                report.stillFailing.append(item)
            }
        }
        return report
    }

    // MARK: Bulk Import & Sample Pack Management

    /// Adds imported SMS messages to the lab.
    /// Approved permanent test cases are NEVER automatically overwritten if a duplicate SMS is re-imported.
    @discardableResult
    func addImportedSamples(_ incoming: [LabSample]) -> (added: Int, skippedApprovedOrDuplicate: Int) {
        var existingKeys = Set(samples.map(\.dedupeKey))
        var added = 0
        var skipped = 0

        for var item in incoming {
            if existingKeys.contains(item.dedupeKey) {
                skipped += 1
                continue
            }
            existingKeys.insert(item.dedupeKey)
            if item.expected.isLabeled {
                let baseSnap = SMSLabEvaluator.snapshot(
                    text: item.text,
                    sender: item.sender,
                    knowledge: SMSKnowledgeStore.liveCompiled,
                    includePersonalRules: false
                )
                item.baselinePassed = LabCompare.passes(item, baseSnap)
            }
            samples.insert(item, at: 0)
            added += 1
        }

        saveSamples()
        evaluateAllAndRunRegression()
        return (added, skipped)
    }

    @discardableResult
    func loadBahrainSamplePack() -> (added: Int, skipped: Int) {
        let pack = SMSLabImporter.bahrainSamplePack()
        let res = addImportedSamples(pack)
        return (res.added, res.skippedApprovedOrDuplicate)
    }

    /// Updates a sample's expected classification or permanent test-case status.
    /// When `allowOverwriteApproved` is false (used by any automated/bulk operation), approved test cases cannot be modified.
    @discardableResult
    func updateSample(
        id: UUID,
        sender: String?? = nil,
        expected: LabExpected,
        promoteToTestCase: Bool? = nil,
        allowOverwriteApproved: Bool = false
    ) -> Bool {
        guard let idx = samples.firstIndex(where: { $0.id == id }) else { return false }
        if samples[idx].isTestCase && !allowOverwriteApproved {
            return false
        }
        if let sender {
            samples[idx].sender = sender
        }
        samples[idx].expected = expected
        if let promoteToTestCase {
            samples[idx].isTestCase = promoteToTestCase
            samples[idx].approvedAt = promoteToTestCase ? (samples[idx].approvedAt ?? .now) : nil
        }
        if expected.isLabeled && samples[idx].baselinePassed == nil {
            let baseSnap = SMSLabEvaluator.snapshot(
                text: samples[idx].text,
                sender: samples[idx].sender,
                knowledge: SMSKnowledgeStore.liveCompiled,
                includePersonalRules: false
            )
            samples[idx].baselinePassed = LabCompare.passes(samples[idx], baseSnap)
        }
        saveSamples()
        evaluateAllAndRunRegression()
        return true
    }

    /// Saves the current actual parser output as the expected classification and promotes the SMS to a permanent test case.
    func approveActualAsTestCase(id: UUID) {
        guard let idx = samples.firstIndex(where: { $0.id == id }),
              let snap = results[id] else { return }
        // Never overwrite an already-approved test case automatically
        guard !samples[idx].isTestCase else { return }
        var exp = samples[idx].expected
        if !snap.isTransaction {
            exp.nonTransaction = true
        } else {
            exp.nonTransaction = nil
            if exp.bank == nil { exp.bank = snap.bank }
            if exp.amount == nil { exp.amount = snap.amount }
            if exp.type == nil { exp.type = snap.type }
            if exp.direction == nil { exp.direction = snap.direction }
            if exp.account == nil { exp.account = snap.account }
            if exp.category == nil { exp.category = snap.category }
        }
        samples[idx].expected = exp
        samples[idx].isTestCase = true
        samples[idx].approvedAt = .now
        if samples[idx].baselinePassed == nil {
            samples[idx].baselinePassed = true
        }
        saveSamples()
        evaluateAllAndRunRegression()
    }

    func unlockTestCase(id: UUID) {
        guard let idx = samples.firstIndex(where: { $0.id == id }) else { return }
        samples[idx].isTestCase = false
        samples[idx].approvedAt = nil
        saveSamples()
        evaluateAllAndRunRegression()
    }

    func deleteSample(id: UUID, forceEvenIfApproved: Bool = false) {
        guard let idx = samples.firstIndex(where: { $0.id == id }) else { return }
        if samples[idx].isTestCase && !forceEvenIfApproved { return }
        samples.remove(at: idx)
        saveSamples()
        evaluateAllAndRunRegression()
    }

    /// Clears only non-approved imported messages; permanent approved test cases are preserved.
    func clearUnapprovedSamples() {
        samples.removeAll { !$0.isTestCase }
        saveSamples()
        evaluateAllAndRunRegression()
    }

    // MARK: Self-Learning Rule Generation & Rule Editing

    /// Evaluates approved test cases against the current approved rules (without drafts) and generates
    /// draft rules for any recurring mistakes or failed cases.
    @discardableResult
    func generateRulesFromCorrections() -> LabRuleProposal {
        let baseKnowledge = SMSCompiledKnowledge(pack: workingPack, label: "approved-only", includeDrafts: false)
        var baseResults: [UUID: LabSnapshot] = [:]
        for sample in samples {
            baseResults[sample.id] = SMSLabEvaluator.snapshot(
                text: sample.text,
                sender: sample.sender,
                knowledge: baseKnowledge,
                includePersonalRules: false
            )
        }

        let proposal = SMSRuleGenerator.generate(
            samples: samples,
            results: baseResults,
            existing: workingPack
        )

        workingPack.senderBanks.append(contentsOf: proposal.senderBanks)
        workingPack.patterns.append(contentsOf: proposal.patterns)
        workingPack.categoryKeywords.append(contentsOf: proposal.keywords)
        lastLearningNotes = proposal.notes

        saveWorkingPack()
        evaluateAllAndRunRegression()
        return proposal
    }

    func setSenderRuleStatus(id: String, status: SMSRuleStatus) {
        guard let idx = workingPack.senderBanks.firstIndex(where: { $0.id == id }) else { return }
        workingPack.senderBanks[idx].status = status
        saveWorkingPack()
        evaluateAllAndRunRegression()
    }

    func setPatternRuleStatus(id: String, status: SMSRuleStatus) {
        guard let idx = workingPack.patterns.firstIndex(where: { $0.id == id }) else { return }
        workingPack.patterns[idx].status = status
        saveWorkingPack()
        evaluateAllAndRunRegression()
    }

    func setKeywordRuleStatus(id: String, status: SMSRuleStatus) {
        guard let idx = workingPack.categoryKeywords.firstIndex(where: { $0.id == id }) else { return }
        workingPack.categoryKeywords[idx].status = status
        saveWorkingPack()
        evaluateAllAndRunRegression()
    }

    func approveAllDraftRules() {
        for idx in workingPack.senderBanks.indices where workingPack.senderBanks[idx].status == .draft {
            workingPack.senderBanks[idx].status = .approved
        }
        for idx in workingPack.patterns.indices where workingPack.patterns[idx].status == .draft {
            workingPack.patterns[idx].status = .approved
        }
        for idx in workingPack.categoryKeywords.indices where workingPack.categoryKeywords[idx].status == .draft {
            workingPack.categoryKeywords[idx].status = .approved
        }
        saveWorkingPack()
        evaluateAllAndRunRegression()
    }

    func addOrUpdateSenderRule(_ rule: SMSSenderBankRule) {
        if let idx = workingPack.senderBanks.firstIndex(where: { $0.id == rule.id }) {
            workingPack.senderBanks[idx] = rule
        } else {
            workingPack.senderBanks.append(rule)
        }
        saveWorkingPack()
        evaluateAllAndRunRegression()
    }

    func addOrUpdatePatternRule(_ rule: SMSPatternRule) {
        if let idx = workingPack.patterns.firstIndex(where: { $0.id == rule.id }) {
            workingPack.patterns[idx] = rule
        } else {
            workingPack.patterns.append(rule)
        }
        saveWorkingPack()
        evaluateAllAndRunRegression()
    }

    func addOrUpdateKeywordRule(_ rule: SMSCategoryKeywordRule) {
        if let idx = workingPack.categoryKeywords.firstIndex(where: { $0.id == rule.id }) {
            workingPack.categoryKeywords[idx] = rule
        } else {
            workingPack.categoryKeywords.append(rule)
        }
        saveWorkingPack()
        evaluateAllAndRunRegression()
    }

    func deleteRule(id: String) {
        workingPack.senderBanks.removeAll { $0.id == id }
        workingPack.patterns.removeAll { $0.id == id }
        workingPack.categoryKeywords.removeAll { $0.id == id }
        saveWorkingPack()
        evaluateAllAndRunRegression()
    }

    // MARK: Publish to Budget AI & Rollback

    /// Runs pre-publish regression on the approved rules and publishes them to the production `SMSKnowledgeStore`.
    @discardableResult
    func publishToBudgetAI(notes: String, allowWithRegressions: Bool = false) throws -> SMSKnowledgeVersionEntry {
        let publishReport = computeRegressionReport(candidateOverride: publishCandidateKnowledge)
        if !publishReport.regressions.isEmpty && !allowWithRegressions {
            throw SMSKnowledgeError.writeFailed("Pre-publish regression check detected \(publishReport.regressions.count) regression(s) on approved test cases.")
        }

        let cleanNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Published \(workingPack.approvedOnly.ruleCount) approved rule(s) from SMS Testing Lab"
            : notes.trimmingCharacters(in: .whitespacesAndNewlines)

        let entry = try SMSKnowledgeStore.publish(
            workingPack,
            notes: cleanNotes,
            regressionPassed: publishReport.candidatePassed,
            regressionTotal: publishReport.totalApprovedCases
        )

        // Keep draft rules in workingPack while syncing approved rules and version metadata from livePack
        let draftsSender = workingPack.senderBanks.filter { $0.status == .draft }
        let draftsPatterns = workingPack.patterns.filter { $0.status == .draft }
        let draftsKeywords = workingPack.categoryKeywords.filter { $0.status == .draft }

        var synced = SMSKnowledgeStore.livePack
        synced.senderBanks.append(contentsOf: draftsSender)
        synced.patterns.append(contentsOf: draftsPatterns)
        synced.categoryKeywords.append(contentsOf: draftsKeywords)
        workingPack = synced
        saveWorkingPack()
        versionHistory = SMSKnowledgeStore.history()
        evaluateAllAndRunRegression()
        return entry
    }

    /// Rolls the live parser back to a previous version and syncs the lab's approved rules to that snapshot.
    @discardableResult
    func rollbackToVersion(_ version: Int, notes: String = "") throws -> SMSKnowledgeVersionEntry {
        let entry = try SMSKnowledgeStore.rollback(to: version, notes: notes)
        let draftsSender = workingPack.senderBanks.filter { $0.status == .draft }
        let draftsPatterns = workingPack.patterns.filter { $0.status == .draft }
        let draftsKeywords = workingPack.categoryKeywords.filter { $0.status == .draft }

        var restored = SMSKnowledgeStore.livePack
        restored.senderBanks.append(contentsOf: draftsSender)
        restored.patterns.append(contentsOf: draftsPatterns)
        restored.categoryKeywords.append(contentsOf: draftsKeywords)
        workingPack = restored

        saveWorkingPack()
        versionHistory = SMSKnowledgeStore.history()
        evaluateAllAndRunRegression()
        return entry
    }

    func resetAllForTesting() {
        samples = []
        results = [:]
        workingPack = .empty
        regressionReport = LabRegressionReport()
        lastLearningNotes = []
        versionHistory = []
        try? FileManager.default.removeItem(at: Self.directory)
    }
}
