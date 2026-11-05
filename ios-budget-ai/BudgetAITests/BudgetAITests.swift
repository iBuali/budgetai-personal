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

        // 1. A single SMS with recipient IBAN ending 0846 is NEVER marked as internalTransfer on its own
        let sms1 = "Fawri+ payment BHD3.000, ref: BIB103KAK000KZUM was credited to IBAN ending 0846 on 2026/10/27 15:26. Balance BHD263.195. Tel: 17515151"
        let outcome1 = await SMSImporter.importText(sms1, context: context, forceApprove: true)
        let tx = try #require(outcome1.transaction)
        #expect(tx.smsTransactionType == .expense)
        #expect(tx.toAccountID == nil)

        // 2. When matched with a second SMS at the same date & time (2026/10/27 15:26), Rule 6 applies:
        //    - Converts to internalTransfer
        //    - Analyzes debit (BisB) vs credit (ila)
        //    - Includes both banks in smsBank ("BisB · ila")
        //    - Stores both SMS messages in rawText
        let sms2 = "Credit transaction of BHD 3.000 to account 0846 on 2026/10/27 15:26. Available balance is BHD 103.000. Call 17123456"
        _ = await SMSImporter.importText(sms2, context: context, forceApprove: true)

        #expect(tx.smsTransactionType == .internalTransfer)
        #expect(tx.category == .internalTransfer)
        #expect(tx.accountID == bisb.id)
        #expect(tx.toAccountID == ila.id)
        #expect(tx.smsBank == "BisB · ila")
        #expect(tx.rawText?.contains(sms1) == true)
        #expect(tx.rawText?.contains(sms2) == true)
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

    // MARK: - 7. Savings Goal Linking (Only on Internal Transfer or Manual Addition)

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

        // 1. Single SMS where recipient IBAN matches savings goal:
        // Rule: It will NOT add the transaction to the goal unless it's marked as internal transfer!
        let sms1 = "Fawri+ payment BHD3.000, ref: BIB103KAK000KZUM was credited to IBAN ending 0846 on 2026/10/27 15:26. Balance BHD263.195. Tel: 17515151"
        let outcome1 = await SMSImporter.importText(sms1, context: context, forceApprove: true)
        let tx1 = try #require(outcome1.transaction)

        #expect(tx1.smsTransactionType == .expense)
        #expect(tx1.category != .internalTransfer)
        #expect(tx1.goalID == nil)
        #expect(abs(emergencyGoal.saved - 100.000) < 0.0001)

        // 2. Can be manually added to the savings goal:
        Ledger.edit(tx1, context: context) { target in
            target.goalID = emergencyGoal.id
        }
        #expect(tx1.goalID == emergencyGoal.id)
        #expect(abs(emergencyGoal.saved - 103.000) < 0.0001)

        // Editing amount updates the manually linked goal
        Ledger.edit(tx1, context: context) { target in
            target.amount = 10.000
        }
        #expect(abs(emergencyGoal.saved - 110.000) < 0.0001)

        // 3. When marked as internal transfer (e.g. matched with second SMS at same date & time),
        // it DOES automatically link to the savings goal:
        let bisb2 = Account(name: "BisB 2", kind: .bank, institution: "BisB", balance: 500.000)
        bisb2.smsMatch = "9901"
        context.insert(bisb2)

        let tripGoal = SavingsGoal(
            name: "Trip Goal",
            symbol: "airplane",
            target: 500.000,
            saved: 50.000,
            targetDate: Calendar.current.date(byAdding: .month, value: 3, to: .now) ?? .now,
            monthlyCommitment: 25.000,
            linkedAccountID: ilaSavings.id,
            smsMatch: "0846"
        )
        context.insert(tripGoal)
        try context.save()

        let transferDebitSMS = "Your account ending 9901 has been debited BHD 25.000 for outward transfer on 2026/10/28 12:00. Balance BHD 475.000. Tel: 17515151"
        let transferCreditSMS = "Your account ending 0846 has been credited with BHD 25.000 via Fawri+ on 2026/10/28 12:00. Available balance BHD 125.000. Call 17123456"

        _ = await SMSImporter.importText(transferDebitSMS, context: context, forceApprove: true)
        let mergedOutcome = await SMSImporter.importText(transferCreditSMS, context: context, forceApprove: true)
        let mergedTx = try #require(mergedOutcome.transaction)

        #expect(mergedTx.smsTransactionType == .internalTransfer)
        #expect(mergedTx.category == .internalTransfer)
        #expect(mergedTx.toAccountID == ilaSavings.id)
        #expect(mergedTx.goalID == tripGoal.id || mergedTx.goalID == emergencyGoal.id)
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

    @Test func safeToSpendSubtractsLiabilities() throws {
        let bank = Account(name: "Checking", kind: .bank, balance: 1000.0)
        let loan = Account(name: "Car Loan", kind: .loan, balance: 200.0)
        let bill = Bill(name: "Internet", amount: 50.0, category: .bills, nextDueDate: .now.addingTimeInterval(86400 * 2), frequency: .monthly)
        let f = Finance(transactions: [], accounts: [bank, loan], bills: [bill])

        let safe = f.safeToSpend
        #expect(safe.spendable == 1000.0)
        #expect(safe.billsDue == 50.0)
        #expect(safe.liabilities == 200.0)
        // monthly = max(0, 1000 - 50 - 0 - 0 - 200) = 750.0
        #expect(safe.monthly == 750.0)
        #expect(safe.isShort == false)
    }

    // MARK: - Financial Time Machine engine

    private func simpleBaseline(commitments: [ScheduledCommitment] = []) -> FinancialBaseline {
        FinancialBaseline(startingBalance: 1000, recurringIncome: 0, recurringIncomeDay: 1, recurringSources: [],
                          otherIncome: 0,
                          categories: [CategoryBaseline(category: .groceries, monthly: TimeMachineEngine.daysPerMonth * 10)],
                          refundsMonthly: 0, commitments: commitments, historyDays: 90, isDemo: false)
    }

    @Test func timeMachineExpectedProjection() throws {
        let r = TimeMachineEngine.simulate(simpleBaseline(), SimulationAssumptions(), scenario: .expected, days: 30)
        #expect(abs(r.endBalance - 700) < 0.001)
        #expect(abs(r.totalExpenses - 300) < 0.001)
        #expect(r.points.count == 31)
        #expect(abs(r.estimatedSavings + 300) < 0.001)
    }

    @Test func timeMachineScenariosAndAdjustments() throws {
        var a = SimulationAssumptions()
        a.conservativeExpenseBuffer = 10
        let conservative = TimeMachineEngine.simulate(simpleBaseline(), a, scenario: .conservative, days: 30)
        #expect(abs(conservative.endBalance - 670) < 0.001)

        a.expenseChangeAmount = -TimeMachineEngine.daysPerMonth * 2 // −2 per day
        let reduced = TimeMachineEngine.simulate(simpleBaseline(), a, scenario: .expected, days: 30)
        #expect(abs(reduced.endBalance - 760) < 0.001)

        var b = SimulationAssumptions()
        b.events = [OneTimeEvent(title: "Bonus", amount: 200, date: Date.now.addingTimeInterval(86400 * 3), isIncome: true)]
        let expected = TimeMachineEngine.simulate(simpleBaseline(), b, scenario: .expected, days: 30)
        let cautious = TimeMachineEngine.simulate(simpleBaseline(), b, scenario: .conservative, days: 30)
        #expect(abs(expected.totalIncome - 200) < 0.001)
        #expect(cautious.totalIncome < expected.totalIncome)
    }

    @Test func timeMachineSchedulesBillsOnce() throws {
        let bill = ScheduledCommitment(id: UUID(), name: "Rent", amount: 50,
                                       nextDueDate: Date.now.addingTimeInterval(86400 * 5), frequency: .monthly, isSubscription: false)
        let r = TimeMachineEngine.simulate(simpleBaseline(commitments: [bill]), SimulationAssumptions(), scenario: .expected, days: 30)
        #expect(abs(r.commitmentsTotal - 50) < 0.001)
        #expect(abs(r.endBalance - 650) < 0.001)

        var off = SimulationAssumptions()
        off.includeCommitments = false
        let none = TimeMachineEngine.simulate(simpleBaseline(commitments: [bill]), off, scenario: .expected, days: 30)
        #expect(none.commitmentsTotal == 0)
    }

    @Test func timeMachineBaselineExcludesTransfers() throws {
        let bank = Account(name: "Main", kind: .bank, balance: 1000)
        let now = Date.now
        let salary = MoneyTransaction(amount: 1000, isIncome: true, merchant: "Employer", category: .income, date: now.addingTimeInterval(-86400 * 10))
        let transfer = MoneyTransaction(amount: 500, isIncome: true, merchant: "Own account", category: .internalTransfer, date: now.addingTimeInterval(-86400 * 5))
        let food = MoneyTransaction(amount: 100, isIncome: false, merchant: "Market", category: .groceries, date: now.addingTimeInterval(-86400 * 3))
        let f = Finance(transactions: [salary, transfer, food], accounts: [bank])
        let base = TimeMachineEngine.baseline(from: f, now: now)
        let months = 30 / TimeMachineEngine.daysPerMonth
        #expect(base.isDemo == false)
        #expect(base.startingBalance == 1000)
        #expect(abs(base.monthlyIncome - 1000 / months) < 0.001)
        #expect(abs(base.grossSpending - 100 / months) < 0.001)
    }

    @Test func savedConditionsManagementAndClearAll() throws {
        SMSUserRules.clearAll()
        #expect(SMSUserRules.totalConditionsCount() == 0)

        // 1. Add sender bank condition
        SMSUserRules.rememberBank("BisB", forSender: "17515151")
        #expect(SMSUserRules.allSenderBanks().count == 1)
        #expect(SMSUserRules.bank(forSender: "17515151") == "BisB")

        // 2. Add classification condition
        SMSUserRules.rememberClassification(
            type: .expense,
            category: .dining,
            merchant: "Cafeteria",
            bank: "BisB",
            forRawSMS: "Purchase of BHD 2.500 at Cafeteria with card 1234",
            sender: "17515151"
        )
        #expect(SMSUserRules.allClassificationRules().count == 1)
        #expect(SMSUserRules.totalConditionsCount() == 2)

        let rule = try #require(SMSUserRules.allClassificationRules().first)
        #expect(rule.merchant == "Cafeteria")
        #expect(rule.category == .dining)
        #expect(rule.transactionType == .expense)

        // 3. Delete single classification rule
        SMSUserRules.removeClassificationRule(signature: rule.signature)
        #expect(SMSUserRules.allClassificationRules().count == 0)
        #expect(SMSUserRules.totalConditionsCount() == 1)

        // 4. Clear all conditions
        SMSUserRules.clearAll()
        #expect(SMSUserRules.totalConditionsCount() == 0)
        #expect(SMSUserRules.allSenderBanks().isEmpty)
        #expect(SMSUserRules.allClassificationRules().isEmpty)
    }

    @Test func multipleAccountsByBankPhoneAndSavedSenderRules() async throws {
        let context = makeCleanContext()
        let bisb = Account(name: "BisB Account", kind: .bank, institution: "BisB", balance: 500.000)
        let ila = Account(name: "ila Bank", kind: .bank, institution: "ila", balance: 300.000)
        context.insert(bisb)
        context.insert(ila)
        try context.save()

        // 1. SMS with phone 17515151 (without explicit sender parameter) routes to BisB Account
        let bisbSMS = "Your card ending 4411 was used for BHD 10.000 at STARBUCKS on 2026/10/28 09:15. Tel: 17515151"
        let out1 = await SMSImporter.importText(bisbSMS, context: context, forceApprove: true, sender: nil)
        let tx1 = try #require(out1.transaction)
        #expect(tx1.smsBank == "BisB")
        #expect(tx1.smsSender == "17515151")
        #expect(tx1.accountID == bisb.id)
        #expect(tx1.isPending == false)
        #expect(abs(bisb.balance - 490.000) < 0.0001)
        #expect(abs(ila.balance - 300.000) < 0.0001)

        // 2. SMS with phone 17123456 (without explicit sender parameter) routes to ila Bank Account
        let ilaSMS = "Your card ending 8822 was used for BHD 20.000 at CARREFOUR on 2026/10/28 10:30. Call 17123456"
        let out2 = await SMSImporter.importText(ilaSMS, context: context, forceApprove: true, sender: nil)
        let tx2 = try #require(out2.transaction)
        #expect(tx2.smsBank == "ila")
        #expect(tx2.smsSender == "17123456")
        #expect(tx2.accountID == ila.id)
        #expect(tx2.isPending == false)
        #expect(abs(ila.balance - 280.000) < 0.0001)

        // 3. User saves custom sender phone/ID linked to ila account, recognized even when Shortcut sender is nil
        SMSUserRules.rememberBank("ila", forSender: "99001122", accountID: ila.id)
        let customSenderSMS = "Purchase of BHD 5.000 at COSTA COFFEE on 2026/10/28 11:00. Helpline: +973 9900 1122"
        let out3 = await SMSImporter.importText(customSenderSMS, context: context, forceApprove: true, sender: nil)
        let tx3 = try #require(out3.transaction)
        #expect(tx3.smsBank == "ila")
        #expect(tx3.accountID == ila.id)
        #expect(tx3.isPending == false)
        #expect(abs(ila.balance - 275.000) < 0.0001)
    }

    @Test func simultaneousTransferBetweenAccountsMergesIntoSingleTransaction() async throws {
        let context = makeCleanContext()
        let bisb = Account(name: "BisB Account", kind: .bank, institution: "BisB", balance: 500.000)
        bisb.smsMatch = "9001"
        let ila = Account(name: "ila Account", kind: .bank, institution: "ila", balance: 200.000)
        ila.smsMatch = "0846"
        context.insert(bisb)
        context.insert(ila)
        try context.save()

        // Case A: First SMS is Transfer Out from BisB, Second SMS at same date & time is Transfer In to ila Bank.
        // Both SMS have independent balances: BisB has 450.000, ila has 250.000.
        let smsTransferOut = "Your account ending 9001 has been debited BHD 50.000 for outward transfer on 2026/10/27 15:26. Balance BHD 450.000. Tel: 17515151"
        let smsInternal = "Your account ending 0846 has been credited with BHD 50.000 via Fawri+ on 2026/10/27 15:26. Available balance BHD 250.000. Call 17123456"

        _ = await SMSImporter.importText(smsTransferOut, context: context, forceApprove: true)
        let mergedOutcome = await SMSImporter.importText(smsInternal, context: context, forceApprove: true)

        let allTxs = try context.fetch(FetchDescriptor<MoneyTransaction>())
        #expect(allTxs.count == 1)
        let singleTx = try #require(allTxs.first)
        #expect(mergedOutcome.transaction?.id == singleTx.id)
        #expect(singleTx.smsTransactionType == .internalTransfer)
        #expect(singleTx.category == .internalTransfer)
        #expect(singleTx.accountID == bisb.id)
        #expect(singleTx.toAccountID == ila.id)
        #expect(singleTx.smsBalance == 450.000)
        #expect(singleTx.smsToBalance == 250.000)
        #expect(abs(bisb.balance - 450.000) < 0.0001)
        #expect(abs(ila.balance - 250.000) < 0.0001)
        // Ensure balances are NEVER merged or summed
        #expect(bisb.balance != 700.000)
        #expect(ila.balance != 700.000)
        #expect(bisb.balance != 250.000)
        #expect(ila.balance != 450.000)

        // Case B: Reverse order (Inward Transfer arrives first with destination balance, Outward Transfer arrives second with source balance)
        let smsInternal2 = "Your account ending 0846 has been credited with BHD 30.000 via Fawri+ on 2026/10/28 18:10. Available balance BHD 280.000. Call 17123456"
        let smsTransferOut2 = "Your account ending 9001 has been debited BHD 30.000 for outward transfer on 2026/10/28 18:10. Balance BHD 420.000. Tel: 17515151"

        _ = await SMSImporter.importText(smsInternal2, context: context, forceApprove: true)
        _ = await SMSImporter.importText(smsTransferOut2, context: context, forceApprove: true)

        let allTxsAfterSecond = try context.fetch(FetchDescriptor<MoneyTransaction>())
        #expect(allTxsAfterSecond.count == 2)
        let secondTx = try #require(allTxsAfterSecond.first(where: { $0.amount == 30.000 }))
        #expect(secondTx.smsTransactionType == .internalTransfer)
        #expect(secondTx.accountID == bisb.id)
        #expect(secondTx.toAccountID == ila.id)
        #expect(secondTx.smsBalance == 420.000)
        #expect(secondTx.smsToBalance == 280.000)
        #expect(abs(bisb.balance - 420.000) < 0.0001)
        #expect(abs(ila.balance - 280.000) < 0.0001)

        // Case C: Initial balance discrepancy - each account syncs with its own SMS balance without merging
        let bbk = Account(name: "BBK Account", kind: .bank, institution: "BBK", balance: 500.000)
        bbk.smsMatch = "1111"
        let nbb = Account(name: "NBB Account", kind: .bank, institution: "NBB", balance: 190.000) // Discrepancy: should be 200 at bank
        nbb.smsMatch = "2222"
        context.insert(bbk)
        context.insert(nbb)
        try context.save()

        let bbkSMS = "Your account ending 1111 was debited BHD 50.000 on 2026/10/29 12:00 for transfer. Avl Bal BHD 450.000. Tel: 17205555"
        let nbbSMS = "Your account ending 2222 was credited BHD 50.000 on 2026/10/29 12:00. Avl Bal BHD 250.000. Tel: 17228800"

        _ = await SMSImporter.importText(bbkSMS, context: context, forceApprove: true)
        _ = await SMSImporter.importText(nbbSMS, context: context, forceApprove: true)

        let allTxsAfterThird = try context.fetch(FetchDescriptor<MoneyTransaction>())
        let thirdTx = try #require(allTxsAfterThird.first(where: { $0.accountID == bbk.id }))
        #expect(thirdTx.smsTransactionType == .internalTransfer)
        #expect(thirdTx.toAccountID == nbb.id)
        #expect(thirdTx.smsBalance == 450.000)
        #expect(thirdTx.smsToBalance == 250.000)
        #expect(abs(bbk.balance - 450.000) < 0.0001)
        #expect(abs(nbb.balance - 250.000) < 0.0001)
        #expect(thirdTx.toBalanceAdjustment == 10.000)
        #expect(thirdTx.balanceAdjustment == 0.0)

        // Case D: Same bank sends two messages (Debit alert + Fawri+ payment credited to destination IBAN)
        let smsOutwardBisB = "Your account ending 9001 has been debited BHD 20.000 for outward transfer on 2026/10/30 08:00. Balance BHD 400.000. Tel: 17515151"
        let smsFawriBisB = "Fawri+ payment BHD20.000, ref: BIB999KZUM was credited to IBAN ending 0846 on 2026/10/30 08:00. Balance BHD400.000. Tel: 17515151"

        _ = await SMSImporter.importText(smsOutwardBisB, context: context, forceApprove: true)
        _ = await SMSImporter.importText(smsFawriBisB, context: context, forceApprove: true)

        let allTxsAfterFourth = try context.fetch(FetchDescriptor<MoneyTransaction>())
        let fourthTx = try #require(allTxsAfterFourth.first(where: { $0.amount == 20.000 }))
        #expect(fourthTx.smsTransactionType == .internalTransfer)
        #expect(fourthTx.accountID == bisb.id)
        #expect(fourthTx.toAccountID == ila.id)
        #expect(fourthTx.smsBank == "BisB · ila")
        #expect(fourthTx.rawText?.contains(smsOutwardBisB) == true)
        #expect(fourthTx.rawText?.contains(smsFawriBisB) == true)
        #expect(abs(bisb.balance - 400.000) < 0.0001)
        #expect(abs(ila.balance - 300.000) < 0.0001)
    }

    @Test func testInternalTransferRecipientMatchAndSeparateBalances() async throws {
        let context = makeCleanContext()

        let bisb = Account(name: "BisB Account", kind: .bank, institution: "BisB", balance: 1000.000)
        bisb.smsMatch = "9001"
        let ila = Account(name: "ila Bank", kind: .bank, institution: "ila Bank", balance: 100.000)
        ila.smsMatch = "0846"
        context.insert(bisb)
        context.insert(ila)

        // Add a newer transaction in the future to ensure historical/merged SMS still syncs each account's SMS balance accurately
        let newerTx = MoneyTransaction(amount: 1.000, isIncome: false, merchant: "Coffee", category: .dining, date: Date().addingTimeInterval(3600), source: .manual, accountID: nil)
        newerTx.isPending = false
        context.insert(newerTx)
        try context.save()

        // 1. Single outgoing transfer SMS where recipient IBAN/account matches user's ila account (0846):
        // Must NEVER be marked as internalTransfer on its own until matched with another SMS at the same date & time!
        let sms1 = "Fawri+ Transfer of BHD 75.000 from account 9001 to IBAN BH29ILAB00000000000846 on 2026/10/25 14:15. Available Balance BHD 925.000. Tel: 17515151"
        let res1 = await SMSImporter.importText(sms1, context: context, forceApprove: true)
        let tx1 = try #require(res1.transaction)
        #expect(tx1.smsTransactionType == .expense)
        #expect(tx1.category != .internalTransfer)
        #expect(tx1.accountID == bisb.id)
        #expect(tx1.toAccountID == nil)
        #expect(tx1.smsBank == "BisB")

        // 2. Simultaneous second SMS from ila Bank (17123456) at 2026/10/25 14:15 with ila's own SMS balance (175.000):
        // Rule 6 now applies: merges into tx1, analyzes Debit (bisb.id) vs Credit (ila.id),
        // includes both banks in smsBank ("BisB · ila"), stores both SMS in rawText,
        // and updates BisB balance to 925.000 and ila balance to 175.000 separately!
        let sms2 = "Credit transaction of BHD 75.000 to account 0846 on 2026/10/25 14:15. Available balance is BHD 175.000. Call 17123456"
        _ = await SMSImporter.importText(sms2, context: context, forceApprove: true)

        let allSMS = try context.fetch(FetchDescriptor<MoneyTransaction>()).filter { $0.source == .sms }
        #expect(allSMS.count == 1)
        let merged = try #require(allSMS.first)
        #expect(merged.smsTransactionType == .internalTransfer)
        #expect(merged.category == .internalTransfer)
        #expect(merged.accountID == bisb.id)
        #expect(merged.toAccountID == ila.id)
        #expect(merged.smsBank == "BisB · ila")
        #expect(merged.rawText?.components(separatedBy: "\n\n---\n\n").count == 2)
        #expect(merged.rawText?.contains(sms1) == true)
        #expect(merged.rawText?.contains(sms2) == true)
        #expect(merged.smsBalance == 925.000)
        #expect(merged.smsToBalance == 175.000)
        #expect(abs(bisb.balance - 925.000) < 0.0001)
        #expect(abs(ila.balance - 175.000) < 0.0001)

        // 3. Reverse arrival order when Credit SMS from ila Bank arrives first and Debit SMS from BisB arrives second:
        // Analyzes both SMS to put Debit (bisb.id) as accountID and Credit (ila.id) as toAccountID,
        // includes both banks ("BisB · ila"), and updates each balance separately.
        let smsIlaFirst = "Your account 0846 credited BHD 25.000 on 2026/10/26 09:30. Available balance BHD 210.000. Call 17123456"
        let smsBisBSecond = "Fawri+ payment BHD 25.000, ref: BIB555KZUM was credited to IBAN ending 0846 on 2026/10/26 09:30. Balance BHD 890.000. Tel: 17515151"

        let resIlaFirst = await SMSImporter.importText(smsIlaFirst, context: context, forceApprove: true)
        #expect(resIlaFirst.transaction?.smsTransactionType == .income)
        _ = await SMSImporter.importText(smsBisBSecond, context: context, forceApprove: true)

        let allSMSAfterReverse = try context.fetch(FetchDescriptor<MoneyTransaction>()).filter { $0.source == .sms }
        #expect(allSMSAfterReverse.count == 2)
        let mergedReverse = try #require(allSMSAfterReverse.first(where: { $0.amount == 25.000 }))
        #expect(mergedReverse.smsTransactionType == .internalTransfer)
        #expect(mergedReverse.accountID == bisb.id)
        #expect(mergedReverse.toAccountID == ila.id)
        #expect(mergedReverse.smsBank == "BisB · ila")
        #expect(mergedReverse.rawText?.components(separatedBy: "\n\n---\n\n").count == 2)
        #expect(mergedReverse.smsBalance == 890.000)
        #expect(mergedReverse.smsToBalance == 210.000)
        #expect(abs(bisb.balance - 890.000) < 0.0001)
        #expect(abs(ila.balance - 210.000) < 0.0001)
    }

    @Test func testAccountDoesNotHaveToMatchSMSSenderBank() async throws {
        let context = makeCleanContext()

        let bisb = Account(name: "BisB Account", kind: .bank, institution: "BisB", balance: 500.000)
        let ila = Account(name: "ila Bank", kind: .bank, institution: "ila", balance: 300.000)
        context.insert(bisb)
        context.insert(ila)
        try context.save()

        // 1. Explicitly providing an account different from the SMS sender bank:
        // Rule 'Account Must Always Match SMS sender bank' is REMOVED.
        // Even though SMS is from BisB (Tel: 17515151), assigning to ila account preserves ila.id!
        let bisbSMS = "Your card ending 4411 was used for BHD 10.000 at STARBUCKS on 2026/10/28 09:15. Tel: 17515151"
        let outcome = await SMSImporter.importText(bisbSMS, context: context, forceApprove: true, accountID: ila.id)
        let tx = try #require(outcome.transaction)

        #expect(tx.accountID == ila.id)
        #expect(tx.smsBank == "BisB")
        #expect(abs(ila.balance - 290.000) < 0.0001)
        #expect(abs(bisb.balance - 500.000) < 0.0001)
    }

    @Test func testCreditCardIdentifiedCorrectlyFromCardDigitsOrFullCardNumber() async throws {
        let context = makeCleanContext()

        let bisbChecking = Account(name: "BisB Checking", kind: .bank, institution: "BisB", balance: 500.000)
        let visaCard = Account(name: "Visa Platinum", kind: .creditCard, institution: "BisB", balance: 50.000)
        visaCard.smsMatch = "4821" // Last 4 digits

        let mcCard = Account(name: "Mastercard Black", kind: .creditCard, institution: "ila", balance: 0.000)
        mcCard.smsMatch = "5412123456789988" // Full 16-digit card number configured in setup

        context.insert(bisbChecking)
        context.insert(visaCard)
        context.insert(mcCard)
        try context.save()

        // 1. Transaction with card ending 4821 from BisB sender
        // MUST identify Visa Platinum (creditCard), NOT the BisB Checking account!
        let sms1 = "Purchase of BHD 15.000 with Card ending 4821 at Costa Coffee on 2026/10/28 10:00. Tel: 17515151"
        let outcome1 = await SMSImporter.importText(sms1, context: context, forceApprove: true)
        let tx1 = try #require(outcome1.transaction)

        #expect(tx1.accountID == visaCard.id)
        #expect(abs(visaCard.balance - 65.000) < 0.0001) // Liability increased by 15 BHD
        #expect(abs(bisbChecking.balance - 500.000) < 0.0001) // Checking unchanged

        // 2. Transaction matching full 16-digit card setup when SMS only mentions ending 9988
        let sms2 = "Your Credit Card ending 9988 was used for BHD 40.000 at Alosra Supermarket on 2026/10/28 11:30"
        let outcome2 = await SMSImporter.importText(sms2, context: context, forceApprove: true)
        let tx2 = try #require(outcome2.transaction)

        #expect(tx2.accountID == mcCard.id)
        #expect(abs(mcCard.balance - 40.000) < 0.0001)

        // 3. Masked card number format in SMS
        let sms3 = "Purchase of BHD 22.000 with Card No: 4532XXXXXXXX4821 at Carrefour on 2026/10/28 12:00"
        let outcome3 = await SMSImporter.importText(sms3, context: context, forceApprove: true)
        let tx3 = try #require(outcome3.transaction)

        #expect(tx3.accountID == visaCard.id)
        #expect(abs(visaCard.balance - 87.000) < 0.0001)
    }

    @Test func testConditionsNotSavedAutomaticallyAndCanBeSavedManually() async throws {
        let context = makeCleanContext()
        SMSUserRules.clearAll()
        #expect(SMSUserRules.totalConditionsCount() == 0)

        let acc1 = Account(name: "Main Account", kind: .bank, institution: "BisB", balance: 500.000)
        let acc2 = Account(name: "Shopping Account", kind: .bank, institution: "BisB", balance: 300.000)
        context.insert(acc1)
        context.insert(acc2)
        try context.save()

        // 1. Import transaction
        let sms = "Debit: BHD 18.000 spent at Novelty Store on 2026/10/28 14:00. Tel: 17515151"
        let outcome = await SMSImporter.importText(sms, context: context, forceApprove: true)
        let tx = try #require(outcome.transaction)

        // 2. Perform various edits like the user would in TransactionDetailView
        Ledger.edit(tx, context: context) { target in
            target.merchant = "Specialty Books"
            target.category = .education
            target.accountID = acc2.id
            target.amount = 20.000
        }
        _ = Ledger.approve(tx, context: context)

        // Verify conditions were NOT saved automatically!
        #expect(SMSUserRules.totalConditionsCount() == 0)

        // 3. User explicitly taps "Save condition for future" (calling rememberTransactionRule)
        SMSUserRules.rememberTransactionRule(for: tx)
        #expect(SMSUserRules.totalConditionsCount() > 0)

        // 4. Future matching SMS from the same bank & counterparty now automatically gets the saved condition
        let nextSMS = "Debit: BHD 18.000 spent at Novelty Store on 2026/10/29 15:00. Tel: 17515151"
        let nextOutcome = await SMSImporter.importText(nextSMS, context: context, forceApprove: true)
        let nextTx = try #require(nextOutcome.transaction)

        #expect(nextTx.category == .education)
        #expect(nextTx.accountID == acc2.id)
        #expect(nextTx.merchant == "Specialty Books")
    }
}
