import SwiftUI
import SwiftData
import AppIntents

struct SMSSetupGuideView: View {
    @Environment(AppState.self) private var appState

    private let steps: [(String, String)] = [
        ("Open the Shortcuts app", "Go to the Automation tab and tap New Automation."),
        ("Choose Message", "Set Message Contains to \"BHD\" (or pick your bank as the sender)."),
        ("Run Immediately", "Select Run Immediately so it works without asking you."),
        ("Add the Budget AI action", "Search for \"Add Bank SMS\" and set its Message to the Shortcut Input's content."),
        ("Done", "Every bank alert is now read and filed automatically, with a category and duplicate check."),
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
                SMSSenderBanksView()
            } label: {
                HStack {
                    Label("SMS sender banks", systemImage: "building.columns.fill")
                    Spacer()
                    let count = SMSUserRules.allSenderBanks().count
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

// MARK: - SMS Sender Banks Management

struct SMSSenderBanksView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState
    @State private var senderBankMap: [String: String] = [:]
    @State private var showAddSheet = false

    var body: some View {
        List {
            if senderBankMap.isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("No sender banks added yet")
                            .font(.headline)
                            .foregroundStyle(Theme.ink)
                        Text("Add SMS sender IDs or phone numbers (e.g. BisB, ilaBank, or +973...) and link them to your bank so imported messages are automatically recognized.")
                            .font(.footnote)
                            .foregroundStyle(Theme.secondaryInk)
                    }
                    .padding(.vertical, 4)
                }
            } else {
                Section {
                    ForEach(sortedRules, id: \.sender) { item in
                        HStack(spacing: 12) {
                            IconBadge(symbol: "building.columns.fill", color: Theme.cobalt, size: 38)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.sender)
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(Theme.ink)
                                Text(item.bank)
                                    .font(.subheadline)
                                    .foregroundStyle(Theme.secondaryInk)
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
                } header: {
                    Text("Saved Sender Rules")
                } footer: {
                    Text("Swipe left on a rule to delete it. Messages from these senders will automatically route to their mapped bank.")
                }
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
        }
        .scrollContentBackground(.hidden)
        .canvasBackground()
        .navigationTitle("SMS Sender Banks")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showAddSheet = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add sender bank")
            }
        }
        .sheet(isPresented: $showAddSheet) {
            AddSMSSenderBankSheet {
                reload()
            }
        }
        .onAppear(perform: reload)
    }

    private var sortedRules: [(sender: String, bank: String)] {
        senderBankMap.map { ($0.key, $0.value) }.sorted { $0.0 < $1.0 }
    }

    private func reload() {
        senderBankMap = SMSUserRules.allSenderBanks()
    }
}

struct AddSMSSenderBankSheet: View {
    var onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState
    @State private var sender = ""
    @State private var selectedBank = "BisB"
    @State private var customBank = ""
    @State private var useCustomBank = false

    private let sampleSenders = ["BisB", "ilaBank", "NBB", "BBK", "AlSalam", "AUB", "BenefitPay", "CrediMax"]

    private var effectiveBank: String {
        useCustomBank ? customBank.trimmingCharacters(in: .whitespacesAndNewlines) : selectedBank
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("SMS Sender ID or Phone Number") {
                    TextField("e.g. BisB, ilaBank, or +973...", text: $sender)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(sampleSenders, id: \.self) { sample in
                                Button {
                                    sender = sample
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

    private func save() {
        let cleanSender = sender.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanBank = effectiveBank
        guard !cleanSender.isEmpty, !cleanBank.isEmpty else { return }
        SMSUserRules.rememberBank(cleanBank, forSender: cleanSender)
        appState.show("Linked '\(cleanSender)' to \(cleanBank)")
        onSaved()
        dismiss()
    }
}
