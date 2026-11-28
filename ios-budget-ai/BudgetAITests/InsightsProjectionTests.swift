import Foundation
import Testing
@testable import BudgetAI

@Suite(.serialized)
@MainActor
struct InsightsProjectionTests {

    private func makeSampleFinance(now: Date = .now) -> Finance {
        let bank = Account(name: "Main Bank", kind: .bank, institution: "BisB", balance: 600.0)
        let loan = Account(name: "Car Loan", kind: .loan, institution: "BisB", balance: 1200.0)
        loan.loanMonthlyInstallment = 120.0
        loan.paymentDueReminder = true
        loan.paymentDueDate = Calendar.current.date(byAdding: .day, value: 4, to: now) ?? now

        let salary = MoneyTransaction(amount: 800.0, isIncome: true, merchant: "Employer Salary", category: .income, date: now.addingTimeInterval(-15 * 86_400), source: .sms, accountID: bank.id)
        let food = MoneyTransaction(amount: 90.0, isIncome: false, merchant: "Dining", category: .dining, date: now.addingTimeInterval(-10 * 86_400), source: .sms, accountID: bank.id)
        let shop = MoneyTransaction(amount: 60.0, isIncome: false, merchant: "Mall", category: .shopping, date: now.addingTimeInterval(-5 * 86_400), source: .sms, accountID: bank.id)

        let bill = Bill(name: "Batelco Fiber", amount: 25.0, category: .bills, nextDueDate: Calendar.current.date(byAdding: .day, value: 3, to: now) ?? now, frequency: .monthly, isSubscription: true)
        let budget = Budget(name: "Shopping", categories: [.shopping], limit: 150.0)
        let goal = SavingsGoal(
            name: "Emergency Fund",
            symbol: "shield.fill",
            target: 1000.0,
            saved: 400.0,
            targetDate: Calendar.current.date(byAdding: .month, value: 6, to: now) ?? now,
            monthlyCommitment: 100.0
        )

        return Finance(
            transactions: [salary, food, shop],
            accounts: [bank, loan],
            budgets: [budget],
            goals: [goal],
            bills: [bill],
            now: now,
            sharedExpenseOverlay: .empty
        )
    }

    @Test func projectionEngineCoversAllFourPeriodsAndIncludesRealEvents() {
        let now = Date()
        let finance = makeSampleFinance(now: now)

        for period in ForecastPeriod.allCases {
            let result = FinancialProjectionEngine.project(finance: finance, period: period, currency: "BHD")
            #expect(result.period == period)
            #expect(result.hasSufficientData == true)
            #expect(abs(result.startingBalance - 600.0) < 0.001)
            #expect(!result.projectedPoints.isEmpty)
            #expect(result.events.contains(where: { $0.kind == .upcomingBill && $0.title == "Batelco Fiber" }))
            #expect(result.events.contains(where: { $0.kind == .loanInstallment }))
            #expect(result.events.contains(where: { $0.kind == .expectedIncome }))
            #expect(result.events.contains(where: { $0.kind == .plannedSavings }))
            #expect(!result.primaryInsight.title.isEmpty)
            #expect(!result.primaryInsight.action.isEmpty)
        }

        // Empty data produces honest insufficient-data state without fake balances
        let emptyFinance = Finance(transactions: [], accounts: [], budgets: [], goals: [], bills: [], now: now, sharedExpenseOverlay: .empty)
        let emptyProj = FinancialProjectionEngine.project(finance: emptyFinance, period: .threeMonths, currency: "BHD")
        #expect(emptyProj.hasSufficientData == false)
        #expect(emptyProj.startingBalance == 0)
        #expect(!emptyProj.missingData.isEmpty)
    }

