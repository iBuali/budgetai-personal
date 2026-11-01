import SwiftUI
import SwiftData

struct ProfileView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var context
    @Query private var accounts: [Account]
    @Query private var bills: [Bill]
    @AppStorage(Keys.currency) private var currency = "BHD"
    @AppStorage(Keys.userName) private var userName = ""
    @AppStorage(Keys.faceID) private var faceID = false
    @AppStorage(Keys.billReminders) private var billReminders = true
    @AppStorage(Keys.budgetAlerts) private var budgetAlerts = true
    @AppStorage(Keys.onboarded) private var onboarded = true
    @AppStorage(Keys.cycleStartDay) private var cycleStartDay = 1
    @Query private var customCategories: [CustomCategory]
    @State private var confirmSample = false
    @State private var confirmErase = false
    @State private var geminiOn = GeminiAccount.isConfigured

    private var netWorth: Double { Finance(transactions: [], accounts: accounts).netWorth }

    private var initials: String {
        let parts = userName.split(separator: " ").prefix(2)
        let s = parts.compactMap(\.first).map(String.init).joined().uppercased()
        return s.isEmpty ? "B" : s
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink { NetWorthView() } label: {
                        HStack(spacing: 14) {
                            Text(initials)
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(Theme.cobalt)
                                .frame(width: 60, height: 60)
                                .background(Theme.cobaltSoft, in: Circle())
                            VStack(alignment: .leading, spacing: 3) {
                                Text(userName.isEmpty ? "Your profile" : userName)
                                    .font(.title3.weight(.semibold)).foregroundStyle(Theme.ink)
                                Text("Net worth \(Money.format(netWorth, currency))")
                                    .font(.subheadline.monospacedDigit())
                                    .foregroundStyle(Theme.secondaryInk)
                                    .animatedNumber(netWorth)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    TextField("Your name", text: $userName)
                        .textContentType(.name)
                }

                Section("Money") {
                    NavigationLink { NetWorthView() } label: {
                        row("Accounts & net worth", "building.columns.fill", Theme.cobalt, value: "\(accounts.count)")
                    }
                    NavigationLink { BillsView() } label: {
                        row("Bills & subscriptions", "calendar.badge.clock", SpendCategory.bills.color, value: "\(bills.count)")
                    }
                    NavigationLink { CategoriesView() } label: {
                        row("Categories", "square.grid.2x2.fill", SpendCategory.shopping.color)
                    }
                    Picker(selection: $cycleStartDay) {
                        ForEach(1...28, id: \.self) { d in Text(ordinal(d)).tag(d) }
                    } label: {
                        row("Month starts on", "calendar", Theme.warning)
                    }
                    .onChange(of: cycleStartDay) { _, _ in appState.show("Budgets now run \(Cycle.label(Cycle.interval(containing: .now)))") }
                    NavigationLink {
                        CurrencyPickerView(selection: $currency).toolbar(.hidden, for: .tabBar)
                    } label: {
                        row("Currency", "dollarsign.circle.fill", Theme.positive, value: currency)
                    }
                }

                Section("Import transactions") {
                    NavigationLink { SMSSetupGuideView() } label: {
                        row("Automatic SMS import", "message.badge.filled.fill", Theme.positive)
                    }
                    Button { appState.showPasteSMS = true } label: {
                        row("Paste bank SMS", "doc.on.clipboard.fill", SpendCategory.transport.color)
                    }
                }

                SMSImportSettingsSection()

                Section {
                    NavigationLink { GeminiSettingsView() } label: {
                        row("Gemini AI", "sparkles", Theme.cobalt, value: geminiOn ? "Connected" : "Not connected")
                    }
                } header: {
                    Text("AI")
                } footer: {
                    Text("AI features run on your own Google Gemini account.")
                }

                Section("Security & notifications") {
                    Toggle(isOn: $faceID) { row("Face ID lock", "faceid", Theme.ink) }
                    Toggle(isOn: $billReminders) { row("Bill reminders", "bell.badge.fill", Theme.warning) }
                        .onChange(of: billReminders) { _, on in
                            if on { Task { _ = await Notifier.requestAuthorization() } }
                            Notifier.rescheduleBills(bills)
                        }
                    Toggle(isOn: $budgetAlerts) { row("Budget alerts", "exclamationmark.triangle.fill", Theme.negative) }
                        .onChange(of: budgetAlerts) { _, on in
                            if on { Task { _ = await Notifier.requestAuthorization() } }
                        }
                }

                Section {
                    Button { confirmSample = true } label: {
                        row("Load sample data", "wand.and.stars", SpendCategory.shopping.color)
                    }
                    Button(role: .destructive) { confirmErase = true } label: {
                        Label("Erase all data", systemImage: "trash").foregroundStyle(Theme.negative)
                    }
                } header: {
                    Text("Data")
                } footer: {
                    Label("All data stays on this iPhone.", systemImage: "lock.fill")
                        .font(.footnote)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 12)
                }
            }
            .scrollContentBackground(.hidden)
            .canvasBackground()
            .navigationTitle("Profile")
            .onAppear { geminiOn = GeminiAccount.isConfigured }
            .confirmationDialog("Replace your data with sample data?", isPresented: $confirmSample, titleVisibility: .visible) {
                Button("Load sample data", role: .destructive) {
                    Ledger.eraseAll(context: context)
                    SampleData.load(into: context)
                    Notifier.rescheduleBills((try? context.fetch(FetchDescriptor<Bill>())) ?? [])
                    appState.show("Sample data loaded")
                }
            } message: {
                Text("Your current accounts, transactions, budgets and bills will be erased.")
            }
            .confirmationDialog("Erase all data?", isPresented: $confirmErase, titleVisibility: .visible) {
                Button("Erase everything", role: .destructive) {
                    Ledger.eraseAll(context: context)
                    UserDefaults.standard.removeObject(forKey: "aiFindingsCache")
                    UserDefaults.standard.removeObject(forKey: "aiFindingsDate")
                    for key in [Keys.cycleStartDay, Keys.smsAccountID, Keys.smsAutoApprove, Keys.smsSyncBalance] {
                        UserDefaults.standard.removeObject(forKey: key)
                    }
                    appState.tab = .home
                    onboarded = false
                }
            } message: {
                Text("This permanently deletes everything on this iPhone and can't be undone.")
            }
        }
    }

    private func ordinal(_ d: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .ordinal
        return f.string(from: NSNumber(value: d)) ?? "\(d)"
    }

    private func row(_ title: String, _ symbol: String, _ color: Color, value: String? = nil) -> some View {
        HStack(spacing: 12) {
            IconBadge(symbol: symbol, color: color, size: 32)
            Text(title).foregroundStyle(Theme.ink)
            Spacer()
            if let value {
                Text(value).foregroundStyle(Theme.secondaryInk)
            }
        }
    }
}
