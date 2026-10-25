import SwiftUI
import SwiftData

enum TxFilter: String, CaseIterable, Identifiable {
    case all = "All", income = "Income", expenses = "Expenses", sms = "From SMS", duplicates = "Duplicates"
    var id: String { rawValue }
}

struct TransactionsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var context
    @Query(sort: \MoneyTransaction.date, order: .reverse) private var transactions: [MoneyTransaction]
    @AppStorage(Keys.currency) private var currency = "BHD"
    @State private var query = ""
    @State private var filter: TxFilter = .all
    @State private var showBanks = false
    @State private var categorizing = false

    private var filtered: [MoneyTransaction] {
        transactions.filter { tx in
            let matchesFilter: Bool
            switch filter {
            case .all: matchesFilter = true
            case .income: matchesFilter = tx.isIncome
            case .expenses: matchesFilter = !tx.isIncome
            case .sms: matchesFilter = tx.source == .sms
            case .duplicates: matchesFilter = tx.isPossibleDuplicate
            }
            guard matchesFilter else { return false }
            guard !query.isEmpty else { return true }
            return tx.merchant.localizedCaseInsensitiveContains(query)
                || tx.category.title.localizedCaseInsensitiveContains(query)
                || tx.note.localizedCaseInsensitiveContains(query)
        }
    }

    private var grouped: [(day: Date, items: [MoneyTransaction])] {
        let cal = Calendar.current
        let groups = Dictionary(grouping: filtered) { cal.startOfDay(for: $0.date) }
        return groups.map { ($0.key, $0.value) }.sorted { $0.day > $1.day }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    chips
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                        .listRowBackground(Color.clear)
                }
                ForEach(grouped, id: \.day) { group in
                    Section {
                        ForEach(group.items) { tx in
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
                    } header: {
                        Text(dayTitle(group.day))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.secondaryInk)
                            .textCase(nil)
                    }
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
                if filtered.isEmpty {
                    if transactions.isEmpty {
                        ContentUnavailableView {
                            Label("No transactions yet", systemImage: "list.bullet.rectangle")
                        } description: {
                            Text("Add one manually or paste a bank SMS. Set up automatic SMS import in Profile.")
                        } actions: {
                            Button("Add transaction") { appState.showAddTransaction = true }
                                .buttonStyle(.borderedProminent)
                        }
                    } else {
                        ContentUnavailableView.search(text: query)
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
                ToolbarItem(placement: .topBarTrailing) {
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
        }
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(TxFilter.allCases) { f in
                    Button {
                        withAnimation(.snappy) { filter = f }
                    } label: {
                        Text(f.rawValue)
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 9)
                            .foregroundStyle(filter == f ? .white : Theme.ink)
                            .background(filter == f ? Theme.cobalt : Theme.track.opacity(0.8), in: Capsule())
                    }
                    .buttonStyle(PressableStyle())
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 4)
        }
        .sensoryFeedback(.selection, trigger: filter)
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

// MARK: - Detail

struct TransactionDetailView: View {
    @Bindable var tx: MoneyTransaction
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var accounts: [Account]
    @AppStorage(Keys.currency) private var currency = "BHD"
    @State private var confirmDelete = false

    var body: some View {
        List {
            Section {
                VStack(spacing: 10) {
                    CategoryIcon(category: tx.isIncome ? .income : tx.category, size: 64)
                    Text(tx.merchant).font(.title3.weight(.semibold)).foregroundStyle(Theme.ink)
                    Text(Money.format(tx.signedAmount, currency, signed: true))
                        .font(.system(size: 34, weight: .bold).monospacedDigit())
                        .foregroundStyle(tx.isIncome ? Theme.positive : Theme.ink)
                    Text(tx.date.formatted(date: .complete, time: .shortened)).font(.subheadline).foregroundStyle(Theme.secondaryInk)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .listRowBackground(Color.clear)
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

            Section("Details") {
                Picker("Category", selection: Binding(get: { tx.category }, set: { tx.category = $0; tx.aiCategorized = false; try? context.save() })) {
                    ForEach(SpendCategory.allCases) { c in Label(c.title, systemImage: c.symbol).tag(c) }
                }
                Picker("Account", selection: Binding(get: { tx.accountID }, set: { newID in
                    Ledger.edit(tx, context: context) { $0.accountID = newID }
                })) {
                    Text("None").tag(UUID?.none)
                    ForEach(accounts) { a in Text(a.name).tag(UUID?.some(a.id)) }
                }
                LabeledContent("Source") {
                    HStack(spacing: 6) {
                        Text(tx.source.title)
                        if tx.aiCategorized { AIBadge() }
                    }
                }
                TextField("Note", text: $tx.note, axis: .vertical)
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
        .navigationTitle("Transaction")
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