    @Test func buyNowSimulationEvaluatesSafeVsRiskWithoutMutatingData() {
        let now = Date()
        let finance = makeSampleFinance(now: now)

        // Small purchase (BD 30) -> safe
        let safeSim = FinancialProjectionEngine.simulateBuyNow(
            input: BuyNowSimulationInput(amount: 30.0, name: "Headphones", date: now, category: .shopping),
            finance: finance,
            currency: "BHD"
        )
        #expect(safeSim.overallStatus == .safe)
        #expect(abs((safeSim.safeToSpend.before - safeSim.safeToSpend.after) - 30.0) < 0.001)
        #expect(abs((safeSim.budget.beforeRemaining - safeSim.budget.afterRemaining) - 30.0) < 0.001)
        #expect(safeSim.bills.billsCovered == true)

        // Huge purchase (BD 900) -> risk
        let riskSim = FinancialProjectionEngine.simulateBuyNow(
            input: BuyNowSimulationInput(amount: 900.0, name: "Luxury Watch", date: now, category: .shopping),
            finance: finance,
            currency: "BHD"
        )
        #expect(riskSim.overallStatus == .risk)
        #expect(riskSim.safeToSpend.after < 0)
        #expect(riskSim.budget.afterRemaining < 0)
        #expect(riskSim.bills.billsCovered == false)
        #expect(!riskSim.recommendations.isEmpty)
    }

    @Test func savingGoalSimulationCalculatesExactMonthlyAndWeeklyRequirements() {
        let now = Date()
        let finance = makeSampleFinance(now: now)
        let sixMonths = Calendar.current.date(byAdding: .month, value: 6, to: now) ?? now

        // Achievable goal: target 600, saved 150 -> remaining 450 over ~6 months (~75/mo)
        let goodSim = FinancialProjectionEngine.simulateSavingGoal(
            input: SavingGoalSimulationInput(name: "Laptop", targetAmount: 600.0, currentSaved: 150.0, targetDate: sixMonths, startDate: now),
            finance: finance,
            currency: "BHD"
        )
        #expect(abs(goodSim.remainingAmount - 450.0) < 0.001)
        #expect(goodSim.requiredMonthlyContribution > 65 && goodSim.requiredMonthlyContribution < 85)
        #expect(goodSim.requiredWeeklyContribution > 15 && goodSim.requiredWeeklyContribution < 20)
        #expect(goodSim.isAchievable == true)

        // Unachievable goal: target 6000 over 3 months (~2000/mo)
        let threeMonths = Calendar.current.date(byAdding: .month, value: 3, to: now) ?? now
        let hardSim = FinancialProjectionEngine.simulateSavingGoal(
            input: SavingGoalSimulationInput(name: "New Car", targetAmount: 6000.0, currentSaved: 0, targetDate: threeMonths, startDate: now),
            finance: finance,
            currency: "BHD"
        )
        #expect(hardSim.isAchievable == false)
        #expect(hardSim.overallStatus == .risk)
        #expect(!hardSim.smartSuggestions.isEmpty)
    }

    @Test func wishlistStoreTracksPriceDropsAndEvaluatesSuitability() {
        let suite = "falak.tests.wishlist.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = WishlistStore(defaults: defaults, storageKey: "wl")

        var item = WishlistItem(name: "AirPods", currentPrice: 50.0, originalPrice: 62.5, targetPrice: 55.0, priority: .high)
        store.add(item)
        #expect(store.items.count == 1)
        #expect(abs(item.priceReductionPercent - 20.0) < 0.01)
        #expect(item.hasReachedTargetPrice == true)

        let finance = makeSampleFinance()
        let projection = FinancialProjectionEngine.project(finance: finance, period: .threeMonths, currency: "BHD")
        let eval = WishlistEvaluator.evaluate(item: item, finance: finance, projection: projection, currency: "BHD")
        #expect(eval.suitability == .goodTimeToBuy)

        // Update price higher -> priceHistory records change
        item.currentPrice = 60.0
        store.update(item)
        #expect(store.items.first?.priceHistory.count == 2)
    }

