import Foundation
import SwiftData
import Testing
@testable import BudgetAI

@Suite(.serialized)
@MainActor
struct BudgetAITests {

    private func makeCleanContext() -> ModelContext {
        let context = DataStore.shared.mainContext
        let txs = (try? context.fetch(FetchDescriptor<MoneyTransaction>())) ?? []
        for t in txs { context.delete(t) }
        let accs = (try? context.fetch(FetchDescriptor<Account>())) ?? []
        for a in accs { context.delete(a) }
        let budgets = (try? context.fetch(FetchDescriptor<Budget>())) ?? []
        for b in budgets { context.delete(b) }
        let goals = (try? context.fetch(FetchDescriptor<SavingsGoal>())) ?? []
        for g in goals { context.delete(g) }
        let cats = (try? context.fetch(FetchDescriptor<CustomCategory>())) ?? []
        for c in cats { context.delete(c) }
        try? context.save()
        UserDefaults.standard.removeObject(forKey: Keys.smsAccountID)
        UserDefaults.standard.removeObject(forKey: Keys.smsAutoApprove)
        UserDefaults.standard.removeObject(forKey: Keys.smsSyncBalance)
        SMSUserRules.clearAll()
        return context
    }

    // MARK: - 1. Critical Fawri+ Outgoing Regression Test

    @Test func confirmedBisBFawriPlusOutgoingRegression() async throws {
        let context = makeCleanContext()
        let bisbAccount = Account(name: "BisB Current", kind: .bank, institution: "BisB", balance: 266.195)
        context.insert(bisbAccount)
        try context.save()

        let sms = "Fawri+ payment BHD3.000, ref: BIB103KAK000KZUM was credited to IBAN ending 0846 on 2026/10/27 15:26. Balance BHD263.195. Tel: 17515151"

        let parsed = try #require(SMSParser.parse(sms, context: context))
        #expect(parsed.transactionType == .transferOut)
        #expect(abs(parsed.amount - 3.000) < 0.0001)
        #expect(parsed.currency == "BHD")
        #expect(abs((parsed.balance ?? 0) - 263.195) < 0.0001)
        #expect(parsed.referenceNumber == "BIB103KAK000KZUM")
        #expect(parsed.recipientSuffix == "0846")
        #expect(parsed.accountSuffix == nil)
        #expect(parsed.detectedBank == "BisB")
        #expect(parsed.bankConfidence == .high)
        #expect(parsed.confidence == .high)
        #expect(parsed.isIncome == false)
        #expect(parsed.isOrdinaryExpense == false)
        #expect(parsed.category == .transfers)
        #expect(parsed.timeString == "15:26")

        let parsedDate = try #require(parsed.date)
        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: parsedDate)
        #expect(comps.year == 2026)
        #expect(comps.month == 10)
        #expect(comps.day == 27)
        #expect(comps.hour == 15)
        #expect(comps.minute == 26)

