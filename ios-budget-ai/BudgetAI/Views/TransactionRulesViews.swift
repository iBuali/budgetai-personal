import SwiftUI
import SwiftData

// MARK: - Common Regional Banks List

private let regionalBanksList: [String] = [
    "BisB",
    "ila Bank",
    "NBB",
    "BBK",
    "Al Salam Bank",
    "Khaleeji Bank",
    "AUB",
    "KFH",
    "Standard Chartered",
    "BenefitPay"
]

// MARK: - Create / Edit Rule Sheet (from Transaction Details or Rule List)

private enum RuleEditorTab: String, CaseIterable {
    case settings = "SETTINGS"
    case preview = "PREVIEW"
}

struct TransactionRuleBuilderSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Account.createdAt) private var accounts: [Account]
    @Query(sort: \SavingsGoal.createdAt) private var goals: [SavingsGoal]
    @Query(sort: \MoneyTransaction.date, order: .reverse) private var allTransactions: [MoneyTransaction]
    @AppStorage(Keys.currency) private var currency = "BHD"

    let sourceTransaction: MoneyTransaction?
    let existingRule: TransactionRule?
    var onSaved: ((TransactionRule) -> Void)? = nil

    @State private var selectedTab: RuleEditorTab = .settings
    @State private var applyToExisting: Bool = true

    @State private var ruleName: String = ""
    @State private var isEnabled: Bool = true
    @State private var logic: RuleConditionLogic = .and
    @State private var availableConditions: [RuleCondition] = []
    @State private var selectedFields: Set<RuleConditionField> = []
    @State private var locationRadius: Double = 10.0
    @State private var originalSMSMatchMode: RuleSMSMatchMode = .contains
    @State private var originalSMSText: String = ""
    @State private var manualConditionValues: [RuleConditionField: String] = [:]
    @State private var manualAccountConditionID: UUID? = nil
    @State private var selectedDirectionType: RuleTransactionTypeOption = .transferOut
    @State private var selectedMonth: Int = Calendar.current.component(.month, from: .now)
    @State private var selectedDay: Int = Calendar.current.component(.day, from: .now)
    @State private var selectedWeekday: Int = Calendar.current.component(.weekday, from: .now)

    // THEN – Actions
    @State private var enableSetCategory: Bool = false
    @State private var selectedCategory: SpendCategory = .other
    @State private var showCategoryPicker: Bool = false
    @State private var fromAccountID: UUID?
    @State private var toAccountID: UUID?

    @State private var enableOverrideAccount: Bool = false
    @State private var overrideAccountID: UUID?

    @State private var enableSetMerchant: Bool = false
    @State private var actionMerchant: String = ""

    @State private var enableSetBank: Bool = false
    @State private var actionBank: String = ""
    @State private var selectedBankPicker: String = "Custom"

    @State private var enableSetLocation: Bool = false
    @State private var actionLocationName: String = ""
    @State private var actionLocationAddress: String?
    @State private var actionLatitude: Double?
    @State private var actionLongitude: Double?
    @State private var showLocationPicker: Bool = false

    @State private var enableSetNote: Bool = false
    @State private var actionNote: String = ""

    @State private var enableSetGoal: Bool = false
    @State private var actionGoalID: UUID?

    @State private var showConflictAlert: Bool = false
    @State private var conflictingRuleName: String = ""
    @State private var cachedAffected: [(tx: MoneyTransaction, changes: [(label: String, before: String, after: String)])] = []
    @State private var hasComputedInitialPreview: Bool = false

    private struct RulePreviewKey: Equatable {
        let logic: RuleConditionLogic
        let availableConditions: [RuleCondition]
        let selectedFields: Set<RuleConditionField>
        let locationRadius: Double
        let originalSMSMatchMode: RuleSMSMatchMode
        let originalSMSText: String
        let manualConditionValues: [RuleConditionField: String]
        let manualAccountConditionID: UUID?
        let selectedDirectionType: RuleTransactionTypeOption
        let selectedMonth: Int
        let selectedDay: Int
        let selectedWeekday: Int
        let enableSetCategory: Bool
        let selectedCategoryRaw: String
        let fromAccountID: UUID?
        let toAccountID: UUID?
        let enableOverrideAccount: Bool
        let overrideAccountID: UUID?
        let enableSetMerchant: Bool
        let actionMerchant: String
        let enableSetBank: Bool
        let actionBank: String
        let enableSetLocation: Bool
        let actionLocationName: String
        let actionLocationAddress: String?
        let actionLatitude: Double?
        let actionLongitude: Double?
        let enableSetNote: Bool
        let actionNote: String
        let enableSetGoal: Bool
        let actionGoalID: UUID?
        let transactionCount: Int
    }

    private var previewKey: RulePreviewKey {
        RulePreviewKey(
            logic: logic,
            availableConditions: availableConditions,
            selectedFields: selectedFields,
            locationRadius: locationRadius,
            originalSMSMatchMode: originalSMSMatchMode,
            originalSMSText: originalSMSText,
            manualConditionValues: manualConditionValues,
            manualAccountConditionID: manualAccountConditionID,
            selectedDirectionType: selectedDirectionType,
            selectedMonth: selectedMonth,
            selectedDay: selectedDay,
            selectedWeekday: selectedWeekday,
            enableSetCategory: enableSetCategory,
            selectedCategoryRaw: selectedCategory.rawValue,
            fromAccountID: fromAccountID,
            toAccountID: toAccountID,
            enableOverrideAccount: enableOverrideAccount,
            overrideAccountID: overrideAccountID,
            enableSetMerchant: enableSetMerchant,
            actionMerchant: actionMerchant,
            enableSetBank: enableSetBank,
            actionBank: actionBank,
            enableSetLocation: enableSetLocation,
            actionLocationName: actionLocationName,
            actionLocationAddress: actionLocationAddress,
            actionLatitude: actionLatitude,
            actionLongitude: actionLongitude,
            enableSetNote: enableSetNote,
            actionNote: actionNote,
            enableSetGoal: enableSetGoal,
            actionGoalID: actionGoalID,
            transactionCount: allTransactions.count
        )
    }

    private var store: TransactionRuleStore { TransactionRuleStore.shared }

    private var isManualCreation: Bool {
        sourceTransaction == nil && existingRule == nil
    }

    /// True if this condition should show an inline manual editor when checked (either creating from scratch
    /// or adding a condition that wasn't auto-captured from a source transaction).
    private func needsManualInput(for cond: RuleCondition) -> Bool {
        if cond.field == .originalSMS || cond.field == .direction || cond.field == .monthDay || cond.field == .dayOfWeek {
            return false
        }
        if isManualCreation { return true }
        return cond.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || (manualConditionValues[cond.field] != nil)
            || (cond.field == .accountID && cond.value.isEmpty)
    }

    private var selectedConditionsList: [RuleCondition] {
        availableConditions.filter { selectedFields.contains($0.field) }
    }

    private var canSave: Bool {
        guard !selectedConditionsList.isEmpty else { return false }
        return selectedConditionsList.allSatisfy { cond in
            if cond.field == .direction || cond.field == .monthDay || cond.field == .dayOfWeek {
                return true
            }
            if cond.field == .originalSMS {
                let text = originalSMSText.trimmingCharacters(in: .whitespacesAndNewlines)
                return !text.isEmpty || !cond.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            if needsManualInput(for: cond) {
                if cond.field == .accountID {
                    return manualAccountConditionID != nil || !cond.value.isEmpty
                }
                let raw = (manualConditionValues[cond.field] ?? cond.value).trimmingCharacters(in: .whitespacesAndNewlines)
                if cond.field == .amount {
                    return (Money.parse(raw) ?? 0) > 0
                }
                return !raw.isEmpty
            }
            return !cond.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func computeAffectedTransactions() -> [(tx: MoneyTransaction, changes: [(label: String, before: String, after: String)])] {
        guard canSave else { return [] }
        let candidate = buildRule()
        return allTransactions.compactMap { tx in
            guard store.matches(rule: candidate, context: RuleEvaluationContext(from: tx), ignoreEnabledState: true) else {
                return nil
            }
            let changes = previewChanges(for: tx, rule: candidate)
            guard !changes.isEmpty else { return nil }
            return (tx: tx, changes: changes)
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                tabHeader(previewCount: cachedAffected.count)

                Group {
                    switch selectedTab {
                    case .settings:
                        Form {
                            conditionsSection
                            logicSection
                            thenActionsSection
                            ruleInfoSection
                        }
                        .scrollContentBackground(.hidden)
                        .canvasBackground()
                    case .preview:
                        previewTabView(affected: cachedAffected)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                bottomActionFooter(affectedCount: cachedAffected.count)
            }
            .navigationTitle(existingRule == nil ? "Create rule" : "Edit rule")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(Theme.ink)
                    }
                    .accessibilityLabel("Close")
                }
            }
            .onAppear(perform: loadInitialState)
            .task(id: previewKey) {
                if hasComputedInitialPreview {
                    try? await Task.sleep(for: .milliseconds(120))
                    guard !Task.isCancelled else { return }
                }
                cachedAffected = computeAffectedTransactions()
                hasComputedInitialPreview = true
            }
            .alert("Duplicate Rule Conditions", isPresented: $showConflictAlert) {
                Button("Update Existing Rule") {
                    commitSave()
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("A rule (\"\(conflictingRuleName)\") already uses these exact conditions. Would you like to update that rule with these actions instead?")
            }
            .sheet(isPresented: $showLocationPicker) {
                LocationPickerSheet(
                    initialName: actionLocationName,
                    initialLatitude: actionLatitude,
                    initialLongitude: actionLongitude
                ) { loc in
                    actionLocationName = loc.name
                    actionLocationAddress = loc.address
                    actionLatitude = loc.latitude
                    actionLongitude = loc.longitude
                }
            }
        }
    }

    @ViewBuilder
    private var conditionsSection: some View {
        Section {
            if availableConditions.isEmpty {
                Text("No transaction fields available to capture.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(availableConditions) { cond in
                    conditionRow(cond)
                }
            }
        } header: {
            Text("1. IF — Select Captured Conditions")
        } footer: {
            Text("Check the fields captured from this transaction that should identify similar future transactions.")
        }
    }

    @ViewBuilder
    private func conditionRow(_ cond: RuleCondition) -> some View {
        let isSelected = selectedFields.contains(cond.field)
        VStack(alignment: .leading, spacing: 8) {
            Button {
                if isSelected {
                    selectedFields.remove(cond.field)
                } else {
                    selectedFields.insert(cond.field)
                }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                        .font(.title3)
                        .foregroundStyle(isSelected ? Theme.brand : .secondary)

                    Image(systemName: cond.field.symbol)
                        .font(.subheadline)
                        .foregroundStyle(Theme.brand)
                        .frame(width: 24)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(cond.field.label)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Theme.ink)
                        Text(displayValue(for: cond))
                            .font(.caption)
                            .foregroundStyle(Theme.secondaryInk)
                            .lineLimit(1)
                    }

                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // If this is the Original SMS condition and it is selected, offer Contains vs Exactly match
            if cond.field == .originalSMS && isSelected {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("SMS Match Mode", selection: $originalSMSMatchMode) {
                        ForEach(RuleSMSMatchMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    if originalSMSMatchMode == .contains || isManualCreation || cond.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        TextField(
                            originalSMSMatchMode == .contains ? "Text the SMS must contain" : "Paste full example SMS",
                            text: $originalSMSText,
                            axis: .vertical
                        )
                            .font(.caption)
                            .lineLimit(2...4)
                            .padding(8)
                            .background(Theme.track.opacity(0.65), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    if originalSMSMatchMode == .exactTemplate {
                        Text("Matches this exact SMS structure while ignoring date, time, reference number, and balance.")
                            .font(.caption2)
                            .foregroundStyle(Theme.secondaryInk)
                    }
                }
                .padding(.leading, 36)
                .padding(.top, 2)
            }

            // Inline controls for Transaction Type, Date (Day & Month), and Day of Week
            if cond.field == .direction && isSelected {
                VStack(alignment: .leading, spacing: 6) {
                    Picker("Transaction Type", selection: $selectedDirectionType) {
                        ForEach(RuleTransactionTypeOption.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .pickerStyle(.menu)
                    .font(.caption)
                }
                .padding(.leading, 36)
                .padding(.top, 2)
            }

            if cond.field == .monthDay && isSelected {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 12) {
                        Picker("Day", selection: Binding(
                            get: { min(RuleDateHelper.maxDays(inMonth: selectedMonth), max(1, selectedDay)) },
                            set: { selectedDay = $0 }
                        )) {
                            ForEach(1...RuleDateHelper.maxDays(inMonth: selectedMonth), id: \.self) { day in
                                Text("\(day)").tag(day)
                            }
                        }
                        .pickerStyle(.menu)
                        .font(.caption)

                        Picker("Month", selection: Binding(
                            get: { selectedMonth },
                            set: { newMonth in
                                selectedMonth = newMonth
                                let cap = RuleDateHelper.maxDays(inMonth: newMonth)
                                if selectedDay > cap { selectedDay = cap }
                            }
                        )) {
                            ForEach(1...12, id: \.self) { month in
                                Text(RuleDateHelper.monthAbbreviations[month - 1]).tag(month)
                            }
                        }
                        .pickerStyle(.menu)
                        .font(.caption)
                    }
                    Text("Matches \(RuleDateHelper.monthDayDisplay(month: selectedMonth, day: selectedDay)) every year (ignores year).")
                        .font(.caption2)
                        .foregroundStyle(Theme.secondaryInk)
                }
                .padding(.leading, 36)
                .padding(.top, 2)
            }

            if cond.field == .dayOfWeek && isSelected {
                VStack(alignment: .leading, spacing: 6) {
                    Picker("Day of Week", selection: $selectedWeekday) {
                        ForEach(1...7, id: \.self) { weekday in
                            Text(RuleDateHelper.weekdayDisplay(weekday)).tag(weekday)
                        }
                    }
                    .pickerStyle(.menu)
                    .font(.caption)
                }
                .padding(.leading, 36)
                .padding(.top, 2)
            }

            // Inline manual inputs when creating from scratch or adding an uncaptured condition while editing
            if needsManualInput(for: cond) && isSelected && cond.field != .originalSMS {
                Group {
                    if cond.field == .accountID {
                        Picker("Match Account", selection: $manualAccountConditionID) {
                            Text("Select Account").tag(UUID?.none)
                            ForEach(accounts) { acc in
                                Text(acc.name).tag(UUID?.some(acc.id))
                            }
                        }
                        .font(.caption)
                    } else {
                        TextField(manualPlaceholder(for: cond.field), text: Binding(
                            get: { manualConditionValues[cond.field] ?? "" },
                            set: { manualConditionValues[cond.field] = $0 }
                        ))
                        .font(.caption)
                        .keyboardType(cond.field == .amount ? .decimalPad : .default)
                        .padding(8)
                        .background(Theme.track.opacity(0.65), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }
                .padding(.leading, 36)
                .padding(.top, 2)
            }
        }
    }

    private func displayValue(for cond: RuleCondition) -> String {
        if cond.field == .direction {
            return selectedDirectionType.title
        }
        if cond.field == .monthDay {
            return RuleDateHelper.monthDayDisplay(month: selectedMonth, day: selectedDay)
        }
        if cond.field == .dayOfWeek {
            return RuleDateHelper.weekdayDisplay(selectedWeekday)
        }
        if cond.field == .location && (cond.latitude != nil || actionLatitude != nil) {
            let place = cond.value.isEmpty ? "GPS Location" : cond.value
            return "\(place) (within \(Int(locationRadius))m)"
        }
        return cond.displayValue
    }

    @ViewBuilder
    private var logicSection: some View {
        Section {
            Picker("Match Logic", selection: $logic) {
                Text("AND").tag(RuleConditionLogic.and)
                Text("OR").tag(RuleConditionLogic.or)
            }
            .pickerStyle(.segmented)
        } header: {
            Text("2. Condition Logic")
        }
    }

    @ViewBuilder
    private var thenActionsSection: some View {
        Section {
            // 1. Set Category (toggleable, not default)
            Toggle(isOn: $enableSetCategory) {
                Label("Set Category", systemImage: "tag.fill")
            }
            if enableSetCategory {
                Button {
                    showCategoryPicker = true
                } label: {
                    HStack(spacing: 10) {
                        Text("Category")
                            .foregroundStyle(Theme.ink)
                        Spacer()
                        HStack(spacing: 6) {
                            CategoryIcon(category: selectedCategory, size: 22)
                            Text(selectedCategory.title)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(Theme.ink)
                                .lineLimit(1)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(Theme.secondaryInk)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Theme.track.opacity(0.65), in: Capsule())
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .sheet(isPresented: $showCategoryPicker) {
                    TransactionCategoryPickerSheet(
                        selected: selectedCategory,
                        initialTab: selectedCategory.isTransferCategory ? .transfers : (selectedCategory.isIncomeCategory ? .income : .expenses),
                        onSelect: { chosen in
                            selectedCategory = chosen
                        }
                    )
                    .presentationDetents([.medium, .large])
                }

                // If Category is Internal Transfer: From and To account pickers
                if selectedCategory == .internalTransfer {
                    Picker("From Account", selection: $fromAccountID) {
                        Text("Keep Detected Account").tag(UUID?.none)
                        ForEach(accounts) { acc in
                            Text(acc.name).tag(UUID?.some(acc.id))
                        }
                    }

                    Picker("To Account", selection: $toAccountID) {
                        Text("Select Destination Account").tag(UUID?.none)
                        ForEach(accounts.filter { $0.id != fromAccountID }) { acc in
                            Text(acc.name).tag(UUID?.some(acc.id))
                        }
                    }
                } else if selectedCategory == .transfers {
                    Picker("From / To Account", selection: $fromAccountID) {
                        Text("Keep Detected Account").tag(UUID?.none)
                        ForEach(accounts) { acc in
                            Text(acc.name).tag(UUID?.some(acc.id))
                        }
                    }
                }
            }

            // 2. Override Account (Force-routes to designated account)
            Toggle(isOn: $enableOverrideAccount) {
                VStack(alignment: .leading, spacing: 2) {
                    Label("Override Account", systemImage: "wallet.bifold.fill")
                    Text("Force-routes transaction to a designated account")
                        .font(.caption2)
                        .foregroundStyle(Theme.secondaryInk)
                }
            }
            if enableOverrideAccount {
                Picker("Designated Account", selection: $overrideAccountID) {
                    Text("Select Account").tag(UUID?.none)
                    ForEach(accounts) { acc in
                        Text(acc.name).tag(UUID?.some(acc.id))
                    }
                }
            }

            // 3. Set Merchant Name (Renames or cleans up cryptic SMS text)
            Toggle(isOn: $enableSetMerchant) {
                VStack(alignment: .leading, spacing: 2) {
                    Label("Set Merchant Name", systemImage: "storefront.fill")
                    Text("Renames or cleans up cryptic SMS merchant text")
                        .font(.caption2)
                        .foregroundStyle(Theme.secondaryInk)
                }
            }
            if enableSetMerchant {
                TextField("Clean Merchant Name", text: $actionMerchant)
                    .textFieldStyle(.roundedBorder)
            }

            // 4. Set Location (Transaction Location Editor: Search + Interactive Movable Pin Map)
            Toggle(isOn: $enableSetLocation) {
                VStack(alignment: .leading, spacing: 2) {
                    Label("Set Location", systemImage: "mappin.and.ellipse")
                    Text("Search place or drop & move pin on interactive map")
                        .font(.caption2)
                        .foregroundStyle(Theme.secondaryInk)
                }
            }
            if enableSetLocation {
                if !actionLocationName.isEmpty || actionLatitude != nil {
                    TransactionLocationCard(
                        placeName: actionLocationName.isEmpty ? "Pinned Map Location" : actionLocationName,
                        address: actionLocationAddress,
                        latitude: actionLatitude,
                        longitude: actionLongitude,
                        onSearchPlace: { showLocationPicker = true },
                        onRemove: {
                            actionLocationName = ""
                            actionLocationAddress = nil
                            actionLatitude = nil
                            actionLongitude = nil
                        }
                    )
                    .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                    .listRowBackground(Color.clear)
                } else {
                    Button {
                        showLocationPicker = true
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "mappin.and.ellipse")
                            Text("Select Location / Search on Map")
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

            // 6. Set Note (Always enabled, write inside even if empty originally)
            Toggle(isOn: $enableSetNote) {
                Label("Set Note", systemImage: "note.text")
            }
            if enableSetNote {
                TextField("Write Note", text: $actionNote, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...4)
            }

            // 7. Link Savings Goal
            if !goals.isEmpty {
                Toggle(isOn: $enableSetGoal) {
                    Label("Link Savings Goal", systemImage: "target")
                }
                if enableSetGoal {
                    Picker("Savings Goal", selection: $actionGoalID) {
                        Text("Select Goal").tag(UUID?.none)
                        ForEach(goals) { goal in
                            Text(goal.name).tag(UUID?.some(goal.id))
                        }
                    }
                }
            }
        } header: {
            Text("3. THEN — Actions")
        } footer: {
            Text("Configure what happens when this rule matches future transactions.")
        }
    }

    @ViewBuilder
    private var ruleInfoSection: some View {
        Section("Rule Info") {
            TextField("Rule Name (optional)", text: $ruleName)
            Toggle("Enable Rule for Future Transactions", isOn: $isEnabled)
                .onChange(of: isEnabled) { _, enabled in
                    if !enabled {
                        applyToExisting = false
                    }
                }
        }
    }

    private func loadInitialState() {
        if let existingRule {
            ruleName = existingRule.name
            isEnabled = existingRule.isEnabled
            applyToExisting = existingRule.isEnabled
            logic = existingRule.logic

            let resolvedTx: MoneyTransaction? = sourceTransaction
                ?? existingRule.sourceTransactionID.flatMap { sid in allTransactions.first(where: { $0.id == sid }) }

            var merged: [RuleCondition] = []
            if let tx = resolvedTx {
                merged = TransactionRuleStore.captureAvailableConditions(from: tx, accounts: accounts)
            }
            // Apply saved rule conditions (overriding captured values for fields already saved on the rule)
            for cond in existingRule.conditions {
                if let idx = merged.firstIndex(where: { $0.field == cond.field }) {
                    merged[idx] = cond
                } else {
                    merged.append(cond)
                }
            }
            // Ensure all standard condition options are always visible so the user can add/toggle any option while editing
            let refDate = resolvedTx?.date ?? .now
            let cal = Calendar.current
            let refMonth = cal.component(.month, from: refDate)
            let refDay = cal.component(.day, from: refDate)
            let refWeekday = cal.component(.weekday, from: refDate)
            let refType = resolvedTx.map { RuleTransactionTypeOption.from(txType: $0.effectiveTransactionType, isIncome: $0.isIncome) } ?? .transferOut

            let standardPlaceholders: [RuleCondition] = [
                RuleCondition(field: .originalSMS, value: "", displayValue: "Match SMS text", smsMatchMode: .contains),
                RuleCondition(field: .merchant, value: "", displayValue: "Enter merchant or recipient"),
                RuleCondition(field: .senderIBAN, value: "", displayValue: "Enter sender IBAN digits"),
                RuleCondition(field: .recipientIBAN, value: "", displayValue: "Enter recipient IBAN digits"),
                RuleCondition(field: .accountDigits, value: "", displayValue: "Enter card or account digits"),
                RuleCondition(field: .smsSender, value: "", displayValue: "Enter bank phone number"),
                RuleCondition(field: .accountID, value: "", displayValue: "Choose account"),
                RuleCondition(field: .amount, value: "", displayValue: "Enter exact amount"),
                RuleCondition(field: .direction, value: refType.rawValue, displayValue: refType.title),
                RuleCondition(field: .monthDay, value: RuleDateHelper.monthDayValue(month: refMonth, day: refDay), displayValue: RuleDateHelper.monthDayDisplay(month: refMonth, day: refDay)),
                RuleCondition(field: .dayOfWeek, value: "\(refWeekday)", displayValue: RuleDateHelper.weekdayDisplay(refWeekday))
            ]
            for placeholder in standardPlaceholders where !merged.contains(where: { $0.field == placeholder.field }) {
                merged.append(placeholder)
            }
            // Keep consistent display order (Original SMS first, then standard order; keep legacy .note only if saved on rule)
            let fieldOrder: [RuleConditionField] = [.originalSMS, .merchant, .senderIBAN, .recipientIBAN, .accountDigits, .smsSender, .accountID, .location, .amount, .direction, .monthDay, .dayOfWeek, .note]
            merged.sort { lhs, rhs in
                let i0 = fieldOrder.firstIndex(of: lhs.field) ?? 99
                let i1 = fieldOrder.firstIndex(of: rhs.field) ?? 99
                return i0 < i1
            }
            availableConditions = merged
            selectedFields = Set(existingRule.conditions.map(\.field))
            if let accCond = existingRule.conditions.first(where: { $0.field == .accountID }),
               let accUUID = UUID(uuidString: accCond.value) {
                manualAccountConditionID = accUUID
            }
            if let dirCond = existingRule.conditions.first(where: { $0.field == .direction }),
               let parsedType = RuleTransactionTypeOption.parse(dirCond.value) {
                selectedDirectionType = parsedType
            } else {
                selectedDirectionType = refType
            }
            if let mdCond = existingRule.conditions.first(where: { $0.field == .monthDay }),
               let parsedMD = RuleDateHelper.parseMonthDay(mdCond.value) {
                selectedMonth = parsedMD.month
                selectedDay = parsedMD.day
            } else {
                selectedMonth = refMonth
                selectedDay = refDay
            }
            if let dowCond = existingRule.conditions.first(where: { $0.field == .dayOfWeek }),
               let parsedWD = RuleDateHelper.parseWeekday(dowCond.value) {
                selectedWeekday = parsedWD
            } else {
                selectedWeekday = refWeekday
            }

            if let locCond = existingRule.conditions.first(where: { $0.field == .location }) {
                locationRadius = locCond.radiusMeters > 0 ? locCond.radiusMeters : 10.0
            }
            if let smsCond = existingRule.conditions.first(where: { $0.field == .originalSMS }) {
                originalSMSMatchMode = smsCond.smsMatchMode ?? .contains
                originalSMSText = smsCond.value
            } else if let capturedSMS = availableConditions.first(where: { $0.field == .originalSMS }) {
                originalSMSMatchMode = .contains
                originalSMSText = capturedSMS.value
            }

            let act = existingRule.actions
            if let cat = act.category {
                enableSetCategory = true
                selectedCategory = cat
            } else {
                enableSetCategory = false
            }
            fromAccountID = act.fromAccountID
            toAccountID = act.toAccountID

            if let ov = act.overrideAccountID {
                enableOverrideAccount = true
                overrideAccountID = ov
            }

            if let m = act.setMerchant, !m.isEmpty {
                enableSetMerchant = true
                actionMerchant = m
            }
            if let b = act.setBank, !b.isEmpty {
                enableSetBank = true
                actionBank = b
                selectedBankPicker = regionalBanksList.contains(b) ? b : "Custom"
            }
            if let loc = act.setLocationName, !loc.isEmpty {
                enableSetLocation = true
                actionLocationName = loc
                actionLocationAddress = act.setLocationAddress
                actionLatitude = act.setLatitude
                actionLongitude = act.setLongitude
            } else if act.setLatitude != nil {
                enableSetLocation = true
                actionLocationName = act.setLocationAddress ?? "Pinned Location"
                actionLocationAddress = act.setLocationAddress
                actionLatitude = act.setLatitude
                actionLongitude = act.setLongitude
            }
            if let g = act.setGoalID {
                enableSetGoal = true
                actionGoalID = g
            }
            if let n = act.setNote {
                enableSetNote = true
                actionNote = n
            }

            if let tx = sourceTransaction {
                populateFallbackActionValues(from: tx)
            }
        } else if let tx = sourceTransaction {
            availableConditions = TransactionRuleStore.captureAvailableConditions(from: tx, accounts: accounts)
            if let smsCond = availableConditions.first(where: { $0.field == .originalSMS }) {
                originalSMSMatchMode = .contains
                originalSMSText = smsCond.value
            }

            let cal = Calendar.current
            selectedDirectionType = RuleTransactionTypeOption.from(txType: tx.effectiveTransactionType, isIncome: tx.isIncome)
            selectedMonth = cal.component(.month, from: tx.date)
            selectedDay = cal.component(.day, from: tx.date)
            selectedWeekday = cal.component(.weekday, from: tx.date)

            // Pre-select the primary identifying condition(s) for convenience
            if availableConditions.contains(where: { $0.field == .recipientIBAN }) {
                selectedFields.insert(.recipientIBAN)
            } else if availableConditions.contains(where: { $0.field == .senderIBAN }) {
                selectedFields.insert(.senderIBAN)
            } else if availableConditions.contains(where: { $0.field == .merchant }) {
                selectedFields.insert(.merchant)
            } else if let first = availableConditions.first {
                selectedFields.insert(first.field)
            }

            enableSetCategory = true
            selectedCategory = tx.category
            fromAccountID = tx.accountID
            toAccountID = tx.toAccountID
            overrideAccountID = tx.accountID
            populateFallbackActionValues(from: tx)
        } else {
            // Creating a new rule from scratch in Settings -> Transaction Rules
            let cal = Calendar.current
            let m = cal.component(.month, from: .now)
            let d = cal.component(.day, from: .now)
            let wd = cal.component(.weekday, from: .now)
            selectedDirectionType = .transferOut
            selectedMonth = m
            selectedDay = d
            selectedWeekday = wd

            availableConditions = [
                RuleCondition(field: .originalSMS, value: "", displayValue: "Match SMS text", smsMatchMode: .contains),
                RuleCondition(field: .merchant, value: "", displayValue: "Enter merchant or recipient"),
                RuleCondition(field: .senderIBAN, value: "", displayValue: "Enter sender IBAN digits"),
                RuleCondition(field: .recipientIBAN, value: "", displayValue: "Enter recipient IBAN digits"),
                RuleCondition(field: .accountDigits, value: "", displayValue: "Enter card or account digits"),
                RuleCondition(field: .smsSender, value: "", displayValue: "Enter bank phone number"),
                RuleCondition(field: .accountID, value: "", displayValue: "Choose account"),
                RuleCondition(field: .amount, value: "", displayValue: "Enter exact amount"),
                RuleCondition(field: .direction, value: RuleTransactionTypeOption.transferOut.rawValue, displayValue: RuleTransactionTypeOption.transferOut.title),
                RuleCondition(field: .monthDay, value: RuleDateHelper.monthDayValue(month: m, day: d), displayValue: RuleDateHelper.monthDayDisplay(month: m, day: d)),
                RuleCondition(field: .dayOfWeek, value: "\(wd)", displayValue: RuleDateHelper.weekdayDisplay(wd))
            ]
            selectedFields = [.originalSMS]
            originalSMSMatchMode = .contains
            originalSMSText = ""
            enableSetCategory = true
            selectedCategory = .other
            isEnabled = true
        }
    }

    private func manualPlaceholder(for field: RuleConditionField) -> String {
        switch field {
        case .originalSMS:   return "Paste SMS text or keyword"
        case .merchant:      return "e.g. Talabat, Batelco, Lulu"
        case .senderIBAN:    return "Last digits, e.g. 0000"
        case .recipientIBAN: return "Last digits, e.g. 3876"
        case .accountDigits: return "Last digits, e.g. 9001"
        case .smsSender:     return "e.g. 17515151"
        case .amount:        return "e.g. 3.000"
        default:             return "Enter value"
        }
    }

    private func populateFallbackActionValues(from tx: MoneyTransaction) {
        if actionMerchant.isEmpty {
            actionMerchant = tx.merchant.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if actionBank.isEmpty, let bank = tx.smsBank?.trimmingCharacters(in: .whitespacesAndNewlines) {
            actionBank = bank
            selectedBankPicker = regionalBanksList.contains(bank) ? bank : "Custom"
        }
        if actionLocationName.isEmpty, let loc = tx.locationName?.trimmingCharacters(in: .whitespacesAndNewlines) {
            actionLocationName = loc
            actionLocationAddress = tx.locationAddress
            actionLatitude = tx.latitude
            actionLongitude = tx.longitude
        }
        if actionGoalID == nil {
            actionGoalID = tx.goalID
        }
        if actionNote.isEmpty {
            actionNote = tx.note.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private func buildRule() -> TransactionRule {
        var chosenConditions = selectedConditionsList

        // Synchronize Original SMS match mode and text
        for idx in chosenConditions.indices where chosenConditions[idx].field == .originalSMS {
            chosenConditions[idx].smsMatchMode = originalSMSMatchMode
            let trimmed = originalSMSText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                chosenConditions[idx].value = trimmed
            }
            if originalSMSMatchMode == .contains {
                chosenConditions[idx].displayValue = "Contains \"\(chosenConditions[idx].value)\""
            } else {
                chosenConditions[idx].displayValue = "Exact SMS (ignores date, time, ref & balance)"
            }
        }

        // Synchronize Transaction Type, Date (Day & Month), and Day of Week conditions
        for idx in chosenConditions.indices {
            switch chosenConditions[idx].field {
            case .direction:
                chosenConditions[idx].value = selectedDirectionType.rawValue
                chosenConditions[idx].displayValue = selectedDirectionType.title
            case .monthDay:
                chosenConditions[idx].value = RuleDateHelper.monthDayValue(month: selectedMonth, day: selectedDay)
                chosenConditions[idx].displayValue = RuleDateHelper.monthDayDisplay(month: selectedMonth, day: selectedDay)
            case .dayOfWeek:
                chosenConditions[idx].value = "\(selectedWeekday)"
                chosenConditions[idx].displayValue = RuleDateHelper.weekdayDisplay(selectedWeekday)
            default:
                break
            }
        }

        // Synchronize manual condition values (for creating from scratch OR newly added manual conditions when editing)
        let cur = UserDefaults.standard.string(forKey: Keys.currency) ?? "BHD"
        for idx in chosenConditions.indices where chosenConditions[idx].field != .originalSMS {
            let cond = chosenConditions[idx]
            guard needsManualInput(for: cond) else { continue }
            let field = cond.field
            if field == .accountID, let accID = manualAccountConditionID {
                chosenConditions[idx].value = accID.uuidString
                chosenConditions[idx].displayValue = accounts.first(where: { $0.id == accID })?.name ?? "Account"
            } else if let typed = manualConditionValues[field] {
                let raw = typed.trimmingCharacters(in: .whitespacesAndNewlines)
                if field == .amount, let parsed = Money.parse(raw), parsed > 0 {
                    chosenConditions[idx].value = String(format: "%.3f", parsed)
                    chosenConditions[idx].displayValue = Money.format(parsed, cur)
                } else if field == .senderIBAN || field == .recipientIBAN || field == .accountDigits {
                    let digits = raw.replacingOccurrences(of: "*", with: "")
                    chosenConditions[idx].value = digits
                    chosenConditions[idx].displayValue = digits.isEmpty ? "" : "**\(digits)"
                } else {
                    chosenConditions[idx].value = raw
                    chosenConditions[idx].displayValue = raw
                }
            }
        }

        // Synchronize custom radius and display for location condition
        for idx in chosenConditions.indices where chosenConditions[idx].field == .location {
            chosenConditions[idx].radiusMeters = locationRadius
            if chosenConditions[idx].latitude != nil || actionLatitude != nil {
                let place = chosenConditions[idx].value.isEmpty ? "GPS Location" : chosenConditions[idx].value
                chosenConditions[idx].displayValue = "\(place) (within \(Int(locationRadius))m)"
                if chosenConditions[idx].latitude == nil {
                    chosenConditions[idx].latitude = actionLatitude
                    chosenConditions[idx].longitude = actionLongitude
                }
            }
        }

        let effectiveCat: SpendCategory? = enableSetCategory ? selectedCategory : nil

        let effectiveLocationName: String? = {
            guard enableSetLocation else { return nil }
            let trimmed = actionLocationName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
            if let addr = actionLocationAddress, !addr.isEmpty { return addr }
            if actionLatitude != nil { return "Pinned Location" }
            return nil
        }()

        var actions = RuleActions(
            setCategoryRaw: effectiveCat?.rawValue,
            overrideAccountID: enableOverrideAccount ? overrideAccountID : nil,
            fromAccountID: (effectiveCat?.isTransferCategory == true) ? fromAccountID : nil,
            toAccountID: (effectiveCat == .internalTransfer || effectiveCat == .visaTransfer) ? toAccountID : nil,
            setMerchant: enableSetMerchant && !actionMerchant.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? actionMerchant.trimmingCharacters(in: .whitespacesAndNewlines) : nil,
            setBank: nil,
            setLocationName: effectiveLocationName,
            setLocationAddress: enableSetLocation ? actionLocationAddress : nil,
            setLatitude: enableSetLocation ? actionLatitude : nil,
            setLongitude: enableSetLocation ? actionLongitude : nil,
            setNote: enableSetNote && !actionNote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? actionNote.trimmingCharacters(in: .whitespacesAndNewlines) : nil,
            setGoalID: enableSetGoal ? actionGoalID : nil
        )
        if let cat = effectiveCat, cat.isIncomeCategory {
            actions.setIsIncome = true
        }

        let cleanName = ruleName.trimmingCharacters(in: .whitespacesAndNewlines)
        let generatedName: String = {
            if !cleanName.isEmpty { return cleanName }
            let condSummary = chosenConditions.map(\.displayValue).joined(separator: logic == .and ? " + " : " | ")
            if let cat = effectiveCat {
                return "\(condSummary) → \(cat.rawValue)"
            }
            return condSummary
        }()

        return TransactionRule(
            id: existingRule?.id ?? UUID(),
            name: generatedName,
            isEnabled: isEnabled,
            logic: logic,
            conditions: chosenConditions,
            actions: actions,
            sourceTransactionID: existingRule?.sourceTransactionID ?? sourceTransaction?.id,
            createdAt: existingRule?.createdAt ?? .now
        )
    }

    private func attemptSave() {
        let candidate = buildRule()
        if let conflict = store.conflictingRule(for: candidate, excludingRuleID: existingRule?.id) {
            conflictingRuleName = conflict.name
            showConflictAlert = true
            return
        }
        commitSave()
    }

    private func commitSave() {
        let candidate = buildRule()
        let savedRule: TransactionRule
        if existingRule != nil {
            store.updateRule(candidate)
            savedRule = candidate
        } else {
            savedRule = store.addRule(candidate)
        }

        if applyToExisting && savedRule.isEnabled {
            let affected = computeAffectedTransactions()
            if !affected.isEmpty {
                for item in affected {
                    Ledger.edit(item.tx, context: modelContext) { target in
                        store.applyBestMatchingRuleIfAny(to: target, context: modelContext)
                    }
                }
            }
        }

        onSaved?(savedRule)
        dismiss()
    }

    // MARK: - Tab Header, Preview & Footer

    @ViewBuilder
    private func tabHeader(previewCount: Int) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(RuleEditorTab.allCases, id: \.self) { tab in
                    let isSelected = selectedTab == tab
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            selectedTab = tab
                        }
                    } label: {
                        VStack(spacing: 10) {
                            HStack(spacing: 6) {
                                Text(tab.rawValue)
                                    .font(.caption.weight(.bold))
                                    .tracking(0.6)
                                    .foregroundStyle(isSelected ? Theme.cobalt : Theme.secondaryInk)

                                if tab == .preview {
                                    Text("\(previewCount)")
                                        .font(.caption2.weight(.bold))
                                        .foregroundStyle(isSelected ? Theme.cobalt : Theme.secondaryInk)
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 2)
                                        .background(
                                            Capsule()
                                                .fill(isSelected ? Theme.cobalt.opacity(0.16) : Theme.track)
                                        )
                                }
                            }
                            .padding(.top, 12)

                            Rectangle()
                                .fill(isSelected ? Theme.cobalt : Color.clear)
                                .frame(height: 2.5)
                        }
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            Divider()
        }
        .background(Theme.card)
    }

    @ViewBuilder
    private func previewTabView(affected: [(tx: MoneyTransaction, changes: [(label: String, before: String, after: String)])]) -> some View {
        if affected.isEmpty {
            VStack(spacing: 12) {
                Spacer()
                Image(systemName: "chevron.right.2")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(Theme.secondaryInk)
                Text("No changes")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(Theme.ink)
                Text("This rule will not change any\nexisting transactions.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondaryInk)
                    .multilineTextAlignment(.center)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.canvas.ignoresSafeArea())
        } else {
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(affected, id: \.tx.id) { item in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.tx.merchant)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(Theme.ink)
                                    Text(item.tx.date.formatted(date: .abbreviated, time: .omitted))
                                        .font(.caption)
                                        .foregroundStyle(Theme.secondaryInk)
                                }
                                Spacer()
                                Text("\(item.tx.isIncome ? "+" : "−")\(Money.format(item.tx.amount, currency))")
                                    .font(.subheadline.weight(.semibold).monospacedDigit())
                                    .foregroundStyle(item.tx.isIncome ? Theme.positive : Theme.ink)
                            }

                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(Array(item.changes.enumerated()), id: \.offset) { _, change in
                                    HStack(spacing: 6) {
                                        Text(change.label)
                                            .font(.caption2.weight(.semibold))
                                            .foregroundStyle(Theme.secondaryInk)
                                        Text(change.before)
                                            .font(.caption)
                                            .foregroundStyle(Theme.secondaryInk)
                                            .strikethrough()
                                            .lineLimit(1)
                                        Image(systemName: "arrow.right")
                                            .font(.caption2.weight(.semibold))
                                            .foregroundStyle(Theme.cobalt)
                                        Text(change.after)
                                            .font(.caption.weight(.medium))
                                            .foregroundStyle(Theme.ink)
                                            .lineLimit(1)
                                    }
                                }
                            }
                        }
                        .card(padding: 14)
                    }
                }
                .padding(16)
            }
            .background(Theme.canvas.ignoresSafeArea())
        }
    }

    @ViewBuilder
    private func bottomActionFooter(affectedCount: Int) -> some View {
        VStack(spacing: 14) {
            Divider()

            Button {
                guard isEnabled else { return }
                applyToExisting.toggle()
            } label: {
                HStack {
                    Text("Apply to \(affectedCount) existing transaction\(affectedCount == 1 ? "" : "s")")
                        .font(.subheadline)
                        .foregroundStyle(isEnabled ? Theme.ink : Theme.secondaryInk)
                    Spacer()
                    let checked = applyToExisting && isEnabled
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(checked ? Theme.cobalt : Color.clear)
                        .frame(width: 22, height: 22)
                        .overlay {
                            if checked {
                                Image(systemName: "checkmark")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(.white)
                            } else {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .stroke(Theme.secondaryInk.opacity(0.45), lineWidth: 1.5)
                            }
                        }
                }
                .contentShape(Rectangle())
                .opacity(isEnabled ? 1 : 0.45)
            }
            .buttonStyle(.plain)
            .disabled(!isEnabled)

            Button {
                attemptSave()
            } label: {
                Text("Save rule")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(Capsule().fill(Theme.cobalt))
                    .opacity(canSave ? 1 : 0.45)
            }
            .buttonStyle(PressableStyle())
            .disabled(!canSave)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .background(Theme.card)
    }

    private func previewChanges(for tx: MoneyTransaction, rule: TransactionRule) -> [(label: String, before: String, after: String)] {
        let actions = rule.actions
        var changes: [(label: String, before: String, after: String)] = []

        func accountName(for id: UUID?) -> String {
            guard let id else { return "None" }
            return accounts.first(where: { $0.id == id })?.name ?? "Account"
        }

        func goalName(for id: UUID?) -> String {
            guard let id else { return "None" }
            return goals.first(where: { $0.id == id })?.name ?? "Goal"
        }

        if let transferKind = actions.effectiveTransferKind {
            let targetCat: SpendCategory = (transferKind == .internalTransfer) ? .internalTransfer : .transfers
            if tx.category != targetCat {
                changes.append(("Category", tx.category.rawValue, targetCat.rawValue))
            }
            if let fromID = actions.fromAccountID ?? actions.overrideAccountID, tx.accountID != fromID {
                changes.append(("Account", accountName(for: tx.accountID), accountName(for: fromID)))
            }
            if transferKind == .internalTransfer,
               let toID = actions.toAccountID,
               toID != (actions.fromAccountID ?? actions.overrideAccountID ?? tx.accountID),
               tx.toAccountID != toID {
                changes.append(("To Account", accountName(for: tx.toAccountID), accountName(for: toID)))
            }
        } else {
            if let overrideID = actions.overrideAccountID ?? actions.fromAccountID, tx.accountID != overrideID {
                changes.append(("Account", accountName(for: tx.accountID), accountName(for: overrideID)))
            }
            if let cat = actions.category, tx.category != cat {
                changes.append(("Category", tx.category.rawValue, cat.rawValue))
            }
        }

        if let merchant = actions.setMerchant?.trimmingCharacters(in: .whitespacesAndNewlines),
           !merchant.isEmpty,
           tx.merchant != merchant {
            changes.append(("Merchant", tx.merchant, merchant))
        }
        if let bank = actions.setBank?.trimmingCharacters(in: .whitespacesAndNewlines),
           !bank.isEmpty,
           tx.smsBank != bank {
            changes.append(("Bank", tx.smsBank ?? "None", bank))
        }
        if let locName = actions.setLocationName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !locName.isEmpty,
           tx.locationName != locName {
            changes.append(("Location", tx.locationName ?? "None", locName))
        }
        if let note = actions.setNote?.trimmingCharacters(in: .whitespacesAndNewlines),
           !note.isEmpty,
           tx.note != note {
            changes.append(("Note", tx.note.isEmpty ? "None" : tx.note, note))
        }
        if let goalID = actions.setGoalID, tx.goalID != goalID {
            changes.append(("Goal", goalName(for: tx.goalID), goalName(for: goalID)))
        }

        return changes
    }
}

// MARK: - Transaction Details Rules Section

struct TransactionDetailRulesSection: View {
    let tx: MoneyTransaction
    let accounts: [Account]
    @Binding var showCreateSheet: Bool

    @State private var editingRule: TransactionRule?
    private var store: TransactionRuleStore { TransactionRuleStore.shared }

    var body: some View {
        let context = RuleEvaluationContext(from: tx)
        // Show all matching rules ordered by specificity (most specific first)
        let resolution = store.evaluateRules(for: context)
        let winningID = resolution.winningRule?.id
        let conflictIDs = Set(resolution.conflictingRules.map(\.id))
        let matchedRules: [TransactionRule] = store.rules
            .filter { store.matches(rule: $0, context: context, ignoreEnabledState: true) }
            .sorted {
                let s0 = store.evaluateSpecificity(rule: $0, context: context, ignoreEnabledState: true)?.score ?? TransactionRuleStore.staticSpecificityScore(for: $0)
                let s1 = store.evaluateSpecificity(rule: $1, context: context, ignoreEnabledState: true)?.score ?? TransactionRuleStore.staticSpecificityScore(for: $1)
                return s0 > s1
            }

        VStack(alignment: .leading, spacing: 12) {
            if matchedRules.isEmpty {
                Text("No matching rules for this transaction.")
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryInk)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.track.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else {
                VStack(spacing: 8) {
                    ForEach(matchedRules) { rule in
                        let statusBadge: String? = {
                            if !rule.isEnabled { return nil }
                            if conflictIDs.contains(rule.id) { return "Conflict" }
                            if winningID == rule.id { return "Best Match" }
                            return nil
                        }()
                        Button {
                            editingRule = rule
                        } label: {
                            TransactionRuleRowCard(
                                rule: rule,
                                accounts: accounts,
                                statusBadge: statusBadge,
                                isHighlighted: winningID == rule.id || conflictIDs.contains(rule.id),
                                showControls: false,
                                onToggle: {},
                                onEdit: {},
                                onDelete: {}
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if !store.rules.isEmpty {
                NavigationLink {
                    TransactionRulesListView()
                } label: {
                    Text("Manage All Transaction Rules (\(store.rules.count))")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.brand)
                        .padding(.top, 4)
                }
            }
        }
        .card()
        .sheet(isPresented: $showCreateSheet) {
            TransactionRuleBuilderSheet(sourceTransaction: tx, existingRule: nil)
        }
        .sheet(item: $editingRule) { rule in
            TransactionRuleBuilderSheet(sourceTransaction: tx, existingRule: rule)
        }
    }
}

// MARK: - Compact Rule Card (Specificity-Based)

struct TransactionRuleRowCard: View {
    let rule: TransactionRule
    let accounts: [Account]
    var statusBadge: String? = nil
    var isHighlighted: Bool = false
    var showControls: Bool = true
    let onToggle: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    private var specificityScore: Int {
        TransactionRuleStore.staticSpecificityScore(for: rule)
    }

    private func accountName(_ id: UUID?) -> String? {
        guard let id else { return nil }
        return accounts.first(where: { $0.id == id })?.name
    }

    private var actionSummaryText: String {
        var parts: [String] = []
        if let cat = rule.actions.category {
            parts.append("Category: \(cat.title)")
        }
        if let overrideID = rule.actions.overrideAccountID, let acc = accountName(overrideID) {
            parts.append("Route to \(acc)")
        }
        if let fromName = accountName(rule.actions.fromAccountID),
           let toName = accountName(rule.actions.toAccountID) {
            parts.append("\(fromName) → \(toName)")
        } else if let fromName = accountName(rule.actions.fromAccountID), rule.actions.overrideAccountID == nil {
            parts.append(fromName)
        }
        if let merchant = rule.actions.setMerchant {
            parts.append("Merchant: \"\(merchant)\"")
        }
        if let loc = rule.actions.setLocationName {
            parts.append("Location: \(loc)")
        }
        if let goalID = rule.actions.setGoalID {
            parts.append("Goal (\(goalID.uuidString.prefix(4)))")
        }
        return parts.isEmpty ? "Apply rule actions" : parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Row 1: Rule Name + Specificity / Status Badges + Toggle
            HStack(spacing: 8) {
                Text(rule.name.isEmpty ? "Rule" : rule.name)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)

                Spacer(minLength: 8)

                if let badge = statusBadge {
                    let isConflict = badge == "Conflict"
                    Text(badge)
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background((isConflict ? Theme.warning : Theme.positive).opacity(0.16), in: Capsule())
                        .foregroundStyle(isConflict ? Theme.warning : Theme.positive)
                } else if !rule.isEnabled {
                    Text("Off")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Theme.track, in: Capsule())
                        .foregroundStyle(Theme.secondaryInk)
                } else {
                    Text("Score \(specificityScore)")
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Theme.cobaltSoft, in: Capsule())
                        .foregroundStyle(Theme.cobalt)
                }

                if showControls {
                    Toggle("", isOn: Binding(
                        get: { rule.isEnabled },
                        set: { _ in onToggle() }
                    ))
                    .labelsHidden()
                    .tint(Theme.positive)
                }
            }

            // Row 2: IF (AND/OR) + condition pills
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    Text("IF (\(rule.logic.rawValue))")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(Theme.track, in: Capsule())
                        .foregroundStyle(Theme.secondaryInk)

                    ForEach(Array(rule.conditions.enumerated()), id: \.offset) { _, cond in
                        Text("\(cond.field.label): \(cond.displayValue)")
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Theme.track.opacity(0.7), in: Capsule())
                            .foregroundStyle(Theme.ink)
                            .lineLimit(1)
                    }
                }
            }

            // Row 3: THEN + action summary + Edit/Delete buttons
            HStack(spacing: 8) {
                Text("THEN")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(Theme.cobaltSoft, in: Capsule())
                    .foregroundStyle(Theme.cobalt)

                Text(actionSummaryText)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)

                Spacer(minLength: 8)

                if showControls {
                    Button(action: onEdit) {
                        Image(systemName: "pencil")
                            .font(.caption.weight(.semibold))
                            .frame(width: 28, height: 28)
                            .background(Theme.cobaltSoft, in: Circle())
                            .foregroundStyle(Theme.cobalt)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Edit rule")

                    Button(role: .destructive, action: onDelete) {
                        Image(systemName: "trash")
                            .font(.caption.weight(.semibold))
                            .frame(width: 28, height: 28)
                            .background(Theme.expense.opacity(0.12), in: Circle())
                            .foregroundStyle(Theme.expense)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Delete rule")
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Theme.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Theme.track.opacity(0.6), lineWidth: 1)
        )
    }
}

// MARK: - Full Transaction Rules Management View (Profile Tab & Transactions Toolbar)

struct TransactionRulesListView: View {
    @Query(sort: \Account.createdAt) private var accounts: [Account]
    @State private var editingRule: TransactionRule?
    @State private var showCreateRule = false
    @State private var confirmDeleteAll = false

    private var store: TransactionRuleStore { TransactionRuleStore.shared }

    var body: some View {
        List {
            if store.rules.isEmpty {
                Section {
                    VStack(spacing: 14) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 34))
                            .foregroundStyle(Theme.brand)
                        Text("No Transaction Rules Yet")
                            .font(.headline)
                        Text("Create a rule here or from any transaction to automatically classify similar future transactions.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        Button {
                            showCreateRule = true
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "plus.circle.fill")
                                Text("Create Rule")
                                    .fontWeight(.semibold)
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 10)
                            .background(Theme.brand, in: Capsule())
                        }
                        .buttonStyle(PressableStyle())
                        .padding(.top, 4)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
                }
            } else {
                Section {
                    let sortedRules = store.rules.sorted {
                        TransactionRuleStore.staticSpecificityScore(for: $0) > TransactionRuleStore.staticSpecificityScore(for: $1)
                    }
                    ForEach(sortedRules) { rule in
                        Button {
                            editingRule = rule
                        } label: {
                            TransactionRuleRowCard(
                                rule: rule,
                                accounts: accounts,
                                isHighlighted: false,
                                showControls: false,
                                onToggle: {},
                                onEdit: {},
                                onDelete: {}
                            )
                        }
                        .buttonStyle(.plain)
                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                store.deleteRule(id: rule.id)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text("Rules (Most Specific First)")
                        Spacer()
                        Text("Specificity-Based")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("All enabled rules are evaluated and only the most specific matching rule executes, regardless of creation order. If multiple rules tie with equal specificity and different outcomes, the conflict is flagged for your review.")
                }
                .listSectionSeparator(.hidden)

                Section {
                    Button(role: .destructive) {
                        confirmDeleteAll = true
                    } label: {
                        HStack {
                            Spacer()
                            Label("Delete All Rules", systemImage: "trash.fill")
                                .fontWeight(.semibold)
                            Spacer()
                        }
                    }
                    .listRowBackground(Theme.surface)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .canvasBackground()
        .navigationTitle("Transaction Rules")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showCreateRule = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Create rule")
            }
        }
        .sheet(isPresented: $showCreateRule) {
            TransactionRuleBuilderSheet(sourceTransaction: nil, existingRule: nil)
        }
        .sheet(item: $editingRule) { rule in
            TransactionRuleBuilderSheet(sourceTransaction: nil, existingRule: rule)
        }
        .confirmationDialog("Delete all transaction rules?", isPresented: $confirmDeleteAll, titleVisibility: .visible) {
            Button("Delete All Rules", role: .destructive) {
                store.deleteAll()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This removes all saved transaction rules. Existing transactions will not be affected.")
        }
    }
}
