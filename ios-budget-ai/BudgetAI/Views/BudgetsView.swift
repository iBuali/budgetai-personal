import SwiftUI
import SwiftData

struct BudgetsView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \MoneyTransaction.date, order: .reverse) private var transactions: [MoneyTransaction]
    @Query private var accounts: [Account]
    @Query(sort: \Budget.createdAt) private var budgets: [Budget]
    @Query(sort: \SavingsGoal.createdAt) private var goals: [SavingsGoal]
    @Query private var bills: [Bill]
    @AppStorage(Keys.currency) private var currency = "BHD"
    @State private var monthOffset = 0
    @State private var editingBudget: Budget?
    @State private var showNewBudget = false
    @State private var editingGoal: SavingsGoal?
    @State private var showNewGoal = false

    private var finance: Finance {
        Finance(transactions: transactions, accounts: accounts, budgets: budgets, goals: goals, bills: bills)
    }

    private var selectedMonth: Date {
        Calendar.current.date(byAdding: .month, value: -monthOffset, to: .now) ?? .now
    }

    var body: some View {
        let f = finance
        let interval = f.monthInterval(selectedMonth)
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    overview(f, interval: interval)
                    if monthOffset == 0 { safeRow(f) }
                    categorySection(f, interval: interval)
                    goalsSection
                    Button { showNewBudget = true } label: {
                        Label("New budget", systemImage: "plus").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .buttonBorderShape(.roundedRectangle(radius: 18))
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .canvasBackground()
            .navigationTitle("Budgets")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Month", selection: $monthOffset) {
                            ForEach(0..<6, id: \.self) { i in
                                let d = Calendar.current.date(byAdding: .month, value: -i, to: .now) ?? .now
                                Text(Cycle.startDay == 1 ? d.formatted(.dateTime.month(.wide).year()) : Cycle.label(Cycle.interval(containing: d))).tag(i)
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(Cycle.label(Cycle.interval(containing: selectedMonth), short: true))
                            Image(systemName: "chevron.down").font(.caption.weight(.bold))
                        }
                        .font(.subheadline.weight(.medium))
                    }
                }
            }
            .navigationDestination(for: HomeRoute.self) { _ in SafeToSpendView() }
            .sheet(item: $editingBudget) { BudgetEditor(budget: $0) }
            .sheet(isPresented: $showNewBudget) { BudgetEditor(budget: nil) }
            .sheet(item: $editingGoal) { GoalSheet(goal: $0) }
            .sheet(isPresented: $showNewGoal) { GoalSheet(goal: nil) }
        }
    }

    private func overview(_ f: Finance, interval: DateInterval) -> some View {
        let spent = f.budgetSpent(in: interval)
        let total = f.totalBudget
        let used = total > 0 ? spent / total : 0
        return HStack(spacing: 20) {
            ZStack {
                RingView(progress: used, lineWidth: 16, color: used > 1 ? Theme.negative : Theme.cobalt)
                VStack(spacing: 0) {
                    Text(total > 0 ? "\(Int(used * 100))%" : "—").font(.title2.bold().monospacedDigit()).foregroundStyle(Theme.ink)
                    Text("used").font(.caption).foregroundStyle(Theme.secondaryInk)
                }
            }
            .frame(width: 120, height: 120)
            VStack(alignment: .leading, spacing: 4) {
                Text(Cycle.label(interval)).font(.subheadline).foregroundStyle(Theme.secondaryInk)
                Text(Money.format(spent, currency))
                    .font(.title.bold().monospacedDigit())
                    .foregroundStyle(Theme.ink)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                Text("of \(Money.number(total, decimals: Money.digits(currency)))").font(.title3).foregroundStyle(Theme.secondaryInk)
                Text(monthOffset == 0 ? "\(Int(used * 100))% used · \(f.daysLeftInMonth) days left" : (spent <= total ? "Finished under budget" : "Went over budget"))
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryInk)
            }
            Spacer(minLength: 0)
        }
        .card(padding: 20)
    }

    private func safeRow(_ f: Finance) -> some View {
        NavigationLink(value: HomeRoute.safe) {
            HStack(spacing: 12) {
                IconBadge(symbol: "shield.checkered", color: Theme.positive)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Safe to spend").font(.subheadline).foregroundStyle(Theme.secondaryInk)
                    Text("\(Money.format(f.safeToSpend.daily, currency)) today · \(Money.format(f.safeToSpend.monthly, currency)) this month")
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(Theme.ink)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .card(padding: 14)
        }
        .buttonStyle(PressableStyle())
    }

    private func categorySection(_ f: Finance, interval: DateInterval) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionTitle(title: "Category budgets") {
                Button { showNewBudget = true } label: { Image(systemName: "plus.circle.fill").font(.title3) }
                    .accessibilityLabel("Add budget")
            }
            if budgets.isEmpty {
                Text("Set monthly limits for groceries, dining and more. We'll alert you at 80% and 100%.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondaryInk)
            }
            ForEach(budgets) { budget in
                let spent = f.spent(budget.category, in: interval)
                let ratio = budget.limit > 0 ? spent / budget.limit : 0
                Button { editingBudget = budget } label: {
                    HStack(spacing: 12) {
                        CategoryIcon(category: budget.category)
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(budget.category.title).font(.body.weight(.medium)).foregroundStyle(Theme.ink)
                                Spacer()
                                (Text(Money.format(spent, currency, decimals: 0)).fontWeight(.semibold).foregroundStyle(Theme.ink)
                                 + Text(" / \(Money.number(budget.limit, decimals: 0))").foregroundStyle(Theme.secondaryInk)
                                 + Text(ratio >= 0.8 ? " · \(Int(ratio * 100))%" : "").foregroundStyle(ratio >= 1 ? Theme.negative : Theme.secondaryInk))
                                    .font(.footnote.monospacedDigit())
                            }
                            ProgressBar(progress: ratio, color: ratio >= 0.9 ? Theme.negative : (ratio >= 0.8 ? Theme.warning : Theme.cobalt))
                        }
                        Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .card()
    }

    private var goalsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionTitle(title: "Savings goals") {
                Button { showNewGoal = true } label: { Image(systemName: "plus.circle.fill").font(.title3) }
                    .accessibilityLabel("Add goal")
            }
            if goals.isEmpty {
                Text("Save for an emergency fund, a trip or a new car. Monthly commitments are set aside in Safe to Spend.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondaryInk)
            }
            ForEach(goals) { goal in
                Button { editingGoal = goal } label: {
                    HStack(spacing: 12) {
                        IconBadge(symbol: goal.symbol, color: goal.isComplete ? Theme.positive : Theme.cobalt)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(goal.name).font(.body.weight(.medium)).foregroundStyle(Theme.ink)
                            Text("\(Money.format(goal.saved, currency, decimals: 0)) / \(Money.number(goal.target, decimals: 0)) · \(goal.targetDate.formatted(.dateTime.month(.abbreviated).year()))")
                                .font(.footnote.monospacedDigit())
                                .foregroundStyle(Theme.secondaryInk)
                            ProgressBar(progress: goal.progress, color: goal.progress >= 0.5 ? Theme.positive : Theme.cobalt)
                        }
                        Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .card()
    }
}

// MARK: - Editors

struct BudgetEditor: View {
    let budget: Budget?
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var budgets: [Budget]
    @AppStorage(Keys.currency) private var currency = "BHD"
    @State private var category: SpendCategory = .groceries
    @State private var limitText = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Category", selection: $category) {
                        ForEach(available) { c in Label(c.title, systemImage: c.symbol).tag(c) }
                    }
                    HStack {
                        Text("Monthly limit")
                        Spacer()
                        TextField(Money.format(0, currency), text: $limitText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .monospacedDigit()
                    }
                } footer: {
                    Text(category.isEssential ? "Essential category: what's left is protected in Safe to Spend." : "You'll get alerts at 80% and 100% of this limit.")
                }
                if let budget {
                    Section {
                        Button("Delete budget", role: .destructive) {
                            context.delete(budget)
                            try? context.save()
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(budget == nil ? "New budget" : "Edit budget")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save).fontWeight(.semibold).disabled((Money.parse(limitText) ?? 0) <= 0)
                }
            }
            .onAppear {
                if let budget {
                    category = budget.category
                    limitText = Money.number(budget.limit, decimals: Money.digits(currency)).replacingOccurrences(of: ",", with: "")
                } else if let first = available.first {
                    category = first
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var available: [SpendCategory] {
        let used = Set(budgets.filter { $0.id != budget?.id }.map(\.category))
        return SpendCategory.expenseCases.filter { !used.contains($0) && $0 != .transfers }
    }

    private func save() {
        let limit = Money.parse(limitText) ?? 0
        if let budget {
            budget.category = category
            budget.limit = limit
        } else {
            context.insert(Budget(category: category, limit: limit))
        }
        try? context.save()
        dismiss()
    }
}

struct GoalSheet: View {
    let goal: SavingsGoal?
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Account.createdAt) private var accounts: [Account]
    @AppStorage(Keys.currency) private var currency = "BHD"
    @State private var name = ""
    @State private var symbol = "star.fill"
    @State private var targetText = ""
    @State private var savedText = ""
    @State private var commitmentText = ""
    @State private var targetDate = Calendar.current.date(byAdding: .month, value: 6, to: .now) ?? .now
    @State private var contributionText = ""
    @State private var fromAccount: UUID?

    private let symbols = ["star.fill", "shield.lefthalf.filled", "airplane", "car.fill", "house.fill", "graduationcap.fill", "gift.fill", "heart.fill", "laptopcomputer", "ring"]

    var body: some View {
        NavigationStack {
            Form {
                if let goal {
                    Section {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("\(Money.format(goal.saved, currency)) of \(Money.format(goal.target, currency))")
                                .font(.headline.monospacedDigit())
                            ProgressBar(progress: goal.progress, color: Theme.positive, height: 9)
                            Text(suggestion(goal)).font(.footnote).foregroundStyle(Theme.secondaryInk)
                        }
                        .padding(.vertical, 4)
                    }
                    Section("Add money") {
                        HStack {
                            TextField(Money.format(0, currency), text: $contributionText).keyboardType(.decimalPad).monospacedDigit()
                            Button("Add") { contribute(goal) }
                                .buttonStyle(.borderedProminent)
                                .disabled((Money.parse(contributionText) ?? 0) <= 0)
                        }
                        Picker("From", selection: $fromAccount) {
                            Text("Don't move money").tag(UUID?.none)
                            ForEach(accounts.filter { $0.kind.isLiquid }) { Text($0.name).tag(UUID?.some($0.id)) }
                        }
                    }
                }
                Section("Goal") {
                    TextField("Name (e.g. Emergency fund)", text: $name)
                    HStack {
                        Text("Target")
                        Spacer()
                        TextField(Money.format(0, currency), text: $targetText).keyboardType(.decimalPad).multilineTextAlignment(.trailing).monospacedDigit()
                    }
                    if goal == nil {
                        HStack {
                            Text("Already saved")
                            Spacer()
                            TextField(Money.format(0, currency), text: $savedText).keyboardType(.decimalPad).multilineTextAlignment(.trailing).monospacedDigit()
                        }
                    }
                    HStack {
                        Text("Monthly commitment")
                        Spacer()
                        TextField(Money.format(0, currency), text: $commitmentText).keyboardType(.decimalPad).multilineTextAlignment(.trailing).monospacedDigit()
                    }
                    DatePicker("Target date", selection: $targetDate, in: Date.now..., displayedComponents: .date)
                }
                Section("Icon") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: 12) {
                        ForEach(symbols, id: \.self) { s in
                            Button { symbol = s } label: {
                                IconBadge(symbol: s, color: symbol == s ? Theme.cobalt : Theme.secondaryInk, size: 44)
                                    .overlay(RoundedRectangle(cornerRadius: 13).stroke(symbol == s ? Theme.cobalt : .clear, lineWidth: 2))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 4)
                }
                if let goal {
                    Section {
                        Button("Delete goal", role: .destructive) {
                            context.delete(goal)
                            try? context.save()
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(goal == nil ? "New goal" : goal!.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save).fontWeight(.semibold)
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || (Money.parse(targetText) ?? 0) <= 0)
                }
            }
            .onAppear(perform: load)
        }
    }

    private func plain(_ v: Double) -> String {
        Money.number(v, decimals: Money.digits(currency)).replacingOccurrences(of: ",", with: "")
    }

    private func load() {
        fromAccount = accounts.first(where: { $0.kind == .bank })?.id
        guard let goal else { return }
        name = goal.name
        symbol = goal.symbol
        targetText = plain(goal.target)
        commitmentText = plain(goal.monthlyCommitment)
        targetDate = goal.targetDate
    }

    private func suggestion(_ goal: SavingsGoal) -> String {
        if goal.isComplete { return "Goal reached. Nicely done." }
        let months = max(1, Calendar.current.dateComponents([.month], from: .now, to: goal.targetDate).month ?? 1)
        let needed = (goal.target - goal.saved) / Double(months)
        return "Save \(Money.format(needed, currency)) a month to reach it by \(goal.targetDate.formatted(.dateTime.month(.wide).year()))."
    }

    private func contribute(_ goal: SavingsGoal) {
        let amount = Money.parse(contributionText) ?? 0
        guard amount > 0 else { return }
        Ledger.contribute(to: goal, amount: amount, fromAccountID: fromAccount, context: context)
        contributionText = ""
        appState.show(goal.isComplete ? "\(goal.name) reached!" : "Added \(Money.format(amount, currency)) to \(goal.name)")
    }

    private func save() {
        let target = Money.parse(targetText) ?? 0
        let commitment = Money.parse(commitmentText) ?? 0
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if let goal {
            goal.name = trimmed
            goal.symbol = symbol
            goal.target = target
            goal.monthlyCommitment = commitment
            goal.targetDate = targetDate
        } else {
            context.insert(SavingsGoal(name: trimmed, symbol: symbol, target: target, saved: Money.parse(savedText) ?? 0,
                                       targetDate: targetDate, monthlyCommitment: commitment))
        }
        try? context.save()
        dismiss()
    }
}

// MARK: - Safe to spend

struct SafeToSpendView: View {
    @Query private var transactions: [MoneyTransaction]
    @Query private var accounts: [Account]
    @Query private var budgets: [Budget]
    @Query private var goals: [SavingsGoal]
    @Query private var bills: [Bill]
    @AppStorage(Keys.currency) private var currency = "BHD"

    var body: some View {
        let f = Finance(transactions: transactions, accounts: accounts, budgets: budgets, goals: goals, bills: bills)
        let s = f.safeToSpend
        List {
            Section {
                VStack(spacing: 8) {
                    Text("Safe to spend today").font(.subheadline).foregroundStyle(Theme.secondaryInk)
                    Text(Money.format(s.daily, currency))
                        .font(.system(size: 46, weight: .bold).monospacedDigit())
                        .foregroundStyle(s.isShort ? Theme.negative : Theme.cobalt)
                        .contentTransition(.numericText(value: s.daily))
                    Text("\(Money.format(s.monthly, currency)) for the next \(s.daysLeft) day\(s.daysLeft == 1 ? "" : "s")")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(Theme.secondaryInk)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .listRowBackground(Color.clear)
            }

            Section {
                row("Spendable balance", "Cash and bank accounts", s.spendable, symbol: "building.columns.fill", color: Theme.cobalt, sign: 1)
                row("Upcoming bills", "Due before month end", s.billsDue, symbol: "calendar", color: Theme.warning, sign: -1)
                row("Essential spending", "Left in essential budgets", s.essentials, symbol: "cart.fill", color: Color(hex: 0x22A565), sign: -1)
                row("Savings commitments", "Still to set aside this month", s.savings, symbol: "banknote.fill", color: Color(hex: 0x8B5CF6), sign: -1)
                LabeledContent {
                    Text(Money.format(s.monthly, currency)).font(.headline.monospacedDigit()).foregroundStyle(Theme.ink)
                } label: {
                    Text("Safe this month").font(.headline)
                }
            } header: {
                Text("How it's calculated")
            } footer: {
                Text(s.isShort
                     ? "Your commitments are higher than your spendable balance. Consider pausing a savings goal or moving money from savings."
                     : "Divided evenly across the \(s.daysLeft) days left this month. Spend less today and tomorrow's amount grows.")
            }

            if !bills.isEmpty {
                Section("Bills counted") {
                    ForEach(f.upcomingBills.filter { $0.nextDueDate < f.thisMonth.end }) { bill in
                        LabeledContent(bill.name) {
                            Text(Money.format(bill.amount, currency)).monospacedDigit()
                        }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .canvasBackground()
        .navigationTitle("Safe to Spend")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
    }

    private func row(_ title: String, _ subtitle: String, _ value: Double, symbol: String, color: Color, sign: Double) -> some View {
        HStack(spacing: 12) {
            IconBadge(symbol: symbol, color: color, size: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(Theme.ink)
                Text(subtitle).font(.caption).foregroundStyle(Theme.secondaryInk)
            }
            Spacer()
            Text(Money.format(value * sign, currency, signed: sign > 0))
                .font(.body.weight(.medium).monospacedDigit())
                .foregroundStyle(sign > 0 ? Theme.positive : Theme.ink)
        }
    }
}
