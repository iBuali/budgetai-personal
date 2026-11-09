import SwiftUI
import UniformTypeIdentifiers

// MARK: - SMS Testing Lab + Self-Learning Developer Interface

enum SMSLabTab: String, CaseIterable, Identifiable {
    case dashboard = "Dashboard"
    case messages = "SMS & Labels"
    case learning = "Self-Learning"
    case publish = "Publish"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .dashboard: "gauge.with.dots.needle.33percent"
        case .messages: "text.bubble.fill"
        case .learning: "brain.head.profile"
        case .publish: "arrow.up.doc.fill"
        }
    }
}

enum SMSLabFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case failed = "Failed"
    case passed = "Passed"
    case unlabeled = "Unlabeled"
    case testCases = "Test Cases"
    case skipped = "Non-Tx / OTP"

    var id: String { rawValue }
}

struct SMSTestingLabView: View {
    @Environment(AppState.self) private var appState
    @State private var store = SMSLabStore.shared
    @State private var selectedTab: SMSLabTab = .dashboard

    // Filters for SMS list
    @State private var statusFilter: SMSLabFilter = .all
    @State private var bankFilter: String = "All"
    @State private var typeFilter: String = "All"
    @State private var searchText: String = ""

    // Sheets & dialogs
    @State private var showFileImporter = false
    @State private var showPasteImportSheet = false
    @State private var editingSample: LabSample? = nil
    @State private var showAddRuleSheet: AddRuleKind? = nil
    @State private var releaseNotes: String = ""
    @State private var rollbackCandidate: SMSKnowledgeVersionEntry? = nil
    @State private var confirmClearUnapproved = false

    enum AddRuleKind: Identifiable {
        case sender, pattern, keyword
        var id: String {
            switch self {
            case .sender: "sender"
            case .pattern: "pattern"
            case .keyword: "keyword"
            }
        }
    }

    private var stats: LabStats { store.stats }

