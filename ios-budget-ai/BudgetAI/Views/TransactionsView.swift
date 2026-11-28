import SwiftUI
import SwiftData
import UIKit

enum TxFilter: String, CaseIterable, Identifiable {
    case all = "All", income = "Income", expenses = "Expenses", transfers = "Transfers", review = "Review"
    var id: String { rawValue }
}

enum TxDateRange: String, CaseIterable, Identifiable {
    case all = "All time", thisCycle = "This month", lastCycle = "Last month", last7 = "Last 7 days", last30 = "Last 30 days", custom = "Custom"
    var id: String { rawValue }
}

struct TxFilterState: Equatable, Hashable {
    var kind: TxFilter = .all
    var range: TxDateRange = .thisCycle
    var customStart: Date = Calendar.current.date(byAdding: .day, value: -30, to: .now) ?? .now
    var customEnd: Date = .now
    var categories: Set<String> = []
    var accounts: Set<UUID> = []
    var smsOnly = false
    var duplicatesOnly = false

    /// Number of filters beyond the quick type chips (defaulting to the current cycle).
    var activeCount: Int {
        (range == .thisCycle ? 0 : 1) + (categories.isEmpty ? 0 : 1) + (accounts.isEmpty ? 0 : 1) + (smsOnly ? 1 : 0) + (duplicatesOnly ? 1 : 0)
    }

    var interval: DateInterval? {
        let cal = Calendar.current
        switch range {
        case .all: return nil
        case .thisCycle: return Cycle.interval(containing: .now)
        case .lastCycle:
            let current = Cycle.interval(containing: .now)
            return Cycle.interval(containing: current.start.addingTimeInterval(-1))
        case .last7: return DateInterval(start: cal.startOfDay(for: cal.date(byAdding: .day, value: -6, to: .now) ?? .now), end: .now.addingTimeInterval(86_400))
        case .last30: return DateInterval(start: cal.startOfDay(for: cal.date(byAdding: .day, value: -29, to: .now) ?? .now), end: .now.addingTimeInterval(86_400))
        case .custom:
            let s = cal.startOfDay(for: min(customStart, customEnd))
            let e = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: max(customStart, customEnd))) ?? customEnd
            return DateInterval(start: s, end: e)
        }
    }

    var rangeLabel: String {
        switch range {
        case .thisCycle, .lastCycle: return interval.map { Cycle.label($0) } ?? range.rawValue
        case .custom: return "\(customStart.formatted(.dateTime.day().month(.abbreviated))) – \(customEnd.formatted(.dateTime.day().month(.abbreviated)))"
        default: return range.rawValue
        }
    }

    func matches(_ tx: MoneyTransaction, ignoringDates: Bool = false) -> Bool {
        matches(tx, interval: ignoringDates ? nil : self.interval, ignoringDates: ignoringDates)
    }

    func matches(_ tx: MoneyTransaction, interval activeInterval: DateInterval?, ignoringDates: Bool = false) -> Bool {
        switch kind {
        case .all: break
        case .review:
            if !tx.isPending && !tx.isPossibleDuplicate && !tx.needsBillReview && !tx.hasRuleConflict
                && !SharedExpenseAdjustmentStore.shared.isMonitoredForReview(tx.id) {
                return false
            }
        case .income: if !tx.isOrdinaryIncome && !(!tx.isTransfer && tx.isIncome) { return false }
        case .expenses: if !tx.isSpending { return false }
        case .transfers: if !tx.isTransfer { return false }
        }
        if !ignoringDates, let activeInterval, !(tx.date >= activeInterval.start && tx.date < activeInterval.end) { return false }
        if !categories.isEmpty && !categories.contains(tx.categoryRaw) && !categories.contains(tx.subcategoryKey) { return false }
        if !accounts.isEmpty {
            let hit = tx.accountID.map(accounts.contains) ?? false
            let hitTo = tx.toAccountID.map(accounts.contains) ?? false
            if !hit && !hitTo { return false }
        }
        if smsOnly && tx.source != .sms { return false }
        if duplicatesOnly && !tx.isPossibleDuplicate { return false }
        return true
    }
}

enum TxViewMode: String { case list, calendar }

