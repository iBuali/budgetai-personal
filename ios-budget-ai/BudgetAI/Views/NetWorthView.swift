import SwiftUI
import SwiftData
import Charts

struct NetWorthView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Account.createdAt) private var accounts: [Account]
    @Query(sort: \NetWorthSnapshot.day) private var snapshots: [NetWorthSnapshot]
    @AppStorage(Keys.currency) private var currency = "BHD"
    @State private var range = 2
    @State private var editing: Account?
    @State private var showNew = false
    @State private var selectedDate: Date?

    private let ranges = [(label: "3M", months: 3), (label: "6M", months: 6), (label: "1Y", months: 12), (label: "All", months: 1200)]

    private var finance: Finance { Finance(transactions: [], accounts: accounts) }

    private var points: [ChartPoint] {
        let start = Calendar.current.date(byAdding: .month, value: -ranges[range].months, to: .now) ?? .distantPast
        return snapshots.filter { $0.day >= start }.map { ChartPoint(date: $0.day, value: $0.netWorth) }
    }

    var body: some View {
        let f = finance
        let pts = points
        let change = (pts.last?.value ?? f.netWorth) - (pts.first?.value ?? f.netWorth)
        let selected = selectedDate.flatMap { d in pts.min(by: { abs($0.date.timeIntervalSince(d)) < abs($1.date.timeIntervalSince(d)) }) }
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    let heroValue = selected?.value ?? f.netWorth
                    Text(selected.map { $0.date.formatted(date: .abbreviated, time: .omitted) } ?? "Net worth")
                        .font(.subheadline).foregroundStyle(Theme.secondaryInk)
                    Text(Money.format(heroValue, currency))
                        .font(.system(size: 36, weight: .bold).monospacedDigit())
                        .foregroundStyle(Theme.ink)
                        .minimumScaleFactor(0.6).lineLimit(1)
                        .animatedNumber(heroValue)
                    Text("\(Money.format(change, currency, signed: true)) in \(ranges[range].label == "All" ? "total" : ranges[range].label)")
                        .font(.subheadline.weight(.medium).monospacedDigit())
                        .foregroundStyle(change >= 0 ? Theme.positive : Theme.negative)
                        .animatedNumber(change)
                    Chart(pts) { p in
                        AreaMark(x: .value("Date", p.date), y: .value("Net worth", p.value))
                            .interpolationMethod(.catmullRom)
                            .foregroundStyle(LinearGradient(colors: [Theme.cobalt.opacity(0.16), Theme.cobalt.opacity(0.01)], startPoint: .top, endPoint: .bottom))
                        LineMark(x: .value("Date", p.date), y: .value("Net worth", p.value))
                            .interpolationMethod(.catmullRom)
                            .foregroundStyle(Theme.cobalt)
                            .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        if let selected, selected.date == p.date {
                            RuleMark(x: .value("Date", p.date)).foregroundStyle(Theme.ink.opacity(0.2))
                            PointMark(x: .value("Date", p.date), y: .value("Net worth", p.value)).foregroundStyle(Theme.cobalt)
                        }
                    }
                    .chartXSelection(value: $selectedDate)
                    .chartYScale(domain: .automatic(includesZero: false))
                    .chartYAxis {
                        AxisMarks(position: .trailing) { v in
                            AxisGridLine().foregroundStyle(Theme.track)
                            AxisValueLabel { if let d = v.as(Double.self) { Text(Money.short(d)) } }
                        }
                    }
                    .frame(height: 180)
                    .padding(.top, 8)
                    .overlay {
                        if pts.count < 2 {
                            Text("History builds up as you use the app").font(.footnote).foregroundStyle(Theme.secondaryInk)
                        }
                    }
                    Picker("Range", selection: $range) {
                        ForEach(ranges.indices, id: \.self) { Text(ranges[$0].label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .padding(.top, 6)
                }
                .padding(.vertical, 6)
            }

            Section {
                LabeledContent {
                    Text(Money.format(f.totalAssets, currency))
                        .monospacedDigit()
                        .foregroundStyle(Theme.positive)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .layoutPriority(1)
                        .animatedNumber(f.totalAssets)
                } label: {
                    Text("Assets")
                }
                LabeledContent {
                    Text(Money.format(f.totalLiabilities, currency))
                        .monospacedDigit()
                        .foregroundStyle(Theme.negative)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .layoutPriority(1)
                        .animatedNumber(f.totalLiabilities)
                } label: {
                    Text("Liabilities")
                }
            }

            let assets = accounts.filter { !$0.kind.isLiability }
            let liabilities = accounts.filter { $0.kind.isLiability }
            if !assets.isEmpty {
                Section("Assets") { ForEach(assets, content: accountRow) }
            }
            if !liabilities.isEmpty {
                Section("Loans & liabilities") { ForEach(liabilities, content: accountRow) }
            }
            Section {
                Button("Add account or asset", systemImage: "plus.circle.fill") { showNew = true }
            }
        }
        .scrollContentBackground(.hidden)
        .canvasBackground()
        .navigationTitle("Net Worth")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .sheet(item: $editing) { AccountEditor(account: $0) }
        .sheet(isPresented: $showNew) { AccountEditor(account: nil) }
    }

    private func accountRow(_ account: Account) -> some View {
        Button { editing = account } label: {
            HStack(spacing: 12) {
                AccountIcon(account: account, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.name)
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    let baseSubtitle = account.institution.isEmpty ? account.kind.title : "\(account.kind.title) · \(account.institution)"
                    let dueSubtitle = account.kind == .creditCard && account.paymentDueReminder
                        ? "\(baseSubtitle) · Due \(account.nextUpcomingDueDate().formatted(.dateTime.day().month(.abbreviated)))"
                        : baseSubtitle
                    Text(account.includeInNetWorth ? dueSubtitle : "\(dueSubtitle) · Excluded from net worth")
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryInk)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                Spacer(minLength: 8)
                let signedBalance = account.kind.isLiability ? -account.balance : account.balance
                Text(Money.format(signedBalance, currency))
                    .font(.body.weight(.medium).monospacedDigit())
                    .foregroundStyle(!account.includeInNetWorth ? Theme.secondaryInk : (account.kind.isLiability ? Theme.negative : Theme.ink))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .layoutPriority(1)
                    .animatedNumber(signedBalance)
            }
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .leading) {
            Button {
                withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
                    account.includeInNetWorth.toggle()
                    Ledger.recordSnapshot(context: context)
                    try? context.save()
                }
            } label: {
                Label(
                    account.includeInNetWorth ? "Exclude" : "Include",
                    systemImage: account.includeInNetWorth ? "eye.slash" : "eye"
                )
            }
            .tint(Theme.cobalt)
        }
        .swipeActions {
            Button(role: .destructive) {
                context.delete(account)
                Ledger.recordSnapshot(context: context)
                try? context.save()
            } label: { Label("Delete", systemImage: "trash") }
        }
    }
}

