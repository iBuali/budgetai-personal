import SwiftUI
import SwiftData
import LocalAuthentication

enum AppTab: Hashable { case home, transactions, budgets, insights, accounts }

@Observable
final class AppState {
    var tab: AppTab = .home
    var requestedTransactionsFilter: TxFilter?
    var toast: String?
    var toastIsWarning = false
    var showAddTransaction = false
    var showPasteSMS = false
    var showDrawer = false
    var showNotifications = false
    var showSettings = false
    var notificationsReadSignature: String = UserDefaults.standard.string(forKey: "notificationsReadSignature") ?? ""
    var hasUnreadAlerts = false
    var dataVersion = 0

    func markNotificationsRead(signature: String) {
        notificationsReadSignature = signature
        UserDefaults.standard.set(signature, forKey: "notificationsReadSignature")
        hasUnreadAlerts = false
    }

    @MainActor
    func refreshAlerts(context: ModelContext) {
        var parts: [String] = []
        let cal = Calendar.current
        let soon = cal.date(byAdding: .day, value: 7, to: .now) ?? .now

        let bills = (try? context.fetch(FetchDescriptor<Bill>())) ?? []
        for bill in bills where !bill.isPaidForCurrentCycle() && bill.nextDueDate <= soon {
            parts.append("bill-\(bill.id.uuidString)")
        }

        let reviewCount = (try? context.fetchCount(FetchDescriptor<MoneyTransaction>(predicate: #Predicate {
            $0.isPending || $0.isPossibleDuplicate
        }))) ?? 0
        if reviewCount > 0 { parts.append("review-\(reviewCount)") }

