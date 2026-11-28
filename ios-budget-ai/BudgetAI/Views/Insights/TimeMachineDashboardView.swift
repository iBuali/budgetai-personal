import SwiftUI
import SwiftData
import Charts

// MARK: - Time Machine Main Screen (Forecast, Graph, Events, FALAK Insight, Buy Now?, Saving Goal)

struct TimeMachineDashboardView: View {
    var onNavigate: (InsightRoute) -> Void

    @Query(sort: \MoneyTransaction.date, order: .reverse) private var transactions: [MoneyTransaction]
    @Query(sort: \Account.createdAt) private var accounts: [Account]
    @Query private var budgets: [Budget]
    @Query private var goals: [SavingsGoal]
    @Query(sort: \Bill.nextDueDate) private var bills: [Bill]
    @AppStorage(Keys.currency) private var currency = "BHD"

    @State private var period: ForecastPeriod = .threeMonths
    @State private var selectedAccountID: UUID? = nil
    @State private var selectedDate: Date? = nil
    @State private var selectedGroup: FinancialEventGroup? = nil
    @State private var aiInsight: PrimaryForecastInsight? = nil
    @State private var loadingAI = false

    private var selectableAccounts: [Account] {
        let liquid = accounts.filter { $0.kind.isLiquid }
        return liquid.isEmpty ? accounts : liquid
    }

    private var activeAccount: Account? {
        if let id = selectedAccountID, let match = accounts.first(where: { $0.id == id }) {
            return match
        }
        return selectableAccounts.first(where: { $0.kind == .bank }) ?? selectableAccounts.first
    }

    private var finance: Finance {
        if let account = activeAccount {
            return FinancialProjectionEngine.scopedFinance(
                for: account,
                transactions: transactions,
                accounts: accounts,
                budgets: budgets,
                goals: goals,
                bills: bills
            )
        }
        return Finance(transactions: transactions, accounts: accounts, budgets: budgets, goals: goals, bills: bills)
    }

    var body: some View {
        let f = finance
        let projection = FinancialProjectionEngine.project(finance: f, period: period, currency: currency)
        let eventGroups = FinancialProjectionEngine.groupEvents(projection.events, period: period)
        let activeInsight = aiInsight ?? projection.primaryInsight

        ScrollView {
            VStack(spacing: 16) {
                if !selectableAccounts.isEmpty {
                    accountPicker
                }
                periodPicker
                heroSummaryCard(projection)
                projectionGraphCard(projection, eventGroups: eventGroups)
                falakInsightCard(activeInsight, projection: projection)
                simulationsSection
                upcomingEventsCard(projection, eventGroups: eventGroups)
                if !projection.missingData.isEmpty || !projection.assumptions.isEmpty {
                    assumptionsCard(projection)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 28)
        }
        .canvasBackground()
        .navigationTitle("FALAK Time Machine")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .onAppear {
            if selectedAccountID == nil {
                selectedAccountID = activeAccount?.id
            }
        }
        .sheet(item: $selectedGroup) { group in
            ProjectionEventGroupSheet(group: group, currency: currency)
        }
        .task(id: "\(period.rawValue)-\(activeAccount?.id.uuidString ?? "all")-\(transactions.count)-\(bills.count)-\(accounts.count)") {
            aiInsight = nil
            selectedDate = nil
            guard projection.hasSufficientData, GeminiAccount.isConfigured else { return }
            loadingAI = true
            let enhanced = await InsightsAIService.enhanceForecastInsight(projection: projection, currency: currency)
            if !Task.isCancelled {
                aiInsight = enhanced
                loadingAI = false
            }
        }
        .sensoryFeedback(.selection, trigger: period)
    }

    // MARK: Account Selector (Single Account at a Time)

    private var accountPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(selectableAccounts) { acc in
                    let isSelected = activeAccount?.id == acc.id
                    Button {
                        withAnimation(.snappy(duration: 0.22)) {
                            selectedAccountID = acc.id
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: acc.kind.symbol)
                                .font(.caption.weight(.semibold))
                            Text(acc.name)
                                .font(.caption.weight(.semibold))
                                .lineLimit(1)
                            Text(Money.format(acc.balance, currency))
                                .font(.caption2.monospacedDigit())
                                .opacity(isSelected ? 0.9 : 0.7)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(isSelected ? Theme.cobalt : Theme.card, in: Capsule())
                        .foregroundStyle(isSelected ? .white : Theme.ink)
                        .overlay(
                            Capsule().stroke(isSelected ? Color.clear : Theme.track, lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 2)
        }
    }

    // MARK: Period Selector

    private var periodPicker: some View {
        Picker("Forecast Period", selection: $period) {
            ForEach(ForecastPeriod.allCases) { p in
                Text(p.title).tag(p)
            }
        }
        .pickerStyle(.segmented)
    }

    // MARK: Hero Summary

    private func heroSummaryCard(_ p: FinancialProjectionResult) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Projected in \(p.period.title)")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.secondaryInk)
                Spacer()
                Text(p.uncertainty.title)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Theme.track, in: Capsule())
                    .foregroundStyle(Theme.secondaryInk)
            }

