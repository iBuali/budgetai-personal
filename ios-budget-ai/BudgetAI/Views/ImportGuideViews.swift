import SwiftUI
import SwiftData
import AppIntents

struct SMSSetupGuideView: View {
    @Environment(AppState.self) private var appState

    private let steps: [(String, String)] = [
        ("Open the Shortcuts app", "Go to the Automation tab and tap New Automation."),
        ("Choose Message", "Set Message Contains to \"BHD\" (or pick your bank as the sender)."),
        ("Run Immediately", "Select Run Immediately so it works without asking you."),
        ("Add the Budget AI action", "Search for \"Add Bank SMS\". Set Message to Shortcut Input, and tap Sender → Shortcut Input → Sender (Budget AI also fetches bank phone numbers like 17515151 for BisB or 17123456 for ila directly from the SMS)."),
        ("Done", "Every bank alert is now read and filed automatically, with multi-account routing and duplicate transfer merging."),
    ]

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    IconBadge(symbol: "message.badge.filled.fill", color: Theme.positive, size: 52)
                    Text("Import bank SMS automatically")
                        .font(.title3.weight(.bold)).foregroundStyle(Theme.ink)
                    Text("iOS doesn't let apps read your messages directly. A one-time Shortcuts automation forwards bank alerts to Budget AI instead.")
                        .font(.subheadline).foregroundStyle(Theme.secondaryInk)
                }
                .padding(.vertical, 6)
            }

            SMSImportSettingsSection()

            Section("Setup, about 1 minute") {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .top, spacing: 12) {
                        Text("\(index + 1)")
                            .font(.subheadline.weight(.bold).monospacedDigit())
                            .foregroundStyle(.white)
                            .frame(width: 28, height: 28)
                            .background(Theme.cobalt, in: Circle())
                        VStack(alignment: .leading, spacing: 2) {
                            Text(step.0).font(.body.weight(.semibold)).foregroundStyle(Theme.ink)
                            Text(step.1).font(.subheadline).foregroundStyle(Theme.secondaryInk)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            Section {
                ShortcutsLink()
                    .shortcutsLinkStyle(.automaticOutline)
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
            }

            Section {
                Button("Try it: paste a bank SMS", systemImage: "doc.on.clipboard") { appState.showPasteSMS = true }
            } footer: {
                Text(GeminiAccount.isConfigured
                     ? "Messages are read by your Gemini account for best accuracy."
                     : "Without Gemini connected, a built-in reader handles common NBB, BBK and card alert formats.")
            }
        }
        .scrollContentBackground(.hidden)
        .canvasBackground()
        .navigationTitle("SMS Import")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
    }
}

/// How imported bank SMS are handled: approval, target account and balance matching.
struct SMSImportSettingsSection: View {
    @AppStorage(Keys.smsAutoApprove) private var autoApprove = true
    @AppStorage(Keys.smsSyncBalance) private var syncBalance = true
    @AppStorage(Keys.smsAccountID) private var accountIDString = ""
    @Query(sort: \Account.createdAt) private var accounts: [Account]

    private var targetAccounts: [Account] { accounts.filter { $0.kind == .bank || $0.kind == .creditCard || $0.kind == .cash } }

    var body: some View {
        Section {
            NavigationLink {
                SMSSavedConditionsView()
            } label: {
                HStack {
                    Label("Saved SMS conditions", systemImage: "checklist")
                    Spacer()
                    let count = SMSUserRules.totalConditionsCount()
                    if count > 0 {
                        Text("\(count) saved")
                            .font(.subheadline)
                            .foregroundStyle(Theme.secondaryInk)
                    }
                }
            }
            Picker(selection: $autoApprove) {
                Text("Add automatically").tag(true)
                Text("Ask me to approve").tag(false)
            } label: {
                Label("New SMS transactions", systemImage: autoApprove ? "bolt.fill" : "hand.raised.fill")
            }
            Picker(selection: $accountIDString) {
                Text("Detect automatically").tag("")
                ForEach(targetAccounts) { a in Text(a.menuTitle).tag(a.id.uuidString) }
            } label: {
                Label("Add to account", systemImage: "creditcard.fill")
            }
            Toggle(isOn: $syncBalance) {
                Label("Match balance from SMS", systemImage: "equal.circle.fill")
            }
        } header: {
            Text("SMS import")
        } footer: {
            Text(footer)
        }
        .sensoryFeedback(.selection, trigger: autoApprove)
    }

