import SwiftUI
import SwiftData
import Charts

struct NetWorthView: View {
    var initialAccountID: UUID? = nil
    var isRootTab: Bool = false
    @Environment(\.modelContext) private var context
    @Query(sort: \Account.createdAt) private var accounts: [Account]
    @Query(sort: \NetWorthSnapshot.day) private var snapshots: [NetWorthSnapshot]
    @AppStorage(Keys.currency) private var currency = "BHD"
    @AppStorage(Keys.netWorthChartExcludedAccounts) private var chartExcludedRaw = ""
    @State private var editing: Account?
    @State private var showNew = false
    @State private var showChartAccountsPicker = false
    @State private var didOpenInitialAccount = false

    private var finance: Finance { Finance(transactions: [], accounts: accounts) }

    var body: some View {
        let f = finance
        ScrollViewReader { proxy in
            List {
            NetWorthChartSection(
                accounts: accounts,
                snapshots: snapshots,
                currentNetWorth: f.netWorth,
                currency: currency,
                chartExcludedRaw: $chartExcludedRaw,
                onOpenPicker: { showChartAccountsPicker = true }
            )

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
        .navigationTitle(isRootTab ? "Accounts" : "Net Worth")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(isRootTab ? .visible : .hidden, for: .tabBar)
        .toolbar {
            if isRootTab {
                ToolbarItem(placement: .topBarLeading) {
                    DrawerMenuToolbarButtons()
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Add", systemImage: "plus") { showNew = true }
            }
        }
        .sheet(item: $editing) { AccountEditor(account: $0) }
        .sheet(isPresented: $showNew) { AccountEditor(account: nil) }
        .sheet(isPresented: $showChartAccountsPicker) {
            NetWorthChartAccountsSheet(
                accounts: accounts,
                currency: currency,
                excludedRaw: $chartExcludedRaw
            )
        }
        .onAppear {
            guard !didOpenInitialAccount, let targetID = initialAccountID else { return }
            didOpenInitialAccount = true
            if let target = accounts.first(where: { $0.id == targetID }) {
                proxy.scrollTo(targetID, anchor: .center)
                editing = target
            }
        }
        }
    }

    private func accountRow(_ account: Account) -> some View {
        let isExcluded = !account.includeInNetWorth
        return Button { editing = account } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    AccountIcon(account: account, size: 40)
                        .saturation(isExcluded ? 0 : 1)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(account.name)
                                .foregroundStyle(isExcluded ? Theme.secondaryInk : Theme.ink)
                                .lineLimit(1)
                                .minimumScaleFactor(0.85)
                            if isExcluded {
                                Image(systemName: "eye.slash.fill")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(Theme.secondaryInk)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 3)
                                    .background(Theme.track, in: Capsule())
                            }
                            if account.kind == .loan && account.isLoanInstallmentPaidForCurrentCycle() {
                                HStack(spacing: 3) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.system(size: 10, weight: .bold))
                                    Text("Paid this month")
                                        .font(.caption2.weight(.semibold))
                                }
                                .foregroundStyle(Theme.positive)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2.5)
                                .background(Theme.positive.opacity(0.14), in: Capsule())
                            } else if account.kind.isLiability {
                                dueBadge(for: account)
                            }
                        }
                        Text(account.kind.title)
                            .font(.caption)
                            .foregroundStyle(Theme.secondaryInk)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    let signedBalance = account.kind.isLiability ? -account.balance : account.balance
                    Text(Money.format(signedBalance, currency))
                        .font(.body.weight(.medium).monospacedDigit())
                        .foregroundStyle(isExcluded ? Theme.secondaryInk : (account.kind.isLiability ? Theme.negative : Theme.ink))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .layoutPriority(1)
                        .animatedNumber(signedBalance)
                }

                if account.kind == .creditCard && account.cardLimit > 0 {
                    LiabilityProgressBar(
                        progress: account.cardUsedProgress,
                        tint: isExcluded ? Theme.secondaryInk : (account.cardUsedProgress >= 0.9 ? Theme.negative : (account.cardUsedProgress >= 0.7 ? Theme.warning : Theme.cobalt)),
                        leadingText: "Used \(Money.format(account.cardUsedBalance, currency))",
                        trailingText: "Remaining \(Money.format(account.cardRemainingBalance, currency))"
                    )
                } else if account.kind == .loan && account.loanOriginalAmount > 0 {
                    LiabilityProgressBar(
                        progress: account.loanPaidProgress,
                        tint: isExcluded ? Theme.secondaryInk : Theme.positive,
                        leadingText: "Paid \(Money.format(account.loanPaidAmount, currency))",
                        trailingText: account.loanMonthlyInstallment > 0
                            ? "\(Money.format(account.loanMonthlyInstallment, currency))/mo"
                            : "Remaining \(Money.format(account.loanRemainingBalance, currency))"
                    )
                }
            }
            .opacity(isExcluded ? 0.48 : 1.0)
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
        .listRowBackground(isExcluded ? Theme.track.opacity(0.45) : Theme.surface)
        .id(account.id)
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
                .lineLimit(1)
        }
        .fixedSize(horizontal: true, vertical: false)
        .layoutPriority(1)
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
    @Query(sort: \Account.createdAt) private var allAccounts: [Account]
    @AppStorage(Keys.currency) private var currency = "BHD"
    @State private var name = ""
    @State private var kind: AccountKind = .bank
    @State private var institution = ""
    @State private var balanceText = ""
    @State private var creditLimitText = ""
    @State private var loanTotalAmountText = ""
    @State private var loanMonthlyInstallmentText = ""
    @State private var loanKeywordsText = ""
    @State private var loanAutoDeduct = false
    @State private var loanAutoDeductAccountID: UUID? = nil
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
                    TextField("Name (e.g. Checking Account)", text: $name)
                    SheetPickerRow(
                        title: "Type",
                        selection: $kind,
                        options: AccountKind.allCases.map {
                            SheetPickerOption(id: $0, title: $0.title, symbol: $0.symbol, color: $0.color)
                        }
                    )
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
                        Text("Loan installments are not deducted from net worth directly before the installment transaction is received via SMS, manual entry, or automatic deduction.")
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
                if kind == .loan {
                    Section {
                        TextField("Loan number or SMS keywords, e.g. 400001377387, Murabaha", text: $loanKeywordsText)
                            .autocorrectionDisabled()
                    } header: {
                        Text("Loan keyword / number in SMS")
                    } footer: {
                        Text("Incoming bank SMS containing this loan number or keyword will automatically match this loan, reduce its remaining balance, and mark this month's installment as paid.")
                    }
                }
                if kind.isLiability {
                    Section {
                        DatePicker(kind == .loan ? "Installment due date" : "Payment due date", selection: $paymentDueDate, displayedComponents: .date)
                        if kind == .loan {
                            Toggle(isOn: $loanAutoDeduct.animation(.snappy)) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Label("Auto-add installment on due date", systemImage: "calendar.badge.checkmark")
                                    Text("Record monthly installment even without SMS")
                                        .font(.caption2)
                                        .foregroundStyle(Theme.secondaryInk)
                                }
                            }
                            if loanAutoDeduct {
                                let liquidAccounts = allAccounts.filter { $0.kind.isLiquid }
                                Picker("Deduct from account", selection: $loanAutoDeductAccountID) {
                                    Text("None (loan balance only)").tag(UUID?.none)
                                    ForEach(liquidAccounts) { acc in
                                        Text(acc.name).tag(UUID?.some(acc.id))
                                    }
                                }
                            }
                        }
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
                        Text(kind == .loan ? "Loan installment schedule" : "Visa payment reminder")
                    } footer: {
                        if kind == .loan && loanAutoDeduct {
                            Text("Automatically records the monthly installment on the chosen date if no bank SMS has arrived. If an SMS arrives before or after, it will never be deducted twice.")
                        } else {
                            Text(paymentDueReminder
                                 ? "You'll get a notification at 9:00 AM \(reminderDaysBefore == 0 ? "on the due date" : "\(reminderDaysBefore) day\(reminderDaysBefore == 1 ? "" : "s") before it and again on the due date") every month."
                                 : "Turn on to get a monthly reminder before your \(kind == .loan ? "loan installment" : "card payment") is due.")
                        }
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
            .scrollContentBackground(.hidden)
            .canvasBackground()
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
                loanKeywordsText = account.loanKeywordsRaw
                loanAutoDeduct = account.loanAutoDeduct
                loanAutoDeductAccountID = account.loanAutoDeductAccountID
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
        target.loanKeywordsRaw = kind == .loan ? loanKeywordsText.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        target.loanAutoDeduct = kind == .loan && loanAutoDeduct
        target.loanAutoDeductAccountID = (kind == .loan && loanAutoDeduct) ? loanAutoDeductAccountID : nil
        target.paymentDueReminder = kind.isLiability && paymentDueReminder
        target.paymentDueDate = paymentDueDate
        target.paymentReminderDaysBefore = reminderDaysBefore
        let trimmedMatch = target.smsMatch.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedMatch.isEmpty {
            let txs = (try? context.fetch(FetchDescriptor<MoneyTransaction>())) ?? []
            for tx in txs where tx.source == .sms && tx.accountID == nil && tx.toAccountID != target.id {
                let raw = tx.rawText ?? ""
                guard !raw.contains("\n\n---\n\n") else { continue }
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
        if target.kind == .loan && target.loanAutoDeduct {
            _ = Ledger.processScheduledLoanInstallments(context: context)
        }
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

private enum NetWorthChartSelection {
    static func excludedIDs(from raw: String) -> Set<UUID> {
        Set(raw.split(separator: ",").compactMap { UUID(uuidString: String($0)) })
    }

    static func toggle(_ id: UUID, in raw: String) -> String {
        var set = excludedIDs(from: raw)
        if set.contains(id) {
            set.remove(id)
        } else {
            set.insert(id)
        }
        return set.map(\.uuidString).sorted().joined(separator: ",")
    }

    static func setAllExcluded(_ accounts: [Account]) -> String {
        accounts.map(\.id.uuidString).sorted().joined(separator: ",")
    }
}

private enum NetWorthChartMode: String, CaseIterable, Identifiable {
    case breakdown = "Breakdown"
    case trend = "Trend"
    var id: String { rawValue }
}

private struct NetWorthChartItem: Identifiable {
    let id: UUID
    let name: String
    let value: Double
    let isLiability: Bool
    let color: Color
    let kindTitle: String
}

private struct NetWorthChartSection: View {
    let accounts: [Account]
    let snapshots: [NetWorthSnapshot]
    let currentNetWorth: Double
    let currency: String
    @Binding var chartExcludedRaw: String
    let onOpenPicker: () -> Void

    @State private var chartMode: NetWorthChartMode = .breakdown
    @State private var range = 2
    @State private var selectedDate: Date?
    @State private var selectedItemID: UUID?

    private let ranges = [(label: "3M", months: 3), (label: "6M", months: 6), (label: "1Y", months: 12), (label: "All", months: 1200)]

    private var selectedAccounts: [Account] {
        let excluded = NetWorthChartSelection.excludedIDs(from: chartExcludedRaw)
        return accounts.filter { !excluded.contains($0.id) }
    }

    private var chartAssets: Double {
        selectedAccounts.filter { !$0.kind.isLiability }.reduce(0) { $0 + $1.balance }
    }

    private var chartLiabilities: Double {
        selectedAccounts.filter { $0.kind.isLiability }.reduce(0) { $0 + $1.netWorthLiabilityAmount }
    }

    private var chartNetWorth: Double {
        chartAssets - chartLiabilities
    }

    private var breakdownItems: [NetWorthChartItem] {
        selectedAccounts.compactMap { acc in
            let amt = acc.kind.isLiability ? acc.netWorthLiabilityAmount : max(0, acc.balance)
            guard amt > 0.0005 else { return nil }
            let col: Color = {
                switch acc.kind {
                case .bank: return Color(hex: 0x2563EB)
                case .cash: return Color(hex: 0x16A34A)
                case .investment: return Color(hex: 0x0EA5A4)
                case .property: return Color(hex: 0x8B5CF6)
                case .otherAsset: return Color(hex: 0x0891B2)
                case .creditCard: return Color(hex: 0xDC2626)
                case .loan: return Color(hex: 0xF08A24)
                }
            }()
            return NetWorthChartItem(
                id: acc.id,
                name: acc.name,
                value: amt,
                isLiability: acc.kind.isLiability,
                color: col,
                kindTitle: acc.kind == .loan ? "Loan installment" : acc.kind.title
            )
        }
        .sorted { $0.value > $1.value }
    }

    private var trendPoints: [ChartPoint] {
        let start = Calendar.current.date(byAdding: .month, value: -ranges[range].months, to: .now) ?? .distantPast
        let offset = chartNetWorth - currentNetWorth
        return snapshots.filter { $0.day >= start }.map { ChartPoint(date: $0.day, value: $0.netWorth + offset) }
    }

    var body: some View {
        let pts = trendPoints
        let change = (pts.last?.value ?? chartNetWorth) - (pts.first?.value ?? chartNetWorth)
        let selectedPoint = selectedDate.flatMap { d in pts.min(by: { abs($0.date.timeIntervalSince(d)) < abs($1.date.timeIntervalSince(d)) }) }
        let selectedItem = selectedItemID.flatMap { id in breakdownItems.first(where: { $0.id == id }) }
        let totalMagnitude = chartAssets + chartLiabilities

        Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        let heroLabel: String = {
                            if chartMode == .trend, let p = selectedPoint {
                                return p.date.formatted(date: .abbreviated, time: .omitted)
                            }
                            if chartMode == .breakdown, let item = selectedItem {
                                return "\(item.name) · \(item.kindTitle)"
                            }
                            return selectedAccounts.count == accounts.count ? "Net worth" : "Chart net worth"
                        }()
                        Text(heroLabel)
                            .font(.subheadline)
                            .foregroundStyle(Theme.secondaryInk)
                            .lineLimit(1)
                    }
                    Spacer()
                    Button(action: onOpenPicker) {
                        HStack(spacing: 5) {
                            Image(systemName: "slider.horizontal.3")
                                .font(.caption2.weight(.semibold))
                            Text("\(selectedAccounts.count)/\(accounts.count)")
                                .font(.caption.weight(.semibold).monospacedDigit())
                        }
                        .foregroundStyle(Theme.cobalt)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Theme.cobaltSoft, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Choose chart accounts")
                }

                let heroValue: Double = {
                    if chartMode == .trend, let p = selectedPoint { return p.value }
                    if chartMode == .breakdown, let item = selectedItem { return item.isLiability ? -item.value : item.value }
                    return chartNetWorth
                }()
                Text(Money.format(heroValue, currency))
                    .font(.system(size: 34, weight: .bold).monospacedDigit())
                    .foregroundStyle(heroValue < 0 ? Theme.negative : Theme.ink)
                    .minimumScaleFactor(0.6).lineLimit(1)
                    .animatedNumber(heroValue)

                HStack(spacing: 12) {
                    HStack(spacing: 5) {
                        Circle().fill(Theme.positive).frame(width: 7, height: 7)
                        Text(Money.format(chartAssets, currency))
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .foregroundStyle(Theme.positive)
                    }
                    HStack(spacing: 5) {
                        Circle().fill(Theme.negative).frame(width: 7, height: 7)
                        Text(Money.format(-chartLiabilities, currency))
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .foregroundStyle(Theme.negative)
                    }
                    Spacer()
                    if chartMode == .trend {
                        Text("\(Money.format(change, currency, signed: true)) · \(ranges[range].label)")
                            .font(.caption.weight(.semibold).monospacedDigit())
                            .foregroundStyle(change >= 0 ? Theme.positive : Theme.negative)
                    }
                }

                Picker("Chart mode", selection: $chartMode) {
                    ForEach(NetWorthChartMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)

                if chartMode == .breakdown {
                    if breakdownItems.isEmpty {
                        VStack(spacing: 6) {
                            Image(systemName: "chart.bar.xaxis")
                                .font(.title2)
                                .foregroundStyle(Theme.secondaryInk.opacity(0.6))
                            Text(selectedAccounts.isEmpty ? "No accounts selected for chart" : "No balances to chart")
                                .font(.footnote)
                                .foregroundStyle(Theme.secondaryInk)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 150)
                    } else {
                        // Assets vs Liabilities proportion bar
                        if totalMagnitude > 0 {
                            GeometryReader { geo in
                                let assetRatio = min(1, max(0, chartAssets / totalMagnitude))
                                HStack(spacing: 3) {
                                    if chartAssets > 0 {
                                        Capsule()
                                            .fill(Theme.positive)
                                            .frame(width: max(8, (geo.size.width - (chartLiabilities > 0 ? 3 : 0)) * assetRatio))
                                    }
                                    if chartLiabilities > 0 {
                                        Capsule()
                                            .fill(Theme.negative)
                                    }
                                }
                            }
                            .frame(height: 8)
                            .padding(.top, 2)
                        }

                        Chart(breakdownItems) { item in
                            BarMark(
                                x: .value("Amount", item.value),
                                y: .value("Account", item.name)
                            )
                            .foregroundStyle(item.color.opacity(selectedItemID == nil || selectedItemID == item.id ? 0.92 : 0.32))
                            .cornerRadius(6)
                            .annotation(position: .trailing, alignment: .center, spacing: 6) {
                                Text(Money.short(item.isLiability ? -item.value : item.value))
                                    .font(.caption2.weight(.semibold).monospacedDigit())
                                    .foregroundStyle(item.isLiability ? Theme.negative : Theme.secondaryInk)
                            }
                        }
                        .chartXAxis(.hidden)
                        .chartYAxis {
                            AxisMarks(position: .leading) { _ in
                                AxisValueLabel()
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(Theme.ink)
                            }
                        }
                        .frame(height: CGFloat(max(120, min(breakdownItems.count, 8) * 34)))
                        .padding(.trailing, 32)
                        .padding(.top, 4)

                        // Interactive quick-select chips
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(breakdownItems) { item in
                                    let isSelected = selectedItemID == item.id
                                    Button {
                                        withAnimation(.snappy(duration: 0.2)) {
                                            selectedItemID = isSelected ? nil : item.id
                                        }
                                    } label: {
                                        HStack(spacing: 5) {
                                            Circle().fill(item.color).frame(width: 7, height: 7)
                                            Text(item.name).lineLimit(1)
                                        }
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(isSelected ? .white : Theme.ink)
                                        .padding(.horizontal, 9)
                                        .padding(.vertical, 5)
                                        .background(isSelected ? item.color : Theme.track.opacity(0.7), in: Capsule())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                } else {
                    Chart(pts) { p in
                        AreaMark(x: .value("Date", p.date), y: .value("Net worth", p.value))
                            .interpolationMethod(.catmullRom)
                            .foregroundStyle(LinearGradient(colors: [Theme.cobalt.opacity(0.22), Theme.cobalt.opacity(0.01)], startPoint: .top, endPoint: .bottom))
                        LineMark(x: .value("Date", p.date), y: .value("Net worth", p.value))
                            .interpolationMethod(.catmullRom)
                            .foregroundStyle(Theme.cobalt)
                            .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        if let selectedPoint, selectedPoint.date == p.date {
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
                    .padding(.top, 4)
                    .overlay {
                        if pts.count < 2 {
                            Text("History builds up as you use the app").font(.footnote).foregroundStyle(Theme.secondaryInk)
                        }
                    }
                    Picker("Range", selection: $range) {
                        ForEach(ranges.indices, id: \.self) { Text(ranges[$0].label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .padding(.top, 2)
                }
            }
            .padding(.vertical, 6)
        }
    }
}

private struct NetWorthChartAccountsSheet: View {
    let accounts: [Account]
    let currency: String
    @Binding var excludedRaw: String
    @Environment(\.dismiss) private var dismiss

    private var excludedSet: Set<UUID> {
        NetWorthChartSelection.excludedIDs(from: excludedRaw)
    }

    var body: some View {
        let assets = accounts.filter { !$0.kind.isLiability }
        let liabilities = accounts.filter { $0.kind.isLiability }

        NavigationStack {
            List {
                if !assets.isEmpty {
                    Section("Assets") {
                        ForEach(assets) { acc in
                            chartToggleRow(acc)
                        }
                    }
                }
                if !liabilities.isEmpty {
                    Section("Loans & liabilities") {
                        ForEach(liabilities) { acc in
                            chartToggleRow(acc)
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .canvasBackground()
            .navigationTitle("Chart Accounts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(excludedSet.isEmpty ? "Clear all" : "Select all") {
                        withAnimation(.snappy) {
                            excludedRaw = excludedSet.isEmpty ? NetWorthChartSelection.setAllExcluded(accounts) : ""
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func chartToggleRow(_ account: Account) -> some View {
        let isIncluded = !excludedSet.contains(account.id)
        let displayAmount = account.kind.isLiability ? -account.netWorthLiabilityAmount : account.balance
        return Button {
            withAnimation(.snappy(duration: 0.2)) {
                excludedRaw = NetWorthChartSelection.toggle(account.id, in: excludedRaw)
            }
        } label: {
            HStack(spacing: 12) {
                AccountIcon(account: account, size: 34)
                    .saturation(isIncluded ? 1 : 0)
                    .opacity(isIncluded ? 1 : 0.45)
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.name)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(isIncluded ? Theme.ink : Theme.secondaryInk)
                    Text(account.kind == .loan ? "Loan · Monthly installment" : account.kind.title)
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryInk)
                }
                Spacer()
                Text(Money.format(displayAmount, currency))
                    .font(.subheadline.weight(.medium).monospacedDigit())
                    .foregroundStyle(isIncluded ? (account.kind.isLiability ? Theme.negative : Theme.ink) : Theme.secondaryInk)
                Image(systemName: isIncluded ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isIncluded ? Theme.cobalt : Color(hex: 0xC7CCD6))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
