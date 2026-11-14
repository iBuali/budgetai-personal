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
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    AccountIcon(account: account, size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(account.name)
                                .foregroundStyle(Theme.ink)
                                .lineLimit(1)
                                .minimumScaleFactor(0.85)
                            if account.kind.isLiability {
                                dueBadge(for: account)
                            }
                        }
                        let baseSubtitle = account.institution.isEmpty ? account.kind.title : "\(account.kind.title) · \(account.institution)"
                        let extraSubtitle: String = {
                            if account.kind == .loan && account.loanMonthlyInstallment > 0 {
                                return "\(baseSubtitle) · \(Money.format(account.loanMonthlyInstallment, currency))/mo"
                            }
                            return baseSubtitle
                        }()
                        Text(account.includeInNetWorth ? extraSubtitle : "\(extraSubtitle) · Excluded from net worth")
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

                if account.kind == .creditCard && account.cardLimit > 0 {
                    LiabilityProgressBar(
                        progress: account.cardUsedProgress,
                        tint: account.cardUsedProgress >= 0.9 ? Theme.negative : (account.cardUsedProgress >= 0.7 ? Theme.warning : Theme.cobalt),
                        leadingText: "Used \(Money.format(account.cardUsedBalance, currency))",
                        trailingText: "Remaining \(Money.format(account.cardRemainingBalance, currency))"
                    )
                } else if account.kind == .loan && account.loanOriginalAmount > 0 {
                    LiabilityProgressBar(
                        progress: account.loanPaidProgress,
                        tint: Theme.positive,
                        leadingText: "Paid \(Money.format(account.loanPaidAmount, currency))",
                        trailingText: "Remaining \(Money.format(account.loanRemainingBalance, currency))"
                    )
                }
            }
            .padding(.vertical, 2)
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
    @ViewBuilder
    private func dueBadge(for account: Account) -> some View {
        let due = account.nextUpcomingDueDate()
        let days = account.daysUntilDue()
        let label = days == 0 ? "Due today" : "Due \(due.formatted(.dateTime.day().month(.abbreviated)))"
        let tint: Color = days <= 3 && account.balance > 0.0005 ? Theme.warning : Theme.secondaryInk
        HStack(spacing: 3) {
            if account.paymentDueReminder {
                Image(systemName: "bell.fill")
                    .font(.system(size: 9, weight: .semibold))
            }
            Text(label)
                .font(.caption2.weight(.semibold))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(tint.opacity(0.12), in: Capsule())
    }
}