        // When imported without a prior user rule, Transfer Out is added as an Expense
        let outcome = await SMSImporter.importText(sms, context: context, forceApprove: true)
        let tx = try #require(outcome.transaction)
        #expect(tx.smsTransactionType == .expense)
        #expect(tx.smsBank == "BisB")
        #expect(tx.smsReference == "BIB103KAK000KZUM")
        #expect(tx.smsRecipientSuffix == "0846")
        #expect(tx.isIncome == false)
        #expect(tx.isSpending == true)
        #expect(tx.isOrdinaryIncome == false)
        #expect(abs(bisbAccount.balance - 263.195) < 0.0001)
    }

    // MARK: - 2. Incoming Transfers, Outgoing Transfers, Internal Transfers & Net Worth

    @Test func incomingFawriPlusTransfer() async throws {
        let context = makeCleanContext()
        let nbb = Account(name: "NBB Savings", kind: .bank, institution: "NBB", balance: 100.000)
        nbb.smsMatch = "1234"
        context.insert(nbb)
        try context.save()

        let sms = "NBB: Your account ending 1234 has been credited with BHD 45.500 via Fawri+ from AHMED ALI on 2026/10/27 10:15. Ref: NBB99887766. Avl Bal: BHD 145.500"
        let parsed = try #require(SMSParser.parse(sms, context: context))
        #expect(parsed.transactionType == .transferIn)
        #expect(parsed.detectedBank == "NBB")
        #expect(abs(parsed.amount - 45.500) < 0.0001)
        #expect(parsed.referenceNumber == "NBB99887766")
        #expect(parsed.accountSuffix == "1234")
        #expect(parsed.isIncome == true)
        #expect(parsed.isOrdinaryExpense == false)
        #expect(parsed.category == .transfers)

        // When imported without a prior user rule, Transfer In is added as Income
        let outcome = await SMSImporter.importText(sms, context: context, forceApprove: true)
        let tx = try #require(outcome.transaction)
        #expect(tx.smsTransactionType == .income)
        #expect(tx.isOrdinaryIncome == true)
        #expect(tx.isSpending == false)
        #expect(abs(nbb.balance - 145.500) < 0.0001)
    }

    @Test func internalTransferBetweenOwnAccountsPreservesNetWorth() async throws {
        let context = makeCleanContext()
        let bisb = Account(name: "BisB Account", kind: .bank, institution: "BisB", balance: 266.195)
        bisb.smsMatch = "9001"
        let ila = Account(name: "ila Account", kind: .bank, institution: "ila", balance: 100.000)
        ila.smsMatch = "0846"
        context.insert(bisb)
        context.insert(ila)
        try context.save()

        let initialNetWorth = Finance(transactions: [], accounts: [bisb, ila]).netWorth
        #expect(abs(initialNetWorth - 366.195) < 0.0001)

        // Because IBAN ending 0846 matches the user's own ila Account, this Fawri+ payment is classified as an internal transfer
        let sms = "Fawri+ payment BHD3.000, ref: BIB103KAK000KZUM was credited to IBAN ending 0846 on 2026/10/27 15:26. Balance BHD263.195. Tel: 17515151"
        let outcome = await SMSImporter.importText(sms, context: context, forceApprove: true)
        let tx = try #require(outcome.transaction)

        #expect(tx.smsTransactionType == .internalTransfer)
        #expect(tx.accountID == bisb.id)
        #expect(tx.toAccountID == ila.id)
        #expect(abs(bisb.balance - 263.195) < 0.0001)
        #expect(abs(ila.balance - 103.000) < 0.0001)

        let afterFinance = Finance(transactions: [tx], accounts: [bisb, ila], now: tx.date)
        #expect(abs(afterFinance.netWorth - initialNetWorth) < 0.0001)
        #expect(afterFinance.income(in: afterFinance.monthInterval(tx.date)) == 0)
        #expect(afterFinance.expenses(in: afterFinance.monthInterval(tx.date)) == 0)
    }

    // MARK: - 3. Salary Credits, Card Purchases, Refunds, and Fees

    @Test func salaryCreditClassification() async throws {
        let context = makeCleanContext()
        let bbk = Account(name: "BBK Main", kind: .bank, institution: "BBK", balance: 378.850)
        bbk.smsMatch = "8801"
        context.insert(bbk)
        try context.save()

        let sms = "BBK: Salary of BHD 1,250.000 has been credited to your account ending 8801 on 2026-10-25. Avl Bal: BHD 1,628.850"
        let outcome = await SMSImporter.importText(sms, context: context, forceApprove: true)
        let tx = try #require(outcome.transaction)

        #expect(tx.smsTransactionType == .income)
        #expect(tx.smsBank == "BBK")
        #expect(tx.isOrdinaryIncome == true)
        #expect(tx.isSpending == false)
        #expect(tx.category == .income)
        #expect(abs(tx.amount - 1250.000) < 0.0001)

        let f = Finance(transactions: [tx], accounts: [bbk], now: tx.date)
        #expect(abs(f.income(in: f.monthInterval(tx.date)) - 1250.000) < 0.0001)
        #expect(f.expenses(in: f.monthInterval(tx.date)) == 0)
    }

    @Test func cardPurchaseAndArabicDigitsClassification() throws {
        SMSUserRules.clearAll()
        let enSMS = "Your NBB card ending 1234 was used for BHD 6.750 at TALABAT BH on 24-Oct. Avl Bal: BHD 412.300"
        let enParsed = try #require(SMSParser.parse(enSMS))
        #expect(enParsed.transactionType == .expense)
        #expect(enParsed.detectedBank == "NBB")
        #expect(abs(enParsed.amount - 6.750) < 0.0001)
        #expect(enParsed.currency == "BHD")
        #expect(enParsed.accountSuffix == "1234")
        #expect(enParsed.category == .dining)
        #expect(abs((enParsed.balance ?? 0) - 412.300) < 0.0001)

        let arSMS = "بنك إلى: تم خصم مبلغ ١٨.٤٥٠ د.ب باستخدام البطاقة رقم 9921 لدى اللولو هايبرماركت. الرصيد المتاح: ٣٧٨.٨٥٠ د.ب"
        let arParsed = try #require(SMSParser.parse(arSMS))
        #expect(arParsed.transactionType == .expense)
        #expect(arParsed.detectedBank == "ila")
        #expect(abs(arParsed.amount - 18.450) < 0.0001)
        #expect(arParsed.currency == "BHD")
        #expect(arParsed.accountSuffix == "9921")
        #expect(arParsed.category == .groceries)
        #expect(abs((arParsed.balance ?? 0) - 378.850) < 0.0001)
    }

    @Test func refundAndFeeClassification() async throws {
        let context = makeCleanContext()
        let nbb = Account(name: "NBB", kind: .bank, institution: "NBB", balance: 200.000)
        nbb.smsMatch = "1234"
        context.insert(nbb)
        try context.save()

        let refundSMS = "NBB: Refund of BHD 12.400 from AMAZON has been credited back to your card ending 1234 on 2026-10-27. Ref: REF112233"
        let refundOutcome = await SMSImporter.importText(refundSMS, context: context, forceApprove: true)
        let refundTx = try #require(refundOutcome.transaction)
        #expect(refundTx.smsTransactionType == .refund)
        #expect(refundTx.isIncome == true)
        #expect(refundTx.isOrdinaryIncome == false) // Refunds do not inflate gross income
        #expect(refundTx.isSpending == false)

        let feeSMS = "NBB: Transfer fee of BHD 0.110 debited from your account ending 1234 on 2026-10-27. Ref: FEE998877"
        let feeOutcome = await SMSImporter.importText(feeSMS, context: context, forceApprove: true)
        let feeTx = try #require(feeOutcome.transaction)
        #expect(feeTx.smsTransactionType == .fee)
        #expect(feeTx.isIncome == false)
        #expect(feeTx.isSpending == true)
        #expect(feeTx.category == .bills)
    }

    // MARK: - 4. Ambiguous Messages, Low Confidence Bank, and Non-Transaction Filtering

    @Test func ambiguousFawriMessageRequiresReviewAndDoesNotGuessBank() async throws {
        let context = makeCleanContext()
        let acc = Account(name: "Main Bank", kind: .bank, balance: 500.000)
        context.insert(acc)
        try context.save()

        // Ambiguous Fawri+ SMS without bank name, without helpline, and without clear direction
        let ambiguousSMS = "Fawri+ BHD 25.000 IBAN *0846 on 2026/10/27. Balance BHD 475.000"
        let parsed = try #require(SMSParser.parse(ambiguousSMS, context: context))

        #expect(parsed.detectedBank == nil) // Never guess a bank when confidence is low
        #expect(parsed.bankConfidence == .low)
        #expect(parsed.transactionType == .unknown)
        #expect(parsed.confidence == .low)
        #expect(parsed.requiresReview == true)

        // Importing an ambiguous message must mark it pending for user review even when forceApprove is true
        let outcome = await SMSImporter.importText(ambiguousSMS, context: context, forceApprove: true)
        let tx = try #require(outcome.transaction)
        #expect(tx.isPending == true)
        #expect(tx.smsTransactionType == .unknown)
        #expect(tx.smsBank == nil)
        #expect(abs(acc.balance - 500.000) < 0.0001) // Balance untouched while pending/unknown

        // OTP and declined messages return nil
        #expect(SMSParser.parse("Your OTP for BHD 50.000 transaction is 482910. Do not share this code.") == nil)
        #expect(SMSParser.parse("Your card ending 1234 was declined for BHD 12.000 at TALABAT due to insufficient funds.") == nil)
    }

    // MARK: - 5. Duplicate Prevention via Reference Numbers

    @Test func duplicatePreventionByReferenceNumber() async throws {
        let context = makeCleanContext()
        let bisb = Account(name: "BisB", kind: .bank, institution: "BisB", balance: 300.000)
        context.insert(bisb)
        try context.save()

        let sms1 = "Fawri+ payment BHD3.000, ref: BIB103KAK000KZUM was credited to IBAN ending 0846 on 2026/10/27 15:26. Balance BHD263.195. Tel: 17515151"
        let first = await SMSImporter.importText(sms1, context: context, forceApprove: true)
        #expect(first.flaggedDuplicate == false)

        // Same reference number imported again -> flagged as duplicate
        let duplicate = await SMSImporter.importText(sms1, context: context, forceApprove: true)
        #expect(duplicate.flaggedDuplicate == true)

        // Same amount & recipient on the same day, but a DIFFERENT reference number -> NOT a duplicate
        let smsDistinctRef = "Fawri+ payment BHD3.000, ref: BIB103KAK0009999 was credited to IBAN ending 0846 on 2026/10/27 15:30. Balance BHD260.195. Tel: 17515151"
        let distinct = await SMSImporter.importText(smsDistinctRef, context: context, forceApprove: true)
        #expect(distinct.flaggedDuplicate == false)
    }

    // MARK: - 6. User Corrections, Scoped Learning, and Sender-vs-Account Separation

    @Test func userCorrectionsUpdateBalancesAndScopeRulesProperly() async throws {
        let context = makeCleanContext()
        let nbb = Account(name: "NBB Current", kind: .bank, institution: "NBB", balance: 500.000)
        let bbk = Account(name: "BBK Savings", kind: .bank, institution: "BBK", balance: 200.000)
        context.insert(nbb)
        context.insert(bbk)
        try context.save()

        // 1. Import an ambiguous message from sender "88990" assigned to account NBB
        let ambiguous1 = "Alert: BHD 10.000 processed for ACCT *7711 on 2026/10/27"
        let outcome1 = await SMSImporter.importText(ambiguous1, context: context, forceApprove: true, accountID: nbb.id, sender: "88990")
        let tx1 = try #require(outcome1.transaction)
        #expect(tx1.isPending == true)
        #expect(tx1.smsTransactionType == .unknown)
        #expect(tx1.smsBank == nil)
        #expect(abs(nbb.balance - 500.000) < 0.0001)

        // 2. User corrects tx1: assigns bank "Al Salam" (separate from NBB account!), classifies as .expense,
        // and customizes the name ("Gym Membership"), category (.health), and account (bbk.id)
        Ledger.applyUserCorrection(
            to: tx1,
            newType: .expense,
            newBank: "Al Salam",
            newCategory: .health,
            approveIfPending: true,
            rememberRule: true,
            context: context
        )
        tx1.merchant = "Gym Membership"
        Ledger.edit(tx1, context: context) { target in
            target.accountID = bbk.id
            target.amount = 12.500 // Also test editing transaction amount
        }
        SMSUserRules.rememberTransactionRule(for: tx1)

        #expect(tx1.isPending == false)
        #expect(tx1.smsTransactionType == .expense)
        #expect(tx1.smsBank == "Al Salam")
        #expect(tx1.merchant == "Gym Membership")
        #expect(tx1.category == .health)
        #expect(tx1.accountID == bbk.id)
        #expect(abs(nbb.balance - 500.000) < 0.0001) // Reversed from NBB when moved to BBK
        #expect(abs(bbk.balance - 187.500) < 0.0001) // Deducted edited amount 12.500 from BBK

        // 3. Future message from the same sender "88990" with same template & counterparty *7711 automatically remembers
        // bank, transaction type, category, custom name, and source account!
        let ambiguous2 = "Alert: BHD 25.000 processed for ACCT *7711 on 2026/10/28"
        let outcome2 = await SMSImporter.importText(ambiguous2, context: context, forceApprove: true, sender: "88990")
        let tx2 = try #require(outcome2.transaction)
        #expect(tx2.smsBank == "Al Salam")
        #expect(tx2.smsTransactionType == .expense)
        #expect(tx2.smsConfidence == .high)
        #expect(tx2.merchant == "Gym Membership")
        #expect(tx2.category == .health)
        #expect(tx2.accountID == bbk.id)
        #expect(abs(tx2.amount - 25.000) < 0.0001)

        // 4. Unrelated message with a different counterparty/structure is NOT affected by the correction rule
        let unrelated = "Alert: BHD 15.000 processed for ACCT *9999 on 2026/10/28"
        let parsedUnrelated = try #require(SMSParser.parse(unrelated, sender: "OTHER_SENDER", context: context))
        #expect(parsedUnrelated.detectedBank == nil)
        #expect(parsedUnrelated.transactionType == .unknown)
    }

    // MARK: - 7. Auto-Contribute to Linked Savings Goal on SMS Transfer

    @Test func smsTransferAutoContributesToLinkedSavingsGoal() async throws {
        let context = makeCleanContext()
        let bisb = Account(name: "BisB Current", kind: .bank, institution: "BisB", balance: 266.195)
        let ilaSavings = Account(name: "ila Hassala", kind: .bank, institution: "ila", balance: 100.000)
        ilaSavings.smsMatch = "0846"
        context.insert(bisb)
        context.insert(ilaSavings)

        let emergencyGoal = SavingsGoal(
            name: "Emergency Fund",
            symbol: "shield.lefthalf.filled",
            target: 1000.000,
            saved: 100.000,
            targetDate: Calendar.current.date(byAdding: .month, value: 6, to: .now) ?? .now,
            monthlyCommitment: 50.000,
            linkedAccountID: ilaSavings.id,
            smsMatch: "0846"
        )
        context.insert(emergencyGoal)
        try context.save()

        let sms = "Fawri+ payment BHD3.000, ref: BIB103KAK000KZUM was credited to IBAN ending 0846 on 2026/10/27 15:26. Balance BHD263.195. Tel: 17515151"
        let outcome = await SMSImporter.importText(sms, context: context, forceApprove: true)
        let tx = try #require(outcome.transaction)

        #expect(tx.category == .internalTransfer)
        #expect(tx.smsTransactionType == .internalTransfer)
        #expect(tx.toAccountID == ilaSavings.id)
        #expect(tx.goalID == emergencyGoal.id)
        #expect(abs(bisb.balance - 263.195) < 0.0001)
        #expect(abs(ilaSavings.balance - 103.000) < 0.0001)
        #expect(abs(emergencyGoal.saved - 103.000) < 0.0001)

        // Editing the transfer amount updates both the linked account and the linked SavingsGoal
        Ledger.edit(tx, context: context) { target in
            target.amount = 10.000
        }
        #expect(abs(ilaSavings.balance - 110.000) < 0.0001)
        #expect(abs(emergencyGoal.saved - 110.000) < 0.0001)
    }

    // MARK: - 8. Account Include/Exclude in Net Worth vs Cash & Bank

    @Test func accountIncludeInNetWorthToggle() throws {
        let checking = Account(name: "NBB Current", kind: .bank, institution: "NBB", balance: 400.000, includeInNetWorth: true)
        let hiddenSavings = Account(name: "Side Vault", kind: .bank, institution: "ila", balance: 600.000, includeInNetWorth: false)
        let carLoan = Account(name: "Car Loan", kind: .loan, institution: "BBK", balance: 150.000, includeInNetWorth: false)

        let finance = Finance(transactions: [], accounts: [checking, hiddenSavings, carLoan])
        // Liquid balance (Cash & bank) still counts all liquid cash & bank accounts (400 + 600 = 1000)
        #expect(abs(finance.liquidBalance - 1000.000) < 0.0001)
        // Net worth only counts accounts with includeInNetWorth == true (400)
        #expect(abs(finance.totalAssets - 400.000) < 0.0001)
        #expect(abs(finance.totalLiabilities - 0.000) < 0.0001)
        #expect(abs(finance.netWorth - 400.000) < 0.0001)
    }

    // MARK: - 9. Visa Credit Card Payment SMS

    @Test func visaCardPaymentPaysDownCardAndKeepsBankBalance() async throws {
        let context = makeCleanContext()
        let bisb = Account(name: "BisB Current", kind: .bank, institution: "BisB", balance: 1000.000)
        let visa = Account(name: "Visa Infinite", kind: .creditCard, institution: "BisB", balance: 457.558)
        context.insert(bisb)
        context.insert(visa)
        try context.save()

        let sms = "Dear ISA, Thank you for paying BHD 457.558 on 24/10 for your VISA INFINITE card. Available Bal BHD 5000. Tel 17515151"
        let parsed = try #require(SMSParser.parse(sms, context: context))
        #expect(parsed.category == .visaTransfer)
        #expect(parsed.transactionType == .internalTransfer)
        #expect(abs(parsed.amount - 457.558) < 0.0001)
        #expect(abs((parsed.balance ?? 0) - 5000) < 0.0001)
        #expect(parsed.balanceIsCardLimit == true)
        #expect(parsed.toAccountID == visa.id)
        #expect(parsed.requiresReview == false)

        let outcome = await SMSImporter.importText(sms, context: context, forceApprove: true)
        let tx = try #require(outcome.transaction)
        #expect(tx.category == .visaTransfer)
        #expect(tx.accountID == bisb.id)
        #expect(tx.toAccountID == visa.id)
        #expect(tx.isSpending == false)
        #expect(tx.isOrdinaryIncome == false)
        #expect(tx.smsBalanceIsCardLimit == true)
        #expect(tx.balanceAdjustment == 0)
        // Bank is debited by the payment and NOT synced to the card's 5000 available limit
        #expect(abs(bisb.balance - 542.442) < 0.0001)
        // Visa balance owed is paid off
        #expect(abs(visa.balance - 0) < 0.0001)

        let comps = Calendar.current.dateComponents([.month, .day], from: tx.date)
        #expect(comps.month == 10)
        #expect(comps.day == 24)

        // Deleting the payment restores both balances
        Ledger.delete(tx, context: context)
        #expect(abs(bisb.balance - 1000.000) < 0.0001)
        #expect(abs(visa.balance - 457.558) < 0.0001)
    }

    @Test func creditCardDueDateRollsMonthly() throws {
        let cal = Calendar.current
        let card = Account(name: "Visa", kind: .creditCard, balance: 0)
        card.paymentDueReminder = true
        let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 31, hour: 10))!
        card.paymentDueDate = cal.date(from: DateComponents(year: 2026, month: 9, day: 25))!
        let next = card.nextUpcomingDueDate(from: now)
        let c = cal.dateComponents([.year, .month, .day], from: next)
        #expect(c.year == 2026)
        #expect(c.month == 11)
        #expect(c.day == 25)
        #expect(card.upcomingDueDates(count: 3, from: now).count == 3)
    }

    // MARK: - 9. Auto-Marking Bills/Subscriptions from SMS & Quarantining Uncertain SMS

    @Test func autoMarkBillPaidFromSMSAndHoldCycle() throws {
        let context = makeCleanContext()
        let cal = Calendar.current
        let currentCycle = Cycle.interval(containing: .now)
        let dueDate = currentCycle.start.addingTimeInterval(86400 * 5)
        let bill = Bill(name: "Batelco Fiber", amount: 15.000, category: .bills, nextDueDate: dueDate, frequency: .monthly)
        context.insert(bill)
        try context.save()

        #expect(bill.isPaidForCurrentCycle(now: .now) == false)

        // Incoming expense matching keyword "Batelco" and amount 15.000
        let tx = MoneyTransaction(amount: 15.000, isIncome: false, merchant: "Batelco Online", category: .bills, date: .now, source: .sms)
        tx.rawText = "Dear customer, BD 15.000 paid to Batelco for ref 998811. Available bal BD 120."

        let matched = Ledger.matchAndPayBillFromSMS(tx, context: context)
        #expect(matched != nil)
        #expect(matched?.id == bill.id)
        #expect(bill.isPaidForCurrentCycle(now: .now) == true)
        #expect(bill.lastPaidMethod == .autoSMS)
        #expect(bill.lastPaidAmount == 15.000)

        // nextDueDate advanced to next month cycle
        let nextDueDateMonth = cal.component(.month, from: bill.nextDueDate)
        let expectedNextMonth = cal.component(.month, from: cal.date(byAdding: .month, value: 1, to: dueDate) ?? dueDate)
        #expect(nextDueDateMonth == expectedNextMonth)

        // Finance upcomingBills excludes this paid bill during the current cycle
        let f = Finance(transactions: [tx], accounts: [], budgets: [], goals: [], bills: [bill], now: .now)
        #expect(f.upcomingBills.isEmpty)
        #expect(f.billsDueRestOfMonth == 0)

        // When evaluating next cycle, it becomes due again
        let nextCycleDate = currentCycle.end.addingTimeInterval(86400 * 2)
        #expect(bill.isPaidForCurrentCycle(now: nextCycleDate) == false)
        let fNext = Finance(transactions: [], accounts: [], budgets: [], goals: [], bills: [bill], now: nextCycleDate)
        #expect(fNext.upcomingBills.count == 1)
        #expect(fNext.upcomingBills.first?.id == bill.id)
    }

    @Test func smsNoteFieldIsEmptyAndUncertainQuarantined() async throws {
        let context = makeCleanContext()
        let acc = Account(name: "My Bank", kind: .bank, balance: 200.000)
        context.insert(acc)
        try context.save()

        // SMS with unknown bank sender and low confidence -> must be quarantined (isPending)
        let unknownSMS = "Paid BHD 12.500 at UNKNOWN_VENDOR. Ref: REF991188. Bal BHD 187.500"
        let outcome = await SMSImporter.importText(unknownSMS, context: context)
        let tx = try #require(outcome.transaction)

        // Note field MUST be empty (SMS reference preserved in smsReference)
        #expect(tx.note.isEmpty)
        #expect(tx.smsReference == "REF991188")

        // Must be quarantined (isPending = true) and NOT deduct from account balance yet
        #expect(tx.isPending == true)
        #expect(abs(acc.balance - 200.000) < 0.0001)

        // When approved, balance is deducted
        Ledger.approve(tx, context: context)
        #expect(tx.isPending == false)
        #expect(abs(acc.balance - 187.500) < 0.0001)
    }

    @Test func billCustomKeywordsMatching() throws {
        let context = makeCleanContext()
        let cal = Calendar.current
        let dueDate = cal.date(from: DateComponents(year: 2026, month: 10, day: 25))!
        // Bill named "Home Internet" with custom keywords "Fiber, Batelco, SADAD"
        let bill = Bill(name: "Home Internet", amount: 16.500, category: .bills, nextDueDate: dueDate, frequency: .monthly, keywords: "Fiber, Batelco, SADAD")
        context.insert(bill)
        try context.save()

        #expect(bill.keywords.count == 3)
        #expect(bill.keywords.contains("Batelco"))

        // SMS mentions "Fiber" and "SADAD" while bill name is "Home Internet"
        let tx = MoneyTransaction(amount: 16.500, isIncome: false, merchant: "SADAD PAYMENT", category: .bills, date: .now, source: .sms)
        tx.rawText = "Dear customer, payment of BD 16.500 via SADAD for Fiber bill was processed."

        let matched = Ledger.matchAndPayBillFromSMS(tx, context: context)
        #expect(matched != nil)
        #expect(matched?.id == bill.id)
        #expect(bill.isPaidForCurrentCycle() == true)
        #expect(bill.lastPaidMethod == .autoSMS)
    }

    @Test func unmatchedBalanceSMSIsNotQuarantined() async throws {
        let context = makeCleanContext()
        let acc = Account(name: "BisB Main", kind: .bank, institution: "BisB", balance: 500.000)
        context.insert(acc)
        try context.save()

        // Incoming purchase from known bank BisB with an updated balance (not quarantined despite balance difference)
        let sms = "BisB: Purchase of BHD 15.000 at CARREFOUR on 2026/10/28. Avl Bal BHD 200.000. Tel 17515151"
        let outcome = await SMSImporter.importText(sms, context: context, forceApprove: true)
        let tx = try #require(outcome.transaction)

        #expect(tx.isPending == false)
        #expect(tx.smsBank == "BisB")
    }
}