struct AccountEditor: View {
    let account: Account?
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @AppStorage(Keys.currency) private var currency = "BHD"
    @State private var name = ""
    @State private var kind: AccountKind = .bank
    @State private var institution = ""
    @State private var balanceText = ""
    @State private var emoji = ""
    @State private var smsMatch = ""
    @State private var includeInNetWorth = true
    @State private var paymentDueReminder = false
    @State private var paymentDueDate = Calendar.current.date(byAdding: .day, value: 14, to: .now) ?? .now
    @State private var reminderDaysBefore = 3

    var body: some View {
        NavigationStack {
            Form {
                Section("Icon") {
                    EmojiPicker(emoji: $emoji, suggestions: EmojiPicker.accountSuggestions)
                }
                Section {
                    TextField("Name (e.g. NBB Current)", text: $name)
                    Picker("Type", selection: $kind) {
                        ForEach(AccountKind.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
                    }
                    TextField("Bank or provider (optional)", text: $institution)
                }
                Section {
                    HStack {
                        Text(kind.isLiability ? "Amount owed" : (kind == .property || kind == .investment ? "Current value" : "Balance"))
                        Spacer()
                        TextField(Money.format(0, currency), text: $balanceText)
                            .keyboardType(.numbersAndPunctuation)
                            .multilineTextAlignment(.trailing)
                            .monospacedDigit()
                    }
                    Toggle("Include in net worth", isOn: $includeInNetWorth)
                } footer: {
                    if !includeInNetWorth {
                        Text("Excluded from your net worth total.")
                    } else {
                        Text(kind.isLiquid ? "Counts toward your cash & bank balance, net worth, and Safe to Spend." : (kind.isLiability ? "Subtracted from your net worth." : "Counts toward your net worth."))
                    }
                }
                if kind == .bank || kind == .creditCard || kind == .cash {
                    Section {
                        TextField(kind == .creditCard ? "Card number or last digits, e.g. 4821" : "Account or card digits, e.g. 4821", text: $smsMatch)
                            .keyboardType(.numberPad)
                            .onChange(of: smsMatch) { _, v in
                                let digits = String(v.filter(\.isNumber).prefix(19))
                                if digits != v { smsMatch = digits }
                            }
                    } header: {
                        Text(kind == .creditCard ? "Card number or digits in SMS" : "Card or account digits in SMS")
                    } footer: {
                        Text(kind == .creditCard ? "Bank SMS messages mentioning this card number or its last digits will be routed to this credit card automatically." : "Bank messages mentioning these digits are filed to this account automatically.")
                    }
                }
                if kind == .creditCard {
                    Section {
                        Toggle(isOn: $paymentDueReminder.animation(.snappy)) {
                            Label("Payment due reminder", systemImage: "bell.badge.fill")
                        }
                        if paymentDueReminder {
                            DatePicker("Payment due date", selection: $paymentDueDate, displayedComponents: .date)
                            Stepper(value: $reminderDaysBefore, in: 0...14) {
                                HStack {
                                    Text("Remind me")
                                    Spacer()
                                    Text(reminderDaysBefore == 0 ? "On the due date" : "\(reminderDaysBefore) day\(reminderDaysBefore == 1 ? "" : "s") before")
                                        .foregroundStyle(Theme.secondaryInk)
                                        .monospacedDigit()
                                }
                            }
                        }
                    } header: {
                        Text("Visa payment")
                    } footer: {
                        Text(paymentDueReminder
                             ? "You'll get a notification at 9:00 AM \(reminderDaysBefore == 0 ? "on the due date" : "\(reminderDaysBefore) day\(reminderDaysBefore == 1 ? "" : "s") before it and again on the due date") every month, so you can pay before the bank deducts late fees. Paying the card in full moves the reminder to next month."
                             : "Turn on to get a monthly reminder before your card payment is due.")
                    }
                }
                if let account {
                    Section {
                        Button("Delete", role: .destructive) {
                            context.delete(account)
                            Ledger.recordSnapshot(context: context)
                            try? context.save()
                            Notifier.rescheduleCreditCards((try? context.fetch(FetchDescriptor<Account>())) ?? [])
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(account == nil ? "New account" : "Edit account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save).fontWeight(.semibold).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear {
                guard let account else { return }
                name = account.name
                kind = account.kind
                institution = account.institution
                emoji = account.emoji
                smsMatch = account.smsMatch
                includeInNetWorth = account.includeInNetWorth
                paymentDueReminder = account.paymentDueReminder
                paymentDueDate = account.paymentDueDate
                reminderDaysBefore = account.paymentReminderDaysBefore
                balanceText = Money.number(account.balance, decimals: Money.digits(currency)).replacingOccurrences(of: ",", with: "")
                if account.balance < 0 { balanceText = "-" + balanceText }
            }
        }
    }

    private func save() {
        let balance = Money.parse(balanceText) ?? 0
        let target: Account
        if let account {
            target = account
            account.name = name.trimmingCharacters(in: .whitespaces)
            account.kind = kind
            account.institution = institution
            account.balance = balance
            account.emoji = emoji
            account.smsMatch = smsMatch
            account.includeInNetWorth = includeInNetWorth
        } else {
            let new = Account(name: name.trimmingCharacters(in: .whitespaces), kind: kind, institution: institution, balance: balance, emoji: emoji, includeInNetWorth: includeInNetWorth)
            new.smsMatch = smsMatch
            context.insert(new)
            target = new
        }
        target.paymentDueReminder = kind == .creditCard && paymentDueReminder
        target.paymentDueDate = paymentDueDate
        target.paymentReminderDaysBefore = reminderDaysBefore
        Ledger.recordSnapshot(context: context)
        try? context.save()
        let all = (try? context.fetch(FetchDescriptor<Account>())) ?? []
        if target.paymentDueReminder {
            Task {
                _ = await Notifier.requestAuthorization()
                Notifier.rescheduleCreditCards(all)
            }
        } else {
            Notifier.rescheduleCreditCards(all)
        }
        dismiss()
    }
}