    var body: some View {
        VStack(spacing: 0) {
            topStatusHeader
            tabSelector
            Divider().overlay(Theme.track)

            ScrollView {
                VStack(spacing: 16) {
                    switch selectedTab {
                    case .dashboard:
                        dashboardTab
                    case .messages:
                        messagesTab
                    case .learning:
                        learningTab
                    case .publish:
                        publishTab
                    }
                }
                .padding(16)
                .padding(.bottom, 24)
            }
        }
        .canvasBackground()
        .navigationTitle("SMS Testing Lab")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        showFileImporter = true
                    } label: {
                        Label("Import TXT, CSV or Excel (.xlsx)", systemImage: "doc.badge.plus")
                    }
                    Button {
                        showPasteImportSheet = true
                    } label: {
                        Label("Paste Bulk SMS / CSV", systemImage: "doc.on.clipboard")
                    }
                    Button {
                        let res = store.loadBahrainSamplePack()
                        appState.show("Loaded \(res.added) Bahrain bank SMS (\(res.skipped) already in lab)")
                    } label: {
                        Label("Load Bahrain Bank Sample Pack", systemImage: "building.columns.fill")
                    }
                    Divider()
                    Button {
                        store.evaluateAllAndRunRegression()
                        appState.show("Re-evaluated \(store.samples.count) SMS with production parser")
                    } label: {
                        Label("Re-run Parser & Regression Suite", systemImage: "arrow.clockwise")
                    }
                    if store.samples.contains(where: { !$0.isTestCase }) {
                        Divider()
                        Button(role: .destructive) {
                            confirmClearUnapproved = true
                        } label: {
                            Label("Clear Unapproved SMS (Keep Test Cases)", systemImage: "trash")
                        }
                    }
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.title3)
                        .foregroundStyle(Theme.cobalt)
                }
            }
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [
                .plainText,
                .commaSeparatedText,
                .tabSeparatedText,
                UTType(filenameExtension: "xlsx") ?? .data,
                .data
            ],
            allowsMultipleSelection: true
        ) { result in
            handleFileImport(result)
        }
        .sheet(isPresented: $showPasteImportSheet) {
            SMSLabPasteImportSheet { summary in
                let res = store.addImportedSamples(summary.importedSamples)
                appState.show("Imported \(res.added) SMS from \(summary.format.rawValue)")
            }
        }
        .sheet(item: $editingSample) { sample in
            if let latest = store.samples.first(where: { $0.id == sample.id }) {
                SMSLabSampleInspectorSheet(
                    sample: latest,
                    snapshot: store.results[latest.id],
                    store: store
                )
            }
        }
        .sheet(item: $showAddRuleSheet) { kind in
            SMSLabRuleEditorSheet(kind: kind, store: store)
        }
        .confirmationDialog(
            "Clear unapproved SMS messages?",
            isPresented: $confirmClearUnapproved,
            titleVisibility: .visible
        ) {
            Button("Clear Unapproved Only", role: .destructive) {
                store.clearUnapprovedSamples()
                appState.show("Cleared unapproved SMS; permanent test cases preserved")
            }
        } message: {
            Text("Approved permanent test cases are locked and will never be deleted.")
        }
        .confirmationDialog(
            "Roll back live SMS knowledge?",
            isPresented: Binding(
                get: { rollbackCandidate != nil },
                set: { if !$0 { rollbackCandidate = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let entry = rollbackCandidate {
                Button("Roll Back to v\(entry.version)", role: .destructive) {
                    do {
                        let newEntry = try store.rollbackToVersion(entry.version)
                        appState.show("Rolled back live parser to v\(entry.version) (published as v\(newEntry.version))")
                    } catch {
                        appState.show(error.localizedDescription, warning: true)
                    }
                    rollbackCandidate = nil
                }
            }
        } message: {
            if let entry = rollbackCandidate {
                Text("This restores the approved bank formats, SMS patterns and classification rules from v\(entry.version) into the live Budget AI parser.")
            }
        }
    }

    // MARK: - Top Header & Tab Bar

    private var topStatusHeader: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "shield.lefthalf.filled.badge.checkmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Theme.positive)
                Text("Isolated Sandbox · Live Parser Engine")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.ink)
            }
            Spacer()
            let liveV = store.livePack.version
            Text(liveV > 0 ? "Live v\(liveV)" : "Built-in v0")
                .font(.caption2.weight(.bold).monospacedDigit())
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Theme.cobaltSoft, in: Capsule())
                .foregroundStyle(Theme.cobalt)

            if !store.unpublishedChanges.isEmpty || store.draftRulesCount > 0 {
                let pendingCount = store.unpublishedChanges.count + store.draftRulesCount
                Text("\(pendingCount) unpublished")
                    .font(.caption2.weight(.bold).monospacedDigit())
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Theme.warning.opacity(0.16), in: Capsule())
                    .foregroundStyle(Theme.warning)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Theme.surface)
    }

    private var tabSelector: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(SMSLabTab.allCases) { tab in
                    let active = selectedTab == tab
                    Button {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                            selectedTab = tab
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: tab.symbol)
                                .font(.caption.weight(.semibold))
                            Text(tab.rawValue)
                                .font(.subheadline.weight(.semibold))
                            if tab == .messages && stats.failed > 0 {
                                badgePill("\(stats.failed)", color: Theme.negative)
                            } else if tab == .learning && store.draftRulesCount > 0 {
                                badgePill("\(store.draftRulesCount)", color: Theme.warning)
                            } else if tab == .publish && !store.unpublishedChanges.isEmpty {
                                badgePill("\(store.unpublishedChanges.count)", color: Theme.cobalt)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(active ? Theme.cobalt : Theme.canvas, in: Capsule())
                        .foregroundStyle(active ? .white : Theme.ink)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(Theme.surface)
    }

    private func badgePill(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.bold).monospacedDigit())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(selectedTab == .dashboard ? color : .white)
    }

    // MARK: - 1. DASHBOARD TAB

    private var dashboardTab: some View {
        VStack(spacing: 16) {
            if store.samples.isEmpty {
                emptyLabHeroCard
            }

            metricsGridCard
            quickActionsCard
            bankCoverageCard
            if stats.labeled > 0 {
                fieldAccuracyCard
                bankAccuracyBreakdownCard
                typeBreakdownCard
            }
        }
    }

    private var emptyLabHeroCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                IconBadge(symbol: "sparkles.rectangle.stack.fill", color: Theme.cobalt, size: 46)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Ready to Test & Train Budget AI")
                        .font(.headline)
                        .foregroundStyle(Theme.ink)
                    Text("Import hundreds of SMS messages from TXT, CSV or Excel (.xlsx), or start with the curated 18-message Bahrain Bank Sample Pack.")
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryInk)
                }
            }
            HStack(spacing: 10) {
                Button {
                    let res = store.loadBahrainSamplePack()
                    appState.show("Loaded \(res.added) Bahrain bank SMS messages")
                } label: {
                    Label("Load Bahrain Sample Pack", systemImage: "building.columns.fill")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(Theme.cobalt, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .foregroundStyle(.white)
                }
                .buttonStyle(PressableStyle())

                Button {
                    showFileImporter = true
                } label: {
                    Label("Import File", systemImage: "doc.badge.plus")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)
                        .background(Theme.cobaltSoft, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .foregroundStyle(Theme.cobalt)
                }
                .buttonStyle(PressableStyle())
            }
        }
        .card()
    }

    private var metricsGridCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Lab Overview")
                    .font(.headline)
                    .foregroundStyle(Theme.ink)
                Spacer()
                Toggle(isOn: $store.evaluateWithDrafts) {
                    Text("Preview Draft Rules")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Theme.secondaryInk)
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                .fixedSize()
            }

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                metricTile(
                    title: "SMS Tested",
                    value: "\(stats.total)",
                    subtitle: "\(stats.testCases) locked cases",
                    symbol: "message.fill",
                    color: Theme.cobalt
                )
                metricTile(
                    title: "Accuracy",
                    value: LabFormat.percent(stats.accuracy),
                    subtitle: "\(stats.passed)/\(stats.labeled) labeled",
                    symbol: "checkmark.seal.fill",
                    color: (stats.accuracy ?? 1) >= 0.9 ? Theme.positive : Theme.warning
                )
                metricTile(
                    title: "Failed Cases",
                    value: "\(stats.failed)",
                    subtitle: stats.failed == 0 ? "All passing" : "Tap to inspect",
                    symbol: "exclamationmark.triangle.fill",
                    color: stats.failed == 0 ? Theme.positive : Theme.negative
                )
                metricTile(
                    title: "Improvements",
                    value: "+\(stats.improvements)",
                    subtitle: "Fixed vs baseline",
                    symbol: "arrow.up.right.circle.fill",
                    color: Theme.positive
                )
                metricTile(
                    title: "Bank Coverage",
                    value: "\(stats.coveredBanks.count)/\(stats.catalogBanks.count)",
                    subtitle: LabFormat.percent(stats.coverage) + " Bahrain",
                    symbol: "building.columns.fill",
                    color: Theme.cobalt
                )
                metricTile(
                    title: "Unpublished",
                    value: "\(store.unpublishedChanges.count + store.draftRulesCount)",
                    subtitle: "\(store.draftRulesCount) draft · \(store.unpublishedChanges.count) staged",
                    symbol: "arrow.up.doc.fill",
                    color: (store.unpublishedChanges.isEmpty && store.draftRulesCount == 0) ? Theme.secondaryInk : Theme.warning
                )
            }
        }
        .card()
    }

    private func metricTile(title: String, value: String, subtitle: String, symbol: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(color)
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Theme.secondaryInk)
                    .lineLimit(1)
            }
            Text(value)
                .font(.title3.weight(.bold).monospacedDigit())
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(Theme.secondaryInk)
                .lineLimit(1)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.canvas, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var quickActionsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Workflow Actions")
                .font(.headline)
                .foregroundStyle(Theme.ink)

            HStack(spacing: 10) {
                Button {
                    showFileImporter = true
                } label: {
                    actionButtonLabel("Import File", subtitle: "TXT · CSV · XLSX", symbol: "tray.and.arrow.down.fill", color: Theme.cobalt)
                }
                .buttonStyle(PressableStyle())

                Button {
                    showPasteImportSheet = true
                } label: {
                    actionButtonLabel("Paste Batch", subtitle: "Raw SMS or CSV", symbol: "doc.on.clipboard.fill", color: SpendCategory.transport.color)
                }
                .buttonStyle(PressableStyle())

                Button {
                    let proposal = store.generateRulesFromCorrections()
                    if proposal.count > 0 {
                        appState.show("Generated \(proposal.count) draft rule(s) from corrections")
                        selectedTab = .learning
                    } else {
                        appState.show(proposal.notes.first ?? "No new rules needed")
                        selectedTab = .learning
                    }
                } label: {
                    actionButtonLabel("Self-Learn", subtitle: "Generate rules", symbol: "brain.head.profile", color: SpendCategory.shopping.color)
                }
                .buttonStyle(PressableStyle())
            }
        }
        .card()
    }

    private func actionButtonLabel(_ title: String, subtitle: String, symbol: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            IconBadge(symbol: symbol, color: color, size: 34)
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(Theme.secondaryInk)
                .lineLimit(1)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.canvas, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var bankCoverageCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Bahrain Bank Coverage")
                    .font(.headline)
                    .foregroundStyle(Theme.ink)
                Spacer()
                Text("\(stats.coveredBanks.count) of \(stats.catalogBanks.count) institutions tested")
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryInk)
            }
            ProgressBar(progress: stats.coverage, color: Theme.cobalt, height: 8)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 8)], spacing: 8) {
                ForEach(stats.catalogBanks, id: \.self) { bank in
                    let covered = stats.coveredBanks.contains { SMSKnowledge.sameBank($0, bank) }
                    HStack(spacing: 5) {
                        Image(systemName: covered ? "checkmark.circle.fill" : "circle.dashed")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(covered ? Theme.positive : Theme.secondaryInk)
                        Text(bank)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(covered ? Theme.ink : Theme.secondaryInk)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(covered ? Theme.positive.opacity(0.10) : Theme.canvas, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
        }
        .card()
    }

    private var fieldAccuracyCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Accuracy by Extracted Field")
                .font(.headline)
                .foregroundStyle(Theme.ink)

            ForEach(stats.fields) { f in
                HStack(spacing: 10) {
                    Text(f.field.title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Theme.ink)
                        .frame(width: 78, alignment: .leading)
                    ProgressBar(
                        progress: f.accuracy ?? 0,
                        color: (f.accuracy ?? 0) >= 0.9 ? Theme.positive : Theme.warning,
                        height: 7
                    )
                    Text("\(f.correct)/\(f.total) (\(LabFormat.percent(f.accuracy)))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Theme.secondaryInk)
                        .frame(width: 86, alignment: .trailing)
                }
            }
        }
        .card()
    }

    private var bankAccuracyBreakdownCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Accuracy & Errors by Bank")
                    .font(.headline)
                    .foregroundStyle(Theme.ink)
                Spacer()
                Text("Tap a bank to filter")
                    .font(.caption2)
                    .foregroundStyle(Theme.secondaryInk)
            }

            ForEach(stats.byBank) { item in
                Button {
                    bankFilter = item.bank
                    selectedTab = .messages
                } label: {
                    HStack(spacing: 10) {
                        IconBadge(symbol: "building.columns.fill", color: item.failed > 0 ? Theme.negative : Theme.cobalt, size: 32)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.bank)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Theme.ink)
                            Text("\(item.total) SMS · \(item.labeled) labeled")
                                .font(.caption2)
                                .foregroundStyle(Theme.secondaryInk)
                        }
                        Spacer()
                        if item.failed > 0 {
                            Text("\(item.failed) error\(item.failed == 1 ? "" : "s")")
                                .font(.caption2.weight(.bold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Theme.negative.opacity(0.14), in: Capsule())
                                .foregroundStyle(Theme.negative)
                        }
                        Text(LabFormat.percent(item.accuracy))
                            .font(.subheadline.weight(.bold).monospacedDigit())
                            .foregroundStyle(item.failed > 0 ? Theme.warning : Theme.positive)
                    }
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
            }
        }
        .card()
    }

    private var typeBreakdownCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Accuracy & Errors by Transaction Type")
                .font(.headline)
                .foregroundStyle(Theme.ink)

            ForEach(stats.byType) { item in
                HStack {
                    Text(item.title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Theme.ink)
                    Spacer()
                    Text("\(item.total) total")
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryInk)
                    if item.failed > 0 {
                        Text("\(item.failed) failed")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Theme.negative.opacity(0.14), in: Capsule())
                            .foregroundStyle(Theme.negative)
                    } else if item.labeled > 0 {
                        Text("100%")
                            .font(.caption.weight(.bold).monospacedDigit())
                            .foregroundStyle(Theme.positive)
                    }
                }
                .padding(.vertical, 3)
            }
        }
        .card()
    }

    // MARK: - 2. MESSAGES & EXPECTED VS ACTUAL TAB

    private var filteredSamples: [LabSample] {
        store.samples.filter { sample in
            let snap = store.results[sample.id]
            let status = LabCompare.status(sample, snap)

            switch statusFilter {
            case .all: break
            case .failed: if status != .failed { return false }
            case .passed: if status != .passed { return false }
            case .unlabeled: if status != .unlabeled { return false }
            case .testCases: if !sample.isTestCase { return false }
            case .skipped: if snap?.isTransaction != false { return false }
            }

            if bankFilter != "All" {
                let b = sample.expected.bank ?? snap?.bank ?? "Unknown"
                if !SMSKnowledge.sameBank(b, bankFilter) && b != bankFilter { return false }
            }

            if typeFilter != "All" {
                let t = sample.expected.type ?? snap?.type ?? "skip"
                if t != typeFilter { return false }
            }

            let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !q.isEmpty {
                let hay = [
                    sample.text,
                    sample.sender ?? "",
                    snap?.bank ?? "",
                    snap?.merchant ?? "",
                    sample.expected.bank ?? ""
                ].joined(separator: " ").lowercased()
                if !hay.contains(q) { return false }
            }
            return true
        }
    }

    private var availableBankFilters: [String] {
        let names = Set(store.samples.compactMap { s in
            s.expected.bank ?? store.results[s.id]?.bank
        })
        return ["All"] + names.sorted()
    }

    private var messagesTab: some View {
        VStack(spacing: 12) {
            filterBarCard

            if filteredSamples.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.title2)
                        .foregroundStyle(Theme.secondaryInk)
                    Text(store.samples.isEmpty ? "No SMS messages in the lab yet." : "No SMS messages match the current filters.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondaryInk)
                    if store.samples.isEmpty {
                        Button("Load Bahrain Bank Sample Pack") {
                            _ = store.loadBahrainSamplePack()
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.cobalt)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
                .card()
            } else {
                ForEach(filteredSamples) { sample in
                    sampleRowCard(sample)
                }
            }
        }
    }

    private var filterBarCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Theme.secondaryInk)
                TextField("Search SMS text, bank, sender or merchant…", text: $searchText)
                    .font(.subheadline)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Theme.secondaryInk)
                    }
                }
            }
            .padding(10)
            .background(Theme.canvas, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(SMSLabFilter.allCases) { f in
                        let on = statusFilter == f
                        Button {
                            statusFilter = f
                        } label: {
                            Text(f.rawValue)
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(on ? Theme.cobalt : Theme.canvas, in: Capsule())
                                .foregroundStyle(on ? .white : Theme.ink)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            HStack(spacing: 10) {
                Menu {
                    ForEach(availableBankFilters, id: \.self) { b in
                        Button(b) { bankFilter = b }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "building.columns")
                        Text("Bank: \(bankFilter)")
                        Image(systemName: "chevron.down")
                    }
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Theme.canvas, in: Capsule())
                    .foregroundStyle(Theme.ink)
                }

                Menu {
                    Button("All") { typeFilter = "All" }
                    ForEach(SMSTransactionType.allCases) { t in
                        Button(t.title) { typeFilter = t.rawValue }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.left.arrow.right")
                        Text("Type: \(typeFilter == "All" ? "All" : (SMSTransactionType(rawValue: typeFilter)?.title ?? typeFilter))")
                        Image(systemName: "chevron.down")
                    }
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Theme.canvas, in: Capsule())
                    .foregroundStyle(Theme.ink)
                }

                Spacer()
                Text("\(filteredSamples.count) shown")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(Theme.secondaryInk)
            }
        }
        .card(padding: 12)
    }

    private func sampleRowCard(_ sample: LabSample) -> some View {
        let snap = store.results[sample.id]
        let status = LabCompare.status(sample, snap)
        let verdicts = (snap != nil && sample.expected.isLabeled)
            ? LabCompare.verdicts(expected: sample.expected, snapshot: snap!)
            : []
        let verdictMap = Dictionary(uniqueKeysWithValues: verdicts.map { ($0.field, $0) })

        return Button {
            editingSample = sample
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                // Header row: Sender + Test case badge + Status pill
                HStack(spacing: 8) {
                    if let sender = sample.sender, !sender.isEmpty {
                        Label(sender, systemImage: "antenna.radiowaves.left.and.right")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Theme.cobaltSoft, in: Capsule())
                            .foregroundStyle(Theme.cobalt)
                    } else {
                        Text(sample.source)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(Theme.secondaryInk)
                    }

                    if sample.isTestCase {
                        Label("Test Case", systemImage: "lock.fill")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Theme.cobalt.opacity(0.12), in: Capsule())
                            .foregroundStyle(Theme.cobalt)
                    }

                    Spacer()
                    statusBadge(status)
                }

                // SMS raw text
                Text(sample.text)
                    .font(.footnote)
                    .foregroundStyle(Theme.ink)
                    .multilineTextAlignment(.leading)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // Detected fields grid (Bank, Amount, Type, Direction, Account, Category)
                if let snap {
                    if snap.isTransaction {
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                            ForEach(LabField.allCases) { field in
                                fieldChip(field: field, actual: snap.display(field), verdict: verdictMap[field])
                            }
                        }
                    } else {
                        HStack(spacing: 6) {
                            Image(systemName: "nosign")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(verdictMap[.type]?.isCorrect == false ? Theme.negative : Theme.secondaryInk)
                            Text(snap.skipReason ?? "Skipped as non-transaction")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(Theme.secondaryInk)
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.canvas, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }

                    // Top reasoning summary + quick approve button
                    HStack(spacing: 8) {
                        Image(systemName: snap.knowledgeRuleID != nil ? "brain" : "info.circle")
                            .font(.caption2)
                            .foregroundStyle(snap.knowledgeRuleID != nil ? Theme.cobalt : Theme.secondaryInk)
                        Text(snap.reasoning.first(where: { $0.kind == "type" || $0.kind == "knowledge" })?.text ?? snap.reasoning.first?.text ?? "")
                            .font(.caption2)
                            .foregroundStyle(Theme.secondaryInk)
                            .lineLimit(1)
                        Spacer()
                        if !sample.isTestCase {
                            Button {
                                store.approveActualAsTestCase(id: sample.id)
                                appState.show("Saved as permanent test case")
                            } label: {
                                Label("Approve", systemImage: "checkmark.circle")
                                    .font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Theme.positive.opacity(0.14), in: Capsule())
                                    .foregroundStyle(Theme.positive)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .card(padding: 14)
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .strokeBorder(borderColor(for: status), lineWidth: status == .failed ? 1.5 : (status == .passed ? 1.0 : 0))
            )
        }
        .buttonStyle(.plain)
    }

    private func fieldChip(field: LabField, actual: String, verdict: LabFieldVerdict?) -> some View {
        let bg: Color = {
            guard let verdict else { return Theme.canvas }
            return verdict.isCorrect ? Theme.positive.opacity(0.12) : Theme.negative.opacity(0.14)
        }()
        let fg: Color = {
            guard let verdict else { return Theme.ink }
            return verdict.isCorrect ? Theme.positive : Theme.negative
        }()

        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 3) {
                Text(field.title.uppercased())
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.secondaryInk)
                Spacer(minLength: 0)
                if let verdict {
                    Image(systemName: verdict.isCorrect ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(fg)
                }
            }
            Text(actual)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            if let verdict, !verdict.isCorrect {
                Text("Exp: \(verdict.expected)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.negative)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(bg, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func statusBadge(_ status: LabStatus) -> some View {
        let (label, icon, color): (String, String, Color) = {
            switch status {
            case .passed: return ("Match", "checkmark.circle.fill", Theme.positive)
            case .failed: return ("Mismatch", "xmark.octagon.fill", Theme.negative)
            case .unlabeled: return ("Unlabeled", "questionmark.circle", Theme.secondaryInk)
            case .notEvaluated: return ("Pending", "clock", Theme.warning)
            }
        }()
        return Label(label, systemImage: icon)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.14), in: Capsule())
            .foregroundStyle(color)
    }

    private func borderColor(for status: LabStatus) -> Color {
        switch status {
        case .passed: Theme.positive.opacity(0.35)
        case .failed: Theme.negative.opacity(0.65)
        default: .clear
        }
    }

    // MARK: - 3. SELF-LEARNING & REGRESSION TAB

    private var learningTab: some View {
        VStack(spacing: 16) {
            selfLearningBannerCard
            regressionSuiteCard
            mistakeClustersCard
            rulesListCard
        }
    }

    private var selfLearningBannerCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                IconBadge(symbol: "brain.head.profile", color: SpendCategory.shopping.color, size: 42)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Self-Learning Rule Synthesizer")
                        .font(.headline)
                        .foregroundStyle(Theme.ink)
                    Text("Analyzes approved test cases where the baseline parser failed and generates scoped Sender→Bank formats, Regex SMS patterns, and Merchant→Category rules. Approved test cases are never overwritten.")
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryInk)
                }
            }

            HStack(spacing: 10) {
                Button {
                    let proposal = store.generateRulesFromCorrections()
                    if proposal.count > 0 {
                        appState.show("Generated \(proposal.count) new draft rule(s)")
                    } else {
                        appState.show(proposal.notes.first ?? "All approved test cases already pass")
                    }
                } label: {
                    Label("Generate Improved Rules", systemImage: "wand.and.stars")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(Theme.cobalt, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .foregroundStyle(.white)
                }
                .buttonStyle(PressableStyle())

                if store.draftRulesCount > 0 {
                    Button {
                        store.approveAllDraftRules()
                        appState.show("Approved all draft rules — ready to publish")
                    } label: {
                        Label("Approve All (\(store.draftRulesCount))", systemImage: "checkmark.seal.fill")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 11)
                            .background(Theme.positive.opacity(0.15), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .foregroundStyle(Theme.positive)
                    }
                    .buttonStyle(PressableStyle())
                }
            }

            if !store.lastLearningNotes.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(store.lastLearningNotes, id: \.self) { note in
                        Label(note, systemImage: "sparkles")
                            .font(.caption2)
                            .foregroundStyle(Theme.secondaryInk)
                    }
                }
            }
        }
        .card()
    }

    private var regressionSuiteCard: some View {
        let rep = store.regressionReport
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Automated Regression Suite", systemImage: "checkmark.shield.fill")
                    .font(.headline)
                    .foregroundStyle(Theme.ink)
                Spacer()
                Text(rep.isSafeToPublish ? "0 Regressions" : "\(rep.regressions.count) Regression(s)")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background((rep.isSafeToPublish ? Theme.positive : Theme.negative).opacity(0.15), in: Capsule())
                    .foregroundStyle(rep.isSafeToPublish ? Theme.positive : Theme.negative)
            }

            Text("Runs automatically whenever any rule or test case changes.")
                .font(.caption)
                .foregroundStyle(Theme.secondaryInk)

            HStack(spacing: 10) {
                regressionStatPill("Approved Cases", "\(rep.totalApprovedCases)", color: Theme.cobalt)
                regressionStatPill("Live Passing", "\(rep.livePassed)/\(rep.totalApprovedCases)", color: Theme.secondaryInk)
                regressionStatPill("Candidate Passing", "\(rep.candidatePassed)/\(rep.totalApprovedCases)", color: rep.candidatePassed >= rep.livePassed ? Theme.positive : Theme.negative)
                regressionStatPill("Newly Fixed", "+\(rep.newlyFixed.count)", color: Theme.positive)
            }

            if !rep.regressions.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Regressions Detected (Passed on Live, Failed on Candidate):")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Theme.negative)
                    ForEach(rep.regressions) { reg in
                        Text("• \(reg.sample.text.prefix(80))…")
                            .font(.caption2)
                            .foregroundStyle(Theme.negative)
                    }
                }
                .padding(10)
                .background(Theme.negative.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            if !rep.newlyFixed.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Improvements Verified by Regression Suite:")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Theme.positive)
                    ForEach(rep.newlyFixed.prefix(5)) { fix in
                        Text("✓ [\(fix.candidateSnapshot.bank ?? "Bank")] \(fix.sample.text.prefix(75))…")
                            .font(.caption2)
                            .foregroundStyle(Theme.ink)
                    }
                }
                .padding(10)
                .background(Theme.positive.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .card()
    }

    private func regressionStatPill(_ label: String, _ value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.secondaryInk)
                .lineLimit(1)
            Text(value)
                .font(.subheadline.weight(.bold).monospacedDigit())
                .foregroundStyle(color)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.canvas, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var mistakeClustersCard: some View {
        let clusters = store.mistakeClusters
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Recurring Patterns & Classification Mistakes")
                    .font(.headline)
                    .foregroundStyle(Theme.ink)
                Spacer()
                Text("\(clusters.count) pattern\(clusters.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryInk)
            }

            if clusters.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Theme.positive)
                    Text("Zero classification mistakes across all labeled SMS messages.")
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryInk)
                }
                .padding(.vertical, 6)
            } else {
                ForEach(clusters) { c in
                    HStack(spacing: 10) {
                        IconBadge(symbol: "exclamationmark.bubble.fill", color: Theme.negative, size: 34)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(c.bank) · \(c.field.title) Mistake")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Theme.ink)
                            Text("Expected '\(c.expected)' vs Actual '\(c.actual)' · \(c.formats) template(s)")
                                .font(.caption2)
                                .foregroundStyle(Theme.secondaryInk)
                        }
                        Spacer()
                        Text("\(c.sampleIDs.count)×")
                            .font(.caption.weight(.bold).monospacedDigit())
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Theme.negative.opacity(0.14), in: Capsule())
                            .foregroundStyle(Theme.negative)
                    }
                    .padding(10)
                    .background(Theme.canvas, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
        }
        .card()
    }

    private var rulesListCard: some View {
        let pack = store.workingPack
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Knowledge Rules (\(pack.ruleCount))")
                    .font(.headline)
                    .foregroundStyle(Theme.ink)
                Spacer()
                Menu {
                    Button {
                        showAddRuleSheet = .sender
                    } label: {
                        Label("Add Sender → Bank Format", systemImage: "building.columns")
                    }
                    Button {
                        showAddRuleSheet = .pattern
                    } label: {
                        Label("Add Regex SMS Pattern", systemImage: "text.magnifyingglass")
                    }
                    Button {
                        showAddRuleSheet = .keyword
                    } label: {
                        Label("Add Merchant → Category Rule", systemImage: "tag")
                    }
                } label: {
                    Label("Add Rule", systemImage: "plus.circle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.cobalt)
                }
            }

            if pack.ruleCount == 0 {
                Text("No custom or learned rules yet. Correct a failed SMS or tap 'Generate Improved Rules' above.")
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryInk)
                    .padding(.vertical, 6)
            } else {
                if !pack.senderBanks.isEmpty {
                    Text("Bank Sender Formats (\(pack.senderBanks.count))")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Theme.secondaryInk)
                    ForEach(pack.senderBanks) { rule in
                        ruleRow(
                            title: "Sender '\(rule.sender)' → \(rule.bank)",
                            subtitle: rule.note.isEmpty ? "Identifies bank from SMS sender ID" : rule.note,
                            status: rule.status,
                            onApprove: { store.setSenderRuleStatus(id: rule.id, status: .approved) },
                            onReject: { store.setSenderRuleStatus(id: rule.id, status: .rejected) },
                            onDelete: { store.deleteRule(id: rule.id) }
                        )
                    }
                }

                if !pack.patterns.isEmpty {
                    Text("SMS Regex Patterns (\(pack.patterns.count))")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Theme.secondaryInk)
                    ForEach(pack.patterns) { rule in
                        ruleRow(
                            title: rule.name,
                            subtitle: "Regex: \(rule.pattern)",
                            status: rule.status,
                            onApprove: { store.setPatternRuleStatus(id: rule.id, status: .approved) },
                            onReject: { store.setPatternRuleStatus(id: rule.id, status: .rejected) },
                            onDelete: { store.deleteRule(id: rule.id) }
                        )
                    }
                }

                if !pack.categoryKeywords.isEmpty {
                    Text("Merchant Classification Keywords (\(pack.categoryKeywords.count))")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Theme.secondaryInk)
                    ForEach(pack.categoryKeywords) { rule in
                        let catTitle = SpendCategory(rawValue: rule.category)?.title ?? rule.category
                        ruleRow(
                            title: "Keyword '\(rule.keyword)' → \(catTitle)",
                            subtitle: rule.note.isEmpty ? "Maps merchant keyword to category" : rule.note,
                            status: rule.status,
                            onApprove: { store.setKeywordRuleStatus(id: rule.id, status: .approved) },
                            onReject: { store.setKeywordRuleStatus(id: rule.id, status: .rejected) },
                            onDelete: { store.deleteRule(id: rule.id) }
                        )
                    }
                }
            }
        }
        .card()
    }

    private func ruleRow(
        title: String,
        subtitle: String,
        status: SMSRuleStatus,
        onApprove: @escaping () -> Void,
        onReject: @escaping () -> Void,
        onDelete: @escaping () -> Void
    ) -> some View {
        let statusColor: Color = {
            switch status {
            case .approved: Theme.positive
            case .draft: Theme.warning
            case .rejected: Theme.negative
            }
        }()

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.ink)
                Spacer()
                Text(status.title)
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(statusColor.opacity(0.15), in: Capsule())
                    .foregroundStyle(statusColor)
            }
            Text(subtitle)
                .font(.caption2.monospaced())
                .foregroundStyle(Theme.secondaryInk)
                .lineLimit(2)

            HStack(spacing: 10) {
                if status != .approved {
                    Button(action: onApprove) {
                        Label("Approve", systemImage: "checkmark.circle.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.positive)
                    }
                    .buttonStyle(.plain)
                }
                if status != .rejected {
                    Button(action: onReject) {
                        Label("Reject", systemImage: "xmark.circle")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.warning)
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                        .font(.caption)
                        .foregroundStyle(Theme.negative)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .background(Theme.canvas, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - 4. PUBLISH TO BUDGET AI TAB

    private var publishTab: some View {
        let publishReport = store.computeRegressionReport(candidateOverride: store.publishCandidateKnowledge)
        let changes = store.unpublishedChanges

        return VStack(spacing: 16) {
            publishActionCard(publishReport: publishReport, changes: changes)
            unpublishedDiffCard(changes: changes)
            versionHistoryCard
        }
    }

    private func publishActionCard(publishReport: LabRegressionReport, changes: [LabKnowledgeChange]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                IconBadge(symbol: "arrow.up.doc.fill", color: Theme.cobalt, size: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Publish Knowledge to Budget AI")
                        .font(.headline)
                        .foregroundStyle(Theme.ink)
                    Text("Publishes all approved bank formats, SMS patterns and classification rules directly into the production SMSParser engine.")
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryInk)
                }
            }

            if store.draftRulesCount > 0 {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(Theme.warning)
                    Text("You have \(store.draftRulesCount) draft rule(s). Only approved rules are included in a published version.")
                        .font(.caption)
                        .foregroundStyle(Theme.ink)
                    Spacer()
                    Button("Approve All") {
                        store.approveAllDraftRules()
                    }
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Theme.cobalt)
                }
                .padding(10)
                .background(Theme.warning.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            // Pre-publish Regression Gate
            HStack(spacing: 10) {
                Image(systemName: publishReport.isSafeToPublish ? "checkmark.shield.fill" : "xmark.shield.fill")
                    .font(.title3)
                    .foregroundStyle(publishReport.isSafeToPublish ? Theme.positive : Theme.negative)
                VStack(alignment: .leading, spacing: 2) {
                    Text(publishReport.isSafeToPublish ? "Pre-Publish Regression Check Passed" : "Pre-Publish Regression Check Failed")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.ink)
                    Text("\(publishReport.candidatePassed)/\(publishReport.totalApprovedCases) permanent test cases pass · \(publishReport.regressions.count) regressions")
                        .font(.caption2)
                        .foregroundStyle(Theme.secondaryInk)
                }
                Spacer()
            }
            .padding(10)
            .background(Theme.canvas, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            TextField("Version release notes (e.g. Added BBK shortcode & NBB roastery rules)…", text: $releaseNotes)
                .font(.subheadline)
                .padding(10)
                .background(Theme.canvas, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            Button {
                do {
                    let entry = try store.publishToBudgetAI(notes: releaseNotes)
                    releaseNotes = ""
                    appState.show("Published SMS Knowledge v\(entry.version) to Budget AI")
                } catch {
                    appState.show(error.localizedDescription, warning: true)
                }
            } label: {
                HStack {
                    Image(systemName: "paperplane.fill")
                    Text("Publish to Budget AI (v\((store.versionHistory.map(\.version).max() ?? 0) + 1))")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(publishReport.isSafeToPublish ? Theme.cobalt : Theme.secondaryInk, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .foregroundStyle(.white)
            }
            .buttonStyle(PressableStyle())
            .disabled(!publishReport.isSafeToPublish)
        }
        .card()
    }

    private func unpublishedDiffCard(changes: [LabKnowledgeChange]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Unpublished Approved Changes")
                    .font(.headline)
                    .foregroundStyle(Theme.ink)
                Spacer()
                Text("\(changes.count) change\(changes.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryInk)
            }

            if changes.isEmpty {
                Text("Live Budget AI parser is up to date with all approved rules.")
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryInk)
            } else {
                ForEach(changes) { change in
                    let color: Color = {
                        switch change.kind {
                        case .added: Theme.positive
                        case .modified: Theme.warning
                        case .removed: Theme.negative
                        }
                    }()
                    HStack(spacing: 8) {
                        Text(change.kind.rawValue.uppercased())
                            .font(.system(size: 10, weight: .bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(color.opacity(0.15), in: Capsule())
                            .foregroundStyle(color)
                        Text(change.area)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Theme.secondaryInk)
                        Text(change.title)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Theme.ink)
                            .lineLimit(1)
                        Spacer()
                    }
                    .padding(8)
                    .background(Theme.canvas, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
        }
        .card()
    }

    private var versionHistoryCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Published Version History & Rollback")
                    .font(.headline)
                    .foregroundStyle(Theme.ink)
                Spacer()
                if let exportURL = try? SMSKnowledgeStore.exportURL() {
                    ShareLink(item: exportURL) {
                        Label("Export JSON", systemImage: "square.and.arrow.up")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.cobalt)
                    }
                }
            }

            if store.versionHistory.isEmpty {
                Text("No versions published yet. The live app is currently using built-in rules (v0).")
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryInk)
            } else {
                ForEach(store.versionHistory) { entry in
                    let isCurrent = entry.version == store.livePack.version
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("v\(entry.version)")
                                .font(.subheadline.weight(.bold).monospacedDigit())
                                .foregroundStyle(Theme.cobalt)
                            if isCurrent {
                                Text("LIVE")
                                    .font(.system(size: 10, weight: .bold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Theme.positive.opacity(0.16), in: Capsule())
                                    .foregroundStyle(Theme.positive)
                            }
                            if entry.action == .rollback, let from = entry.restoredFrom {
                                Text("Restored from v\(from)")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(Theme.warning)
                            }
                            Spacer()
                            Text(entry.publishedAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption2)
                                .foregroundStyle(Theme.secondaryInk)
                        }

                        Text(entry.notes)
                            .font(.caption)
                            .foregroundStyle(Theme.ink)

                        HStack(spacing: 10) {
                            Text("\(entry.senderCount) senders · \(entry.patternCount) patterns · \(entry.keywordCount) keywords")
                                .font(.caption2)
                                .foregroundStyle(Theme.secondaryInk)
                            if let p = entry.regressionPassed, let t = entry.regressionTotal {
                                Text("Regression: \(p)/\(t)")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(Theme.positive)
                            }
                            Spacer()
                            if !isCurrent {
                                Button {
                                    rollbackCandidate = entry
                                } label: {
                                    Label("Roll Back", systemImage: "arrow.uturn.backward.circle.fill")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(Theme.cobalt)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(10)
                    .background(Theme.canvas, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
        }
        .card()
    }

    // MARK: - File Import Handler

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            appState.show(error.localizedDescription, warning: true)
        case .success(let urls):
            var totalAdded = 0
            var totalSkipped = 0
            let existing = Set(store.samples.map(\.dedupeKey))
            for url in urls {
                do {
                    let summary = try SMSLabImporter.importFile(at: url, existingKeys: existing)
                    let res = store.addImportedSamples(summary.importedSamples)
                    totalAdded += res.added
                    totalSkipped += res.skippedApprovedOrDuplicate + summary.skippedEmptyOrDuplicate
                } catch {
                    appState.show(error.localizedDescription, warning: true)
                    return
                }
            }
            appState.show("Imported \(totalAdded) SMS (\(totalSkipped) duplicates skipped)")
        }
    }
}

// MARK: - Sample Inspector & Expected vs Actual Editor Sheet

struct SMSLabSampleInspectorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState
    let sample: LabSample
    let snapshot: LabSnapshot?
    let store: SMSLabStore

    @State private var sender: String
    @State private var isNonTransaction: Bool
    @State private var expectedBank: String
    @State private var expectedAmount: String
    @State private var expectedType: String
    @State private var expectedDirection: String
    @State private var expectedAccount: String
    @State private var expectedCategory: String
    @State private var saveAsPermanentTestCase: Bool
    @State private var unlockApprovedConfirm = false

    init(sample: LabSample, snapshot: LabSnapshot?, store: SMSLabStore) {
        self.sample = sample
        self.snapshot = snapshot
        self.store = store
        _sender = State(initialValue: sample.sender ?? "")
        _isNonTransaction = State(initialValue: sample.expected.nonTransaction == true)
        _expectedBank = State(initialValue: sample.expected.bank ?? snapshot?.bank ?? "")
        _expectedAmount = State(initialValue: sample.expected.amount.map { String(format: "%.3f", $0) } ?? (snapshot?.amount.map { String(format: "%.3f", $0) } ?? ""))
        _expectedType = State(initialValue: sample.expected.type ?? snapshot?.type ?? SMSTransactionType.expense.rawValue)
        _expectedDirection = State(initialValue: sample.expected.direction ?? snapshot?.direction ?? SMSDirection.outgoing.rawValue)
        _expectedAccount = State(initialValue: sample.expected.account ?? snapshot?.account ?? "")
        _expectedCategory = State(initialValue: sample.expected.category ?? snapshot?.category ?? SpendCategory.other.rawValue)
        _saveAsPermanentTestCase = State(initialValue: true)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Raw SMS Message") {
                    Text(sample.text)
                        .font(.footnote.monospaced())
                        .foregroundStyle(Theme.ink)
                        .textSelection(.enabled)
                    HStack {
                        Text("Sender / Shortcode")
                        Spacer()
                        TextField("e.g. BisB, BBK, 88188", text: $sender)
                            .multilineTextAlignment(.trailing)
                    }
                }

                if let snapshot {
                    Section("Production Parser Reasoning (\(snapshot.engineLabel))") {
                        ForEach(snapshot.reasoning, id: \.self) { r in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: r.symbol)
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(Theme.cobalt)
                                    .frame(width: 18)
                                Text(r.text)
                                    .font(.caption)
                                    .foregroundStyle(Theme.ink)
                            }
                        }
                    }
                }

                Section {
                    if sample.isTestCase {
                        HStack(spacing: 8) {
                            Image(systemName: "lock.shield.fill")
                                .foregroundStyle(Theme.cobalt)
                            Text("This SMS is a locked permanent test case. Automatic imports cannot overwrite it.")
                                .font(.caption)
                                .foregroundStyle(Theme.secondaryInk)
                        }
                    }

                    Toggle("Not a transaction (OTP / Promo / Declined)", isOn: $isNonTransaction)

                    if !isNonTransaction {
                        Picker("Expected Bank", selection: $expectedBank) {
                            Text("Unspecified").tag("")
                            ForEach(BahrainBankCatalog.bahrainBanks, id: \.self) { b in
                                Text(b).tag(b)
                            }
                        }

                        HStack {
                            Text("Expected Amount")
                            Spacer()
                            TextField("0.000", text: $expectedAmount)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                        }

                        Picker("Transaction Type", selection: $expectedType) {
                            ForEach(SMSTransactionType.allCases) { t in
                                Text(t.title).tag(t.rawValue)
                            }
                        }
                        .onChange(of: expectedType) { _, newValue in
                            if let t = SMSTransactionType(rawValue: newValue) {
                                expectedDirection = SMSDirection.from(t).rawValue
                            }
                        }

                        Picker("Direction", selection: $expectedDirection) {
                            ForEach(SMSDirection.allCases) { d in
                                Text(d.title).tag(d.rawValue)
                            }
                        }

                        HStack {
                            Text("Account / Card Last 4")
                            Spacer()
                            TextField("Optional (e.g. 4412)", text: $expectedAccount)
                                .multilineTextAlignment(.trailing)
                        }

                        Picker("Category", selection: $expectedCategory) {
                            ForEach(SpendCategory.allCases) { c in
                                Text(c.title).tag(c.rawValue)
                            }
                        }
                    }

                    Toggle("Save as Permanent Test Case", isOn: $saveAsPermanentTestCase)
                } header: {
                    Text("Expected Classification (Ground Truth)")
                }

                if sample.isTestCase {
                    Section {
                        Button("Unlock Test Case") {
                            store.unlockTestCase(id: sample.id)
                            dismiss()
                        }
                        .foregroundStyle(Theme.warning)
                    }
                }
            }
            .navigationTitle("Inspect & Label SMS")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveExpected()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }

    private func saveExpected() {
        var exp = LabExpected()
        if isNonTransaction {
            exp.nonTransaction = true
        } else {
            let b = expectedBank.trimmingCharacters(in: .whitespacesAndNewlines)
            if !b.isEmpty { exp.bank = b }
            if let a = Money.parse(expectedAmount), a > 0 { exp.amount = a }
            if !expectedType.isEmpty { exp.type = expectedType }
            if !expectedDirection.isEmpty { exp.direction = expectedDirection }
            let acc = String(expectedAccount.filter(\.isNumber).suffix(4))
            if !acc.isEmpty { exp.account = acc }
            if !expectedCategory.isEmpty { exp.category = expectedCategory }
        }
        let cleanSender = sender.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = store.updateSample(
            id: sample.id,
            sender: cleanSender.isEmpty ? nil : cleanSender,
            expected: exp,
            promoteToTestCase: saveAsPermanentTestCase,
            allowOverwriteApproved: true
        )
        appState.show(saveAsPermanentTestCase ? "Saved correction & locked as permanent test case" : "Updated expected labels")
        dismiss()
    }
}

