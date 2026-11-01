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
    @State private var expandedBudgets: Set<UUID> = []

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
            .sheet(item: $editingBudget) { BudgetEditor(budget: $0) }
            .sheet(isPresented: $showNewBudget) { BudgetEditor(budget: nil) }
            .sheet(item: $editingGoal) { GoalSheet(goal: $0) }
            .sheet(isPresented: $showNewGoal) { GoalSheet(goal: nil) }
            .sensoryFeedback(.selection, trigger: expandedBudgets)
            .sensoryFeedback(.selection, trigger: monthOffset)
        }
    }

    private func overview(_ f: Finance, interval: DateInterval) -> some View {
        let spent = f.budgetSpent(in: interval)
        let total = f.totalBudget
        let used = total > 0 ? spent / total : 0
        let pct = Int(used * 100)
        return HStack(spacing: 20) {
            ZStack {
                RingView(progress: used, lineWidth: 16, color: used > 1 ? Theme.negative : Theme.cobalt)
                VStack(spacing: 0) {
                    Text(total > 0 ? "\(pct)%" : "—")
                        .font(.title2.bold().monospacedDigit())
                        .foregroundStyle(Theme.ink)
                        .animatedNumber(Double(pct))
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
                    .animatedNumber(spent)
                Text("of \(Money.number(total, decimals: Money.digits(currency)))")
                    .font(.title3.monospacedDigit())
                    .foregroundStyle(Theme.secondaryInk)
                    .animatedNumber(total)
                Text(monthOffset == 0 ? "\(pct)% used · \(f.daysLeftInMonth) days left" : (spent <= total ? "Finished under budget" : "Went over budget"))
                    .font(.footnote)
                    .foregroundStyle(Theme.secondaryInk)
                    .animatedNumber(Double(pct))
            }
            Spacer(minLength: 0)
        }
        .card(padding: 20)
    }

    private func categorySection(_ f: Finance, interval: DateInterval) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionTitle(title: "Category budgets") {
                Button { showNewBudget = true } label: { Image(systemName: "plus.circle.fill").font(.title3) }
                    .accessibilityLabel("Add budget")
            }
            if budgets.isEmpty {
                Text("Create custom budgets and assign one or more categories to track your monthly spending.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondaryInk)
            }
            ForEach(budgets) { budget in
                let spent = f.spent(for: budget, in: interval)
                let ratio = budget.limit > 0 ? spent / budget.limit : 0
                let pct = Int(ratio * 100)
                let isExpanded = expandedBudgets.contains(budget.id)
                let cats = budget.categories

                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        Button {
                            withAnimation(.spring(response: 0.42, dampingFraction: 0.82, blendDuration: 0.12)) {
                                if isExpanded {
                                    expandedBudgets.remove(budget.id)
                                } else {
                                    expandedBudgets.insert(budget.id)
                                }
                            }
                        } label: {
                            HStack(spacing: 12) {
                                CategoryIcon(category: budget.category)
                                    .scaleEffect(isExpanded ? 1.04 : 1.0)
                                    .animation(.spring(response: 0.35, dampingFraction: 0.7), value: isExpanded)
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack(alignment: .top) {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(budget.displayName)
                                                .font(.body.weight(.semibold))
                                                .foregroundStyle(Theme.ink)
                                                .lineLimit(1)
                                                .minimumScaleFactor(0.85)
                                            Text("\(cats.count) categor\(cats.count == 1 ? "y" : "ies")")
                                                .font(.caption2)
                                                .foregroundStyle(Theme.secondaryInk)
                                        }
                                        Spacer(minLength: 8)
                                        HStack(spacing: 0) {
                                            Text(Money.format(spent, currency, decimals: 0))
                                                .fontWeight(.semibold)
                                                .foregroundStyle(Theme.ink)
                                                .animatedNumber(spent)
                                            Text(" / \(Money.number(budget.limit, decimals: 0))")
                                                .foregroundStyle(Theme.secondaryInk)
                                                .animatedNumber(budget.limit)
                                            Text(" · \(pct)%")
                                                .foregroundStyle(ratio >= 1 ? Theme.negative : (ratio >= 0.8 ? Theme.warning : Theme.secondaryInk))
                                                .animatedNumber(Double(pct))
                                        }
                                        .font(.footnote.monospacedDigit())
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.75)
                                        .layoutPriority(1)
                                    }
                                    ProgressBar(progress: ratio, color: ratio >= 0.9 ? Theme.negative : (ratio >= 0.8 ? Theme.warning : Theme.cobalt))
                                }
                                Image(systemName: "chevron.down")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(isExpanded ? Theme.cobalt : Color(uiColor: .tertiaryLabel))
                                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
                                    .animation(.spring(response: 0.38, dampingFraction: 0.72), value: isExpanded)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(PressableStyle())

                        Button {
                            editingBudget = budget
                        } label: {
                            Image(systemName: "slider.horizontal.3")
                                .font(.subheadline)
                                .foregroundStyle(Theme.cobalt)
                                .frame(width: 30, height: 30)
                                .background(Theme.cobaltSoft, in: Circle())
                        }
                        .buttonStyle(PressableStyle())
                        .accessibilityLabel("Edit \(budget.displayName)")
                    }
                    .zIndex(1)

                    if isExpanded {
                        VStack(alignment: .leading, spacing: 11) {
                            ForEach(Array(cats.enumerated()), id: \.element.id) { index, cat in
                                let catSpent = f.spent(cat, in: interval)
                                let catRatio = budget.limit > 0 ? catSpent / budget.limit : (spent > 0 ? catSpent / spent : 0)
                                MiniCategorySpendRow(
                                    category: cat,
                                    spent: catSpent,
                                    ratio: catRatio,
                                    currency: currency,
                                    index: index
                                )
                            }
                        }
                        .padding(.vertical, 10)
                        .padding(.horizontal, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Theme.track.opacity(0.38))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .stroke(Theme.cobalt.opacity(0.12), lineWidth: 1)
                                )
                        )
                        .clipped()
                        .zIndex(0)
                        .transition(
                            .asymmetric(
                                insertion: .opacity
                                    .combined(with: .scale(scale: 0.96, anchor: .top))
                                    .combined(with: .offset(y: -6)),
                                removal: .opacity
                                    .combined(with: .scale(scale: 0.97, anchor: .top))
                                    .combined(with: .offset(y: -4))
                            )
                        )
                    }
                }
                .padding(.vertical, 2)
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
                let linkedAcc = accounts.first { $0.id == goal.linkedAccountID }
                let linkedSuffix = !goal.smsMatch.trimmingCharacters(in: .whitespaces).isEmpty
                    ? goal.smsMatch.trimmingCharacters(in: .whitespaces)
                    : (linkedAcc.flatMap { !$0.smsMatch.trimmingCharacters(in: .whitespaces).isEmpty ? $0.smsMatch.trimmingCharacters(in: .whitespaces) : nil })
                let hasCommitment = goal.monthlyCommitment > 0
                let monthlyPaid = goal.contributedThisMonth(now: .now)
                let monthlyRatio = hasCommitment ? min(monthlyPaid / goal.monthlyCommitment, 1.0) : goal.progress
                let monthlyPct = hasCommitment ? Int((monthlyPaid / goal.monthlyCommitment) * 100) : Int(goal.progress * 100)

                Button { editingGoal = goal } label: {
                    HStack(spacing: 12) {
                        IconBadge(symbol: goal.symbol, color: (hasCommitment && monthlyPaid >= goal.monthlyCommitment) || goal.isComplete ? Theme.positive : Theme.cobalt)
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(goal.name)
                                            .font(.body.weight(.semibold))
                                            .foregroundStyle(Theme.ink)
                                            .lineLimit(1)
                                            .minimumScaleFactor(0.85)
                                        if linkedAcc != nil || linkedSuffix != nil {
                                            Label(
                                                linkedSuffix.map { "••\($0)" } ?? (linkedAcc?.name ?? "Linked"),
                                                systemImage: "link"
                                            )
                                            .font(.caption2.weight(.semibold))
                                            .foregroundStyle(Theme.cobalt)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Theme.cobalt.opacity(0.12), in: Capsule())
                                        }
                                    }
                                    if hasCommitment {
                                        Text("Total: \(Money.format(goal.saved, currency, decimals: 0)) / \(Money.number(goal.target, decimals: 0))")
                                            .font(.caption2)
                                            .foregroundStyle(Theme.secondaryInk)
                                    } else {
                                        Text("Target: \(goal.targetDate.formatted(.dateTime.month(.abbreviated).year()))")
                                            .font(.caption2)
                                            .foregroundStyle(Theme.secondaryInk)
                                    }
                                }
                                Spacer(minLength: 8)
                                HStack(spacing: 0) {
                                    if hasCommitment {
                                        Text(Money.format(monthlyPaid, currency, decimals: 0))
                                            .fontWeight(.semibold)
                                            .foregroundStyle(Theme.ink)
                                            .animatedNumber(monthlyPaid)
                                        Text(" / \(Money.number(goal.monthlyCommitment, decimals: 0))")
                                            .foregroundStyle(Theme.secondaryInk)
                                            .animatedNumber(goal.monthlyCommitment)
                                        Text(" · \(monthlyPct)%")
                                            .foregroundStyle(monthlyPaid >= goal.monthlyCommitment ? Theme.positive : Theme.secondaryInk)
                                            .animatedNumber(Double(monthlyPct))
                                    } else {
                                        Text(Money.format(goal.saved, currency, decimals: 0))
                                            .fontWeight(.semibold)
                                            .foregroundStyle(Theme.ink)
                                            .animatedNumber(goal.saved)
                                        Text(" / \(Money.number(goal.target, decimals: 0))")
                                            .foregroundStyle(Theme.secondaryInk)
                                            .animatedNumber(goal.target)
                                        Text(" · \(monthlyPct)%")
                                            .foregroundStyle(goal.isComplete ? Theme.positive : Theme.secondaryInk)
                                            .animatedNumber(Double(monthlyPct))
                                    }
                                }
                                .font(.footnote.monospacedDigit())
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                                .layoutPriority(1)
                            }

                            ProgressBar(
                                progress: hasCommitment ? monthlyRatio : goal.progress,
                                color: (hasCommitment && monthlyPaid >= goal.monthlyCommitment) || goal.isComplete ? Theme.positive : Theme.cobalt
                            )

                            if hasCommitment && monthlyPaid >= goal.monthlyCommitment {
                                HStack {
                                    Label("Monthly commitment paid", systemImage: "checkmark.circle.fill")
                                        .font(.caption2.weight(.medium))
                                        .foregroundStyle(Theme.positive)
                                    Spacer()
                                }
                            }
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