struct TransactionsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var context
    @Query(sort: \MoneyTransaction.date, order: .reverse) private var transactions: [MoneyTransaction]
    @Query(sort: \Account.createdAt) private var accounts: [Account]
    @AppStorage(Keys.currency) private var currency = "BHD"
    @AppStorage(Keys.cycleStartDay) private var cycleStartDay = 1
    @State private var query = ""
    @State private var filters = TxFilterState()
    @State private var mode: TxViewMode = .list
    @State private var showFilters = false
    @State private var showStatementImport = false
    @State private var showStatementExport = false
    @State private var categorizing = false
    @State private var calendarMonth = Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: .now)) ?? .now
    @State private var selectedDay: Date = Calendar.current.startOfDay(for: .now)
    @State private var approvedTick = 0
    @State private var cachedSnapshot = TxViewSnapshot()
    @State private var lastSnapshotKey: Int? = nil

    private var currentSnapshotKey: Int {
        var hasher = Hasher()
        hasher.combine(transactions.count)
        hasher.combine(appState.dataVersion)
        hasher.combine(filters)
        hasher.combine(query)
        hasher.combine(mode.rawValue)
        hasher.combine(cycleStartDay)
        hasher.combine(SharedExpenseAdjustmentStore.shared.monitoredReviewTransactionIDs.count)
        return hasher.finalize()
    }

    private func refreshSnapshotIfNeeded() {
        let key = currentSnapshotKey
        guard key != lastSnapshotKey else { return }
        cachedSnapshot = computeViewSnapshot()
        lastSnapshotKey = key
    }

    private func matchesSearch(_ tx: MoneyTransaction) -> Bool {
        guard !query.isEmpty else { return true }
        return tx.merchant.localizedCaseInsensitiveContains(query)
            || tx.category.title.localizedCaseInsensitiveContains(query)
            || tx.note.localizedCaseInsensitiveContains(query)
    }

    private struct TxViewSnapshot {
        var filtered: [MoneyTransaction] = []
        var pending: [MoneyTransaction] = []
        var needsReview: [MoneyTransaction] = []
        var grouped: [(day: Date, items: [MoneyTransaction])] = []
        var totals: (income: Double, spent: Double, transferIn: Double, transferOut: Double) = (0, 0, 0, 0)
        var hasUncategorizedOther = false
    }

    private func computeViewSnapshot() -> TxViewSnapshot {
        var snap = TxViewSnapshot()
        let cal = Calendar.current
        let ignoreDatesForReview = mode == .calendar || filters.range == .thisCycle
        let ignoreDates = (filters.kind == .review) ? ignoreDatesForReview : (mode == .calendar)
        let activeInterval = ignoreDates ? nil : filters.interval
        let showSummary = mode == .list && (filters.activeCount > 0 || filters.kind != .all)

        var groupsByDay: [Date: [MoneyTransaction]] = [:]
        var dayKeys: [Date] = []

        for tx in transactions {
            let isMonitoredShared = SharedExpenseAdjustmentStore.shared.isMonitoredForReview(tx.id)
            if tx.isPending {
                snap.pending.append(tx)
                snap.needsReview.append(tx)
            } else if tx.isPossibleDuplicate || isMonitoredShared {
                snap.needsReview.append(tx)
            }

            if !snap.hasUncategorizedOther && tx.categoryRaw == SpendCategory.other.rawValue && !tx.isIncome {
                snap.hasUncategorizedOther = true
            }

            let passesKindScope: Bool = {
                switch filters.kind {
                case .review: return tx.isPending || tx.isPossibleDuplicate || tx.needsBillReview || tx.hasRuleConflict || isMonitoredShared
                case .all: return true
                case .income, .expenses, .transfers: return !tx.isPending
                }
            }()
            guard passesKindScope,
                  filters.matches(tx, interval: activeInterval, ignoringDates: ignoreDates),
                  matchesSearch(tx) else { continue }

            snap.filtered.append(tx)

            if showSummary && !tx.isPending {
                if tx.isOrdinaryIncome {
                    snap.totals.income += tx.amount
                } else if tx.isSpending {
                    snap.totals.spent += tx.amount
                } else if tx.isTransferIn {
                    snap.totals.transferIn += tx.amount
                } else if tx.isTransferOut {
                    snap.totals.transferOut += tx.amount
                }
            }

            if mode == .list {
                let day = cal.startOfDay(for: tx.date)
                if groupsByDay[day] == nil { dayKeys.append(day) }
                groupsByDay[day, default: []].append(tx)
            }
        }

        if mode == .list {
            snap.grouped = dayKeys.sorted(by: >).compactMap { day in
                guard let items = groupsByDay[day] else { return nil }
                return (day: day, items: items)
            }
        }

        return snap
    }

    var body: some View {
        let _ = cycleStartDay
        let snapKey = currentSnapshotKey
        let snap = (lastSnapshotKey == snapKey) ? cachedSnapshot : computeViewSnapshot()
        let currentFiltered = snap.filtered
        let currentPending = snap.pending
        let currentNeedsReview = snap.needsReview
        let currentGrouped = snap.grouped
        let showSummary = mode == .list && (filters.activeCount > 0 || filters.kind != .all) && !currentFiltered.isEmpty
        let currentTotals = snap.totals

        NavigationStack {
            VStack(spacing: 0) {
                VStack(spacing: 8) {
                    searchPill
                    chips(needsReviewCount: currentNeedsReview.count)
                }
                .padding(.horizontal, 16)
                .padding(.top, 6)
                .padding(.bottom, filters.activeCount > 0 ? 4 : 6)

                if filters.activeCount > 0 {
                    activeChips
                }

                List {

                if filters.kind == .review {
                    if currentFiltered.isEmpty {
                        Section {
                            HStack(spacing: 12) {
                                Image(systemName: "shield.lefthalf.filled.badge.checkmark")
                                    .font(.title2)
                                    .foregroundStyle(Theme.warning)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("Needs Review")
                                        .font(.headline)
                                        .foregroundStyle(Theme.ink)
                                    Text("Transactions waiting for approval or flagged with duplicate SMS reference codes appear here.")
                                        .font(.caption)
                                        .foregroundStyle(Theme.secondaryInk)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    } else {
                        let pendingFiltered = currentFiltered.filter(\.isPending)
                        let duplicateFiltered = currentFiltered.filter(\.isPossibleDuplicate)
                        let monitoredSharedFiltered = currentFiltered.filter { SharedExpenseAdjustmentStore.shared.isMonitoredForReview($0.id) }
                        Section {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(currentFiltered.count) transaction\(currentFiltered.count == 1 ? "" : "s") to review")
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(Theme.ink)
                                    let parts: [String] = [
                                        pendingFiltered.isEmpty ? nil : "\(pendingFiltered.count) pending approval",
                                        duplicateFiltered.isEmpty ? nil : "\(duplicateFiltered.count) duplicate\(duplicateFiltered.count == 1 ? "" : "s")",
                                        monitoredSharedFiltered.isEmpty ? nil : "\(monitoredSharedFiltered.count) shared reimbursement\(monitoredSharedFiltered.count == 1 ? "" : "s")"
                                    ].compactMap { $0 }
                                    if !parts.isEmpty {
                                        Text(parts.joined(separator: " · "))
                                            .font(.caption)
                                            .foregroundStyle(Theme.secondaryInk)
                                    }
                                }
                                Spacer()
                                if !pendingFiltered.isEmpty {
                                    Button("Approve all") {
                                        let items = pendingFiltered
                                        withAnimation { _ = Ledger.approveAll(items, context: context) }
                                        approvedTick += 1
                                        appState.show("Approved \(items.count) transaction\(items.count == 1 ? "" : "s")")
                                    }
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(Theme.cobalt)
                                } else if !duplicateFiltered.isEmpty {
                                    Button("Keep all") {
                                        let items = duplicateFiltered
                                        withAnimation {
                                            for tx in items { tx.isPossibleDuplicate = false }
                                            try? context.save()
                                            Ledger.notifyDataChanged()
                                        }
                                        approvedTick += 1
                                        appState.show("Kept \(items.count) transaction\(items.count == 1 ? "" : "s")")
                                    }
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(Theme.cobalt)
                                }
                            }
                        }
                    }
                } else if filters.kind == .all && !currentNeedsReview.isEmpty && query.isEmpty {
                    Section {
                        Button {
                            withAnimation(.snappy) { filters.kind = .review }
                        } label: {
                            HStack(spacing: 12) {
                                ZStack {
                                    Circle()
                                        .fill(Theme.warning.opacity(0.16))
                                        .frame(width: 38, height: 38)
                                    Image(systemName: "clock.badge.exclamationmark.fill")
                                        .font(.system(size: 18))
                                        .foregroundStyle(Theme.warning)
                                }
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("\(currentNeedsReview.count) needing review")
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(Theme.ink)
                                    Text("Tap to open Needs Review tab, approve pending SMS, or resolve duplicates.")
                                        .font(.caption)
                                        .foregroundStyle(Theme.secondaryInk)
                                }
                                Spacer()
                                if !currentPending.isEmpty {
                                    Button("Approve all") {
                                        let count = currentPending.count
                                        withAnimation { _ = Ledger.approveAll(currentPending, context: context) }
                                        approvedTick += 1
                                        appState.show("Approved \(count) transaction\(count == 1 ? "" : "s")")
                                    }
                                    .font(.caption.weight(.semibold))
                                    .buttonStyle(.bordered)
                                    .tint(Theme.positive)
                                } else {
                                    Image(systemName: "chevron.right")
                                        .font(.footnote.weight(.semibold))
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                        .buttonStyle(.plain)
                    }
                }

                if mode == .list {
                    if showSummary {
                        Section { summaryRow(count: currentFiltered.count, totals: currentTotals) }
                    }
                    listSections(grouped: currentGrouped)
                } else {
                    calendarSections(filtered: currentFiltered)
                }
            }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .canvasBackground()
            .navigationTitle("Transactions")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: UUID.self) { id in
                if let tx = transactions.first(where: { $0.id == id }) {
                    TransactionDetailView(tx: tx)
                }
            }
            .overlay {
                if mode == .list && currentFiltered.isEmpty && filters.kind != .review {
                    if transactions.isEmpty {
                        ContentUnavailableView {
                            Label("No transactions yet", systemImage: "list.bullet.rectangle")
                        } description: {
                            Text("Add one manually or paste a bank SMS. Set up automatic SMS import in Profile.")
                        } actions: {
                            Button("Add transaction") { appState.showAddTransaction = true }
                                .buttonStyle(.borderedProminent)
                        }
                    } else if !query.isEmpty {
                        ContentUnavailableView.search(text: query)
                    } else {
                        ContentUnavailableView {
                            Label("Nothing matches", systemImage: "line.3.horizontal.decrease.circle")
                        } description: {
                            Text("Try a different date range or fewer filters.")
                        } actions: {
                            if filters.range == .thisCycle && filters.activeCount == 0 && filters.kind == .all {
                                Button("Show all time") {
                                    withAnimation(.snappy) { filters = TxFilterState(kind: filters.kind, range: .all) }
                                }
                            } else {
                                Button("Clear filters") {
                                    withAnimation(.snappy) { filters = TxFilterState(kind: filters.kind) }
                                }
                            }
                        }
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    DrawerMenuToolbarButtons()
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if snap.hasUncategorizedOther && GeminiAccount.isConfigured {
                        Button {
                            Task { await recategorize() }
                        } label: {
                            if categorizing { ProgressView() } else { Image(systemName: "sparkles") }
                        }
                        .accessibilityLabel("Categorize with AI")
                        .disabled(categorizing)
                    }

                    Button {
                        mode = mode == .list ? .calendar : .list
                    } label: {
                        Image(systemName: mode == .list ? "calendar" : "list.bullet")
                    }
                    .accessibilityLabel(mode == .list ? "Calendar view" : "List view")

                    Button { showFilters = true } label: {
                        Image(systemName: filters.activeCount > 0 ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                    }
                    .accessibilityLabel("Filters")
                }
            }
            .sheet(isPresented: $showFilters) {
                TransactionFilterSheet(filters: $filters, accounts: accounts)
            }
            .sheet(isPresented: $showStatementImport) {
                StatementImportSheet()
            }
            .sheet(isPresented: $showStatementExport) {
                StatementExportSheet()
            }
            .onAppear {
                applyRequestedFilterIfNeeded()
                refreshSnapshotIfNeeded()
            }
            .onChange(of: appState.requestedTransactionsFilter) { _, _ in
                applyRequestedFilterIfNeeded()
                refreshSnapshotIfNeeded()
            }
            .onChange(of: currentSnapshotKey) { _, _ in
                refreshSnapshotIfNeeded()
            }
            .sensoryFeedback(.success, trigger: approvedTick)
            .sensoryFeedback(.selection, trigger: mode)
        }
    }

    private func applyRequestedFilterIfNeeded() {
        guard let requested = appState.requestedTransactionsFilter else { return }
        withAnimation(.snappy) {
            filters = TxFilterState(kind: requested, range: requested == .review ? .all : .thisCycle)
            mode = .list
        }
        appState.requestedTransactionsFilter = nil
    }

    private func approve(_ tx: MoneyTransaction) {
        var result = LedgerResult()
        withAnimation { result = Ledger.approve(tx, context: context) }
        approvedTick += 1
        appState.report(result, base: "Approved \(Money.format(tx.amount, currency))")
    }

    // MARK: List

    @ViewBuilder
    private func listSections(grouped: [(day: Date, items: [MoneyTransaction])]) -> some View {
        ForEach(grouped, id: \.day) { group in
            Section {
                ForEach(group.items) { tx in row(tx) }
            } header: {
                Text(dayTitle(group.day))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.secondaryInk)
                    .textCase(nil)
            }
        }
    }

    private func row(_ tx: MoneyTransaction) -> some View {
        NavigationLink(value: tx.id) {
            TransactionRow(tx: tx, currency: currency)
        }
        .listRowBackground(
            tx.isPending ? Theme.warning.opacity(0.08) :
            (tx.isPossibleDuplicate ? Theme.negative.opacity(0.07) : Theme.surface)
        )
        .swipeActions(edge: .trailing) {
            if tx.isPending {
                Button(role: .destructive) {
                    withAnimation { Ledger.delete(tx, context: context) }
                    appState.show("Rejected")
                } label: { Label("Reject", systemImage: "xmark") }
            } else {
                Button(role: .destructive) {
                    withAnimation { Ledger.delete(tx, context: context) }
                } label: { Label("Delete", systemImage: "trash") }
            }
        }
        .swipeActions(edge: .leading) {
            if tx.isPending {
                Button {
                    approve(tx)
                } label: { Label("Approve & update account", systemImage: "checkmark.circle.fill") }
                .tint(Theme.positive)
            } else if tx.isPossibleDuplicate {
                Button {
                    tx.isPossibleDuplicate = false
                    try? context.save()
                    Ledger.notifyDataChanged()
                } label: { Label("Keep", systemImage: "checkmark") }
                .tint(Theme.positive)
            } else if SharedExpenseAdjustmentStore.shared.isMonitoredForReview(tx.id) {
                Button {
                    SharedExpenseAdjustmentStore.shared.setMonitoredForReview(tx.id, monitored: false)
                    Ledger.notifyDataChanged()
                    appState.show("Removed from Review")
                } label: { Label("Done Reviewing", systemImage: "checkmark.circle") }
                .tint(Theme.positive)
            }
        }
    }

    private func summaryRow(count: Int, totals: (income: Double, spent: Double, transferIn: Double, transferOut: Double)) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(count) transaction\(count == 1 ? "" : "s")")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Theme.secondaryInk)
                    .animatedNumber(Double(count))
                Text(filters.rangeLabel).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
            }
            Spacer()
            if filters.kind == .transfers {
                VStack(alignment: .trailing, spacing: 2) {
                    HStack(spacing: 4) {
                        Text("In")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Theme.secondaryInk)
                        Text(Money.format(totals.transferIn, currency, signed: true))
                            .foregroundStyle(Theme.positive)
                            .animatedNumber(totals.transferIn)
                    }
                    HStack(spacing: 4) {
                        Text("Out")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Theme.secondaryInk)
                        Text(Money.format(-totals.transferOut, currency, signed: true))
                            .foregroundStyle(Theme.ink)
                            .animatedNumber(-totals.transferOut)
                    }
                }
                .font(.subheadline.weight(.semibold).monospacedDigit())
            } else {
                VStack(alignment: .trailing, spacing: 2) {
                    if totals.income > 0 {
                        Text(Money.format(totals.income, currency, signed: true))
                            .foregroundStyle(Theme.positive)
                            .animatedNumber(totals.income)
                    }
                    Text(Money.format(-totals.spent, currency, signed: true))
                        .foregroundStyle(Theme.ink)
                        .animatedNumber(-totals.spent)
                }
                .font(.subheadline.weight(.semibold).monospacedDigit())
            }
        }
    }

    // MARK: Calendar

    @ViewBuilder
    private func calendarSections(filtered: [MoneyTransaction]) -> some View {
        let cal = Calendar.current
        let dayTotals = Dictionary(grouping: filtered) { cal.startOfDay(for: $0.date) }
        Section {
            TransactionCalendar(month: $calendarMonth, selected: $selectedDay, totals: dayTotals.mapValues { items in
                items.reduce((0.0, 0.0)) { acc, tx in
                    if tx.isOrdinaryIncome { return (acc.0 + tx.amount, acc.1) }
                    if tx.isSpending { return (acc.0, acc.1 + tx.amount) }
                    return acc
                }
            }, currency: currency)
            .listRowInsets(EdgeInsets(top: 14, leading: 12, bottom: 14, trailing: 12))
        }
        let items = dayTotals[selectedDay] ?? []
        Section {
            if items.isEmpty {
                Text("No transactions on this day").foregroundStyle(Theme.secondaryInk)
            } else {
                ForEach(items) { tx in row(tx) }
            }
        } header: {
            HStack {
                Text(dayTitle(selectedDay))
                Spacer()
                let spent = items.filter { !$0.isIncome && !$0.isTransfer }.reduce(0) { $0 + $1.amount }
                if spent > 0 { Text(Money.format(spent, currency)).monospacedDigit() }
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Theme.secondaryInk)
            .textCase(nil)
        }
    }

    // MARK: Chips

    private var searchPill: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Theme.secondaryInk)
            TextField("Search transactions", text: $query)
                .font(.subheadline)
                .foregroundStyle(Theme.ink)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondaryInk)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Theme.surface, in: Capsule())
        .shadow(color: .black.opacity(0.03), radius: 6, y: 2)
    }

    private func chips(needsReviewCount: Int) -> some View {
        HStack(spacing: 2) {
            ForEach(TxFilter.allCases) { f in
                let isSelected = filters.kind == f
                Button {
                    withAnimation(.snappy) { filters.kind = f }
                } label: {
                    HStack(spacing: 3) {
                        Text(f.rawValue)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                        if f == .review && needsReviewCount > 0 {
                            Text("\(needsReviewCount)")
                                .font(.caption2.bold().monospacedDigit())
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(isSelected ? .white.opacity(0.28) : Theme.warning, in: Capsule())
                                .foregroundStyle(.white)
                                .fixedSize()
                        }
                    }
                    .font(.caption.weight(isSelected ? .semibold : .medium))
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 8)
                    .foregroundStyle(isSelected ? .white : Theme.secondaryInk)
                    .background(
                        isSelected ? (f == .review ? Theme.warning : Theme.cobalt) : Color.clear,
                        in: Capsule()
                    )
                    .contentShape(Capsule())
                }
                .buttonStyle(PressableStyle())
            }
        }
        .padding(4)
        .frame(maxWidth: .infinity)
        .background(Theme.surface, in: Capsule())
        .shadow(color: .black.opacity(0.03), radius: 6, y: 2)
        .sensoryFeedback(.selection, trigger: filters.kind)
    }

    private var activeChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if filters.range != .thisCycle {
                    removable(filters.rangeLabel, symbol: "calendar") { filters.range = .thisCycle }
                }
                if !filters.categories.isEmpty {
                    let names = filters.categories.compactMap { SpendCategory(rawValue: $0)?.title }.sorted()
                    removable(names.count == 1 ? names[0] : "\(names.count) categories", symbol: "square.grid.2x2") { filters.categories = [] }
                }
                if !filters.accounts.isEmpty {
                    let names = accounts.filter { filters.accounts.contains($0.id) }.map(\.name)
                    removable(names.count == 1 ? names[0] : "\(names.count) accounts", symbol: "creditcard") { filters.accounts = [] }
                }
                if filters.smsOnly { removable("From SMS", symbol: "message") { filters.smsOnly = false } }
                if filters.duplicatesOnly { removable("Duplicates", symbol: "exclamationmark.circle") { filters.duplicatesOnly = false } }
                Button("Clear all") { withAnimation(.snappy) { filters = TxFilterState(kind: filters.kind) } }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.cobalt)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 6)
        }
    }

    private func removable(_ title: String, symbol: String, remove: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.snappy) { remove() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.caption)
                Text(title).lineLimit(1)
                Image(systemName: "xmark").font(.caption2.weight(.bold))
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(Theme.cobalt)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Theme.cobaltSoft, in: Capsule())
        }
        .buttonStyle(PressableStyle())
    }

    private func dayTitle(_ day: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(day) { return "Today" }
        if cal.isDateInYesterday(day) { return "Yesterday" }
        return DateFormatCache.dayHeader(day)
    }

    private func recategorize() async {
        categorizing = true
        defer { categorizing = false }
        let targets = transactions.filter { $0.category == .other && !$0.isIncome }
        let names = Array(Set(targets.map(\.merchant))).prefix(40)
        do {
            let map = try await AIService.categorize(merchants: Array(names))
            var count = 0
            for tx in targets {
                if let cat = map[tx.merchant], cat != .other {
                    tx.category = cat
                    tx.aiCategorized = true
                    if tx.source == .sms && tx.smsTransactionType == .unknown {
                        tx.smsTransactionType = tx.isIncome ? .income : .expense
                    }
                    count += 1
                }
            }
            try? context.save()
            appState.show(count > 0 ? "AI categorized \(count) transaction\(count == 1 ? "" : "s")" : "Nothing new to categorize")
        } catch {
            appState.show(error.localizedDescription, warning: true)
        }
    }
}