            Text(Money.format(p.projectedEndBalance, currency))
                .font(.system(size: 32, weight: .bold).monospacedDigit())
                .foregroundStyle(p.projectedEndBalance < 0 ? Theme.negative : Theme.ink)
                .animatedNumber(p.projectedEndBalance)

            HStack(spacing: 12) {
                Label(
                    Money.format(p.netChange, currency, signed: true),
                    systemImage: p.netChange >= 0 ? "arrow.up.right" : "arrow.down.right"
                )
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(p.netChange >= 0 ? Theme.positive : Theme.negative)

                Text("·")
                    .foregroundStyle(Theme.secondaryInk)

                Text("Now \(Money.format(p.startingBalance, currency))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Theme.secondaryInk)
            }

            Divider()

            HStack(spacing: 12) {
                miniStat("Est. Income/mo", value: Money.format(p.expectedMonthlyIncome, currency), color: Theme.positive)
                miniStat("Est. Outflow/mo", value: Money.format(p.expectedMonthlyExpenses, currency), color: Theme.ink)
                miniStat("Lowest Point", value: Money.format(p.lowestBalance, currency), color: p.lowestBalance < 0 ? Theme.negative : Theme.cobalt)
            }
        }
        .card()
    }

    private func miniStat(_ label: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(Theme.secondaryInk)
                .lineLimit(1)
            Text(value)
                .font(.caption.weight(.bold).monospacedDigit())
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Interactive Projection Graph with Actual vs Projected & Event Markers

    private func projectionGraphCard(_ p: FinancialProjectionResult, eventGroups: [FinancialEventGroup]) -> some View {
        let markerGroups = Array(eventGroups.prefix(14))
        let scrubbedPoint: ProjectionTimelinePoint? = {
            guard let sel = selectedDate else { return nil }
            let all = p.actualPoints + p.projectedPoints
            return all.min(by: { abs($0.date.timeIntervalSince(sel)) < abs($1.date.timeIntervalSince(sel)) })
        }()

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Balance Projection")
                        .font(.headline)
                        .foregroundStyle(Theme.ink)
                    if let pt = scrubbedPoint {
                        Text("\(pt.isActual ? "Actual" : "Projected") · \(pt.date.formatted(.dateTime.month(.abbreviated).day().year()))")
                            .font(.caption)
                            .foregroundStyle(Theme.cobalt)
                    } else {
                        Text("Drag across the chart to inspect dates")
                            .font(.caption)
                            .foregroundStyle(Theme.secondaryInk)
                    }
                }
                Spacer()
                if let pt = scrubbedPoint {
                    Text(Money.format(pt.balance, currency))
                        .font(.subheadline.weight(.bold).monospacedDigit())
                        .foregroundStyle(pt.balance < 0 ? Theme.negative : Theme.ink)
                }
            }

            if !p.hasSufficientData && p.startingBalance == 0 && p.events.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "chart.xyaxis.line")
                        .font(.title2)
                        .foregroundStyle(Theme.secondaryInk)
                    Text("Not enough financial data yet")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Theme.ink)
                    Text("Add accounts, bills, or recent transactions to see your projected balance.")
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryInk)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 180)
            } else {
                Chart {
                    // Actual balance line (solid)
                    ForEach(p.actualPoints) { pt in
                        LineMark(
                            x: .value("Date", pt.date),
                            y: .value("Balance", pt.balance),
                            series: .value("Series", "Actual")
                        )
                        .foregroundStyle(Theme.ink)
                        .lineStyle(StrokeStyle(lineWidth: 2.5))
                        .interpolationMethod(.catmullRom)
                    }

                    // Projected balance area + dashed line
                    ForEach(p.projectedPoints) { pt in
                        AreaMark(
                            x: .value("Date", pt.date),
                            y: .value("Balance", pt.balance)
                        )
                        .foregroundStyle(
                            LinearGradient(
                                colors: [Theme.cobalt.opacity(0.22), Theme.cobalt.opacity(0.01)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .interpolationMethod(.catmullRom)

                        LineMark(
                            x: .value("Date", pt.date),
                            y: .value("Balance", pt.balance),
                            series: .value("Series", "Projected")
                        )
                        .foregroundStyle(p.lowestBalance < 0 ? Theme.warning : Theme.cobalt)
                        .lineStyle(StrokeStyle(lineWidth: 2.5, dash: [6, 4]))
                        .interpolationMethod(.catmullRom)
                    }

                    // Zero line when balance dips near or below zero
                    if p.lowestBalance <= 0 {
                        RuleMark(y: .value("Zero", 0))
                            .foregroundStyle(Theme.negative.opacity(0.5))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    }

                    // Grouped event category icons plotted on the projected curve (daily for 1M, weekly for 3M/6M/1Y)
                    ForEach(markerGroups) { grp in
                        if let nearest = p.projectedPoints.min(by: { abs($0.date.timeIntervalSince(grp.bucketDate)) < abs($1.date.timeIntervalSince(grp.bucketDate)) }) {
                            PointMark(
                                x: .value("Date", grp.bucketDate),
                                y: .value("Balance", nearest.balance)
                            )
                            .symbol {
                                ZStack {
                                    Circle()
                                        .fill(eventColor(grp.primaryKind))
                                        .frame(width: 22, height: 22)
                                        .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                                    Image(systemName: grp.symbol)
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundStyle(.white)
                                }
                            }
                        }
                    }

                    if let pt = scrubbedPoint {
                        RuleMark(x: .value("Selected", pt.date))
                            .foregroundStyle(Theme.cobalt.opacity(0.45))
                            .lineStyle(StrokeStyle(lineWidth: 1.2))
                        PointMark(x: .value("Selected", pt.date), y: .value("Balance", pt.balance))
                            .symbolSize(70)
                            .foregroundStyle(Theme.cobalt)
                    }
                }
                .chartXSelection(value: $selectedDate)
                .chartYAxis {
                    AxisMarks(position: .trailing) { v in
                        AxisGridLine().foregroundStyle(Theme.track)
                        AxisValueLabel {
                            if let d = v.as(Double.self) {
                                Text(Money.short(d))
                            }
                        }
                    }
                }
                .frame(height: 220)
                .animation(.snappy(duration: 0.28), value: period)

                // Legend distinguishing Actual vs Projected
                HStack(spacing: 16) {
                    HStack(spacing: 6) {
                        Capsule().fill(Theme.ink).frame(width: 16, height: 3)
                        Text("Actual").font(.caption2).foregroundStyle(Theme.secondaryInk)
                    }
                    HStack(spacing: 6) {
                        Capsule().fill(Theme.cobalt).frame(width: 16, height: 3)
                        Text("Projected").font(.caption2).foregroundStyle(Theme.secondaryInk)
                    }
                    Spacer()
                    if !markerGroups.isEmpty {
                        Text("\(eventGroups.count) groups · \(period == .oneMonth ? "Daily" : "Weekly")")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(Theme.secondaryInk)
                    }
                }
            }
        }
        .card()
    }

    // MARK: FALAK Insight Primary Card

    private func falakInsightCard(_ insight: PrimaryForecastInsight, projection: FinancialProjectionResult) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                IconBadge(symbol: insight.isAIEnhanced ? "sparkles" : insight.severity.symbol, color: insight.severity.color, size: 32)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text("FALAK Insight")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(insight.severity.color)
                        if loadingAI {
                            ProgressView().scaleEffect(0.65)
                        } else if insight.isAIEnhanced {
                            Text("AI")
                                .font(.caption2.weight(.bold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Theme.cobalt.opacity(0.15), in: Capsule())
                                .foregroundStyle(Theme.cobalt)
                        }
                    }
                    Text(insight.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.ink)
                }
                Spacer()
            }

            VStack(alignment: .leading, spacing: 6) {
                insightLine("What", text: insight.what)
                insightLine("Why", text: insight.why)
                insightLine("When", text: insight.when)
                insightLine("Next step", text: insight.action, highlight: true)
            }
        }
        .card()
    }

    private func insightLine(_ label: String, text: String, highlight: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.caption2.weight(.bold))
                .foregroundStyle(highlight ? Theme.cobalt : Theme.secondaryInk)
                .frame(width: 60, alignment: .leading)
            Text(text)
                .font(.caption)
                .foregroundStyle(highlight ? Theme.ink : Theme.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Sub-features Inside Time Machine (Buy Now? & Saving Goal)

    private var simulationsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Simulate Before You Decide")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.secondaryInk)
                .padding(.horizontal, 4)

            HStack(spacing: 12) {
                Button {
                    onNavigate(.buyNow(amount: 0, name: ""))
                } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        IconBadge(symbol: "cart.badge.questionmark", color: Theme.cobalt, size: 36)
                        Text("Buy Now?")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.ink)
                        Text("Test a purchase against your budget, bills & goals")
                            .font(.caption2)
                            .foregroundStyle(Theme.secondaryInk)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .card(padding: 14)
                }
                .buttonStyle(PressableStyle())

                Button {
                    onNavigate(.savingGoal)
                } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        IconBadge(symbol: "target", color: Theme.positive, size: 36)
                        Text("Saving Goal")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.ink)
                        Text("Check if a goal is achievable in your timeframe")
                            .font(.caption2)
                            .foregroundStyle(Theme.secondaryInk)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .card(padding: 14)
                }
                .buttonStyle(PressableStyle())
            }
        }
    }

    // MARK: Interactive Upcoming Financial Events List

    private func upcomingEventsCard(_ p: FinancialProjectionResult, eventGroups: [FinancialEventGroup]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Upcoming Financial Events")
                        .font(.headline)
                        .foregroundStyle(Theme.ink)
                    Text(period == .oneMonth ? "Grouped by category per day" : "Grouped by category per week")
                        .font(.caption2)
                        .foregroundStyle(Theme.secondaryInk)
                }
                Spacer()
                Text("\(eventGroups.count)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.secondaryInk)
            }

            if eventGroups.isEmpty {
                Text("No scheduled bills, installments, or upcoming events found for this account in this period.")
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryInk)
            } else {
                ForEach(eventGroups.prefix(15)) { grp in
                    Button {
                        selectedGroup = grp
                    } label: {
                        HStack(spacing: 10) {
                            IconBadge(symbol: grp.symbol, color: eventColor(grp.primaryKind), size: 32)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(grp.title)
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(Theme.ink)
                                        .lineLimit(1)
                                    if grp.events.count > 1 {
                                        Text("\(grp.events.count)")
                                            .font(.caption2.weight(.bold).monospacedDigit())
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 1)
                                            .background(Theme.track, in: Capsule())
                                            .foregroundStyle(Theme.secondaryInk)
                                    }
                                }
                                Text(grp.dateLabel)
                                    .font(.caption2)
                                    .foregroundStyle(Theme.secondaryInk)
                            }
                            Spacer()
                            if grp.totalAmount > 0 {
                                Text(Money.format(grp.totalSignedImpact != 0 ? grp.totalSignedImpact : grp.totalAmount, currency, signed: grp.totalSignedImpact != 0))
                                    .font(.subheadline.weight(.semibold).monospacedDigit())
                                    .foregroundStyle(grp.totalSignedImpact > 0 ? Theme.positive : Theme.ink)
                            } else {
                                Text("Plan")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(Theme.secondaryInk)
                            }
                        }
                        .padding(.vertical, 2)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .card()
    }

    private func assumptionsCard(_ p: FinancialProjectionResult) -> some View {
        DisclosureGroup("Forecast Assumptions & Data Notes") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(p.assumptions, id: \.self) { a in
                    Label(a, systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryInk)
                }
                ForEach(p.missingData, id: \.self) { m in
                    Label(m, systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(Theme.warning)
                }
            }
            .padding(.top, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.subheadline.weight(.medium))
        .foregroundStyle(Theme.ink)
        .card()
    }

    private func eventColor(_ kind: ProjectionEventKind) -> Color {
        switch kind {
        case .expectedIncome: return Theme.positive
        case .upcomingBill, .loanInstallment, .scheduledExpense: return Theme.negative
        case .plannedSavings, .goalDeadline: return Theme.cobalt
        case .recurringExpense: return Theme.warning
        case .seasonalRamadan, .seasonalEid: return Color(hex: 0x8B5CF6)
        }
    }
}