// MARK: - Paste Bulk SMS / CSV Sheet

struct SMSLabPasteImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var rawText = ""
    @State private var errorMessage: String? = nil
    var onImported: (SMSBulkImportSummary) -> Void

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("Paste raw SMS messages (one per line or separated by blank lines) or CSV rows with headers (`sender,sms,bank,amount,type,direction,account,category`).")
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryInk)

                TextEditor(text: $rawText)
                    .font(.footnote.monospaced())
                    .padding(8)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .frame(minHeight: 240)

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(Theme.negative)
                }

                Spacer()
            }
            .padding(16)
            .canvasBackground()
            .navigationTitle("Paste Bulk SMS / CSV")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") {
                        do {
                            let summary = try SMSLabImporter.importRawText(rawText)
                            onImported(summary)
                            dismiss()
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }
                    .fontWeight(.semibold)
                    .disabled(rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

// MARK: - Manual Rule Editor Sheet

struct SMSLabRuleEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    let kind: SMSTestingLabView.AddRuleKind
    let store: SMSLabStore

    @State private var senderID = ""
    @State private var selectedBank = BahrainBankCatalog.bahrainBanks.first ?? "BisB"
    @State private var patternName = ""
    @State private var regexPattern = ""
    @State private var setType = SMSTransactionType.expense.rawValue
    @State private var setCategory = SpendCategory.other.rawValue
    @State private var keyword = ""
    @State private var approveImmediately = true

    var body: some View {
        NavigationStack {
            Form {
                switch kind {
                case .sender:
                    Section("Sender → Bank Format") {
                        TextField("SMS Sender ID or Shortcode (e.g. 88188, BBK)", text: $senderID)
                        Picker("Bank", selection: $selectedBank) {
                            ForEach(BahrainBankCatalog.bahrainBanks, id: \.self) { b in
                                Text(b).tag(b)
                            }
                        }
                    }
                case .pattern:
                    Section("SMS Regex Pattern Rule") {
                        TextField("Rule Name (e.g. BisB Compact Debit)", text: $patternName)
                        TextField("Regex (use (?<amount>...) or (?<account>...))", text: $regexPattern)
                            .font(.footnote.monospaced())
                        Picker("Bank", selection: $selectedBank) {
                            Text("Any Bank").tag("")
                            ForEach(BahrainBankCatalog.bahrainBanks, id: \.self) { b in
                                Text(b).tag(b)
                            }
                        }
                        Picker("Transaction Type", selection: $setType) {
                            ForEach(SMSTransactionType.allCases) { t in
                                Text(t.title).tag(t.rawValue)
                            }
                        }
                        Picker("Category", selection: $setCategory) {
                            ForEach(SpendCategory.allCases) { c in
                                Text(c.title).tag(c.rawValue)
                            }
                        }
                    }
                case .keyword:
                    Section("Merchant Keyword → Category") {
                        TextField("Merchant Keyword (e.g. manama roastery)", text: $keyword)
                        Picker("Category", selection: $setCategory) {
                            ForEach(SpendCategory.allCases) { c in
                                Text(c.title).tag(c.rawValue)
                            }
                        }
                    }
                }

                Section {
                    Toggle("Mark as Approved immediately", isOn: $approveImmediately)
                }
            }
            .navigationTitle("Add Knowledge Rule")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save Rule") {
                        save()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }

    private func save() {
        let status: SMSRuleStatus = approveImmediately ? .approved : .draft
        switch kind {
        case .sender:
            let s = senderID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !s.isEmpty else { return }
            store.addOrUpdateSenderRule(SMSSenderBankRule(sender: s, bank: selectedBank, status: status, note: "Manual sender format"))
        case .pattern:
            let p = regexPattern.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !p.isEmpty, (try? NSRegularExpression(pattern: p)) != nil else { return }
            let name = patternName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Custom Pattern" : patternName
            store.addOrUpdatePatternRule(
                SMSPatternRule(
                    name: name,
                    pattern: p,
                    bankScope: selectedBank.isEmpty ? nil : selectedBank,
                    setBank: selectedBank.isEmpty ? nil : selectedBank,
                    setType: setType,
                    setCategory: setCategory,
                    priority: 15,
                    status: status,
                    note: "Manual SMS pattern"
                )
            )
        case .keyword:
            let k = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !k.isEmpty else { return }
            store.addOrUpdateKeywordRule(SMSCategoryKeywordRule(keyword: k, category: setCategory, status: status, note: "Manual keyword rule"))
        }
        dismiss()
    }
}