        let budgets = (try? context.fetch(FetchDescriptor<Budget>())) ?? []
        if !budgets.isEmpty {
            let interval = Cycle.interval(containing: .now)
            let start = interval.start, end = interval.end
            let cycleTxs = (try? context.fetch(FetchDescriptor<MoneyTransaction>(predicate: #Predicate {
                $0.date >= start && $0.date < end && !$0.isPending
            }))) ?? []
            var spentByCategory: [String: Double] = [:]
            for tx in cycleTxs where tx.isSpending {
                spentByCategory[tx.categoryRaw, default: 0] += tx.amount
            }
            for b in budgets where b.limit > 0 {
                let spent = b.categories.reduce(0) { $0 + (spentByCategory[$1.rawValue] ?? 0) }
                let pct = Int((spent / b.limit) * 100)
                if pct >= 80 { parts.append("budget-\(b.id.uuidString)-\(pct)") }
            }
        }

        let accounts = (try? context.fetch(FetchDescriptor<Account>())) ?? []
        for acc in accounts where acc.kind.isLiability && acc.balance > 0 && acc.paymentDueReminder {
            let days = acc.daysUntilDue()
            if days <= 5 {
                parts.append("card-\(acc.id.uuidString)-\(days)")
            }
        }

        let sig = parts.joined(separator: "|")
        hasUnreadAlerts = !sig.isEmpty && sig != notificationsReadSignature
    }

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
            Task { @MainActor in
                await Task.yield()
                SMSImporter.reconcileExistingTransactions(context: context)
                _ = Ledger.processScheduledLoanInstallments(context: context)
                Ledger.recordSnapshot(context: context)
                Ledger.refreshCardReminders(context: context)
                ICloudBackupService.shared.performAutoBackupIfDue(context: context)
                appState.refreshAlerts(context: context)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background && faceID { locked = true }
            if phase == .active {
                if faceID && locked { authenticate() }
                Task { @MainActor in
                    await Task.yield()
                    SMSImporter.reconcileExistingTransactions(context: context)
                    _ = Ledger.processScheduledLoanInstallments(context: context)
                    ICloudBackupService.shared.performAutoBackupIfDue(context: context)
                    appState.refreshAlerts(context: context)
                }
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

enum DrawerDestination: Identifiable {
    case bills, categories, rules, importStatement, exportStatement, aiAssistant
    var id: Self { self }
}

struct MainTabs: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var context
    @State private var drawerDestination: DrawerDestination?
    @State private var alertRefreshTask: Task<Void, Never>?

    var body: some View {
        @Bindable var state = appState
        ZStack(alignment: .leading) {
            TabView(selection: $state.tab) {
                Tab("Home", systemImage: "house.fill", value: AppTab.home) { HomeView() }
                Tab("Transactions", systemImage: "list.bullet", value: AppTab.transactions) { TransactionsView() }
                Tab("Budgets", systemImage: "chart.bar.fill", value: AppTab.budgets) { BudgetsView() }
                Tab("Insights", image: "FalakTabIcon", value: AppTab.insights) { InsightsView() }
                Tab("Accounts", systemImage: "square.3.layers.3d", value: AppTab.accounts) {
                    NavigationStack { NetWorthView(isRootTab: true) }
                }
            }
            .sensoryFeedback(.selection, trigger: appState.tab)

            if !appState.showDrawer {
                Color.clear
                    .frame(width: 24)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 20)
                            .onEnded { value in
                                if value.translation.width > 55 && abs(value.translation.height) < 80 {
                                    withAnimation(.snappy(duration: 0.28)) {
                                        appState.showDrawer = true
                                    }
                                }
                            }
                    )
            }

            if appState.showDrawer {
                Color.black.opacity(0.28)
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation(.snappy(duration: 0.25)) {
                            appState.showDrawer = false
                        }
                    }
                    .transition(.opacity)
                    .zIndex(10)

                SideMenuDrawer(
                    onOpenAccounts: {
                        withAnimation(.snappy(duration: 0.25)) { appState.showDrawer = false }
                        appState.tab = .accounts
                    },
                    onOpenDestination: { dest in
                        withAnimation(.snappy(duration: 0.25)) { appState.showDrawer = false }
                        drawerDestination = dest
                    },
                    onOpenSettings: {
                        withAnimation(.snappy(duration: 0.25)) { appState.showDrawer = false }
                        appState.showSettings = true
                    }
                )
                .gesture(
                    DragGesture(minimumDistance: 20)
                        .onEnded { value in
                            if value.translation.width < -50 {
                                withAnimation(.snappy(duration: 0.25)) {
                                    appState.showDrawer = false
                                }
                            }
                        }
                )
                .transition(.move(edge: .leading))
                .zIndex(11)
            }

            if appState.showNotifications {
                Color.black.opacity(0.12)
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation(.snappy(duration: 0.22)) {
                            appState.showNotifications = false
                        }
                    }
                    .transition(.opacity)
                    .zIndex(12)

                VStack {
                    NotificationsPopoverCard(
                        onOpenDestination: { dest in
                            withAnimation(.snappy(duration: 0.22)) { appState.showNotifications = false }
                            drawerDestination = dest
                        },
                        onClose: {
                            withAnimation(.snappy(duration: 0.22)) { appState.showNotifications = false }
                        }
                    )
                    .padding(.horizontal, 12)
                    .padding(.top, 52)
                    Spacer()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(13)
            }
        }
        .animation(.snappy(duration: 0.28), value: appState.showDrawer)
        .animation(.snappy(duration: 0.22), value: appState.showNotifications)
        .onReceive(NotificationCenter.default.publisher(for: .budgetDataDidChange)) { _ in
            appState.dataVersion += 1
            alertRefreshTask?.cancel()
            alertRefreshTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return }
                appState.refreshAlerts(context: context)
            }
        }
        .onChange(of: appState.showNotifications) { _, shown in
            if !shown {
                appState.refreshAlerts(context: context)
            }
        }
        .sheet(isPresented: $state.showSettings) { ProfileView() }
        .sheet(item: $drawerDestination) { dest in
            switch dest {
            case .bills:
                NavigationStack { BillsView() }
            case .categories:
                NavigationStack { CategoriesView() }
            case .rules:
                NavigationStack { TransactionRulesListView() }
            case .importStatement:
                StatementImportSheet()
            case .exportStatement:
                StatementExportSheet()
            case .aiAssistant:
                NavigationStack { AdvisorChatView() }
            }
        }
    }
}