// MARK: - Grouped Event Detail Sheet

private struct ProjectionEventGroupSheet: View {
    let group: FinancialEventGroup
    let currency: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Category", value: group.title)
                    LabeledContent(group.isWeeklyBucket ? "Week" : "Date", value: group.dateLabel)
                    LabeledContent("Events", value: "\(group.events.count)")
                    if group.totalAmount > 0 {
                        LabeledContent("Total Impact") {
                            Text(Money.format(group.totalSignedImpact != 0 ? group.totalSignedImpact : group.totalAmount, currency, signed: group.totalSignedImpact != 0))
                                .fontWeight(.semibold)
                                .foregroundStyle(group.totalSignedImpact > 0 ? Theme.positive : Theme.negative)
                        }
                    }
                }
                Section("Included Events") {
                    ForEach(group.events) { ev in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(ev.title)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(Theme.ink)
                                Spacer()
                                if ev.amount > 0 {
                                    Text(Money.format(ev.signedImpact != 0 ? ev.signedImpact : ev.amount, currency, signed: ev.signedImpact != 0))
                                        .font(.subheadline.weight(.semibold).monospacedDigit())
                                        .foregroundStyle(ev.signedImpact > 0 ? Theme.positive : Theme.ink)
                                }
                            }
                            Text("\(ev.date.formatted(.dateTime.month(.abbreviated).day().year())) · \(ev.kind.title)")
                                .font(.caption2)
                                .foregroundStyle(Theme.secondaryInk)
                            if !ev.explanation.isEmpty {
                                Text(ev.explanation)
                                    .font(.caption)
                                    .foregroundStyle(Theme.secondaryInk)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .canvasBackground()
            .navigationTitle(group.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Event Detail Sheet

private struct ProjectionEventDetailSheet: View {
    let event: FinancialProjectionEvent
    let currency: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Event", value: event.title)
                    LabeledContent("Type", value: event.kind.title)
                    LabeledContent("Date", value: event.date.formatted(date: .complete, time: .omitted))
                    if event.amount > 0 {
                        LabeledContent("Amount", value: Money.format(event.amount, currency))
                    }
                    if let acc = event.accountOrCategory {
                        LabeledContent("Account / Category", value: acc)
                    }
                    LabeledContent("Projection Effect") {
                        if event.signedImpact > 0 {
                            Text("Increases balance by \(Money.format(event.signedImpact, currency))")
                                .foregroundStyle(Theme.positive)
                        } else if event.signedImpact < 0 {
                            Text("Reduces balance by \(Money.format(abs(event.signedImpact), currency))")
                                .foregroundStyle(Theme.negative)
                        } else {
                            Text("Informational / planning marker")
                                .foregroundStyle(Theme.secondaryInk)
                        }
                    }
                }
                Section("Explanation") {
                    Text(event.explanation)
                        .font(.subheadline)
                        .foregroundStyle(Theme.ink)
                }
            }
            .scrollContentBackground(.hidden)
            .canvasBackground()
            .navigationTitle("Event Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - Buy Now? Purchase Simulation (Sub-feature inside Time Machine)

struct BuyNowSimulationView: View {
    var initialAmount: Double = 0
    var initialName: String = ""

    @Query(sort: \MoneyTransaction.date, order: .reverse) private var transactions: [MoneyTransaction]
    @Query(sort: \Account.createdAt) private var accounts: [Account]
    @Query private var budgets: [Budget]
    @Query private var goals: [SavingsGoal]
    @Query(sort: \Bill.nextDueDate) private var bills: [Bill]
    @AppStorage(Keys.currency) private var currency = "BHD"

    @State private var amountText = ""
    @State private var purchaseName = ""
    @State private var purchaseDate = Date()
    @State private var selectedCategory: SpendCategory = .shopping
    @State private var aiRecommendation: String? = nil
    @State private var loadingAI = false
    @State private var initialized = false

    private var parsedAmount: Double {
        max(0, Money.parse(amountText) ?? 0)
    }

    var body: some View {
        let f = Finance(transactions: transactions, accounts: accounts, budgets: budgets, goals: goals, bills: bills)
        let simulation: BuyNowSimulationResult? = parsedAmount > 0
            ? FinancialProjectionEngine.simulateBuyNow(
                input: BuyNowSimulationInput(amount: parsedAmount, name: purchaseName, date: purchaseDate, category: selectedCategory),
                finance: f,
                currency: currency
            )
            : nil

        ScrollView {
            VStack(spacing: 16) {
                // Inputs Card
                VStack(alignment: .leading, spacing: 12) {
                    Text("Hypothetical Purchase")
                        .font(.headline)
                        .foregroundStyle(Theme.ink)

                    HStack {
                        Text("Amount (\(Money.symbol(currency)))")
                            .font(.subheadline)
                            .foregroundStyle(Theme.secondaryInk)
                        Spacer()
                        TextField("0.000", text: $amountText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .font(.title3.weight(.bold).monospacedDigit())
                            .frame(width: 140)
                    }
                    Divider()
                    TextField("Purchase name (optional)", text: $purchaseName)
                        .font(.subheadline)
                    Divider()
                    DatePicker("Purchase date", selection: $purchaseDate, displayedComponents: .date)
                        .font(.subheadline)
                    Divider()
                    Picker("Category", selection: $selectedCategory) {
                        ForEach(SpendCategory.expenseCases) { cat in
                            Text(cat.title).tag(cat)
                        }
                    }
                    .font(.subheadline)
                }
                .card()

                if let sim = simulation {
                    // Overall Status Banner
                    HStack(spacing: 12) {
                        IconBadge(symbol: sim.overallStatus.symbol, color: sim.overallStatus.color, size: 42)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(sim.overallStatus.title)
                                .font(.headline)
                                .foregroundStyle(sim.overallStatus.color)
                            Text(sim.summaryReason)
                                .font(.caption)
                                .foregroundStyle(Theme.ink)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                    }
                    .card()

                    // 4 Analysis Pillars (strict Current -> After Purchase format, NO separate Impact line)
                    pillarCard(
                        title: "SAFE TO SPEND",
                        comparison: "Current: \(Money.format(sim.safeToSpend.before, currency)) → After Purchase: \(Money.format(sim.safeToSpend.after, currency))",
                        status: sim.safeToSpend.status,
                        explanation: sim.safeToSpend.explanation
                    )

                    pillarCard(
                        title: "SAVING GOALS",
                        comparison: sim.savingGoals.totalTarget > 0
                            ? "Current: \(Int((sim.savingGoals.currentProgress * 100).rounded()))% → After Purchase: \(Int((sim.savingGoals.projectedProgress * 100).rounded()))%"
                            : "Current: No active goals",
                        status: sim.savingGoals.status,
                        explanation: sim.savingGoals.explanation
                    )

                    pillarCard(
                        title: "BUDGET · \(sim.budget.categoryTitle.uppercased())",
                        comparison: sim.budget.hasBudgetConfigured
                            ? "Current: \(Money.format(sim.budget.beforeRemaining, currency)) → After Purchase: \(Money.format(sim.budget.afterRemaining, currency))"
                            : "No budget configured",
                        status: sim.budget.status,
                        explanation: sim.budget.explanation
                    )

                    pillarCard(
                        title: "BILLS & INSTALLMENTS",
                        comparison: sim.bills.billsCovered && sim.bills.loansCovered && !sim.bills.createsCashShortfall
                            ? "Upcoming bills & installments remain covered"
                            : "Cash shortfall risk detected",
                        status: sim.bills.status,
                        explanation: sim.bills.explanation
                    )

                    // Recommendations Card
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Label("FALAK Recommendation", systemImage: "sparkles")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Theme.cobalt)
                            Spacer()
                            if loadingAI { ProgressView().scaleEffect(0.7) }
                        }
                        if let aiRec = aiRecommendation {
                            Text(aiRec)
                                .font(.subheadline)
                                .foregroundStyle(Theme.ink)
                        } else {
                            ForEach(sim.recommendations, id: \.self) { rec in
                                Text("• \(rec)")
                                    .font(.caption)
                                    .foregroundStyle(Theme.secondaryInk)
                            }
                        }
                    }
                    .card()

                    Text("Simulation only — no transaction is created and your balances stay untouched.")
                        .font(.caption2)
                        .foregroundStyle(Theme.secondaryInk)
                        .frame(maxWidth: .infinity, alignment: .center)
                } else {
                    ContentUnavailableView(
                        "Enter a Purchase Amount",
                        systemImage: "cart.badge.questionmark",
                        description: Text("See how a hypothetical purchase affects your Safe to Spend, goals, budgets, and upcoming bills.")
                    )
                    .padding(.top, 24)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 28)
        }
        .canvasBackground()
        .navigationTitle("Buy Now?")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .onAppear {
            guard !initialized else { return }
            initialized = true
            if initialAmount > 0 {
                amountText = Money.number(initialAmount, decimals: Money.digits(currency)).replacingOccurrences(of: ",", with: "")
            }
            if !initialName.isEmpty {
                purchaseName = initialName
            }
        }
        .task(id: "\(parsedAmount)-\(purchaseName)-\(selectedCategory.rawValue)") {
            aiRecommendation = nil
            guard let sim = simulation, GeminiAccount.isConfigured else { return }
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            loadingAI = true
            aiRecommendation = await InsightsAIService.generateBuyNowRecommendation(simulation: sim, currency: currency)
            loadingAI = false
        }
    }

    private func pillarCard(title: String, comparison: String, status: SimulationStatus, explanation: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Theme.secondaryInk)
                Spacer()
                Circle()
                    .fill(status.color)
                    .frame(width: 9, height: 9)
            }
            Text(comparison)
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(Theme.ink)
            Text(explanation)
                .font(.caption)
                .foregroundStyle(Theme.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
        }
        .card(padding: 14)
    }
}

