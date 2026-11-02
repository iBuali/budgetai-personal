import SwiftUI
import SwiftData
import Charts

extension SimulationScenario {
    var color: Color {
        switch self {
        case .conservative: Theme.warning
        case .expected: Theme.cobalt
        case .optimistic: Theme.positive
        }
    }
}

struct FinancialTimeMachineView: View {
    @Query(sort: \MoneyTransaction.date, order: .reverse) private var transactions: [MoneyTransaction]
    @Query private var accounts: [Account]
    @Query private var budgets: [Budget]
    @Query private var goals: [SavingsGoal]
    @Query(sort: \Bill.nextDueDate) private var bills: [Bill]
    @AppStorage(Keys.currency) private var currency = "BHD"
    @AppStorage("timeMachineAssumptions") private var storedAssumptions: Data = Data()

    @State private var assumptions = SimulationAssumptions()
    @State private var loaded = false
    @State private var days = 90
    @State private var scenario: SimulationScenario = .expected
    @State private var compare = false
    @State private var selectedDate: Date?
    @State private var showEditor = false

    var body: some View {
        let f = Finance(transactions: transactions, accounts: accounts, budgets: budgets, goals: goals, bills: bills)
        let base = TimeMachineEngine.baseline(from: f)
        let results = SimulationScenario.allCases.map { TimeMachineEngine.simulate(base, assumptions, scenario: $0, days: days) }
        let r = results.first(where: { $0.scenario == scenario }) ?? results[1]
        let actual = base.isDemo ? [] : TimeMachineEngine.actualHistory(f, days: 30)

        ScrollView {
            VStack(spacing: 16) {
                heroCard(base, r)
                periodPicker
                scenarioPicker
                summaryGrid(r)
                commitmentCard(r)
                chartCard(actual: actual, results: results, selected: r)
                quickControls
                comparisonCard(base, results)
                if assumptions.targetBalance > 0 { targetCard(r) }
                monthlyCard(r)
                baselineCard(base)
                disclaimer
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 28)
            .animation(.spring(response: 0.45, dampingFraction: 0.86), value: days)
            .animation(.spring(response: 0.45, dampingFraction: 0.86), value: scenario)
        }
        .canvasBackground()
        .navigationTitle("Time Machine")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showEditor = true } label: { Image(systemName: "slider.horizontal.3") }
                    .accessibilityLabel("Adjust assumptions")
            }
        }
        .sheet(isPresented: $showEditor) {
            AssumptionsEditor(assumptions: $assumptions, baseline: base, currency: currency)
        }
        .onAppear(perform: load)
        .onChange(of: assumptions) { _, value in
            storedAssumptions = (try? JSONEncoder().encode(value)) ?? Data()
        }
        .sensoryFeedback(.selection, trigger: days)
        .sensoryFeedback(.selection, trigger: scenario)
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        if let saved = try? JSONDecoder().decode(SimulationAssumptions.self, from: storedAssumptions) {
            assumptions = saved
        }
    }

    private func m(_ v: Double, signed: Bool = false) -> String { Money.format(v, currency, signed: signed) }

    // MARK: Hero

    private func heroCard(_ base: FinancialBaseline, _ r: SimulationResult) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Financial Time Machine")
                        .font(.title3.bold())
                        .foregroundStyle(.white)
                    Text("See where your money is heading.")
                        .font(.subheadline)
                        .foregroundStyle(Color.white.opacity(0.8))
                }
                Spacer()
                if base.isDemo {
                    Text("DEMO DATA")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Color.white.opacity(0.22), in: Capsule())
                        .foregroundStyle(.white)
                } else {
                    Image(systemName: "clock.arrow.2.circlepath")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(Color.white.opacity(0.9))
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Projected in \(days) days · \(scenario.title)")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.white.opacity(0.8))
                Text(m(r.endBalance))
                    .font(.system(size: 38, weight: .bold).monospacedDigit())
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)
                    .animatedNumber(r.endBalance)
                Text("\(m(r.estimatedSavings, signed: true)) vs today")
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .foregroundStyle(r.estimatedSavings >= 0 ? Color(hex: 0xA7F3D0) : Color(hex: 0xFECACA))
                    .animatedNumber(r.estimatedSavings)
            }
            Divider().overlay(Color.white.opacity(0.25))
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Current balance").font(.caption).foregroundStyle(Color.white.opacity(0.75))
                    Text(m(base.startingBalance))
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(.white)
                        .lineLimit(1).minimumScaleFactor(0.7)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Projection date").font(.caption).foregroundStyle(Color.white.opacity(0.75))
                    Text(r.points.last?.date ?? .now, format: .dateTime.day().month(.abbreviated).year())
                        .font(.headline)
                        .foregroundStyle(.white)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(colors: [Color(hex: 0x1E3FAE), Color(hex: 0x3B5BDB), Color(hex: 0x6D4AE0)],
                           startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .shadow(color: Theme.cobalt.opacity(0.25), radius: 18, y: 8)
    }

    // MARK: Pickers

    private var periodPicker: some View {
        Picker("Forecast period", selection: $days) {
            ForEach(TimeMachineEngine.periods, id: \.self) { d in
                Text(d == 365 ? "1 year" : "\(d) days").tag(d)
            }
        }
        .pickerStyle(.segmented)
    }

    private var scenarioPicker: some View {
        HStack(spacing: 8) {
            ForEach(SimulationScenario.allCases) { s in
                Button {
                    scenario = s
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: s.symbol).font(.caption.weight(.semibold))
                        Text(s.title).font(.subheadline.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .foregroundStyle(scenario == s ? .white : s.color)
                    .background(scenario == s ? s.color : s.color.opacity(0.12),
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(PressableStyle())
            }
        }
    }

    // MARK: Summary

    private func summaryGrid(_ r: SimulationResult) -> some View {
        let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]
        return LazyVGrid(columns: columns, spacing: 10) {
            metric("Expected income", r.totalIncome, symbol: "arrow.down.circle.fill", color: Theme.positive)
            metric("Expected expenses", r.totalExpenses, symbol: "arrow.up.circle.fill", color: Theme.negative)
            metric("Estimated savings", r.estimatedSavings, symbol: "banknote.fill", color: r.estimatedSavings >= 0 ? Theme.cobalt : Theme.negative, signed: true)
            metric("Bills & subscriptions", r.commitmentsTotal, symbol: "calendar", color: Theme.warning)
        }
    }

    private func metric(_ title: String, _ value: Double, symbol: String, color: Color, signed: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            IconBadge(symbol: symbol, color: color, size: 30)
            Text(title)
                .font(.caption)
                .foregroundStyle(Theme.secondaryInk)
                .lineLimit(1).minimumScaleFactor(0.8)
            Text(m(value, signed: signed))
                .font(.headline.monospacedDigit())
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .animatedNumber(value)
        }
        .card(padding: 14)
    }

    private func commitmentCard(_ r: SimulationResult) -> some View {
        let ok = r.coversCommitments
        return HStack(spacing: 12) {
            IconBadge(symbol: ok ? "checkmark.shield.fill" : "exclamationmark.triangle.fill",
                      color: ok ? Theme.positive : Theme.negative, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(ok ? "Your commitments are covered" : "Balance may run short")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.ink)
                Group {
                    if ok {
                        Text("Lowest projected balance \(m(r.lowestBalance)) on \(r.lowestDate.formatted(.dateTime.day().month(.abbreviated)))")
                    } else {
                        Text("Projected to dip to \(m(r.lowestBalance)) around \(r.lowestDate.formatted(.dateTime.day().month(.abbreviated)))")
                    }
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(Theme.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .card(padding: 14)
    }

    // MARK: Chart

    private func chartCard(actual: [ProjectionPoint], results: [SimulationResult], selected: SimulationResult) -> some View {
        let shown = compare ? results : [selected]
        let today = Calendar.current.startOfDay(for: .now)
        let probe = selectedDate.flatMap { d in nearest(d, actual: actual, projected: selected.points) }
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Balance over time").font(.headline).foregroundStyle(Theme.ink)
                Spacer()
                Toggle("Compare", isOn: $compare.animation(.spring(response: 0.4, dampingFraction: 0.85)))
                    .toggleStyle(.button)
                    .controlSize(.small)
                    .font(.caption.weight(.semibold))
            }
            Group {
                if let probe {
                    HStack(spacing: 6) {
                        Text(probe.point.date, format: .dateTime.day().month(.abbreviated).year())
                            .foregroundStyle(Theme.secondaryInk)
                        Text(m(probe.point.balance)).fontWeight(.bold).foregroundStyle(Theme.ink)
                        Text(probe.isActual ? "Actual" : "Projected")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background((probe.isActual ? Theme.ink : selected.scenario.color).opacity(0.12), in: Capsule())
                            .foregroundStyle(probe.isActual ? Theme.ink : selected.scenario.color)
                    }
                } else {
                    Text("Touch and drag the chart to explore")
                        .foregroundStyle(Theme.secondaryInk)
                }
            }
            .font(.subheadline.monospacedDigit())
            .lineLimit(1)
            .minimumScaleFactor(0.7)

            Chart {
                ForEach(actual) { p in
                    LineMark(x: .value("Date", p.date, unit: .day), y: .value("Balance", p.balance),
                             series: .value("Series", "Actual"))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(Theme.ink)
                        .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                }
                ForEach(shown, id: \.scenario) { res in
                    ForEach(res.points) { p in
                        LineMark(x: .value("Date", p.date, unit: .day), y: .value("Balance", p.balance),
                                 series: .value("Series", res.scenario.title))
                            .interpolationMethod(.monotone)
                            .foregroundStyle(res.scenario.color)
                            .lineStyle(StrokeStyle(lineWidth: res.scenario == selected.scenario ? 2.6 : 1.8,
                                                   lineCap: .round, dash: [6, 4]))
                    }
                }
                RuleMark(x: .value("Today", today, unit: .day))
                    .foregroundStyle(Theme.ink.opacity(0.25))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .annotation(position: .top, alignment: .center) {
                        Text("Today").font(.caption2).foregroundStyle(Theme.secondaryInk)
                    }
                if assumptions.targetBalance > 0 {
                    RuleMark(y: .value("Target", assumptions.targetBalance))
                        .foregroundStyle(Theme.positive.opacity(0.6))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
                        .annotation(position: .top, alignment: .leading) {
                            Text("Target").font(.caption2.weight(.semibold)).foregroundStyle(Theme.positive)
                        }
                }
                if let probe {
                    RuleMark(x: .value("Selected", probe.point.date, unit: .day))
                        .foregroundStyle(Theme.ink.opacity(0.15))
                    PointMark(x: .value("Date", probe.point.date, unit: .day), y: .value("Balance", probe.point.balance))
                        .foregroundStyle(probe.isActual ? Theme.ink : selected.scenario.color)
                        .symbolSize(80)
                }
            }
            .chartXSelection(value: $selectedDate)
            .chartYScale(domain: .automatic(includesZero: false))
            .chartYAxis {
                AxisMarks(position: .trailing) { v in
                    AxisGridLine().foregroundStyle(Theme.track)
                    AxisValueLabel {
                        if let d = v.as(Double.self) { Text((d < 0 ? "−" : "") + Money.short(d)) }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                    AxisValueLabel(format: axisFormat)
                }
            }
            .frame(height: 210)

            HStack(spacing: 14) {
                if !actual.isEmpty { legend("Actual", Theme.ink, dashed: false) }
                ForEach(shown, id: \.scenario) { res in legend(res.scenario.title, res.scenario.color, dashed: true) }
            }
            .font(.caption)
        }
        .card()
    }

    private var axisFormat: Date.FormatStyle {
        days > 180 ? Date.FormatStyle().month(.abbreviated) : Date.FormatStyle().month(.abbreviated).day()
    }

    private func nearest(_ d: Date, actual: [ProjectionPoint], projected: [ProjectionPoint]) -> (point: ProjectionPoint, isActual: Bool)? {
        let today = Calendar.current.startOfDay(for: .now)
        if d < today, let p = actual.min(by: { abs($0.date.timeIntervalSince(d)) < abs($1.date.timeIntervalSince(d)) }) {
            return (p, true)
        }
        if let p = projected.min(by: { abs($0.date.timeIntervalSince(d)) < abs($1.date.timeIntervalSince(d)) }) {
            return (p, false)
        }
        return nil
    }

    private func legend(_ title: String, _ color: Color, dashed: Bool) -> some View {
        HStack(spacing: 5) {
            Capsule()
                .stroke(color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: dashed ? [4, 3] : []))
                .frame(width: 18, height: 1)
            Text(title).foregroundStyle(Theme.secondaryInk)
        }
    }

    // MARK: Quick what-ifs

    private var step: Double { Money.digits(currency) == 0 ? 1000 : 10 }

    private var quickControls: some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionTitle(title: "What if…") {
                Button("All assumptions") { showEditor = true }
                    .font(.subheadline.weight(.medium))
            }
            .padding(.bottom, 6)
            QuickStepRow(title: "Salary change", symbol: "briefcase.fill", color: Theme.positive,
                         value: TimeMachineEngine.pct(assumptions.salaryChangePercent),
                         onMinus: { assumptions.salaryChangePercent = max(-100, assumptions.salaryChangePercent - 5) },
                         onPlus: { assumptions.salaryChangePercent = min(200, assumptions.salaryChangePercent + 5) })
            Divider().padding(.leading, 44)
            QuickStepRow(title: "Monthly expenses", symbol: "cart.fill", color: Theme.negative,
                         value: m(assumptions.expenseChangeAmount, signed: true),
                         onMinus: { assumptions.expenseChangeAmount -= step },
                         onPlus: { assumptions.expenseChangeAmount += step })
            Divider().padding(.leading, 44)
            QuickStepRow(title: "Extra monthly savings", symbol: "banknote.fill", color: Theme.cobalt,
                         value: m(assumptions.additionalMonthlySavings),
                         onMinus: { assumptions.additionalMonthlySavings = max(0, assumptions.additionalMonthlySavings - step) },
                         onPlus: { assumptions.additionalMonthlySavings += step })
            if assumptions.hasAdjustments {
                Button(role: .destructive) {
                    withAnimation { resetAdjustments() }
                } label: {
                    Label("Reset adjustments", systemImage: "arrow.counterclockwise").font(.subheadline)
                }
                .padding(.top, 8)
            }
        }
        .card()
    }

    private func resetAdjustments() {
        var fresh = SimulationAssumptions()
        fresh.targetBalance = assumptions.targetBalance
        fresh.conservativeExpenseBuffer = assumptions.conservativeExpenseBuffer
        fresh.conservativeExtraIncomeShare = assumptions.conservativeExtraIncomeShare
        fresh.optimisticDiscretionaryCut = assumptions.optimisticDiscretionaryCut
        fresh.optimisticExtraIncomeShare = assumptions.optimisticExtraIncomeShare
        assumptions = fresh
    }

    // MARK: Scenario comparison

    private func comparisonCard(_ base: FinancialBaseline, _ results: [SimulationResult]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionTitle(title: "Scenario comparison") {
                Button("Edit") { showEditor = true }.font(.subheadline.weight(.medium))
            }
            ForEach(results, id: \.scenario) { res in
                Button { scenario = res.scenario } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 10) {
                            IconBadge(symbol: res.scenario.symbol, color: res.scenario.color, size: 34)
                            Text(res.scenario.title).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
                            Spacer()
                            VStack(alignment: .trailing, spacing: 1) {
                                Text(m(res.endBalance))
                                    .font(.subheadline.weight(.bold).monospacedDigit())
                                    .foregroundStyle(Theme.ink)
                                    .lineLimit(1).minimumScaleFactor(0.7)
                                    .animatedNumber(res.endBalance)
                                Text("\(m(res.estimatedSavings, signed: true)) savings")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(res.estimatedSavings >= 0 ? Theme.positive : Theme.negative)
                                    .lineLimit(1).minimumScaleFactor(0.7)
                            }
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(TimeMachineEngine.assumptionLines(base, assumptions, scenario: res.scenario, currency: currency), id: \.self) { line in
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Circle().fill(res.scenario.color.opacity(0.6)).frame(width: 4, height: 4)
                                    Text(line)
                                        .font(.caption)
                                        .foregroundStyle(Theme.secondaryInk)
                                        .multilineTextAlignment(.leading)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        .padding(.leading, 44)
                    }
                    .padding(12)
                    .background(scenario == res.scenario ? res.scenario.color.opacity(0.08) : Theme.canvas,
                                in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(scenario == res.scenario ? res.scenario.color.opacity(0.5) : .clear, lineWidth: 1.5))
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle())
            }
        }
        .card()
    }

    // MARK: Target

    private func targetCard(_ r: SimulationResult) -> some View {
        let target = assumptions.targetBalance
        let progress = target > 0 ? max(0, min(1, r.endBalance / target)) : 0
        let gap = target - r.endBalance
        let monthsLeft = max(1, Double(days) / TimeMachineEngine.daysPerMonth)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Target balance").font(.headline).foregroundStyle(Theme.ink)
                Spacer()
                Text(m(target)).font(.subheadline.weight(.semibold).monospacedDigit()).foregroundStyle(Theme.ink)
            }
            ProgressBar(progress: progress, color: gap <= 0 ? Theme.positive : Theme.cobalt, height: 10)
            Group {
                if let date = r.targetReachedDate {
                    Text("Reached around \(date.formatted(.dateTime.day().month(.abbreviated).year())) in the \(r.scenario.title.lowercased()) scenario.")
                } else {
                    Text("\(m(gap)) short after \(days) days. Saving about \(m(gap / monthsLeft)) more per month would close the gap.")
                }
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(Theme.secondaryInk)
            .fixedSize(horizontal: false, vertical: true)
        }
        .card()
    }

    // MARK: Monthly breakdown

    private func monthlyCard(_ r: SimulationResult) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("Monthly breakdown")
            HStack {
                Text("Month").frame(maxWidth: .infinity, alignment: .leading)
                Text("Net").frame(width: 92, alignment: .trailing)
                Text("Balance").frame(width: 100, alignment: .trailing)
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(Theme.secondaryInk)
            ForEach(r.months) { mo in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(mo.month, format: .dateTime.month(.abbreviated).year(.twoDigits))
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Theme.ink)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(m(mo.net, signed: true))
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(mo.net >= 0 ? Theme.positive : Theme.negative)
                            .lineLimit(1).minimumScaleFactor(0.6)
                            .frame(width: 92, alignment: .trailing)
                        Text(m(mo.endBalance))
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                            .foregroundStyle(Theme.ink)
                            .lineLimit(1).minimumScaleFactor(0.6)
                            .frame(width: 100, alignment: .trailing)
                    }
                    Text("In \(Money.short(mo.income)) · Spend \(Money.short(mo.expenses)) · Bills \(Money.short(mo.commitments))")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(Theme.secondaryInk)
                        .lineLimit(1).minimumScaleFactor(0.7)
                }
                if mo.id != r.months.last?.id { Divider() }
            }
            Text("Partial months only include the days inside the forecast period.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .card()
    }

    // MARK: Baseline transparency

    private func baselineCard(_ base: FinancialBaseline) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(base.isDemo ? "Demo data used" : "Based on your data")
            if base.isDemo {
                Text("You have no accounts or transactions yet, so this projection uses sample figures. Add accounts and transactions to see your own future.")
                    .font(.caption)
                    .foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            baseRow("Starting balance", "Cash & bank accounts", base.startingBalance)
            if !base.recurringSources.isEmpty {
                baseRow("Regular income", base.recurringSources.prefix(2).map(\.name).joined(separator: ", "), base.recurringIncome, suffix: "/mo")
            }
            baseRow("Other income", "Average of irregular income", base.otherIncome, suffix: "/mo")
            baseRow("Day-to-day spending", "Average of last \(base.historyDays) days", base.grossSpending, suffix: "/mo")
            if base.refundsMonthly > 0 {
                baseRow("Refunds", "Offset against spending", base.refundsMonthly, suffix: "/mo")
            }
            baseRow("Bills & subscriptions", "\(base.commitments.count) scheduled", base.commitmentsMonthly, suffix: "/mo")
            Text("Internal transfers, card payments, savings transfers and unapproved SMS are excluded. Bill payments are scheduled on their due dates and not counted twice.")
                .font(.caption2)
                .foregroundStyle(Theme.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
        }
        .card()
    }

    private func baseRow(_ title: String, _ subtitle: String, _ value: Double, suffix: String = "") -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.subheadline).foregroundStyle(Theme.ink)
                Text(subtitle).font(.caption2).foregroundStyle(Theme.secondaryInk).lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(m(value) + suffix)
                .font(.subheadline.weight(.medium).monospacedDigit())
                .foregroundStyle(Theme.ink)
                .lineLimit(1).minimumScaleFactor(0.7)
                .layoutPriority(1)
        }
    }

    private var disclaimer: some View {
        Label {
            Text("Forecasts are estimates based on your history and the assumptions above — not guaranteed bank balances. Simulations never change your real transactions or balances.")
        } icon: {
            Image(systemName: "info.circle")
        }
        .font(.caption)
        .foregroundStyle(Theme.secondaryInk)
        .padding(.horizontal, 4)
    }
}

