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
    @State private var transferCategoryEditor: CategoryEditorTarget?
    @FocusState private var amountFocused: Bool

    private var amount: Double { Money.parse(amountText) ?? 0 }
    private var isIncome: Bool { kind == .income }
    private var isBetweenOwnAccounts: Bool { category == .internalTransfer || category == .visaTransfer }

    private var canSave: Bool {
        guard amount > 0 else { return false }
        if kind == .transfer && isBetweenOwnAccounts {
            return accountID != nil && toAccountID != nil && accountID != toAccountID
        }
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
                        TextField(isIncome ? "From (e.g. Salary)" : "Merchant (e.g. Grocery Store)", text: $merchant)
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
                        AccountPickerRow(
                            title: "Account",
                            selection: $accountID,
                            accounts: accounts,
                            noneLabel: "None"
                        )
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
                                onSearchPlace: { showLocationPicker = true },
                                onRemove: { locationData = nil }
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
                if newKind == .income {
                    category = .income
                } else if newKind == .transfer {
                    category = .internalTransfer
                } else {
                    category = .other
                }
            }
            .onAppear {
                accountID = Ledger.defaultAccountID(context: context)
                amountFocused = true
            }
            .sheet(isPresented: $showLocationPicker) {
                LocationPickerSheet(
                    initialName: locationData?.name ?? merchant,
                    initialLatitude: locationData?.latitude,
                    initialLongitude: locationData?.longitude
                ) { loc in
                    locationData = loc
                }
            }
            .sheet(item: $transferCategoryEditor) { target in
                CategoryEditor(target: target) { created in
                    category = created
                    subcategory = nil
                    userPickedCategory = true
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
        let registry = CategoryRegistry.shared
        let transferOptions = SpendCategory.transferCases

        Section("Transfer type") {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 12) {
                ForEach(transferOptions) { c in
                    Button {
                        withAnimation(.snappy) {
                            category = c
                            subcategory = nil
                            userPickedCategory = true
                            if c == .visaTransfer {
                                let cards = accounts.filter { $0.kind == .creditCard && $0.id != accountID }
                                if let firstCard = cards.first, !cards.contains(where: { $0.id == toAccountID }) {
                                    toAccountID = firstCard.id
                                }
                            }
                        }
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
                                .minimumScaleFactor(0.75)
                        }
                    }
                    .buttonStyle(PressableStyle())
                }
                Button {
                    transferCategoryEditor = .new(parent: nil, income: false, transfer: true)
                } label: {
                    VStack(spacing: 6) {
                        Image(systemName: "plus")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(Theme.cobalt)
                            .frame(width: 44, height: 44)
                            .background(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(Theme.cobalt.opacity(0.4), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])))
                        Text("New").font(.caption2).foregroundStyle(Theme.cobalt)
                    }
                }
                .buttonStyle(PressableStyle())
            }
            .id(registry.order)
            .padding(.vertical, 4)
        }

        if isBetweenOwnAccounts {
            let destinationAccounts: [Account] = {
                if category == .visaTransfer {
                    let cards = accounts.filter { $0.kind == .creditCard }
                    return cards.isEmpty ? accounts : cards
                }
                return accounts
            }()
            Section("From") {
                ForEach(accounts) { a in
                    accountChoice(a, selected: accountID == a.id, disabled: false) {
                        accountID = a.id
                        if toAccountID == a.id { toAccountID = nil }
                    }
                }
            }
            Section(category == .visaTransfer ? "To Visa card" : "To") {
                ForEach(destinationAccounts) { a in
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
        } else {
            Section {
                TextField(category == .transferIn ? "From (e.g. Sender name)" : "To (e.g. Recipient name)", text: $merchant)
                    .textInputAutocapitalization(.words)
                AccountPickerRow(
                    title: "Account",
                    selection: $accountID,
                    accounts: accounts,
                    noneLabel: "None"
                )
                DatePicker("Date", selection: $date, in: ...Date.now.addingTimeInterval(86_400 * 365))
                TextField("Note", text: $note, axis: .vertical)
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
            if category == .internalTransfer {
                guard let from = accounts.first(where: { $0.id == accountID }), let to = accounts.first(where: { $0.id == toAccountID }) else { return }
                Ledger.transfer(amount: amount, from: from, to: to, date: date, note: note, context: context)
                saved = true
                appState.show("Moved \(Money.format(amount, currency)) to \(to.name)")
                dismiss()
                return
            } else if category == .visaTransfer {
                guard let from = accounts.first(where: { $0.id == accountID }), let to = accounts.first(where: { $0.id == toAccountID }) else { return }
                let tx = MoneyTransaction(amount: amount, isIncome: false, merchant: "\(from.name) → \(to.name)",
                                          category: .visaTransfer, date: date, note: note, source: .transfer, accountID: from.id)
                tx.toAccountID = to.id
                tx.smsTransactionType = .internalTransfer
                Ledger.add(tx, context: context, checkDuplicates: false)
                saved = true
                appState.show("Paid \(Money.format(amount, currency)) to \(to.name)")
                dismiss()
                return
            } else {
                let incoming = category == .transferIn
                let name = merchant.trimmingCharacters(in: .whitespaces)
                let tx = MoneyTransaction(
                    amount: amount,
                    isIncome: incoming,
                    merchant: name.isEmpty ? category.title : name,
                    category: category,
                    date: date,
                    note: note,
                    source: .transfer,
                    accountID: accountID
                )
                tx.smsTransactionType = incoming ? .transferIn : .transferOut
                let result = Ledger.add(tx, context: context)
                saved = true
                appState.report(result, base: "Saved \(Money.format(amount, currency))")
                dismiss()
                return
            }
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
            TransactionRuleStore.shared.applyBestMatchingRuleIfAny(to: tx, context: context)
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
    @State private var showAddSenderBankAlert = false
    @State private var newSenderBankName = ""
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
                                Text("Paste one or more bank SMS alerts (English or Arabic) to import.")
                                    .foregroundStyle(.tertiary)
                                    .padding(.top, 8)
                                    .padding(.leading, 4)
                                    .allowsHitTesting(false)
                            }
                        }
                    Button("Paste from clipboard", systemImage: "doc.on.clipboard") {
                        if let s = UIPasteboard.general.string { text = s }
                    }
                    TextField("Sender ID / phone (optional, e.g. MyBank)", text: $sender)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SheetPickerRow(
                        title: "SMS sender bank",
                        selection: $manualBank,
                        options: [SheetPickerOption(id: "", title: "Detect automatically", symbol: "sparkles", color: Theme.cobalt)]
                            + BahrainBankCatalog.allBanks.map { SheetPickerOption(id: $0, title: $0, symbol: "building.columns", color: Theme.secondaryInk) },
                        addConfig: SheetPickerAddConfig(
                            title: "Create Sender Bank",
                            placeholder: "Bank or sender name",
                            message: "Enter a bank or SMS sender name to add it to your sender bank list.",
                            onAdd: { name in
                                if let created = BahrainBankCatalog.addCustomBank(name) {
                                    manualBank = created
                                }
                            }
                        )
                    )
                    AccountPickerRow(
                        title: "Account",
                        selection: $accountID,
                        accounts: accounts,
                        noneLabel: "Detect automatically"
                    )
                } footer: {
                    HStack(spacing: 4) {
                        if GeminiAccount.isConfigured {
                            Image(systemName: "sparkles")
                            Text("On-device bank rules run first; Gemini handles uncertain messages.")
                        } else {
                            Text("On-device bank rules with transfer direction and duplicate checks.")
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