private struct SideMenuDrawer: View {
    @AppStorage(Keys.userName) private var userName = ""
    let onOpenAccounts: () -> Void
    let onOpenDestination: (DrawerDestination) -> Void
    let onOpenSettings: () -> Void

    private var initials: String {
        let parts = userName.split(separator: " ").prefix(2)
        let s = parts.compactMap(\.first).map(String.init).joined().uppercased()
        return s.isEmpty ? "F" : s
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image("FalakLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 28, height: 28)
                Text("FALAK")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(Theme.ink)
                Spacer()
                Button(action: onOpenSettings) {
                    Image(systemName: "gearshape")
                        .font(.body.weight(.medium))
                        .foregroundStyle(Theme.ink)
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Settings")
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 18)

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Money")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.secondaryInk)
                            .padding(.horizontal, 18)
                            .padding(.bottom, 4)

                        drawerRow(title: "Accounts & Net Worth", symbol: "building.columns", action: onOpenAccounts)
                        drawerRow(title: "Bills & Subscriptions", symbol: "clock") { onOpenDestination(.bills) }
                        drawerRow(title: "Categories", symbol: "square.grid.2x2") { onOpenDestination(.categories) }
                        drawerRow(title: "Transaction Rules", symbol: "slider.horizontal.3") { onOpenDestination(.rules) }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Import & AI")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.secondaryInk)
                            .padding(.horizontal, 18)
                            .padding(.bottom, 4)

                        drawerRow(title: "Import Bank Statement", symbol: "doc.text") { onOpenDestination(.importStatement) }
                        drawerRow(title: "Export Statement (Excel)", symbol: "arrow.up") { onOpenDestination(.exportStatement) }
                        drawerRow(title: "Gemini AI Assistant", symbol: "sparkles") { onOpenDestination(.aiAssistant) }
                    }
                }
                .padding(.vertical, 4)
            }

            Divider()
                .padding(.horizontal, 18)

            Button(action: onOpenSettings) {
                HStack(spacing: 12) {
                    Text(initials)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.ink)
                        .frame(width: 32, height: 32)
                        .background(Theme.track, in: Circle())
                    Text(userName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Settings" : userName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .frame(width: 292)
        .frame(maxHeight: .infinity)
        .background(Theme.canvas.ignoresSafeArea())
        .shadow(color: .black.opacity(0.14), radius: 20, x: 6)
    }

    private func drawerRow(title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.ink)
                    .frame(width: 22)
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.ink)
                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct NotificationCardItem: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let timeText: String
    let action: () -> Void
}

private struct NotificationsPopoverCard: View {
    @Environment(AppState.self) private var appState
    @Query(sort: \Bill.nextDueDate) private var bills: [Bill]
    @Query(sort: \MoneyTransaction.date, order: .reverse) private var transactions: [MoneyTransaction]
    @Query(sort: \Budget.createdAt) private var budgets: [Budget]
    @Query(sort: \Account.createdAt) private var accounts: [Account]
    @AppStorage(Keys.currency) private var currency = "BHD"

    let onOpenDestination: (DrawerDestination) -> Void
    let onClose: () -> Void

    private var notificationItems: [NotificationCardItem] {
        var list: [NotificationCardItem] = []
        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: .now)
        let soon = cal.date(byAdding: .day, value: 7, to: .now) ?? .now

        for bill in bills where !bill.isPaidForCurrentCycle() && bill.nextDueDate <= soon {
            let days = cal.dateComponents([.day], from: todayStart, to: cal.startOfDay(for: bill.nextDueDate)).day ?? 0
            let dueTitle: String = {
                if days < 0 { return "\(bill.name) is overdue" }
                if days == 0 { return "\(bill.name) due today" }
                if days == 1 { return "\(bill.name) due tomorrow" }
                return "\(bill.name) due in \(days) days"
            }()
            let timeLabel = days < 0 ? "\(-days)d ago" : (days == 0 ? "Today" : "In \(days)d")
            list.append(NotificationCardItem(
                id: "bill-\(bill.id.uuidString)",
                title: dueTitle,
                subtitle: "\(Money.format(bill.amount, currency)) scheduled",
                timeText: timeLabel,
                action: { onOpenDestination(.bills) }
            ))
        }