// MARK: - Quick step row

struct QuickStepRow: View {
    let title: String
    let symbol: String
    let color: Color
    let value: String
    let onMinus: () -> Void
    let onPlus: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            IconBadge(symbol: symbol, color: color, size: 34)
            Text(title)
                .font(.subheadline)
                .foregroundStyle(Theme.ink)
                .lineLimit(1).minimumScaleFactor(0.8)
            Spacer(minLength: 4)
            Button(action: onMinus) {
                Image(systemName: "minus").font(.caption.weight(.bold)).frame(width: 30, height: 30)
                    .background(Theme.track.opacity(0.8), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Decrease \(title)")
            Text(value)
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(Theme.ink)
                .lineLimit(1).minimumScaleFactor(0.6)
                .frame(minWidth: 70)
                .contentTransition(.numericText())
            Button(action: onPlus) {
                Image(systemName: "plus").font(.caption.weight(.bold)).frame(width: 30, height: 30)
                    .background(Theme.track.opacity(0.8), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Increase \(title)")
        }
        .foregroundStyle(Theme.ink)
        .padding(.vertical, 4)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: value)
    }
}

// MARK: - Assumptions editor

struct AssumptionsEditor: View {
    @Binding var assumptions: SimulationAssumptions
    let baseline: FinancialBaseline
    let currency: String
    @Environment(\.dismiss) private var dismiss
    @State private var newEventIsIncome: Bool?

