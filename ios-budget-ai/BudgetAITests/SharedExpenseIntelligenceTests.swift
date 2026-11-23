import Foundation
import SwiftData
import Testing
@testable import BudgetAI

// MARK: - Deterministic Mock AI Provider for Isolated Tests

private struct MockSharedExpenseAIProvider: SharedExpenseAIProvider {
    var expenseHandler: @Sendable (SharedExpenseAIExpenseContext) -> SharedExpenseAIExpenseAssessment? = { _ in nil }
    var reimbursementHandler: @Sendable (SharedExpenseAIReimbursementContext) -> SharedExpenseAIReimbursementAssessment? = { _ in nil }

    func assessExpense(_ context: SharedExpenseAIExpenseContext) async -> SharedExpenseAIExpenseAssessment? {
        expenseHandler(context)
    }

    func assessReimbursement(_ context: SharedExpenseAIReimbursementContext) async -> SharedExpenseAIReimbursementAssessment? {
        reimbursementHandler(context)
    }
}

// MARK: - Isolated Shared Expense Intelligence Tests

@Suite(.serialized)
@MainActor
struct SharedExpenseIntelligenceTests {

    private func makeIsolatedHarness(
        enabled: Bool = true,
        aiProvider: any SharedExpenseAIProvider = MockSharedExpenseAIProvider(),
        ruleChecker: @escaping (MoneyTransaction) -> Bool = { _ in false }
    ) -> (service: SharedExpenseIntelligenceService, adjustments: SharedExpenseAdjustmentStore, memory: SharedExpenseMemoryStore, suiteName: String) {
        let suiteName = "falak.tests.sharedExpense.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let adjStore = SharedExpenseAdjustmentStore(
            defaults: defaults,
            adjustmentsKey: "adj",
            predictionsKey: "pred",
            suggestionsKey: "sug"
        )
        let memStore = SharedExpenseMemoryStore(defaults: defaults, storageKey: "mem")
        let service = SharedExpenseIntelligenceService(
            adjustmentStore: adjStore,
            memoryStore: memStore,
            aiProvider: aiProvider,
            isEnabledProvider: { enabled },
            hasExistingRuleProvider: ruleChecker
        )
        return (service, adjStore, memStore, suiteName)
    }

    private func diningHistory(count: Int, amount: Double, baseDate: Date) -> [MoneyTransaction] {
        (1...count).map { idx in
            MoneyTransaction(
                amount: amount,
                isIncome: false,
                merchant: "Local Bistro \(idx)",
                category: .dining,
                date: baseDate.addingTimeInterval(-Double(idx * 3) * 86_400),
                source: .sms
            )
        }
    }

    // MARK: 1. Normal personal restaurant expense

    @Test func normalPersonalRestaurantExpenseIsNotFlagged() async {
        let (service, adjStore, _, _) = makeIsolatedHarness()
        let now = Date()
        var history = diningHistory(count: 5, amount: 7.500, baseDate: now)
        let tx = MoneyTransaction(amount: 8.200, isIncome: false, merchant: "Lumee Street Cafe", category: .dining, date: now, source: .sms)
        history.append(tx)

        let outcome = await service.analyzeTransaction(tx, allTransactions: history, currency: "BHD")
        if case .waitingForMoreContext(let pred) = outcome {
            #expect((pred?.sharedProbability ?? 0) < 0.42)
            #expect(pred?.estimatedReimbursableAmount == 0)
        } else {
            Issue.record("Expected waitingForMoreContext for normal personal restaurant expense, got \(outcome)")
        }
        #expect(adjStore.activeAdjustments.isEmpty)
        #expect(adjStore.pendingSuggestions.isEmpty)
        #expect(tx.amount == 8.200)
    }

    // MARK: 2. Large personal restaurant expense (never assumes every large bill is shared or silently reduces budget)

    @Test func largePersonalRestaurantExpenseNeverAutoAdjustsBudget() async {
        let (service, adjStore, memStore, _) = makeIsolatedHarness()
        let now = Date()
        var history = diningHistory(count: 5, amount: 8.000, baseDate: now)
        // Record prior personal dining pattern at this fine-dining venue
        memStore.record(SharedExpenseMemoryRecord(
            transactionID: UUID().uuidString,
            relationshipType: .personalExpense,
            confirmedCategory: SpendCategory.dining.rawValue,
            personalAmount: 45.0,
            reimbursableAmount: 0,
            confirmationSource: .userConfirmed,
            confidence: 1.0,
            merchantKey: SharedExpensePrivacy.normalizedMerchantKey("CUT by Wolfgang Puck")
        ))
        let largePersonal = MoneyTransaction(amount: 48.000, isIncome: false, merchant: "CUT by Wolfgang Puck", category: .dining, date: now, source: .sms)
        history.append(largePersonal)

        let outcome = await service.analyzeTransaction(largePersonal, allTransactions: history, currency: "BHD")
        // Must NEVER auto-adjust budget on a large personal restaurant bill
        if case .automaticallyAdjusted = outcome {
            Issue.record("Large personal restaurant expense must never be automatically adjusted")
        }
        #expect(adjStore.activeAdjustments.isEmpty)

        let finance = Finance(transactions: [largePersonal], now: now, sharedExpenseOverlay: adjStore.makeOverlay(isEnabled: true))
        #expect(abs(finance.spent(.dining, in: finance.thisMonth) - 48.000) < 0.0001)
    }

    // MARK: 3. Shared restaurant bill + high-confidence reimbursement auto-link & budget protection

    @Test func sharedRestaurantBillWithCorroboratedReimbursementAutoAdjustsSafely() async {
        let (service, adjStore, memStore, _) = makeIsolatedHarness()
        let now = Date()
        let diningDate = now.addingTimeInterval(-3600 * 3)
        var txs = diningHistory(count: 5, amount: 8.000, baseDate: diningDate)

        // Prior confirmed sender pattern (anonymized)
        let friendTransfer = MoneyTransaction(
            amount: 20.000,
            isIncome: true,
            merchant: "Ahmed Ali",
            category: .transferIn,
            date: now,
            note: "Dinner split",
            source: .sms
        )
        friendTransfer.smsTransactionType = .transferIn
        let senderToken = SharedExpensePrivacy.extractSenderToken(from: friendTransfer)
        memStore.record(SharedExpenseMemoryRecord(
            transactionID: UUID().uuidString,
            relationshipType: .reimbursementPattern,
            confirmedCategory: SpendCategory.dining.rawValue,
            personalAmount: 10.0,
            reimbursableAmount: 20.0,
            confirmationSource: .userConfirmed,
            confidence: 1.0,
            merchantKey: "lumee street cafe",
            senderToken: senderToken,
            reimbursementDelayHours: 4.0
        ))

        let sharedDinner = MoneyTransaction(
            amount: 30.000,
            isIncome: false,
            merchant: "Lumee Street Cafe",
            category: .dining,
            date: diningDate,
            note: "Dinner with friends",
            source: .sms
        )
        sharedDinner.smsReference = "REF-DINNER-001"
        txs.append(sharedDinner)

        // Step 1: Analyze the expense -> generates prediction & suggestion, zero silent budget change yet
        _ = await service.analyzeTransaction(sharedDinner, allTransactions: txs, currency: "BHD")
        #expect(adjStore.activeAdjustments.isEmpty)

        // Step 2: Incoming corroborated reimbursement arrives -> high confidence auto-link
        txs.append(friendTransfer)
        let outcome = await service.analyzeTransaction(friendTransfer, allTransactions: txs, currency: "BHD")
        guard case .automaticallyAdjusted(let adjs) = outcome, let adj = adjs.first else {
            Issue.record("Expected high-confidence automatic adjustment, got \(outcome)")
            return
        }

        // Verify original transactions are 100% unmutated
        #expect(sharedDinner.amount == 30.000)
        #expect(sharedDinner.date == diningDate)
        #expect(sharedDinner.smsReference == "REF-DINNER-001")
        #expect(friendTransfer.amount == 20.000)

        // Verify audit fields
        #expect(adj.originalTransactionID == sharedDinner.id)
        #expect(adj.relatedReimbursementTransactionIDs == [friendTransfer.id])
        #expect(abs(adj.originalExpenseAmount - 30.000) < 0.0001)
        #expect(abs(adj.personalAmount - 10.000) < 0.0001)
        #expect(abs(adj.reimbursableAmount - 20.000) < 0.0001)
        #expect(abs(adj.outstandingReimbursementAmount - 0.0) < 0.0001)
        #expect(adj.confirmationSource == .automatic)
        #expect(adj.aiConfidence >= 0.85)
        #expect(!adj.explanation.isEmpty)

        // Verify Finance overlay excludes reimbursable share from Food budget and excludes reimbursement from income
        let foodBudget = Budget(name: "Food", categories: [.dining], limit: 50.0)
        let finance = Finance(
            transactions: [sharedDinner, friendTransfer],
            budgets: [foodBudget],
            now: now,
            sharedExpenseOverlay: adjStore.makeOverlay(isEnabled: true)
        )
        #expect(abs(finance.spent(.dining, in: finance.thisMonth) - 10.000) < 0.0001)
        #expect(abs(finance.spent(for: foodBudget, in: finance.thisMonth) - 10.000) < 0.0001)
        #expect(abs(finance.income(in: finance.thisMonth) - 0.0) < 0.0001)

        // Verify duplicate reimbursement matching is blocked
        let dupOutcome = await service.analyzeTransaction(friendTransfer, allTransactions: txs, currency: "BHD")
        if case .automaticallyAdjusted = dupOutcome {
            Issue.record("Duplicate reimbursement must never be matched twice")
        }
    }

    // MARK: 4. Multiple partial reimbursements for one shared expense

    @Test func multiplePartialReimbursementsAccumulateWithoutOverAllocation() async throws {
        let (service, adjStore, _, _) = makeIsolatedHarness()
        let now = Date()
        let dinnerDate = now.addingTimeInterval(-3600 * 48)
        let dinner = MoneyTransaction(amount: 40.000, isIncome: false, merchant: "Maki Restaurant", category: .dining, date: dinnerDate, note: "Group dinner", source: .sms)

        // User confirms shared dinner: personal = 10, reimbursable = 30 (from 3 friends x 10 BHD each)
        let sug = SharedExpenseSuggestion(
            expenseTransactionID: dinner.id,
            originalExpenseAmount: 40.000,
            suggestedCategoryRaw: SpendCategory.dining.rawValue,
            suggestedPersonalAmount: 10.000,
            suggestedReimbursableAmount: 30.000,
            expectedBudgetImpact: -30.000,
            confidence: 0.72,
            confidenceLevel: .medium,
            explanation: "Group dinner split",
            promptMessage: "Confirm split"
        )
        adjStore.upsertSuggestion(sug)
        let confirmRes = service.confirmSuggestion(sug, allTransactions: [dinner], currency: "BHD")
        guard case .success(let initialAdj) = confirmRes else {
            Issue.record("Initial confirmation should succeed")
            return
        }
        #expect(abs(initialAdj.outstandingReimbursementAmount - 30.000) < 0.0001)

        // Partial reimbursement #1 (10 BHD)
        let r1 = MoneyTransaction(amount: 10.000, isIncome: true, merchant: "Khalid", category: .transferIn, date: dinnerDate.addingTimeInterval(3600 * 6), note: "Dinner share", source: .sms)
        r1.smsTransactionType = .transferIn
        let o1 = await service.analyzeTransaction(r1, allTransactions: [dinner, r1], currency: "BHD")
        guard case .automaticallyAdjusted = o1 else {
            Issue.record("Expected partial reimbursement #1 to auto-link, got \(o1)")
            return
        }
        #expect(abs((adjStore.activeAdjustment(forExpenseID: dinner.id)?.outstandingReimbursementAmount ?? -1) - 20.000) < 0.0001)

        // Partial reimbursement #2 (10 BHD)
        let r2 = MoneyTransaction(amount: 10.000, isIncome: true, merchant: "Sara", category: .transferIn, date: dinnerDate.addingTimeInterval(3600 * 18), note: "My share for dinner", source: .sms)
        r2.smsTransactionType = .transferIn
        let o2 = await service.analyzeTransaction(r2, allTransactions: [dinner, r1, r2], currency: "BHD")
        guard case .automaticallyAdjusted = o2 else {
            Issue.record("Expected partial reimbursement #2 to auto-link, got \(o2)")
            return
        }
        #expect(abs((adjStore.activeAdjustment(forExpenseID: dinner.id)?.outstandingReimbursementAmount ?? -1) - 10.000) < 0.0001)

        // Partial reimbursement #3 (10 BHD) closes remaining balance to 0
        let r3 = MoneyTransaction(amount: 10.000, isIncome: true, merchant: "Omar", category: .transferIn, date: dinnerDate.addingTimeInterval(3600 * 30), note: "Dinner", source: .sms)
        r3.smsTransactionType = .transferIn
        let o3 = await service.analyzeTransaction(r3, allTransactions: [dinner, r1, r2, r3], currency: "BHD")
        guard case .automaticallyAdjusted = o3 else {
            Issue.record("Expected partial reimbursement #3 to auto-link, got \(o3)")
            return
        }
        let finalAdj = try #require(adjStore.activeAdjustment(forExpenseID: dinner.id))
        #expect(finalAdj.relatedReimbursementTransactionIDs.count == 3)
        #expect(abs(finalAdj.totalReceivedReimbursementAmount - 30.000) < 0.0001)
        #expect(abs(finalAdj.outstandingReimbursementAmount - 0.0) < 0.0001)

        // Validator blocks over-allocation beyond remaining capacity
        let overCheck = SharedExpenseFinancialValidator.validateAllocation(
            expenseTxID: dinner.id,
            expenseDate: dinnerDate,
            expenseTotalAmount: 40.000,
            expenseReimbursableCap: 30.000,
            reimbursementTxID: UUID(),
            reimbursementDate: now,
            reimbursementTotalAmount: 10.000,
            requestedAmount: 10.000,
            existingActiveAdjustments: adjStore.activeAdjustments
        )
        if case .failure(.expenseExceedsOutstanding) = overCheck {
            // expected
        } else {
            Issue.record("Expected expenseExceedsOutstanding validation error, got \(overCheck)")
        }
    }

    // MARK: 5. One reimbursement covering multiple expenses

    @Test func oneReimbursementCoveringMultipleExpensesSplitsAcrossBoth() async {
        let (service, adjStore, memStore, _) = makeIsolatedHarness()
        let now = Date()
        let e1 = MoneyTransaction(amount: 20.000, isIncome: false, merchant: "Nandos", category: .dining, date: now.addingTimeInterval(-3600 * 20), note: "Split lunch", source: .sms)
        let e2 = MoneyTransaction(amount: 10.000, isIncome: false, merchant: "Starbucks", category: .dining, date: now.addingTimeInterval(-3600 * 18), note: "Split coffee", source: .sms)

        // Save predictions (50% share each: 10 + 5 = 15 BHD)
        adjStore.savePrediction(SharedExpensePrediction(transactionID: e1.id, sharedProbability: 0.75, estimatedPersonalAmount: 10.0, estimatedReimbursableAmount: 10.0, confidence: 0.70, confidenceLevel: .medium, explanation: "Shared lunch", suggestedCategoryRaw: SpendCategory.dining.rawValue))
        adjStore.savePrediction(SharedExpensePrediction(transactionID: e2.id, sharedProbability: 0.72, estimatedPersonalAmount: 5.0, estimatedReimbursableAmount: 5.0, confidence: 0.68, confidenceLevel: .medium, explanation: "Shared coffee", suggestedCategoryRaw: SpendCategory.dining.rawValue))

        let bundledTransfer = MoneyTransaction(amount: 15.000, isIncome: true, merchant: "Yusuf", category: .transferIn, date: now, note: "Lunch and coffee split", source: .sms)
        bundledTransfer.smsTransactionType = .transferIn
        if let token = SharedExpensePrivacy.extractSenderToken(from: bundledTransfer) {
            memStore.record(SharedExpenseMemoryRecord(transactionID: UUID().uuidString, relationshipType: .reimbursementPattern, confirmedCategory: SpendCategory.dining.rawValue, personalAmount: 10, reimbursableAmount: 10, confirmationSource: .userConfirmed, confidence: 1.0, merchantKey: "nandos", senderToken: token))
        }

        let outcome = await service.analyzeTransaction(bundledTransfer, allTransactions: [e1, e2, bundledTransfer], currency: "BHD")
        guard case .automaticallyAdjusted(let adjs) = outcome else {
            Issue.record("Expected bundled multi-expense auto-adjustment, got \(outcome)")
            return
        }
        #expect(adjs.count == 2)
        #expect(abs(adjStore.remainingCapacity(forReimbursementID: bundledTransfer.id, totalAmount: 15.000) - 0.0) < 0.0001)

        let finance = Finance(transactions: [e1, e2, bundledTransfer], now: now, sharedExpenseOverlay: adjStore.makeOverlay(isEnabled: true))
        #expect(abs(finance.spent(.dining, in: finance.thisMonth) - 15.000) < 0.0001)
    }

    // MARK: 6. Reimbursement received several days later

    @Test func reimbursementReceivedSeveralDaysLaterStillMatches() async {
        let (service, adjStore, memStore, _) = makeIsolatedHarness()
        let now = Date()
        let fiveDaysAgo = now.addingTimeInterval(-5 * 86_400)
        let travelHotel = MoneyTransaction(amount: 120.000, isIncome: false, merchant: "Gulf Hotel Resort", category: .travel, date: fiveDaysAgo, note: "Shared weekend booking", source: .sms)
        adjStore.savePrediction(SharedExpensePrediction(transactionID: travelHotel.id, sharedProbability: 0.78, estimatedPersonalAmount: 60.0, estimatedReimbursableAmount: 60.0, confidence: 0.72, confidenceLevel: .medium, explanation: "Shared booking", suggestedCategoryRaw: SpendCategory.travel.rawValue))

        let lateReimb = MoneyTransaction(amount: 60.000, isIncome: true, merchant: "Salman", category: .transferIn, date: now, note: "Hotel trip share", source: .sms)
        lateReimb.smsTransactionType = .transferIn
        if let token = SharedExpensePrivacy.extractSenderToken(from: lateReimb) {
            memStore.record(SharedExpenseMemoryRecord(transactionID: UUID().uuidString, relationshipType: .reimbursementPattern, confirmedCategory: SpendCategory.travel.rawValue, personalAmount: 50, reimbursableAmount: 50, confirmationSource: .userConfirmed, confidence: 1.0, merchantKey: "gulf hotel", senderToken: token, reimbursementDelayHours: 120))
        }

        let outcome = await service.analyzeTransaction(lateReimb, allTransactions: [travelHotel, lateReimb], currency: "BHD")
        guard case .automaticallyAdjusted(let adjs) = outcome, let adj = adjs.first else {
            Issue.record("Expected delayed reimbursement (5 days later) to match, got \(outcome)")
            return
        }
        #expect(adj.originalTransactionID == travelHotel.id)
        #expect(abs(adj.personalAmount - 60.000) < 0.0001)
    }

    // MARK: 7. Unrelated incoming transfer (never auto-matched on amount/timing alone)

    @Test func unrelatedIncomingTransferIsNeverAutoMatched() async {
        let (service, adjStore, _, _) = makeIsolatedHarness()
        let now = Date()
        let dinner = MoneyTransaction(amount: 20.000, isIncome: false, merchant: "Corner Cafe", category: .dining, date: now.addingTimeInterval(-3600 * 5), source: .sms)
        // Random transfer of 10.000 with no sender history, no shared prediction, no note cue
        let unrelated = MoneyTransaction(amount: 10.000, isIncome: true, merchant: "Fawri+ Transfer", category: .transferIn, date: now, source: .sms)
        unrelated.smsTransactionType = .transferIn

        let outcome = await service.analyzeTransaction(unrelated, allTransactions: [dinner, unrelated], currency: "BHD")
        if case .automaticallyAdjusted = outcome {
            Issue.record("Unrelated transfer must never be automatically matched")
        }
        #expect(adjStore.activeAdjustments.isEmpty)
        #expect(adjStore.pendingSuggestions.isEmpty)
    }

    // MARK: 8. Merchant refund (excluded from reimbursement matching)

    @Test func merchantRefundIsIgnoredByReimbursementMatcher() async {
        let (service, adjStore, _, _) = makeIsolatedHarness()
        let now = Date()
        let purchase = MoneyTransaction(amount: 35.000, isIncome: false, merchant: "Amazon Shopping", category: .shopping, date: now.addingTimeInterval(-86_400), source: .sms)
        adjStore.savePrediction(SharedExpensePrediction(transactionID: purchase.id, sharedProbability: 0.70, estimatedPersonalAmount: 17.5, estimatedReimbursableAmount: 17.5, confidence: 0.65, confidenceLevel: .medium, explanation: "Shared shopping", suggestedCategoryRaw: SpendCategory.shopping.rawValue))

        let explicitRefund = MoneyTransaction(amount: 17.500, isIncome: true, merchant: "Amazon Shopping", category: .other, date: now, note: "Order refund", source: .sms)
        explicitRefund.smsTransactionType = .refund

        let o1 = await service.analyzeTransaction(explicitRefund, allTransactions: [purchase, explicitRefund], currency: "BHD")
        if case .ignored = o1 {
            // expected
        } else {
            Issue.record("Merchant refund must be ignored, got \(o1)")
        }

        // Also test a refund without smsTransactionType = .refund (same merchant credit)
        let sameMerchantCredit = MoneyTransaction(amount: 17.500, isIncome: true, merchant: "Amazon Shopping", category: .transferIn, date: now, source: .sms)
        sameMerchantCredit.smsTransactionType = .transferIn
        let o2 = await service.analyzeTransaction(sameMerchantCredit, allTransactions: [purchase, sameMerchantCredit], currency: "BHD")
        if case .ignored = o2 {
            // expected
        } else {
            Issue.record("Same-merchant credit refund must be ignored, got \(o2)")
        }
        #expect(adjStore.activeAdjustments.isEmpty)
    }

    // MARK: 9. Internal transfer between user's own accounts

    @Test func internalTransferBetweenOwnAccountsIsIgnored() async {
        let (service, adjStore, _, _) = makeIsolatedHarness()
        let now = Date()
        let dinner = MoneyTransaction(amount: 30.000, isIncome: false, merchant: "Lumee", category: .dining, date: now.addingTimeInterval(-3600), note: "Group dinner", source: .sms)
        adjStore.savePrediction(SharedExpensePrediction(transactionID: dinner.id, sharedProbability: 0.80, estimatedPersonalAmount: 15.0, estimatedReimbursableAmount: 15.0, confidence: 0.75, confidenceLevel: .medium, explanation: "Shared dinner", suggestedCategoryRaw: SpendCategory.dining.rawValue))

        let internalTx = MoneyTransaction(amount: 15.000, isIncome: true, merchant: "ila -> BisB", category: .internalTransfer, date: now, source: .transfer, accountID: UUID())
        internalTx.toAccountID = UUID()
        internalTx.smsTransactionType = .internalTransfer

        let outcome = await service.analyzeTransaction(internalTx, allTransactions: [dinner, internalTx], currency: "BHD")
        if case .ignored = outcome {
            // expected
        } else {
            Issue.record("Internal transfer between own accounts must be ignored, got \(outcome)")
        }
        #expect(adjStore.activeAdjustments.isEmpty)
    }

    // MARK: 10 & 11. Medium-confidence and Low-confidence predictions generate suggestions without budget mutation

    @Test func mediumAndLowConfidenceGenerateSuggestionsWithoutModifyingBudget() async {
        let now = Date()

        // Medium confidence via mock AI
        let medAI = MockSharedExpenseAIProvider(expenseHandler: { ctx in
            SharedExpenseAIExpenseAssessment(
                sharedProbability: 0.72,
                estimatedPersonalAmount: 12.0,
                estimatedReimbursableAmount: 18.0,
                confidence: 0.68,
                explanation: "Higher than usual restaurant bill.",
                suggestedCategoryRaw: SpendCategory.dining.rawValue
            )
        })
        let (medService, medAdj, _, _) = makeIsolatedHarness(aiProvider: medAI)
        var medHistory = diningHistory(count: 4, amount: 8.000, baseDate: now)
        let medTx = MoneyTransaction(amount: 30.000, isIncome: false, merchant: "Villa Mamas", category: .dining, date: now, source: .sms)
        medHistory.append(medTx)

        let medOutcome = await medService.analyzeTransaction(medTx, allTransactions: medHistory, currency: "BHD")
        guard case .suggested(let medSug) = medOutcome else {
            Issue.record("Expected medium-confidence suggestion, got \(medOutcome)")
            return
        }
        #expect(medSug.confidenceLevel == .medium)
        #expect(medAdj.activeAdjustments.isEmpty) // Budget NOT silently changed!

        // Low confidence via mock AI
        let lowAI = MockSharedExpenseAIProvider(expenseHandler: { ctx in
            SharedExpenseAIExpenseAssessment(
                sharedProbability: 0.52,
                estimatedPersonalAmount: 15.0,
                estimatedReimbursableAmount: 15.0,
                confidence: 0.48,
                explanation: "Possible shared cafe order.",
                suggestedCategoryRaw: SpendCategory.dining.rawValue
            )
        })
        let (lowService, lowAdj, _, _) = makeIsolatedHarness(aiProvider: lowAI)
        var lowHistory = diningHistory(count: 4, amount: 8.000, baseDate: now)
        let lowTx = MoneyTransaction(amount: 30.000, isIncome: false, merchant: "Roast Cafe", category: .dining, date: now, source: .sms)
        lowHistory.append(lowTx)

        let lowOutcome = await lowService.analyzeTransaction(lowTx, allTransactions: lowHistory, currency: "BHD")
        guard case .suggested(let lowSug) = lowOutcome else {
            Issue.record("Expected low-confidence suggestion, got \(lowOutcome)")
            return
        }
        #expect(lowSug.confidenceLevel == .low)
        #expect(lowAdj.activeAdjustments.isEmpty) // Budget NOT silently changed!
    }

    // MARK: 12. Missing transaction context waits silently

    @Test func missingTransactionContextWaitsWithoutSuggesting() async {
        let (service, adjStore, _, _) = makeIsolatedHarness()
        let now = Date()
        let vagueTx = MoneyTransaction(amount: 55.000, isIncome: false, merchant: "POS", category: .other, date: now, note: "", source: .sms)

        let outcome = await service.analyzeTransaction(vagueTx, allTransactions: [vagueTx], currency: "BHD")
        if case .waitingForMoreContext = outcome {
            // expected
        } else {
            Issue.record("Transaction with missing context should wait, got \(outcome)")
        }
        #expect(adjStore.pendingSuggestions.isEmpty)
        #expect(adjStore.activeAdjustments.isEmpty)
    }

    // MARK: 13. User-confirmed shared expense + learning memory + clean reversal

    @Test func userConfirmedSharedExpenseAdjustsBudgetSavesMemoryAndReversesCleanly() async throws {
        let (service, adjStore, memStore, _) = makeIsolatedHarness()
        let now = Date()
        var history = diningHistory(count: 5, amount: 7.000, baseDate: now)
        let dinner = MoneyTransaction(amount: 30.000, isIncome: false, merchant: "My Cafe", category: .dining, date: now, note: "Split with friends", source: .sms)
        history.append(dinner)

        let outcome = await service.analyzeTransaction(dinner, allTransactions: history, currency: "BHD")
        guard case .suggested(let sug) = outcome else {
            Issue.record("Expected suggestion for shared dinner, got \(outcome)")
            return
        }

        // Confirm with exact split: personal = 10, reimbursable = 20
        let confirmed = service.confirmSuggestion(
            sug,
            allTransactions: history,
            chosenCategoryRaw: SpendCategory.dining.rawValue,
            customPersonalAmount: 10.0,
            customReimbursableAmount: 20.0,
            currency: "BHD"
        )
        guard case .success(let adj) = confirmed else {
            Issue.record("User confirmation should succeed")
            return
        }

        // Original transaction is untouched
        #expect(dinner.amount == 30.000)
        #expect(adj.confirmationSource == .userConfirmed)
        #expect(abs(adj.personalAmount - 10.0) < 0.0001)
        #expect(abs(adj.reimbursableAmount - 20.0) < 0.0001)

        // Memory record persisted cleanly
        let mem = try #require(memStore.activeRecords.first(where: { $0.transactionID == dinner.id.uuidString }))
        #expect(mem.relationshipType == .sharedExpense)
        #expect(mem.confirmedCategory == SpendCategory.dining.rawValue)
        #expect(abs(mem.personalAmount - 10.0) < 0.0001)
        #expect(abs(mem.reimbursableAmount - 20.0) < 0.0001)
        #expect(mem.confirmationSource == .userConfirmed)

        // Budget reflects 10.0 personal spending
        let finBeforeReverse = Finance(transactions: [dinner], now: now, sharedExpenseOverlay: adjStore.makeOverlay(isEnabled: true))
        #expect(abs(finBeforeReverse.spent(.dining, in: finBeforeReverse.thisMonth) - 10.0) < 0.0001)

        // Reverse adjustment -> restores 30.0 personal spending and marks memory reversed
        let reversed = service.reverseAdjustment(id: adj.id, reason: "Actually paid solo")
        #expect(reversed != nil)
        #expect(adjStore.activeAdjustments.isEmpty)
        #expect(dinner.amount == 30.000) // Still untouched

        let finAfterReverse = Finance(transactions: [dinner], now: now, sharedExpenseOverlay: adjStore.makeOverlay(isEnabled: true))
        #expect(abs(finAfterReverse.spent(.dining, in: finAfterReverse.thisMonth) - 30.0) < 0.0001)

        let reversedMem = memStore.records.first(where: { $0.transactionID == dinner.id.uuidString && $0.relationshipType == .sharedExpense })
        #expect(reversedMem?.isReversed == true)
    }

    // MARK: 14. User-rejected suggestion suppresses future false suggestions

    @Test func userRejectedSuggestionKeepsBudgetUnchangedAndSuppressesRepeatPattern() async {
        let (service, adjStore, memStore, _) = makeIsolatedHarness()
        let now = Date()
        var history = diningHistory(count: 5, amount: 7.000, baseDate: now)
        let dinner1 = MoneyTransaction(amount: 28.000, isIncome: false, merchant: "Steakhouse Prime", category: .dining, date: now.addingTimeInterval(-86_400), source: .sms)
        history.append(dinner1)

        let firstOutcome = await service.analyzeTransaction(dinner1, allTransactions: history, currency: "BHD")
        guard case .suggested(let sug) = firstOutcome else {
            Issue.record("Expected initial suggestion for unusually high steakhouse bill, got \(firstOutcome)")
            return
        }

        // User rejects suggestion
        service.rejectSuggestion(sug, expenseTransaction: dinner1)
        #expect(adjStore.activeAdjustments.isEmpty)
        #expect(adjStore.pendingSuggestions.isEmpty)
        #expect(memStore.activeRecords.contains { $0.relationshipType == .rejectedSuggestion })

        // Future similar expense at the same merchant should NOT repeat the rejected suggestion
        let dinner2 = MoneyTransaction(amount: 29.000, isIncome: false, merchant: "Steakhouse Prime", category: .dining, date: now, source: .sms)
        history.append(dinner2)
        let secondOutcome = await service.analyzeTransaction(dinner2, allTransactions: history, currency: "BHD")
        if case .waitingForMoreContext = secondOutcome {
            // expected: suppressed by rejection memory
        } else {
            Issue.record("Rejected merchant pattern should suppress repeat suggestion, got \(secondOutcome)")
        }
        #expect(adjStore.pendingSuggestions.isEmpty)
    }

    // MARK: 15. Existing transactions processed by current Transaction Rules are respected

    @Test func existingRuleGovernedTransactionsAreNotAutoOverridden() async {
        let now = Date()
        let (service, adjStore, memStore, _) = makeIsolatedHarness(ruleChecker: { _ in true })
        let ruleTx = MoneyTransaction(amount: 30.000, isIncome: false, merchant: "Cafe Rule", category: .dining, date: now.addingTimeInterval(-3600), note: "Dinner split", source: .sms)
        adjStore.savePrediction(SharedExpensePrediction(transactionID: ruleTx.id, sharedProbability: 0.90, estimatedPersonalAmount: 10.0, estimatedReimbursableAmount: 20.0, confidence: 0.78, confidenceLevel: .medium, explanation: "Shared bill", suggestedCategoryRaw: SpendCategory.dining.rawValue))

        let reimb = MoneyTransaction(amount: 20.000, isIncome: true, merchant: "Hassan", category: .transferIn, date: now, note: "Dinner split", source: .sms)
        reimb.smsTransactionType = .transferIn
        if let token = SharedExpensePrivacy.extractSenderToken(from: reimb) {
            memStore.record(SharedExpenseMemoryRecord(transactionID: UUID().uuidString, relationshipType: .reimbursementPattern, confirmedCategory: SpendCategory.dining.rawValue, personalAmount: 10, reimbursableAmount: 20, confirmationSource: .userConfirmed, confidence: 1.0, merchantKey: "cafe rule", senderToken: token))
        }

        // Even with strong signals, rule-governed transactions are downgraded to a user suggestion rather than auto-overridden
        let outcome = await service.analyzeTransaction(reimb, allTransactions: [ruleTx, reimb], currency: "BHD")
        if case .automaticallyAdjusted = outcome {
            Issue.record("Rule-governed transactions must never be automatically overridden")
        }
        guard case .suggested = outcome else {
            Issue.record("Expected downgrade to suggestion when an existing TransactionRule applies, got \(outcome)")
            return
        }
        #expect(adjStore.activeAdjustments.isEmpty)
    }

    // MARK: 16. Disabled feature flag leaves existing application behavior 100% unchanged (+ default is enabled)

    @Test func disabledFeatureFlagLeavesAllExistingBehaviorUnchanged() async {
        // Default setting is enabled when unset
        let savedVal = UserDefaults.standard.object(forKey: Keys.sharedExpenseIntelligenceEnabled)
        defer {
            if let savedVal {
                UserDefaults.standard.set(savedVal, forKey: Keys.sharedExpenseIntelligenceEnabled)
            } else {
                UserDefaults.standard.removeObject(forKey: Keys.sharedExpenseIntelligenceEnabled)
            }
        }
        UserDefaults.standard.removeObject(forKey: Keys.sharedExpenseIntelligenceEnabled)
        #expect(AppSettings.sharedExpenseIntelligenceEnabled == true)

        // When disabled, service is an immediate no-op and Finance ignores all active adjustments
        let (disabledService, adjStore, _, _) = makeIsolatedHarness(enabled: false)
        let now = Date()
        let dinner = MoneyTransaction(amount: 30.000, isIncome: false, merchant: "Lumee", category: .dining, date: now, note: "Group dinner", source: .sms)
        let reimb = MoneyTransaction(amount: 20.000, isIncome: true, merchant: "Ali", category: .income, date: now, source: .sms)

        let outcome = await disabledService.analyzeTransaction(dinner, allTransactions: [dinner], currency: "BHD")
        #expect(outcome == .disabled)

        // Even if an adjustment already existed in store from before disabling, overlay is empty when disabled
        adjStore.upsertAdjustment(SharedExpenseAdjustment(
            originalTransactionID: dinner.id,
            reimbursementAllocations: [ReimbursementAllocation(reimbursementTransactionID: reimb.id, allocatedAmount: 20.000)],
            originalExpenseAmount: 30.000,
            personalAmount: 10.000,
            reimbursableAmount: 20.000,
            effectiveCategoryRaw: SpendCategory.dining.rawValue,
            aiConfidence: 0.95,
            explanation: "Test",
            confirmationSource: .automatic
        ))

        let disabledFinance = Finance(transactions: [dinner, reimb], now: now, sharedExpenseOverlay: adjStore.makeOverlay(isEnabled: false))
        let baselineFinance = Finance(transactions: [dinner, reimb], now: now, sharedExpenseOverlay: .empty)

        #expect(abs(disabledFinance.expenses(in: disabledFinance.thisMonth) - 30.000) < 0.0001)
        #expect(abs(disabledFinance.spent(.dining, in: disabledFinance.thisMonth) - 30.000) < 0.0001)
        #expect(abs(disabledFinance.income(in: disabledFinance.thisMonth) - 20.000) < 0.0001)
        #expect(abs(disabledFinance.expenses(in: disabledFinance.thisMonth) - baselineFinance.expenses(in: baselineFinance.thisMonth)) < 0.0001)
        #expect(abs(disabledFinance.income(in: disabledFinance.thisMonth) - baselineFinance.income(in: baselineFinance.thisMonth)) < 0.0001)
    }
}