        let reviewTxs = transactions.filter { $0.isPending || $0.isPossibleDuplicate }
        if !reviewTxs.isEmpty {
            let latest = reviewTxs.first?.date ?? .now
            let hours = max(1, cal.dateComponents([.hour], from: latest, to: .now).hour ?? 1)
            let timeLabel = hours < 24 ? "\(hours)h ago" : "\(hours / 24)d ago"
            list.append(NotificationCardItem(
                id: "review-\(reviewTxs.count)",
                title: "\(reviewTxs.count) transaction\(reviewTxs.count == 1 ? "" : "s") to approve",
                subtitle: "Tap Review in Transactions to confirm",
                timeText: timeLabel,
                action: {
                    onClose()
                    appState.openTransactions(filter: .review)
                }
            ))
        }

        let f = Finance(transactions: transactions, accounts: accounts, budgets: budgets, bills: bills)
        let interval = f.monthInterval(.now)
        for budget in budgets where budget.limit > 0 {
            let spent = f.spent(for: budget, in: interval)
            let pct = Int((spent / budget.limit) * 100)
            if pct >= 80 {
                list.append(NotificationCardItem(
                    id: "budget-\(budget.id.uuidString)-\(pct)",
                    title: "\(budget.name) at \(pct)%",
                    subtitle: "\(Money.format(spent, currency)) of \(Money.format(budget.limit, currency)) monthly budget used",
                    timeText: "This month",
                    action: {
                        onClose()
                        appState.tab = .budgets
                    }
                ))
            }
        }

        for acc in accounts where acc.kind.isLiability && acc.balance > 0 && acc.paymentDueReminder {
            let days = acc.daysUntilDue()
            if days <= 5 {
                let dueStr = acc.nextUpcomingDueDate().formatted(.dateTime.day().month(.abbreviated))
                list.append(NotificationCardItem(
                    id: "card-\(acc.id.uuidString)-\(days)",
                    title: "\(acc.name) payment due",
                    subtitle: "Due \(dueStr) · \(Money.format(acc.balance, currency))",
                    timeText: days <= 0 ? "Today" : "In \(days)d",
                    action: {
                        onClose()
                        appState.tab = .accounts
                    }
                ))
            }
        }

        return list
    }

    private var alertSignature: String {
        notificationItems.map(\.id).joined(separator: "|")
    }

    var body: some View {
        let items = notificationItems
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Notifications")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(Theme.ink)
                Spacer()
                if !items.isEmpty {
                    Button("Mark all read") {
                        appState.markNotificationsRead(signature: alertSignature)
                        onClose()
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.ink)
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 4)

            if items.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "bell.badge")
                        .foregroundStyle(Theme.secondaryInk)
                    Text("You're all caught up")
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondaryInk)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(Theme.track.opacity(0.6), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(items) { item in
                            Button(action: item.action) {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                                        Text(item.title)
                                            .font(.subheadline.weight(.semibold))
                                            .foregroundStyle(Theme.ink)
                                            .lineLimit(1)
                                        Spacer()
                                        Text(item.timeText)
                                            .font(.caption)
                                            .foregroundStyle(Theme.secondaryInk)
                                    }
                                    Text(item.subtitle)
                                        .font(.caption)
                                        .foregroundStyle(Theme.secondaryInk)
                                        .lineLimit(2)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(14)
                                .background(Theme.track.opacity(0.65), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 320)
            }
        }
        .padding(16)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 22, y: 8)
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
            Text("FALAK is locked").font(.title2.bold()).foregroundStyle(Theme.ink)
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