private struct MiniCategorySpendRow: View {
    let category: SpendCategory
    let spent: Double
    let ratio: Double
    let currency: String
    let index: Int
    @State private var appeared = false
    @State private var displayedSpent: Double = 0
    @State private var displayedRatio: Double = 0

    var body: some View {
        let targetPct = Int(min(max(ratio, 0), 9.99) * 100)
        let shownPct = Int(min(max(displayedRatio, 0), 9.99) * 100)
        HStack(spacing: 10) {
            CategoryIcon(category: category, size: 28)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(category.title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    Spacer(minLength: 8)
                    if targetPct > 0 || shownPct > 0 {
                        Text("\(shownPct)%")
                            .font(.caption2.weight(.medium).monospacedDigit())
                            .foregroundStyle(Theme.secondaryInk)
                            .animatedNumber(Double(shownPct))
                            .lineLimit(1)
                            .layoutPriority(1)
                    }
                    Text(Money.format(displayedSpent, currency))
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(Theme.ink)
                        .animatedNumber(displayedSpent)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .layoutPriority(2)
                }
                ProgressBar(
                    progress: ratio,
                    color: category.color,
                    height: 6.5,
                    delay: 0.06 + Double(index) * 0.055,
                    trackColor: Theme.surface
                )
            }
        }
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 6)
        .scaleEffect(appeared ? 1 : 0.985, anchor: .leading)
        .onAppear {
            let rowDelay = Double(index) * 0.045
            withAnimation(.spring(response: 0.44, dampingFraction: 0.84).delay(rowDelay)) {
                appeared = true
            }
            withAnimation(.spring(response: 0.52, dampingFraction: 0.85).delay(rowDelay + 0.04)) {
                displayedSpent = spent
                displayedRatio = ratio
            }
        }
        .onChange(of: spent) { _, newValue in
            withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
                displayedSpent = newValue
            }
        }
        .onChange(of: ratio) { _, newValue in
            withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
                displayedRatio = newValue
            }
        }
    }
}

