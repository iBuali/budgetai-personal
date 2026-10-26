import SwiftUI
import SwiftData

enum EntryKind: String, CaseIterable, Identifiable {
    case expense = "Expense", income = "Income", transfer = "Transfer"
    var id: String { rawValue }
}

struct AddTransactionSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Account.createdAt) private var accounts: [Account]
    @AppStorage(Keys.currency) private var currency = "BHD"

    @State private var kind: EntryKind = .expense
    @State private var amountText = ""
    @State private var merchant = ""
    @State private var category: SpendCategory = .other
    @State private var subcategory: SpendCategory?
    @State private var userPickedCategory = false
    @State private var accountID: UUID?
    @State private var toAccountID: UUID?
    @State private var date = Date()
    @State private var note = ""
    @State private var repeatsMonthly = false
    @State private var saved = false
    @FocusState private var amountFocused: Bool

    private var amount: Double { Money.parse(amountText) ?? 0 }
    private var isIncome: Bool { kind == .income }

    private var canSave: Bool {
        guard amount > 0 else { return false }
        if kind == .transfer { return accountID != nil && toAccountID != nil && accountID != toAccountID }
        return true
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Type", selection: $kind) {
                        ForEach(EntryKind.allCases) { Text($0.rawValue).tag($0) }
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
                            .foregroundStyle(kind == .income ? Theme.positive : (kind == .transfer ? Theme.cobalt : Theme.ink))
                            .keyboardType(.decimalPad)
                            .focused($amountFocused)
                            .minimumScaleFactor(0.5)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .listRowBackground(Color.clear)
                }

                if kind == .transfer {
                    transferSections
                } else {
                    Section {
                        TextField(isIncome ? "From (e.g. Salary)" : "Merchant (e.g. Lulu Hypermarket)", text: $merchant)
                            .textInputAutocapitalization(.words)
                            .onChange(of: merchant) { _, value in
                                guard !userPickedCategory, !isIncome, let guess = Categorizer.guess(value),
                                      guess != .income, guess != .transfers else { return }
                                withAnimation(.snappy) { category = guess; subcategory = nil }
                            }
                        CategoryPickerGrid(category: $category, subcategory: $subcategory, income: isIncome) {
                            userPickedCategory = true
                        }
                    }

                    Section {
                        Picker("Account", selection: $accountID) {
                            Text("None").tag(UUID?.none)
                            ForEach(accounts) { a in Text(a.menuTitle).tag(UUID?.some(a.id)) }
                        }
                        DatePicker("Date", selection: $date, in: ...Date.now.addingTimeInterval(86_400 * 365))
                        TextField("Note", text: $note, axis: .vertical)
                        if !isIncome {
                            Toggle("Repeats monthly", isOn: $repeatsMonthly)
                        }
                    } footer: {
                        if repeatsMonthly && !isIncome { Text("We'll add it to Bills and remind you before it's due.") }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .canvasBackground()
            .navigationTitle(kind == .transfer ? "Transfer" : (isIncome ? "Add income" : "Add expense"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save).fontWeight(.semibold).disabled(!canSave)
                }
            }
            .sensoryFeedback(.success, trigger: saved)
            .sensoryFeedback(.selection, trigger: kind)
            .onChange(of: kind) { _, newKind in
                subcategory = nil
                userPickedCategory = false
                category = newKind == .income ? .income : .other
            }
            .onAppear {
                accountID = Ledger.defaultAccountID(context: context)
                amountFocused = true
            }
        }
        .presentationDragIndicator(.visible)
    }

    // MARK: Transfer

    @ViewBuilder
    private var transferSections: some View {
        Section("From") {
            ForEach(accounts) { a in
                accountChoice(a, selected: accountID == a.id, disabled: false) {
                    accountID = a.id
                    if toAccountID == a.id { toAccountID = nil }
                }
            }
        }
        Section("To") {
            ForEach(accounts) { a in
                accountChoice(a, selected: toAccountID == a.id, disabled: a.id == accountID) { toAccountID = a.id }
            }
        }
        Section {
            DatePicker("Date", selection: $date, in: ...Date.now.addingTimeInterval(86_400 * 365))
            TextField("Note", text: $note, axis: .vertical)
        } footer: {
            if let from = accounts.first(where: { $0.id == accountID }), let to = accounts.first(where: { $0.id == toAccountID }), amount > 0 {
                Text("\(from.name) \(Money.format(balance(from), currency)) → \(Money.format(balance(from) - amount, currency)). \(to.name) \(Money.format(balance(to), currency)) → \(Money.format(balance(to) + amount, currency)).")
            } else {
                Text("Transfers move money between your accounts and don't count as spending.")
            }
        }
    }

    /// Value as shown to the user (liabilities shown as negative).
    private func balance(_ a: Account) -> Double { a.kind.isLiability ? -a.balance : a.balance }

    private func accountChoice(_ a: Account, selected: Bool, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                AccountIcon(account: a, size: 36)
                VStack(alignment: .leading, spacing: 1) {
                    Text(a.name).foregroundStyle(Theme.ink)
                    Text(a.kind.title).font(.caption).foregroundStyle(Theme.secondaryInk)
                }
                Spacer()
                Text(Money.format(balance(a), currency))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(a.kind.isLiability ? Theme.negative : Theme.secondaryInk)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selected ? Theme.cobalt : Color(hex: 0xC7CCD6))
            }
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
    }

    // MARK: Save

    private func save() {
        if kind == .transfer {
            guard let from = accounts.first(where: { $0.id == accountID }), let to = accounts.first(where: { $0.id == toAccountID }) else { return }
            Ledger.transfer(amount: amount, from: from, to: to, date: date, note: note, context: context)
            saved = true
            appState.show("Moved \(Money.format(amount, currency)) to \(to.name)")
            dismiss()
            return
        }
        let name = merchant.trimmingCharacters(in: .whitespaces)
        let cat: SpendCategory = isIncome && !category.isIncomeCategory ? .income : category
        let tx = MoneyTransaction(amount: amount, isIncome: isIncome,
                                  merchant: name.isEmpty ? (subcategory ?? cat).title : name,
                                  category: cat, date: date, note: note, source: .manual, accountID: accountID)
        tx.subcategory = subcategory
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
    @State private var accountID: UUID?
    @Query(sort: \Account.createdAt) private var accounts: [Account]

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
                    Picker("Account", selection: $accountID) {
                        Text("Detect automatically").tag(UUID?.none)
                        ForEach(accounts) { a in Text(a.menuTitle).tag(UUID?.some(a.id)) }
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
                            if let synced = outcome.balanceSynced {
                                Label("Account balance matched to bank: \(Money.format(synced, currency))", systemImage: "equal.circle.fill")
                                    .foregroundStyle(Theme.cobalt)
                            }
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
            .onAppear { if accountID == nil { accountID = AppSettings.smsAccountID } }
        }
    }

    private func run() async {
        working = true
        let result = await SMSImporter.importText(text, context: context, forceApprove: true, accountID: accountID)
        working = false
        withAnimation { outcome = result }
        if result.transaction != nil {
            text = ""
            if let alert = result.alerts.first { appState.show(alert, warning: true) }
        }
    }
}