// MARK: - Saving Goal Simulation (Sub-feature inside Time Machine)

struct SavingGoalSimulationView: View {
    @Environment(\.modelContext) private var context
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \MoneyTransaction.date, order: .reverse) private var transactions: [MoneyTransaction]
    @Query(sort: \Account.createdAt) private var accounts: [Account]
    @Query private var budgets: [Budget]
    @Query private var goals: [SavingsGoal]
    @Query(sort: \Bill.nextDueDate) private var bills: [Bill]
    @AppStorage(Keys.currency) private var currency = "BHD"

    @State private var goalName = ""
    @State private var targetText = ""
    @State private var savedText = ""
    @State private var selectedPreset: SavingGoalPeriodPreset? = nil
    @State private var customDate = Calendar.current.date(byAdding: .month, value: 6, to: .now) ?? .now
    @State private var showCreateConfirmation = false
    @State private var aiAdvice: String? = nil

    private var parsedTarget: Double { max(0, Money.parse(targetText) ?? 0) }
    private var parsedSaved: Double { max(0, Money.parse(savedText) ?? 0) }

    private var resolvedTargetDate: Date? {
        guard let preset = selectedPreset else { return nil }
        if let months = preset.months {
            return Calendar.current.date(byAdding: .month, value: months, to: .now)
        }
        return customDate
    }

    var body: some View {
        let f = Finance(transactions: transactions, accounts: accounts, budgets: budgets, goals: goals, bills: bills)
        let simulation: SavingGoalSimulationResult? = {
            guard parsedTarget > 0, let tDate = resolvedTargetDate else { return nil }
            return FinancialProjectionEngine.simulateSavingGoal(
                input: SavingGoalSimulationInput(name: goalName, targetAmount: parsedTarget, currentSaved: parsedSaved, targetDate: tDate),
                finance: f,
                currency: currency
            )
        }()

        ScrollView {
            VStack(spacing: 16) {
                // Goal Inputs
                VStack(alignment: .leading, spacing: 12) {
                    Text("Simulate a Savings Goal")
                        .font(.headline)
                        .foregroundStyle(Theme.ink)

                    TextField("Goal name (e.g. Emergency Fund, Car)", text: $goalName)
                        .font(.subheadline)
                    Divider()
                    HStack {
                        Text("Target amount")
                            .font(.subheadline)
                            .foregroundStyle(Theme.secondaryInk)
                        Spacer()
                        TextField("0.000", text: $targetText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .font(.subheadline.weight(.bold).monospacedDigit())
                            .frame(width: 130)
                    }
                    Divider()
                    HStack {
                        Text("Current saved (optional)")
                            .font(.subheadline)
                            .foregroundStyle(Theme.secondaryInk)
                        Spacer()
                        TextField("0.000", text: $savedText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .font(.subheadline.monospacedDigit())
                            .frame(width: 130)
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Saving Period (Required)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(selectedPreset == nil ? Theme.warning : Theme.secondaryInk)

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(SavingGoalPeriodPreset.allCases) { preset in
                                    let active = selectedPreset == preset
                                    Button {
                                        withAnimation(.snappy) { selectedPreset = preset }
                                    } label: {
                                        Text(preset.rawValue)
                                            .font(.caption.weight(.semibold))
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 8)
                                            .background(active ? Theme.cobalt : Theme.track.opacity(0.7), in: Capsule())
                                            .foregroundStyle(active ? .white : Theme.ink)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }

                        if selectedPreset == .customDate {
                            DatePicker(
                                "Target date",
                                selection: $customDate,
                                in: (Calendar.current.date(byAdding: .day, value: 7, to: .now) ?? .now)...,
                                displayedComponents: .date
                            )
                            .font(.subheadline)
                        }
                    }
                }
                .card()

                if let sim = simulation {
                    // Automatic Calculation Summary
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 10) {
                            IconBadge(symbol: sim.overallStatus.symbol, color: sim.overallStatus.color, size: 38)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(sim.isAchievable ? (sim.isSustainable ? "Achievable & Sustainable" : "Achievable (Tight)") : "Needs Adjustment")
                                    .font(.headline)
                                    .foregroundStyle(sim.overallStatus.color)
                                Text(sim.summaryReason)
                                    .font(.caption)
                                    .foregroundStyle(Theme.ink)
                            }
                            Spacer()
                        }

                        Divider()

                        HStack(spacing: 12) {
                            metricBox("Remaining", Money.format(sim.remainingAmount, currency))
                            metricBox("Required / mo", Money.format(sim.requiredMonthlyContribution, currency))
                            metricBox("Required / wk", Money.format(sim.requiredWeeklyContribution, currency))
                        }

                        HStack {
                            Text("Expected completion")
                                .font(.caption)
                                .foregroundStyle(Theme.secondaryInk)
                            Spacer()
                            Text(sim.expectedCompletionDate.formatted(date: .abbreviated, time: .omitted))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Theme.ink)
                        }
                    }
                    .card()

                    // 4-Pillar Evaluation
                    goalPillar("SAFE TO SPEND", status: sim.safeToSpendStatus, detail: "Current: \(Money.format(sim.safeToSpendBeforeMonthly, currency)) → After Saving: \(Money.format(sim.safeToSpendAfterMonthly, currency))", explanation: sim.safeToSpendExplanation)
                    goalPillar("SAVING GOALS", status: sim.goalsStatus, detail: "Current: \(Int((sim.currentProgress * 100).rounded()))% → Projected: \(Int((sim.projectedProgressAtTargetDate * 100).rounded()))%", explanation: sim.goalsExplanation)
                    goalPillar("BUDGET", status: sim.budgetStatus, detail: "Current: \(Money.format(sim.budgetRemainingBefore, currency)) → After Saving: \(Money.format(sim.budgetRemainingAfter, currency))", explanation: sim.budgetExplanation)
                    goalPillar("BILLS & INSTALLMENTS", status: sim.billsStatus, detail: sim.billsCovered && sim.loansCovered ? "Covered" : "At risk", explanation: sim.billsExplanation)

                    // Smart Suggestions
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Smart Suggestions", systemImage: "sparkles")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.cobalt)
                        if let advice = aiAdvice {
                            Text(advice).font(.subheadline).foregroundStyle(Theme.ink)
                        }
                        ForEach(sim.smartSuggestions, id: \.self) { s in
                            Text("• \(s)").font(.caption).foregroundStyle(Theme.secondaryInk)
                        }
                    }
                    .card()

                    // Explicit User Confirmation to Save Real Goal
                    Button {
                        showCreateConfirmation = true
                    } label: {
                        Text("Create Real Savings Goal")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Theme.cobalt, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .confirmationDialog("Create this savings goal?", isPresented: $showCreateConfirmation, titleVisibility: .visible) {
                        Button("Create Goal") {
                            let finalName = goalName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Savings Goal" : goalName.trimmingCharacters(in: .whitespacesAndNewlines)
                            let newGoal = SavingsGoal(
                                name: finalName,
                                symbol: "star.fill",
                                target: parsedTarget,
                                saved: parsedSaved,
                                targetDate: sim.input.targetDate,
                                monthlyCommitment: sim.requiredMonthlyContribution
                            )
                            context.insert(newGoal)
                            try? context.save()
                            Ledger.notifyDataChanged()
                            appState.show("Created \(finalName) goal")
                            dismiss()
                        }
                    } message: {
                        Text("Adds \(goalName.isEmpty ? "this goal" : goalName) with a \(Money.format(sim.requiredMonthlyContribution, currency))/mo plan to your Budgets tab.")
                    }
                } else {
                    ContentUnavailableView(
                        "Enter Target & Choose Period",
                        systemImage: "target",
                        description: Text("Enter a target amount and select a saving period or custom date to automatically calculate your monthly saving plan.")
                    )
                    .padding(.top, 20)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 28)
        }
        .canvasBackground()
        .navigationTitle("Saving Goal")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .task(id: "\(parsedTarget)-\(parsedSaved)-\(selectedPreset?.rawValue ?? "")-\(Int(customDate.timeIntervalSinceReferenceDate))") {
            aiAdvice = nil
            guard let sim = simulation, GeminiAccount.isConfigured else { return }
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            aiAdvice = await InsightsAIService.generateSavingGoalAdvice(simulation: sim, currency: currency)
        }
    }

    private func metricBox(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption2).foregroundStyle(Theme.secondaryInk)
            Text(value).font(.caption.weight(.bold).monospacedDigit()).foregroundStyle(Theme.ink).lineLimit(1).minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func goalPillar(_ title: String, status: SimulationStatus, detail: String, explanation: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.caption.weight(.bold)).foregroundStyle(Theme.secondaryInk)
                Spacer()
                Circle().fill(status.color).frame(width: 9, height: 9)
            }
            Text(detail).font(.subheadline.weight(.semibold).monospacedDigit()).foregroundStyle(Theme.ink)
            Text(explanation).font(.caption).foregroundStyle(Theme.secondaryInk).fixedSize(horizontal: false, vertical: true)
        }
        .card(padding: 14)
    }
}
