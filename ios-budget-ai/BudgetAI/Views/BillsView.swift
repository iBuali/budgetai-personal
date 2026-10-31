import SwiftUI
import SwiftData

struct BillsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var context
    @Query(sort: \Bill.nextDueDate) private var bills: [Bill]
    @AppStorage(Keys.currency) private var currency = "BHD"
    @State private var editing: Bill?
    @State private var showNew = false

    private var unpaidRegular: [Bill] { bills.filter { !$0.isSubscription && !$0.isPaidForCurrentCycle() } }
    private var unpaidSubscriptions: [Bill] { bills.filter { $0.isSubscription && !$0.isPaidForCurrentCycle() } }
    private var paidThisMonth: [Bill] { bills.filter { $0.isPaidForCurrentCycle() } }

    var body: some View {
        List {
            Section {
                HStack(spacing: 0) {
                    summary("Bills", bills.reduce(0) { $0 + $1.monthlyCost })
                    Divider().frame(height: 40)
                    summary("Subscriptions", bills.filter(\.isSubscription).reduce(0) { $0 + $1.monthlyCost })
                }
                .padding(.vertical, 6)
            } footer: {
                Text("Swipe right on a bill to mark it paid. When paid via SMS or manually, it remains marked as paid for this month.")
            }

            if !unpaidRegular.isEmpty {
                Section("Due Bills") { ForEach(unpaidRegular, content: row) }
            }
            if !unpaidSubscriptions.isEmpty {
                Section("Due Subscriptions") { ForEach(unpaidSubscriptions, content: row) }
            }
            if !paidThisMonth.isEmpty {
                Section {
                    ForEach(paidThisMonth) { bill in
                        Button { editing = bill } label: {
                            BillRow(bill: bill, currency: currency)
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .leading) {
                            Button {
                                withAnimation(.spring(response: 0.45, dampingFraction: 0.7)) {
                                    bill.unmarkPaid()
                                    try? context.save()
                                    Notifier.rescheduleBills(bills)
                                    appState.show("\(bill.name) marked as unpaid")
                                }
                            } label: { Label("Unmark", systemImage: "arrow.uturn.backward") }
                            .tint(Theme.warning)
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                withAnimation {
                                    context.delete(bill)
                                    try? context.save()
                                    Notifier.rescheduleBills(bills.filter { $0.id != bill.id })
                                }
                            } label: { Label("Delete", systemImage: "trash") }
                        }
                    }
                } header: {
                    HStack {
                        Label("Paid this month · \(paidThisMonth.count)", systemImage: "checkmark.seal.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.positive)
                        Spacer()
                    }
                    .textCase(nil)
                } footer: {
                    Text("Paid for this month. Next cycle's due dates will appear automatically next month.")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .canvasBackground()
        .navigationTitle("Bills & Subscriptions")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Add bill", systemImage: "plus") { showNew = true }
            }
        }
        .overlay {
            if bills.isEmpty {
                ContentUnavailableView {
                    Label("No bills yet", systemImage: "calendar.badge.clock")
                } description: {
                    Text("Add rent, utilities and subscriptions to get reminders and a smarter Safe to Spend.")
                } actions: {
                    Button("Add bill") { showNew = true }.buttonStyle(.borderedProminent)
                }
            }
        }
        .sheet(item: $editing) { BillEditor(bill: $0) }
        .sheet(isPresented: $showNew) { BillEditor(bill: nil) }
    }

    private func summary(_ title: String, _ value: Double) -> some View {
        VStack(spacing: 4) {
            Text(title).font(.caption).foregroundStyle(Theme.secondaryInk)
            Text(Money.format(value, currency))
                .font(.headline.monospacedDigit())
                .foregroundStyle(Theme.ink)
                .animatedNumber(value)
            Text("per month").font(.caption2).foregroundStyle(Theme.secondaryInk)
        }
        .frame(maxWidth: .infinity)
    }

    private func row(_ bill: Bill) -> some View {
        Button { editing = bill } label: {
            BillRow(bill: bill, currency: currency)
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .leading) {
            Button {
                withAnimation(.spring(response: 0.45, dampingFraction: 0.7)) {
                    Ledger.payBill(bill, accountID: Ledger.defaultAccountID(context: context), context: context)
                    Notifier.rescheduleBills(bills)
                    appState.show("\(bill.name) marked as paid")
                }
            } label: { Label("Paid", systemImage: "checkmark") }
            .tint(Theme.positive)
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                withAnimation {
                    context.delete(bill)
                    try? context.save()
                    Notifier.rescheduleBills(bills.filter { $0.id != bill.id })
                }
            } label: { Label("Delete", systemImage: "trash") }
        }
    }
}

