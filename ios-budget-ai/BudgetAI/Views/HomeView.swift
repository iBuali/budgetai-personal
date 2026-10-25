import SwiftUI
import SwiftData
import Charts

struct HomeView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var context
    @Query(sort: \MoneyTransaction.date, order: .reverse) private var transactions: [MoneyTransaction]
    @Query private var accounts: [Account]
    @Query private var budgets: [Budget]
    @Query private var goals: [SavingsGoal]
    @Query(sort: \Bill.nextDueDate) private var bills: [Bill]
    @AppStorage(Keys.currency) private var currency = "BHD"
    @AppStorage(Keys.userName) private var userName = ""
    @State private var range: ChartRange = .month
    @State private var selectedDate: Date?
    @State private var billToPay: Bill?

    private var finance: Finance {
        Finance(transactions: transactions, accounts: accounts, budgets: budgets, goals: goals, bills: bills)
    }

    var body: some View {
        let f = finance
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    header(f)
                    spendingCard(f)
                    statTiles(f)
                    safeCard(f)
                    duplicatesBanner
                    netWorthCard(f)
                    billsSection(f)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .canvasBackground()
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Add transaction", systemImage: "plus") { appState.showAddTransaction = true }
                        Button("Paste bank SMS", systemImage: "message") { appState.showPasteSMS = true }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add")
                }
            }
            .navigationDestination(for: HomeRoute.self) { route in
                switch route {
                case .safe: SafeToSpendView()
                case .netWorth: NetWorthView()
                case .bills: BillsView()
                }
            }
            .confirmationDialog("Mark \(billToPay?.name ?? "bill") as paid?", isPresented: Binding(get: { billToPay != nil }, set: { if !$0 { billToPay = nil } }), titleVisibility: .visible) {
                Button("Paid \(Money.format(billToPay?.amount ?? 0, currency))") {
                    if let bill = billToPay {
                        Ledger.payBill(bill, accountID: Ledger.defaultAccountID(context: context), context: context)
                        Notifier.rescheduleBills(bills)
                        appState.show("\(bill.name) marked as paid")
                    }
                    billToPay = nil
                }
            }
        }
    }

    // MARK: Sections

    private func header(_ f: Finance) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(greeting).font(.title2.bold()).foregroundStyle(Theme.ink)
                    Text("Total balance").font(.body).foregroundStyle(Theme.secondaryInk)
                }
                Spacer()
                Button { appState.tab = .profile } label: {
                    Text(initials)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.cobalt)
                        .frame(width: 44, height: 44)
                        .background(Theme.cobaltSoft, in: Circle())
                }
                .accessibilityLabel("Profile")
            }
            Text(Money.format(f.liquidBalance, currency))
                .font(.system(size: 42, weight: .bold).monospacedDigit())
                .foregroundStyle(Theme.ink)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
                .contentTransition(.numericText(value: f.liquidBalance))
                .animation(.snappy, value: f.liquidBalance)
            Text("\(Money.format(f.monthNet, currency, signed: true)) this month")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(f.monthNet >= 0 ? Theme.positive : Theme.negative)
        }
        .padding(.top, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func spendingCard(_ f: Finance) -> some View {
        let points = f.spendingSeries(range)
        let selected = selectedDate.flatMap { d in points.min(by: { abs($0.date.timeIntervalSince(d)) < abs($1.date.timeIntervalSince(d)) }) }
        let unit: Calendar.Component = range == .year ? .month : .day
        return VStack(alignment: .leading, spacing: 14) {
            Picker("Range", selection: $range) {
                ForEach(ChartRange.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            HStack(spacing: 4) {
                if let selected {
                    Text(selected.date, format: range == .year ? .dateTime.month(.wide) : .dateTime.month(.abbreviated).day())
                        .foregroundStyle(Theme.secondaryInk)
                    Text(Money.format(selected.value, currency)).fontWeight(.bold).foregroundStyle(Theme.ink)
                } else {
                    Text("Spent").foregroundStyle(Theme.secondaryInk)
                    Text(Money.format(f.spendingTotal(range), currency)).fontWeight(.bold).foregroundStyle(Theme.ink)
                        .contentTransition(.numericText())
                }
            }
            .font(.title3.monospacedDigit())

            Chart {
                ForEach(points) { p in
                    AreaMark(x: .value("Date", p.date, unit: unit), y: .value("Spent", p.value))
                        .interpolationMethod(.catmullRom)
                        .foregroundStyle(LinearGradient(colors: [Theme.cobalt.opacity(0.18), Theme.cobalt.opacity(0.01)], startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("Date", p.date, unit: unit), y: .value("Spent", p.value))
                        .interpolationMethod(.catmullRom)
                        .foregroundStyle(Theme.cobalt)
                        .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                }
                if let selected {
                    RuleMark(x: .value("Date", selected.date, unit: unit))
                        .foregroundStyle(Theme.ink.opacity(0.25))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    PointMark(x: .value("Date", selected.date, unit: unit), y: .value("Spent", selected.value))
                        .symbolSize(90)
                        .foregroundStyle(Theme.cobalt)
                }
            }
            .chartXSelection(value: $selectedDate)
            .chartYAxis {
                AxisMarks(position: .trailing) { v in
                    AxisGridLine().foregroundStyle(Theme.track)
                    AxisValueLabel { if let d = v.as(Double.self) { Text(Money.short(d)) } }
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: range == .week ? 7 : 5)) { _ in
                    AxisValueLabel(format: range == .year ? .dateTime.month(.narrow) : (range == .week ? .dateTime.weekday(.abbreviated) : .dateTime.month(.abbreviated).day()))
                }
            }
            .frame(height: 170)
            .animation(.easeInOut(duration: 0.35), value: range)
        }
        .card()
        .sensoryFeedback(.selection, trigger: range)
    }

    private func statTiles(_ f: Finance) -> some View {
        HStack(spacing: 10) {
            StatTile(title: "Income", value: f.monthIncome, symbol: "arrow.down", color: Theme.positive, currency: currency)
            StatTile(title: "Expenses", value: f.monthExpenses, symbol: "arrow.up", color: Theme.negative, currency: currency)
            StatTile(title: "Saved", value: max(0, f.monthNet), symbol: "banknote.fill", color: Theme.cobalt, currency: currency)
        }
    }

    private func safeCard(_ f: Finance) -> some View {
        let safe = f.safeToSpend
        return NavigationLink(value: HomeRoute.safe) {
            HStack(spacing: 18) {
                ZStack {
                    RingView(progress: f.budgetUsed, lineWidth: 11, color: f.budgetUsed > 0.95 ? Theme.negative : Theme.cobalt)
                    Text(f.totalBudget > 0 ? "\(Int(f.budgetUsed * 100))%" : "—")
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(Theme.ink)
                }
                .frame(width: 86, height: 86)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Safe to spend today").font(.headline).foregroundStyle(Theme.ink)
                    Text(Money.format(safe.daily, currency))
                        .font(.title2.bold().monospacedDigit())
                        .foregroundStyle(safe.isShort ? Theme.negative : Theme.cobalt)
                        .contentTransition(.numericText(value: safe.daily))
                    if f.totalBudget > 0 {
                        Text("Budget left \(Money.format(f.budgetLeft, currency)) of \(Money.number(f.totalBudget, decimals: Money.digits(currency)))")
                            .font(.subheadline)
                            .foregroundStyle(Theme.secondaryInk)
                    } else {
                        Text("Set budgets to protect essentials").font(.subheadline).foregroundStyle(Theme.secondaryInk)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .card()
        }
        .buttonStyle(PressableStyle())
    }

    @ViewBuilder
    private var duplicatesBanner: some View {
        let count = transactions.filter(\.isPossibleDuplicate).count
        if count > 0 {
            Button { appState.tab = .transactions } label: {
                HStack(spacing: 12) {
                    IconBadge(symbol: "exclamationmark.2", color: Theme.negative, size: 38)
                    Text("\(count) possible duplicate\(count == 1 ? "" : "s") to review")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.ink)
                    Spacer()
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                }
                .card(padding: 12)
            }
            .buttonStyle(PressableStyle())
        }
    }

    private func netWorthCard(_ f: Finance) -> some View {
        NavigationLink(value: HomeRoute.netWorth) {
            HStack(spacing: 12) {
                IconBadge(symbol: "chart.pie.fill", color: Color(hex: 0x8B5CF6))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Net worth").font(.subheadline).foregroundStyle(Theme.secondaryInk)
                    Text(Money.format(f.netWorth, currency)).font(.headline.monospacedDigit()).foregroundStyle(Theme.ink)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Assets \(Money.short(f.totalAssets))").font(.caption).foregroundStyle(Theme.positive)
                    Text("Debts \(Money.short(f.totalLiabilities))").font(.caption).foregroundStyle(Theme.negative)
                }
                .monospacedDigit()
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .card()
        }
        .buttonStyle(PressableStyle())
    }

    private func billsSection(_ f: Finance) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: "Upcoming bills") {
                NavigationLink("See all", value: HomeRoute.bills).font(.subheadline.weight(.medium))
            }
            .padding(.horizontal, 4)
            VStack(spacing: 0) {
                let upcoming = Array(f.upcomingBills.prefix(3))
                if upcoming.isEmpty {
                    NavigationLink(value: HomeRoute.bills) {
                        HStack {
                            IconBadge(symbol: "calendar.badge.plus", color: Theme.cobalt)
                            Text("Add your first bill to get reminders").font(.subheadline).foregroundStyle(Theme.ink)
                            Spacer()
                        }
                        .padding(14)
                    }
                    .buttonStyle(.plain)
                }
                ForEach(Array(upcoming.enumerated()), id: \.element.id) { index, bill in
                    Button { billToPay = bill } label: {
                        BillRow(bill: bill, currency: currency).padding(.horizontal, 14).padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)
                    if index < upcoming.count - 1 { Divider().padding(.leading, 70) }
                }
            }
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            .shadow(color: Theme.ink.opacity(0.04), radius: 14, y: 4)
        }
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: .now)
        let part = hour < 12 ? "Good morning" : (hour < 17 ? "Good afternoon" : "Good evening")
        return userName.isEmpty ? part : "\(part), \(userName)"
    }

    private var initials: String {
        let parts = userName.split(separator: " ")
        let letters = parts.prefix(2).compactMap(\.first).map(String.init).joined()
        return letters.isEmpty ? "Me" : letters.uppercased()
    }
}

