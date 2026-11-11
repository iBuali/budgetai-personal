import SwiftUI
import SwiftData
import UniformTypeIdentifiers

// MARK: - Statement Import & Review Sheet

struct StatementImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(AppState.self) private var appState

    @Query(sort: \Account.createdAt) private var accounts: [Account]
    @Query private var allTransactions: [MoneyTransaction]

    @State private var showFilePicker = false
    @State private var isParsing = false
    @State private var isCategorizingWithAI = false
    @State private var parseResult: StatementParseResult?
    @State private var selectedAccountID: UUID?
    @State private var selectedBankName: String = ""
    @State private var customBankName: String = ""
    @State private var errorMessage: String?
    @State private var showSuccessAlert = false
    @State private var importSummary: (imported: Int, skipped: Int) = (0, 0)
    @State private var editingItem: ParsedStatementItem?

    var body: some View {
        NavigationStack {
            Group {
                if isParsing {
                    VStack(spacing: 16) {
                        ProgressView()
                            .scaleEffect(1.4)
                        Text("Reading & Parsing Bank Statement...")
                            .font(.headline)
                        Text("Extracting transactions, references, and amounts using built-in offline parser.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let result = parseResult {
                    reviewStatementView(result)
                } else {
                    emptyUploadPromptView
                }
            }
            .navigationTitle("Import Statement")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                if parseResult != nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Confirm Import (\(selectedItemsCount))") {
                            commitImport()
                        }
                        .fontWeight(.semibold)
                        .disabled(selectedItemsCount == 0)
                    }
                }
            }
            .fileImporter(
                isPresented: $showFilePicker,
                allowedContentTypes: [
                    UTType.pdf,
                    UTType.commaSeparatedText,
                    UTType.tabSeparatedText,
                    UTType.plainText,
                    UTType(filenameExtension: "xlsx") ?? .data,
                    UTType(filenameExtension: "xls") ?? .data
                ],
                allowsMultipleSelection: false
            ) { outcome in
                handlePickedFile(outcome)
            }
            .alert("Import Successful", isPresented: $showSuccessAlert) {
                Button("Done") { dismiss() }
            } message: {
                Text("Successfully imported \(importSummary.imported) transactions into transaction history. Your account balances remain unchanged.")
            }
            .sheet(item: $editingItem) { item in
                EditStatementItemSheet(item: item) { updated in
                    if let idx = parseResult?.items.firstIndex(where: { $0.id == updated.id }) {
                        parseResult?.items[idx] = updated
                    }
                }
            }
        }
    }

    private var selectedItemsCount: Int {
        parseResult?.items.filter { $0.isSelected && !$0.isDuplicate }.count ?? 0
    }

    // MARK: - Empty Upload Prompt View

    private var emptyUploadPromptView: some View {
        VStack(spacing: 24) {
            Spacer()

            ZStack {
                Circle()
                    .fill(Theme.cobaltSoft)
                    .frame(width: 88, height: 88)
                Image(systemName: "doc.text.viewfinder")
                    .font(.system(size: 40))
                    .foregroundStyle(Theme.cobalt)
            }

            VStack(spacing: 8) {
                Text("Bank & Card Statement Import")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(Theme.ink)

                Text("Upload your official PDF or Excel statement (.xlsx, .xls, .csv). Transactions are extracted instantly on-device without AI.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondaryInk)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
            }

            VStack(alignment: .leading, spacing: 10) {
                featureBullet(symbol: "lock.shield.fill", color: Theme.positive, text: "Privacy-first: parsing runs 100% on-device")
                featureBullet(symbol: "creditcard.and.123", color: Theme.cobalt, text: "Auto-matches accounts via IBAN or card last 4 digits")
                featureBullet(symbol: "checkmark.circle.badge.questionmark.fill", color: Theme.warning, text: "Duplicate prevention against existing transactions")
                featureBullet(symbol: "scalemass.fill", color: Theme.ink, text: "Safe: never alters or modifies existing account balances")
            }
            .padding(16)
            .background(Theme.track.opacity(0.5), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.horizontal, 20)

            if let err = errorMessage {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(Theme.negative)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }

            Spacer()

            Button {
                showFilePicker = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.up.doc.fill")
                    Text("Select PDF or Excel Statement")
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Theme.cobalt, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .foregroundStyle(.white)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
    }

    private func featureBullet(symbol: String, color: Color, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .font(.subheadline)
                .frame(width: 20)
            Text(text)
                .font(.caption)
                .foregroundStyle(Theme.ink)
        }
    }

    // MARK: - Review Statement View

    @ViewBuilder
    private func reviewStatementView(_ result: StatementParseResult) -> some View {
        List {
            // Header summary
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Extracted Transactions")
                                .font(.headline)
                                .foregroundStyle(Theme.ink)
                            Text("\(result.newItemsCount) new transactions • \(result.duplicatesCount) skipped duplicates")
                                .font(.caption)
                                .foregroundStyle(Theme.secondaryInk)
                        }
                        Spacer()
                        Text(result.format.rawValue)
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Theme.cobaltSoft, in: Capsule())
                            .foregroundStyle(Theme.cobalt)
                    }

                    Divider()

                    // Account routing selector
                    HStack {
                        Label("Target Account", systemImage: "building.columns.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.ink)
                        Spacer()
                        Picker("Account", selection: $selectedAccountID) {
                            Text("No Account (Unassigned)").tag(UUID?.none)
                            ForEach(accounts) { acc in
                                HStack {
                                    Image(systemName: acc.kind.symbol)
                                    Text("\(acc.name) (\(acc.kind.title))")
                                }
                                .tag(UUID?.some(acc.id))
                            }
                        }
                    }

                    if let bank = result.detectedBank {
                        HStack {
                            Text("Detected Bank / Institution:")
                                .font(.caption2)
                                .foregroundStyle(Theme.secondaryInk)
                            Text(bank)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(Theme.cobalt)
                        }
                    }

                    if let iban = result.detectedAccountIBAN {
                        HStack {
                            Text("Detected IBAN / Suffix:")
                                .font(.caption2)
                                .foregroundStyle(Theme.secondaryInk)
                            Text("**\(String(iban.suffix(4)))")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(Theme.cobalt)
                        }
                    }

                    if let card = result.detectedCardLast4 {
                        HStack {
                            Text("Detected Card Digits:")
                                .font(.caption2)
                                .foregroundStyle(Theme.secondaryInk)
                            Text("Ending in \(card)")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(Theme.cobalt)
                        }
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("Statement Information")
            } footer: {
                Text("Review and edit any transaction before finalizing. Existing account balances will NOT be changed.")
            }

            // AI Suggestion Banner
            if GeminiAccount.isConfigured && result.items.contains(where: { $0.category == .other }) {
                Section {
                    Button {
                        requestAISuggestions()
                    } label: {
                        HStack(spacing: 12) {
                            ZStack {
                                Circle()
                                    .fill(Theme.cobaltSoft)
                                    .frame(width: 36, height: 36)
                                if isCategorizingWithAI {
                                    ProgressView()
                                } else {
                                    Image(systemName: "sparkles")
                                        .foregroundStyle(Theme.cobalt)
                                }
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Suggest Categories with AI")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(Theme.ink)
                                Text("Optionally let Gemini categorize unassigned merchants.")
                                    .font(.caption2)
                                    .foregroundStyle(Theme.secondaryInk)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(isCategorizingWithAI)
                }
            }

            // Selection Controls
            Section {
                HStack {
                    Button("Select All New") {
                        if var r = parseResult {
                            for i in r.items.indices where !r.items[i].isDuplicate {
                                r.items[i].isSelected = true
                            }
                            parseResult = r
                        }
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.cobalt)

                    Spacer()

                    Button("Deselect All") {
                        if var r = parseResult {
                            for i in r.items.indices {
                                r.items[i].isSelected = false
                            }
                            parseResult = r
                        }
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.secondaryInk)
                }
            }

            // Transactions list
            Section("Transactions (\(result.items.count))") {
                ForEach(result.items) { item in
                    statementItemRow(item)
                }
            }
        }
    }

    @ViewBuilder
    private func statementItemRow(_ item: ParsedStatementItem) -> some View {
        HStack(spacing: 12) {
            // Checkbox
            Button {
                toggleSelection(for: item.id)
            } label: {
                Image(systemName: item.isSelected ? "checkmark.square.fill" : "square")
                    .font(.title3)
                    .foregroundStyle(item.isSelected ? Theme.cobalt : Color.secondary)
            }
            .buttonStyle(.plain)
            .disabled(item.isDuplicate)
            .opacity(item.isDuplicate ? 0.35 : 1.0)

            // Category Icon Badge
            IconBadge(symbol: item.category.symbol, color: item.category.color, size: 36)

            // Merchant, Date & Reference
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(item.merchant)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(item.isDuplicate ? Theme.secondaryInk : Theme.ink)
                        .lineLimit(1)

                    if item.isDuplicate {
                        Text("DUPLICATE")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Theme.warning.opacity(0.16), in: Capsule())
                            .foregroundStyle(Theme.warning)
                    } else if item.aiSuggestedCategory {
                        HStack(spacing: 2) {
                            Image(systemName: "sparkles")
                            Text("AI")
                        }
                        .font(.system(size: 8, weight: .bold))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Theme.cobaltSoft, in: Capsule())
                        .foregroundStyle(Theme.cobalt)
                    }
                }

                HStack(spacing: 6) {
                    Text(DateFormatter.localizedString(from: item.date, dateStyle: .short, timeStyle: .none))
                        .font(.caption2)
                        .foregroundStyle(Theme.secondaryInk)

                    Text("•")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Text(item.category.title)
                        .font(.caption2)
                        .foregroundStyle(item.category.color)

                    if let ref = item.reference {
                        Text("•")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(ref)
                            .font(.caption2.monospaced())
                            .foregroundStyle(Theme.secondaryInk)
                            .lineLimit(1)
                    }
                }

                if let dupReason = item.duplicateReason {
                    Text(dupReason)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.warning)
                        .lineLimit(1)
                }
            }

            Spacer()

            // Amount
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(item.isIncome ? "+" : "-")\(String(format: "%.3f", item.amount))")
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(item.isIncome ? Theme.positive : Theme.ink)

                Button {
                    editingItem = item
                } label: {
                    Text("Edit")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(Theme.cobalt)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 2)
        .opacity(item.isDuplicate ? 0.6 : 1.0)
    }

    private func toggleSelection(for id: UUID) {
        if var r = parseResult, let idx = r.items.firstIndex(where: { $0.id == id }) {
            r.items[idx].isSelected.toggle()
            parseResult = r
        }
    }

    // MARK: - File Parsing Handler

    private func handlePickedFile(_ outcome: Result<[URL], Error>) {
        do {
            guard let url = try outcome.get().first else { return }
            guard url.startAccessingSecurityScopedResource() else {
                errorMessage = "Unable to access selected file due to system permissions."
                return
            }
            defer { url.stopAccessingSecurityScopedResource() }

            let data = try Data(contentsOf: url)
            let filename = url.lastPathComponent

            isParsing = true
            errorMessage = nil

            DispatchQueue.global(qos: .userInitiated).async {
                let result = StatementService.parse(
                    fileData: data,
                    filename: filename,
                    existingAccounts: accounts,
                    existingTransactions: allTransactions
                )

                DispatchQueue.main.async {
                    self.isParsing = false
                    self.parseResult = result
                    self.selectedAccountID = result.matchedAccountID
                    self.selectedBankName = result.detectedBank ?? ""

                    if result.items.isEmpty {
                        self.errorMessage = "No transactions found in this statement. Please check the file format or try an Excel/CSV export from your online banking."
                    }
                }
            }
        } catch {
            isParsing = false
            errorMessage = "Failed to read statement: \(error.localizedDescription)"
        }
    }

    // MARK: - AI Suggestion Handler

    private func requestAISuggestions() {
        guard let result = parseResult else { return }
        isCategorizingWithAI = true

        Task {
            do {
                let suggestions = try await StatementService.requestAICategorySuggestions(for: result.items)
                await MainActor.run {
                    if var r = parseResult {
                        for i in r.items.indices {
                            if let newCat = suggestions[r.items[i].id] {
                                r.items[i].category = newCat
                                r.items[i].aiSuggestedCategory = true
                            }
                        }
                        self.parseResult = r
                    }
                    self.isCategorizingWithAI = false
                    appState.show("AI updated \(suggestions.count) transaction categories")
                }
            } catch {
                await MainActor.run {
                    self.isCategorizingWithAI = false
                    appState.show(error.localizedDescription, warning: true)
                }
            }
        }
    }

    // MARK: - Commit Import

    private func commitImport() {
        guard let result = parseResult else { return }

        let bankToRecord = !selectedBankName.isEmpty ? selectedBankName : (result.detectedBank ?? "Bank Statement")

        let outcome = StatementService.importConfirmedTransactions(
            result.items,
            into: selectedAccountID,
            sourceBank: bankToRecord,
            context: context
        )

        importSummary = outcome
        showSuccessAlert = true
    }
}

// MARK: - Edit Single Statement Item Sheet

struct EditStatementItemSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var item: ParsedStatementItem
    var onSaved: (ParsedStatementItem) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Transaction Details") {
                    TextField("Merchant / Description", text: $item.merchant)
                    DatePicker("Date", selection: $item.date, displayedComponents: [.date])
                    HStack {
                        Text("Amount")
                        Spacer()
                        TextField("0.000", value: $item.amount, format: .number)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                    Toggle("Is Income / Credit", isOn: $item.isIncome)
                }

                Section("Category") {
                    Picker("Category", selection: $item.category) {
                        ForEach(SpendCategory.allCases) { cat in
                            Label(cat.title, systemImage: cat.symbol).tag(cat)
                        }
                    }
                }

                Section("Reference") {
                    TextField("Reference Number", text: Binding(
                        get: { item.reference ?? "" },
                        set: { item.reference = $0.isEmpty ? nil : $0 }
                    ))
                }
            }
            .navigationTitle("Edit Transaction")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        onSaved(item)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }
}
