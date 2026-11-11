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

struct TransactionRuleBuilderSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Account.createdAt) private var accounts: [Account]
    @Query(sort: \SavingsGoal.createdAt) private var goals: [SavingsGoal]

    let sourceTransaction: MoneyTransaction?
    let existingRule: TransactionRule?
    var onSaved: ((TransactionRule) -> Void)? = nil

    @State private var ruleName: String = ""
    @State private var isEnabled: Bool = true
    @State private var logic: RuleConditionLogic = .and
    @State private var availableConditions: [RuleCondition] = []
    @State private var selectedFields: Set<RuleConditionField> = []

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

    @State private var enableSetNote: Bool = false
    @State private var actionNote: String = ""

    @State private var enableSetGoal: Bool = false
    @State private var actionGoalID: UUID?

    @State private var showConflictAlert: Bool = false
    @State private var conflictingRuleName: String = ""

    private var store: TransactionRuleStore { TransactionRuleStore.shared }

    private var selectedConditionsList: [RuleCondition] {
        availableConditions.filter { selectedFields.contains($0.field) }
    }

    private var canSave: Bool {
        !selectedConditionsList.isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                conditionsSection
                logicSection
                thenActionsSection
                ruleInfoSection
            }
            .navigationTitle(existingRule == nil ? "Create Rule" : "Edit Rule")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save Rule") {
                        attemptSave()
                    }
                    .fontWeight(.semibold)
                    .disabled(!canSave)
                }
            }
            .onAppear(perform: loadInitialState)
            .alert("Duplicate Rule Conditions", isPresented: $showConflictAlert) {
                Button("Update Existing Rule") {
                    commitSave()
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("A rule (\"\(conflictingRuleName)\") already uses these exact conditions. Would you like to update that rule with these actions instead?")
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
                    Text(cond.displayValue)
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryInk)
                        .lineLimit(1)
                }

                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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

            // 5. Set Location (Fully editable place / location name)
            Toggle(isOn: $enableSetLocation) {
                Label("Set Location", systemImage: "mappin.and.ellipse")
            }
            if enableSetLocation {
                TextField("Location / Place Name", text: $actionLocationName)
                    .textFieldStyle(.roundedBorder)
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
            if existingRule == nil {
                Toggle("Enable Rule for Future Transactions", isOn: $isEnabled)
            }
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
        let chosenConditions = selectedConditionsList
        let effectiveCat: SpendCategory? = enableSetCategory ? selectedCategory : nil

        var actions = RuleActions(
            setCategoryRaw: effectiveCat?.rawValue,
            overrideAccountID: enableOverrideAccount ? overrideAccountID : nil,
            fromAccountID: (effectiveCat == .internalTransfer || effectiveCat == .transfers) ? fromAccountID : nil,
            toAccountID: (effectiveCat == .internalTransfer) ? toAccountID : nil,
            setMerchant: enableSetMerchant && !actionMerchant.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? actionMerchant.trimmingCharacters(in: .whitespacesAndNewlines) : nil,
            setBank: enableSetBank && !actionBank.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? actionBank.trimmingCharacters(in: .whitespacesAndNewlines) : nil,
            setLocationName: enableSetLocation && !actionLocationName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? actionLocationName.trimmingCharacters(in: .whitespacesAndNewlines) : nil,
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
        if existingRule != nil {
            store.updateRule(candidate)
            onSaved?(candidate)
        } else {
            let saved = store.addRule(candidate)
            onSaved?(saved)
        }
        dismiss()
    }
}

// MARK: - Transaction Details Rules Section

struct TransactionDetailRulesSection: View {
    let tx: MoneyTransaction
    let accounts: [Account]

