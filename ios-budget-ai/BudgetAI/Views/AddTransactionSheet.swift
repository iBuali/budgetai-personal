import SwiftUI
import SwiftData

struct AddTransactionSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Account.createdAt) private var accounts: [Account]
    @AppStorage(Keys.currency) private var currency = "BHD"

    @State private var isIncome = false
    @State private var amountText = ""
    @State private var merchant = ""
    @State private var category: SpendCategory = .other
    @State private var userPickedCategory = false
    @State private var accountID: UUID?
    @State private var date = Date()
    @State private var note = ""
    @State private var repeatsMonthly = false
    @State private var saved = false
    @FocusState private var amountFocused: Bool

    private var amount: Double { Money.parse(amountText) ?? 0 }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Type", selection: $isIncome) {
                        Text("Expense").tag(false)
                        Text("Income").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())

                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(Money.symbol(currency))
                            .font(.title.weight(.semibold))
                            .foregroundStyle(Theme.secondaryInk)
                        TextField(Money.number(0, decimals: Money.digits(currency)), text: $amountText)
                            .font(.system(size: 48, weight: .bold).monospacedDigit())
                            .foregroundStyle(isIncome ? Theme.positive : Theme.ink)
                            .keyboardType(.decimalPad)
                            .focused($amountFocused)
                            .minimumScaleFactor(0.5)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .listRowBackground(Color.clear)
                }

                Section {
                    TextField(isIncome ? "From (e.g. Salary)" : "Merchant (e.g. Lulu Hypermarket)", text: $merchant)
                        .textInputAutocapitalization(.words)
                        .onChange(of: merchant) { _, value in
                            guard !userPickedCategory, let guess = Categorizer.guess(value) else { return }
                            withAnimation(.snappy) { category = guess }
                        }
                    if !isIncome {
                        categoryGrid
                    }
                }

                Section {
                    Picker("Account", selection: $accountID) {
                        Text("None").tag(UUID?.none)
                        ForEach(accounts) { a in Label(a.name, systemImage: a.kind.symbol).tag(UUID?.some(a.id)) }
                    }
                    DatePicker("Date", selection: $date, in: ...Date.now.addingTimeInterval(86_400 * 365))
                    TextField("Note", text: $note, axis: .vertical)
                    if !isIncome {
                        Toggle("Repeats monthly", isOn: $repeatsMonthly)
                    }
                } footer: {
                    if repeatsMonthly { Text("We'll add it to Bills and remind you before it's due.") }
                }
            }
            .scrollContentBackground(.hidden)
            .canvasBackground()
            .navigationTitle(isIncome ? "Add income" : "Add expense")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save).fontWeight(.semibold).disabled(amount <= 0)
                }
            }
            .sensoryFeedback(.success, trigger: saved)
            .onAppear {
                accountID = Ledger.defaultAccountID(context: context)
                amountFocused = true
            }
        }
        .presentationDragIndicator(.visible)
    }

    private var categoryGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 12) {
            ForEach(SpendCategory.expenseCases) { c in
                Button {
                    category = c
                    userPickedCategory = true
                } label: {
                    VStack(spacing: 6) {
                        CategoryIcon(category: c, size: 44)
                            .overlay(
                                RoundedRectangle(cornerRadius: 13, style: .continuous)
                                    .stroke(category == c ? c.color : .clear, lineWidth: 2)
                            )
                        Text(c.shortTitle)
                            .font(.caption2.weight(category == c ? .semibold : .regular))
                            .foregroundStyle(category == c ? Theme.ink : Theme.secondaryInk)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                }
                .buttonStyle(PressableStyle())
            }
        }
        .padding(.vertical, 6)
        .sensoryFeedback(.selection, trigger: category)
    }

    private func save() {
        let name = merchant.trimmingCharacters(in: .whitespaces)
        let cat: SpendCategory = isIncome ? .income : category
        let tx = MoneyTransaction(amount: amount, isIncome: isIncome,
                                  merchant: name.isEmpty ? (isIncome ? "Income" : cat.title) : name,
                                  category: cat, date: date, note: note, source: .manual, accountID: accountID)
        let result = Ledger.add(tx, context: context)
        if repeatsMonthly && !isIncome {
            let next = Calendar.current.date(byAdding: .month, value: 1, to: date) ?? date
            let bill = Bill(name: tx.merchant, amount: amount, category: cat, nextDueDate: next, isSubscription: cat == .subscriptions)
            context.insert(bill)
            try? context.save()
            let all = (try? context.fetch(FetchDescriptor<Bill>())) ?? []
            Notifier.rescheduleBills(all)
        }
        saved = true
        appState.report(result, base: "Saved \(Money.format(amount, currency))")
        dismiss()
    }
}

struct PasteSMSSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @AppStorage(Keys.currency) private var currency = "BHD"
    @State private var text = ""
    @State private var working = false
    @State private var outcome: SMSImportOutcome?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $text)
                        .frame(minHeight: 140)
                        .overlay(alignment: .topLeading) {
                            if text.isEmpty {
                                Text("Paste a bank SMS, e.g. \"Your NBB card ending 1234 was used for BHD 6.750 at TALABAT on 24-Oct.\"")
                                    .foregroundStyle(.tertiary)
                                    .padding(.top, 8)
                                    .padding(.leading, 4)
                                    .allowsHitTesting(false)
                            }
                        }
                    Button("Paste from clipboard", systemImage: "doc.on.clipboard") {
                        if let s = UIPasteboard.general.string { text = s }
                    }
                } footer: {
                    HStack(spacing: 4) {
                        if GeminiAccount.isConfigured {
                            Image(systemName: "sparkles")
                            Text("Gemini reads the message and picks a category.")
                        } else {
                            Text("Read on-device. Connect Gemini in Profile for smarter reading.")
                        }
                    }
                }

                if let outcome {
                    Section("Result") {
                        if let tx = outcome.transaction {
                            TransactionRow(tx: tx, currency: currency)
                            if outcome.usedAI { LabeledContent("Read by") { AIBadge() } }
                            if outcome.flaggedDuplicate {
                                Label("Flagged as a possible duplicate", systemImage: "exclamationmark.circle.fill").foregroundStyle(Theme.negative)
                            }
                        } else {
                            Label(outcome.message, systemImage: "questionmark.circle").foregroundStyle(Theme.secondaryInk)
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .canvasBackground()
            .navigationTitle("Paste bank SMS")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(outcome?.transaction == nil ? "Cancel" : "Done") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if working {
                        ProgressView()
                    } else {
                        Button("Import") { Task { await run() } }
                            .fontWeight(.semibold)
                            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .sensoryFeedback(.success, trigger: outcome?.transaction?.id)
        }
    }

    private func run() async {
        working = true
        let result = await SMSImporter.importText(text, context: context)
        working = false
        withAnimation { outcome = result }
        if result.transaction != nil {
            text = ""
            if let alert = result.alerts.first { appState.show(alert, warning: true) }
        }
    }
}