// MARK: - Calendar

struct TransactionCalendar: View {
    @Binding var month: Date
    @Binding var selected: Date
    let totals: [Date: (Double, Double)]
    let currency: String

    private let cal = Calendar.current

    private var days: [Date?] {
        guard let range = cal.range(of: .day, in: .month, for: month) else { return [] }
        let weekday = cal.component(.weekday, from: month)
        let lead = (weekday - cal.firstWeekday + 7) % 7
        var cells: [Date?] = Array(repeating: nil, count: lead)
        for d in range { cells.append(cal.date(byAdding: .day, value: d - 1, to: month)) }
        return cells
    }

    private var monthSpent: Double {
        totals.filter { cal.isDate($0.key, equalTo: month, toGranularity: .month) }.reduce(0) { $0 + $1.value.1 }
    }

    private var maxSpent: Double {
        max(totals.filter { cal.isDate($0.key, equalTo: month, toGranularity: .month) }.map(\.value.1).max() ?? 0, 1)
    }

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(month.formatted(.dateTime.month(.wide).year()))
                        .font(.headline).foregroundStyle(Theme.ink)
                    Text("Spent \(Money.format(monthSpent, currency))")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(Theme.secondaryInk)
                        .animatedNumber(monthSpent)
                }
                Spacer()
                Button { shift(-1) } label: { Image(systemName: "chevron.left").frame(width: 34, height: 34) }
                    .accessibilityLabel("Previous month")
                Button { shift(1) } label: { Image(systemName: "chevron.right").frame(width: 34, height: 34) }
                    .accessibilityLabel("Next month")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.cobalt)
            .font(.body.weight(.semibold))

            let symbols = cal.veryShortWeekdaySymbols
            let ordered = Array(symbols[(cal.firstWeekday - 1)...] + symbols[..<(cal.firstWeekday - 1)])
            let allDays = days
            let weekCount = (allDays.count + 6) / 7
            VStack(spacing: 6) {
                HStack(spacing: 4) {
                    ForEach(Array(ordered.enumerated()), id: \.offset) { _, s in
                        Text(s)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Theme.secondaryInk)
                            .frame(maxWidth: .infinity)
                    }
                }
                ForEach(0..<weekCount, id: \.self) { week in
                    HStack(spacing: 4) {
                        ForEach(0..<7, id: \.self) { col in
                            let idx = week * 7 + col
                            if idx < allDays.count, let day = allDays[idx] {
                                cell(day)
                            } else {
                                Color.clear.frame(maxWidth: .infinity).frame(height: 48)
                            }
                        }
                    }
                }
            }
        }
        .sensoryFeedback(.selection, trigger: selected)
        .gesture(DragGesture(minimumDistance: 30).onEnded { v in
            if v.translation.width < -40 { shift(1) } else if v.translation.width > 40 { shift(-1) }
        })
    }

    private func cell(_ day: Date) -> some View {
        let t = totals[day] ?? (0, 0)
        let isSelected = cal.isDate(day, inSameDayAs: selected)
        let isToday = cal.isDateInToday(day)
        let intensity = t.1 / maxSpent
        return Button {
            selected = day
        } label: {
            VStack(spacing: 2) {
                Text("\(cal.component(.day, from: day))")
                    .font(.subheadline.weight(isToday || isSelected ? .bold : .regular))
                    .foregroundStyle(isSelected ? .white : (isToday ? Theme.cobalt : Theme.ink))
                Text(t.1 > 0 ? compact(t.1) : (t.0 > 0 ? "+" + compact(t.0) : " "))
                    .font(.system(size: 9, weight: .semibold).monospacedDigit())
                    .foregroundStyle(isSelected ? .white.opacity(0.85) : (t.1 > 0 ? Theme.negative : Theme.positive))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isSelected ? Theme.cobalt : Theme.negative.opacity(t.1 > 0 ? 0.05 + 0.18 * intensity : 0))
            }
            .overlay {
                if isToday && !isSelected {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.cobalt.opacity(0.5), lineWidth: 1)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(day.formatted(date: .abbreviated, time: .omitted)), spent \(Money.format(t.1, currency))")
    }

    private func compact(_ v: Double) -> String {
        if v >= 1000 { return Money.number(v / 1000, decimals: 1) + "k" }
        if v >= 100 { return Money.number(v, decimals: 0) }
        return Money.number(v, decimals: v < 10 ? 1 : 0)
    }

    private func shift(_ delta: Int) {
        guard let next = cal.date(byAdding: .month, value: delta, to: month) else { return }
        withAnimation(.snappy) {
            month = next
            selected = cal.isDate(next, equalTo: .now, toGranularity: .month) ? cal.startOfDay(for: .now) : next
        }
    }
}

// MARK: - Filter sheet

struct TransactionFilterSheet: View {
    @Binding var filters: TxFilterState
    let accounts: [Account]
    @Environment(\.dismiss) private var dismiss
    @State private var draft = TxFilterState()

