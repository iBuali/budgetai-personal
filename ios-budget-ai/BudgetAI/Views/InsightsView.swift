import SwiftUI
import SwiftData

enum InsightRoute: Hashable {
    case timeMachine
    case wishlist
    case alerts
    case buyNow(amount: Double, name: String)
    case savingGoal
    case bills
}

/// Completely rebuilt FALAK Insights & Financial Intelligence hub.
/// Displays exactly three clean, focused main cards:
/// 1. Time Machine (contains Forecast, Graph, Events, FALAK Insight, Buy Now?, Saving Goal)
/// 2. Wishlist Intelligence
/// 3. Insights & Alerts
struct InsightsView: View {
    @Environment(AppState.self) private var appState
    @Query(sort: \MoneyTransaction.date, order: .reverse) private var transactions: [MoneyTransaction]
    @Query(sort: \Account.createdAt) private var accounts: [Account]
    @Query private var budgets: [Budget]
    @Query private var goals: [SavingsGoal]
    @Query(sort: \Bill.nextDueDate) private var bills: [Bill]
    @AppStorage(Keys.currency) private var currency = "BHD"

    private struct SummaryBadges: Equatable {
        var timeMachineBadge: String = "Forecast Ready"
        var timeMachineSeverity: SimulationStatus = .safe
        var wishlistBadge: String = "Add items"
        var wishlistHasReady: Bool = false
        var alertsBadge: String = "All clear"
        var alertsUnreadCount: Int = 0
        var alertsHasCritical: Bool = false
    }

    @State private var path = NavigationPath()
    @State private var badges = SummaryBadges()

    private let wishlistStore = WishlistStore.shared
    private let alertStateStore = FinancialAlertStateStore.shared

    private var summaryKey: Int {
        var hasher = Hasher()
        hasher.combine(transactions.count)
        hasher.combine(accounts.count)
        hasher.combine(budgets.count)
        hasher.combine(goals.count)
        hasher.combine(bills.count)
        hasher.combine(wishlistStore.items.count)
        hasher.combine(alertStateStore.readIDs.count)
        hasher.combine(alertStateStore.dismissedIDs.count)
        hasher.combine(currency)
        hasher.combine(appState.dataVersion)
        return hasher.finalize()
    }