    private var amountFormat: FloatingPointFormatStyle<Double> {
        .number.precision(.fractionLength(0...Money.digits(currency)))
    }

    var body: some View {
        NavigationStack {
            Form {
                incomeSection
                expenseSection
                categorySection
                savingsSection
                eventsSection
                scenarioSection
                Section {
                    Button("Reset everything", role: .destructive) { assumptions = SimulationAssumptions() }
                } footer: {
                    Text("Changes update the projection instantly. Your real transactions and balances are never changed.")
                }
            }
            .navigationTitle("Assumptions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(item: Binding(get: { newEventIsIncome.map { EventKind(isIncome: $0) } },
                                 set: { newEventIsIncome = $0?.isIncome })) { kind in
                OneTimeEventSheet(isIncome: kind.isIncome, currency: currency) { event in
                    assumptions.events.append(event)
                    assumptions.events.sort { $0.date < $1.date }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationBackgroundInteraction(.enabled(upThrough: .medium))
    }

    private var incomeSection: some View {
        Section {
            Stepper(value: $assumptions.salaryChangePercent, in: -100...200, step: 5) {
                LabeledContent("Salary change", value: TimeMachineEngine.pct(assumptions.salaryChangePercent))
            }
            amountField("Salary change (fixed)", value: $assumptions.salaryChangeAmount, allowNegative: true)
            amountField("Additional monthly income", value: $assumptions.additionalMonthlyIncome)
        } header: {
            Text("Income")
        } footer: {
            Text(baseline.recurringIncome > 0
                 ? "Regular income detected: \(Money.format(baseline.recurringIncome, currency))/mo. Use a negative fixed amount for a decrease."
                 : "No regular salary detected yet, so salary changes apply to your average income.")
        }
    }

    private var expenseSection: some View {
        Section {
            Stepper(value: $assumptions.expenseChangePercent, in: -90...200, step: 5) {
                LabeledContent("Spending change", value: TimeMachineEngine.pct(assumptions.expenseChangePercent))
            }
            amountField("Monthly change (fixed)", value: $assumptions.expenseChangeAmount, allowNegative: true)
            Toggle("Include bills & subscriptions", isOn: $assumptions.includeCommitments)
        } header: {
            Text("Expenses")
        } footer: {
            Text("Baseline day-to-day spending: \(Money.format(baseline.variableSpending, currency))/mo. Bills: \(Money.format(baseline.commitmentsMonthly, currency))/mo. Enter −100 to reduce spending by 100.")
        }
    }

    @ViewBuilder
    private var categorySection: some View {
        if !baseline.categories.isEmpty {
            Section("Spending by category") {
                ForEach(baseline.categories) { c in
                    let key = c.category.rawValue
                    let pct = assumptions.categoryChangePercent[key] ?? 0
                    Stepper(value: Binding(get: { assumptions.categoryChangePercent[key] ?? 0 },
                                           set: { assumptions.categoryChangePercent[key] = $0 }),
                            in: -100...200, step: 10) {
                        HStack(spacing: 10) {
                            CategoryIcon(category: c.category, size: 28)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(c.category.shortTitle).font(.subheadline).lineLimit(1)
                                Text("\(Money.format(c.monthly * (1 + pct / 100), currency))/mo")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(Theme.secondaryInk)
                            }
                            Spacer(minLength: 4)
                            Text(TimeMachineEngine.pct(pct))
                                .font(.caption.weight(.semibold).monospacedDigit())
                                .foregroundStyle(pct == 0 ? Theme.secondaryInk : (pct < 0 ? Theme.positive : Theme.negative))
                        }
                    }
                }
            }
        }
    }

    private var savingsSection: some View {
        Section {
            amountField("Extra monthly savings", value: $assumptions.additionalMonthlySavings)
            amountField("Target future balance", value: $assumptions.targetBalance)
        } header: {
            Text("Savings")
        } footer: {
            Text("Extra savings are funded by spending less each month, so they are never counted twice. Set target to 0 to hide it.")
        }
    }

    private var eventsSection: some View {
        Section {
            ForEach(assumptions.events) { e in
                HStack {
                    IconBadge(symbol: e.isIncome ? "arrow.down" : "arrow.up", color: e.isIncome ? Theme.positive : Theme.negative, size: 30)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(e.title.isEmpty ? (e.isIncome ? "One-time income" : "One-time expense") : e.title)
                            .font(.subheadline).lineLimit(1)
                        Text(e.date, format: .dateTime.day().month(.abbreviated).year())
                            .font(.caption2).foregroundStyle(Theme.secondaryInk)
                    }
                    Spacer()
                    Text(Money.format(e.isIncome ? e.amount : -e.amount, currency, signed: true))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(e.isIncome ? Theme.positive : Theme.ink)
                }
            }
            .onDelete { assumptions.events.remove(atOffsets: $0) }
            Button { newEventIsIncome = true } label: { Label("Add one-time income", systemImage: "plus.circle") }
            Button { newEventIsIncome = false } label: { Label("Add one-time expense", systemImage: "minus.circle") }
        } header: {
            Text("One-time events")
        } footer: {
            Text("For example a bonus, a car repair or a holiday. Swipe to delete.")
        }
    }

