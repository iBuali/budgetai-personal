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
        TransactionRuleStore.shared.clearAll()
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
        TransactionRuleStore.shared.clearAll()
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
        TransactionRuleStore.shared.clearAll()
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
            context: context
        )
        tx1.merchant = "Gym Membership"
        Ledger.edit(tx1, context: context) { target in
            target.accountID = bbk.id
            target.amount = 12.500 // Also test editing transaction amount
        }

        // User creates a rule from tx1 matching sender "88990" AND accountDigits "7711"
        let rule = TransactionRule(
            name: "Gym Membership Rule",
            logic: .and,
            conditions: [
                RuleCondition(field: .smsSender, value: "88990", displayValue: "88990"),
                RuleCondition(field: .accountDigits, value: "7711", displayValue: "Ending 7711")
            ],
            actions: RuleActions(
                categoryRaw: SpendCategory.health.rawValue,
                fromAccountID: bbk.id,
                setMerchant: "Gym Membership",
                setBank: "Al Salam",
                setIsIncome: false
            ),
            sourceTransactionID: tx1.id
        )
        _ = TransactionRuleStore.shared.addRule(rule)

        #expect(tx1.isPending == false)
        #expect(tx1.smsTransactionType == .expense)
        #expect(tx1.smsBank == "Al Salam")
        #expect(tx1.merchant == "Gym Membership")
        #expect(tx1.category == .health)
        #expect(tx1.accountID == bbk.id)
        #expect(abs(nbb.balance - 500.000) < 0.0001) // Reversed from NBB when moved to BBK
        #expect(abs(bbk.balance - 187.500) < 0.0001) // Deducted edited amount 12.500 from BBK

        // 3. Future message from the same sender "88990" with same counterparty *7711 automatically applies the rule!
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

        // 4. Unrelated message with a different counterparty/structure is NOT affected by the rule
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

        let transferDebitSMS = "Your account ending 9901 has been debited BHD 25.000 for outward transfer Ref: TRF20261028A on 2026/10/28 12:00. Balance BHD 475.000. Tel: 17515151"
        let transferCreditSMS = "Your account ending 0846 has been credited with BHD 25.000 via Fawri+ Ref: TRF20261028A on 2026/10/28 12:00. Available balance BHD 125.000. Call 17123456"

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
        let investment = Account(name: "Portfolio", kind: .investment, institution: "SICO", balance: 250.000, includeInNetWorth: true)
        let carLoan = Account(name: "Car Loan", kind: .loan, institution: "BBK", balance: 150.000, includeInNetWorth: false)

        let finance = Finance(transactions: [], accounts: [checking, hiddenSavings, investment, carLoan])
        // Liquid balance (Cash & bank) still counts all liquid cash & bank accounts (400 + 600 = 1000)
        #expect(abs(finance.liquidBalance - 1000.000) < 0.0001)
        // Net worth and Safe to Spend spendable balance are linked to Assets with includeInNetWorth == true (400 + 250 = 650)
        #expect(abs(finance.totalAssets - 650.000) < 0.0001)
        #expect(abs(finance.safeToSpend.spendable - 650.000) < 0.0001)
        #expect(abs(finance.totalLiabilities - 0.000) < 0.0001)
        #expect(abs(finance.netWorth - 650.000) < 0.0001)

        // Including hiddenSavings in net worth updates Safe to Spend spendable balance (650 + 600 = 1250)
        hiddenSavings.includeInNetWorth = true
        let financeIncluded = Finance(transactions: [], accounts: [checking, hiddenSavings, investment, carLoan])
        #expect(abs(financeIncluded.totalAssets - 1250.000) < 0.0001)
        #expect(abs(financeIncluded.safeToSpend.spendable - 1250.000) < 0.0001)
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

    @Test func transactionRulesManagementAndClearAll() throws {
        TransactionRuleStore.shared.clearAll()
        #expect(TransactionRuleStore.shared.rules.isEmpty)

        // 1. Add a transaction rule
        let rule = TransactionRule(
            name: "Cafeteria Rule",
            logic: .and,
            conditions: [
                RuleCondition(field: .merchant, value: "Cafeteria", displayValue: "Cafeteria"),
                RuleCondition(field: .smsSender, value: "17515151", displayValue: "17515151")
            ],
            actions: RuleActions(
                categoryRaw: SpendCategory.dining.rawValue,
                setMerchant: "Cafeteria",
                setBank: "BisB",
                setIsIncome: false
            )
        )
        let savedRule = TransactionRuleStore.shared.addRule(rule)
        #expect(savedRule.id == rule.id)
        #expect(TransactionRuleStore.shared.rules.count == 1)

        let saved = try #require(TransactionRuleStore.shared.rules.first)
        #expect(saved.actions.setMerchant == "Cafeteria")
        #expect(saved.actions.category == .dining)
        #expect(saved.actions.setIsIncome == false)

        // 2. Delete single rule
        TransactionRuleStore.shared.deleteRule(id: saved.id)
        #expect(TransactionRuleStore.shared.rules.isEmpty)

        // 3. Clear all rules
        _ = TransactionRuleStore.shared.addRule(rule)
        #expect(TransactionRuleStore.shared.rules.count == 1)
        TransactionRuleStore.shared.clearAll()
        #expect(TransactionRuleStore.shared.rules.isEmpty)
    }

    @Test func multipleAccountsByBankPhoneReferenceAndSenderRecognition() async throws {
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

        // 3. SMS with reference code prefix (e.g. ILAB2610289911) recognizes sender bank as ila even without phone or bank name
        let refOnlySMS = "Purchase of BHD 5.000 at COSTA COFFEE on 2026/10/28 11:00. Ref: ILAB2610289911"
        let out3 = await SMSImporter.importText(refOnlySMS, context: context, forceApprove: true, sender: nil)
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

        // Case A: First SMS is Transfer Out from BisB, Second SMS at same date & time with same Ref is Transfer In to ila Bank.
        // Both SMS have independent balances: BisB has 450.000, ila has 250.000.
        let smsTransferOut = "Your account ending 9001 has been debited BHD 50.000 for outward transfer Ref: REF1027A on 2026/10/27 15:26. Balance BHD 450.000. Tel: 17515151"
        let smsInternal = "Your account ending 0846 has been credited with BHD 50.000 via Fawri+ Ref: REF1027A on 2026/10/27 15:26. Available balance BHD 250.000. Call 17123456"

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
        let smsInternal2 = "Your account ending 0846 has been credited with BHD 30.000 via Fawri+ Ref: REF1028B on 2026/10/28 18:10. Available balance BHD 280.000. Call 17123456"
        let smsTransferOut2 = "Your account ending 9001 has been debited BHD 30.000 for outward transfer Ref: REF1028B on 2026/10/28 18:10. Balance BHD 420.000. Tel: 17515151"

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

        let bbkSMS = "Your account ending 1111 was debited BHD 50.000 on 2026/10/29 12:00 for transfer Ref: REF1029C. Avl Bal BHD 450.000. Tel: 17205555"
        let nbbSMS = "Your account ending 2222 was credited BHD 50.000 on 2026/10/29 12:00 Ref: REF1029C. Avl Bal BHD 250.000. Tel: 17228800"

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

        // Case D: Different configured account (ila) receives credit with same ref, amount, date & time
        let smsOutwardBisB = "Your account ending 9001 has been debited BHD 20.000 for outward transfer Ref: BIB999KZUM on 2026/10/30 08:00. Balance BHD 400.000. Tel: 17515151"
        let smsFawriBisB = "Your account ending 0846 has been credited with BHD 20.000 via Fawri+ Ref: BIB999KZUM on 2026/10/30 08:00. Available balance BHD 300.000. Call 17123456"

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
        let sms1 = "Fawri+ Transfer of BHD 75.000 from account 9001 to IBAN BH29ILAB00000000000846 Ref: REF1025X on 2026/10/25 14:15. Available Balance BHD 925.000. Tel: 17515151"
        let res1 = await SMSImporter.importText(sms1, context: context, forceApprove: true)
        let tx1 = try #require(res1.transaction)
        #expect(tx1.smsTransactionType == .expense)
        #expect(tx1.category != .internalTransfer)
        #expect(tx1.accountID == bisb.id)
        #expect(tx1.toAccountID == nil)
        #expect(tx1.smsBank == "BisB")

        // 2. Simultaneous second SMS from ila Bank (17123456) at 2026/10/25 14:15 with same Ref and ila's own SMS balance (175.000):
        let sms2 = "Credit transaction of BHD 75.000 to account 0846 Ref: REF1025X on 2026/10/25 14:15. Available balance is BHD 175.000. Call 17123456"
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
        let smsIlaFirst = "Your account 0846 credited BHD 25.000 Ref: BIB555KZUM on 2026/10/26 09:30. Available balance BHD 210.000. Call 17123456"
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

    @Test func testRulesNotCreatedAutomaticallyAndApplyOnlyToFutureTransactions() async throws {
        let context = makeCleanContext()
        TransactionRuleStore.shared.clearAll()
        #expect(TransactionRuleStore.shared.rules.isEmpty)

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

        // Verify rules were NOT created automatically!
        #expect(TransactionRuleStore.shared.rules.isEmpty)

        // 3. User explicitly creates a Transaction Rule with user approval
        let rule = TransactionRule(
            name: "Specialty Books Rule",
            logic: .and,
            conditions: [
                RuleCondition(field: .merchant, value: "Novelty Store", displayValue: "Novelty Store"),
                RuleCondition(field: .bank, value: "BisB", displayValue: "BisB")
            ],
            actions: RuleActions(
                categoryRaw: SpendCategory.education.rawValue,
                fromAccountID: acc2.id,
                setMerchant: "Specialty Books",
                setIsIncome: false
            ),
            sourceTransactionID: tx.id
        )
        _ = TransactionRuleStore.shared.addRule(rule)
        #expect(TransactionRuleStore.shared.rules.count == 1)

        // 4. Future matching SMS from the same bank & merchant now automatically gets the saved rule
        let nextSMS = "Debit: BHD 18.000 spent at Novelty Store on 2026/10/29 15:00. Tel: 17515151"
        let nextOutcome = await SMSImporter.importText(nextSMS, context: context, forceApprove: true)
        let nextTx = try #require(nextOutcome.transaction)

        #expect(nextTx.category == .education)
        #expect(nextTx.accountID == acc2.id)
        #expect(nextTx.merchant == "Specialty Books")
    }

    @Test func testUncertainCategorizationDoesNotQuarantine() async throws {
        let context = makeCleanContext()
        let acc = Account(name: "Main Account", kind: .bank, institution: "BisB", balance: 500.000)
        context.insert(acc)
        try context.save()

        // Merchant with uncertain category (e.g. unknown vendor)
        let sms = "Debit: BHD 12.500 spent at UnknownVendorXYZ on 2026/10/28 14:00. Tel: 17515151"
        let outcome = await SMSImporter.importText(sms, context: context, forceApprove: true)
        let tx = try #require(outcome.transaction)

        // It should NOT be quarantined on the waiting for review list because of uncertain categorization
        #expect(tx.isPending == false)
        #expect(tx.category == .other)
        let reasons = tx.reviewReasons(accounts: [acc])
        #expect(!reasons.contains("Uncertain categorization"))
    }

    @Test func testTransactionRuleWithoutBankConditionAppliesAcrossBanks() async throws {
        let context = makeCleanContext()
        TransactionRuleStore.shared.clearAll()

        let acc = Account(name: "Daily Account", kind: .bank, institution: "BisB", balance: 500.000)
        context.insert(acc)
        try context.save()

        // 1. Initial SMS from BisB
        let sms1 = "Debit: BHD 15.000 spent at Coffee Corner on 2026/10/28 10:00. Tel: 17515151"
        let outcome1 = await SMSImporter.importText(sms1, context: context, forceApprove: true)
        let tx1 = try #require(outcome1.transaction)

        // 2. User creates a rule matching ONLY merchant ("Coffee Corner"), without selecting Bank
        let captured = TransactionRuleStore.captureAvailableConditions(from: tx1, accounts: [acc])
        let merchantCondition = try #require(captured.first(where: { $0.field == .merchant }))
        let rule = TransactionRule(
            name: "Coffee Corner Rule",
            logic: .and,
            conditions: [merchantCondition],
            actions: RuleActions(
                categoryRaw: SpendCategory.dining.rawValue,
                setMerchant: "Specialty Coffee"
            ),
            sourceTransactionID: tx1.id
        )
        _ = TransactionRuleStore.shared.addRule(rule)
        #expect(TransactionRuleStore.shared.rules.count == 1)

        // Existing tx1 was NOT modified automatically when creating the rule
        #expect(tx1.merchant == "Coffee Corner")

        // 3. Receive similar transaction from a DIFFERENT sender/bank (e.g. ila Bank)
        let sms2 = "Debit: BHD 15.000 spent at Coffee Corner on 2026/10/29 11:00. Tel: 17123456"
        let outcome2 = await SMSImporter.importText(sms2, context: context, forceApprove: true)
        let tx2 = try #require(outcome2.transaction)

        // Should apply the saved rule even though the SMS sender bank was different
        #expect(tx2.category == .dining)
        #expect(tx2.merchant == "Specialty Coffee")
    }

    @Test func testAllFilterMatchesPendingTransactions() async throws {
        let context = makeCleanContext()
        let acc = Account(name: "Test Bank", kind: .bank, balance: 100)
        context.insert(acc)
        try context.save()

        let pendingTx = MoneyTransaction(amount: 50, isIncome: false, merchant: "Pending Store", category: .other, date: .now, source: .sms, accountID: acc.id)
        pendingTx.isPending = true
        context.insert(pendingTx)

        let approvedTx = MoneyTransaction(amount: 30, isIncome: false, merchant: "Approved Store", category: .dining, date: .now, source: .manual, accountID: acc.id)
        approvedTx.isPending = false
        context.insert(approvedTx)
        try context.save()

        var allFilter = TxFilterState()
        allFilter.kind = .all

        // TxFilterState.matches returns true for both pending and approved on .all
        #expect(allFilter.matches(pendingTx))
        #expect(allFilter.matches(approvedTx))

        var reviewFilter = TxFilterState()
        reviewFilter.kind = .review
        #expect(reviewFilter.matches(pendingTx))
        #expect(!reviewFilter.matches(approvedTx))

        // Duplicate transactions must also appear in the Needs Review filter tab
        let duplicateTx = MoneyTransaction(amount: 25, isIncome: false, merchant: "Duplicate Store", category: .shopping, date: .now, source: .sms, accountID: acc.id)
        duplicateTx.isPending = false
        duplicateTx.isPossibleDuplicate = true
        context.insert(duplicateTx)
        #expect(reviewFilter.matches(duplicateTx))

        // Home page redirect helper sets tab to .transactions and requestedTransactionsFilter to .review
        let state = AppState()
        state.openTransactions(filter: .review)
        #expect(state.tab == .transactions)
        #expect(state.requestedTransactionsFilter == .review)
    }

    @Test func testAlSalamMaskedIBANTowardsEWABNotAssignedToIlaBank() async throws {
        let context = makeCleanContext()
        TransactionRuleStore.shared.clearAll()

        // User has ila Bank (first account) and BisB, but NO Al Salam Bank account
        let ila = Account(name: "ila Bank", kind: .bank, institution: "ila", balance: 300.000)
        ila.smsMatch = "0846"
        let bisb = Account(name: "BisB Account", kind: .bank, institution: "BisB", balance: 500.000)
        bisb.smsMatch = "9001"
        context.insert(ila)
        context.insert(bisb)
        try context.save()

        let alSalamSMS = "Dear Client, BHD 18.600 has been debited from your account BH69ALSA00219XXXXX0020 towards EWAB, your balance is BHD 5081.229 on 22/04/26 at 03:46. Thank you, Al Salam Bank"

        let outcome = await SMSImporter.importText(alSalamSMS, context: context, forceApprove: true)
        let tx = try #require(outcome.transaction)

        // 1. Bank must be identified as Al Salam (from BH69ALSA... and "Al Salam Bank"), NEVER ila!
        #expect(tx.smsBank == "Al Salam")
        #expect(tx.smsBank != "ila")

        // 2. Account suffix must be extracted as "0020" (trailing 4 digits of masked IBAN), NEVER "00219"
        #expect(tx.smsAccountSuffix == "0020")

        // 3. Merchant extracted from "towards EWAB" -> "EWAB", categorized as .bills
        #expect(tx.merchant == "EWAB")
        #expect(tx.category == .bills)
        #expect(abs(tx.amount - 18.600) < 0.0001)
        #expect(abs((tx.smsBalance ?? 0) - 5081.229) < 0.0001)

        // 4. Since user has no Al Salam / 0020 account, accountID MUST be nil (Unknown) and transaction MUST be quarantined (isPending = true)
        #expect(tx.accountID == nil)
        #expect(tx.isPending == true)

        // 5. ila Bank and BisB balances must remain 100% untouched!
        #expect(abs(ila.balance - 300.000) < 0.0001)
        #expect(abs(bisb.balance - 500.000) < 0.0001)

        let reasons = tx.reviewReasons(accounts: [ila, bisb])
        #expect(reasons.contains("Unmatched account"))
    }

    @Test func testEditedAccountCardOrAccountDigitsRecognizedAcrossAllSMSTypes() async throws {
        let context = makeCleanContext()
        TransactionRuleStore.shared.clearAll()

        // User creates an account (even without setting institution) and edits it to put "3876" in "Card or account digits in SMS"
        let myAccount = Account(name: "Personal Account", kind: .bank, institution: "", balance: 173.613)
        myAccount.smsMatch = "3876"
        let otherAccount = Account(name: "Other Account", kind: .bank, institution: "ila", balance: 500.000)
        otherAccount.smsMatch = "9999"
        context.insert(myAccount)
        context.insert(otherAccount)
        try context.save()

        // 1. Exact user-reported SMS:
        // "Fawri+ payment BHD5.000 received from IBAN 0001 to IBAN 3876 ref. ALS103KAU005SVOW on 2026/11/06 17:46. Balance BHD178.613. Tel 17515151"
        let incomingFawriSMS = "Fawri+ payment BHD5.000 received from IBAN 0001 to IBAN 3876 ref. ALS103KAU005SVOW on 2026/11/06 17:46. Balance BHD178.613. Tel 17515151"
        let parsed = try #require(SMSParser.parse(incomingFawriSMS, context: context))

        #expect(parsed.transactionType == .transferIn)
        #expect(parsed.isIncome == true)
        #expect(parsed.accountSuffix == "3876")
        #expect(parsed.recipientSuffix == "0001")
        #expect(parsed.referenceNumber == "ALS103KAU005SVOW")
        #expect(parsed.accountID == myAccount.id)

        let out1 = await SMSImporter.importText(incomingFawriSMS, context: context, forceApprove: true)
        let tx1 = try #require(out1.transaction)
        #expect(tx1.accountID == myAccount.id)
        #expect(tx1.isPending == false)
        #expect(tx1.isIncome == true)
        #expect(tx1.smsAccountSuffix == "3876")
        #expect(tx1.smsRecipientSuffix == "0001")
        #expect(tx1.smsReference == "ALS103KAU005SVOW")
        #expect(abs(myAccount.balance - 178.613) < 0.0001)
        #expect(tx1.reviewReasons(accounts: [myAccount, otherAccount]).isEmpty)

        // 2. User edits account to hold both IBAN digits and Debit Card digits ("3876, 4821")
        myAccount.smsMatch = "3876, 4821"
        try context.save()

        // Card purchase using card ending 4821
        let cardSMS = "Purchase of BHD 8.613 with Debit Card *4821 at LULU HYPERMARKET on 2026/11/06 18:10. Balance BHD 170.000"
        let out2 = await SMSImporter.importText(cardSMS, context: context, forceApprove: true)
        let tx2 = try #require(out2.transaction)
        #expect(tx2.accountID == myAccount.id)
        #expect(tx2.isPending == false)
        #expect(tx2.smsAccountSuffix == "4821")
        #expect(abs(myAccount.balance - 170.000) < 0.0001)

        // 3. Outgoing Fawri+ transfer from IBAN 3876 to IBAN 5544
        let outgoingFawriSMS = "Fawri+ transfer of BHD 20.000 from IBAN 3876 to IBAN 5544 ref. BIB20269988 on 2026/11/06 19:00. Balance BHD 150.000"
        let out3 = await SMSImporter.importText(outgoingFawriSMS, context: context, forceApprove: true)
        let tx3 = try #require(out3.transaction)
        #expect(tx3.accountID == myAccount.id)
        #expect(tx3.isPending == false)
        #expect(tx3.smsAccountSuffix == "3876")
        #expect(tx3.smsRecipientSuffix == "5544")
        #expect(abs(myAccount.balance - 150.000) < 0.0001)

        // 4. Arabic SMS mentioning account 3876
        let arabicSMS = "تم خصم مبلغ 10.000 د.ب من حساب 3876 لدى بتلكو. الرصيد المتاح 140.000 د.ب"
        let out4 = await SMSImporter.importText(arabicSMS, context: context, forceApprove: true)
        let tx4 = try #require(out4.transaction)
        #expect(tx4.accountID == myAccount.id)
        #expect(tx4.isPending == false)
        #expect(tx4.smsAccountSuffix == "3876")
        #expect(abs(myAccount.balance - 140.000) < 0.0001)
    }

    @Test func testSameReferenceSameDateTimeSameAccountMergesHighestAmountAndLowestBalance() async throws {
        let context = makeCleanContext()
        TransactionRuleStore.shared.clearAll()

        let ilaAccount = Account(name: "ila Bank", kind: .bank, institution: "ila", balance: 5392.174)
        ilaAccount.smsMatch = "1101"
        context.insert(ilaAccount)
        try context.save()

        let sms1 = "An amount of BHD 170.110 inc VAT has been debited from your IBAN ending 1101 on 07/11/2026 11:26 for Outgoing Charges on Fawri+ Ref: ABCO261107054458 Balance BHD 5,392.064"
        let sms2 = "Success! Fawri+ transfer of BHD 170.000 to IBAN **0020 is completed on 07/11/2026 11:26 Ref ABCO261107054458 Balance BHD 5,222.064 Enquiry 17123456"

        // Order A: sms1 (170.110, Bal 5,392.064) arrives first, sms2 (170.000, Bal 5,222.064) arrives second
        _ = await SMSImporter.importText(sms1, context: context, forceApprove: true)
        let mergedOut = await SMSImporter.importText(sms2, context: context, forceApprove: true)

        let allTxs = try context.fetch(FetchDescriptor<MoneyTransaction>())
        #expect(allTxs.count == 1)
        let tx = try #require(mergedOut.transaction)
        #expect(tx.accountID == ilaAccount.id)
        #expect(abs(tx.amount - 170.110) < 0.0001) // Highest debited/transfer amount
        #expect(abs((tx.smsBalance ?? 0) - 5222.064) < 0.0001) // Lowest balance amount
        #expect(abs(ilaAccount.balance - 5222.064) < 0.0001)
        #expect(tx.smsReference == "ABCO261107054458")
        #expect(tx.smsAccountSuffix == "1101")
        #expect(tx.smsRecipientSuffix == "0020")
        #expect(tx.merchant == "IBAN ending 0020")
        #expect(tx.smsBank == "ila")
        #expect(tx.isPending == false)
        #expect(tx.isPossibleDuplicate == false)

        // Order B: Reverse order (sms2 with 170.000 arrives first, sms1 with 170.110 arrives second)
        let sms2Reverse = "Success! Fawri+ transfer of BHD 170.000 to IBAN **0020 is completed on 07/11/2026 12:30 Ref ABCO261107099999 Balance BHD 5,051.954 Enquiry 17123456"
        let sms1Reverse = "An amount of BHD 170.110 inc VAT has been debited from your IBAN ending 1101 on 07/11/2026 12:30 for Outgoing Charges on Fawri+ Ref: ABCO261107099999 Balance BHD 5,221.954"

        _ = await SMSImporter.importText(sms2Reverse, context: context, forceApprove: true)
        let mergedReverseOut = await SMSImporter.importText(sms1Reverse, context: context, forceApprove: true)

        let allTxsAfterReverse = try context.fetch(FetchDescriptor<MoneyTransaction>())
        #expect(allTxsAfterReverse.count == 2)
        let txReverse = try #require(mergedReverseOut.transaction)
        #expect(txReverse.accountID == ilaAccount.id)
        #expect(abs(txReverse.amount - 170.110) < 0.0001) // Highest debited/transfer amount
        #expect(abs((txReverse.smsBalance ?? 0) - 5051.954) < 0.0001) // Lowest balance amount
        #expect(abs(ilaAccount.balance - 5051.954) < 0.0001)
        #expect(txReverse.smsReference == "ABCO261107099999")
        #expect(txReverse.smsAccountSuffix == "1101")
        #expect(txReverse.smsRecipientSuffix == "0020")
        #expect(txReverse.merchant == "IBAN ending 0020")

        // Order C: Pasting both SMS messages together separated by a single newline (without blank lines)
        let smsBatch1 = "An amount of BHD 170.110 inc VAT has been debited from your IBAN ending 1101 on 07/11/2026 14:15 for Outgoing Charges on Fawri+ Ref: ABCO261107077777 Balance BHD 4,881.844"
        let smsBatch2 = "Success! Fawri+ transfer of BHD 170.000 to IBAN **0020 is completed on 07/11/2026 14:15 Ref ABCO261107077777 Balance BHD 4,711.844 Enquiry 17123456"
        let combinedPaste = "\(smsBatch1)\n\(smsBatch2)"
        #expect(SMSParser.splitBatch(combinedPaste).count == 2)

        let batchOutcome = await SMSImporter.importText(combinedPaste, context: context, forceApprove: true)
        #expect(batchOutcome.batchTransactions.count == 1)
        #expect(batchOutcome.flaggedDuplicate == false)
        let txBatch = try #require(batchOutcome.transaction)
        #expect(abs(txBatch.amount - 170.110) < 0.0001)
        #expect(abs((txBatch.smsBalance ?? 0) - 4711.844) < 0.0001)
        #expect(abs(ilaAccount.balance - 4711.844) < 0.0001)
    }

    @Test func testDuplicateConditionStrictlyByReferenceCodeOnly() async throws {
        let context = makeCleanContext()
        let acc = Account(name: "Main Bank", kind: .bank, institution: "BisB", balance: 1000.000)
        acc.smsMatch = "1234"
        context.insert(acc)
        try context.save()

        // 1. Two SMS with identical amount, balance, merchant, and date/time but NO reference code -> NOT duplicates!
        let noRefSMS = "Your BisB card ending 1234 was used for BHD 15.000 at STARBUCKS on 2026/11/07 10:00. Avl Bal BHD 985.000. Tel 17515151"
        let out1 = await SMSImporter.importText(noRefSMS, context: context, forceApprove: true)
        let out2 = await SMSImporter.importText(noRefSMS, context: context, forceApprove: true)
        #expect(out1.flaggedDuplicate == false)
        #expect(out2.flaggedDuplicate == false)
        #expect(out1.transaction?.isPossibleDuplicate == false)
        #expect(out2.transaction?.isPossibleDuplicate == false)

        // 2. Two SMS with the SAME reference code on different days (so not same-time merged) -> Flagged as duplicate!
        let refSMS1 = "BisB: Purchase of BHD 20.000 at CARREFOUR on 2026/11/05 09:00. Ref: DUPREF998877. Avl Bal BHD 965.000. Tel 17515151"
        let refSMS2 = "BisB: Purchase of BHD 35.000 at DIFFERENT SHOP on 2026/11/07 18:00. Ref: DUPREF998877. Avl Bal BHD 930.000. Tel 17515151"
        let refOut1 = await SMSImporter.importText(refSMS1, context: context, forceApprove: true)
        let refOut2 = await SMSImporter.importText(refSMS2, context: context, forceApprove: true)
        #expect(refOut1.flaggedDuplicate == false)
        #expect(refOut2.flaggedDuplicate == true)
        #expect(refOut2.transaction?.isPossibleDuplicate == true)
    }

    // MARK: - 14. New Transaction Rules System, Bank Recognition (Sender/Ref/Phone), and Location Capture Tests

    @Test func testNewTransactionRulesPriorityAndOrConditionsAndInternalExternalTransfers() async throws {
        let context = makeCleanContext()
        TransactionRuleStore.shared.clearAll()

        let bisb = Account(name: "BisB Account", kind: .bank, institution: "BisB", balance: 1000.000)
        bisb.smsMatch = "9001"
        let ila = Account(name: "ila Account", kind: .bank, institution: "ila", balance: 200.000)
        ila.smsMatch = "0846"
        context.insert(bisb)
        context.insert(ila)
        try context.save()

        // 1. Import a sample Fawri+ transfer transaction
        let sampleSMS = "Fawri+ payment BHD 40.000, ref: BIB103KAK999111 was credited to IBAN ending 0846 on 2026/11/01 10:00. Balance BHD 960.000. Tel: 17515151"
        let sampleOut = await SMSImporter.importText(sampleSMS, context: context, forceApprove: true)
        let sampleTx = try #require(sampleOut.transaction)
        #expect(sampleTx.smsTransactionType == .expense)
        #expect(sampleTx.toAccountID == nil)

        // 2. Capture available fields from the selected transaction
        let captured = TransactionRuleStore.captureAvailableConditions(from: sampleTx, accounts: [bisb, ila])
        #expect(captured.contains(where: { $0.field == .recipientIBAN && $0.value == "0846" }))
        #expect(captured.contains(where: { $0.field == .bank && $0.value == "BisB" }))
        #expect(captured.contains(where: { $0.field == .smsSender && $0.value == "17515151" }))

        // 3. Create Rule 1 (External Transfer to IBAN 0846) and Rule 2 (Internal Transfer from BisB to ila)
        let ruleExternal = TransactionRule(
            name: "External Transfer 0846",
            logic: .and,
            conditions: [
                RuleCondition(field: .recipientIBAN, value: "0846", displayValue: "IBAN / Account ending 0846")
            ],
            actions: RuleActions(
                categoryRaw: SpendCategory.transfers.rawValue,
                transferKind: .externalTransfer,
                fromAccountID: bisb.id,
                setMerchant: "External Recipient 0846"
            ),
            sourceTransactionID: sampleTx.id
        )
        let ruleInternal = TransactionRule(
            name: "Internal Transfer BisB to ila",
            logic: .and,
            conditions: [
                RuleCondition(field: .recipientIBAN, value: "0846", displayValue: "IBAN / Account ending 0846"),
                RuleCondition(field: .bank, value: "BisB", displayValue: "BisB")
            ],
            actions: RuleActions(
                categoryRaw: SpendCategory.internalTransfer.rawValue,
                transferKind: .internalTransfer,
                fromAccountID: bisb.id,
                toAccountID: ila.id
            ),
            sourceTransactionID: sampleTx.id
        )

        _ = TransactionRuleStore.shared.addRule(ruleExternal)
        _ = TransactionRuleStore.shared.addRule(ruleInternal)
        #expect(TransactionRuleStore.shared.rules.count == 2)
        #expect(TransactionRuleStore.shared.priorityNumber(for: ruleExternal.id) == 1) // Rule 1
        #expect(TransactionRuleStore.shared.priorityNumber(for: ruleInternal.id) == 2) // Rule 2

        // Existing sampleTx must NOT be altered when rules are created
        #expect(sampleTx.merchant != "External Recipient 0846")

        // 4. Since Rule 1 has higher priority than Rule 2, a matching future SMS uses Rule 1
        let futureSMS1 = "Fawri+ payment BHD 25.000, ref: BIB103KAK999222 was credited to IBAN ending 0846 on 2026/11/02 12:00. Balance BHD 935.000. Tel: 17515151"
        let outFuture1 = await SMSImporter.importText(futureSMS1, context: context, forceApprove: true)
        let txFuture1 = try #require(outFuture1.transaction)
        #expect(txFuture1.merchant == "External Recipient 0846")
        #expect(txFuture1.category == .transfers)
        #expect(txFuture1.toAccountID == nil)

        // 5. Reorder rules so Rule 2 (Internal Transfer) becomes Rule 1 (highest priority)
        TransactionRuleStore.shared.moveRules(from: IndexSet(integer: 1), to: 0)
        #expect(TransactionRuleStore.shared.priorityNumber(for: ruleInternal.id) == 1)
        #expect(TransactionRuleStore.shared.priorityNumber(for: ruleExternal.id) == 2)

        // Now a future SMS to IBAN 0846 from BisB matches the new Rule 1 (Internal Transfer from BisB -> ila)
        let futureSMS2 = "Fawri+ payment BHD 30.000, ref: BIB103KAK999333 was credited to IBAN ending 0846 on 2026/11/03 15:00. Balance BHD 905.000. Tel: 17515151"
        let outFuture2 = await SMSImporter.importText(futureSMS2, context: context, forceApprove: true)
        let txFuture2 = try #require(outFuture2.transaction)
        #expect(txFuture2.smsTransactionType == .internalTransfer)
        #expect(txFuture2.category == .internalTransfer)
        #expect(txFuture2.accountID == bisb.id)
        #expect(txFuture2.toAccountID == ila.id)
        #expect(abs(ila.balance - 230.000) < 0.0001) // Credited 30.000 to ila via internal transfer rule!

        // 6. Test OR logic rule
        let orRule = TransactionRule(
            name: "Food Delivery Rule",
            logic: .or,
            conditions: [
                RuleCondition(field: .merchant, value: "TALABAT", displayValue: "TALABAT"),
                RuleCondition(field: .merchant, value: "JAHEZ", displayValue: "JAHEZ")
            ],
            actions: RuleActions(
                categoryRaw: SpendCategory.dining.rawValue,
                setMerchant: "Food Delivery"
            )
        )
        TransactionRuleStore.shared.clearAll()
        _ = TransactionRuleStore.shared.addRule(orRule)

        let jahezSMS = "Purchase of BHD 6.500 with Card ending 9001 at JAHEZ BH on 2026/11/04 19:00. Tel: 17515151"
        let jahezOut = await SMSImporter.importText(jahezSMS, context: context, forceApprove: true)
        let jahezTx = try #require(jahezOut.transaction)
        #expect(jahezTx.category == .dining)
        #expect(jahezTx.merchant == "Food Delivery")
    }

    @Test func testBankRecognitionFromSenderTextReferenceCodeAndPhone() throws {
        // 1. From Reference Code alone
        #expect(SMSParser.identifyBankFromReference("BIB103KAK000KZUM")?.bank == "BisB")
        #expect(SMSParser.identifyBankFromReference("ALS103KAU005SVOW")?.bank == "Al Salam")
        #expect(SMSParser.identifyBankFromReference("ABCO261107054458")?.bank == "Bank ABC")
        #expect(SMSParser.identifyBankFromReference("ILAB261107001122")?.bank == "ila")
        #expect(SMSParser.identifyBankFromReference("NBB99887766")?.bank == "NBB")
        #expect(SMSParser.identifyBankFromReference("BBK11223344")?.bank == "BBK")
        #expect(SMSParser.identifyBankFromReference("KFH55667788")?.bank == "KFH")

        // 2. Full SMS parsing when only Reference code indicates the bank
        let refSMS = "Payment of BHD 12.000 completed on 2026/11/07 14:00. Ref: KHCB202611079988. Balance BHD 400.000"
        let parsedRef = try #require(SMSParser.parse(refSMS))
        #expect(parsedRef.detectedBank == "Khaleeji")
        #expect(parsedRef.bankConfidence == .high)

        // 3. Full SMS parsing when only Bank Telephone number indicates the bank
        let phoneSMS = "Your card ending 5511 was used for BHD 9.000 at SEEF MALL on 2026/11/07 16:00. For enquiries call 17565656"
        let parsedPhone = try #require(SMSParser.parse(phoneSMS))
        #expect(parsedPhone.detectedBank == "Al Salam")
        #expect(parsedPhone.bankConfidence == .high)

        // 4. Location inference from merchant / SMS text (Apple Wallet style place + coordinates)
        let place = try #require(LocationService.inferLocation(from: phoneSMS, merchant: "SEEF MALL"))
        #expect(place.name.uppercased().contains("SEEF MALL"))
        #expect(abs((place.latitude ?? 0) - 26.2335) < 0.01)
        #expect(abs((place.longitude ?? 0) - 50.5414) < 0.01)
    }

    // MARK: - 15. Shortcuts Automatic Location Capture Tests

    @Test func testShortcutsLocationCaptureAndResolution() async throws {
        let context = makeCleanContext()

        // 1. Resolve location from explicit coordinates
        let coordLoc = await LocationService.shared.resolveLocation(
            rawInput: nil,
            latitude: 26.2336,
            longitude: 50.5532,
            rawSMS: nil,
            merchant: "City Centre Cafe"
        )
        let resolvedCoord = try #require(coordLoc)
        #expect(abs((resolvedCoord.latitude ?? 0) - 26.2336) < 0.001)
        #expect(abs((resolvedCoord.longitude ?? 0) - 50.5532) < 0.001)

        // 2. Resolve location from raw coordinate string (e.g. from Shortcuts)
        let stringCoordLoc = await LocationService.shared.resolveLocation(
            rawInput: "26.2442, 50.5738",
            rawSMS: nil,
            merchant: "The Avenues Store"
        )
        let resolvedStringCoord = try #require(stringCoordLoc)
        #expect(abs((resolvedStringCoord.latitude ?? 0) - 26.2442) < 0.001)
        #expect(abs((resolvedStringCoord.longitude ?? 0) - 50.5738) < 0.001)

        // 3. Fallback inference when no coordinates or address given
        let inferredLoc = await LocationService.shared.resolveLocation(
            rawInput: nil,
            rawSMS: "Debit card purchase of BHD 5.500 at Marassi Galleria on 2026/11/08",
            merchant: "Marassi Galleria"
        )
        let resolvedInferred = try #require(inferredLoc)
        #expect(resolvedInferred.name.contains("Marassi"))
        #expect(abs((resolvedInferred.latitude ?? 0) - 26.2981) < 0.01)

        // 4. SMSImporter passes and attaches location to imported transaction
        let smsText = "Debit card purchase of BHD 14.500 at Starbucks on 2026/11/08 10:30. Available balance BHD 480.000"
        let outcome = await SMSImporter.importText(
            smsText,
            context: context,
            forceApprove: true,
            location: "26.2335, 50.5414"
        )
        let tx = try #require(outcome.transaction)
        #expect(tx.latitude != nil)
        #expect(abs((tx.latitude ?? 0) - 26.2335) < 0.001)
        #expect(abs((tx.longitude ?? 0) - 50.5414) < 0.001)

        // 5. Verify AddBankSMSIntent properties exist
        var intent = AddBankSMSIntent()
        intent.message = smsText
        intent.sender = "BBK"
        intent.location = "26.2335, 50.5414"
        intent.latitude = 26.2335
        intent.longitude = 50.5414
        #expect(intent.location == "26.2335, 50.5414")
        #expect(intent.latitude == 26.2335)
        #expect(intent.longitude == 50.5414)
    }

    @Test func testEnhancedTransactionRulesEngine() async throws {
        let store = TransactionRuleStore.shared
        store.deleteAll()

        let checkingAccount = Account(name: "BisB Checking", kind: .bank, balance: 500)
        let savingsAccount = Account(name: "ila Savings", kind: .bank, balance: 1000)
        let designatedAccount = Account(name: "NBB Credit Card", kind: .creditCard, balance: 200)

        // 1. Test optional category: rule with no category leaves original category intact
        let ruleWithoutCategory = TransactionRule(
            name: "Merchant Cleanup Rule",
            isEnabled: true,
            logic: .and,
            conditions: [
                RuleCondition(field: .merchant, value: "TALABAT*123", displayValue: "TALABAT*123")
            ],
            actions: RuleActions(
                setCategoryRaw: nil, // Category switch OFF
                overrideAccountID: designatedAccount.id,
                setMerchant: "Talabat Delivery",
                setBank: "BisB",
                setLocationName: "Manama",
                setNote: "Lunch delivery"
            )
        )
        store.addRule(ruleWithoutCategory)

        let tx = MoneyTransaction(
            amount: 4.500,
            isIncome: false,
            merchant: "TALABAT*123",
            category: SpendCategory.dining, // Original category
            date: .now,
            source: .sms,
            accountID: checkingAccount.id
        )

        // Evaluation context matches
        let context = RuleEvaluationContext(from: tx)
        #expect(store.matches(rule: ruleWithoutCategory, context: context, ignoreEnabledState: true))

        // Apply rule
        store.apply(rule: ruleWithoutCategory, to: tx, priorityNumber: 1)
        #expect(tx.category == SpendCategory.dining) // Remains .dining because setCategory was not enabled
        #expect(tx.merchant == "Talabat Delivery") // Cleaned up
        #expect(tx.accountID == designatedAccount.id) // Override Account force-routed it
        #expect(tx.smsBank == "BisB")
        #expect(tx.locationName == "Manama")
        #expect(tx.note == "Lunch delivery")

        // 2. Test Category-based internal transfer setting from/to accounts
        let internalTransferRule = TransactionRule(
            name: "Savings Allocation",
            isEnabled: true,
            logic: .and,
            conditions: [
                RuleCondition(field: .merchant, value: "Monthly Savings", displayValue: "Monthly Savings")
            ],
            actions: RuleActions(
                setCategoryRaw: SpendCategory.internalTransfer.rawValue,
                fromAccountID: checkingAccount.id,
                toAccountID: savingsAccount.id
            )
        )
        store.addRule(internalTransferRule)

        let transferTx = MoneyTransaction(
            amount: 100.000,
            isIncome: false,
            merchant: "Monthly Savings",
            category: SpendCategory.other,
            date: .now,
            source: .manual
        )

        store.apply(rule: internalTransferRule, to: transferTx, priorityNumber: 2)
        #expect(transferTx.category == SpendCategory.internalTransfer)
        #expect(transferTx.accountID == checkingAccount.id)
        #expect(transferTx.toAccountID == savingsAccount.id)

        // 3. Test matching filter: only matching rules are returned for matchingTx
        let matchingTx = MoneyTransaction(
            amount: 4.500,
            isIncome: false,
            merchant: "TALABAT*123",
            category: SpendCategory.dining,
            date: .now,
            source: .sms,
            accountID: checkingAccount.id
        )
        let allRules = store.rules
        let matched = allRules.filter { store.matches(rule: $0, context: RuleEvaluationContext(from: matchingTx), ignoreEnabledState: true) }
        #expect(matched.count == 1)
        #expect(matched.first?.name == "Merchant Cleanup Rule")

        store.deleteAll()
    }

    @Test func testICloudBackupAndRestoreFeature() async throws {
        let context = makeCleanContext()
        let backupService = ICloudBackupService.shared

        // 1. Setup sample data
        let acc1 = Account(name: "ila Main", kind: .bank, balance: 1250.0)
        let acc2 = Account(name: "BisB Credit", kind: .creditCard, balance: 340.0)
        context.insert(acc1)
        context.insert(acc2)

        let tx1 = MoneyTransaction(amount: 15.500, isIncome: false, merchant: "Alosra Supermarket", category: .groceries, date: .now, source: .sms, accountID: acc1.id)
        tx1.smsReference = "REF9901"
        let tx2 = MoneyTransaction(amount: 450.000, isIncome: true, merchant: "Salary Transfer", category: .income, date: .now, source: .sms, accountID: acc1.id)
        context.insert(tx1)
        context.insert(tx2)

        let budget = Budget(name: "Monthly Groceries", categories: [.groceries], limit: 120.0)
        context.insert(budget)

        let rule = TransactionRule(
            name: "Alosra Auto Rule",
            isEnabled: true,
            logic: .and,
            conditions: [RuleCondition(field: .merchant, value: "Alosra", displayValue: "Alosra")],
            actions: RuleActions(setCategoryRaw: SpendCategory.groceries.rawValue)
        )
        TransactionRuleStore.shared.addRule(rule)

        try context.save()

        // 2. Test Backup Creation
        let metadata = try await backupService.createBackup(context: context)
        #expect(metadata.transactionsCount >= 2)
        #expect(metadata.accountsCount >= 2)
        #expect(metadata.rulesCount >= 1)
        #expect(!metadata.sha256Checksum.isEmpty)
        #expect(metadata.fileSizeBytes > 0)
        #expect(backupService.lastBackupDate != nil)

        // Verify available backups list contains this backup
        backupService.refreshAvailableBackups()
        #expect(backupService.availableBackups.contains(where: { $0.id == metadata.id }))

        // 3. Test Restore with Deduplication (Merge Mode)
        // Add a new local transaction that is not in the backup
        let newTx = MoneyTransaction(amount: 3.200, isIncome: false, merchant: "Costa Coffee", category: .dining, date: .now, source: .manual, accountID: acc1.id)
        context.insert(newTx)
        try context.save()

        let mergeSummary = try await backupService.restoreBackup(from: metadata, mode: .merge, context: context)
        #expect(mergeSummary.mode == .merge)
        // tx1 and tx2 already exist, so they should be detected as duplicates and skipped
        #expect(mergeSummary.skippedDuplicateTransactionsCount >= 2)

        // Verify all 3 transactions exist (no duplicates created)
        let allTx = try context.fetch(FetchDescriptor<MoneyTransaction>())
        let alosraCount = allTx.filter { $0.merchant == "Alosra Supermarket" }.count
        #expect(alosraCount == 1) // NOT duplicated!
        #expect(allTx.contains(where: { $0.merchant == "Costa Coffee" })) // Preserved!

        // 4. Test Restore in Replace Mode
        let replaceSummary = try await backupService.restoreBackup(from: metadata, mode: .replace, context: context)
        #expect(replaceSummary.mode == .replace)
        #expect(replaceSummary.restoredTransactionsCount >= 2)

        // 5. Test Automatic Backup Schedule Settings
        backupService.isAutoBackupEnabled = true
        backupService.autoBackupSchedule = .weekly
        #expect(backupService.isAutoBackupEnabled == true)
        #expect(backupService.autoBackupSchedule == .weekly)
        #expect(backupService.autoBackupSchedule.intervalDays == 7)

        backupService.autoBackupSchedule = .daily
        #expect(backupService.autoBackupSchedule.intervalDays == 1)

        backupService.autoBackupSchedule = .monthly
        #expect(backupService.autoBackupSchedule.intervalDays == 30)

        // Clean up backup file
        backupService.deleteBackup(metadata)
        TransactionRuleStore.shared.deleteAll()
    }

    // MARK: - 8. GPS Coordinates & Radius-Based Transaction Rules Matching

    @Test func testGPSCoordinatesAndRadiusMatchingInTransactionRules() throws {
        let store = TransactionRuleStore.shared
        store.deleteAll()

        // Reference coordinates (e.g., The Avenues Mall Bahrain: 26.2415, 50.5840)
        let mallLat = 26.2415
        let mallLon = 50.5840

        // 1. Create a rule with GPS coordinates and default 15m radius
        let locationRule = TransactionRule(
            name: "Avenues Mall Coffee Rule",
            isEnabled: true,
            logic: .and,
            conditions: [
                RuleCondition(
                    field: .location,
                    value: "The Avenues Mall",
                    displayValue: "The Avenues Mall (within 15m)",
                    latitude: mallLat,
                    longitude: mallLon,
                    radiusMeters: 15.0
                )
            ],
            actions: RuleActions(
                setCategoryRaw: SpendCategory.dining.rawValue,
                setMerchant: "Mall Cafe"
            )
        )
        store.addRule(locationRule)

        // 2. Transaction exactly at the coordinates, with completely different location name
        let txExact = MoneyTransaction(
            amount: 3.500,
            isIncome: false,
            merchant: "Point of Sale 102",
            category: SpendCategory.other,
            date: .now,
            source: .sms
        )
        txExact.latitude = mallLat
        txExact.longitude = mallLon
        txExact.locationName = "Unknown Store #42" // Different place name

        let contextExact = RuleEvaluationContext(from: txExact)
        #expect(store.matches(rule: locationRule, context: contextExact, ignoreEnabledState: true))

        // 3. Transaction ~8 meters away (well within 15 meters radius)
        // 0.000072 degrees latitude is approximately 8 meters
        let txWithin8m = MoneyTransaction(
            amount: 2.200,
            isIncome: false,
            merchant: "POS Unknown",
            category: SpendCategory.other,
            date: .now,
            source: .sms
        )
        txWithin8m.latitude = mallLat + 0.000072
        txWithin8m.longitude = mallLon
        txWithin8m.locationName = nil // No location name at all

        let contextWithin = RuleEvaluationContext(from: txWithin8m)
        let dist = TransactionRuleStore.distanceBetween(lat1: mallLat, lon1: mallLon, lat2: txWithin8m.latitude!, lon2: txWithin8m.longitude!)
        #expect(dist < 15.0)
        #expect(store.matches(rule: locationRule, context: contextWithin, ignoreEnabledState: true))

        // 4. Transaction ~45 meters away (OUTSIDE 15 meters radius)
        // 0.00040 degrees latitude is approximately 44.5 meters
        let txOutside = MoneyTransaction(
            amount: 5.000,
            isIncome: false,
            merchant: "POS Unknown",
            category: SpendCategory.other,
            date: .now,
            source: .sms
        )
        txOutside.latitude = mallLat + 0.00040
        txOutside.longitude = mallLon
        txOutside.locationName = "The Avenues Mall" // Even with matching name, coordinates take precedence!

        let contextOutside = RuleEvaluationContext(from: txOutside)
        let distOutside = TransactionRuleStore.distanceBetween(lat1: mallLat, lon1: mallLon, lat2: txOutside.latitude!, lon2: txOutside.longitude!)
        #expect(distOutside > 15.0)
        #expect(!store.matches(rule: locationRule, context: contextOutside, ignoreEnabledState: true))

        // 5. Test Custom Radius (e.g. 50 meters)
        var wideRadiusRule = locationRule
        wideRadiusRule.id = UUID()
        wideRadiusRule.conditions[0].radiusMeters = 50.0
        wideRadiusRule.conditions[0].displayValue = "The Avenues Mall (within 50m)"
        store.addRule(wideRadiusRule)

        // Now txOutside (~45m) should MATCH wideRadiusRule
        #expect(store.matches(rule: wideRadiusRule, context: contextOutside, ignoreEnabledState: true))

        // 6. Test applying the rule to txWithin8m
        store.apply(rule: locationRule, to: txWithin8m, priorityNumber: 1)
        #expect(txWithin8m.category == SpendCategory.dining)
        #expect(txWithin8m.merchant == "Mall Cafe")

        // 7. Test backward compatibility: legacy rule with only location name and no coordinates
        let legacyRule = TransactionRule(
            name: "Legacy Name Rule",
            isEnabled: true,
            logic: .and,
            conditions: [
                RuleCondition(
                    field: .location,
                    value: "Seef Mall",
                    displayValue: "Seef Mall"
                )
            ],
            actions: RuleActions(setCategoryRaw: SpendCategory.shopping.rawValue)
        )
        store.addRule(legacyRule)

        let legacyTx = MoneyTransaction(
            amount: 20.000,
            isIncome: false,
            merchant: "Zara",
            category: SpendCategory.other,
            date: .now,
            source: .sms
        )
        legacyTx.locationName = "Seef Mall, Manama"
        let legacyContext = RuleEvaluationContext(from: legacyTx)
        #expect(store.matches(rule: legacyRule, context: legacyContext, ignoreEnabledState: true))

        store.deleteAll()
    }

    // MARK: - 9. Bank Statement Import & Export Feature Tests

    @Test func testBankStatementParsingAndDeduplication() throws {
        let context = makeCleanContext()

        // 1. Setup existing accounts
        let ilaBank = Account(name: "ila Current", kind: .bank, institution: "ila Bank", balance: 500.0)
        ilaBank.smsMatch = "3876" // last 4 digits
        let bisbCredit = Account(name: "BisB Platinum Credit", kind: .creditCard, institution: "BisB", balance: 150.0)
        bisbCredit.smsMatch = "4821" // card digits
        context.insert(ilaBank)
        context.insert(bisbCredit)

        // 2. Setup existing transaction to test duplicate detection
        let existingTx = MoneyTransaction(
            amount: 15.500,
            isIncome: false,
            merchant: "Alosra Supermarket",
            category: .groceries,
            date: Date(),
            source: .sms,
            accountID: ilaBank.id
        )
        existingTx.smsReference = "BIB103KAK000KZUM"
        context.insert(existingTx)
        try context.save()

        // 3. Test Statement Line Parsing (CSV / Text statement)
        let sampleStatement = """
        Bank: ila Bank
        Account: BH29ILAB00000012343876
        Date,Description,Debit,Credit,Reference
        2026-11-10,Alosra Supermarket,15.500,,BIB103KAK000KZUM
        2026-11-09,Costa Coffee,2.750,,TXN889901
        2026-11-08,Salary Transfer,,450.000,SALARY202611
        2026-11-07,TALABAT BAHRAIN,6.500,,
        """

        let parseResult = StatementService.parse(
            fileData: sampleStatement.data(using: .utf8)!,
            filename: "ila_statement_nov2026.csv",
            existingAccounts: [ilaBank, bisbCredit],
            existingTransactions: [existingTx]
        )

        // Verify account auto-matching via IBAN suffix "3876"
        #expect(parseResult.matchedAccountID == ilaBank.id)
        #expect(parseResult.detectedBank == "ila Bank")
        #expect(parseResult.items.count == 4)

        // Verify Duplicate Detection flagged Alosra with BIB103KAK000KZUM
        let alosraItem = try #require(parseResult.items.first(where: { $0.merchant.contains("Alosra") }))
        #expect(alosraItem.isDuplicate == true)
        #expect(alosraItem.isSelected == false) // Unchecked by default
        #expect(alosraItem.duplicateReason != nil)

        // Verify Costa Coffee is recognized as new and categorized as dining
        let costaItem = try #require(parseResult.items.first(where: { $0.merchant.contains("Costa") }))
        #expect(costaItem.isDuplicate == false)
        #expect(costaItem.category == .dining)
        #expect(abs(costaItem.amount - 2.750) < 0.001)
        #expect(costaItem.isIncome == false)

        // Verify Salary is recognized as income
        let salaryItem = try #require(parseResult.items.first(where: { $0.merchant.contains("Salary") }))
        #expect(salaryItem.isIncome == true)
        #expect(abs(salaryItem.amount - 450.000) < 0.001)

        // 4. Test Safe Import: Never modifies account balances!
        let initialIlaBalance = ilaBank.balance
        let initialBisbBalance = bisbCredit.balance

        let importOutcome = StatementService.importConfirmedTransactions(
            parseResult.items,
            into: parseResult.matchedAccountID,
            sourceBank: parseResult.detectedBank,
            context: context
        )

        #expect(importOutcome.importedCount == 3) // Costa, Salary, Talabat
        #expect(importOutcome.skippedCount == 1)  // Alosra (duplicate)

        // CRITICAL CHECK: Account balances MUST remain strictly unmodified!
        #expect(abs(ilaBank.balance - initialIlaBalance) < 0.0001)
        #expect(abs(bisbCredit.balance - initialBisbBalance) < 0.0001)

        // Verify transactions exist in database
        let updatedTxs = try context.fetch(FetchDescriptor<MoneyTransaction>())
        #expect(updatedTxs.count == 4) // 1 existing + 3 newly imported
        #expect(updatedTxs.contains(where: { $0.merchant == "Costa Coffee" }))
        #expect(updatedTxs.contains(where: { $0.merchant == "Salary Transfer" }))

        // 5. Test Export to PDF and Excel
        let excelData = StatementExportService.createExcelData(
            transactions: updatedTxs,
            accounts: [ilaBank, bisbCredit],
            currency: "BHD"
        )
        #expect(!excelData.isEmpty)
        let excelStr = String(data: excelData, encoding: .utf8) ?? ""
        #expect(excelStr.contains("Budget AI — Transaction Statement"))
        #expect(excelStr.contains("Costa Coffee"))
        #expect(excelStr.contains("Salary Transfer"))

        let pdfData = StatementExportService.createPDFData(
            transactions: updatedTxs,
            accounts: [ilaBank, bisbCredit],
            currency: "BHD"
        )
        #expect(!pdfData.isEmpty)
        #expect(pdfData.count > 500)
    }

    @Test func testCreditCardLast4MatchingInStatement() throws {
        let card = Account(name: "My Visa Card", kind: .creditCard, institution: "BisB", balance: 120.0)
        card.smsMatch = "9012"

        let accounts = [card]

        let matched = StatementService.matchAccount(ibanOrAcc: nil, cardLast4: "9012", bank: "BisB", in: accounts)
        #expect(matched?.id == card.id)
    }

    // MARK: - 10. Transaction Location Search & Interactive Map Pin Tests

    @Test func testLocationSearchAndPinCoordinateData() throws {
        // Test TransactionLocationData initialization and coordinate precision
        let mallLocation = TransactionLocationData(
            name: "City Centre Bahrain",
            address: "Seef District, Manama, Bahrain",
            latitude: 26.2336,
            longitude: 50.5532
        )

        #expect(mallLocation.name == "City Centre Bahrain")
        #expect(mallLocation.address?.contains("Seef") == true)
        #expect(abs(mallLocation.latitude! - 26.2336) < 0.0001)
        #expect(abs(mallLocation.longitude! - 50.5532) < 0.0001)

        // Test saving location into MoneyTransaction
        let tx = MoneyTransaction(
            amount: 14.500,
            isIncome: false,
            merchant: "Carrefour Seef",
            category: .groceries,
            date: .now,
            source: .manual
        )

        tx.locationName = mallLocation.name
        tx.locationAddress = mallLocation.address
        tx.latitude = mallLocation.latitude
        tx.longitude = mallLocation.longitude

        #expect(tx.hasLocation == true)
        #expect(tx.locationName == "City Centre Bahrain")
        #expect(tx.latitude != nil)
        #expect(tx.longitude != nil)
    }

    @Test func testMultiLinePDFStatementParsing() throws {
        // Simulates multi-line text extracted by PDFKit from a bank statement
        let multilinePDFText = """
        NATIONAL BANK OF BAHRAIN
        Account: BH29 NBBB 0000 0012 3456 78
        Statement of Account

        15/10/2026
        STARBUCKS SEEF MALL
        POS PURCHASE REF123456
        4.500 DR
        210.500

        16/10/2026
        AL MEERA SUPERMARKET
        DEBIT CARD 9012
        18.750 DR
        191.750

        20/10/2026
        SALARY OCTOBER
        CREDIT SALARY TRANSFER
        650.000 CR
        841.750
        """

        let nbbAccount = Account(name: "NBB Checking", kind: .bank, institution: "NBB", balance: 100.0)
        nbbAccount.smsMatch = "5678"

        let items = StatementService.parseTextLinesToItems(multilinePDFText)
        #expect(items.count == 3)

        let starbucks = try #require(items.first(where: { $0.merchant.contains("STARBUCKS") }))
        #expect(abs(starbucks.amount - 4.500) < 0.001)
        #expect(starbucks.isIncome == false)
        #expect(starbucks.category == .dining)

        let almeera = try #require(items.first(where: { $0.merchant.contains("AL MEERA") }))
        #expect(abs(almeera.amount - 18.750) < 0.001)
        #expect(almeera.isIncome == false)
        #expect(almeera.category == .groceries)

        let salary = try #require(items.first(where: { $0.merchant.contains("SALARY") }))
        #expect(abs(salary.amount - 650.000) < 0.001)
        #expect(salary.isIncome == true)
    }

    @Test func testExcelHTMLStatementParsing() throws {
        // Simulates an HTML table statement exported as .xls
        let htmlTable = """
        <html>
        <body>
        <table border="1">
            <tr>
                <th>Date</th>
                <th>Description</th>
                <th>Debit</th>
                <th>Credit</th>
                <th>Balance</th>
            </tr>
            <tr>
                <td>01/11/2026</td>
                <td>Costa Coffee Seef</td>
                <td>2.850</td>
                <td></td>
                <td>120.000</td>
            </tr>
            <tr>
                <td>02/11/2026</td>
                <td>Client Transfer In</td>
                <td></td>
                <td>150.000</td>
                <td>270.000</td>
            </tr>
        </table>
        </body>
        </html>
        """

        let htmlItems = StatementService.parseHTMLTable(htmlTable)
        #expect(htmlItems.count == 2)

        let costa = try #require(htmlItems.first(where: { $0.merchant.contains("Costa") }))
        #expect(abs(costa.amount - 2.850) < 0.001)
        #expect(costa.isIncome == false)

        let transfer = try #require(htmlItems.first(where: { $0.merchant.contains("Client Transfer") }))
        #expect(abs(transfer.amount - 150.000) < 0.001)
        #expect(transfer.isIncome == true)
    }

    @Test func testRuleActionSetLocationWithPinCoordinates() throws {
        // Tests RuleActions with location coordinates and place name
        let actions = RuleActions(
            setCategoryRaw: SpendCategory.dining.rawValue,
            setLocationName: "The Avenues Bahrain",
            setLocationAddress: "Manama Corniche, Bahrain",
            setLatitude: 26.2412,
            setLongitude: 50.5794
        )

        #expect(actions.setLocationName == "The Avenues Bahrain")
        #expect(actions.setLocationAddress == "Manama Corniche, Bahrain")
        #expect(abs(actions.setLatitude! - 26.2412) < 0.0001)
        #expect(abs(actions.setLongitude! - 50.5794) < 0.0001)

        let testTx = MoneyTransaction(
            amount: 5.500,
            isIncome: false,
            merchant: "Shake Shack",
            category: .dining,
            date: .now
        )

        // Apply rule actions to transaction
        if let loc = actions.setLocationName {
            testTx.locationName = loc
            testTx.locationAddress = actions.setLocationAddress
            testTx.latitude = actions.setLatitude
            testTx.longitude = actions.setLongitude
        }

        #expect(testTx.hasLocation == true)
        #expect(testTx.locationName == "The Avenues Bahrain")
        #expect(testTx.latitude == 26.2412)
        #expect(testTx.longitude == 50.5794)
    }

    // MARK: - Learned Bank Statement Knowledge Base & Detection Engine Tests

    @Test func testBisBAccountStatementLearnedDetection() throws {
        let sampleBisBCSV = """
        BisB - Bahrain
        BIBBBHBMINV
        Building 722, Al Salam Tower, Diplomatic Area, Manama, Bahrain
        Account Statement
        IBAN: BH85BIBB00200001693876
        Statement Period: 11 Oct 26 to 10 Nov 26
        Opening Balance,BHD 431.841
        Closing Balance,BHD 135.703

        Transaction Date,Description,Debit Amount,Credit Amount,Balance
        ,Opening Balance,,,BHD 431.841
        11 Oct 26,FAWRI+ Payment to BH840000000001234-98765432,BHD 200.000,BHD 0.000,"BHD 1,686.277"
        12 Oct 26,FAWRI+ Payment From IBAN: BH29ILAB00000012-12345678,BHD 0.000,BHD 50.000,"BHD 1,736.277"
        13 Oct 26,POS PURCHASE CARREFOUR CITY CENTRE,BHD 24.500,BHD 0.000,"BHD 1,711.777"
        ,Closing Balance,,,BHD 135.703
        """

        let result = StatementService.parseCSV(data: Data(sampleBisBCSV.utf8), accounts: [])

        #expect(result.detectedBank == "BisB")
        #expect(result.detectedAccountIBAN == "BH85BIBB00200001693876")
        #expect(result.items.count == 3) // Opening/Closing rows skipped

        // Verify Opening & Closing Balance extraction
        #expect(abs((result.openingBalance ?? 0) - 431.841) < 0.001)
        #expect(abs((result.closingBalance ?? 0) - 135.703) < 0.001)

        // Item 1: Fawri+ Debit
        let debitTx = result.items[0]
        #expect(abs(debitTx.amount - 200.000) < 0.001)
        #expect(debitTx.isIncome == false)
        #expect(debitTx.merchant.contains("Fawri+"))

        // Item 2: Fawri+ Credit
        let creditTx = result.items[1]
        #expect(abs(creditTx.amount - 50.000) < 0.001)
        #expect(creditTx.isIncome == true)

        // Item 3: Grocery Purchase
        let grocTx = result.items[2]
        #expect(abs(grocTx.amount - 24.500) < 0.001)
        #expect(grocTx.isIncome == false)
        #expect(grocTx.category == .groceries)
    }

    @Test func testAlSalamBankStatementLearnedDetection() throws {
        let sampleAlSalamText = """
        Al Salam Bank
        SWIFT Code ALSABHBM
        IBAN BH69ALSA00219442150020
        Saving Deposit
        Statement of Account
        Opening Balance 2,607.846
        Closing Balance 2,563.966

        Posting Date Description Value Date Amount Balance
        01 OCT 2026 FAWRI+ Payment to BH690000000000-FT262747PTDP 01 OCT 2026 (-) 10.000 2,597.846
        02 OCT 2026 SALARY TRANSFER CREDIT 02 OCT 2026 (+) 100.000 2,697.846
        03 OCT 2026 TALABAT SEEF DELIVERY 03 OCT 2026 (-) 4.500 2,693.346
        """

        let (profile, conf) = BankProfileRegistry.matchProfile(for: sampleAlSalamText)
        #expect(profile.bankName == "Al Salam Bank")
        #expect(profile.signNotation == .parenthesesSigned)
        #expect(conf > 0.5)

        let items = StatementService.parseTextLinesToItems(sampleAlSalamText, profile: profile)
        #expect(items.count == 3)

        // Item 1: (-) 10.000 is Expense
        let item1 = items[0]
        #expect(abs(item1.amount - 10.000) < 0.001)
        #expect(item1.isIncome == false)
        #expect(item1.reference == "FT262747PTDP")

        // Item 2: (+) 100.000 is Income
        let item2 = items[1]
        #expect(abs(item2.amount - 100.000) < 0.001)
        #expect(item2.isIncome == true)

        // Item 3: (-) 4.500 is Dining Expense
        let item3 = items[2]
        #expect(abs(item3.amount - 4.500) < 0.001)
        #expect(item3.isIncome == false)
        #expect(item3.category == .dining)
    }

    @Test func testBisBCreditCardStatementLearnedDetection() throws {
        let sampleCreditCardText = """
        Credit Card Statement
        BisB - Bahrain
        Credit Card Number 4545 22** **** 1843
        VISA INFINITE
        Total Credit Limit BHD 5,000.000
        Previous Balance 98.000
        Total Amount Due 115.230

        Posting Date Transaction Date Description Currency Transaction Amount Amount in BHD VAT
        Wed May 13 2026 Wed May 13 2026 PAYMENT RECEIVED - MCC: 0000 BHD -98 -98 0
        Fri May 15 2026 Fri May 15 2026 TALABAT GO - MCC: 5814 BHD 11.41 11.41 0
        Sat May 16 2026 Sat May 16 2026 COSTA COFFEE - MCC: 5814 BHD 2 2 0
        Sun May 17 2026 Sun May 17 2026 LULU HYPERMARKET - MCC: 5411 BHD 17.500 17.500 0
        """

        let (profile, conf) = BankProfileRegistry.matchProfile(for: sampleCreditCardText)
        #expect(profile.bankName == "BisB")
        #expect(profile.docType == .creditCard)
        #expect(profile.signNotation == .creditCardNegativePayment)
        #expect(conf > 0.6)

        let items = StatementService.parseTextLinesToItems(sampleCreditCardText, profile: profile)
        #expect(items.count == 4)

        // Payment Received: -98 -> Income / Payment
        let paymentItem = items[0]
        #expect(abs(paymentItem.amount - 98.0) < 0.001)
        #expect(paymentItem.isIncome == true)
        #expect(paymentItem.category == .transfers)

        // Talabat: 11.41 -> Dining
        let talabatItem = items[1]
        #expect(abs(talabatItem.amount - 11.41) < 0.001)
        #expect(talabatItem.isIncome == false)
        #expect(talabatItem.category == .dining)

        // Costa: integer amount 2 -> Dining
        let costaItem = items[2]
        #expect(abs(costaItem.amount - 2.0) < 0.001)
        #expect(costaItem.isIncome == false)
        #expect(costaItem.category == .dining)

        // Lulu: MCC 5411 -> Groceries
        let luluItem = items[3]
        #expect(abs(luluItem.amount - 17.5) < 0.001)
        #expect(luluItem.isIncome == false)
        #expect(luluItem.category == .groceries)
    }

    @Test func testStatementLearningEngineDiagnosticReportAndIsolation() throws {
        // Sample bank statement data
        let sampleData = Data("""
        Al Salam Bank
        SWIFT Code ALSABHBM
        IBAN BH69ALSA00219442150020
        Saving Deposit
        Opening Balance 1,000.000
        Closing Balance 1,090.000

        01 OCT 2026 FAWRI+ Payment to BH... 01 OCT 2026 (-) 10.000 990.000
        02 OCT 2026 Inward Transfer 02 OCT 2026 (+) 100.000 1,090.000
        """.utf8)

        // User account to verify strict isolation
        let existingAccount = Account(name: "Existing User Account", kind: .bank, balance: 500.0)
        let initialBalance = existingAccount.balance

        let report = StatementLearningEngine.analyzeSampleStatement(fileData: sampleData, filename: "alsalam_sample.csv")

        // Diagnostic assertions
        #expect(report.detectedBank == "Al Salam Bank")
        #expect(report.detectedDocType == .bankAccount)
        #expect(report.detectedIBAN == "BH69ALSA00219442150020")
        #expect(report.detectedTransactionsCount == 2)
        #expect(abs(report.totalDebits - 10.000) < 0.001)
        #expect(abs(report.totalCredits - 100.000) < 0.001)
        #expect(report.balanceReconciled == true)
        #expect(report.inconsistencies.isEmpty)

        // STRICT ISOLATION ASSERTION: User account balance was NEVER touched or modified
        #expect(existingAccount.balance == initialBalance)
    }

    // MARK: - 17. Custom Sender Bank Creation & Detection

    @Test func customSenderBankCreationAndSMSDetection() throws {
        let testBank = "MeemTestBank"
        BahrainBankCatalog.removeCustomBank(testBank)
        defer { BahrainBankCatalog.removeCustomBank(testBank) }

        let added = BahrainBankCatalog.addCustomBank("  \(testBank)  ")
        #expect(added == testBank)
        #expect(BahrainBankCatalog.allBanks.contains(testBank))

        let sms = "Your card was charged BHD 12.500 at CARREFOUR on 2026/11/01 10:30."
        let parsed = try #require(SMSParser.parse(sms, sender: testBank))
        #expect(parsed.bank == testBank)
    }

    // MARK: - 18. iCloud Entitlement Parsing Guard

    @Test func icloudEntitlementParserGuardsMissingCloudKitEntitlements() throws {
        let unsignedProvision = Data("""
        CMS_HEADER<plist version="1.0"><dict>
        <key>Entitlements</key><dict>
            <key>application-identifier</key><string>TEAM.com.example.budgetai</string>
        </dict>
        </dict></plist>CMS_FOOTER
        """.utf8)
        let unsignedStatus = ICloudBackupService.ICloudEntitlementStatus.parse(mobileProvisionData: unsignedProvision)
        #expect(unsignedStatus.hasCloudKitEntitlement == false)
        #expect(unsignedStatus.hasUbiquityContainerEntitlement == false)
        #expect(unsignedStatus.hasKVStoreEntitlement == false)

        let signedProvision = Data("""
        CMS_HEADER<plist version="1.0"><dict>
        <key>Entitlements</key><dict>
            <key>com.apple.developer.icloud-services</key><array><string>CloudKit</string><string>CloudDocuments</string></array>
            <key>com.apple.developer.icloud-container-identifiers</key><array><string>iCloud.com.example.budgetai</string></array>
            <key>com.apple.developer.ubiquity-kvstore-identifier</key><string>TEAM.com.example.budgetai</string>
        </dict>
        </dict></plist>CMS_FOOTER
        """.utf8)
        let signedStatus = ICloudBackupService.ICloudEntitlementStatus.parse(mobileProvisionData: signedProvision)
        #expect(signedStatus.hasCloudKitEntitlement == true)
        #expect(signedStatus.hasUbiquityContainerEntitlement == true)
        #expect(signedStatus.hasKVStoreEntitlement == true)
    }

    // MARK: - 19. Card Last-4 Detection & Statement Formats

    @Test func statementCardLast4DetectionAndVariedFormats() throws {
        #expect(StatementService.extractCardLast4(from: "Credit Card Statement 2026\nCard No: 4545 22** **** 1843") == "1843")
        #expect(StatementService.extractCardLast4(from: "Card Number,**** **** **** 9010") == "9010")
        #expect(StatementService.extractCardLast4(from: "Visa Platinum ending in 4321") == "4321")
        #expect(StatementService.extractCardLast4(from: "Credit Card Statement 2026") == nil)

        // Excel/CSV with varied headers ("Txn Date", "Details", "Withdrawal", "Deposit") and omitted trailing empty cell
        let csv = Data("""
        Account Summary
        Card Number,XXXX-XXXX-XXXX-7788
        Txn Date,Details,Withdrawal,Deposit
        05/11/2026,LULU HYPERMARKET,14.250
        06/11/2026,SALARY TRANSFER,,450.000
        """.utf8)
        let parsed = StatementService.parseCSV(data: csv, accounts: [])
        #expect(parsed.detectedCardLast4 == "7788")
        #expect(parsed.items.count == 2)
        #expect(parsed.items[0].amount == 14.250)
        #expect(parsed.items[0].isIncome == false)
        #expect(parsed.items[1].amount == 450.000)
        #expect(parsed.items[1].isIncome == true)

        // Headless CSV with title lines at top before actual rows
        let headless = Data("""
        My Bank Export
        Generated 2026-11-10
        07/11/2026,COSTA COFFEE,2.400
        08/11/2026,TALABAT,5.800
        """.utf8)
        let headlessItems = StatementService.parseCSVRows(String(decoding: headless, as: UTF8.self))
        #expect(headlessItems.count == 2)
    }

    // MARK: - 20. Unknown Category Treated as Other Without Review Flag

    @Test func unknownCategoryKeptAsOtherWithoutRequiringReview() throws {
        #expect(SpendCategory.resolve("Unknown") == .other)
        #expect(SpendCategory.resolve("unknown") == .other)
        #expect(SpendCategory.resolve(nil) == .other)

        let tx = MoneyTransaction(amount: 9.500, isIncome: false, merchant: "Corner Shop", category: .other, source: .sms)
        tx.smsBank = "NBB"
        tx.accountID = UUID()
        tx.smsTransactionType = .expense
        tx.smsConfidence = .low
        tx.isPending = false

        #expect(tx.category == .other)
        #expect(tx.isUnmatchedOrUncertain == false)
        #expect(tx.reviewReasons(accounts: []).isEmpty)

        let parsed = ParsedSMS(
            amount: 9.500,
            isIncome: false,
            merchant: "Corner Shop",
            category: .other,
            transactionType: .expense,
            confidence: .low
        )
        #expect(parsed.requiresReview == false)
    }

    // MARK: - 21. Strict SMS Internal Transfer Matching (All 4 Conditions Required)

    @Test func strictSMSInternalTransferMatchingConditions() async throws {
        let context = makeCleanContext()

        let accA = Account(name: "BisB", kind: .bank, institution: "BisB", balance: 500.000)
        accA.smsMatch = "9001"
        let accB = Account(name: "ila", kind: .bank, institution: "ila Bank", balance: 200.000)
        accB.smsMatch = "0846"
        context.insert(accA)
        context.insert(accB)
        try context.save()

        // 1. Missing reference -> must NOT link as internal transfer
        _ = await SMSImporter.importText("Your account ending 9001 has been debited BHD 15.000 for outward transfer on 2026/11/01 10:00. Balance BHD 485.000. Tel: 17515151", context: context, forceApprove: true)
        _ = await SMSImporter.importText("Your account ending 0846 has been credited with BHD 15.000 via Fawri+ on 2026/11/01 10:00. Available balance BHD 215.000. Call 17123456", context: context, forceApprove: true)
        let afterNoRef = try context.fetch(FetchDescriptor<MoneyTransaction>())
        #expect(afterNoRef.count == 2)
        #expect(afterNoRef.allSatisfy { $0.smsTransactionType != .internalTransfer })

        // 2. Different time (11:00 vs 11:01) with same ref & amount -> must NOT link as internal transfer
        _ = await SMSImporter.importText("Your account ending 9001 has been debited BHD 22.000 for outward transfer Ref: REFDIFFTIME on 2026/11/02 11:00. Balance BHD 463.000. Tel: 17515151", context: context, forceApprove: true)
        _ = await SMSImporter.importText("Your account ending 0846 has been credited with BHD 22.000 via Fawri+ Ref: REFDIFFTIME on 2026/11/02 11:01. Available balance BHD 237.000. Call 17123456", context: context, forceApprove: true)
        let afterDiffTime = try context.fetch(FetchDescriptor<MoneyTransaction>()).filter { abs($0.amount - 22.000) < 0.001 }
        #expect(afterDiffTime.count == 2)
        #expect(afterDiffTime.allSatisfy { $0.smsTransactionType != .internalTransfer })

        // 3. Different ref -> must NOT link as internal transfer
        _ = await SMSImporter.importText("Your account ending 9001 has been debited BHD 33.000 for outward transfer Ref: REFAAA on 2026/11/03 12:00. Balance BHD 430.000. Tel: 17515151", context: context, forceApprove: true)
        _ = await SMSImporter.importText("Your account ending 0846 has been credited with BHD 33.000 via Fawri+ Ref: REFBBB on 2026/11/03 12:00. Available balance BHD 270.000. Call 17123456", context: context, forceApprove: true)
        let afterDiffRef = try context.fetch(FetchDescriptor<MoneyTransaction>()).filter { abs($0.amount - 33.000) < 0.001 }
        #expect(afterDiffRef.count == 2)
        #expect(afterDiffRef.allSatisfy { $0.smsTransactionType != .internalTransfer })

        // 4. All 4 conditions met (exact amount, same ref, exact same date & time, two different configured accounts) -> MUST link as internalTransfer
        _ = await SMSImporter.importText("Your account ending 9001 has been debited BHD 44.000 for outward transfer Ref: REFMATCH44 on 2026/11/04 14:30. Balance BHD 386.000. Tel: 17515151", context: context, forceApprove: true)
        _ = await SMSImporter.importText("Your account ending 0846 has been credited with BHD 44.000 via Fawri+ Ref: REFMATCH44 on 2026/11/04 14:30. Available balance BHD 314.000. Call 17123456", context: context, forceApprove: true)
        let matched = try context.fetch(FetchDescriptor<MoneyTransaction>()).filter { abs($0.amount - 44.000) < 0.001 }
        #expect(matched.count == 1)
        #expect(matched.first?.smsTransactionType == .internalTransfer)
        #expect(matched.first?.category == .internalTransfer)
        #expect(matched.first?.accountID == accA.id)
        #expect(matched.first?.toAccountID == accB.id)
    }
}
