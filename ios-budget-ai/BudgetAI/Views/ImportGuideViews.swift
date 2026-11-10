import SwiftUI
import SwiftData
import AppIntents

struct SMSSetupGuideView: View {
    @Environment(AppState.self) private var appState

    private let steps: [(title: String, detail: String, icon: String)] = [
        ("1. Create Message Automation", "Open Apple Shortcuts → Automation tab → tap New Automation (+). Choose \"Message\", enter \"BHD\" under Message Contains (or select your bank as sender), and select \"Run Immediately\".", "message.badge.filled.fill"),
        ("2. Add 'Get Current Location'", "Tap \"New Blank Automation\" → tap \"Add Action\" → search for \"Get Current Location\" and add it. This captures your exact GPS location at the moment of payment so you see purchase locations on the map.", "location.fill"),
        ("3. Add 'Add Bank SMS' Action", "Tap \"Add Action\" → search for \"Add Bank SMS\" (from Budget AI). Set up the parameters:\n• Message: Shortcut Input\n• Sender: Shortcut Input → Sender (optional)\n• Location: Current Location (from Step 2)\n• Tap arrow for Latitude & Longitude if desired", "arrow.triangle.2.circlepath"),
        ("4. Automatic GPS Fallback", "Budget AI also attempts automatic real-time GPS location capture directly whenever a bank SMS is imported. Ensure Location is set to \"While Using\" in iOS Settings.", "checkmark.seal.fill")
    ]

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    IconBadge(symbol: "message.badge.filled.fill", color: Theme.positive, size: 52)
                    Text("Import bank SMS automatically")
                        .font(.title3.weight(.bold)).foregroundStyle(Theme.ink)
                    Text("iOS doesn't let apps read your messages directly. A one-time Shortcuts automation forwards bank alerts to Budget AI and automatically tags your purchase location.")
                        .font(.subheadline).foregroundStyle(Theme.secondaryInk)
                }
                .padding(.vertical, 6)
            }

            // Visual automation diagram
            Section("Recommended Shortcut Flow") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Image(systemName: "bolt.badge.clock.fill")
                            .foregroundStyle(Theme.brand)
                            .frame(width: 24)
                        Text("Trigger: When message contains \"BHD\"")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.ink)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.canvas, in: RoundedRectangle(cornerRadius: 8))

                    HStack(spacing: 8) {
                        Image(systemName: "arrow.down")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Theme.secondaryInk)
                            .padding(.leading, 12)
                    }

                    HStack(spacing: 10) {
                        Image(systemName: "location.fill")
                            .foregroundStyle(Theme.positive)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Action 1: Get Current Location")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Theme.ink)
                            Text("Retrieves current shop or place GPS coordinates")
                                .font(.caption)
                                .foregroundStyle(Theme.secondaryInk)
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.canvas, in: RoundedRectangle(cornerRadius: 8))

                    HStack(spacing: 8) {
                        Image(systemName: "arrow.down")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Theme.secondaryInk)
                            .padding(.leading, 12)
                    }

                    HStack(spacing: 10) {
                        Image(systemName: "plus.app.fill")
                            .foregroundStyle(Theme.brand)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Action 2: Add Bank SMS")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Theme.ink)
                            Text("Message: Shortcut Input\nSender: Shortcut Input → Sender\nLocation: Current Location")
                                .font(.caption.monospaced())
                                .foregroundStyle(Theme.secondaryInk)
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.canvas, in: RoundedRectangle(cornerRadius: 8))
                }
                .padding(.vertical, 4)
            }

            SMSImportSettingsSection()

            Section("Setup Steps (about 1 minute)") {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: step.icon)
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(.white)
                            .frame(width: 28, height: 28)
                            .background(Theme.brand, in: Circle())
                        VStack(alignment: .leading, spacing: 4) {
                            Text(step.title).font(.body.weight(.semibold)).foregroundStyle(Theme.ink)
                            Text(step.detail).font(.subheadline).foregroundStyle(Theme.secondaryInk)
                        }
                    }
                    .padding(.vertical, 4)
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
                TransactionRulesListView()
            } label: {
                HStack {
                    Label("Transaction Rules", systemImage: "slider.horizontal.3")
                    Spacer()
                    let count = TransactionRuleStore.shared.rules.count
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
