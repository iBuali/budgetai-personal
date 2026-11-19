import SwiftUI
import SwiftData
import AppIntents

struct SMSSetupGuideView: View {
    @Environment(AppState.self) private var appState

    private let steps: [(title: String, detail: String, icon: String)] = [
        ("1. Create Message Automation", "Open Apple Shortcuts → Automation tab → tap New Automation (+). Choose \"Message\", enter \"BHD\" under Message Contains (or select your bank as sender), and select \"Run Immediately\".", "message.badge.filled.fill"),
        ("2. Add 'Get Current Location' (Optional)", "Tap \"New Blank Automation\" → tap \"Add Action\" → search for \"Get Current Location\" and add it. This captures your exact GPS location at the moment of payment so you see purchase locations on the map.", "location.fill"),
        ("3. Add 'Add Bank SMS' Action", "Tap \"Add Action\" → search for \"Add Bank SMS\" (from FALAK). Set up the parameters:\n• Message: Shortcut Input\n• Sender: Shortcut Input → Sender (optional)\n• Location: Current Location (if Step 2 was added)\n• Tap arrow for Latitude & Longitude if desired", "arrow.triangle.2.circlepath"),
        ("4. Automatic GPS Fallback", "FALAK also attempts automatic real-time GPS location capture directly whenever a bank SMS is imported. Ensure Location is set to \"While Using\" in iOS Settings.", "checkmark.seal.fill")
    ]

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    IconBadge(symbol: "message.badge.filled.fill", color: Theme.cobalt, size: 52)
                    Text("Import bank SMS automatically")
                        .font(.title3.weight(.bold)).foregroundStyle(Theme.ink)
                    Text("iOS doesn't let apps read your messages directly. A one-time Shortcuts automation forwards bank alerts to FALAK and automatically tags your purchase location.")
                        .font(.subheadline).foregroundStyle(Theme.secondaryInk)
                }
                .padding(.vertical, 6)
            }

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
                     : "Without Gemini connected, a built-in reader handles common bank and card alert formats.")
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
        Section("SMS Configuration") {
            NavigationLink {
                SMSSetupGuideView()
            } label: {
                HStack(spacing: 12) {
                    IconBadge(symbol: "message.badge.filled.fill", color: Theme.cobalt, size: 32)
                    Text("Automatic SMS import").foregroundStyle(Theme.ink)
                }
            }

            HStack(spacing: 12) {
                IconBadge(symbol: autoApprove ? "bolt.fill" : "hand.raised.fill", color: Theme.cobalt, size: 32)
                SheetPickerRow(
                    title: "New SMS",
                    selection: $autoApprove,
                    options: [
                        SheetPickerOption(id: true, title: "Auto-add", symbol: "bolt.fill", color: Theme.cobalt),
                        SheetPickerOption(id: false, title: "Ask first", symbol: "hand.raised.fill", color: Theme.cobalt)
                    ]
                )
            }

            HStack(spacing: 12) {
                IconBadge(symbol: "creditcard.fill", color: Theme.cobalt, size: 32)
                AccountPickerRow(
                    title: "Account",
                    selection: Binding(
                        get: { UUID(uuidString: accountIDString) },
                        set: { accountIDString = $0?.uuidString ?? "" }
                    ),
                    accounts: targetAccounts,
                    noneLabel: "Auto-detect"
                )
            }

            Toggle(isOn: $syncBalance) {
                HStack(spacing: 12) {
                    IconBadge(symbol: "equal.circle.fill", color: Theme.cobalt, size: 32)
                    Text("Match balance from SMS").foregroundStyle(Theme.ink)
                }
            }
        }
        .sensoryFeedback(.selection, trigger: autoApprove)
    }
}
