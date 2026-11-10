import SwiftUI
import SwiftData

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

    // THEN – Default Action: Set Category
    @State private var selectedCategory: SpendCategory = .other
    @State private var isTransferMode: Bool = false
    @State private var transferKind: RuleTransferKind = .internalTransfer
    @State private var fromAccountID: UUID?
    @State private var toAccountID: UUID?

    // THEN – Additional Optional Actions from available fields
    @State private var enableSetAccount: Bool = false
    @State private var enableSetMerchant: Bool = false
    @State private var actionMerchant: String = ""
    @State private var enableSetBank: Bool = false
    @State private var actionBank: String = ""
    @State private var enableSetLocation: Bool = false
    @State private var actionLocationName: String = ""
    @State private var actionLocationAddress: String?
    @State private var actionLatitude: Double?
    @State private var actionLongitude: Double?
    @State private var enableSetGoal: Bool = false
    @State private var actionGoalID: UUID?
    @State private var enableSetNote: Bool = false
    @State private var actionNote: String = ""

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
                // MARK: 1. Capture Transaction Data & Select Conditions
                Section {
                    if availableConditions.isEmpty {
                        Text("No transaction fields available to capture.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(availableConditions) { cond in
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
                    }
                } header: {
                    Text("1. IF — Select Captured Conditions")
                } footer: {
                    Text("Check the fields captured from this transaction that should identify similar future transactions.")
                }

                // MARK: 2. Condition Logic (AND / OR)
                Section {
                    Picker("Match Logic", selection: $logic) {
                        ForEach(RuleConditionLogic.allCases) { item in
                            Text(item.shortTitle).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)

                    Text(logic.title)
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryInk)
                } header: {
                    Text("2. Condition Logic")
                }

                // MARK: 3. THEN – Actions (Default: Set Category + Transfer Options)
                Section {
                    Picker("Set Category", selection: $selectedCategory) {
                        ForEach(CategoryRegistry.shared.all) { cat in
                            Label(cat.rawValue, systemImage: cat.symbol).tag(cat)
                        }
                    }
                    .onChange(of: selectedCategory) { _, newValue in
                        if newValue == .internalTransfer {
                            isTransferMode = true
                            transferKind = .internalTransfer
                        } else if newValue == .transfers {
                            isTransferMode = true
                            transferKind = .externalTransfer
                        } else {
                            isTransferMode = false
                        }
                    }

                    Toggle("Classify as Transfer", isOn: $isTransferMode)
                        .onChange(of: isTransferMode) { _, isTransfer in
                            if isTransfer {
                                selectedCategory = (transferKind == .internalTransfer) ? .internalTransfer : .transfers
                            } else if selectedCategory == .transfers || selectedCategory == .internalTransfer {
                                selectedCategory = .other
                            }
                        }

                    if isTransferMode {
                        Picker("Transfer Type", selection: $transferKind) {
                            ForEach(RuleTransferKind.allCases) { kind in
                                Text(kind.title).tag(kind)
                            }
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: transferKind) { _, newKind in
                            selectedCategory = (newKind == .internalTransfer) ? .internalTransfer : .transfers
                        }

                        if transferKind == .internalTransfer {
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
                        } else {
                            Picker("From / To Account", selection: $fromAccountID) {
                                Text("Keep Detected Account").tag(UUID?.none)
                                ForEach(accounts) { acc in
                                    Text(acc.name).tag(UUID?.some(acc.id))
                                }
                            }
                        }
                    }
                } header: {
                    Text("3. THEN — Default Action")
                } footer: {
                    if isTransferMode && transferKind == .internalTransfer {
                        Text("Internal transfers move money between your selected From Account and To Account.")
                    } else if isTransferMode {
                        Text("External transfers record money sent to or received from an external account.")
                    }
                }

                // MARK: 4. Additional Actions (from available transaction fields)
                Section {
                    if !isTransferMode {
                        Toggle(isOn: $enableSetAccount) {
                            Label("Set Account", systemImage: "wallet.bifold.fill")
                        }
                        if enableSetAccount {
                            Picker("Account", selection: $fromAccountID) {
                                Text("Select Account").tag(UUID?.none)
                                ForEach(accounts) { acc in
                                    Text(acc.name).tag(UUID?.some(acc.id))
                                }
                            }
                        }
                    }

                    if !actionMerchant.isEmpty || existingRule != nil {
                        Toggle(isOn: $enableSetMerchant) {
                            VStack(alignment: .leading, spacing: 2) {
                                Label("Set Merchant / Name", systemImage: "storefront.fill")
                                if !actionMerchant.isEmpty {
                                    Text(actionMerchant)
                                        .font(.caption)
                                        .foregroundStyle(Theme.secondaryInk)
                                }
                            }
                        }
                    }

                    if !actionBank.isEmpty || existingRule != nil {
                        Toggle(isOn: $enableSetBank) {
                            VStack(alignment: .leading, spacing: 2) {
                                Label("Set SMS Bank", systemImage: "building.columns.fill")
                                if !actionBank.isEmpty {
                                    Text(actionBank)
                                        .font(.caption)
                                        .foregroundStyle(Theme.secondaryInk)
                                }
                            }
                        }
                    }

                    if !actionLocationName.isEmpty || existingRule != nil {
                        Toggle(isOn: $enableSetLocation) {
                            VStack(alignment: .leading, spacing: 2) {
                                Label("Set Location", systemImage: "mappin.and.ellipse")
                                if !actionLocationName.isEmpty {
                                    Text(actionLocationName)
                                        .font(.caption)
                                        .foregroundStyle(Theme.secondaryInk)
                                }
                            }
                        }
                    }

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

                    if !actionNote.isEmpty || existingRule != nil {
                        Toggle(isOn: $enableSetNote) {
                            VStack(alignment: .leading, spacing: 2) {
                                Label("Set Note", systemImage: "note.text")
                                if !actionNote.isEmpty {
                                    Text(actionNote)
                                        .font(.caption)
                                        .foregroundStyle(Theme.secondaryInk)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Additional Actions (Optional)")
                } footer: {
                    Text("Additional actions use the values captured from this transaction.")
                }

                // MARK: 5. Rule Name & Status
                Section("Rule Info") {
                    TextField("Rule Name (optional)", text: $ruleName)
                    Toggle("Enable Rule for Future Transactions", isOn: $isEnabled)
                }
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
            selectedCategory = act.category
            if let tk = act.effectiveTransferKind {
                isTransferMode = true
                transferKind = tk
            } else {
                isTransferMode = false
            }
            fromAccountID = act.fromAccountID
            toAccountID = act.toAccountID
            enableSetAccount = !isTransferMode && act.fromAccountID != nil
            if let m = act.setMerchant, !m.isEmpty {
                enableSetMerchant = true
                actionMerchant = m
            }
            if let b = act.setBank, !b.isEmpty {
                enableSetBank = true
                actionBank = b
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
            if let n = act.setNote, !n.isEmpty {
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

            selectedCategory = tx.category
            if tx.category == .internalTransfer || tx.smsTransactionType == .internalTransfer {
                isTransferMode = true
                transferKind = .internalTransfer
            } else if tx.category == .transfers || tx.smsTransactionType == .transferOut || tx.smsTransactionType == .transferIn {
                isTransferMode = true
                transferKind = .externalTransfer
            }
            fromAccountID = tx.accountID
            toAccountID = tx.toAccountID
            populateFallbackActionValues(from: tx)
        }
    }

    private func populateFallbackActionValues(from tx: MoneyTransaction) {
        if actionMerchant.isEmpty {
            actionMerchant = tx.merchant.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if actionBank.isEmpty, let bank = tx.smsBank?.trimmingCharacters(in: .whitespacesAndNewlines) {
            actionBank = bank
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
        let effectiveCat: SpendCategory = {
            if isTransferMode {
                return transferKind == .internalTransfer ? .internalTransfer : .transfers
            }
            return selectedCategory
        }()

        var actions = RuleActions(
            categoryRaw: effectiveCat.rawValue,
            transferKind: isTransferMode ? transferKind : nil,
            fromAccountID: (isTransferMode || enableSetAccount) ? fromAccountID : nil,
            toAccountID: (isTransferMode && transferKind == .internalTransfer) ? toAccountID : nil,
            setMerchant: enableSetMerchant && !actionMerchant.isEmpty ? actionMerchant : nil,
            setBank: enableSetBank && !actionBank.isEmpty ? actionBank : nil,
            setLocationName: enableSetLocation && !actionLocationName.isEmpty ? actionLocationName : nil,
            setLocationAddress: enableSetLocation ? actionLocationAddress : nil,
            setLatitude: enableSetLocation ? actionLatitude : nil,
            setLongitude: enableSetLocation ? actionLongitude : nil,
            setNote: enableSetNote && !actionNote.isEmpty ? actionNote : nil,
            setGoalID: enableSetGoal ? actionGoalID : nil
        )
        if effectiveCat.isIncomeCategory {
            actions.setIsIncome = true
        }

        let cleanName = ruleName.trimmingCharacters(in: .whitespacesAndNewlines)
        let generatedName: String = {
            if !cleanName.isEmpty { return cleanName }
            let condSummary = chosenConditions.map(\.displayValue).joined(separator: logic == .and ? " + " : " | ")
            return "\(condSummary) → \(effectiveCat.rawValue)"
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
        let allRules = store.rules
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

            Text("Rules apply in priority order (Rule 1 highest) to future matching transactions only.")
                .font(.caption)
                .foregroundStyle(Theme.secondaryInk)

            if allRules.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "wand.and.stars")
                        .foregroundStyle(Theme.brand)
                    Text("No rules created yet. Tap \"Create Rule\" to capture fields from this transaction.")
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryInk)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.track.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else {
                VStack(spacing: 8) {
                    ForEach(Array(allRules.enumerated()), id: \.element.id) { index, rule in
                        let isMatchedHere = store.matches(rule: rule, context: RuleEvaluationContext(from: tx), ignoreEnabledState: true)
                        TransactionRuleRowCard(
                            priorityNumber: index + 1,
                            rule: rule,
                            accounts: accounts,
                            isHighlighted: isMatchedHere,
                            canMoveUp: index > 0,
                            canMoveDown: index < allRules.count - 1,
                            onMoveUp: { store.moveRuleUp(id: rule.id) },
                            onMoveDown: { store.moveRuleDown(id: rule.id) },
                            onToggle: { store.toggleRule(id: rule.id) },
                            onEdit: { editingRule = rule },
                            onDelete: { store.deleteRule(id: rule.id) }
                        )
                    }
                }

                NavigationLink {
                    TransactionRulesListView()
                } label: {
                    HStack {
                        Text("Manage All Transaction Rules (\(allRules.count))")
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

                if priorityNumber == 1 {
                    Text("Highest Priority")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Theme.brand)
                }

                if isHighlighted {
                    Text("Matches this Tx")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Theme.income.opacity(0.15), in: Capsule())
                        .foregroundStyle(Theme.income)
                }

                Spacer()

                // Reorder priority buttons
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
            HStack(spacing: 6) {
                Text("THEN")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Theme.secondaryInk)

                Label(rule.actions.category.rawValue, systemImage: rule.actions.category.symbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(rule.actions.category.color)

                if let tk = rule.actions.effectiveTransferKind {
                    Text("(\(tk.title))")
                        .font(.caption2)
                        .foregroundStyle(Theme.secondaryInk)
                }

                if let fromName = accountName(rule.actions.fromAccountID),
                   let toName = accountName(rule.actions.toAccountID) {
                    Text("• \(fromName) → \(toName)")
                        .font(.caption2)
                        .foregroundStyle(Theme.secondaryInk)
                        .lineLimit(1)
                } else if let fromName = accountName(rule.actions.fromAccountID) {
                    Text("• \(fromName)")
                        .font(.caption2)
                        .foregroundStyle(Theme.secondaryInk)
                        .lineLimit(1)
                }

                Spacer()

                Button("Edit", action: onEdit)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.brand)
                    .buttonStyle(.plain)

                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                        .font(.caption)
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
                .stroke(isHighlighted ? Theme.brand.opacity(0.45) : Color.clear, lineWidth: 1)
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
                    Text("Priority Order (Rule 1 is Evaluated First)")
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
