import SwiftUI
import SwiftData

// MARK: - Insights & Alerts Center (Card 3)

struct InsightsAlertsCenterView: View {
    var onAction: (FinancialAlertAction) -> Void

    @Query(sort: \MoneyTransaction.date, order: .reverse) private var transactions: [MoneyTransaction]
    @Query(sort: \Account.createdAt) private var accounts: [Account]
    @Query private var budgets: [Budget]
    @Query private var goals: [SavingsGoal]
    @Query(sort: \Bill.nextDueDate) private var bills: [Bill]
    @AppStorage(Keys.currency) private var currency = "BHD"

    @State private var showPrevious = false

    private let stateStore = FinancialAlertStateStore.shared
    private let wishlistStore = WishlistStore.shared

    var body: some View {
        let f = Finance(transactions: transactions, accounts: accounts, budgets: budgets, goals: goals, bills: bills)
        let projection = FinancialProjectionEngine.project(finance: f, period: .threeMonths, currency: currency)
        let generated = FinancialAlertsEngine.generate(
            finance: f,
            projection: projection,
            wishlistItems: wishlistStore.items,
            currency: currency
        )
        let activeAlerts = generated.filter { !stateStore.isDismissed($0.id) }
        let previousAlerts = stateStore.archivedAlerts

        ScrollView {
            VStack(spacing: 14) {
                Picker("View", selection: $showPrevious) {
                    Text("Active (\(activeAlerts.count))").tag(false)
                    Text("Previous (\(previousAlerts.count))").tag(true)
                }
                .pickerStyle(.segmented)

                let displayed = showPrevious ? previousAlerts : activeAlerts
                if displayed.isEmpty {
                    ContentUnavailableView(
                        showPrevious ? "No Previous Alerts" : "You're All Caught Up",
                        systemImage: showPrevious ? "clock.arrow.circlepath" : "checkmark.seal.fill",
                        description: Text(showPrevious
                            ? "Alerts you mark as read or dismiss appear here so you can review them later."
                            : "No urgent financial risks, budget warnings, or bill alerts right now.")
                    )
                    .padding(.top, 44)
                } else {
                    ForEach(displayed) { alert in
                        alertCard(alert, isHistory: showPrevious)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 28)
        }
        .canvasBackground()
        .navigationTitle("Insights & Alerts")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
    }

    private func alertCard(_ alert: FinancialAlert, isHistory: Bool) -> some View {
        let isRead = stateStore.isRead(alert.id)
        let tint = priorityColor(alert.priority)

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                IconBadge(symbol: alert.category.symbol, color: tint, size: 36)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        if !isRead && !isHistory {
                            Circle().fill(tint).frame(width: 7, height: 7)
                        }
                        Text(alert.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.ink)
                        Spacer()
                        Text(alert.priority.rawValue)
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(tint.opacity(0.14), in: Capsule())
                            .foregroundStyle(tint)
                    }

                    Text(alert.explanation)
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 10) {
                if let amt = alert.amount, amt > 0 {
                    Text(Money.format(amt, currency))
                        .font(.caption.weight(.bold).monospacedDigit())
                        .foregroundStyle(Theme.ink)
                }
                Text(alert.timeframe)
                    .font(.caption2)
                    .foregroundStyle(Theme.secondaryInk)
                Spacer()
            }

            Text(alert.recommendedAction)
                .font(.caption)
                .foregroundStyle(Theme.ink)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.track.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            HStack(spacing: 8) {
                Button {
                    stateStore.markRead(alert)
                    onAction(alert.action)
                } label: {
                    Text(alert.action.buttonTitle)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Theme.cobalt, in: Capsule())
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)

                Spacer()

                if isHistory {
                    if stateStore.isDismissed(alert.id) {
                        Button("Restore") {
                            stateStore.restore(alert.id)
                        }
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Theme.cobalt)
                        .buttonStyle(.plain)
                    }
                } else {
                    if !isRead {
                        Button("Mark Read") {
                            stateStore.markRead(alert)
                        }
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Theme.secondaryInk)
                        .buttonStyle(.plain)
                    }
                    Button("Dismiss") {
                        withAnimation(.snappy) {
                            stateStore.dismiss(alert)
                        }
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Theme.negative)
                    .buttonStyle(.plain)
                }
            }
        }
        .opacity(isRead && !isHistory ? 0.80 : 1.0)
        .card(padding: 14)
    }

    private func priorityColor(_ priority: FinancialAlertPriority) -> Color {
        switch priority {
        case .critical: return Theme.negative
        case .high: return Theme.warning
        case .medium: return Theme.cobalt
        case .low: return Theme.positive
        }
    }
}