private struct LiabilityProgressBar: View {
    let progress: Double
    let tint: Color
    let leadingText: String
    let trailingText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geo in
                let clamped = min(1, max(0, progress))
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(tint.opacity(0.14))
                    Capsule()
                        .fill(tint)
                        .frame(width: max(clamped > 0 ? 6 : 0, geo.size.width * clamped))
                }
            }
            .frame(height: 6)

            HStack {
                Text(leadingText)
                    .font(.caption2.weight(.medium).monospacedDigit())
                    .foregroundStyle(Theme.secondaryInk)
                Spacer()
                Text(trailingText)
                    .font(.caption2.weight(.medium).monospacedDigit())
                    .foregroundStyle(Theme.secondaryInk)
            }
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
    @State private var creditLimitText = ""
    @State private var loanTotalAmountText = ""
    @State private var loanMonthlyInstallmentText = ""
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
                    if kind == .creditCard {
                        HStack {
                            Text("Card limit")
                            Spacer()
                            TextField(Money.format(0, currency), text: $creditLimitText)
                                .keyboardType(.numbersAndPunctuation)
                                .multilineTextAlignment(.trailing)
                                .monospacedDigit()
                        }
                        HStack {
                            Text("Used balance")
                            Spacer()
                            TextField(Money.format(0, currency), text: $balanceText)
                                .keyboardType(.numbersAndPunctuation)
                                .multilineTextAlignment(.trailing)
                                .monospacedDigit()
                        }
                        let limitVal = max(0, Money.parse(creditLimitText) ?? 0)
                        let usedVal = max(0, Money.parse(balanceText) ?? 0)
                        if limitVal > 0 {
                            let remainingVal = max(0, limitVal - usedVal)
                            let ratio = min(1, max(0, usedVal / limitVal))
                            LiabilityProgressBar(
                                progress: ratio,
                                tint: ratio >= 0.9 ? Theme.negative : (ratio >= 0.7 ? Theme.warning : Theme.cobalt),
                                leadingText: "Used \(Money.format(usedVal, currency))",
                                trailingText: "Remaining \(Money.format(remainingVal, currency))"
                            )
                            .padding(.vertical, 4)
                        }
                    } else if kind == .loan {
                        HStack {
                            Text("Total loan amount")
                            Spacer()
                            TextField(Money.format(0, currency), text: $loanTotalAmountText)
                                .keyboardType(.numbersAndPunctuation)
                                .multilineTextAlignment(.trailing)
                                .monospacedDigit()
                        }
                        HStack {
                            Text("Remaining balance")
                            Spacer()
                            TextField(Money.format(0, currency), text: $balanceText)
                                .keyboardType(.numbersAndPunctuation)
                                .multilineTextAlignment(.trailing)
                                .monospacedDigit()
                        }
                        HStack {
                            Text("Monthly installment")
                            Spacer()
                            TextField(Money.format(0, currency), text: $loanMonthlyInstallmentText)
                                .keyboardType(.numbersAndPunctuation)
                                .multilineTextAlignment(.trailing)
                                .monospacedDigit()
                        }
                        let totalVal = max(Money.parse(loanTotalAmountText) ?? 0, max(0, Money.parse(balanceText) ?? 0))
                        let remVal = max(0, Money.parse(balanceText) ?? 0)
                        if totalVal > 0 {
                            let paidVal = max(0, totalVal - remVal)
                            let ratio = min(1, max(0, paidVal / totalVal))
                            LiabilityProgressBar(
                                progress: ratio,
                                tint: Theme.positive,
                                leadingText: "Paid \(Money.format(paidVal, currency))",
                                trailingText: "Remaining \(Money.format(remVal, currency))"
                            )
                            .padding(.vertical, 4)
                        }
                    } else {
                        HStack {
                            Text(kind == .property || kind == .investment ? "Current value" : "Balance")
                            Spacer()
                            TextField(Money.format(0, currency), text: $balanceText)
                                .keyboardType(.numbersAndPunctuation)
                                .multilineTextAlignment(.trailing)
                                .monospacedDigit()
                        }
                    }
                    Toggle("Include in net worth", isOn: $includeInNetWorth)
                } header: {
                    if kind == .creditCard {
                        Text("Visa Card Balance")
                    } else if kind == .loan {
                        Text("Loan Details")
                    }
                } footer: {
                    if !includeInNetWorth {
                        Text("Excluded from your net worth total and Spendable balance in Safe to Spend.")
                    } else if kind == .creditCard {
                        Text("Used balance updates automatically from linked Visa transactions and payments. Subtracted from net worth.")
                    } else if kind == .loan {
                        Text("Remaining balance updates automatically from recorded loan payments. Subtracted from net worth.")
                    } else {
                        Text("Counts toward your assets, net worth, and Spendable balance in Safe to Spend.")
                    }
                }
                if kind == .bank || kind == .creditCard || kind == .cash {
                    Section {
                        TextField(kind == .creditCard ? "Card number or last digits, e.g. 4821" : "Account or card digits, e.g. 3876 or 3876, 4821", text: $smsMatch)
                            .keyboardType(.numbersAndPunctuation)
                            .onChange(of: smsMatch) { _, v in
                                let normalized = SMSParser.normalizeText(v)
                                let filtered = String(normalized.filter { $0.isNumber || $0 == "," || $0 == " " }.prefix(48))
                                if filtered != v { smsMatch = filtered }
                            }
                    } header: {
                        Text(kind == .creditCard ? "Card number or digits in SMS" : "Card or account digits in SMS")
                    } footer: {
                        Text(kind == .creditCard ? "Bank SMS messages mentioning this card number or its last digits will be routed to this credit card automatically." : "Bank messages mentioning these IBAN, account, or card digits are filed to this account automatically. Separate multiple numbers with a comma (e.g. 3876, 4821).")
                    }
                }
                if kind.isLiability {
                    Section {
                        DatePicker("Payment due date", selection: $paymentDueDate, displayedComponents: .date)
                        Toggle(isOn: $paymentDueReminder.animation(.snappy)) {
                            Label("Payment due reminder", systemImage: "bell.badge.fill")
                        }
                        if paymentDueReminder {
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
                        Text(kind == .loan ? "Loan payment reminder" : "Visa payment reminder")
                    } footer: {
                        Text(paymentDueReminder
                             ? "You'll get a notification at 9:00 AM \(reminderDaysBefore == 0 ? "on the due date" : "\(reminderDaysBefore) day\(reminderDaysBefore == 1 ? "" : "s") before it and again on the due date") every month."
                             : "Turn on to get a monthly reminder before your \(kind == .loan ? "loan installment" : "card payment") is due.")
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
                let decimals = Money.digits(currency)
                balanceText = Money.number(account.balance, decimals: decimals).replacingOccurrences(of: ",", with: "")
                if account.balance < 0 { balanceText = "-" + balanceText }
                if account.creditLimit > 0 {
                    creditLimitText = Money.number(account.creditLimit, decimals: decimals).replacingOccurrences(of: ",", with: "")
                }
                if account.loanTotalAmount > 0 {
                    loanTotalAmountText = Money.number(account.loanTotalAmount, decimals: decimals).replacingOccurrences(of: ",", with: "")
                }
                if account.loanMonthlyInstallment > 0 {
                    loanMonthlyInstallmentText = Money.number(account.loanMonthlyInstallment, decimals: decimals).replacingOccurrences(of: ",", with: "")
                }
            }
        }
    }

    private func save() {
        let balance = Money.parse(balanceText) ?? 0
        let parsedCreditLimit = max(0, Money.parse(creditLimitText) ?? 0)
        let parsedLoanTotal = max(0, Money.parse(loanTotalAmountText) ?? 0)
        let parsedInstallment = max(0, Money.parse(loanMonthlyInstallmentText) ?? 0)
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
        target.creditLimit = kind == .creditCard ? parsedCreditLimit : 0
        target.loanTotalAmount = kind == .loan ? max(parsedLoanTotal, balance) : 0
        target.loanMonthlyInstallment = kind == .loan ? parsedInstallment : 0
        target.paymentDueReminder = kind.isLiability && paymentDueReminder
        target.paymentDueDate = paymentDueDate
        target.paymentReminderDaysBefore = reminderDaysBefore
        let trimmedMatch = target.smsMatch.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedMatch.isEmpty {
            let txs = (try? context.fetch(FetchDescriptor<MoneyTransaction>())) ?? []
            for tx in txs where tx.source == .sms && tx.accountID == nil {
                let raw = tx.rawText ?? ""
                let reparsedSuffix = raw.isEmpty ? nil : SMSParser.extractSuffixes(in: raw).accountSuffix
                let candidateSuffix = reparsedSuffix ?? tx.smsAccountSuffix
                let matchedBySuffix = candidateSuffix.map { SMSParser.digitsMatch(accountMatch: trimmedMatch, query: $0) } ?? false
                let matchedInText = !raw.isEmpty && SMSParser.findAccountInSMSText(raw, detectedBank: tx.smsBank, in: context)?.id == target.id
                if matchedBySuffix || matchedInText {
                    if let reparsedSuffix, !reparsedSuffix.isEmpty {
                        tx.smsAccountSuffix = reparsedSuffix
                    }
                    if tx.isPending {
                        tx.accountID = target.id
                    } else {
                        Ledger.edit(tx, context: context) { $0.accountID = target.id }
                    }
                }
            }
        }
        SMSImporter.reconcileExistingTransactions(context: context)
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