// MARK: - Editors

struct BudgetEditor: View {
    let budget: Budget?
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @AppStorage(Keys.currency) private var currency = "BHD"
    @State private var name = ""
    @State private var selectedCategories: [SpendCategory] = []
    @State private var limitText = ""

    private var availableCategories: [SpendCategory] {
        SpendCategory.expenseCases.filter { $0 != .transfers && $0 != .internalTransfer && $0 != .visaTransfer }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Budget details") {
                    TextField("Budget name (e.g. Daily Living)", text: $name)
                        .textInputAutocapitalization(.words)
                    HStack {
                        Text("Monthly limit")
                        Spacer()
                        TextField(Money.format(0, currency), text: $limitText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .monospacedDigit()
                    }
                }

                Section {
                    ForEach(availableCategories) { c in
                        let isSelected = selectedCategories.contains(c)
                        Button {
                            toggleCategory(c)
                        } label: {
                            HStack(spacing: 12) {
                                CategoryIcon(category: c, size: 34)
                                Text(c.title)
                                    .foregroundStyle(Theme.ink)
                                Spacer()
                                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                    .font(.title3)
                                    .foregroundStyle(isSelected ? Theme.cobalt : Color(hex: 0xC7CCD6))
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("Categories (\(selectedCategories.count) selected)")
                } footer: {
                    Text("Select one or more categories to track together under this budget. You'll get alerts at 80% and 100% of the limit.")
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
                    Button("Save", action: save)
                        .fontWeight(.semibold)
                        .disabled((Money.parse(limitText) ?? 0) <= 0 || selectedCategories.isEmpty)
                }
            }
            .onAppear {
                CategoryRegistry.shared.reload(context: context)
                if let budget {
                    name = budget.displayName
                    selectedCategories = budget.categories
                    limitText = Money.number(budget.limit, decimals: Money.digits(currency)).replacingOccurrences(of: ",", with: "")
                } else if let first = availableCategories.first {
                    selectedCategories = [first]
                }
            }
        }
        .presentationDetents([.large])
    }

    private func toggleCategory(_ category: SpendCategory) {
        if let idx = selectedCategories.firstIndex(of: category) {
            selectedCategories.remove(at: idx)
        } else {
            selectedCategories.append(category)
        }
    }

    private func save() {
        let limit = Money.parse(limitText) ?? 0
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName: String = {
            if !trimmedName.isEmpty { return trimmedName }
            if selectedCategories.count == 1 { return selectedCategories[0].title }
            return selectedCategories.map(\.shortTitle).joined(separator: " & ")
        }()
        if let budget {
            budget.name = resolvedName
            budget.categories = selectedCategories
            budget.limit = limit
        } else {
            context.insert(Budget(name: resolvedName, categories: selectedCategories, limit: limit))
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
    @State private var linkedAccountID: UUID?
    @State private var smsMatch = ""

    private let symbols = ["star.fill", "shield.lefthalf.filled", "airplane", "car.fill", "house.fill", "graduationcap.fill", "gift.fill", "heart.fill", "laptopcomputer", "ring"]

    var body: some View {
        NavigationStack {
            Form {
                if let goal {
                    Section {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 0) {
                                Text(Money.format(goal.saved, currency))
                                    .animatedNumber(goal.saved)
                                Text(" of \(Money.format(goal.target, currency))")
                                    .animatedNumber(goal.target)
                            }
                            .font(.headline.monospacedDigit())
                            ProgressBar(progress: goal.progress, color: Theme.positive, height: 9)
                            Text(suggestion(goal)).font(.footnote).foregroundStyle(Theme.secondaryInk)
                        }
                        .padding(.vertical, 4)
                    }
                    Section("Add money") {
                        if goal.monthlyCommitment > 0 && goal.remainingCommitment() > 0 {
                            Button {
                                contributionText = plain(goal.remainingCommitment())
                                contribute(goal)
                            } label: {
                                Label("Pay monthly commitment (\(Money.format(goal.remainingCommitment(), currency)))", systemImage: "arrow.up.circle.fill")
                                    .font(.subheadline.weight(.semibold))
                            }
                        }
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
                Section {
                    Picker("Linked savings account", selection: $linkedAccountID) {
                        Text("None").tag(UUID?.none)
                        ForEach(accounts.filter { !$0.kind.isLiability }) { a in
                            Text(a.menuTitle).tag(UUID?.some(a.id))
                        }
                    }
                    .onChange(of: linkedAccountID) { _, newID in
                        if smsMatch.trimmingCharacters(in: .whitespaces).isEmpty,
                           let newID,
                           let acc = accounts.first(where: { $0.id == newID }),
                           !acc.smsMatch.trimmingCharacters(in: .whitespaces).isEmpty {
                            smsMatch = acc.smsMatch
                        }
                    }
                    HStack {
                        Text("Savings IBAN / account suffix")
                        Spacer()
                        TextField("e.g. 0846", text: $smsMatch)
                            .keyboardType(.asciiCapable)
                            .multilineTextAlignment(.trailing)
                            .monospacedDigit()
                    }
                } header: {
                    Text("Auto-save from SMS / Transfers")
                } footer: {
                    Text("Whenever an SMS transfer (such as Fawri+ to your savings IBAN ending in these digits) or transfer to the linked account is imported, its amount is automatically added to this goal.")
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
        linkedAccountID = goal.linkedAccountID
        smsMatch = goal.smsMatch
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
        let cleanSuffix = smsMatch.trimmingCharacters(in: .whitespacesAndNewlines)
        if let goal {
            goal.name = trimmed
            goal.symbol = symbol
            goal.target = target
            goal.monthlyCommitment = commitment
            goal.targetDate = targetDate
            goal.linkedAccountID = linkedAccountID
            goal.smsMatch = cleanSuffix
        } else {
            context.insert(SavingsGoal(name: trimmed, symbol: symbol, target: target, saved: Money.parse(savedText) ?? 0,
                                       targetDate: targetDate, monthlyCommitment: commitment,
                                       linkedAccountID: linkedAccountID, smsMatch: cleanSuffix))
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
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                        .animatedNumber(s.daily)
                    Text("\(Money.format(s.monthly, currency)) for the next \(s.daysLeft) day\(s.daysLeft == 1 ? "" : "s")")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(Theme.secondaryInk)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .animatedNumber(s.monthly)
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
                row("Loans & liabilities", "Outstanding debt and loans", s.liabilities, symbol: "creditcard.trianglebadge.exclamationmark", color: Theme.negative, sign: -1)
                LabeledContent {
                    Text(Money.format(s.monthly, currency))
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .layoutPriority(1)
                        .animatedNumber(s.monthly)
                } label: {
                    Text("Safe this month").font(.headline)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
            } header: {
                Text("How it's calculated")
            } footer: {
                Text(s.isShort
                     ? "Your commitments and liabilities are higher than your spendable balance. Consider pausing a savings goal or moving money from savings."
                     : "Divided evenly across the \(s.daysLeft) days left this month. Spend less today and tomorrow's amount grows.")
            }

            if !bills.isEmpty {
                Section("Bills counted") {
                    ForEach(f.upcomingBills.filter { $0.nextDueDate < f.thisMonth.end }) { bill in
                        LabeledContent {
                            Text(Money.format(bill.amount, currency))
                                .monospacedDigit()
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                                .layoutPriority(1)
                        } label: {
                            Text(bill.name)
                                .lineLimit(1)
                                .minimumScaleFactor(0.85)
                        }
                    }
                }
            }

            let liabilities = accounts.filter { $0.includeInNetWorth && $0.kind.isLiability && $0.balance > 0 }
            if !liabilities.isEmpty {
                Section("Loans & liabilities") {
                    ForEach(liabilities) { acc in
                        LabeledContent {
                            Text(Money.format(-acc.balance, currency, signed: true))
                                .font(.body.monospacedDigit())
                                .foregroundStyle(Theme.negative)
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                                .layoutPriority(1)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(acc.name)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.85)
                                Text(acc.institution.isEmpty ? acc.kind.title : "\(acc.kind.title) · \(acc.institution)")
                                    .font(.caption2)
                                    .foregroundStyle(Theme.secondaryInk)
                                    .lineLimit(1)
                            }
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
                Text(title)
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryInk)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            Spacer(minLength: 8)
            Text(Money.format(value * sign, currency, signed: sign > 0))
                .font(.body.weight(.medium).monospacedDigit())
                .foregroundStyle(sign > 0 ? Theme.positive : Theme.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .layoutPriority(1)
                .animatedNumber(value * sign)
        }
    }
}
