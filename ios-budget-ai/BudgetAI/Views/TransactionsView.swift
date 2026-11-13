import SwiftUI
import SwiftData

enum TxFilter: String, CaseIterable, Identifiable {
    case all = "All", income = "Income", expenses = "Expenses", transfers = "Transfers", review = "Needs Review"
    var id: String { rawValue }
}

enum TxDateRange: String, CaseIterable, Identifiable {
    case all = "All time", thisCycle = "This month", lastCycle = "Last month", last7 = "Last 7 days", last30 = "Last 30 days", custom = "Custom"
    var id: String { rawValue }
}

struct TxFilterState: Equatable {
    var kind: TxFilter = .all
    var range: TxDateRange = .all
    var customStart: Date = Calendar.current.date(byAdding: .day, value: -30, to: .now) ?? .now
    var customEnd: Date = .now
    var categories: Set<String> = []
    var accounts: Set<UUID> = []
    var smsOnly = false
    var duplicatesOnly = false

    /// Number of filters beyond the quick type chips.
    var activeCount: Int {
        (range == .all ? 0 : 1) + (categories.isEmpty ? 0 : 1) + (accounts.isEmpty ? 0 : 1) + (smsOnly ? 1 : 0) + (duplicatesOnly ? 1 : 0)
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
        switch kind {
        case .all: break
        case .review: if !tx.isPending && !tx.isPossibleDuplicate { return false }
        case .income: if !tx.isOrdinaryIncome { return false }
        case .expenses: if !tx.isSpending { return false }
        case .transfers: if !tx.isTransfer { return false }
        }
        if !ignoringDates, let interval, !(tx.date >= interval.start && tx.date < interval.end) { return false }
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

    private var pending: [MoneyTransaction] { transactions.filter(\.isPending) }
    private var needsReviewItems: [MoneyTransaction] { transactions.filter { $0.isPending || $0.isPossibleDuplicate } }

    private func matchesSearch(_ tx: MoneyTransaction) -> Bool {
        guard !query.isEmpty else { return true }
        return tx.merchant.localizedCaseInsensitiveContains(query)
            || tx.category.title.localizedCaseInsensitiveContains(query)
            || (tx.subcategory?.title.localizedCaseInsensitiveContains(query) ?? false)
            || tx.note.localizedCaseInsensitiveContains(query)
    }

    private var filtered: [MoneyTransaction] {
        if filters.kind == .review {
            return transactions.filter { ($0.isPending || $0.isPossibleDuplicate) && filters.matches($0, ignoringDates: mode == .calendar) && matchesSearch($0) }
        }
        if filters.kind == .all {
            return transactions.filter { filters.matches($0, ignoringDates: mode == .calendar) && matchesSearch($0) }
        }
        return transactions.filter { !$0.isPending && filters.matches($0, ignoringDates: mode == .calendar) && matchesSearch($0) }
    }

    private var grouped: [(day: Date, items: [MoneyTransaction])] {
        let cal = Calendar.current
        let groups = Dictionary(grouping: filtered) { cal.startOfDay(for: $0.date) }
        return groups.map { ($0.key, $0.value) }.sorted { $0.day > $1.day }
    }

    private var filteredTotals: (income: Double, spent: Double) {
        filtered.reduce((0, 0)) { acc, tx in
            guard !tx.isPending else { return acc }
            if tx.isOrdinaryIncome { return (acc.0 + tx.amount, acc.1) }
            if tx.isSpending { return (acc.0, acc.1 + tx.amount) }
            return acc
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    chips
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                    if filters.activeCount > 0 {
                        activeChips
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                    }
                }

                if filters.kind == .review {
                    if filtered.isEmpty {
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
                        let pendingFiltered = filtered.filter(\.isPending)
                        let duplicateFiltered = filtered.filter(\.isPossibleDuplicate)
                        Section {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(filtered.count) transaction\(filtered.count == 1 ? "" : "s") to review")
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(Theme.ink)
                                    if !pendingFiltered.isEmpty && !duplicateFiltered.isEmpty {
                                        Text("\(pendingFiltered.count) pending approval · \(duplicateFiltered.count) duplicate\(duplicateFiltered.count == 1 ? "" : "s")")
                                            .font(.caption)
                                            .foregroundStyle(Theme.secondaryInk)
                                    } else if !duplicateFiltered.isEmpty {
                                        Text("\(duplicateFiltered.count) possible duplicate\(duplicateFiltered.count == 1 ? "" : "s") (same SMS reference)")
                                            .font(.caption)
                                            .foregroundStyle(Theme.secondaryInk)
                                    } else {
                                        Text("\(pendingFiltered.count) pending approval")
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
                } else if filters.kind == .all && !needsReviewItems.isEmpty && query.isEmpty {
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
                                    Text("\(needsReviewItems.count) needing review")
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(Theme.ink)
                                    Text("Tap to open Needs Review tab, approve pending SMS, or resolve duplicates.")
                                        .font(.caption)
                                        .foregroundStyle(Theme.secondaryInk)
                                }
                                Spacer()
                                if !pending.isEmpty {
                                    Button("Approve all") {
                                        let count = pending.count
                                        withAnimation { _ = Ledger.approveAll(pending, context: context) }
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
                    if filters.activeCount > 0 || filters.kind != .all, !filtered.isEmpty {
                        Section { summaryRow }
                    }
                    listSections
                } else {
                    calendarSections
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .canvasBackground()
            .navigationTitle("Transactions")
            .searchable(text: $query, prompt: "Search transactions")
            .navigationDestination(for: UUID.self) { id in
                if let tx = transactions.first(where: { $0.id == id }) {
                    TransactionDetailView(tx: tx)
                }
            }
            .overlay {
                if mode == .list && filtered.isEmpty && filters.kind != .review {
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
                            Button("Clear filters") { withAnimation(.snappy) { filters = TxFilterState() } }
                        }
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if transactions.contains(where: { $0.category == .other && !$0.isIncome }) && GeminiAccount.isConfigured {
                        Button {
                            Task { await recategorize() }
                        } label: {
                            if categorizing { ProgressView() } else { Image(systemName: "sparkles") }
                        }
                        .accessibilityLabel("Categorize with AI")
                        .disabled(categorizing)
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    NavigationLink {
                        TransactionRulesListView()
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                    .accessibilityLabel("Transaction Rules")

                    Button {
                        withAnimation(.snappy) { mode = mode == .list ? .calendar : .list }
                    } label: {
                        Image(systemName: mode == .list ? "calendar" : "list.bullet")
                    }
                    .accessibilityLabel(mode == .list ? "Calendar view" : "List view")

                    Button { showFilters = true } label: {
                        Image(systemName: filters.activeCount > 0 ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                    }
                    .accessibilityLabel("Filters")

                    Menu {
                        Button("Add manually", systemImage: "doc.text") { appState.showAddTransaction = true }
                        Button("Paste bank SMS", systemImage: "message") { appState.showPasteSMS = true }
                        Divider()
                        Button("Import Bank Statement", systemImage: "doc.badge.arrow.up") { showStatementImport = true }
                        Button("Export Statement (Excel)", systemImage: "square.and.arrow.up") { showStatementExport = true }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add or Import")
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
                SMSImporter.reconcileExistingTransactions(context: context)
                applyRequestedFilterIfNeeded()
            }
            .onChange(of: appState.requestedTransactionsFilter) { _, _ in
                applyRequestedFilterIfNeeded()
            }
            .onChange(of: appState.tab) { _, newTab in
                if newTab == .transactions {
                    applyRequestedFilterIfNeeded()
                }
            }
            .sensoryFeedback(.success, trigger: approvedTick)
            .sensoryFeedback(.selection, trigger: mode)
        }
    }

    private func applyRequestedFilterIfNeeded() {
        guard let requested = appState.requestedTransactionsFilter else { return }
        withAnimation(.snappy) {
            filters = TxFilterState(kind: requested)
            mode = .list
        }
        appState.requestedTransactionsFilter = nil
    }

    // MARK: Pending

    private var pendingSection: some View {
        Section {
            ForEach(pending) { tx in
                NavigationLink(value: tx.id) {
                    TransactionRow(tx: tx, currency: currency)
                }
                .listRowBackground(Theme.warning.opacity(0.07))
                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                    Button {
                        approve(tx)
                    } label: { Label("Approve", systemImage: "checkmark") }
                    .tint(Theme.positive)
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        withAnimation { Ledger.delete(tx, context: context) }
                        appState.show("Rejected")
                    } label: { Label("Reject", systemImage: "xmark") }
                }
            }
        } header: {
            HStack {
                Label("Waiting for approval · \(pending.count)", systemImage: "clock.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.warning)
                Spacer()
                Button("Approve all") {
                    let count = pending.count
                    withAnimation { _ = Ledger.approveAll(pending, context: context) }
                    approvedTick += 1
                    appState.show("Approved \(count) transaction\(count == 1 ? "" : "s")")
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.cobalt)
            }
            .textCase(nil)
        } footer: {
            Text("Swipe right to approve, left to reject. Approved items update balances and budgets.")
        }
    }

    private func approve(_ tx: MoneyTransaction) {
        var result = LedgerResult()
        withAnimation { result = Ledger.approve(tx, context: context) }
        approvedTick += 1
        appState.report(result, base: "Approved \(Money.format(tx.amount, currency))")
    }

    // MARK: List

    @ViewBuilder
    private var listSections: some View {
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
                } label: { Label("Keep", systemImage: "checkmark") }
                .tint(Theme.positive)
            }
        }
    }

    private var summaryRow: some View {
        let t = filteredTotals
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(filtered.count) transaction\(filtered.count == 1 ? "" : "s")")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Theme.secondaryInk)
                    .animatedNumber(Double(filtered.count))
                Text(filters.rangeLabel).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                if t.income > 0 {
                    Text(Money.format(t.income, currency, signed: true))
                        .foregroundStyle(Theme.positive)
                        .animatedNumber(t.income)
                }
                Text(Money.format(-t.spent, currency, signed: true))
                    .foregroundStyle(Theme.ink)
                    .animatedNumber(-t.spent)
            }
            .font(.subheadline.weight(.semibold).monospacedDigit())
        }
    }

    // MARK: Calendar

    @ViewBuilder
    private var calendarSections: some View {
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

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(TxFilter.allCases) { f in
                    Button {
                        withAnimation(.snappy) { filters.kind = f }
                    } label: {
                        HStack(spacing: 6) {
                            Text(f.rawValue)
                            if f == .review && !needsReviewItems.isEmpty {
                                Text("\(needsReviewItems.count)")
                                    .font(.caption2.bold().monospacedDigit())
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(filters.kind == f ? .white.opacity(0.3) : Theme.warning, in: Capsule())
                                    .foregroundStyle(.white)
                            }
                        }
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                        .foregroundStyle(filters.kind == f ? .white : Theme.ink)
                        .background(filters.kind == f ? (f == .review ? Theme.warning : Theme.cobalt) : Theme.track.opacity(0.8), in: Capsule())
                    }
                    .buttonStyle(PressableStyle())
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 4)
        }
        .sensoryFeedback(.selection, trigger: filters.kind)
    }

    private var activeChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if filters.range != .all {
                    removable(filters.rangeLabel, symbol: "calendar") { filters.range = .all }
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
        return day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
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
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 6) {
                ForEach(Array(ordered.enumerated()), id: \.offset) { _, s in
                    Text(s).font(.caption2.weight(.semibold)).foregroundStyle(Theme.secondaryInk)
                }
                ForEach(Array(days.enumerated()), id: \.offset) { _, day in
                    if let day { cell(day) } else { Color.clear.frame(height: 48) }
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
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 8)], spacing: 8) {
                        ForEach(SpendCategory.allCases) { c in
                            toggleChip(c.menuTitle, on: draft.categories.contains(c.rawValue)) {
                                toggle(c.rawValue, in: &draft.categories)
                            }
                        }
                    }
                    .padding(.vertical, 4)
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
            .sensoryFeedback(.selection, trigger: draft)
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private func toggle(_ key: String, in set: inout Set<String>) {
        if set.contains(key) { set.remove(key) } else { set.insert(key) }
    }

    private func toggleChip(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .padding(.horizontal, 8)
                .foregroundStyle(on ? .white : Theme.ink)
                .background(on ? Theme.cobalt : Theme.track.opacity(0.8), in: Capsule())
        }
        .buttonStyle(.plain)
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
    @AppStorage(Keys.currency) private var currency = "BHD"
    @State private var confirmDelete = false
    @State private var editingCategory = false
    @State private var nameText = ""
    @State private var amountText = ""
    @State private var showLocationPicker = false
    @State private var isCapturingGPS = false
    @State private var showAddSenderBankAlert = false
    @State private var newSenderBankName = ""
    @FocusState private var focusedField: DetailField?

    private enum DetailField: Hashable {
        case name, amount
    }

    private var account: Account? { accounts.first { $0.id == tx.accountID } }
    private var toAccount: Account? { accounts.first { $0.id == tx.toAccountID } }
    private var isAccountTransfer: Bool { tx.isTransfer && tx.toAccountID != nil }
    private var isSMSTransaction: Bool { tx.source == .sms || tx.smsTransactionType != nil }

    private var matchedRecipientAccount: Account? {
        guard let recip = tx.smsRecipientSuffix, !recip.isEmpty else { return nil }
        return SMSParser.findMatchingAccount(suffix: recip, excludingAccountID: tx.accountID, in: context)
    }

    private var recipientDisplayText: String {
        let suffix = (tx.smsRecipientSuffix?.isEmpty == false ? tx.smsRecipientSuffix : nil)
            ?? (tx.smsAccountSuffix?.isEmpty == false ? tx.smsAccountSuffix : nil)
        let matchedDest = toAccount ?? ((tx.category == .internalTransfer || tx.effectiveTransactionType == .internalTransfer) ? matchedRecipientAccount : nil)
        if let suffix {
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
        return LocationService.inferLocation(from: tx.rawText, merchant: tx.merchant)
    }

    /// Computes the previous balance before this transaction occurred.
    private var previousBalanceAmount: Double? {
        if let smsBal = tx.smsBalance {
            if tx.isCardLimitBalance { return smsBal }
            return tx.isIncome ? max(0, smsBal - tx.amount) : (smsBal + tx.amount)
        }
        if let account {
            if tx.isPending { return account.balance }
            return tx.isIncome ? (account.balance - tx.amount) : (account.balance + tx.amount)
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
            editableFieldsSection
            locationSection
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
        }
        .onChange(of: focusedField) { oldValue, _ in
            if oldValue == .name {
                commitName(silent: true)
            } else if oldValue == .amount {
                commitAmount(silent: true)
                amountText = Money.number(tx.amount, decimals: Money.digits(currency)).replacingOccurrences(of: ",", with: "")
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
    }

    @ViewBuilder
    private var heroSection: some View {
        Section {
            VStack(spacing: 10) {
                if isAccountTransfer {
                    IconBadge(symbol: "arrow.left.arrow.right", color: Theme.cobalt, size: 64)
                } else {
                    CategoryIcon(category: tx.isIncome && tx.category == .other ? .income : tx.displayCategory, size: 64)
                }
                Text(tx.merchant).font(.title3.weight(.semibold)).foregroundStyle(Theme.ink).multilineTextAlignment(.center)
                let heroAmount = isAccountTransfer ? tx.amount : tx.signedAmount
                Text(isAccountTransfer ? Money.format(tx.amount, currency) : Money.format(tx.signedAmount, currency, signed: true))
                    .font(.system(size: 34, weight: .bold).monospacedDigit())
                    .foregroundStyle(tx.isPending ? Theme.secondaryInk : (tx.isIncome ? Theme.positive : Theme.ink))
                    .animatedNumber(heroAmount)
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
                        HStack {
                            Spacer()
                            Label("Approve and update account", systemImage: "checkmark.circle.fill")
                                .font(.body.weight(.semibold))
                            Spacer()
                        }
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.positive)

                    Button(role: .destructive) {
                        Ledger.delete(tx, context: context)
                        appState.show("Transaction rejected and removed")
                        dismiss()
                    } label: {
                        HStack {
                            Spacer()
                            Label("Reject", systemImage: "xmark.circle")
                                .font(.body.weight(.medium))
                            Spacer()
                        }
                        .padding(.vertical, 2)
                    }
                    .buttonStyle(.bordered)
                    .tint(Theme.negative)
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
    private var editableFieldsSection: some View {
        Section("Transaction") {
            HStack(spacing: 8) {
                Text("Name")
                Spacer()
                TextField("Merchant or title", text: $nameText)
                    .multilineTextAlignment(.trailing)
                    .focused($focusedField, equals: .name)
                    .submitLabel(.done)
                    .onChange(of: nameText) { _, newValue in
                        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty, trimmed != tx.merchant else { return }
                        tx.merchant = trimmed
                        try? context.save()
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
                    .onChange(of: amountText) { _, newValue in
                        guard let parsed = Money.parse(newValue), parsed > 0, abs(parsed - tx.amount) >= 0.0005 else { return }
                        Ledger.edit(tx, context: context) { target in
                            target.amount = abs(parsed)
                        }
                    }
            }

            DatePicker(
                "Date",
                selection: Binding(
                    get: { tx.date },
                    set: { newDate in
                        tx.date = newDate
                        Ledger.recordSnapshot(context: context)
                        try? context.save()
                    }
                ),
                displayedComponents: [.date, .hourAndMinute]
            )

            Button {
                withAnimation(.snappy) { editingCategory.toggle() }
            } label: {
                HStack(spacing: 12) {
                    Text("Category").foregroundStyle(Theme.ink)
                    Spacer()
                    CategoryIcon(category: tx.category, size: 28)
                    Text(tx.category.title).foregroundStyle(Theme.ink)
                    if tx.aiCategorized { AIBadge() }
                    Image(systemName: "chevron.down")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(editingCategory ? 180 : 0))
                }
            }
            .buttonStyle(.plain)

            if editingCategory {
                CategoryPickerGrid(
                    category: Binding(get: { tx.category }, set: { new in
                        applySelectedCategory(new)
                    }),
                    subcategory: Binding(get: { tx.subcategory }, set: { newSub in
                        tx.subcategory = newSub
                        try? context.save()
                    }),
                    income: tx.isIncome,
                    includeAllTypes: true
                )
            }

            Picker("Account", selection: Binding(get: { tx.accountID }, set: { newID in
                Ledger.edit(tx, context: context) { target in
                    target.accountID = newID
                }
            })) {
                Text(isSMSTransaction ? "Unknown" : "None").tag(UUID?.none)
                ForEach(accounts) { a in Text(a.menuTitle).tag(UUID?.some(a.id)) }
            }

            transferAccountPickers

            if !goals.isEmpty && tx.category != .visaTransfer {
                savingsGoalPicker
            }

            TextField("Note", text: $tx.note, axis: .vertical)
                .onChange(of: tx.note) { _, _ in
                    try? context.save()
                }
        }
    }

    @ViewBuilder
    private var transferAccountPickers: some View {
        if tx.category == .visaTransfer {
            Picker("Visa card", selection: Binding(get: { tx.toAccountID }, set: { newID in
                guard newID != tx.accountID else { return }
                Ledger.edit(tx, context: context) { $0.toAccountID = newID }
            })) {
                Text("Select card").tag(UUID?.none)
                ForEach(accounts.filter { $0.kind == .creditCard }) { a in
                    Text(a.menuTitle).tag(UUID?.some(a.id))
                }
            }
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
            Picker("To account", selection: Binding(get: { tx.toAccountID ?? matchedRecipientAccount?.id }, set: { newID in
                guard newID != tx.accountID else { return }
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
            })) {
                Text("Select destination").tag(UUID?.none)
                ForEach(accounts.filter { $0.id != tx.accountID }) { a in
                    Text(a.menuTitle).tag(UUID?.some(a.id))
                }
            }
        }
    }

    @ViewBuilder
    private var savingsGoalPicker: some View {
        Picker("Savings goal", selection: Binding(get: { tx.goalID }, set: { newGoalID in
            let linkedAccountID = newGoalID.flatMap { id in goals.first(where: { $0.id == id })?.linkedAccountID }
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
        })) {
            Text("None").tag(UUID?.none)
            ForEach(goals) { g in
                Text(g.name).tag(UUID?.some(g.id))
            }
        }
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
        } else if tx.category == .internalTransfer || tx.category == .visaTransfer || tx.smsTransactionType == .internalTransfer || tx.isIncome != new.isIncomeCategory {
            Ledger.edit(tx, context: context) { target in
                target.subcategory = nil
                target.category = new
                target.toAccountID = nil
                target.goalID = nil
                target.smsBalanceIsCardLimit = false
                target.isIncome = new.isIncomeCategory
                if isSMSTransaction {
                    target.smsTransactionType = new.isIncomeCategory ? .income : (new == .transfers ? .transferOut : .expense)
                }
                target.aiCategorized = false
            }
        } else {
            if new != tx.category { tx.subcategory = nil }
            tx.category = new
            tx.aiCategorized = false
            try? context.save()
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
            TransactionDetailRulesSection(tx: tx, accounts: accounts)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
        }
    }

    @ViewBuilder
    private var smsDetailsSection: some View {
        Section("SMS Details") {
            Picker("SMS sender bank", selection: Binding(
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
            )) {
                Text("Unknown / Not set").tag("")
                if let currentBank = tx.smsBank, !currentBank.isEmpty,
                   !BahrainBankCatalog.allBanks.contains(where: { $0.caseInsensitiveCompare(currentBank) == .orderedSame }) {
                    Text(currentBank).tag(currentBank)
                }
                ForEach(BahrainBankCatalog.allBanks, id: \.self) { bank in
                    Text(bank).tag(bank)
                }
            }

            Button {
                newSenderBankName = ""
                showAddSenderBankAlert = true
            } label: {
                Label("Create Sender Bank...", systemImage: "plus.circle")
            }
            .alert("Create Sender Bank", isPresented: $showAddSenderBankAlert) {
                TextField("Bank or sender name (e.g. HSBC)", text: $newSenderBankName)
                Button("Add") {
                    if let created = BahrainBankCatalog.addCustomBank(newSenderBankName) {
                        commitPendingEdits(silent: true)
                        Ledger.edit(tx, context: context) { target in
                            target.smsBank = created
                        }
                        try? context.save()
                        appState.show("Created & set bank to \(created)")
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Enter a bank or SMS sender name to add it to your sender bank list.")
            }

            LabeledContent("Reference") {
                Text((tx.smsReference?.isEmpty == false) ? tx.smsReference! : "—")
                    .font(.subheadline.monospaced())
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
                    if let smsBal = tx.smsBalance, !tx.isCardLimitBalance, abs(account.balance - smsBal) >= 0.0005 {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("\(account.name) (\(Money.format(account.balance, currency)))")
                                .monospacedDigit()
                                .animatedNumber(account.balance)
                            Text("SMS: \(Money.format(smsBal, currency))")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(Theme.secondaryInk)
                        }
                    } else {
                        Text("\(account.name) (\(Money.format(account.balance, currency)))")
                            .monospacedDigit()
                            .animatedNumber(account.balance)
                    }
                } else if let smsBal = tx.smsBalance {
                    Text(Money.format(smsBal, currency))
                        .monospacedDigit()
                } else {
                    Text("None").foregroundStyle(Theme.secondaryInk)
                }
            }

            if let bank = tx.smsBalance, let account, !account.kind.isLiability, !tx.isCardLimitBalance {
                if abs(account.balance - bank) >= 0.0005 && !tx.isPending {
                    Button {
                        if let synced = Ledger.syncBalanceFromSMS(tx, context: context, force: true) {
                            appState.show("\(account.name) set to \(Money.format(synced, currency))")
                        }
                    } label: {
                        Label("Match \(account.name) to bank balance", systemImage: "equal.circle.fill")
                    }
                } else if tx.balanceAdjustment != 0 {
                    Label("\(account.name) matched (\(Money.format(tx.balanceAdjustment, currency, signed: true)))", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(Theme.positive)
                }
            }

            if let toBal = tx.smsToBalance, let toID = tx.toAccountID, let toAccount = Ledger.account(toID, context: context) {
                Divider()

                LabeledContent("Destination previous balance") {
                    let destPrev = max(0, toBal - tx.amount)
                    Text(Money.format(destPrev, currency))
                        .monospacedDigit()
                }

                LabeledContent("Destination new balance") {
                    Text("\(toAccount.name) (\(Money.format(toAccount.balance, currency)))")
                        .monospacedDigit()
                        .animatedNumber(toAccount.balance)
                }

                if !toAccount.kind.isLiability {
                    if abs(toAccount.balance - toBal) >= 0.0005 && !tx.isPending {
                        Button {
                            if let synced = Ledger.syncBalanceForAccount(id: toID, balance: toBal, on: tx, isToAccount: true, context: context, force: true) {
                                appState.show("\(toAccount.name) set to \(Money.format(synced, currency))")
                            }
                        } label: {
                            Label("Match \(toAccount.name) to bank balance", systemImage: "equal.circle.fill")
                        }
                    } else if tx.toBalanceAdjustment != 0 {
                        Label("\(toAccount.name) matched (\(Money.format(tx.toBalanceAdjustment, currency, signed: true)))", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(Theme.positive)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Classification reason").font(.caption).foregroundStyle(Theme.secondaryInk)
                Text(tx.smsClassificationReason.isEmpty ? "—" : tx.smsClassificationReason)
                    .font(.footnote)
                    .foregroundStyle(Theme.ink)
            }
        }
    }

    @ViewBuilder
    private var rawMessagesSection: some View {
        Section(rawSMSMessages.count > 1 ? "Original SMS messages (\(rawSMSMessages.count))" : "Original message") {
            if rawSMSMessages.count > 1 {
                ForEach(Array(rawSMSMessages.enumerated()), id: \.offset) { idx, msg in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(smsLegHeaderTitle(index: idx, message: msg))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(idx == 0 ? Theme.ink : Theme.positive)
                        Text(msg)
                            .font(.footnote)
                            .foregroundStyle(Theme.secondaryInk)
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, 2)
                }
            } else {
                Text(rawSMSMessages[0])
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryInk)
                    .textSelection(.enabled)
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

    private func commitPendingEdits(silent: Bool) {
        if hasUnsavedName { commitName(silent: silent) }
        if hasUnsavedAmount { commitAmount(silent: silent) }
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