    private var displayedCategories: [SpendCategory] {
        switch draft.kind {
        case .all, .review: return SpendCategory.allCases
        case .income: return SpendCategory.incomeCases
        case .expenses: return SpendCategory.expenseCases
        case .transfers: return SpendCategory.transferCases
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Date") {
                    Picker("Range", selection: $draft.range) {
                        ForEach(TxDateRange.allCases) { r in Text(r.rawValue).tag(r) }
                    }
                    if draft.range == .custom {
                        DatePicker("From", selection: $draft.customStart, displayedComponents: .date)
                        DatePicker("To", selection: $draft.customEnd, displayedComponents: .date)
                    }
                }
                Section("Type") {
                    Picker("Type", selection: $draft.kind) {
                        ForEach(TxFilter.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                Section {
                    ForEach(displayedCategories) { c in
                        let isSelected = draft.categories.contains(c.rawValue)
                        Button {
                            toggle(c.rawValue, in: &draft.categories)
                        } label: {
                            HStack(spacing: 12) {
                                CategoryIcon(category: c, size: 32)
                                Text(c.title)
                                    .foregroundStyle(Theme.ink)
                                Spacer()
                                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(isSelected ? Theme.cobalt : Color(hex: 0xC7CCD6))
                                    .font(.title3)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("Categories")
                }
                if !accounts.isEmpty {
                    Section("Accounts") {
                        ForEach(accounts) { a in
                            Button {
                                if draft.accounts.contains(a.id) { draft.accounts.remove(a.id) } else { draft.accounts.insert(a.id) }
                            } label: {
                                HStack(spacing: 12) {
                                    AccountIcon(account: a, size: 32)
                                    Text(a.name).foregroundStyle(Theme.ink)
                                    Spacer()
                                    Image(systemName: draft.accounts.contains(a.id) ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(draft.accounts.contains(a.id) ? Theme.cobalt : Color(hex: 0xC7CCD6))
                                        .font(.title3)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                Section {
                    Toggle("Only from bank SMS", isOn: $draft.smsOnly)
                    Toggle("Only possible duplicates", isOn: $draft.duplicatesOnly)
                }
            }
            .scrollContentBackground(.hidden)
            .canvasBackground()
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Reset") { withAnimation(.snappy) { draft = TxFilterState() } }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Show results") {
                        withAnimation(.snappy) { filters = draft }
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .onAppear { draft = filters }
            .onChange(of: draft.kind) { _, _ in
                let valid = Set(displayedCategories.map(\.rawValue))
                draft.categories = draft.categories.intersection(valid)
            }
            .sensoryFeedback(.selection, trigger: draft)
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private func toggle(_ key: String, in set: inout Set<String>) {
        if set.contains(key) { set.remove(key) } else { set.insert(key) }
    }
}

// MARK: - Detail

struct TransactionDetailView: View {
    @Bindable var tx: MoneyTransaction
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Account.createdAt) private var accounts: [Account]
    @Query(sort: \SavingsGoal.createdAt) private var goals: [SavingsGoal]
    @Query(sort: \Bill.name) private var bills: [Bill]
    @AppStorage(Keys.currency) private var currency = "BHD"
    @AppStorage(Keys.smsSyncBalance) private var smsSyncBalance = true
    @State private var confirmDelete = false
    @State private var editingCategory = false
    @State private var nameText = ""
    @State private var amountText = ""
    @State private var noteText = ""
    @State private var showLocationPicker = false
    @State private var isCapturingGPS = false
    @State private var showAddSenderBankAlert = false
    @State private var newSenderBankName = ""
    @State private var showCreateRuleSheet = false
    @State private var showSharedManualSheet = false
    @State private var showSharedLinkSheet = false
    @State private var cachedSMSLegHeaders: [String] = []
    @State private var cachedInferredLocation: TransactionLocationData? = nil
    @State private var isLatestForSourceAccount = false
    @State private var isLatestForDestAccount = false
    @FocusState private var focusedField: DetailField?

    private enum DetailField: Hashable {
        case name, amount, note
    }

    private var account: Account? { accounts.first { $0.id == tx.accountID } }
    private var toAccount: Account? { accounts.first { $0.id == tx.toAccountID } }
    private var isAccountTransfer: Bool { tx.isTransfer && tx.toAccountID != nil }
    private var isSMSTransaction: Bool { tx.source == .sms || tx.smsTransactionType != nil }

    private var matchedRecipientAccount: Account? {
        let targetSuffix = resolvedTransferParties.recipientSuffix ?? tx.smsRecipientSuffix
        guard let recip = targetSuffix, !recip.isEmpty else { return nil }
        return SMSParser.findMatchingAccount(suffix: recip, excludingAccountID: tx.accountID, in: accounts)
    }

    private var resolvedTransferParties: (senderSuffix: String?, recipientSuffix: String?, isIncoming: Bool) {
        if let raw = tx.rawText?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            let parts = raw.components(separatedBy: "\n\n---\n\n")
            if parts.count >= 2, let firstRaw = parts.first {
                let firstParties = SMSParser.extractTransferParties(in: firstRaw)
                let lastParties = SMSParser.extractTransferParties(in: parts.last ?? firstRaw)
                return (
                    senderSuffix: firstParties.senderSuffix ?? tx.smsAccountSuffix,
                    recipientSuffix: lastParties.recipientSuffix ?? tx.smsRecipientSuffix ?? firstParties.recipientSuffix,
                    isIncoming: tx.isIncome || tx.isTransferIn
                )
            }
            return SMSParser.extractTransferParties(in: raw)
        }
        let incoming = tx.isIncome || tx.isTransferIn
        if incoming {
            return (tx.smsRecipientSuffix, tx.smsAccountSuffix, true)
        }
        return (tx.smsAccountSuffix, tx.smsRecipientSuffix, false)
    }

    private var senderDisplayText: String {
        let parties = resolvedTransferParties
        let suffix = parties.senderSuffix
        if isAccountTransfer, let account {
            if let suffix, !suffix.isEmpty {
                return "\(account.name) · ••\(suffix)"
            }
            return account.name
        }
        if parties.isIncoming {
            if let suffix, !suffix.isEmpty {
                return "••\(suffix)"
            }
            return "—"
        }
        if let account {
            if let suffix, !suffix.isEmpty {
                return "\(account.name) · ••\(suffix)"
            }
            return account.name
        }
        if let suffix, !suffix.isEmpty {
            return "••\(suffix)"
        }
        return "—"
    }

    private var recipientDisplayText: String {
        let parties = resolvedTransferParties
        let suffix = parties.recipientSuffix
        let isTwoSMSInternalTransfer = rawSMSMessages.count > 1 && (tx.category == .internalTransfer || tx.effectiveTransactionType == .internalTransfer)
        let matchedDest: Account? = {
            if let toAccount { return toAccount }
            if parties.isIncoming { return account ?? matchedRecipientAccount }
            if tx.category == .internalTransfer || tx.effectiveTransactionType == .internalTransfer {
                return matchedRecipientAccount
            }
            return nil
        }()
        if let suffix, !suffix.isEmpty {
            if isTwoSMSInternalTransfer && toAccount == nil {
                return "••\(suffix)"
            }
            if let matchedDest {
                return "\(matchedDest.name) · ••\(suffix)"
            }
            return "••\(suffix)"
        }
        return matchedDest?.name ?? "—"
    }

    private var rawSMSMessages: [String] {
        guard let raw = tx.rawText, !raw.isEmpty else { return [] }
        return raw.components(separatedBy: "\n\n---\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private var hasUnsavedName: Bool {
        let trimmed = nameText.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed != tx.merchant
    }

    private var hasUnsavedAmount: Bool {
        guard let parsed = Money.parse(amountText), parsed > 0 else { return false }
        return abs(parsed - tx.amount) >= 0.0005
    }

    private var hasUnsavedNote: Bool {
        noteText != tx.note
    }

    private var effectiveLocation: TransactionLocationData? {
        if tx.hasLocation {
            let place = (tx.locationName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
                ? tx.locationName!
                : tx.merchant
            return TransactionLocationData(
                name: place,
                address: tx.locationAddress,
                latitude: tx.latitude,
                longitude: tx.longitude
            )
        }
        return cachedInferredLocation
    }

    private func effectiveAccountBalance(_ acc: Account) -> Double {
        if acc.kind == .creditCard && acc.creditLimit > 0 {
            return acc.cardRemainingBalance
        }
        return acc.balance
    }

    /// Computes the previous balance before this transaction occurred.
    private var previousBalanceAmount: Double? {
        if let smsBal = tx.smsBalance, !tx.isCardLimitBalance {
            return tx.isIncome ? max(0, smsBal - tx.amount) : (smsBal + tx.amount)
        }
        if let account {
            let currentBal = effectiveAccountBalance(account)
            if tx.isPending { return currentBal }
            if account.kind == .creditCard && account.creditLimit <= 0 && tx.smsBalance == nil {
                return tx.isIncome ? (currentBal + tx.amount) : max(0, currentBal - tx.amount)
            }
            return tx.isIncome ? (currentBal - tx.amount) : (currentBal + tx.amount)
        }
        return nil
    }

    var body: some View {
        List {
            heroSection
            if tx.isPending {
                approvalSection
            }
            if tx.isPossibleDuplicate {
                duplicateSection
            }
            if tx.hasRuleConflict {
                ruleConflictSection
            }
            if tx.needsBillReview {
                billReviewSection
            }
            editableFieldsSection
            locationSection
            SharedExpenseTransactionSection(
                tx: tx,
                showManualSheet: $showSharedManualSheet,
                showLinkSheet: $showSharedLinkSheet
            )
            rulesSection
            if isSMSTransaction || tx.smsBalance != nil {
                smsDetailsSection
            }
            if !rawSMSMessages.isEmpty {
                rawMessagesSection
            }
            deleteSection
        }
        .scrollContentBackground(.hidden)
        .canvasBackground()
        .navigationTitle(isAccountTransfer ? "Transfer" : "Transaction")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") {
                    commitPendingEdits(silent: true)
                    focusedField = nil
                }
                .fontWeight(.semibold)
            }
        }
        .onAppear {
            syncSMSAccountAndRecipientIfNeeded()
            nameText = tx.merchant
            amountText = Money.number(tx.amount, decimals: Money.digits(currency)).replacingOccurrences(of: ",", with: "")
            noteText = tx.note
            refreshDerivedSMSMetadata()
            refreshLatestTransactionFlags()
        }
        .onChange(of: tx.merchant) { _, newValue in
            if focusedField != .name && nameText != newValue {
                nameText = newValue
            }
        }
        .onChange(of: tx.note) { _, newValue in
            if focusedField != .note && noteText != newValue {
                noteText = newValue
            }
        }
        .onChange(of: tx.amount) { _, newValue in
            if focusedField != .amount {
                amountText = Money.number(newValue, decimals: Money.digits(currency)).replacingOccurrences(of: ",", with: "")
            }
        }
        .onChange(of: tx.rawText) { _, _ in
            refreshDerivedSMSMetadata()
        }
        .onChange(of: tx.accountID) { _, _ in
            refreshLatestTransactionFlags()
        }
        .onChange(of: tx.toAccountID) { _, _ in
            refreshLatestTransactionFlags()
        }
        .onChange(of: tx.isPending) { _, _ in
            refreshLatestTransactionFlags()
        }
        .onChange(of: tx.date) { _, _ in
            refreshLatestTransactionFlags()
        }
        .onChange(of: smsSyncBalance) { _, _ in
            refreshLatestTransactionFlags()
        }
        .onChange(of: focusedField) { oldValue, _ in
            if oldValue == .name {
                commitName(silent: true)
            } else if oldValue == .amount {
                commitAmount(silent: true)
                amountText = Money.number(tx.amount, decimals: Money.digits(currency)).replacingOccurrences(of: ",", with: "")
            } else if oldValue == .note {
                commitNote(silent: true)
            }
        }
        .onDisappear {
            commitPendingEdits(silent: true)
            try? context.save()
        }
        .confirmationDialog("Delete this transaction?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                Ledger.delete(tx, context: context)
                dismiss()
            }
        }
        .sheet(isPresented: $showLocationPicker) {
            LocationPickerSheet(
                initialName: tx.locationName ?? tx.merchant,
                initialLatitude: tx.latitude,
                initialLongitude: tx.longitude
            ) { loc in
                tx.locationName = loc.name
                tx.locationAddress = loc.address
                tx.latitude = loc.latitude
                tx.longitude = loc.longitude
                try? context.save()
                appState.show("Location updated to \(loc.name)")
            }
        }
        .sheet(isPresented: $showSharedManualSheet) {
            ManualSharedExpenseSheet(expenseTx: tx)
        }
        .sheet(isPresented: $showSharedLinkSheet) {
            LinkReimbursementSheet(reimbursementTx: tx)
        }
    }

    @ViewBuilder
    private var heroSection: some View {
        Section {
            VStack(spacing: 10) {
                if isAccountTransfer {
                    IconBadge(symbol: "arrow.left.arrow.right", color: SpendCategory.internalTransferColor, size: 64)
                } else {
                    CategoryIcon(category: tx.isIncome && tx.category == .other ? .income : tx.displayCategory, size: 64)
                }
                Text(tx.merchant).font(.title3.weight(.semibold)).foregroundStyle(Theme.ink).multilineTextAlignment(.center)
                let heroAmount = isAccountTransfer ? tx.amount : tx.signedAmount
                HStack(spacing: 6) {
                    if let delta = tx.billPriceDelta {
                        Image(systemName: delta > 0 ? "arrowtriangle.up.fill" : "arrowtriangle.down.fill")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(delta > 0 ? Theme.negative : Theme.positive)
                            .accessibilityLabel(delta > 0 ? "Price increased" : "Price decreased")
                    }
                    Text(isAccountTransfer ? Money.format(tx.amount, currency) : Money.format(tx.signedAmount, currency, signed: true))
                        .font(.system(size: 34, weight: .bold).monospacedDigit())
                        .foregroundStyle(tx.isPending ? Theme.secondaryInk : (tx.isIncome ? Theme.positive : Theme.ink))
                        .animatedNumber(heroAmount)
                }
                if let expected = tx.billExpectedAmount, let delta = tx.billPriceDelta {
                    Text(delta > 0
                         ? "Expected \(Money.format(expected, currency)) · +\(Money.format(delta, currency))"
                         : "Expected \(Money.format(expected, currency)) · −\(Money.format(abs(delta), currency))")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(delta > 0 ? Theme.negative : Theme.positive)
                }
                Text(tx.date.formatted(date: .complete, time: .shortened)).font(.subheadline).foregroundStyle(Theme.secondaryInk)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .listRowBackground(Color.clear)
        }
    }

    @ViewBuilder
    private var approvalSection: some View {
        Section {
            let reasons = tx.reviewReasons(accounts: accounts)
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(Theme.warning.opacity(0.18))
                            .frame(width: 44, height: 44)
                        Image(systemName: "clock.badge.exclamationmark.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(Theme.warning)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Waiting for Approval")
                            .font(.headline)
                            .foregroundStyle(Theme.ink)
                        Text("Quarantined transaction · Balances and budgets are not updated until approved.")
                            .font(.caption)
                            .foregroundStyle(Theme.secondaryInk)
                    }
                }

                if !reasons.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Reasons for Review")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Theme.secondaryInk)
                            .textCase(.uppercase)

                        ForEach(reasons, id: \.self) { reason in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: reasonIcon(for: reason))
                                    .font(.body)
                                    .foregroundStyle(Theme.warning)
                                    .frame(width: 22)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(reason)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(Theme.ink)
                                    Text(reasonExplanation(for: reason))
                                        .font(.caption2)
                                        .foregroundStyle(Theme.secondaryInk)
                                }
                            }
                            .padding(.vertical, 6)
                            .padding(.horizontal, 10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Theme.warning.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }

                VStack(spacing: 10) {
                    Button {
                        commitPendingEdits(silent: true)
                        let result = Ledger.approve(tx, context: context)
                        appState.report(result, base: "Approved \(Money.format(tx.amount, currency))")
                    } label: {
                        Text("Approve and update account")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                            .background(
                                LinearGradient(
                                    colors: [
                                        Color(light: Color(hex: 0x16A34A), dark: Color(hex: 0x10B981)),
                                        Color(light: Color(hex: 0x15803D), dark: Color(hex: 0x059669))
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
                            )
                            .shadow(color: Color(light: Color(hex: 0x16A34A).opacity(0.24), dark: Color(hex: 0x10B981).opacity(0.22)), radius: 8, y: 3)
                    }
                    .buttonStyle(PressableStyle())

                    Button(role: .destructive) {
                        Ledger.delete(tx, context: context)
                        appState.show("Transaction rejected and removed")
                        dismiss()
                    } label: {
                        Text("Reject")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color(light: Color(hex: 0xDC2626), dark: Color(hex: 0xFCA5A5)))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(
                                Color(light: Color(hex: 0xFEF2F2), dark: Color(hex: 0xEF4444).opacity(0.14)),
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .strokeBorder(
                                        Color(light: Color(hex: 0xDC2626).opacity(0.28), dark: Color(hex: 0xF87171).opacity(0.34)),
                                        lineWidth: 1
                                    )
                            )
                    }
                    .buttonStyle(PressableStyle())
                }
                .padding(.top, 4)
            }
            .padding(.vertical, 6)
        } header: {
            Text("Approval Status")
        }
    }

    @ViewBuilder
    private var duplicateSection: some View {
        Section {
            Label("This looks like the same payment as another transaction.", systemImage: "exclamationmark.circle.fill")
                .foregroundStyle(Theme.negative)
            Button("Keep both") {
                tx.isPossibleDuplicate = false
                try? context.save()
            }
            Button("Delete this duplicate", role: .destructive) {
                Ledger.delete(tx, context: context)
                dismiss()
            }
        }
    }

    @ViewBuilder
    private var ruleConflictSection: some View {
        let store = TransactionRuleStore.shared
        let conflictingRules = tx.ruleConflictIDs.compactMap { id in
            store.rules.first(where: { $0.id == id })
        }
        Section {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(Theme.warning.opacity(0.18))
                            .frame(width: 42, height: 42)
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(Theme.warning)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Rule Conflict — Review Needed")
                            .font(.headline)
                            .foregroundStyle(Theme.ink)
                        Text("Multiple rules matched with equal specificity but different actions. Choose which rule to apply:")
                            .font(.caption)
                            .foregroundStyle(Theme.secondaryInk)
                    }
                }

                if conflictingRules.isEmpty {
                    Button {
                        tx.ruleConflictIDsRaw = ""
                        try? context.save()
                    } label: {
                        Text("Clear conflict notice")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.ink)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(Theme.track.opacity(0.7), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(PressableStyle())
                } else {
                    VStack(spacing: 8) {
                        ForEach(conflictingRules) { rule in
                            let summary: String = {
                                var parts: [String] = []
                                if let cat = rule.actions.category { parts.append(cat.title) }
                                if let m = rule.actions.setMerchant, !m.isEmpty { parts.append("Merchant: \(m)") }
                                if let accID = rule.actions.overrideAccountID ?? rule.actions.fromAccountID,
                                   let acc = accounts.first(where: { $0.id == accID }) {
                                    parts.append("Account: \(acc.name)")
                                }
                                return parts.isEmpty ? "Apply rule actions" : parts.joined(separator: " · ")
                            }()
                            Button {
                                commitPendingEdits(silent: true)
                                Ledger.edit(tx, context: context) { target in
                                    store.apply(rule: rule, to: target, explanation: "Rule: \(rule.name) · Chosen by user to resolve equal-specificity conflict")
                                }
                                nameText = tx.merchant
                                appState.show("Applied rule \"\(rule.name)\"")
                            } label: {
                                HStack(spacing: 10) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(rule.name.isEmpty ? "Rule" : rule.name)
                                            .font(.subheadline.weight(.semibold))
                                            .foregroundStyle(Theme.ink)
                                        Text(summary)
                                            .font(.caption)
                                            .foregroundStyle(Theme.secondaryInk)
                                            .lineLimit(2)
                                    }
                                    Spacer()
                                    Text("Apply")
                                        .font(.caption.weight(.bold))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 6)
                                        .background(Theme.cobalt, in: Capsule())
                                }
                                .padding(10)
                                .background(Theme.track.opacity(0.55), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }
                            .buttonStyle(PressableStyle())
                        }

                        Button {
                            tx.ruleConflictIDsRaw = ""
                            try? context.save()
                            appState.show("Rule conflict dismissed")
                        } label: {
                            Text("Keep current values (dismiss)")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Theme.secondaryInk)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.vertical, 4)
        } header: {
            Text("Rule Conflict")
        }
    }

    @ViewBuilder
    private var billReviewSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(Theme.cobalt.opacity(0.16))
                            .frame(width: 42, height: 42)
                        Image(systemName: "calendar.badge.plus")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(Theme.cobalt)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Detected Bill / Subscription")
                            .font(.headline)
                            .foregroundStyle(Theme.ink)
                        Text(tx.billMatchReason.isEmpty ? "Add this payment as a recurring bill or subscription?" : tx.billMatchReason)
                            .font(.caption)
                            .foregroundStyle(Theme.secondaryInk)
                    }
                }

                VStack(spacing: 10) {
                    Button {
                        commitPendingEdits(silent: true)
                        let created = SubscriptionMatchingEngine.confirmAsNewRecurringBill(
                            tx: tx,
                            isSubscription: tx.category != .bills,
                            frequency: .monthly,
                            context: context
                        )
                        appState.show("Added \(created.name) as recurring bill & saved rule")
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 17, weight: .semibold))
                            Text("Confirm & Add as Recurring Bill")
                                .font(.subheadline.weight(.semibold))
                        }
                        .foregroundStyle(Color.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(
                            LinearGradient(
                                colors: [
                                    Color(light: Color(hex: 0x1A1A18), dark: Color(hex: 0xB44CFF)),
                                    Color(light: Color(hex: 0x32322E), dark: Color(hex: 0x8B2CE6))
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
                        )
                    }
                    .buttonStyle(PressableStyle())

                    if !bills.isEmpty {
                        Menu {
                            ForEach(bills) { bill in
                                Button {
                                    commitPendingEdits(silent: true)
                                    SubscriptionMatchingEngine.confirmExistingBill(tx: tx, bill: bill, context: context)
                                    appState.show("Matched to \(bill.name) & saved learning rule")
                                } label: {
                                    Text("\(bill.name) (\(Money.format(bill.amount, currency)))")
                                }
                            }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "link")
                                    .font(.system(size: 16, weight: .semibold))
                                Text("Match to Existing Bill")
                                    .font(.subheadline.weight(.semibold))
                            }
                            .foregroundStyle(Theme.ink)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Theme.track.opacity(0.7), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .strokeBorder(Theme.secondaryInk.opacity(0.22), lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                    }

                    Button(role: .destructive) {
                        SubscriptionMatchingEngine.rejectBillSuggestion(tx: tx, context: context)
                        appState.show("Not a bill · We'll remember this")
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 16, weight: .semibold))
                            Text("Not a Bill (Don't Ask Again)")
                                .font(.subheadline.weight(.semibold))
                        }
                        .foregroundStyle(Color(light: Color(hex: 0xDC2626), dark: Color(hex: 0xFCA5A5)))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(
                            Color(light: Color(hex: 0xFEF2F2), dark: Color(hex: 0xEF4444).opacity(0.14)),
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(
                                    Color(light: Color(hex: 0xDC2626).opacity(0.28), dark: Color(hex: 0xF87171).opacity(0.34)),
                                    lineWidth: 1
                                )
                        )
                    }
                    .buttonStyle(PressableStyle())
                }
            }
            .padding(.vertical, 4)
        } header: {
            Text("Bills & Subscriptions Review")
        }
    }

    @ViewBuilder
    private var editableFieldsSection: some View {
        Section("Transaction") {
            HStack(spacing: 8) {
                Text("Name")
                Spacer()
                TextField("Merchant or title", text: $nameText)
                    .multilineTextAlignment(.trailing)
                    .focused($focusedField, equals: .name)
                    .submitLabel(.done)
                    .onSubmit {
                        commitName(silent: true)
                        focusedField = nil
                    }
            }

            HStack(spacing: 8) {
                Text("Amount (\(currency))")
                Spacer()
                TextField(Money.format(0, currency), text: $amountText)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .focused($focusedField, equals: .amount)
            }

            DatePicker(
                "Date",
                selection: Binding(
                    get: { tx.date },
                    set: { newDate in
                        commitPendingEdits(silent: true)
                        Ledger.edit(tx, context: context) { target in
                            target.date = newDate
                        }
                    }
                ),
                displayedComponents: [.date, .hourAndMinute]
            )

            Button {
                editingCategory = true
            } label: {
                HStack(spacing: 8) {
                    Text("Category")
                        .foregroundStyle(Theme.ink)
                    Spacer(minLength: 8)
                    HStack(spacing: 6) {
                        CategoryIcon(category: tx.category, size: 22)
                        Text(tx.category.title)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Theme.ink)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                        if tx.aiCategorized { AIBadge() }
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Theme.secondaryInk)
                    }
                    .layoutPriority(1)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Theme.track.opacity(0.65), in: Capsule())
                }
            }
            .buttonStyle(.plain)
            .sheet(isPresented: $editingCategory) {
                TransactionCategoryPickerSheet(
                    selected: tx.category,
                    initialTab: tx.category.isTransferCategory ? .transfers : ((tx.category.isIncomeCategory || tx.isIncome) ? .income : .expenses),
                    onSelect: { chosen in
                        applySelectedCategory(chosen)
                        tx.subcategory = nil
                        try? context.save()
                    }
                )
                .presentationDetents([.medium, .large])
            }

            AccountPickerRow(
                title: "Account",
                selection: Binding(get: { tx.accountID }, set: { newID in
                    commitPendingEdits(silent: true)
                    Ledger.edit(tx, context: context) { target in
                        target.accountID = newID
                    }
                }),
                accounts: accounts,
                noneLabel: isSMSTransaction ? "Unknown" : "None"
            )

            transferAccountPickers

            if !goals.isEmpty && tx.category != .visaTransfer {
                savingsGoalPicker
            }

            if !tx.isIncome && !tx.isTransfer && !bills.isEmpty {
                billSubscriptionPicker
            }

            TextField("Note", text: $noteText, axis: .vertical)
                .focused($focusedField, equals: .note)
        }
    }

    @ViewBuilder
    private var transferAccountPickers: some View {
        if tx.category == .visaTransfer {
            AccountPickerRow(
                title: "Visa card",
                selection: Binding(get: { tx.toAccountID }, set: { newID in
                    guard newID != tx.accountID else { return }
                    commitPendingEdits(silent: true)
                    Ledger.edit(tx, context: context) { $0.toAccountID = newID }
                }),
                accounts: accounts.filter { $0.kind == .creditCard },
                noneLabel: "Select card"
            )
            if let card = toAccount, card.kind == .creditCard {
                LabeledContent("Card balance owed") {
                    Text(Money.format(card.balance, currency))
                        .monospacedDigit()
                        .foregroundStyle(card.balance > 0.0005 ? Theme.negative : Theme.positive)
                        .animatedNumber(card.balance)
                }
                if card.paymentDueReminder {
                    LabeledContent("Next payment due") {
                        Text(card.nextUpcomingDueDate().formatted(.dateTime.day().month(.abbreviated).year()))
                    }
                }
            }
        } else if tx.category == .internalTransfer || tx.effectiveTransactionType == .internalTransfer || tx.toAccountID != nil {
            AccountPickerRow(
                title: "To account",
                selection: Binding(get: { tx.toAccountID ?? matchedRecipientAccount?.id }, set: { newID in
                    guard newID != tx.accountID else { return }
                    commitPendingEdits(silent: true)
                    let linkedGoalID = newID.flatMap { id in goals.first(where: { $0.linkedAccountID == id })?.id }
                    Ledger.edit(tx, context: context) { target in
                        target.toAccountID = newID
                        if newID != nil {
                            target.category = .internalTransfer
                            target.smsTransactionType = .internalTransfer
                            target.isIncome = false
                        }
                        if let linkedGoalID {
                            target.goalID = linkedGoalID
                        }
                    }
                }),
                accounts: accounts.filter { $0.id != tx.accountID },
                noneLabel: "Select destination"
            )
        }
    }

    @ViewBuilder
    private var savingsGoalPicker: some View {
        let currentSelection: String = {
            guard let gid = tx.goalID, goals.contains(where: { $0.id == gid }) else { return "" }
            return gid.uuidString
        }()
        SheetPickerRow(
            title: "Savings goal",
            selection: Binding(
                get: { currentSelection },
                set: { rawID in
                    commitPendingEdits(silent: true)
                    let newGoalID = UUID(uuidString: rawID)
                    guard newGoalID != tx.goalID else { return }
                    let selectedGoal = newGoalID.flatMap { id in goals.first(where: { $0.id == id }) }
                    let linkedAccountID = selectedGoal?.linkedAccountID
                    Ledger.edit(tx, context: context) { target in
                        target.goalID = newGoalID
                        let isInternal = target.category == .internalTransfer || target.smsTransactionType == .internalTransfer
                        if target.toAccountID == nil,
                           let linkedAcc = linkedAccountID,
                           linkedAcc != target.accountID,
                           isInternal {
                            target.toAccountID = linkedAcc
                        }
                    }
                    if let selectedGoal {
                        appState.show("Assigned to \(selectedGoal.name)")
                    } else {
                        appState.show("Removed from savings goal")
                    }
                }
            ),
            options: [SheetPickerOption(id: "", title: "None", symbol: "minus.circle", color: Theme.secondaryInk)]
                + goals.map { SheetPickerOption(id: $0.id.uuidString, title: $0.name, symbol: $0.symbol, color: Theme.cobalt) }
        )
    }

    @ViewBuilder
    private var billSubscriptionPicker: some View {
        SheetPickerRow(
            title: "Bill / Subscription",
            selection: Binding(
                get: { tx.billID?.uuidString ?? "" },
                set: { newValue in
                    commitPendingEdits(silent: true)
                    if let newID = UUID(uuidString: newValue),
                       let chosen = bills.first(where: { $0.id == newID }) {
                        SubscriptionMatchingEngine.confirmExistingBill(tx: tx, bill: chosen, context: context)
                        appState.show("Linked to \(chosen.name) & saved learning rule")
                    } else {
                        if let oldID = tx.billID,
                           let oldBill = bills.first(where: { $0.id == oldID }),
                           oldBill.lastPaidTxID == tx.id {
                            oldBill.unmarkPaid()
                        }
                        tx.billID = nil
                        tx.billExpectedAmount = nil
                        tx.billMatchConfidence = 0
                        tx.billMatchReason = ""
                        try? context.save()
                        appState.show("Unlinked from bill")
                    }
                }
            ),
            options: [SheetPickerOption(id: "", title: "None", symbol: "minus.circle", color: Theme.secondaryInk)]
                + bills.map { bill in
                    SheetPickerOption(
                        id: bill.id.uuidString,
                        title: "\(bill.name) (\(Money.format(bill.amount, currency)))",
                        symbol: bill.isSubscription ? "repeat.circle.fill" : "calendar.badge.clock",
                        color: bill.category.color
                    )
                }
        )
    }

    private func applySelectedCategory(_ new: SpendCategory) {
        commitPendingEdits(silent: true)
        if new == .visaTransfer {
            let cards = accounts.filter { $0.kind == .creditCard }
            Ledger.edit(tx, context: context) { target in
                target.subcategory = nil
                target.category = .visaTransfer
                target.isIncome = false
                target.smsTransactionType = .internalTransfer
                target.aiCategorized = false
                target.goalID = nil
                target.smsBalanceIsCardLimit = true
                let currentDestIsCard = target.toAccountID.flatMap { id in cards.first { $0.id == id } } != nil
                if !currentDestIsCard {
                    target.toAccountID = cards.first(where: { $0.id != target.accountID })?.id
                }
            }
            if cards.isEmpty {
                appState.show("Add your Visa card as a Credit card account to pay it down", warning: true)
            }
        } else if new == .internalTransfer {
            Ledger.edit(tx, context: context) { target in
                target.subcategory = nil
                target.category = .internalTransfer
                target.isIncome = false
                target.smsTransactionType = .internalTransfer
                target.aiCategorized = false
                if target.toAccountID == nil,
                   let recip = target.smsRecipientSuffix,
                   let matchedDest = SMSParser.findMatchingAccount(suffix: recip, excludingAccountID: target.accountID, in: context) {
                    target.toAccountID = matchedDest.id
                }
                if target.goalID == nil,
                   let matchedGoal = SMSParser.findMatchingGoal(suffix: target.smsRecipientSuffix, accountID: target.toAccountID, in: context),
                   matchedGoal.linkedAccountID == nil || matchedGoal.linkedAccountID != target.accountID {
                    target.goalID = matchedGoal.id
                    if target.toAccountID == nil, let linkedAcc = matchedGoal.linkedAccountID, linkedAcc != target.accountID {
                        target.toAccountID = linkedAcc
                    }
                }
            }
        } else {
            let newIsIncome = new.isIncomeCategory || new == .transferIn
            let wasInternal = tx.category == .internalTransfer || tx.category == .visaTransfer || tx.smsTransactionType == .internalTransfer
            let directionOrTransferChanged = wasInternal || tx.isIncome != newIsIncome || tx.category.isTransferCategory != new.isTransferCategory
            if directionOrTransferChanged {
                Ledger.edit(tx, context: context) { target in
                    target.subcategory = nil
                    target.category = new
                    target.toAccountID = nil
                    if wasInternal {
                        target.goalID = nil
                    }
                    target.smsBalanceIsCardLimit = false
                    target.isIncome = newIsIncome
                    if isSMSTransaction || new.isTransferCategory {
                        if new == .transferIn {
                            target.smsTransactionType = .transferIn
                        } else if new.isTransferCategory {
                            target.smsTransactionType = .transferOut
                        } else if isSMSTransaction {
                            target.smsTransactionType = new.isIncomeCategory ? .income : .expense
                        }
                    }
                    target.aiCategorized = false
                    if target.smsClassificationReason.hasPrefix("Matched:") || target.smsClassificationReason.hasPrefix("Matched Rule") {
                        target.smsClassificationReason = ""
                    }
                }
            } else {
                if new != tx.category { tx.subcategory = nil }
                tx.category = new
                if isSMSTransaction && (tx.smsTransactionType == nil || tx.smsTransactionType == .unknown) {
                    tx.smsTransactionType = new == .transferIn ? .transferIn : (new.isTransferCategory ? .transferOut : (new.isIncomeCategory ? .income : .expense))
                }
                tx.aiCategorized = false
                if tx.smsClassificationReason.hasPrefix("Matched:") || tx.smsClassificationReason.hasPrefix("Matched Rule") {
                    tx.smsClassificationReason = ""
                }
                try? context.save()
                Ledger.notifyDataChanged()
            }
            Categorizer.recordUserCategoryChoice(for: tx, category: new)
        }
    }

    @ViewBuilder
    private var locationSection: some View {
        Section("Location") {
            if let loc = effectiveLocation {
                TransactionLocationCard(
                    placeName: loc.name,
                    address: loc.address,
                    latitude: loc.latitude,
                    longitude: loc.longitude,
                    onSearchPlace: {
                        showLocationPicker = true
                    },
                    onRemove: tx.hasLocation ? {
                        tx.locationName = nil
                        tx.locationAddress = nil
                        tx.latitude = nil
                        tx.longitude = nil
                        try? context.save()
                    } : nil
                )
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            } else {
                Button {
                    showLocationPicker = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "mappin.and.ellipse")
                        Text("Add Location / Search on Map")
                    }
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.brand)
                .padding(.vertical, 4)
            }
        }
    }

    @ViewBuilder
    private var rulesSection: some View {
        Section {
            TransactionDetailRulesSection(tx: tx, accounts: accounts, showCreateSheet: $showCreateRuleSheet)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
        } header: {
            HStack {
                Text("Transaction Rules")
                Spacer()
                Button {
                    showCreateRuleSheet = true
                } label: {
                    Image(systemName: "plus")
                        .font(.caption.weight(.bold))
                        .frame(width: 26, height: 26)
                        .background(Theme.track.opacity(0.75), in: Circle())
                        .foregroundStyle(Theme.ink)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Create rule")
            }
        }
    }

    @ViewBuilder
    private var smsDetailsSection: some View {
        Section("SMS Details") {
            let bankOptions: [SheetPickerOption<String>] = {
                var opts = [SheetPickerOption(id: "", title: "Unknown / Not set", symbol: "questionmark.circle", color: Theme.secondaryInk)]
                if let currentBank = tx.smsBank, !currentBank.isEmpty,
                   !BahrainBankCatalog.allBanks.contains(where: { $0.caseInsensitiveCompare(currentBank) == .orderedSame }) {
                    opts.append(SheetPickerOption(id: currentBank, title: currentBank, symbol: "building.columns", color: Theme.cobalt))
                }
                opts.append(contentsOf: BahrainBankCatalog.allBanks.map {
                    SheetPickerOption(id: $0, title: $0, symbol: "building.columns", color: Theme.secondaryInk)
                })
                return opts
            }()
            SheetPickerRow(
                title: "SMS sender bank",
                selection: Binding(
                    get: { tx.smsBank ?? "" },
                    set: { newBank in
                        commitPendingEdits(silent: true)
                        let clean = newBank.isEmpty ? nil : newBank
                        Ledger.edit(tx, context: context) { target in
                            target.smsBank = clean
                        }
                        try? context.save()
                        appState.show(clean.map { "Bank set to \($0)" } ?? "Cleared SMS bank")
                    }
                ),
                options: bankOptions,
                addConfig: SheetPickerAddConfig(
                    title: "Create Sender Bank",
                    placeholder: "Bank or sender name",
                    message: "Enter a bank or SMS sender name to add it to your sender bank list.",
                    onAdd: { name in
                        if let created = BahrainBankCatalog.addCustomBank(name) {
                            commitPendingEdits(silent: true)
                            Ledger.edit(tx, context: context) { target in
                                target.smsBank = created
                            }
                            try? context.save()
                            appState.show("Created & set bank to \(created)")
                        }
                    }
                )
            )

            LabeledContent("Reference") {
                Text((tx.smsReference?.isEmpty == false) ? tx.smsReference! : "—")
                    .font(.subheadline.monospaced())
                    .foregroundStyle(Theme.ink)
            }

            LabeledContent("Sender IBAN / Account") {
                Text(senderDisplayText)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(Theme.ink)
            }

            LabeledContent("Recipient IBAN / Account") {
                Text(recipientDisplayText)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(Theme.ink)
            }

            LabeledContent("Previous balance") {
                Text(previousBalanceAmount.map { Money.format($0, currency) } ?? "—")
                    .monospacedDigit()
            }

            LabeledContent("New balance") {
                if let account {
                    let effectiveBal = effectiveAccountBalance(account)
                    if let smsBal = tx.smsBalance, !tx.isCardLimitBalance, abs(effectiveBal - smsBal) >= 0.0005 {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("\(account.name) (\(Money.format(effectiveBal, currency)))")
                                .monospacedDigit()
                                .animatedNumber(effectiveBal)
                            Text("SMS: \(Money.format(smsBal, currency))")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(Theme.secondaryInk)
                        }
                    } else {
                        Text("\(account.name) (\(Money.format(effectiveBal, currency)))")
                            .monospacedDigit()
                            .animatedNumber(effectiveBal)
                    }
                } else if let smsBal = tx.smsBalance {
                    Text(Money.format(smsBal, currency))
                        .monospacedDigit()
                } else {
                    Text("None").foregroundStyle(Theme.secondaryInk)
                }
            }

            if let bank = tx.smsBalance, let account, (!account.kind.isLiability || account.kind == .creditCard), !tx.isCardLimitBalance {
                let effectiveBal = effectiveAccountBalance(account)
                if !smsSyncBalance && isLatestForSourceAccount && abs(effectiveBal - bank) >= 0.0005 && !tx.isPending {
                    Button {
                        if let synced = Ledger.syncBalanceForAccount(id: account.id, balance: bank, on: tx, isToAccount: false, context: context, force: true) {
                            refreshLatestTransactionFlags()
                            appState.show("\(account.name) set to \(Money.format(synced, currency))")
                        }
                    } label: {
                        Label("Match \(account.name) to bank balance", systemImage: "equal.circle.fill")
                    }
                }
            }

            if let toBal = tx.smsToBalance, let toID = tx.toAccountID, toID != tx.accountID, let destAcc = toAccount {
                let toEffectiveBal = effectiveAccountBalance(destAcc)

                LabeledContent("To prev. balance") {
                    let destPrev = max(0, toBal - tx.amount)
                    Text(Money.format(destPrev, currency))
                        .monospacedDigit()
                }

                LabeledContent("To new balance") {
                    if (!destAcc.kind.isLiability || destAcc.kind == .creditCard) && abs(toEffectiveBal - toBal) >= 0.0005 {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("\(destAcc.name) (\(Money.format(toEffectiveBal, currency)))")
                                .monospacedDigit()
                                .animatedNumber(toEffectiveBal)
                            Text("SMS: \(Money.format(toBal, currency))")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(Theme.secondaryInk)
                        }
                    } else {
                        Text("\(destAcc.name) (\(Money.format(toEffectiveBal, currency)))")
                            .monospacedDigit()
                            .animatedNumber(toEffectiveBal)
                    }
                }

                if !destAcc.kind.isLiability || destAcc.kind == .creditCard {
                    if !smsSyncBalance && isLatestForDestAccount && abs(toEffectiveBal - toBal) >= 0.0005 && !tx.isPending {
                        Button {
                            if let synced = Ledger.syncBalanceForAccount(id: toID, balance: toBal, on: tx, isToAccount: true, context: context, force: true) {
                                refreshLatestTransactionFlags()
                                appState.show("\(destAcc.name) set to \(Money.format(synced, currency))")
                            }
                        } label: {
                            Label("Match \(destAcc.name) to bank balance", systemImage: "equal.circle.fill")
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Classification reason").font(.caption).foregroundStyle(Theme.secondaryInk)
                Text(formattedClassificationReason)
                    .font(.footnote)
                    .foregroundStyle(Theme.ink)
            }
        }
    }

    private var formattedClassificationReason: String {
        let raw = tx.smsClassificationReason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return "—" }
        return raw
            .replacingOccurrences(of: #"^Matched\s+Rule\s+\d+:\s*"#, with: "Matched: ", options: .regularExpression)
            .replacingOccurrences(of: #"^Rule\s+\d+:\s*"#, with: "", options: .regularExpression)
    }

    @ViewBuilder
    private var rawMessagesSection: some View {
        Section(rawSMSMessages.count > 1 ? "Original SMS messages (\(rawSMSMessages.count))" : "Original message") {
            if rawSMSMessages.count > 1 {
                ForEach(Array(rawSMSMessages.enumerated()), id: \.offset) { idx, msg in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(idx < cachedSMSLegHeaders.count ? cachedSMSLegHeaders[idx] : "SMS \(idx + 1)")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(idx == 0 ? Theme.ink : Theme.positive)
                            Spacer()
                            Button {
                                UIPasteboard.general.string = msg
                                appState.show("SMS copied")
                            } label: {
                                Label("Copy", systemImage: "doc.on.doc")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Theme.cobalt)
                            }
                            .buttonStyle(.plain)
                        }
                        Text(msg)
                            .font(.footnote)
                            .foregroundStyle(Theme.secondaryInk)
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, 2)
                    .contextMenu {
                        Button("Copy SMS", systemImage: "doc.on.doc") {
                            UIPasteboard.general.string = msg
                            appState.show("SMS copied")
                        }
                    }
                }
            } else {
                let msg = rawSMSMessages[0]
                VStack(alignment: .leading, spacing: 8) {
                    Text(msg)
                        .font(.footnote)
                        .foregroundStyle(Theme.secondaryInk)
                        .textSelection(.enabled)
                    HStack {
                        Spacer()
                        Button {
                            UIPasteboard.general.string = msg
                            appState.show("SMS copied")
                        } label: {
                            Label("Copy SMS", systemImage: "doc.on.doc")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Theme.cobalt)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Theme.cobaltSoft, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 2)
                .contextMenu {
                    Button("Copy SMS", systemImage: "doc.on.doc") {
                        UIPasteboard.general.string = msg
                        appState.show("SMS copied")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var deleteSection: some View {
        Section {
            Button("Delete transaction", role: .destructive) { confirmDelete = true }
        }
    }

    private func captureGPSLocation() {
        Task {
            isCapturingGPS = true
            if let loc = await LocationService.shared.captureCurrentLocation(fallbackPlaceName: tx.merchant) {
                tx.locationName = loc.name
                tx.locationAddress = loc.address
                tx.latitude = loc.latitude
                tx.longitude = loc.longitude
                try? context.save()
                appState.show("Captured location: \(loc.name)")
            } else if let err = LocationService.shared.lastError {
                appState.show(err, warning: true)
            }
            isCapturingGPS = false
        }
    }

    private func smsLegHeaderTitle(index: Int, message: String) -> String {
        let dir = SMSParser.analyzeTransferLegDirection(in: message, fallbackIsIncome: index > 0)
        let roleLabel: String = {
            switch dir {
            case .debit: return "Debit SMS"
            case .credit: return "Credit SMS"
            case .unknown: return index == 0 ? "Debit SMS" : "Credit SMS"
            }
        }()
        if let detectedBank = SMSParser.parse(message, context: context)?.detectedBank {
            return "SMS \(index + 1) · \(roleLabel) (\(detectedBank))"
        }
        return "SMS \(index + 1) · \(roleLabel)"
    }

    private func syncSMSAccountAndRecipientIfNeeded() {
        guard isSMSTransaction else { return }
        guard tx.category == .internalTransfer || tx.smsTransactionType == .internalTransfer,
              tx.toAccountID == nil,
              let recip = tx.smsRecipientSuffix, !recip.isEmpty,
              let matchedDest = SMSParser.findMatchingAccount(suffix: recip, excludingAccountID: tx.accountID, in: context) else {
            return
        }
        Ledger.edit(tx, context: context) { target in
            target.toAccountID = matchedDest.id
        }
    }

    private func refreshDerivedSMSMetadata() {
        cachedInferredLocation = tx.hasLocation ? nil : LocationService.inferLocation(from: tx.rawText, merchant: tx.merchant)
        let messages = rawSMSMessages
        cachedSMSLegHeaders = messages.count > 1
            ? messages.enumerated().map { idx, msg in smsLegHeaderTitle(index: idx, message: msg) }
            : []
    }

    private func refreshLatestTransactionFlags() {
        isLatestForSourceAccount = tx.accountID.map { Ledger.isLatestTransaction(tx, forAccountID: $0, context: context) } ?? false
        if let toID = tx.toAccountID, toID != tx.accountID {
            isLatestForDestAccount = Ledger.isLatestTransaction(tx, forAccountID: toID, context: context)
        } else {
            isLatestForDestAccount = false
        }
    }

    private func commitPendingEdits(silent: Bool) {
        if hasUnsavedName { commitName(silent: silent) }
        if hasUnsavedAmount { commitAmount(silent: silent) }
        if hasUnsavedNote { commitNote(silent: silent) }
    }

    private func commitName(silent: Bool = false) {
        let trimmed = nameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != tx.merchant else { return }
        tx.merchant = trimmed
        try? context.save()
        if !silent {
            appState.show("Updated name to \(trimmed)")
        }
    }

    private func commitNote(silent: Bool = false) {
        guard noteText != tx.note else { return }
        tx.note = noteText
        try? context.save()
    }

    private func commitAmount(silent: Bool = false) {
        guard let parsed = Money.parse(amountText), parsed > 0, abs(parsed - tx.amount) >= 0.0005 else { return }
        Ledger.edit(tx, context: context) { target in
            target.amount = abs(parsed)
        }
        amountText = Money.number(tx.amount, decimals: Money.digits(currency)).replacingOccurrences(of: ",", with: "")
        if !silent {
            var result = LedgerResult()
            if !tx.isPending && tx.isSpending {
                result.alerts = Ledger.checkBudgetAlerts(for: tx.category, context: context)
            }
            appState.report(result, base: "Updated amount to \(Money.format(tx.amount, currency))")
        }
    }

    private func reasonIcon(for reason: String) -> String {
        switch reason {
        case "Unknown sender bank": return "building.columns.circle.fill"
        case "Unmatched account": return "creditcard.trianglebadge.exclamationmark.fill"
        case "Unknown transaction type": return "questionmark.diamond.fill"
        case "Possible duplicate": return "doc.on.doc.fill"
        default: return "clock.badge.exclamationmark.fill"
        }
    }

    private func reasonExplanation(for reason: String) -> String {
        switch reason {
        case "Unknown sender bank":
            return "The SMS was received from an unrecognized phone or bank sender. Verify the bank and account below."
        case "Unmatched account":
            return "The account or card suffix could not be matched to any of your accounts."
        case "Unknown transaction type":
            return "The transaction direction or type could not be classified with certainty."
        case "Possible duplicate":
            return "Another SMS transaction with the same reference code was already recorded."
        default:
            return "This transaction requires approval before updating account balances and budgets."
        }
    }
}

struct TransactionCategoryPickerSheet: View {
    let selected: SpendCategory
    let initialTab: CategoryTab
    var allowedTabs: [CategoryTab] = CategoryTab.allCases
    let onSelect: (SpendCategory) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @State private var selectedTab: CategoryTab
    @State private var editorTarget: CategoryEditorTarget?

    init(
        selected: SpendCategory,
        initialTab: CategoryTab,
        allowedTabs: [CategoryTab] = CategoryTab.allCases,
        onSelect: @escaping (SpendCategory) -> Void
    ) {
        self.selected = selected
        self.initialTab = initialTab
        self.allowedTabs = allowedTabs
        self.onSelect = onSelect
        let resolvedInitial = allowedTabs.contains(initialTab) ? initialTab : (allowedTabs.first ?? .expenses)
        self._selectedTab = State(initialValue: resolvedInitial)
    }

    private var categoriesForTab: [SpendCategory] {
        switch selectedTab {
        case .income:
            return SpendCategory.incomeCases
        case .expenses:
            return SpendCategory.expenseCases
        case .transfers:
            return SpendCategory.transferCases
        }
    }

    var body: some View {
        let registry = CategoryRegistry.shared
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if allowedTabs.count > 1 {
                        HStack(spacing: 6) {
                            ForEach(allowedTabs) { tab in
                                Button {
                                    withAnimation(.snappy) { selectedTab = tab }
                                } label: {
                                    Text(tab.rawValue)
                                        .font(.subheadline.weight(selectedTab == tab ? .semibold : .medium))
                                        .foregroundStyle(selectedTab == tab ? Theme.ink : Theme.secondaryInk)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 8)
                                        .background(selectedTab == tab ? Theme.track : Color.clear, in: Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    Text(selectedTab.rawValue)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.ink)
                        .padding(.horizontal, 4)
                        .padding(.top, 2)

                    VStack(spacing: 8) {
                        ForEach(categoriesForTab) { cat in
                            Button {
                                onSelect(cat)
                                dismiss()
                            } label: {
                                HStack(spacing: 12) {
                                    CategoryIcon(category: cat, size: 32)
                                    Text(cat.title)
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(Theme.ink)
                                    Spacer()
                                    if cat == selected {
                                        Image(systemName: "checkmark")
                                            .font(.subheadline.weight(.semibold))
                                            .foregroundStyle(Theme.ink)
                                    }
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 12)
                                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .id(registry.order)
            .canvasBackground()
            .navigationTitle("Category")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("New", systemImage: "plus") {
                        editorTarget = .new(parent: nil, income: selectedTab == .income, transfer: selectedTab == .transfers)
                    }
                }
            }
            .sheet(item: $editorTarget) { target in
                CategoryEditor(target: target) { created in
                    onSelect(created)
                    dismiss()
                }
            }
            .onAppear {
                registry.reload(context: context)
            }
        }
    }
}