struct BillEditor: View {
    let bill: Bill?
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @AppStorage(Keys.currency) private var currency = "BHD"
    @State private var name = ""
    @State private var keywordsText = ""
    @State private var amountText = ""
    @State private var category: SpendCategory = .bills
    @State private var due = Date()
    @State private var frequency: BillFrequency = .monthly
    @State private var isSubscription = false
    @State private var reminders = true

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name (e.g. Batelco Fiber)", text: $name)
                        .onChange(of: name) { _, v in
                            guard bill == nil, let g = Categorizer.guess(v), g != .income else { return }
                            category = g
                            isSubscription = g == .subscriptions
                        }
                    TextField("SMS keywords (e.g. Batelco, SADAD)", text: $keywordsText)
                    HStack {
                        Text("Amount")
                        Spacer()
                        TextField(Money.format(0, currency), text: $amountText)
                            .keyboardType(.decimalPad).multilineTextAlignment(.trailing).monospacedDigit()
                    }
                    Picker("Category", selection: $category) {
                        ForEach(SpendCategory.expenseCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
                    }
                } footer: {
                    Text("Add keywords from your bank SMS (separated by commas). When an SMS arrives matching these keywords and the amount, the bill is automatically marked as paid.")
                }
                Section {
                    DatePicker("Next due", selection: $due, displayedComponents: .date)
                    Picker("Repeats", selection: $frequency) {
                        ForEach(BillFrequency.allCases) { Text($0.title).tag($0) }
                    }
                    Toggle("Subscription", isOn: $isSubscription)
                    Toggle("Remind me the day before", isOn: $reminders)
                }
                if let bill {
                    Section {
                        Button("Delete bill", role: .destructive) {
                            context.delete(bill)
                            try? context.save()
                            reschedule()
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(bill == nil ? "New bill" : "Edit bill")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save).fontWeight(.semibold)
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || (Money.parse(amountText) ?? 0) <= 0)
                }
            }
            .onAppear {
                guard let bill else { return }
                name = bill.name
                keywordsText = bill.keywordsRaw
                amountText = Money.number(bill.amount, decimals: Money.digits(currency)).replacingOccurrences(of: ",", with: "")
                category = bill.category
                due = bill.nextDueDate
                frequency = bill.frequency
                isSubscription = bill.isSubscription
                reminders = bill.remindersOn
            }
        }
    }

    private func save() {
        let amount = Money.parse(amountText) ?? 0
        let target = bill ?? {
            let b = Bill(name: "", amount: 0, category: category, nextDueDate: due)
            context.insert(b)
            return b
        }()
        target.name = name.trimmingCharacters(in: .whitespaces)
        target.keywordsRaw = keywordsText.trimmingCharacters(in: .whitespacesAndNewlines)
        target.amount = amount
        target.category = category
        target.nextDueDate = due
        target.frequency = frequency
        target.isSubscription = isSubscription
        target.remindersOn = reminders
        try? context.save()
        reschedule()
        if reminders { Task { await Notifier.requestAuthorization() } }
        dismiss()
    }

    private func reschedule() {
        let all = (try? context.fetch(FetchDescriptor<Bill>())) ?? []
        Notifier.rescheduleBills(all)
    }
}