    private var footer: String {
        var parts: [String] = []
        parts.append(autoApprove ? "Transactions count right away." : "Transactions wait in a list until you approve them.")
        parts.append(accountIDString.isEmpty ? "Accounts are matched by card digits set on each account, or by bank name." : "All bank messages go to the chosen account.")
        if syncBalance { parts.append("When a message shows your available balance, the account is updated to match it.") }
        return parts.joined(separator: " ")
    }
}

// MARK: - Saved SMS Conditions & Rules Management

enum SMSConditionFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case senderBanks = "Sender Banks"
    case transactionRules = "Transaction Rules"

    var id: String { rawValue }
}

struct SMSSavedConditionsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState
    @Query private var accounts: [Account]
    @Query private var goals: [SavingsGoal]
    @State private var senderBankMap: [String: String] = [:]
    @State private var senderAccountMap: [String: UUID] = [:]
    @State private var classificationRules: [SMSUserRules.ClassificationRule] = []
    @State private var selectedFilter: SMSConditionFilter = .all
    @State private var showAddSheet = false
    @State private var showClearAllConfirmation = false
    @State private var selectedRuleForDetails: SMSUserRules.ClassificationRule? = nil

    private var totalCount: Int {
        senderBankMap.count + classificationRules.count
    }

    private var sortedSenderRules: [(sender: String, bank: String)] {
        senderBankMap.map { ($0.key, $0.value) }.sorted { $0.0 < $1.0 }
    }

    private var sortedClassificationRules: [SMSUserRules.ClassificationRule] {
        classificationRules.sorted { $0.updatedAt > $1.updatedAt }
    }

    var body: some View {
        List {
            if totalCount > 0 {
                Section {
                    Picker("Filter", selection: $selectedFilter) {
                        Text("All (\(totalCount))").tag(SMSConditionFilter.all)
                        Text("Senders (\(senderBankMap.count))").tag(SMSConditionFilter.senderBanks)
                        Text("Rules (\(classificationRules.count))").tag(SMSConditionFilter.transactionRules)
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                }
            }

            if totalCount == 0 {
                emptyStateSection
            }

            if (selectedFilter == .all || selectedFilter == .senderBanks) && (!senderBankMap.isEmpty || selectedFilter == .senderBanks) {
                senderBanksSection
            }

            if (selectedFilter == .all || selectedFilter == .transactionRules) && (!classificationRules.isEmpty || selectedFilter == .transactionRules) {
                classificationRulesSection
            }

            Section {
                Button {
                    showAddSheet = true
                } label: {
                    Label("Add SMS sender bank", systemImage: "plus.circle.fill")
                        .font(.body.weight(.medium))
                        .foregroundStyle(Theme.cobalt)
                }
            }

            if totalCount > 0 {
                clearAllSection
            }
        }
        .scrollContentBackground(.hidden)
        .canvasBackground()
        .navigationTitle("Saved SMS Conditions")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack(spacing: 12) {
                    if totalCount > 0 {
                        Button(role: .destructive) {
                            showClearAllConfirmation = true
                        } label: {
                            Image(systemName: "trash")
                                .foregroundStyle(Theme.negative)
                        }
                        .accessibilityLabel("Clear all saved conditions")
                    }
                    Button {
                        showAddSheet = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add sender bank")
                }
            }
        }
        .confirmationDialog(
            "Clear all saved conditions?",
            isPresented: $showClearAllConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear All (\(totalCount))", role: .destructive) {
                SMSUserRules.clearAll()
                reload()
                appState.show("All saved SMS conditions cleared")
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This will permanently delete all \(totalCount) saved SMS sender bank mappings and transaction rules. Future incoming SMS will use default parsing.")
        }
        .sheet(isPresented: $showAddSheet) {
            AddSMSSenderBankSheet {
                reload()
            }
        }
        .sheet(item: $selectedRuleForDetails) { rule in
            SMSClassificationRuleDetailSheet(rule: rule, accounts: accounts, goals: goals)
        }
        .onAppear(perform: reload)
    }

    private var emptyStateSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                IconBadge(symbol: "checklist", color: Theme.cobalt, size: 48)
                Text("No saved conditions yet")
                    .font(.headline)
                    .foregroundStyle(Theme.ink)
                Text("When you link bank senders or edit/approve SMS transactions with custom categories, merchants, or accounts, your conditions are saved here automatically.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondaryInk)
            }
            .padding(.vertical, 8)
        }
    }

    private var senderBanksSection: some View {
        Section {
            if senderBankMap.isEmpty {
                Text("No sender banks saved yet.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondaryInk)
            } else {
                ForEach(sortedSenderRules, id: \.sender) { item in
                    HStack(spacing: 12) {
                        IconBadge(symbol: "building.columns.fill", color: Theme.cobalt, size: 38)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.sender)
                                .font(.body.weight(.semibold))
                                .foregroundStyle(Theme.ink)
                            if let accID = senderAccountMap[item.sender],
                               let linkedAcc = accounts.first(where: { $0.id == accID }) {
                                Text("\(item.bank) · ➔ \(linkedAcc.name)")
                                    .font(.subheadline)
                                    .foregroundStyle(Theme.secondaryInk)
                            } else {
                                Text(item.bank)
                                    .font(.subheadline)
                                    .foregroundStyle(Theme.secondaryInk)
                            }
                        }
                        Spacer()
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            SMSUserRules.removeBank(forSender: item.sender)
                            reload()
                            appState.show("Removed \(item.sender)")
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
        } header: {
            HStack {
                Text("Sender Banks (\(senderBankMap.count))")
                Spacer()
                if !senderBankMap.isEmpty && selectedFilter == .senderBanks {
                    Button("Clear senders", role: .destructive) {
                        SMSUserRules.clearSenderBanks()
                        reload()
                        appState.show("Cleared sender banks")
                    }
                    .font(.caption)
                }
            }
        } footer: {
            if !senderBankMap.isEmpty {
                Text("Swipe left on a sender to remove its bank mapping.")
            }
        }
    }

    private var classificationRulesSection: some View {
        Section {
            if classificationRules.isEmpty {
                Text("No transaction classification rules saved yet.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondaryInk)
            } else {
                ForEach(sortedClassificationRules) { rule in
                    Button {
                        selectedRuleForDetails = rule
                    } label: {
                        HStack(spacing: 12) {
                            CategoryIcon(category: rule.category, size: 38)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(ruleTitle(for: rule))
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(Theme.ink)
                                    .lineLimit(1)

                                HStack(spacing: 6) {
                                    Text(rule.transactionType.title)
                                        .font(.caption2.weight(.bold))
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(typeColor(rule.transactionType).opacity(0.12), in: Capsule())
                                        .foregroundStyle(typeColor(rule.transactionType))

                                    Text(rule.category.shortTitle)
                                        .font(.caption)
                                        .foregroundStyle(Theme.secondaryInk)

                                    if let sub = rule.subcategory {
                                        Text("· \(sub.shortTitle)")
                                            .font(.caption)
                                            .foregroundStyle(Theme.secondaryInk)
                                    }
                                }

                                if let meta = ruleMetaSummary(for: rule) {
                                    Text(meta)
                                        .font(.caption2)
                                        .foregroundStyle(Theme.secondaryInk)
                                        .lineLimit(1)
                                }
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            SMSUserRules.removeClassificationRule(signature: rule.signature)
                            reload()
                            appState.show("Removed condition")
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
        } header: {
            HStack {
                Text("Transaction Rules & Conditions (\(classificationRules.count))")
                Spacer()
                if !classificationRules.isEmpty && selectedFilter == .transactionRules {
                    Button("Clear rules", role: .destructive) {
                        SMSUserRules.clearClassificationRules()
                        reload()
                        appState.show("Cleared transaction rules")
                    }
                    .font(.caption)
                }
            }
        } footer: {
            if !classificationRules.isEmpty {
                Text("Swipe left on any condition to delete it, or tap to view its full pattern.")
            }
        }
    }

    private var clearAllSection: some View {
        Section {
            Button(role: .destructive) {
                showClearAllConfirmation = true
            } label: {
                HStack {
                    Spacer()
                    Label("Clear all saved conditions", systemImage: "trash.fill")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Theme.negative)
                    Spacer()
                }
            }
        } footer: {
            Text("Permanently deletes all \(totalCount) saved conditions (sender bank links and transaction classification rules).")
        }
    }

    private func ruleTitle(for rule: SMSUserRules.ClassificationRule) -> String {
        if let m = rule.merchant, !m.isEmpty { return m }
        if !rule.partyKey.isEmpty { return rule.partyKey.capitalized }
        if let bank = rule.bank, !bank.isEmpty { return "SMS from \(bank)" }
        return "SMS Pattern Rule"
    }

    private func ruleMetaSummary(for rule: SMSUserRules.ClassificationRule) -> String? {
        var items: [String] = []
        if let bank = rule.bank, !bank.isEmpty {
            items.append("Bank: \(bank)")
        }
        if !rule.senderKey.isEmpty {
            items.append("Sender: \(rule.senderKey)")
        }
        if let goalID = rule.goalIDString.flatMap(UUID.init), let goal = goals.first(where: { $0.id == goalID }) {
            items.append("➔ Goal: \(goal.name)")
        } else if let toID = rule.toAccountIDString.flatMap(UUID.init), let acc = accounts.first(where: { $0.id == toID }) {
            items.append("➔ To: \(acc.name)")
        } else if let fromID = rule.accountIDString.flatMap(UUID.init), let acc = accounts.first(where: { $0.id == fromID }) {
            items.append("➔ From: \(acc.name)")
        }
        return items.isEmpty ? nil : items.joined(separator: " · ")
    }

    private func typeColor(_ type: SMSTransactionType) -> Color {
        switch type {
        case .income, .transferIn: Theme.positive
        case .expense, .transferOut: Theme.negative
        case .internalTransfer: Theme.cobalt
        case .fee: Theme.warning
        case .refund: Theme.positive
        case .unknown: Theme.secondaryInk
        }
    }

    private func reload() {
        senderBankMap = SMSUserRules.allSenderBanks()
        senderAccountMap = SMSUserRules.allSenderAccounts()
        classificationRules = SMSUserRules.allClassificationRules()
    }
}

typealias SMSSenderBanksView = SMSSavedConditionsView

struct SMSClassificationRuleDetailSheet: View {
    let rule: SMSUserRules.ClassificationRule
    let accounts: [Account]
    let goals: [SavingsGoal]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Rule Classification") {
                    LabeledContent("Merchant / Name", value: rule.merchant ?? "Auto-detected")
                    LabeledContent("Transaction Type", value: rule.transactionType.title)
                    LabeledContent("Category", value: rule.category.title)
                    if let sub = rule.subcategory {
                        LabeledContent("Subcategory", value: sub.title)
                    }
                }

                Section("Routing & Accounts") {
                    if let bank = rule.bank, !bank.isEmpty {
                        LabeledContent("Bank", value: bank)
                    }
                    if !rule.senderKey.isEmpty {
                        LabeledContent("Sender ID / Phone", value: rule.senderKey)
                    }
                    if let fromID = rule.accountIDString.flatMap(UUID.init), let acc = accounts.first(where: { $0.id == fromID }) {
                        LabeledContent("Source Account", value: acc.name)
                    }
                    if let toID = rule.toAccountIDString.flatMap(UUID.init), let acc = accounts.first(where: { $0.id == toID }) {
                        LabeledContent("Destination Account", value: acc.name)
                    }
                    if let goalID = rule.goalIDString.flatMap(UUID.init), let goal = goals.first(where: { $0.id == goalID }) {
                        LabeledContent("Linked Savings Goal", value: goal.name)
                    }
                }

                Section("Pattern Matching Details") {
                    if !rule.partyKey.isEmpty {
                        LabeledContent("Counterparty Key", value: rule.partyKey)
                    }
                    if !rule.templateKey.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Message Template Structure").font(.caption).foregroundStyle(Theme.secondaryInk)
                            Text(rule.templateKey)
                                .font(.caption.monospaced())
                                .foregroundStyle(Theme.ink)
                        }
                    }
                    LabeledContent("Saved on", value: rule.updatedAt.formatted(date: .long, time: .shortened))
                }
            }
            .navigationTitle("Condition Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

struct AddSMSSenderBankSheet: View {
    var onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState
    @Query(sort: \Account.createdAt) private var accounts: [Account]
    @State private var sender = ""
    @State private var selectedBank = "BisB"
    @State private var customBank = ""
    @State private var useCustomBank = false
    @State private var selectedAccountIDString = ""

    private let sampleSenders = ["17515151", "17123456", "BisB", "ilaBank", "NBB", "BBK", "AlSalam", "BenefitPay"]

    private var effectiveBank: String {
        useCustomBank ? customBank.trimmingCharacters(in: .whitespacesAndNewlines) : selectedBank
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("SMS Sender ID or Bank Phone Number") {
                    TextField("e.g. 17515151, 17123456, BisB, ilaBank...", text: $sender)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(sampleSenders, id: \.self) { sample in
                                Button {
                                    sender = sample
                                    applyDefaultBank(for: sample)
                                } label: {
                                    Text(sample)
                                        .font(.caption.weight(.medium))
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 5)
                                        .background(sender.caseInsensitiveCompare(sample) == .orderedSame ? Theme.cobalt : Theme.cobaltSoft, in: Capsule())
                                        .foregroundStyle(sender.caseInsensitiveCompare(sample) == .orderedSame ? .white : Theme.cobalt)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                Section("Bank") {
                    if !useCustomBank {
                        Picker("Select bank", selection: $selectedBank) {
                            ForEach(BahrainBankCatalog.bahrainBanks, id: \.self) { b in
                                Text(b).tag(b)
                            }
                        }
                        .pickerStyle(.menu)
                    } else {
                        TextField("Enter bank name", text: $customBank)
                            .textInputAutocapitalization(.words)
                    }

                    Toggle("Other / custom bank name", isOn: $useCustomBank)
                }

                if !accounts.isEmpty {
                    Section {
                        Picker("Target Account", selection: $selectedAccountIDString) {
                            Text("Auto-match by bank (\(effectiveBank))").tag("")
                            ForEach(accounts) { acc in
                                Text(acc.menuTitle).tag(acc.id.uuidString)
                            }
                        }
                    } header: {
                        Text("Account Routing (Optional)")
                    } footer: {
                        Text("Link this sender or bank phone number (e.g. 17515151 for BisB, 17123456 for ila Bank) directly to one of your accounts.")
                    }
                }

                Section {
                    Button {
                        save()
                    } label: {
                        Text("Save Sender Rule")
                            .frame(maxWidth: .infinity)
                            .fontWeight(.semibold)
                    }
                    .disabled(sender.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || effectiveBank.isEmpty)
                }
            }
            .navigationTitle("Add Sender Bank")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .fontWeight(.semibold)
                        .disabled(sender.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || effectiveBank.isEmpty)
                }
            }
        }
    }

    private func applyDefaultBank(for sample: String) {
        switch sample.lowercased() {
        case "17515151", "bisb": selectedBank = "BisB"; useCustomBank = false
        case "17123456", "ilabank", "ila": selectedBank = "ila"; useCustomBank = false
        case "nbb": selectedBank = "NBB"; useCustomBank = false
        case "bbk": selectedBank = "BBK"; useCustomBank = false
        case "alsalam": selectedBank = "Al Salam"; useCustomBank = false
        case "benefitpay": selectedBank = "BenefitPay"; useCustomBank = false
        default: break
        }
    }

    private func save() {
        let cleanSender = sender.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanBank = effectiveBank
        guard !cleanSender.isEmpty, !cleanBank.isEmpty else { return }
        let linkedAccID = UUID(uuidString: selectedAccountIDString)
        SMSUserRules.rememberBank(cleanBank, forSender: cleanSender, accountID: linkedAccID)
        appState.show("Linked '\(cleanSender)' to \(cleanBank)")
        onSaved()
        dismiss()
    }
}
