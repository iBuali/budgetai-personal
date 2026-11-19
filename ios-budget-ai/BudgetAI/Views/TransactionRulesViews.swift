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
    @State private var locationRadius: Double = 15.0

    // THEN – Actions
    @State private var enableSetCategory: Bool = false
    @State private var selectedCategory: SpendCategory = .other
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

    private var selectedConditionsList: [RuleCondition] {
        availableConditions.filter { selectedFields.contains($0.field) }
    }

    private var canSave: Bool {
        !selectedConditionsList.isEmpty
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

            // If this is the Location condition and it is selected with GPS coordinates, offer radius customization
            if cond.field == .location && isSelected && (cond.latitude != nil || actionLatitude != nil) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label("Matching Radius", systemImage: "circle.circle")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.brand)
                        Spacer()
                        Text("\(Int(locationRadius)) meters")
                            .font(.caption.weight(.bold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(Theme.brand.opacity(0.12), in: Capsule())
                            .foregroundStyle(Theme.brand)
                    }

                    HStack(spacing: 6) {
                        ForEach([10.0, 15.0, 25.0, 50.0, 100.0], id: \.self) { r in
                            Button {
                                locationRadius = r
                            } label: {
                                Text("\(Int(r))m")
                                    .font(.caption2.weight(locationRadius == r ? .bold : .regular))
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 4)
                                    .background(locationRadius == r ? Theme.brand : Theme.track, in: Capsule())
                                    .foregroundStyle(locationRadius == r ? .white : Theme.ink)
                            }
                            .buttonStyle(.plain)
                        }

                        Stepper("", value: $locationRadius, in: 5...500, step: 5)
                            .labelsHidden()
                    }

                    Text("Matches any transaction within \(Int(locationRadius)) meters of this GPS coordinate, regardless of place name.")
                        .font(.caption2)
                        .foregroundStyle(Theme.secondaryInk)
                }
                .padding(.leading, 36)
                .padding(.top, 4)
            }
        }
    }

    private func displayValue(for cond: RuleCondition) -> String {
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
                Picker("Category", selection: $selectedCategory) {
                    ForEach(SpendCategory.allCases) { cat in
                        Label(cat.title, systemImage: cat.symbol).tag(cat)
                    }
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

            // 4. Set SMS Bank (Choose from Bahrain/regional banks or custom text)
            Toggle(isOn: $enableSetBank) {
                VStack(alignment: .leading, spacing: 2) {
                    Label("Set SMS Bank", systemImage: "building.columns.fill")
                    Text("Designate SMS sender bank")
                        .font(.caption2)
                        .foregroundStyle(Theme.secondaryInk)
                }
            }
            if enableSetBank {
                Picker("Bank List", selection: $selectedBankPicker) {
                    ForEach(regionalBanksList, id: \.self) { bank in
                        Text(bank).tag(bank)
                    }
                    Text("Custom / Other").tag("Custom")
                }
                .onChange(of: selectedBankPicker) { _, newChoice in
                    if newChoice != "Custom" {
                        actionBank = newChoice
                    }
                }
                TextField("Bank Name", text: $actionBank)
                    .textFieldStyle(.roundedBorder)
            }

            // 5. Set Location (Transaction Location Editor: Search + Interactive Movable Pin Map)
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
        }
    }

    private func loadInitialState() {
        if let existingRule {
            ruleName = existingRule.name
            isEnabled = existingRule.isEnabled
            logic = existingRule.logic

            if let tx = sourceTransaction {
                var captured = TransactionRuleStore.captureAvailableConditions(from: tx, accounts: accounts)
                for cond in existingRule.conditions where !captured.contains(where: { $0.field == cond.field }) {
                    captured.append(cond)
                }
                availableConditions = captured
            } else {
                availableConditions = existingRule.conditions
            }
            selectedFields = Set(existingRule.conditions.map(\.field))

            if let locCond = existingRule.conditions.first(where: { $0.field == .location }) {
                locationRadius = locCond.radiusMeters > 0 ? locCond.radiusMeters : 15.0
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

            // Pre-select the primary identifying condition(s) for convenience
            if availableConditions.contains(where: { $0.field == .recipientIBAN }) {
                selectedFields.insert(.recipientIBAN)
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
            fromAccountID: (effectiveCat == .internalTransfer || effectiveCat == .transfers) ? fromAccountID : nil,
            toAccountID: (effectiveCat == .internalTransfer) ? toAccountID : nil,
            setMerchant: enableSetMerchant && !actionMerchant.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? actionMerchant.trimmingCharacters(in: .whitespacesAndNewlines) : nil,
            setBank: enableSetBank && !actionBank.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? actionBank.trimmingCharacters(in: .whitespacesAndNewlines) : nil,
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

        if applyToExisting {
            let affected = computeAffectedTransactions()
            if !affected.isEmpty {
                let priority = store.priorityNumber(for: savedRule.id) ?? 1
                for item in affected {
                    store.apply(rule: savedRule, to: item.tx, priorityNumber: priority)
                }
                try? modelContext.save()
                Ledger.notifyDataChanged()
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
                applyToExisting.toggle()
            } label: {
                HStack {
                    Text("Apply to \(affectedCount) existing transaction\(affectedCount == 1 ? "" : "s")")
                        .font(.subheadline)
                        .foregroundStyle(Theme.ink)
                    Spacer()
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(applyToExisting ? Theme.cobalt : Color.clear)
                        .frame(width: 22, height: 22)
                        .overlay {
                            if applyToExisting {
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
            }
            .buttonStyle(.plain)

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
        // Only show rules that match this transaction
        let matchedRulesWithIndex: [(originalIndex: Int, rule: TransactionRule)] = store.rules.enumerated().compactMap { index, rule in
            if store.matches(rule: rule, context: context, ignoreEnabledState: true) {
                return (originalIndex: index, rule: rule)
            }
            return nil
        }

        VStack(alignment: .leading, spacing: 12) {
            if matchedRulesWithIndex.isEmpty {
                Text("No matching rules for this transaction.")
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryInk)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.track.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else {
                VStack(spacing: 8) {
                    ForEach(matchedRulesWithIndex, id: \.rule.id) { item in
                        Button {
                            editingRule = item.rule
                        } label: {
                            TransactionRuleRowCard(
                                priorityNumber: item.originalIndex + 1,
                                rule: item.rule,
                                accounts: accounts,
                                isHighlighted: false,
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

// MARK: - Compact Rule Card with Priority & Controls

struct TransactionRuleRowCard: View {
    let priorityNumber: Int
    let rule: TransactionRule
    let accounts: [Account]
    var isHighlighted: Bool = false
    var showControls: Bool = true
    let onToggle: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

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
            // Row 1: #Priority + Rule Name + Toggle
            HStack(spacing: 8) {
                Text("#\(priorityNumber)")
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Theme.cobaltSoft, in: Capsule())
                    .foregroundStyle(Theme.cobalt)

                Text(rule.name.isEmpty ? "Rule \(priorityNumber)" : rule.name)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)

                Spacer(minLength: 8)

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
    @State private var confirmDeleteAll = false

    private var store: TransactionRuleStore { TransactionRuleStore.shared }

    var body: some View {
        List {
            if store.rules.isEmpty {
                Section {
                    VStack(spacing: 12) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 34))
                            .foregroundStyle(Theme.brand)
                        Text("No Transaction Rules Yet")
                            .font(.headline)
                        Text("Open any transaction in the Transactions tab and tap \"Create Rule\" to automatically capture its fields and classify similar future transactions.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
                }
            } else {
                Section {
                    ForEach(Array(store.rules.enumerated()), id: \.element.id) { index, rule in
                        Button {
                            editingRule = rule
                        } label: {
                            TransactionRuleRowCard(
                                priorityNumber: index + 1,
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
                    }
                    .onMove { source, destination in
                        store.moveRules(from: source, to: destination)
                    }
                    .onDelete { offsets in
                        store.deleteRules(at: offsets)
                    }
                } header: {
                    HStack {
                        Text("Rules Priority Order")
                        Spacer()
                        Text("Drag to Reorder")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("Rules have the highest priority in the app and apply only to future matching transactions. Existing transactions are never modified when creating or editing rules.")
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
            if !store.rules.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    EditButton()
                }
            }
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
