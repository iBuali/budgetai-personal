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

struct BankConnectionsView: View {
    var isSheet = false
    @Environment(\.dismiss) private var dismiss

    private let banks: [(name: String, country: String)] = [
        ("National Bank of Bahrain (NBB)", "Bahrain"),
        ("Bank of Bahrain and Kuwait (BBK)", "Bahrain"),
        ("Bank ABC", "Bahrain"),
        ("KFH Bahrain", "Bahrain"),
        ("Al Salam Bank", "Bahrain"),
        ("Bahrain Islamic Bank (BisB)", "Bahrain"),
        ("ila Bank", "Bahrain"),
        ("Ahli United Bank", "Bahrain"),
    ]

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    IconBadge(symbol: "building.columns.fill", color: Theme.cobalt, size: 52)
                    Text("Connect your bank")
                        .font(.title3.weight(.bold)).foregroundStyle(Theme.ink)
                    Text("Direct bank sync uses Open Banking under the Central Bank of Bahrain framework, through a licensed provider. Budget AI is ready for it and will switch it on once the provider is live.")
                        .font(.subheadline).foregroundStyle(Theme.secondaryInk)
                }
                .padding(.vertical, 6)
            }

            Section("Bahrain & GCC banks") {
                ForEach(banks, id: \.name) { bank in
                    HStack(spacing: 12) {
                        Text(String(bank.name.prefix(1)))
                            .font(.headline).foregroundStyle(Theme.cobalt)
                            .frame(width: 36, height: 36)
                            .background(Theme.cobaltSoft, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(bank.name).foregroundStyle(Theme.ink).lineLimit(1)
                            Text(bank.country).font(.caption).foregroundStyle(Theme.secondaryInk)
                        }
                        Spacer()
                        Text("Coming soon")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.secondaryInk)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Theme.track, in: Capsule())
                    }
                }
            }

            Section {
                NavigationLink { SMSSetupGuideView() } label: {
                    Label("Set up SMS import instead", systemImage: "message.badge.filled.fill")
                        .foregroundStyle(Theme.cobalt)
                }
            } footer: {
                Text("SMS import works today with every bank that sends transaction alerts.")
            }
        }
        .scrollContentBackground(.hidden)
        .canvasBackground()
        .navigationTitle("Bank Connections")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            if isSheet {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
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
