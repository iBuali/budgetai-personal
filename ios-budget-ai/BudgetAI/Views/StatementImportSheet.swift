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
    @State private var isAnalyzingWithAI = false
    @State private var isCategorizingWithAI = false
    @State private var parseResult: StatementParseResult?
    @State private var rawFileData: Data?
    @State private var rawFilename: String = ""
    @State private var selectedAccountID: UUID?
    @State private var selectedBankName: String = ""
    @State private var customBankName: String = ""
    @State private var errorMessage: String?
    @State private var showSuccessAlert = false
    @State private var showAIFallbackPermissionAlert = false
    @State private var showFieldMappingSheet = false
    @State private var saveLearnedFormatToKB = true
    @State private var importSummary: (imported: Int, skipped: Int) = (0, 0)
    @State private var editingItem: ParsedStatementItem?

    var body: some View {
        NavigationStack {
            Group {
                if isParsing || isAnalyzingWithAI {
                    VStack(spacing: 16) {
                        ProgressView()
                            .scaleEffect(1.4)
                        Text(isAnalyzingWithAI ? "Analyzing Statement with AI (Option 2)..." : "Reading & Parsing Bank Statement...")
                            .font(.headline)
                        Text(isAnalyzingWithAI
                             ? "Identifying statement layout, column mappings, dates, amounts, and balances."
                             : "Extracting transactions, references, and amounts using built-in offline parser.")
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
            .alert("Use AI-Assisted Statement Recognition? (Option 2)", isPresented: $showAIFallbackPermissionAlert) {
                Button("Analyze with AI") {
                    runAIFallbackRecognition()
                }
                Button("Map Columns Manually") {
                    showFieldMappingSheet = true
                }
                Button("Not Now", role: .cancel) {}
            } message: {
                Text("The standard offline parser had low confidence or could not extract all fields from this statement format. Would you like to allow AI (Option 2) to analyze the file, identify the fields, and learn this layout for future imports?")
            }
            .sheet(item: $editingItem) { item in
                EditStatementItemSheet(item: item) { updated in
                    if let idx = parseResult?.items.firstIndex(where: { $0.id == updated.id }) {
                        parseResult?.items[idx] = updated
                    }
                }
            }
            .sheet(isPresented: $showFieldMappingSheet) {
                if let current = parseResult {
                    StatementFieldMappingSheet(
                        result: current,
                        accounts: accounts,
                        allTransactions: allTransactions
                    ) { updatedResult in
                        self.parseResult = updatedResult
                        if let bank = updatedResult.detectedBank, !bank.isEmpty {
                            self.selectedBankName = bank
                        }
                        if self.selectedAccountID == nil {
                            self.selectedAccountID = updatedResult.matchedAccountID
                        }
                        appState.show("Saved statement mapping to Knowledge Base")
                    }
                }
            }
        }
    }

    private var selectedItemsCount: Int {
        parseResult?.selectedItemsCount ?? 0
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
            if !result.inconsistencies.isEmpty {
                Section("Review required") {
                    ForEach(result.inconsistencies, id: \.self) { issue in
                        Text(issue).font(.caption).foregroundStyle(Theme.warning)
                    }
                }
            }
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

            // Option 2: AI-Assisted Statement Recognition & Field Mapping Confirmation
            Section {
                Button {
                    if GeminiAccount.isConfigured {
                        showAIFallbackPermissionAlert = true
                    } else {
                        appState.show("Configure your Gemini API key in Settings to use AI-Assisted Recognition", warning: true)
                    }
                } label: {
                    HStack(spacing: 12) {
                        ZStack {
                            Circle()
                                .fill(result.shouldOfferAIFallback ? Theme.warning.opacity(0.16) : Theme.cobaltSoft)
                                .frame(width: 36, height: 36)
                            Image(systemName: "wand.and.stars")
                                .foregroundStyle(result.shouldOfferAIFallback ? Theme.warning : Theme.cobalt)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text("AI-Assisted Statement Recognition")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(Theme.ink)
                                Text("OPTION 2")
                                    .font(.system(size: 9, weight: .bold))
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .background(Theme.cobaltSoft, in: Capsule())
                                    .foregroundStyle(Theme.cobalt)
                            }
                            Text(result.shouldOfferAIFallback
                                 ? "Extraction looks incomplete or low-confidence (\(Int(result.confidenceScore * 100))%). Tap to analyze structure & map fields with AI."
                                 : "Use AI fallback to re-analyze statement layout, columns, dates, and amounts.")
                                .font(.caption2)
                                .foregroundStyle(Theme.secondaryInk)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.borderless)

                Button {
                    showFieldMappingSheet = true
                } label: {
                    HStack(spacing: 12) {
                        ZStack {
                            Circle()
                                .fill(Theme.cobaltSoft)
                                .frame(width: 36, height: 36)
                            Image(systemName: "slider.horizontal.3")
                                .foregroundStyle(Theme.cobalt)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text("Confirm / Correct Field Mapping")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(Theme.ink)
                                if result.aiFieldMappingNeedsConfirmation {
                                    Text("VERIFY")
                                        .font(.system(size: 9, weight: .bold))
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 2)
                                        .background(Theme.warning.opacity(0.18), in: Capsule())
                                        .foregroundStyle(Theme.warning)
                                }
                            }
                            Text("Review detected Date, Description, Debit, Credit, Amount, Currency, and save rules to Knowledge Base.")
                                .font(.caption2)
                                .foregroundStyle(Theme.secondaryInk)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.borderless)

                if result.isAIFallbackResult {
                    Toggle(isOn: $saveLearnedFormatToKB) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Save Learned Format to Knowledge Base")
                                .font(.caption.weight(.semibold))
                            Text("Automatically recognize future statements from this bank without needing AI.")
                                .font(.caption2)
                                .foregroundStyle(Theme.secondaryInk)
                        }
                    }
                }
            } header: {
                Text("Recognition & Field Mapping")
            }

            // AI Category Suggestion Banner
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
                    .buttonStyle(.borderless)
                    .disabled(isCategorizingWithAI)
                }
            }

            // Selection Controls
            Section {
                HStack(spacing: 14) {
                    Button {
                        if var r = parseResult {
                            r.selectAllNew()
                            parseResult = r
                        }
                    } label: {
                        Label("Select All", systemImage: "checkmark.circle.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.cobalt)
                    }
                    .buttonStyle(.borderless)

                    if result.duplicatesCount > 0 {
                        Button {
                            if var r = parseResult {
                                r.selectAll()
                                parseResult = r
                            }
                        } label: {
                            Text("Include Duplicates")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(Theme.cobalt)
                        }
                        .buttonStyle(.borderless)
                    }

                    Spacer()

                    Button {
                        if var r = parseResult {
                            r.deselectAll()
                            parseResult = r
                        }
                    } label: {
                        Label("Deselect All", systemImage: "circle")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.secondaryInk)
                    }
                    .buttonStyle(.borderless)
                }
            }

            // Transactions list
            Section("Transactions (\(result.items.count))") {
                if result.items.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("No transactions were extracted by the offline parser.")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Theme.ink)
                        Text("Tap \"AI-Assisted Statement Recognition (Option 2)\" above to analyze this statement with AI, or tap \"Confirm / Correct Field Mapping\" to map columns manually.")
                            .font(.caption)
                            .foregroundStyle(Theme.secondaryInk)
                    }
                    .padding(.vertical, 6)
                } else {
                    ForEach(result.items) { item in
                        statementItemRow(item)
                    }
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
            .buttonStyle(.borderless)
            .opacity(item.isDuplicate && !item.isSelected ? 0.5 : 1.0)

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
                .buttonStyle(.borderless)
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

            self.rawFileData = data
            self.rawFilename = filename
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

                    // If the existing parser cannot recognize/extract transactions or confidence is low,
                    // prompt the user to allow Option 2 (AI-Assisted Statement Recognition) or manual column mapping.
                    if result.items.isEmpty || result.confidenceScore < 0.75 || !result.inconsistencies.isEmpty {
                        if GeminiAccount.isConfigured {
                            self.showAIFallbackPermissionAlert = true
                        }
                    }
                }
            }
        } catch {
            isParsing = false
            errorMessage = "Failed to read statement: \(error.localizedDescription)"
        }
    }

    // MARK: - Option 2: AI-Assisted Statement Recognition Handler

    private func runAIFallbackRecognition() {
        guard let data = rawFileData else {
            appState.show("Please select a statement file first.", warning: true)
            return
        }
        guard GeminiAccount.isConfigured else {
            appState.show("Configure your Gemini API key in Settings to use AI-Assisted Recognition.", warning: true)
            return
        }

        isAnalyzingWithAI = true
        let current = parseResult
        let fname = rawFilename

        Task {
            do {
                let (aiResult, recognition) = try await StatementService.analyzeWithAIFallback(
                    fileData: data,
                    filename: fname,
                    existingResult: current,
                    existingAccounts: accounts,
                    existingTransactions: allTransactions
                )
                await MainActor.run {
                    self.isAnalyzingWithAI = false
                    self.parseResult = aiResult
                    if let bank = aiResult.detectedBank, !bank.isEmpty {
                        self.selectedBankName = bank
                    }
                    if self.selectedAccountID == nil {
                        self.selectedAccountID = aiResult.matchedAccountID
                    }
                    if recognition.isMappingUncertain {
                        self.showFieldMappingSheet = true
                    }
                    appState.show("AI recognized \(aiResult.items.count) transactions. Review before importing.")
                }
            } catch {
                await MainActor.run {
                    self.isAnalyzingWithAI = false
                    appState.show("AI analysis failed: \(error.localizedDescription)", warning: true)
                }
            }
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

        // If this format was recognized via AI fallback or verified by the user, persist its structural rule
        // in the Statement Knowledge Base for future automatic recognition without AI.
        if result.isAIFallbackResult && saveLearnedFormatToKB {
            let inferredDocType: StatementDocType = (result.detectedCardLast4 != nil || (result.profileName?.localizedCaseInsensitiveContains("Credit Card") ?? false))
                ? .creditCard
                : .bankAccount
            let inferredSign: AmountSignNotation = inferredDocType == .creditCard ? .creditCardNegativePayment : .columnarDebitCredit
            BankProfileRegistry.learnFromConfirmedStatement(
                bankName: bankToRecord,
                docType: inferredDocType,
                signNotation: inferredSign,
                primaryCurrency: result.detectedCurrency ?? AppSettings.currency,
                dateFormat: nil,
                columnMapping: result.detectedColumnMapping,
                headerKeywords: result.detectedHeaders
            )
        }

        let outcome = StatementService.importConfirmedTransactions(
            result.items,
            into: selectedAccountID,
            sourceBank: bankToRecord,
            context: context
        )

        importSummary = (imported: outcome.importedCount, skipped: outcome.skippedCount)
        showSuccessAlert = true
    }
}

