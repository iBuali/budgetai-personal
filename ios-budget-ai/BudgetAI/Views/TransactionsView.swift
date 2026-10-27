import SwiftUI
import SwiftData

enum TxFilter: String, CaseIterable, Identifiable {
    case all = "All", income = "Income", expenses = "Expenses", transfers = "Transfers"
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
    @State private var showBanks = false
    @State private var categorizing = false
    @State private var calendarMonth = Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: .now)) ?? .now
    @State private var selectedDay: Date = Calendar.current.startOfDay(for: .now)
    @State private var approvedTick = 0

    private var pending: [MoneyTransaction] { transactions.filter(\.isPending) }

    private func matchesSearch(_ tx: MoneyTransaction) -> Bool {
        guard !query.isEmpty else { return true }
        return tx.merchant.localizedCaseInsensitiveContains(query)
            || tx.category.title.localizedCaseInsensitiveContains(query)
            || (tx.subcategory?.title.localizedCaseInsensitiveContains(query) ?? false)
            || tx.note.localizedCaseInsensitiveContains(query)
    }

    private var filtered: [MoneyTransaction] {
        transactions.filter { !$0.isPending && filters.matches($0, ignoringDates: mode == .calendar) && matchesSearch($0) }
    }

    private var grouped: [(day: Date, items: [MoneyTransaction])] {
        let cal = Calendar.current
        let groups = Dictionary(grouping: filtered) { cal.startOfDay(for: $0.date) }
        return groups.map { ($0.key, $0.value) }.sorted { $0.day > $1.day }
    }

    private var filteredTotals: (income: Double, spent: Double) {
        filtered.reduce((0, 0)) { acc, tx in
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

                if !pending.isEmpty && query.isEmpty {
                    pendingSection
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
                if mode == .list && filtered.isEmpty && pending.isEmpty {
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
                        Button("Connect bank", systemImage: "building.columns") { showBanks = true }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add transaction")
                }
            }
            .sheet(isPresented: $showBanks) {
                NavigationStack { BankConnectionsView(isSheet: true) }
            }
            .sheet(isPresented: $showFilters) {
                TransactionFilterSheet(filters: $filters, accounts: accounts)
            }
            .sensoryFeedback(.success, trigger: approvedTick)
            .sensoryFeedback(.selection, trigger: mode)
        }
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
        .listRowBackground(tx.isPossibleDuplicate ? Theme.negative.opacity(0.07) : Theme.surface)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                withAnimation { Ledger.delete(tx, context: context) }
            } label: { Label("Delete", systemImage: "trash") }
        }
        .swipeActions(edge: .leading) {
            if tx.isPossibleDuplicate {
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
                Text("\(filtered.count) transaction\(filtered.count == 1 ? "" : "s")").font(.caption).foregroundStyle(Theme.secondaryInk)
                Text(filters.rangeLabel).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                if t.income > 0 {
                    Text(Money.format(t.income, currency, signed: true)).foregroundStyle(Theme.positive)
                }
                Text(Money.format(-t.spent, currency, signed: true)).foregroundStyle(Theme.ink)
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
                        Text(f.rawValue)
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 9)
                            .foregroundStyle(filters.kind == f ? .white : Theme.ink)
                            .background(filters.kind == f ? Theme.cobalt : Theme.track.opacity(0.8), in: Capsule())
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
                        .font(.subheadline.monospacedDigit()).foregroundStyle(Theme.secondaryInk)
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
                        ForEach(SpendCategory.allCases.filter { !$0.isSubcategory }) { c in
                            toggleChip(c.menuTitle, on: draft.categories.contains(c.rawValue)) {
                                toggle(c.rawValue, in: &draft.categories)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("Categories")
                } footer: {
                    Text("Sub-categories are included with their parent.")
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
    @AppStorage(Keys.currency) private var currency = "BHD"
    @State private var confirmDelete = false
    @State private var editingCategory = false

    private var account: Account? { accounts.first { $0.id == tx.accountID } }
    private var toAccount: Account? { accounts.first { $0.id == tx.toAccountID } }
    private var isAccountTransfer: Bool { tx.isTransfer && tx.toAccountID != nil }

    var body: some View {
        List {
            Section {
                VStack(spacing: 10) {
                    if isAccountTransfer {
                        IconBadge(symbol: "arrow.left.arrow.right", color: Theme.cobalt, size: 64)
                    } else {
                        CategoryIcon(category: tx.isIncome && tx.category == .other ? .income : tx.displayCategory, size: 64)
                    }
                    Text(tx.merchant).font(.title3.weight(.semibold)).foregroundStyle(Theme.ink).multilineTextAlignment(.center)
                    Text(isAccountTransfer ? Money.format(tx.amount, currency) : Money.format(tx.signedAmount, currency, signed: true))
                        .font(.system(size: 34, weight: .bold).monospacedDigit())
                        .foregroundStyle(tx.isPending ? Theme.secondaryInk : (tx.isIncome ? Theme.positive : Theme.ink))
                    Text(tx.date.formatted(date: .complete, time: .shortened)).font(.subheadline).foregroundStyle(Theme.secondaryInk)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .listRowBackground(Color.clear)
            }

            if tx.isPending {
                Section {
                    Label("Imported from SMS and waiting for your approval. It doesn't affect balances or budgets yet.", systemImage: "clock.fill")
                        .foregroundStyle(Theme.warning)
                    Button {
                        let result = Ledger.approve(tx, context: context)
                        appState.report(result, base: "Approved \(Money.format(tx.amount, currency))")
                    } label: {
                        Label("Approve", systemImage: "checkmark.circle.fill").fontWeight(.semibold)
                    }
                    .foregroundStyle(Theme.positive)
                    Button("Reject", role: .destructive) {
                        Ledger.delete(tx, context: context)
                        dismiss()
                    }
                }
            }

            if tx.isPossibleDuplicate {
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

            if isAccountTransfer {
                Section("Transfer") {
                    Picker("From", selection: Binding(get: { tx.accountID }, set: { newID in
                        guard newID != tx.toAccountID else { return }
                        Ledger.edit(tx, context: context) { $0.accountID = newID }
                    })) {
                        ForEach(accounts) { a in Text(a.menuTitle).tag(UUID?.some(a.id)) }
                    }
                    Picker("To", selection: Binding(get: { tx.toAccountID }, set: { newID in
                        guard newID != tx.accountID else { return }
                        Ledger.edit(tx, context: context) { $0.toAccountID = newID }
                    })) {
                        ForEach(accounts) { a in Text(a.menuTitle).tag(UUID?.some(a.id)) }
                    }
                    TextField("Note", text: $tx.note, axis: .vertical)
                }
            } else {
                Section("Category") {
                    Button {
                        withAnimation(.snappy) { editingCategory.toggle() }
                    } label: {
                        HStack(spacing: 12) {
                            CategoryIcon(category: tx.displayCategory, size: 34)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(tx.category.title).foregroundStyle(Theme.ink)
                                if let sub = tx.subcategory {
                                    Text(sub.title).font(.caption).foregroundStyle(Theme.secondaryInk)
                                }
                            }
                            Spacer()
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
                                if new != tx.category { tx.subcategory = nil }
                                tx.category = new
                                tx.aiCategorized = false
                                try? context.save()
                            }),
                            subcategory: Binding(get: { tx.subcategory }, set: { tx.subcategory = $0; try? context.save() }),
                            income: tx.isIncome
                        )
                    }
                }

                Section("Details") {
                    Picker("Account", selection: Binding(get: { tx.accountID }, set: { newID in
                        Ledger.edit(tx, context: context) { $0.accountID = newID }
                    })) {
                        Text("None").tag(UUID?.none)
                        ForEach(accounts) { a in Text(a.menuTitle).tag(UUID?.some(a.id)) }
                    }
                    if tx.effectiveTransactionType == .internalTransfer {
                        Picker("To account", selection: Binding(get: { tx.toAccountID }, set: { newID in
                            guard newID != tx.accountID else { return }
                            Ledger.edit(tx, context: context) { $0.toAccountID = newID }
                        })) {
                            Text("Select destination").tag(UUID?.none)
                            ForEach(accounts.filter { $0.id != tx.accountID }) { a in
                                Text(a.menuTitle).tag(UUID?.some(a.id))
                            }
                        }
                    }
                    LabeledContent("Source") {
                        HStack(spacing: 6) {
                            Text(tx.source.title)
                            if tx.aiCategorized { AIBadge() }
                        }
                    }
                    TextField("Note", text: $tx.note, axis: .vertical)
                }
            }

            if tx.source == .sms || tx.smsTransactionType != nil {
                Section {
                    Picker("Transaction type", selection: Binding(
                        get: { tx.effectiveTransactionType },
                        set: { newType in
                            let result = Ledger.applyUserCorrection(
                                to: tx,
                                newType: newType,
                                newBank: tx.smsBank,
                                toAccountID: tx.toAccountID,
                                approveIfPending: false,
                                rememberRule: true,
                                context: context
                            )
                            appState.report(result, base: "Updated to \(newType.title)")
                        }
                    )) {
                        ForEach(SMSTransactionType.allCases) { t in
                            Text(t.title).tag(t)
                        }
                    }

                    Picker("SMS sender bank", selection: Binding(
                        get: { tx.smsBank ?? "" },
                        set: { newBank in
                            let clean = newBank.isEmpty ? nil : newBank
                            tx.smsBank = clean
                            if let clean, let sender = tx.smsSender, !sender.isEmpty {
                                SMSUserRules.rememberBank(clean, forSender: sender)
                            }
                            if let raw = tx.rawText, !raw.isEmpty, tx.effectiveTransactionType != .unknown {
                                SMSUserRules.rememberClassification(
                                    type: tx.effectiveTransactionType,
                                    category: tx.category,
                                    bank: clean,
                                    toAccountID: tx.toAccountID,
                                    forRawSMS: raw,
                                    sender: tx.smsSender,
                                    counterparty: tx.smsRecipientSuffix ?? Finance.merchantKey(tx.merchant)
                                )
                            }
                            try? context.save()
                            appState.show(clean.map { "Bank set to \($0)" } ?? "Cleared SMS bank")
                        }
                    )) {
                        Text("Unknown / Not set").tag("")
                        ForEach(BahrainBankCatalog.bahrainBanks, id: \.self) { bank in
                            Text(bank).tag(bank)
                        }
                    }

                    if let ref = tx.smsReference, !ref.isEmpty {
                        LabeledContent("Reference") {
                            Text(ref).font(.subheadline.monospaced()).foregroundStyle(Theme.ink)
                        }
                    }
                    if let recip = tx.smsRecipientSuffix, !recip.isEmpty {
                        LabeledContent("Recipient IBAN / acct") {
                            Text("••\(recip)").font(.subheadline.monospacedDigit()).foregroundStyle(Theme.ink)
                        }
                    }
                    if let acct = tx.smsAccountSuffix, !acct.isEmpty {
                        LabeledContent("Card / account suffix") {
                            Text("••\(acct)").font(.subheadline.monospacedDigit()).foregroundStyle(Theme.ink)
                        }
                    }
                    if let conf = tx.smsConfidence {
                        LabeledContent("Confidence") {
                            Text(conf.title)
                                .foregroundStyle(conf == .low ? Theme.warning : Theme.secondaryInk)
                        }
                    }
                    if !tx.smsClassificationReason.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Classification reason").font(.caption).foregroundStyle(Theme.secondaryInk)
                            Text(tx.smsClassificationReason).font(.footnote).foregroundStyle(Theme.ink)
                        }
                    }
                } header: {
                    Text("SMS classification & bank")
                } footer: {
                    Text("Corrections update balances and totals and are remembered for matching future messages.")
                }
            }

            if let bank = tx.smsBalance {
                Section {
                    LabeledContent("Balance in SMS") {
                        Text(Money.format(bank, currency)).monospacedDigit()
                    }
                    if let account, !account.kind.isLiability {
                        LabeledContent("\(account.name) in app") {
                            Text(Money.format(account.balance, currency)).monospacedDigit()
                        }
                        if abs(account.balance - bank) >= 0.0005 && !tx.isPending {
                            Button {
                                if let synced = Ledger.syncBalanceFromSMS(tx, context: context, force: true) {
                                    appState.show("\(account.name) set to \(Money.format(synced, currency))")
                                }
                            } label: {
                                Label("Match account to bank balance", systemImage: "equal.circle.fill")
                            }
                        } else if tx.balanceAdjustment != 0 {
                            Label("Matched to bank (\(Money.format(tx.balanceAdjustment, currency, signed: true)))", systemImage: "checkmark.seal.fill")
                                .foregroundStyle(Theme.positive)
                        }
                    }
                } header: {
                    Text("Bank balance")
                } footer: {
                    Text("Your bank included the available balance in this message.")
                }
            }

            if let raw = tx.rawText, !raw.isEmpty {
                Section("Original message") {
                    Text(raw).font(.footnote).foregroundStyle(Theme.secondaryInk).textSelection(.enabled)
                }
            }

            Section {
                Button("Delete transaction", role: .destructive) { confirmDelete = true }
            }
        }
        .scrollContentBackground(.hidden)
        .canvasBackground()
        .navigationTitle(isAccountTransfer ? "Transfer" : "Transaction")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .onDisappear { try? context.save() }
        .confirmationDialog("Delete this transaction?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                Ledger.delete(tx, context: context)
                dismiss()
            }
        }
    }
}