    @State private var showCreateSheet = false
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
            HStack {
                Label("Transaction Rules", systemImage: "slider.horizontal.3")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.ink)
                Spacer()
                Button {
                    showCreateSheet = true
                } label: {
                    Label("Create Rule", systemImage: "plus.circle.fill")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Theme.brand.opacity(0.14), in: Capsule())
                        .foregroundStyle(Theme.brand)
                }
                .buttonStyle(.plain)
            }

            if matchedRulesWithIndex.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.seal")
                        .foregroundStyle(Theme.brand)
                    Text("No matching rules for this transaction. Tap \"Create Rule\" to create one.")
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryInk)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.track.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else {
                VStack(spacing: 8) {
                    ForEach(matchedRulesWithIndex, id: \.rule.id) { item in
                        TransactionRuleRowCard(
                            priorityNumber: item.originalIndex + 1,
                            rule: item.rule,
                            accounts: accounts,
                            isHighlighted: true,
                            canMoveUp: item.originalIndex > 0,
                            canMoveDown: item.originalIndex < store.rules.count - 1,
                            onMoveUp: { store.moveRuleUp(id: item.rule.id) },
                            onMoveDown: { store.moveRuleDown(id: item.rule.id) },
                            onToggle: { store.toggleRule(id: item.rule.id) },
                            onEdit: { editingRule = item.rule },
                            onDelete: { store.deleteRule(id: item.rule.id) }
                        )
                    }
                }
            }

            if !store.rules.isEmpty {
                NavigationLink {
                    TransactionRulesListView()
                } label: {
                    HStack {
                        Text("Manage All Transaction Rules (\(store.rules.count))")
                            .font(.caption.weight(.semibold))
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                    }
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
    let canMoveUp: Bool
    let canMoveDown: Bool
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onToggle: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    private func accountName(_ id: UUID?) -> String? {
        guard let id else { return nil }
        return accounts.first(where: { $0.id == id })?.name
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Rule \(priorityNumber)")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(rule.isEnabled ? Theme.brand : Color.secondary, in: Capsule())
                    .foregroundStyle(.white)

                if isHighlighted {
                    HStack(spacing: 5) {
                        ZStack {
                            Circle()
                                .fill(Theme.income)
                                .frame(width: 13, height: 13)
                            Image(systemName: "checkmark")
                                .font(.system(size: 7, weight: .black))
                                .foregroundStyle(.white)
                        }
                        Text("Matches Transaction")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(Theme.income)
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Theme.income.opacity(0.12), in: Capsule())
                    .overlay(Capsule().stroke(Theme.income.opacity(0.35), lineWidth: 1))
                }

                Spacer()

                // Reorder priority buttons (drag & drop is supported in list, arrow controls here)
                HStack(spacing: 4) {
                    Button(action: onMoveUp) {
                        Image(systemName: "arrow.up")
                            .font(.caption2.weight(.bold))
                            .frame(width: 24, height: 24)
                            .background(Theme.track, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!canMoveUp)
                    .opacity(canMoveUp ? 1 : 0.35)

                    Button(action: onMoveDown) {
                        Image(systemName: "arrow.down")
                            .font(.caption2.weight(.bold))
                            .frame(width: 24, height: 24)
                            .background(Theme.track, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!canMoveDown)
                    .opacity(canMoveDown ? 1 : 0.35)
                }

                Toggle("", isOn: Binding(
                    get: { rule.isEnabled },
                    set: { _ in onToggle() }
                ))
                .labelsHidden()
                .scaleEffect(0.8)
            }

            // IF Conditions summary
            let joiner = " \(rule.logic.rawValue) "
            let condText = rule.conditions.map { "\($0.field.label): \($0.displayValue)" }.joined(separator: joiner)
            Text("IF \(condText)")
                .font(.caption)
                .foregroundStyle(Theme.ink)
                .lineLimit(2)

            // THEN Actions summary
            HStack(spacing: 8) {
                Text("THEN")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Theme.secondaryInk)

                if let cat = rule.actions.category {
                    Label(cat.rawValue, systemImage: cat.symbol)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(cat.color)
                }

                if let overrideID = rule.actions.overrideAccountID, let acc = accountName(overrideID) {
                    Text("• Route to \(acc)")
                        .font(.caption2)
                        .foregroundStyle(Theme.secondaryInk)
                        .lineLimit(1)
                }

                if let fromName = accountName(rule.actions.fromAccountID),
                   let toName = accountName(rule.actions.toAccountID) {
                    Text("• \(fromName) → \(toName)")
                        .font(.caption2)
                        .foregroundStyle(Theme.secondaryInk)
                        .lineLimit(1)
                } else if let fromName = accountName(rule.actions.fromAccountID), rule.actions.overrideAccountID == nil {
                    Text("• \(fromName)")
                        .font(.caption2)
                        .foregroundStyle(Theme.secondaryInk)
                        .lineLimit(1)
                }

                if let merchant = rule.actions.setMerchant {
                    Text("• \"\(merchant)\"")
                        .font(.caption2)
                        .foregroundStyle(Theme.secondaryInk)
                        .lineLimit(1)
                }

                Spacer()

                // Enhanced Edit & Delete Buttons
                Button(action: onEdit) {
                    HStack(spacing: 4) {
                        Image(systemName: "pencil")
                            .font(.caption2.weight(.bold))
                        Text("Edit")
                            .font(.caption2.weight(.semibold))
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Theme.brand.opacity(0.12), in: Capsule())
                    .foregroundStyle(Theme.brand)
                }
                .buttonStyle(.plain)

                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                        .font(.caption2.weight(.semibold))
                        .padding(6)
                        .background(Theme.expense.opacity(0.12), in: Circle())
                        .foregroundStyle(Theme.expense)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.track.opacity(rule.isEnabled ? 0.45 : 0.22))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(isHighlighted ? Theme.income.opacity(0.45) : Color.clear, lineWidth: 1)
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
                        TransactionRuleRowCard(
                            priorityNumber: index + 1,
                            rule: rule,
                            accounts: accounts,
                            isHighlighted: false,
                            canMoveUp: index > 0,
                            canMoveDown: index < store.rules.count - 1,
                            onMoveUp: { store.moveRuleUp(id: rule.id) },
                            onMoveDown: { store.moveRuleDown(id: rule.id) },
                            onToggle: { store.toggleRule(id: rule.id) },
                            onEdit: { editingRule = rule },
                            onDelete: { store.deleteRule(id: rule.id) }
                        )
                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                        .listRowBackground(Color.clear)
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
                }
            }
        }
        .navigationTitle("Transaction Rules")
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