enum HomeRoute: Hashable { case safe, netWorth, bills }

struct StatTile: View {
    let title: String
    let value: Double
    let symbol: String
    let color: Color
    let currency: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: symbol)
                .font(.footnote.weight(.bold))
                .foregroundStyle(color)
                .frame(width: 30, height: 30)
                .background(color.opacity(0.13), in: Circle())
            Text(title).font(.caption).foregroundStyle(Theme.secondaryInk)
            Text(Money.format(value, currency))
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .card(padding: 12)
        .accessibilityElement(children: .combine)
    }
}

struct BillRow: View {
    let bill: Bill
    let currency: String

    var body: some View {
        HStack(spacing: 12) {
            CategoryIcon(category: bill.category)
            VStack(alignment: .leading, spacing: 3) {
                Text(bill.name).font(.body.weight(.medium)).foregroundStyle(Theme.ink).lineLimit(1)
                Text(dueText).font(.subheadline).foregroundStyle(isOverdue ? Theme.negative : Theme.secondaryInk)
            }
            Spacer()
            Text(Money.format(bill.amount, currency)).font(.body.weight(.semibold).monospacedDigit()).foregroundStyle(Theme.ink)
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }

    private var isOverdue: Bool { bill.nextDueDate < Calendar.current.startOfDay(for: .now) }

    private var dueText: String {
        let cal = Calendar.current
        if isOverdue { return "Overdue · \(bill.nextDueDate.formatted(.dateTime.month(.abbreviated).day()))" }
        if cal.isDateInToday(bill.nextDueDate) { return "Due today" }
        if cal.isDateInTomorrow(bill.nextDueDate) { return "Due tomorrow" }
        return bill.nextDueDate.formatted(.dateTime.month(.abbreviated).day())
    }
}