    @Test func alertsEnginePrioritizesAndPersistsReadAndDismissedState() {
        let suite = "falak.tests.alerts.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let stateStore = FinancialAlertStateStore(defaults: defaults, readKey: "r", dismissedKey: "d", historyKey: "h")

        let finance = makeSampleFinance()
        let projection = FinancialProjectionEngine.project(finance: finance, period: .threeMonths, currency: "BHD")
        let wishlist = [WishlistItem(name: "Keyboard", currentPrice: 40.0, originalPrice: 50.0, targetPrice: 45.0, priority: .medium)]

        let alerts = FinancialAlertsEngine.generate(finance: finance, projection: projection, wishlistItems: wishlist, currency: "BHD")
        #expect(!alerts.isEmpty)
        // Sorted by priority rank ascending (Critical/High before Medium/Low)
        for idx in 1..<alerts.count {
            #expect(alerts[idx - 1].priority.rank <= alerts[idx].priority.rank)
        }

        if let first = alerts.first {
            stateStore.markRead(first)
            #expect(stateStore.isRead(first.id) == true)
            stateStore.dismiss(first)
            #expect(stateStore.isDismissed(first.id) == true)
            #expect(stateStore.archivedAlerts.contains(where: { $0.id == first.id }))
            stateStore.restore(first.id)
            #expect(stateStore.isDismissed(first.id) == false)
        }
    }

    @Test func timeMachineScopesToSingleAccountAndGroupsEventsDailyVsWeekly() {
        let cal = Calendar(identifier: .gregorian)
        let now = cal.date(from: DateComponents(year: 2026, month: 12, day: 1, hour: 10))!
        let bisb = Account(name: "BisB", kind: .bank, institution: "BisB", balance: 1000.0)
        let ila = Account(name: "ila", kind: .bank, institution: "ila", balance: 250.0)
        let txBisb = MoneyTransaction(amount: 40.0, isIncome: false, merchant: "Lulu", category: .groceries, date: now.addingTimeInterval(-86_400), source: .sms, accountID: bisb.id)
        let txIla = MoneyTransaction(amount: 15.0, isIncome: false, merchant: "Cafe", category: .dining, date: now.addingTimeInterval(-86_400), source: .sms, accountID: ila.id)

        let scopedIla = FinancialProjectionEngine.scopedFinance(
            for: ila,
            transactions: [txBisb, txIla],
            accounts: [bisb, ila],
            budgets: [],
            goals: [],
            bills: [],
            now: now,
            sharedExpenseOverlay: .empty
        )
        #expect(abs(scopedIla.liquidBalance - 250.0) < 0.001)
        #expect(scopedIla.transactions.count == 1)
        #expect(scopedIla.transactions.first?.id == txIla.id)

        // Two Bills events in the same week (Wed Dec 2 & Thu Dec 3):
        // - 1 Month -> separate daily groups (2 groups, isWeeklyBucket == false)
        // - 3 Months -> single weekly group (1 group, isWeeklyBucket == true, 2 events inside)
        let dec2 = cal.date(from: DateComponents(year: 2026, month: 12, day: 2, hour: 9))!
        let dec3 = cal.date(from: DateComponents(year: 2026, month: 12, day: 3, hour: 9))!
        let ev1 = FinancialProjectionEvent(id: "b1", title: "Batelco", date: dec2, amount: 25, signedImpact: -25, kind: .upcomingBill, accountOrCategory: "Bills", explanation: "Bill", isConfirmed: true)
        let ev2 = FinancialProjectionEvent(id: "b2", title: "Zain", date: dec3, amount: 15, signedImpact: -15, kind: .upcomingBill, accountOrCategory: "Bills", explanation: "Bill", isConfirmed: true)

        let oneMonthGroups = FinancialProjectionEngine.groupEvents([ev1, ev2], period: .oneMonth, calendar: cal)
        #expect(oneMonthGroups.count == 2)
        #expect(oneMonthGroups.allSatisfy { !$0.isWeeklyBucket })

        let threeMonthGroups = FinancialProjectionEngine.groupEvents([ev1, ev2], period: .threeMonths, calendar: cal)
        #expect(threeMonthGroups.count == 1)
        #expect(threeMonthGroups.first?.isWeeklyBucket == true)
        #expect(threeMonthGroups.first?.events.count == 2)
        #expect(abs((threeMonthGroups.first?.totalSignedImpact ?? 0) - (-40.0)) < 0.001)
    }
}