    private var scenarioSection: some View {
        Section {
            Stepper(value: $assumptions.conservativeExpenseBuffer, in: 0...50, step: 5) {
                LabeledContent("Conservative: extra spending", value: "+\(Int(assumptions.conservativeExpenseBuffer))%")
            }
            Stepper(value: $assumptions.conservativeExtraIncomeShare, in: 0...100, step: 25) {
                LabeledContent("Conservative: extra income counted", value: "\(Int(assumptions.conservativeExtraIncomeShare))%")
            }
            Stepper(value: $assumptions.optimisticDiscretionaryCut, in: 0...50, step: 5) {
                LabeledContent("Optimistic: less non-essential", value: "−\(Int(assumptions.optimisticDiscretionaryCut))%")
            }
            Stepper(value: $assumptions.optimisticExtraIncomeShare, in: 0...100, step: 25) {
                LabeledContent("Optimistic: extra income counted", value: "\(Int(assumptions.optimisticExtraIncomeShare))%")
            }
        } header: {
            Text("Scenario settings")
        } footer: {
            Text("Expected always uses your real patterns plus your adjustments. These settings only shape the Conservative and Optimistic comparisons.")
        }
    }

    private func amountField(_ title: String, value: Binding<Double>, allowNegative: Bool = false) -> some View {
        LabeledContent(title) {
            HStack(spacing: 4) {
                Text(Money.symbol(currency)).foregroundStyle(Theme.secondaryInk)
                TextField("0", value: value, format: amountFormat)
                    .keyboardType(allowNegative ? .numbersAndPunctuation : .decimalPad)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .frame(maxWidth: 120)
            }
        }
    }
}

private struct EventKind: Identifiable {
    let isIncome: Bool
    var id: Bool { isIncome }
}

struct OneTimeEventSheet: View {
    let isIncome: Bool
    let currency: String
    let onSave: (OneTimeEvent) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var amount: Double?
    @State private var date = Calendar.current.date(byAdding: .month, value: 1, to: .now) ?? .now

    var body: some View {
        NavigationStack {
            Form {
                TextField(isIncome ? "e.g. Bonus" : "e.g. Car repair", text: $title)
                LabeledContent("Amount") {
                    TextField("0", value: $amount, format: .number.precision(.fractionLength(0...Money.digits(currency))))
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                }
                DatePicker("Date", selection: $date, in: Date.now..., displayedComponents: .date)
            }
            .navigationTitle(isIncome ? "One-time income" : "One-time expense")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        let factor = pow(10, Double(Money.digits(currency)))
                        let value = ((amount ?? 0) * factor).rounded() / factor
                        onSave(OneTimeEvent(title: title.trimmingCharacters(in: .whitespaces), amount: abs(value), date: date, isIncome: isIncome))
                        dismiss()
                    }
                    .disabled((amount ?? 0) <= 0)
                }
            }
        }
        .presentationDetents([.medium])
    }
}