    private func recomputeSummaryBadges() {
        let finance = Finance(transactions: transactions, accounts: accounts, budgets: budgets, goals: goals, bills: bills)
        let previewProjection = FinancialProjectionEngine.project(finance: finance, period: .threeMonths, currency: currency)
        let activeAlerts = FinancialAlertsEngine.generate(
            finance: finance,
            projection: previewProjection,
            wishlistItems: wishlistStore.items,
            currency: currency
        ).filter { !alertStateStore.isDismissed($0.id) }
        let unreadAlertsCount = activeAlerts.filter { !alertStateStore.isRead($0.id) }.count
        let readyWishlistCount = wishlistStore.items.filter { item in
            let eval = WishlistEvaluator.evaluate(item: item, finance: finance, projection: previewProjection, currency: currency)
            return eval.suitability == .goodTimeToBuy || item.hasReachedTargetPrice
        }.count

        badges = SummaryBadges(
            timeMachineBadge: previewProjection.hasSufficientData
                ? "3M: \(Money.format(previewProjection.projectedEndBalance, currency))"
                : "Forecast Ready",
            timeMachineSeverity: previewProjection.primaryInsight.severity,
            wishlistBadge: wishlistStore.items.isEmpty
                ? "Add items"
                : (readyWishlistCount > 0 ? "\(readyWishlistCount) ready to buy" : "\(wishlistStore.items.count) tracked"),
            wishlistHasReady: readyWishlistCount > 0,
            alertsBadge: unreadAlertsCount > 0
                ? "\(unreadAlertsCount) unread"
                : (activeAlerts.isEmpty ? "All clear" : "\(activeAlerts.count) active"),
            alertsUnreadCount: unreadAlertsCount,
            alertsHasCritical: activeAlerts.first?.priority == .critical
        )
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(spacing: 16) {
                    Text("Understand your financial future, track goals, and act on smart alerts.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondaryInk)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)

                    // Card 1 — FALAK Time Machine
                    NavigationLink(value: InsightRoute.timeMachine) {
                        mainCard(
                            title: "FALAK Time Machine",
                            subtitle: "Forecast your balance, explore upcoming events, and simulate Buy Now? or Saving Goals.",
                            symbol: "clock.arrow.2.circlepath",
                            colors: [Color(hex: 0x1E3FAE), Color(hex: 0x6D4AE0)],
                            badgeText: badges.timeMachineBadge,
                            badgeColor: badges.timeMachineSeverity.color
                        )
                    }
                    .buttonStyle(PressableStyle())

                    // Card 2 — Wishlist Intelligence
                    NavigationLink(value: InsightRoute.wishlist) {
                        mainCard(
                            title: "Wishlist Intelligence",
                            subtitle: "Track desired purchases, target prices, and the best financial time to buy.",
                            symbol: "heart.text.square.fill",
                            colors: [Color(hex: 0x0EA5A4), Color(hex: 0x22A565)],
                            badgeText: badges.wishlistBadge,
                            badgeColor: badges.wishlistHasReady ? Theme.positive : Theme.cobalt
                        )
                    }
                    .buttonStyle(PressableStyle())

                    // Card 3 — Insights & Alerts
                    NavigationLink(value: InsightRoute.alerts) {
                        mainCard(
                            title: "Insights & Alerts",
                            subtitle: "Priority financial risks, budget warnings, bill reminders, and opportunities.",
                            symbol: "bell.badge.waveform.fill",
                            colors: [Color(hex: 0xF08A24), Color(hex: 0xEC4899)],
                            badgeText: badges.alertsBadge,
                            badgeColor: badges.alertsHasCritical ? Theme.negative : (badges.alertsUnreadCount > 0 ? Theme.warning : Theme.positive)
                        )
                    }
                    .buttonStyle(PressableStyle())
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 28)
            }
            .canvasBackground()
            .navigationTitle("Insights")
            .navigationBarTitleDisplayMode(.inline)
            .task(id: summaryKey) {
                recomputeSummaryBadges()
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    DrawerMenuToolbarButtons()
                }
            }
            .navigationDestination(for: InsightRoute.self) { route in
                switch route {
                case .timeMachine:
                    TimeMachineDashboardView(onNavigate: { path.append($0) })
                case .wishlist:
                    WishlistDashboardView(onSimulateBuyNow: { amount, name in
                        path.append(InsightRoute.buyNow(amount: amount, name: name))
                    })
                case .alerts:
                    InsightsAlertsCenterView(onAction: handleAlertAction)
                case .buyNow(let amount, let name):
                    BuyNowSimulationView(initialAmount: amount, initialName: name)
                case .savingGoal:
                    SavingGoalSimulationView()
                case .bills:
                    BillsView()
                }
            }
        }
    }

    private func handleAlertAction(_ action: FinancialAlertAction) {
        switch action {
        case .openTimeMachine:
            path.append(InsightRoute.timeMachine)
        case .openBuyNow(let amount, let name):
            path.append(InsightRoute.buyNow(amount: amount, name: name))
        case .openWishlist:
            path.append(InsightRoute.wishlist)
        case .openBills:
            path.append(InsightRoute.bills)
        case .openBudgets:
            appState.tab = .budgets
        case .openTransactions:
            appState.tab = .transactions
        case .openAccounts:
            appState.tab = .accounts
        }
    }

    private func mainCard(
        title: String,
        subtitle: String,
        symbol: String,
        colors: [Color],
        badgeText: String,
        badgeColor: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .background(
                        LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: RoundedRectangle(cornerRadius: 15, style: .continuous)
                    )

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(Theme.ink)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryInk)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }

            HStack {
                Text(badgeText)
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(badgeColor.opacity(0.14), in: Capsule())
                    .foregroundStyle(badgeColor)
                Spacer()
            }
        }
        .card()
        .accessibilityElement(children: .combine)
    }
}

extension SimulationStatus {
    var color: Color {
        switch self {
        case .safe: return Theme.positive
        case .caution: return Theme.warning
        case .risk: return Theme.negative
        }
    }

    var symbol: String {
        switch self {
        case .safe: return "checkmark.seal.fill"
        case .caution: return "exclamationmark.triangle.fill"
        case .risk: return "xmark.octagon.fill"
        }
    }
}
