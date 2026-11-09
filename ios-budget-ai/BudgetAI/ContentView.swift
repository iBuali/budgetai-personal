import SwiftUI
import SwiftData
import LocalAuthentication

enum AppTab: Hashable { case home, transactions, budgets, insights, profile }

@Observable
final class AppState {
    var tab: AppTab = .home
    var requestedTransactionsFilter: TxFilter?
    var toast: String?
    var toastIsWarning = false
    var showAddTransaction = false
    var showPasteSMS = false

    func openTransactions(filter: TxFilter) {
        requestedTransactionsFilter = filter
        tab = .transactions
    }

    func show(_ text: String, warning: Bool = false) {
        toastIsWarning = warning
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { toast = text }
        let current = text
        Task {
            try? await Task.sleep(for: .seconds(2.8))
            if toast == current { withAnimation(.easeOut(duration: 0.25)) { toast = nil } }
        }
    }

    func report(_ result: LedgerResult, base: String) {
        if let alert = result.alerts.first {
            show(alert, warning: true)
        } else if result.flaggedDuplicate {
            show("\(base) · flagged as possible duplicate", warning: true)
        } else {
            show(base)
        }
    }
}

struct RootView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(Keys.onboarded) private var onboarded = false
    @AppStorage(Keys.faceID) private var faceID = false
    @State private var locked = true

    var body: some View {
        @Bindable var state = appState
        ZStack(alignment: .top) {
            if onboarded {
                MainTabs()
            } else {
                OnboardingView()
                    .transition(.opacity)
            }

            if let toast = appState.toast {
                Toast(text: toast,
                      symbol: appState.toastIsWarning ? "exclamationmark.triangle.fill" : "checkmark.circle.fill",
                      color: appState.toastIsWarning ? Theme.warning : Theme.positive)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(2)
            }

            if onboarded && faceID && locked {
                LockView(unlock: authenticate)
                    .transition(.opacity)
                    .zIndex(3)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: onboarded)
        .sheet(isPresented: $state.showAddTransaction) { AddTransactionSheet() }
        .sheet(isPresented: $state.showPasteSMS) { PasteSMSSheet() }
        .onAppear {
            if faceID { authenticate() } else { locked = false }
            SMSImporter.reconcileExistingTransactions(context: context)
            Ledger.recordSnapshot(context: context)
            Ledger.refreshCardReminders(context: context)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background && faceID { locked = true }
            if phase == .active {
                SMSImporter.reconcileExistingTransactions(context: context)
                if faceID && locked { authenticate() }
            }
        }
    }

    private func authenticate() {
        let ctx = LAContext()
        var error: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            locked = false
            return
        }
        Task {
            let ok = (try? await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock your finances")) ?? false
            if ok { withAnimation { locked = false } }
        }
    }
}

struct MainTabs: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var state = appState
        TabView(selection: $state.tab) {
            Tab("Home", systemImage: "house.fill", value: AppTab.home) { HomeView() }
            Tab("Transactions", systemImage: "list.bullet", value: AppTab.transactions) { TransactionsView() }
            Tab("Budgets", systemImage: "chart.bar.fill", value: AppTab.budgets) { BudgetsView() }
            Tab("Insights", systemImage: "lightbulb.fill", value: AppTab.insights) { InsightsView() }
            Tab("Profile", systemImage: "person.fill", value: AppTab.profile) { ProfileView() }
        }
        .sensoryFeedback(.selection, trigger: appState.tab)
    }
}

struct LockView: View {
    let unlock: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "lock.fill")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 84, height: 84)
                .background(Theme.cobalt, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            Text("Budget AI is locked").font(.title2.bold()).foregroundStyle(Theme.ink)
            Text("Your finances stay private on this iPhone.").foregroundStyle(Theme.secondaryInk)
            Spacer()
            Button(action: unlock) {
                Label("Unlock", systemImage: "faceid").frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvas.ignoresSafeArea())
    }
}