// MARK: - Confirm / Edit Statement Field & Column Mapping Sheet

struct StatementFieldMappingSheet: View {
    @Environment(\.dismiss) private var dismiss

    let result: StatementParseResult
    let accounts: [Account]
    let allTransactions: [MoneyTransaction]
    var onApplied: (StatementParseResult) -> Void

    @State private var bankName: String = ""
    @State private var docType: StatementDocType = .bankAccount
    @State private var signNotation: AmountSignNotation = .columnarDebitCredit
    @State private var currency: String = "BHD"
    @State private var dateFormat: String = "dd/MM/yyyy"
    @State private var dateColumn: String = ""
    @State private var descriptionColumn: String = ""
    @State private var debitColumn: String = ""
    @State private var creditColumn: String = ""
    @State private var amountColumn: String = ""
    @State private var balanceColumn: String = ""
    @State private var referenceColumn: String = ""
    @State private var saveToKnowledgeBase: Bool = true

    var body: some View {
        NavigationStack {
            Form {
                if !result.detectedHeaders.isEmpty {
                    Section("Detected Table Columns") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(result.detectedHeaders, id: \.self) { header in
                                    Text(header)
                                        .font(.caption.weight(.semibold))
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 5)
                                        .background(Theme.cobaltSoft, in: Capsule())
                                        .foregroundStyle(Theme.cobalt)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }

                Section("Institution & Statement Format") {
                    TextField("Bank / Institution Name", text: $bankName)
                    Picker("Statement Type", selection: $docType) {
                        Text("Bank Account Statement").tag(StatementDocType.bankAccount)
                        Text("Credit Card Statement").tag(StatementDocType.creditCard)
                        Text("General Financial Statement").tag(StatementDocType.generic)
                    }
                    Picker("Amount Sign Format", selection: $signNotation) {
                        Text("Separate Debit & Credit Columns").tag(AmountSignNotation.columnarDebitCredit)
                        Text("Signed Amount (+ / - or CR / DR)").tag(AmountSignNotation.standardSigned)
                        Text("Parentheses Signed ((+) / (-))").tag(AmountSignNotation.parenthesesSigned)
                        Text("Credit Card (- Payment / + Purchase)").tag(AmountSignNotation.creditCardNegativePayment)
                    }
                    TextField("Currency (e.g. BHD, USD, SAR, EUR)", text: $currency)
                    TextField("Date Format (e.g. dd/MM/yyyy, yyyy-MM-dd)", text: $dateFormat)
                }

                Section {
                    columnFieldRow(label: "Date Column", text: $dateColumn, placeholder: "e.g. Transaction Date")
                    columnFieldRow(label: "Description Column", text: $descriptionColumn, placeholder: "e.g. Description / Details")
                    columnFieldRow(label: "Debit Column (Optional)", text: $debitColumn, placeholder: "e.g. Debit / Withdrawal")
                    columnFieldRow(label: "Credit Column (Optional)", text: $creditColumn, placeholder: "e.g. Credit / Deposit")
                    columnFieldRow(label: "Signed Amount Column (Optional)", text: $amountColumn, placeholder: "e.g. Amount")
                    columnFieldRow(label: "Balance Column (Optional)", text: $balanceColumn, placeholder: "e.g. Balance")
                    columnFieldRow(label: "Reference Column (Optional)", text: $referenceColumn, placeholder: "e.g. Reference")
                } header: {
                    Text("Column / Field Mapping")
                } footer: {
                    Text("Confirm or adjust column headers before importing. Never guesses uncertain financial values.")
                }

                Section {
                    Toggle("Save Mapping to Statement Knowledge Base", isOn: $saveToKnowledgeBase)
                } footer: {
                    Text("Once saved, future statements matching this bank and column structure will be recognized automatically on-device.")
                }
            }
            .navigationTitle("Field & Column Mapping")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply & Verify") {
                        applyMapping()
                    }
                    .fontWeight(.semibold)
                }
            }
            .onAppear {
                bankName = result.detectedBank ?? ""
                if result.detectedCardLast4 != nil || (result.profileName?.localizedCaseInsensitiveContains("Credit Card") ?? false) {
                    docType = .creditCard
                    signNotation = .creditCardNegativePayment
                }
                currency = result.detectedCurrency ?? AppSettings.currency
                if let map = result.detectedColumnMapping {
                    dateColumn = map.dateColumnHeader ?? ""
                    descriptionColumn = map.descriptionColumnHeader ?? ""
                    debitColumn = map.debitColumnHeader ?? ""
                    creditColumn = map.creditColumnHeader ?? ""
                    amountColumn = map.amountColumnHeader ?? ""
                    balanceColumn = map.balanceColumnHeader ?? ""
                    referenceColumn = map.referenceColumnHeader ?? ""
                } else {
                    // Pre-fill from detected headers if available
                    for h in result.detectedHeaders {
                        let low = h.lowercased()
                        if dateColumn.isEmpty && (low.contains("date") || low.contains("التاريخ")) { dateColumn = h }
                        else if descriptionColumn.isEmpty && (low.contains("desc") || low.contains("detail") || low.contains("particular") || low.contains("narrative") || low.contains("البيان") || low.contains("الوصف")) { descriptionColumn = h }
                        else if debitColumn.isEmpty && (low.contains("debit") || low.contains("withdrawal") || low.contains("مدين")) { debitColumn = h }
                        else if creditColumn.isEmpty && (low.contains("credit") || low.contains("deposit") || low.contains("دائن")) { creditColumn = h }
                        else if amountColumn.isEmpty && (low.contains("amount") || low.contains("المبلغ")) && !low.contains("balance") { amountColumn = h }
                        else if balanceColumn.isEmpty && (low.contains("balance") || low.contains("الرصيد")) { balanceColumn = h }
                        else if referenceColumn.isEmpty && (low.contains("ref") || low.contains("المرجع")) { referenceColumn = h }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func columnFieldRow(label: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.secondaryInk)
                Spacer()
                if !result.detectedHeaders.isEmpty {
                    Menu("Pick Header") {
                        Button("Clear") { text.wrappedValue = "" }
                        ForEach(result.detectedHeaders, id: \.self) { h in
                            Button(h) { text.wrappedValue = h }
                        }
                    }
                    .font(.caption2.weight(.semibold))
                }
            }
            TextField(placeholder, text: text)
                .font(.subheadline)
        }
        .padding(.vertical, 2)
    }

    private func applyMapping() {
        let mapping = StatementColumnMapping(
            dateColumnHeader: dateColumn.isEmpty ? nil : dateColumn,
            descriptionColumnHeader: descriptionColumn.isEmpty ? nil : descriptionColumn,
            debitColumnHeader: debitColumn.isEmpty ? nil : debitColumn,
            creditColumnHeader: creditColumn.isEmpty ? nil : creditColumn,
            amountColumnHeader: amountColumn.isEmpty ? nil : amountColumn,
            balanceColumnHeader: balanceColumn.isEmpty ? nil : balanceColumn,
            referenceColumnHeader: referenceColumn.isEmpty ? nil : referenceColumn
        )
        let updated = StatementService.applyConfirmedFieldMapping(
            to: result,
            bankName: bankName,
            docType: docType,
            signNotation: signNotation,
            currency: currency,
            dateFormat: dateFormat,
            columnMapping: mapping,
            saveToKnowledgeBase: saveToKnowledgeBase,
            existingAccounts: accounts,
            existingTransactions: allTransactions
        )
        onApplied(updated)
        dismiss()
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
