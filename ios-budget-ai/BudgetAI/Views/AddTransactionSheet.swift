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
    @State private var locationData: TransactionLocationData?
    @State private var showLocationPicker = false
    @State private var isCapturingGPS = false
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
                                guard !userPickedCategory else { return }
                                if let learned = Categorizer.learnedMatch(for: value, in: context, isIncome: isIncome) {
                                    withAnimation(.snappy) {
                                        category = learned.category
                                        subcategory = learned.subcategory
                                    }
                                    return
                                }
                                guard !isIncome, let guess = Categorizer.guess(value),
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

                    Section("Location") {
                        if let loc = locationData {
                            TransactionLocationCard(
                                placeName: loc.name,
                                address: loc.address,
                                latitude: loc.latitude,
                                longitude: loc.longitude,
                                onCaptureCurrent: { captureCurrentLocation() },
                                onSearchPlace: { showLocationPicker = true },
                                onRemove: { locationData = nil }
                            )
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                        } else {
                            HStack(spacing: 10) {
                                Button {
                                    captureCurrentLocation()
                                } label: {
                                    HStack(spacing: 6) {
                                        if isCapturingGPS {
                                            ProgressView().controlSize(.small)
                                        } else {
                                            Image(systemName: "location.fill")
                                        }
                                        Text("Current Location")
                                    }
                                    .font(.caption.weight(.semibold))
                                    .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(Theme.brand)
                                .disabled(isCapturingGPS)

                                Button {
                                    showLocationPicker = true
                                } label: {
                                    Label("Search Place", systemImage: "magnifyingglass")
                                        .font(.caption.weight(.semibold))
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.bordered)
                            }
                            .padding(.vertical, 4)
                        }
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
            .sheet(isPresented: $showLocationPicker) {
                LocationPickerSheet(initialName: locationData?.name ?? merchant) { loc in
                    locationData = loc
                }
            }
        }
        .presentationDragIndicator(.visible)
    }

    private func captureCurrentLocation() {
        Task {
            isCapturingGPS = true
            if let loc = await LocationService.shared.captureCurrentLocation(fallbackPlaceName: merchant.isEmpty ? nil : merchant) {
                locationData = loc
            } else if let err = LocationService.shared.lastError {
                appState.show(err, warning: true)
            }
            isCapturingGPS = false
        }
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
        if let loc = locationData ?? LocationService.inferLocation(from: note, merchant: tx.merchant) {
            tx.locationName = loc.name
            tx.locationAddress = loc.address
            tx.latitude = loc.latitude
            tx.longitude = loc.longitude
        }
        if !userPickedCategory {
            TransactionRuleStore.shared.applyHighestPriorityRuleIfMatching(to: tx, context: context)
        }
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
    @State private var sender = ""
    @State private var manualBank = ""
    @State private var working = false
    @State private var outcome: SMSImportOutcome?
    @State private var accountID: UUID?
    @Query(sort: \Account.createdAt) private var accounts: [Account]

    private var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedSender: String? {
        let s = sender.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    private var batchChunks: [String] {
        SMSParser.splitBatch(trimmedText)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $text)
                        .frame(minHeight: 140)
                        .overlay(alignment: .topLeading) {
                            if text.isEmpty {
                                Text("Paste one or more bank SMS alerts (English or Arabic), e.g. \"Your NBB card ending 1234 was used for BHD 6.750 at TALABAT on 24-Oct.\"")
                                    .foregroundStyle(.tertiary)
                                    .padding(.top, 8)
                                    .padding(.leading, 4)
                                    .allowsHitTesting(false)
                            }
                        }
                    Button("Paste from clipboard", systemImage: "doc.on.clipboard") {
                        if let s = UIPasteboard.general.string { text = s }
                    }
                    Menu {
                        Button("BisB · Fawri+ Outgoing (EN)") {
                            sender = "BisB"
                            text = "Fawri+ payment BHD3.000, ref: BIB103KAK000KZUM was credited to IBAN ending 0846 on 2026/10/27 15:26. Balance BHD263.195. Tel: 17515151"
                        }
                        Button("NBB Card · Talabat (EN)") {
                            sender = "NBB"
                            text = "Your NBB card ending 1234 was used for BHD 6.750 at TALABAT BH on 24-Oct. Avl Bal: BHD 412.300"
                        }
                        Button("BenefitPay · Fawri+ Transfer (EN)") {
                            sender = "BenefitPay"
                            text = "BenefitPay: Fawri+ transfer of BHD 15.000 to COLD STORE from IBAN xx4821 completed. Available Balance: BHD 397.300"
                        }
                        Button("ila Bank · Lulu Hypermarket (AR)") {
                            sender = "ila"
                            text = "بنك إلى: تم خصم مبلغ ١٨.٤٥٠ د.ب باستخدام البطاقة رقم 9921 لدى اللولو هايبرماركت. الرصيد المتاح: ٣٧٨.٨٥٠ د.ب"
                        }
                        Button("Salary Credit · BBK (EN)") {
                            sender = "BBK"
                            text = "BBK: Salary of BHD 1,250.000 has been credited to your account ending 8801. Avl Bal: BHD 1,628.850"
                        }
                        Button("BisB · Visa Card Payment (EN)") {
                            sender = "BisB"
                            text = "Dear ISA, Thank you for paying BHD 457.558 on 24/10 for your VISA INFINITE card. Available Bal BHD 5000. Tel 17515151"
                        }
                    } label: {
                        Label("Try sample SMS (EN / عربي)", systemImage: "text.bubble")
                    }
                    TextField("Sender ID / phone (optional, e.g. BisB)", text: $sender)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Picker("SMS sender bank", selection: $manualBank) {
                        Text("Detect automatically").tag("")
                        ForEach(BahrainBankCatalog.bahrainBanks, id: \.self) { bank in
                            Text(bank).tag(bank)
                        }
                    }
                    Picker("Account", selection: $accountID) {
                        Text("Detect automatically").tag(UUID?.none)
                        ForEach(accounts) { a in Text(a.menuTitle).tag(UUID?.some(a.id)) }
                    }
                } footer: {
                    HStack(spacing: 4) {
                        if GeminiAccount.isConfigured {
                            Image(systemName: "sparkles")
                            Text("Deterministic Bahrain bank rules run first; Gemini is used only for uncertain messages.")
                        } else {
                            Text("Deterministic on-device Bahrain & GCC bank rules with Fawri+ direction and duplicate checks.")
                        }
                    }
                }

                if !trimmedText.isEmpty {
                    livePreviewSection
                }

                if let outcome {
                    Section("Result") {
                        let txs = outcome.batchTransactions.isEmpty ? (outcome.transaction.map { [$0] } ?? []) : outcome.batchTransactions
                        if !txs.isEmpty {
                            if txs.count > 1 {
                                Label(outcome.message, systemImage: "checkmark.circle.fill")
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(Theme.positive)
                            }
                            ForEach(txs) { tx in
                                TransactionRow(tx: tx, currency: currency)
                            }
                            if outcome.usedAI { LabeledContent("Read by") { AIBadge() } }
                            if outcome.learnedMerchant {
                                Label("Category matched from your past transactions", systemImage: "brain.head.profile")
                                    .font(.footnote)
                                    .foregroundStyle(Theme.cobalt)
                            }
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
                        Button(batchChunks.count > 1 ? "Import (\(batchChunks.count))" : "Import") { Task { await run() } }
                            .fontWeight(.semibold)
                            .disabled(trimmedText.isEmpty)
                    }
                }
            }
            .sensoryFeedback(.success, trigger: outcome?.transaction?.id)
            .onAppear {
                CategoryRegistry.shared.reload(context: context)
            }
        }
    }

    @ViewBuilder
    private var livePreviewSection: some View {
        Section("Live preview") {
            let chunks = batchChunks
            if chunks.count > 1 {
                let parsedItems = chunks.compactMap { SMSParser.parse($0, sender: trimmedSender, context: context) }
                if parsedItems.count == 2,
                   let r1 = parsedItems[0].referenceNumber?.trimmingCharacters(in: .whitespacesAndNewlines), !r1.isEmpty,
                   let r2 = parsedItems[1].referenceNumber?.trimmingCharacters(in: .whitespacesAndNewlines), !r2.isEmpty,
                   r1.caseInsensitiveCompare(r2) == .orderedSame,
                   parsedItems[0].isIncome == parsedItems[1].isIncome {
                    let maxAmount = max(parsedItems[0].amount, parsedItems[1].amount)
                    let minBalance: Double? = {
                        if let b1 = parsedItems[0].balance, let b2 = parsedItems[1].balance { return min(b1, b2) }
                        return parsedItems[0].balance ?? parsedItems[1].balance
                    }()
                    Label("Same reference (\(r1)) · Will auto-merge into 1 transaction", systemImage: "arrow.triangle.merge")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.positive)
                    HStack {
                        Text("Merged amount (highest)")
                            .font(.caption)
                            .foregroundStyle(Theme.secondaryInk)
                        Spacer()
                        Text(Money.format(maxAmount, parsedItems[0].currency ?? currency))
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .foregroundStyle(Theme.ink)
                    }
                    if let minBalance {
                        HStack {
                            Text("Merged balance (lowest)")
                                .font(.caption)
                                .foregroundStyle(Theme.secondaryInk)
                            Spacer()
                            Text(Money.format(minBalance, parsedItems[0].currency ?? currency))
                                .font(.caption.monospacedDigit().weight(.semibold))
                                .foregroundStyle(Theme.cobalt)
                        }
                    }
                } else {
                    Label("\(parsedItems.count) of \(chunks.count) messages detected as transactions", systemImage: "doc.on.doc.fill")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Theme.cobalt)
                }
                ForEach(Array(parsedItems.enumerated()), id: \.offset) { _, p in
                    previewRow(for: p)
                }
            } else if let reason = SMSParser.nonTransactionReason(trimmedText) {
                Label("Will be skipped: \(reason)", systemImage: "hand.raised.fill")
                    .foregroundStyle(Theme.warning)
            } else if let p = SMSParser.parse(trimmedText, sender: trimmedSender, context: context) {
                previewRow(for: p)
                if p.requiresReview {
                    Label("Low confidence — will be saved as pending for your review", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.warning)
                }
                if !p.transactionType.isTransferType && Categorizer.learnedMatch(for: p.merchant, in: context, isIncome: p.isIncome) != nil {
                    Label("Category learned from your transaction history", systemImage: "brain.head.profile")
                        .font(.caption)
                        .foregroundStyle(Theme.cobalt)
                }
                HStack {
                    Text("Detected bank")
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryInk)
                    Spacer()
                    let effectiveBank = manualBank.isEmpty ? p.detectedBank : manualBank
                    Text(effectiveBank ?? "Uncertain (assign above if known)")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(effectiveBank == nil ? Theme.warning : Theme.ink)
                }
                if let ref = p.referenceNumber {
                    HStack {
                        Text("Reference")
                            .font(.caption)
                            .foregroundStyle(Theme.secondaryInk)
                        Spacer()
                        Text(ref)
                            .font(.caption.monospaced().weight(.medium))
                            .foregroundStyle(Theme.ink)
                    }
                }
                if let toID = p.toAccountID, let destAcc = accounts.first(where: { $0.id == toID }) {
                    HStack {
                        Text("To account")
                            .font(.caption)
                            .foregroundStyle(Theme.secondaryInk)
                        Spacer()
                        Text(destAcc.menuTitle)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.cobalt)
                    }
                }
                if let recip = p.recipientSuffix {
                    HStack {
                        Text("Recipient IBAN / account")
                            .font(.caption)
                            .foregroundStyle(Theme.secondaryInk)
                        Spacer()
                        if let toID = p.toAccountID, let destAcc = accounts.first(where: { $0.id == toID }) {
                            Text("\(destAcc.name) · ••\(recip)")
                                .font(.caption.monospacedDigit().weight(.medium))
                                .foregroundStyle(Theme.ink)
                        } else {
                            Text("••\(recip)")
                                .font(.caption.monospacedDigit().weight(.medium))
                                .foregroundStyle(Theme.ink)
                        }
                    }
                }
                if let acct = p.accountSuffix {
                    HStack {
                        Text("Source card / account")
                            .font(.caption)
                            .foregroundStyle(Theme.secondaryInk)
                        Spacer()
                        Text("••\(acct)")
                            .font(.caption.monospacedDigit().weight(.medium))
                            .foregroundStyle(Theme.ink)
                    }
                }
                if let bal = p.balance {
                    HStack {
                        Text(p.balanceIsCardLimit ? "Card available limit in SMS" : "Bank balance in SMS")
                            .font(.caption)
                            .foregroundStyle(Theme.secondaryInk)
                        Spacer()
                        Text(Money.format(bal, p.currency ?? currency))
                            .font(.caption.monospacedDigit().weight(.medium))
                            .foregroundStyle(Theme.cobalt)
                    }
                }
            } else {
                Label("No clear amount detected on-device yet.", systemImage: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryInk)
            }
        }
    }

    private func previewRow(for p: ParsedSMS) -> some View {
        let displayCat = p.subcategory ?? p.category
        return HStack(spacing: 12) {
            IconBadge(symbol: displayCat.symbol, color: displayCat.color, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(p.merchant)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.ink)
                Text("\(p.transactionType.title) · \(p.subcategory != nil ? "\(p.category.title) (\(p.subcategory!.title))" : p.category.title)")
                    .font(.caption)
                    .foregroundStyle(p.requiresReview ? Theme.warning : Theme.secondaryInk)
            }
            Spacer()
            let prefix = p.transactionType == .internalTransfer ? "" : (p.isIncome ? "+" : "−")
            Text(prefix + Money.format(p.amount, p.currency ?? currency))
                .font(.subheadline.monospacedDigit().weight(.semibold))
                .foregroundStyle(p.isIncome ? Theme.positive : (p.transactionType.isTransferType ? Theme.secondaryInk : Theme.ink))
        }
    }

    private func run() async {
        working = true
        let result = await SMSImporter.importText(
            text,
            context: context,
            forceApprove: true,
            accountID: accountID,
            sender: trimmedSender,
            manualBank: manualBank.isEmpty ? nil : manualBank
        )
        working = false
        withAnimation { outcome = result }
        if result.transaction != nil {
            text = ""
            if let alert = result.alerts.first { appState.show(alert, warning: true) }
        }
    }
}
