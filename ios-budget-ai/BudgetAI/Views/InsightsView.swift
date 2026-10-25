import SwiftUI
import SwiftData
import Charts

struct InsightsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var context
    @Query(sort: \MoneyTransaction.date, order: .reverse) private var transactions: [MoneyTransaction]
    @Query private var accounts: [Account]
    @Query private var budgets: [Budget]
    @Query private var goals: [SavingsGoal]
    @Query(sort: \Bill.nextDueDate) private var bills: [Bill]
    @AppStorage(Keys.currency) private var currency = "BHD"
    @AppStorage("aiFindingsCache") private var findingsCache: Data = Data()
    @AppStorage("aiFindingsDate") private var findingsDate: Double = 0
    @State private var aiFindings: [AIFinding] = []
    @State private var loadingAI = false
    @State private var aiError: String?
    @State private var lastMonthView = false
    @State private var selectedFinding: AIFinding?

    private var finance: Finance {
        Finance(transactions: transactions, accounts: accounts, budgets: budgets, goals: goals, bills: bills)
    }

    var body: some View {
        let f = finance
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    Text("Smarter money decisions for you")
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondaryInk)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                        .padding(.top, -8)
                    forecastCard(f)
                    findingsCard(f)
                    categoryCard(f)
                    trendCard(f)
                    billsCard(f)
                    recurringCard(f)
                    advisorButton
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .canvasBackground()
            .navigationTitle("Insights")
            .navigationDestination(for: InsightRoute.self) { route in
                switch route {
                case .advisor: AdvisorChatView()
                case .bills: BillsView()
                }
            }
            .task { await loadFindings(force: false) }
            .sheet(item: $selectedFinding) { finding in
                FindingSheet(finding: finding)
            }
        }
    }

    // MARK: Forecast

    private func forecastCard(_ f: Finance) -> some View {
        let series = f.balanceSeries()
        let today = Calendar.current.startOfDay(for: .now)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("End-of-month forecast").font(.subheadline.weight(.medium)).foregroundStyle(Theme.ink)
                Spacer()
                Text(Date.now.formatted(.dateTime.month(.abbreviated).year()))
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Theme.track.opacity(0.7), in: Capsule())
                    .foregroundStyle(Theme.secondaryInk)
            }
            Text(Money.format(f.forecastEndOfMonth, currency))
                .font(.system(size: 34, weight: .bold).monospacedDigit())
                .foregroundStyle(Theme.ink)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            Text(f.projectedSavings >= 0 ? "On track to save \(Money.format(f.projectedSavings, currency))" : "Projected to overspend by \(Money.format(-f.projectedSavings, currency))")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(f.projectedSavings >= 0 ? Theme.positive : Theme.negative)
            Chart {
                ForEach(series.actual) { p in
                    AreaMark(x: .value("Day", p.date, unit: .day), y: .value("Balance", p.value), series: .value("Kind", "Actual"))
                        .interpolationMethod(.catmullRom)
                        .foregroundStyle(LinearGradient(colors: [Theme.cobalt.opacity(0.16), Theme.cobalt.opacity(0.01)], startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("Day", p.date, unit: .day), y: .value("Balance", p.value), series: .value("Kind", "Actual"))
                        .interpolationMethod(.catmullRom)
                        .foregroundStyle(Theme.cobalt)
                        .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                }
                ForEach(series.projected) { p in
                    LineMark(x: .value("Day", p.date, unit: .day), y: .value("Balance", p.value), series: .value("Kind", "Forecast"))
                        .interpolationMethod(.catmullRom)
                        .foregroundStyle(Theme.cobalt.opacity(0.7))
                        .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: [5, 5]))
                }
                RuleMark(x: .value("Today", today, unit: .day))
                    .foregroundStyle(Theme.ink.opacity(0.2))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .annotation(position: .top, alignment: .center) {
                        Text("Today").font(.caption2).foregroundStyle(Theme.secondaryInk)
                    }
                if let last = series.actual.last {
                    PointMark(x: .value("Day", last.date, unit: .day), y: .value("Balance", last.value))
                        .foregroundStyle(Theme.cobalt)
                        .symbolSize(70)
                }
            }
            .chartYScale(domain: .automatic(includesZero: false))
            .chartYAxis {
                AxisMarks(position: .trailing) { v in
                    AxisGridLine().foregroundStyle(Theme.track)
                    AxisValueLabel { if let d = v.as(Double.self) { Text(Money.short(d)) } }
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                    AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                }
            }
            .frame(height: 150)
            .padding(.top, 8)
        }
        .card()
    }

    // MARK: Findings

    private func findingsCard(_ f: Finance) -> some View {
        let items = aiFindings.isEmpty ? AIService.localFindings(f) : aiFindings
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.cobalt)
                    .frame(width: 30, height: 30)
                    .background(Theme.cobaltSoft, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .symbolEffect(.pulse, isActive: loadingAI)
                Text(aiFindings.isEmpty ? "Findings for you" : "AI findings for you").font(.headline).foregroundStyle(Theme.ink)
                Spacer()
                if GeminiAccount.isConfigured {
                    Button {
                        Task { await loadFindings(force: true) }
                    } label: {
                        if loadingAI { ProgressView() } else { Image(systemName: "arrow.clockwise") }
                    }
                    .disabled(loadingAI)
                    .accessibilityLabel("Refresh AI findings")
                }
            }
            if items.isEmpty {
                Text("Add a few transactions and we'll start spotting patterns.")
                    .font(.subheadline).foregroundStyle(Theme.secondaryInk)
            }
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                Button { selectedFinding = item } label: {
                    HStack(spacing: 12) {
                        IconBadge(symbol: item.symbol, color: color(for: item.kind), size: 38)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title).font(.subheadline.weight(.medium)).foregroundStyle(Theme.ink).multilineTextAlignment(.leading)
                            Text(item.detail).font(.caption).foregroundStyle(Theme.secondaryInk).lineLimit(2).multilineTextAlignment(.leading)
                        }
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
                if index < items.count - 1 { Divider().padding(.leading, 50) }
            }
            if let aiError {
                Text(aiError).font(.caption).foregroundStyle(Theme.negative)
            }
            if !GeminiAccount.isConfigured {
                GeminiConnectCard().padding(.top, 4)
            }
        }
        .card()
        .animation(.spring(response: 0.5, dampingFraction: 0.85), value: aiFindings)
    }

    private func color(for kind: String) -> Color {
        switch kind {
        case "warning": Theme.negative
        case "positive": Theme.positive
        case "saving": Theme.warning
        default: Theme.cobalt
        }
    }

    // MARK: Categories & trend

    private func categoryCard(_ f: Finance) -> some View {
        let items = Array(f.categoryBreakdown(in: lastMonthView ? f.lastMonth : f.thisMonth).prefix(6))
        let maxValue = items.first?.amount ?? 1
        return VStack(alignment: .leading, spacing: 14) {
            SectionTitle(title: "Spending by category") {
                Menu {
                    Picker("Period", selection: $lastMonthView) {
                        Text("This month").tag(false)
                        Text("Last month").tag(true)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(lastMonthView ? "Last month" : "This month")
                        Image(systemName: "chevron.down").font(.caption2.weight(.bold))
                    }
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Theme.track.opacity(0.7), in: Capsule())
                    .foregroundStyle(Theme.secondaryInk)
                }
            }
            if items.isEmpty {
                Text("No spending yet in this period.").font(.subheadline).foregroundStyle(Theme.secondaryInk)
            }
            ForEach(items, id: \.category) { item in
                HStack(spacing: 12) {
                    CategoryIcon(category: item.category, size: 30)
                    Text(item.category.shortTitle).font(.subheadline).foregroundStyle(Theme.ink).frame(width: 96, alignment: .leading)
                    ProgressBar(progress: item.amount / maxValue, color: Theme.cobalt, height: 9)
                    Text(Money.short(item.amount)).font(.subheadline.weight(.medium).monospacedDigit()).foregroundStyle(Theme.ink)
                        .frame(width: 48, alignment: .trailing)
                }
            }
        }
        .card()
    }

    private func trendCard(_ f: Finance) -> some View {
        let totals = f.monthlyTotals(months: 6)
        return VStack(alignment: .leading, spacing: 12) {
            SectionTitle("Income vs spending")
            Chart {
                ForEach(totals) { t in
                    BarMark(x: .value("Month", t.month, unit: .month), y: .value("Amount", t.income))
                        .foregroundStyle(by: .value("Type", "Income"))
                        .position(by: .value("Type", "Income"))
                        .cornerRadius(5)
                    BarMark(x: .value("Month", t.month, unit: .month), y: .value("Amount", t.expenses))
                        .foregroundStyle(by: .value("Type", "Spending"))
                        .position(by: .value("Type", "Spending"))
                        .cornerRadius(5)
                }
            }
            .chartForegroundStyleScale(["Income": Theme.positive, "Spending": Theme.cobalt])
            .chartLegend(position: .top, alignment: .leading)
            .chartYAxis {
                AxisMarks(position: .trailing) { v in
                    AxisGridLine().foregroundStyle(Theme.track)
                    AxisValueLabel { if let d = v.as(Double.self) { Text(Money.short(d)) } }
                }
            }
            .chartXAxis { AxisMarks(values: .stride(by: .month)) { _ in AxisValueLabel(format: .dateTime.month(.abbreviated)) } }
            .frame(height: 170)
        }
        .card()
    }

    private func billsCard(_ f: Finance) -> some View {
        NavigationLink(value: InsightRoute.bills) {
            HStack(spacing: 12) {
                IconBadge(symbol: "repeat", color: Theme.negative)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Bills & subscriptions").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
                    Text("\(Money.format(f.billsMonthly, currency))/mo · subscriptions \(Money.format(f.subscriptionsMonthly, currency))/mo")
                        .font(.caption.monospacedDigit()).foregroundStyle(Theme.secondaryInk)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .card()
        }
        .buttonStyle(PressableStyle())
    }

    @ViewBuilder
    private func recurringCard(_ f: Finance) -> some View {
        let candidates = f.recurringCandidates()
        if !candidates.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle("Recurring payments detected")
                ForEach(candidates) { c in
                    HStack(spacing: 12) {
                        CategoryIcon(category: c.category, size: 38)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.name).font(.subheadline.weight(.medium)).foregroundStyle(Theme.ink)
                            Text("~\(Money.format(c.amount, currency)) monthly · \(c.occurrences) payments").font(.caption).foregroundStyle(Theme.secondaryInk)
                        }
                        Spacer()
                        Button("Track") { track(c) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
            }
            .card()
        }
    }

    private var advisorButton: some View {
        NavigationLink(value: InsightRoute.advisor) {
            HStack(spacing: 12) {
                IconBadge(symbol: "sparkles", color: Theme.cobalt)
                Text("Ask your advisor anything…").font(.body).foregroundStyle(Theme.secondaryInk)
                Spacer()
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .card()
        }
        .buttonStyle(PressableStyle())
    }

    // MARK: Actions

    private func track(_ c: RecurringCandidate) {
        let next = Calendar.current.date(byAdding: .month, value: 1, to: c.lastDate) ?? .now
        let bill = Bill(name: c.name, amount: (c.amount * 1000).rounded() / 1000, category: c.category, nextDueDate: next,
                        isSubscription: c.category == .subscriptions || c.category == .entertainment)
        context.insert(bill)
        try? context.save()
        Notifier.rescheduleBills(bills + [bill])
        appState.show("\(c.name) added to bills")
    }

    private func loadFindings(force: Bool) async {
        if aiFindings.isEmpty, let cached = try? JSONDecoder().decode([AIFinding].self, from: findingsCache) {
            aiFindings = cached
        }
        guard GeminiAccount.isConfigured, !transactions.isEmpty else { return }
        let fresh = Date().timeIntervalSince1970 - findingsDate < 60 * 60 * 6
        if !force && fresh && !aiFindings.isEmpty { return }
        loadingAI = true
        aiError = nil
        defer { loadingAI = false }
        do {
            let ctx = AIService.financialContext(finance, transactions: transactions)
            let result = try await AIService.findings(context: ctx)
            if !result.isEmpty {
                aiFindings = result
                findingsCache = (try? JSONEncoder().encode(result)) ?? Data()
                findingsDate = Date().timeIntervalSince1970
            }
        } catch {
            aiError = error.localizedDescription
        }
    }
}

enum InsightRoute: Hashable { case advisor, bills }

struct FindingSheet: View {
    let finding: AIFinding
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                IconBadge(symbol: finding.symbol, color: Theme.cobalt, size: 56)
                Text(finding.title).font(.title2.bold()).foregroundStyle(Theme.ink)
                Text(finding.detail).font(.body).foregroundStyle(Theme.secondaryInk)
                Spacer()
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium])
    }
}
