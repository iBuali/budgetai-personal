import SwiftUI
import SwiftData
import Charts

private enum SpendingChartStyle: String, CaseIterable, Identifiable {
    case pie = "Pie"
    case bar = "Bar"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .pie: "chart.pie.fill"
        case .bar: "chart.bar.fill"
        }
    }
}

private struct CategoryPieChart: View {
    let breakdown: [(category: SpendCategory, amount: Double)]
    let totalSpent: Double
    @Binding var selectedCategory: SpendCategory?
    @State private var angleSelection: Double?

    var body: some View {
        let active = selectedCategory.flatMap { cat in
            breakdown.first(where: { $0.category == cat })
        } ?? breakdown.first

        return ZStack {
            Chart(breakdown, id: \.category.id) { item in
                let isSelected = selectedCategory == item.category
                SectorMark(
                    angle: .value("Amount", item.amount),
                    innerRadius: .ratio(0.62),
                    outerRadius: .ratio(isSelected ? 1.0 : (selectedCategory == nil ? 0.94 : 0.87)),
                    angularInset: 2
                )
                .cornerRadius(6)
                .foregroundStyle(item.category.color)
                .opacity(selectedCategory == nil || isSelected ? 1.0 : 0.32)
            }
            .chartAngleSelection(value: $angleSelection)
            .frame(height: 196)
            .animation(.snappy(duration: 0.25), value: selectedCategory)
            .onChange(of: angleSelection) { _, newValue in
                guard let newValue else { return }
                var cumulative = 0.0
                for item in breakdown {
                    cumulative += item.amount
                    if newValue <= cumulative {
                        if selectedCategory != item.category {
                            withAnimation(.snappy(duration: 0.22)) {
                                selectedCategory = item.category
                            }
                        }
                        break
                    }
                }
            }

            if let active {
                let pct = totalSpent > 0 ? Int((active.amount / totalSpent * 100).rounded()) : 0
                VStack(spacing: 3) {
                    Image(systemName: active.category.symbol)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(active.category.color)
                    if selectedCategory == nil {
                        Text("Top")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(Theme.secondaryInk)
                    }
                    Text(active.category.shortTitle)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                    Text("\(pct)%")
                        .font(.title3.weight(.bold).monospacedDigit())
                        .foregroundStyle(Theme.ink)
                }
                .frame(maxWidth: 100)
                .allowsHitTesting(false)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

private struct CategoryBarChart: View {
    let breakdown: [(category: SpendCategory, amount: Double)]
    @Binding var selectedCategory: SpendCategory?
    @State private var selectedRaw: String?

    var body: some View {
        let chartItems = Array(breakdown.prefix(8))
        return Chart(chartItems, id: \.category.id) { item in
            let isSelected = selectedCategory == item.category
            BarMark(
                x: .value("Category", item.category.rawValue),
                y: .value("Spent", item.amount)
            )
            .cornerRadius(6)
            .foregroundStyle(item.category.color)
            .opacity(selectedCategory == nil || isSelected ? 1.0 : 0.32)
            .annotation(position: .top, spacing: 4) {
                if isSelected || (selectedCategory == nil && item.category == chartItems.first?.category) {
                    Text(Money.short(item.amount))
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(isSelected ? item.category.color : Theme.secondaryInk)
                }
            }
        }
        .chartXSelection(value: $selectedRaw)
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
        .chartXAxis {
            AxisMarks(values: chartItems.map(\.category.rawValue)) { value in
                AxisValueLabel {
                    if let raw = value.as(String.self), let cat = SpendCategory(rawValue: raw) {
                        Image(systemName: cat.symbol)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(selectedCategory == cat ? cat.color : Theme.secondaryInk)
                    }
                }
            }
        }
        .frame(height: 196)
        .animation(.snappy(duration: 0.25), value: selectedCategory)
        .onChange(of: selectedRaw) { _, newValue in
            guard let newValue, let cat = SpendCategory(rawValue: newValue) else { return }
            if selectedCategory != cat {
                withAnimation(.snappy(duration: 0.22)) {
                    selectedCategory = cat
                }
            }
        }
    }
}

struct HomeView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var context
    @Query(sort: \MoneyTransaction.date, order: .reverse) private var transactions: [MoneyTransaction]
    @Query(sort: \Account.createdAt) private var accounts: [Account]
    @Query private var budgets: [Budget]
    @Query private var goals: [SavingsGoal]
    @Query(sort: \Bill.nextDueDate) private var bills: [Bill]
    @AppStorage(Keys.currency) private var currency = "BHD"
    @AppStorage(Keys.userName) private var userName = ""
    @AppStorage(Keys.cycleStartDay) private var cycleStartDay = 1
    @AppStorage(Keys.homeAccountOrder) private var homeAccountOrder = ""
    @AppStorage(Keys.homeHiddenAccounts) private var homeHiddenAccounts = ""
    @State private var range: ChartRange = .month
    @State private var chartStyle: SpendingChartStyle = .pie
    @State private var selectedCategory: SpendCategory?
    @State private var showAllCategories = false
    @State private var showCustomizeItems = false
    @State private var billToPay: Bill?

    private var finance: Finance {
        Finance(transactions: transactions, accounts: accounts, budgets: budgets, goals: goals, bills: bills)
    }

    var body: some View {
        let _ = cycleStartDay
        let f = finance
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    header(f)
                    spendingCard(f)
                    financialItemsSection
                    safeCard(f)
                    duplicatesBanner
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
                case .netWorthAccount(let accountID): NetWorthView(initialAccountID: accountID)
                case .bills: BillsView()
                }
            }
            .sheet(isPresented: $showCustomizeItems) {
                HomeFinancialItemsCustomizeSheet(
                    accounts: accounts,
                    currency: currency,
                    orderRaw: $homeAccountOrder,
                    hiddenRaw: $homeHiddenAccounts
                )
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
                    NavigationLink(value: HomeRoute.netWorth) {
                        HStack(spacing: 4) {
                            Text("Net worth").font(.body).foregroundStyle(Theme.secondaryInk)
                            Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(Theme.secondaryInk)
                        }
                    }
                    .buttonStyle(.plain)
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
            Text(Money.format(f.netWorth, currency))
                .font(.system(size: 42, weight: .bold).monospacedDigit())
                .foregroundStyle(f.netWorth < 0 ? Theme.negative : Theme.ink)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
                .animatedNumber(f.netWorth)
            Text("\(Money.format(f.monthNet, currency, signed: true)) \(Cycle.startDay == 1 ? "this month" : "this cycle")")
                .font(.subheadline.weight(.medium).monospacedDigit())
                .foregroundStyle(f.monthNet >= 0 ? Theme.positive : Theme.negative)
                .animatedNumber(f.monthNet)
        }
        .padding(.top, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func spendingCard(_ f: Finance) -> some View {
        let breakdown = f.categoryBreakdown(range)
        let totalSpent = breakdown.reduce(0) { $0 + $1.amount }
        let activeSlice = selectedCategory.flatMap { cat in
            breakdown.first(where: { $0.category == cat })
        }

        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Spending by Category")
                        .font(.headline)
                        .foregroundStyle(Theme.ink)
                    Text(f.rangeSubtitle(range))
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryInk)
                }

                Spacer()

                HStack(spacing: 2) {
                    ForEach(SpendingChartStyle.allCases) { style in
                        Button {
                            withAnimation(.snappy(duration: 0.25)) {
                                chartStyle = style
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: style.symbol)
                                    .font(.caption.weight(.semibold))
                                Text(style.rawValue)
                                    .font(.caption.weight(.semibold))
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .foregroundStyle(chartStyle == style ? .white : Theme.secondaryInk)
                            .background {
                                if chartStyle == style {
                                    Capsule().fill(Theme.cobalt)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(style.rawValue) chart")
                    }
                }
                .padding(3)
                .background(Theme.track.opacity(0.85), in: Capsule())
            }

            Picker("Range", selection: $range) {
                ForEach(ChartRange.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .onChange(of: range) { _, _ in
                selectedCategory = nil
                showAllCategories = false
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let active = activeSlice {
                    let pct = totalSpent > 0 ? Int((active.amount / totalSpent * 100).rounded()) : 0
                    HStack(spacing: 6) {
                        Circle()
                            .fill(active.category.color)
                            .frame(width: 9, height: 9)
                        Text(active.category.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.ink)
                            .lineLimit(1)
                    }
                    Text(Money.format(active.amount, currency))
                        .font(.title3.weight(.bold).monospacedDigit())
                        .foregroundStyle(Theme.ink)
                        .animatedNumber(active.amount)
                    Text("\(pct)%")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(active.category.color)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(active.category.color.opacity(0.14), in: Capsule())
                    Spacer(minLength: 0)
                    Button {
                        withAnimation(.snappy(duration: 0.25)) {
                            selectedCategory = nil
                        }
                    } label: {
                        Text("All")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.cobalt)
                    }
                    .buttonStyle(.plain)
                } else {
                    Text("Spent")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Theme.secondaryInk)
                    Text(Money.format(totalSpent, currency))
                        .font(.title2.weight(.bold).monospacedDigit())
                        .foregroundStyle(Theme.ink)
                        .animatedNumber(totalSpent)
                    Spacer(minLength: 0)
                    if !breakdown.isEmpty {
                        Text("\(breakdown.count) \(breakdown.count == 1 ? "category" : "categories")")
                            .font(.caption.weight(.medium).monospacedDigit())
                            .foregroundStyle(Theme.secondaryInk)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Theme.track.opacity(0.75), in: Capsule())
                    }
                }
            }

            if breakdown.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: chartStyle.symbol)
                        .font(.system(size: 28, weight: .medium))
                        .foregroundStyle(Theme.secondaryInk.opacity(0.55))
                    Text("No spending recorded \(range == .week ? "this week" : range == .month ? "this cycle" : "this year")")
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondaryInk)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 170)
            } else {
                if chartStyle == .pie {
                    CategoryPieChart(
                        breakdown: breakdown,
                        totalSpent: totalSpent,
                        selectedCategory: $selectedCategory
                    )
                } else {
                    CategoryBarChart(
                        breakdown: breakdown,
                        selectedCategory: $selectedCategory
                    )
                }

                Divider()
                    .padding(.vertical, 2)

                categoryBreakdownList(breakdown: breakdown, totalSpent: totalSpent)
            }
        }
        .card()
        .sensoryFeedback(.selection, trigger: range)
        .sensoryFeedback(.selection, trigger: chartStyle)
    }

    private func categoryBreakdownList(breakdown: [(category: SpendCategory, amount: Double)], totalSpent: Double) -> some View {
        let limit = 5
        let visible = showAllCategories ? breakdown : Array(breakdown.prefix(limit))
        let maxAmount = breakdown.first?.amount ?? 1

        return VStack(spacing: 6) {
            ForEach(visible, id: \.category.id) { item in
                let isSelected = selectedCategory == item.category
                let pct = totalSpent > 0 ? Int((item.amount / totalSpent * 100).rounded()) : 0
                let ratio = maxAmount > 0 ? min(1, max(0.05, item.amount / maxAmount)) : 0

                Button {
                    withAnimation(.snappy(duration: 0.22)) {
                        selectedCategory = isSelected ? nil : item.category
                    }
                } label: {
                    HStack(spacing: 10) {
                        CategoryIcon(category: item.category, size: 28)

                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Text(item.category.title)
                                    .font(.subheadline.weight(isSelected ? .semibold : .medium))
                                    .foregroundStyle(Theme.ink)
                                    .lineLimit(1)
                                Spacer(minLength: 4)
                                Text("\(pct)%")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(Theme.secondaryInk)
                                Text(Money.format(item.amount, currency))
                                    .font(.subheadline.weight(.semibold).monospacedDigit())
                                    .foregroundStyle(Theme.ink)
                            }

                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule()
                                        .fill(Theme.track.opacity(0.65))
                                    Capsule()
                                        .fill(item.category.color)
                                        .frame(width: geo.size.width * ratio)
                                }
                            }
                            .frame(height: 4)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(
                        isSelected ? item.category.color.opacity(0.11) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )
                    .opacity(selectedCategory == nil || isSelected ? 1.0 : 0.45)
                }
                .buttonStyle(.plain)
            }

            if breakdown.count > limit {
                Button {
                    withAnimation(.snappy(duration: 0.25)) {
                        showAllCategories.toggle()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(showAllCategories ? "Show fewer" : "Show all \(breakdown.count) categories")
                        Image(systemName: showAllCategories ? "chevron.up" : "chevron.down")
                            .font(.caption2.weight(.semibold))
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.cobalt)
                    .padding(.top, 4)
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var financialItemsSection: some View {
        let visibleItems = HomeAccountPreferences.orderedAccounts(
            from: accounts,
            orderRaw: homeAccountOrder,
            hiddenRaw: homeHiddenAccounts,
            includeHidden: false
        )

        if accounts.isEmpty {
            NavigationLink(value: HomeRoute.netWorth) {
                HStack(spacing: 12) {
                    IconBadge(symbol: "plus.circle.fill", color: Theme.cobalt, size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Add an account, card, or loan")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.ink)
                        Text("Track balances here with a quick swipe")
                            .font(.caption)
                            .foregroundStyle(Theme.secondaryInk)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .card(padding: 12)
            }
            .buttonStyle(PressableStyle())
        } else {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Accounts & Loans")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.secondaryInk)
                    Spacer()
                    Button {
                        showCustomizeItems = true
                    } label: {
                        Label("Customize", systemImage: "slider.horizontal.3")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.cobalt)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 4)

                if visibleItems.isEmpty {
                    Button {
                        showCustomizeItems = true
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "eye.slash")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Theme.secondaryInk)
                            Text("All items are hidden · Tap to customize")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(Theme.secondaryInk)
                            Spacer()
                        }
                        .card(padding: 12)
                    }
                    .buttonStyle(PressableStyle())
                    .padding(.top, 4)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(visibleItems) { account in
                                NavigationLink(value: HomeRoute.netWorthAccount(account.id)) {
                                    HomeFinancialItemCard(account: account, currency: currency)
                                }
                                .buttonStyle(PressableStyle())
                                .containerRelativeFrame(.horizontal, count: 2, span: 1, spacing: 10)
                                .contextMenu {
                                    Button {
                                        showCustomizeItems = true
                                    } label: {
                                        Label("Customize Items", systemImage: "slider.horizontal.3")
                                    }
                                    Button(role: .destructive) {
                                        withAnimation(.snappy) {
                                            homeHiddenAccounts = HomeAccountPreferences.toggleVisibility(
                                                for: account.id,
                                                hiddenRaw: homeHiddenAccounts
                                            )
                                        }
                                    } label: {
                                        Label("Hide from Home", systemImage: "eye.slash")
                                    }
                                }
                            }
                        }
                        .scrollTargetLayout()
                        .padding(.vertical, 4)
                    }
                    .scrollTargetBehavior(.viewAligned)
                }
            }
        }
    }

    private func safeCard(_ f: Finance) -> some View {
        let safe = f.safeToSpend
        let totalPool = max(safe.spendable + f.monthExpenses, safe.spendable)
        let safeRatio = totalPool > 0 ? min(max(safe.monthly / totalPool, 0), 1) : 0
        let pct = Int((safeRatio * 100).rounded())
        return NavigationLink(value: HomeRoute.safe) {
            HStack(spacing: 18) {
                ZStack {
                    RingView(progress: safeRatio, lineWidth: 11, color: safe.isShort ? Theme.negative : Theme.cobalt)
                    Text("\(pct)%")
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(Theme.ink)
                        .animatedNumber(Double(pct))
                }
                .frame(width: 86, height: 86)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Safe to spend today")
                        .font(.headline)
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    Text(Money.format(safe.daily, currency))
                        .font(.title2.bold().monospacedDigit())
                        .foregroundStyle(safe.isShort ? Theme.negative : Theme.cobalt)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .layoutPriority(1)
                        .animatedNumber(safe.daily)
                    Text("\(Money.format(safe.monthly, currency)) safe of \(Money.format(safe.spendable, currency)) · \(safe.daysLeft)d left")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(Theme.secondaryInk)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .animatedNumber(safe.monthly)
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
        let counts = transactions.reduce(into: (pending: 0, duplicate: 0)) { acc, tx in
            if tx.isPending { acc.pending += 1 }
            if tx.isPossibleDuplicate { acc.duplicate += 1 }
        }
        if counts.pending > 0 {
            Button { appState.openTransactions(filter: .review) } label: {
                HStack(spacing: 12) {
                    IconBadge(symbol: "clock.fill", color: Theme.warning, size: 38)
                    Text("\(counts.pending) SMS transaction\(counts.pending == 1 ? "" : "s") to approve")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.ink)
                    Spacer()
                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                }
                .card(padding: 12)
            }
            .buttonStyle(PressableStyle())
        }
        if counts.duplicate > 0 {
            Button { appState.openTransactions(filter: .review) } label: {
                HStack(spacing: 12) {
                    IconBadge(symbol: "exclamationmark.2", color: Theme.negative, size: 38)
                    Text("\(counts.duplicate) possible duplicate\(counts.duplicate == 1 ? "" : "s") to review")
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
                        HStack(spacing: 12) {
                            if f.bills.isEmpty {
                                IconBadge(symbol: "calendar.badge.plus", color: Theme.cobalt)
                                Text("Add your first bill to get reminders").font(.subheadline).foregroundStyle(Theme.ink)
                            } else {
                                IconBadge(symbol: "checkmark.seal.fill", color: Theme.positive)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("All bills paid for this month 🎉").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
                                    Text("Next cycle starts next month").font(.caption).foregroundStyle(Theme.secondaryInk)
                                }
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
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

enum HomeRoute: Hashable {
    case safe
    case netWorth
    case netWorthAccount(UUID)
    case bills
}

private struct HomeFinancialItemCard: View {
    let account: Account
    let currency: String

    private var displayedAmount: Double {
        switch account.kind {
        case .creditCard: account.cardUsedBalance
        case .loan: account.loanRemainingBalance
        default: account.balance
        }
    }

    private var progressValue: Double? {
        switch account.kind {
        case .creditCard: account.cardUsedProgress
        case .loan: account.loanPaidProgress
        default: nil
        }
    }

    private var progressTint: Color {
        switch account.kind {
        case .creditCard:
            let p = account.cardUsedProgress
            if p >= 0.9 { return Theme.negative }
            if p >= 0.7 { return Theme.warning }
            return account.kind.color
        case .loan:
            return Theme.positive
        default:
            return account.kind.color
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                AccountIcon(account: account, size: 28)
                Text(account.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: 6) {
                Text(Money.format(displayedAmount, currency))
                    .font(.subheadline.weight(.bold).monospacedDigit())
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .animatedNumber(displayedAmount)

                if let progress = progressValue {
                    GeometryReader { geo in
                        let clamped = min(1, max(0, progress))
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(progressTint.opacity(0.16))
                            Capsule()
                                .fill(progressTint)
                                .frame(width: clamped > 0 ? max(5, geo.size.width * clamped) : 0)
                        }
                    }
                    .frame(height: 5)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 74, alignment: .topLeading)
        .card(padding: 12)
        .accessibilityElement(children: .combine)
    }
}

private struct HomeFinancialItemsCustomizeSheet: View {
    let accounts: [Account]
    let currency: String
    @Binding var orderRaw: String
    @Binding var hiddenRaw: String
    @Environment(\.dismiss) private var dismiss

    private var orderedAccounts: [Account] {
        HomeAccountPreferences.orderedAccounts(
            from: accounts,
            orderRaw: orderRaw,
            hiddenRaw: hiddenRaw,
            includeHidden: true
        )
    }

    private var hiddenIDs: Set<UUID> {
        HomeAccountPreferences.hiddenSet(hiddenRaw)
    }

    private func displayedBalance(for account: Account) -> Double {
        switch account.kind {
        case .creditCard: account.cardUsedBalance
        case .loan: account.loanRemainingBalance
        default: account.balance
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(orderedAccounts) { account in
                        let isHidden = hiddenIDs.contains(account.id)
                        HStack(spacing: 12) {
                            AccountIcon(account: account, size: 32)
                                .opacity(isHidden ? 0.45 : 1)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(account.name)
                                    .font(.body.weight(.medium))
                                    .foregroundStyle(isHidden ? Theme.secondaryInk : Theme.ink)
                                    .lineLimit(1)
                                Text(Money.format(displayedBalance(for: account), currency))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(Theme.secondaryInk)
                            }

                            Spacer(minLength: 8)

                            Button {
                                withAnimation(.snappy) {
                                    hiddenRaw = HomeAccountPreferences.toggleVisibility(
                                        for: account.id,
                                        hiddenRaw: hiddenRaw
                                    )
                                }
                            } label: {
                                Image(systemName: isHidden ? "eye.slash" : "eye.fill")
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(isHidden ? Theme.secondaryInk : Theme.cobalt)
                                    .frame(width: 32, height: 32)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(isHidden ? "Show \(account.name)" : "Hide \(account.name)")
                        }
                    }
                    .onMove { source, destination in
                        orderRaw = HomeAccountPreferences.move(
                            from: source,
                            to: destination,
                            in: accounts,
                            orderRaw: orderRaw
                        )
                    }
                } header: {
                    Text("Visible & Order")
                } footer: {
                    Text("Drag rows to rearrange their order on Home, or tap the eye icon to show or hide items.")
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Customize Items")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Reset") {
                        withAnimation(.snappy) {
                            orderRaw = ""
                            hiddenRaw = ""
                        }
                    }
                    .disabled(orderRaw.isEmpty && hiddenRaw.isEmpty)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
    }
}

struct BillRow: View {
    let bill: Bill
    let currency: String
    @State private var animateCheck = false

    private var isPaid: Bool { bill.isPaidForCurrentCycle() }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                CategoryIcon(category: bill.category)
                if isPaid {
                    Circle()
                        .strokeBorder(Theme.positive, lineWidth: 2)
                        .background(Circle().fill(Theme.positive.opacity(0.12)))
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(bill.name)
                    .font(.body.weight(.medium))
                    .foregroundStyle(isPaid ? Theme.secondaryInk : Theme.ink)
                    .lineLimit(1)

                if isPaid {
                    HStack(spacing: 4) {
                        Image(systemName: bill.lastPaidMethod == .autoSMS ? "sparkles" : "checkmark.circle.fill")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(bill.lastPaidMethod == .autoSMS ? Theme.cobalt : Theme.positive)

                        Text("Paid for this month")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.positive)

                        if let method = bill.lastPaidMethod {
                            Text("· \(method.title)")
                                .font(.caption2)
                                .foregroundStyle(Theme.secondaryInk)
                        }
                    }
                } else {
                    Text(dueText)
                        .font(.subheadline)
                        .foregroundStyle(isOverdue ? Theme.negative : Theme.secondaryInk)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(Money.format(isPaid ? (bill.lastPaidAmount ?? bill.amount) : bill.amount, currency))
                    .font(.body.weight(.semibold).monospacedDigit())
                    .foregroundStyle(isPaid ? Theme.secondaryInk : Theme.ink)
                    .animatedNumber(bill.amount)

                if isPaid {
                    HStack(spacing: 3) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                        Text(bill.lastPaidMethod == .autoSMS ? "Auto" : "Manual")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .foregroundStyle(bill.lastPaidMethod == .autoSMS ? Theme.cobalt : Theme.positive)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background((bill.lastPaidMethod == .autoSMS ? Theme.cobalt : Theme.positive).opacity(0.12), in: Capsule())
                    .scaleEffect(animateCheck ? 1.0 : 0.6)
                    .animation(.spring(response: 0.45, dampingFraction: 0.6), value: animateCheck)
                }
            }

            if !isPaid {
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
        .onAppear {
            if isPaid {
                animateCheck = true
            }
        }
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
