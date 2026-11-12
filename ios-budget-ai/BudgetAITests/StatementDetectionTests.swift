import Foundation
import PDFKit
import SwiftData
import Testing
@testable import BudgetAI

private final class StatementFixtureBundle {}

@Suite(.serialized)
@MainActor
struct StatementDetectionTests {
    private func fixture(_ name: String, extension ext: String) throws -> Data {
        let bundle = Bundle(for: StatementFixtureBundle.self)
        let url = try #require(bundle.url(forResource: name, withExtension: ext, subdirectory: "StatementFixtures")
            ?? bundle.url(forResource: name, withExtension: ext))
        return try Data(contentsOf: url)
    }

    @Test func positionedPDFsPreserveAllRowsAcrossPages() throws {
        for (name, expected) in [("account-layout",108),("signed-layout",40),("card-layout",63)] {
            let data = try fixture(name, extension: "pdf")
            let doc = try #require(PDFDocument(data: data))
            let text = try #require(StatementPDFTable.extract(doc))
            if name != "signed-layout" {
                let profile = BankProfileRegistry.matchProfile(for: doc.string ?? "").profile
                let flattened = StatementService.parseTextLinesToItems(doc.string ?? "", profile: profile)
                #expect(flattened.count != expected, "Legacy flattened-text path must reproduce the layout regression")
            }
            #expect(text.components(separatedBy: "\n").count == expected + 1, "\(name) table row count")
            let result = StatementService.parse(fileData: data, filename: name + ".pdf", existingAccounts: [], existingTransactions: [])
            #expect(result.items.count == expected, "\(name): \(result.items.count) extracted rows")
            #expect(result.items.allSatisfy { $0.amount > 0 && !$0.merchant.isEmpty })
            if name == "card-layout" {
                #expect(result.profileName?.contains("Credit Card") == true)
                #expect(result.items[0].isIncome)
                #expect(result.items[0].amount == 11)
                // SAR foreign amount has 2 decimals; account-currency amount has 3.
                #expect(abs(result.items[6].amount - 1.111) < 0.00001)
            }
        }
    }

    @Test func xlsxDescriptorSparseColumnsStylesAndWorksheets() throws {
        let result = StatementService.parse(fileData: try fixture("sparse-descriptor", extension: "xlsx"), filename: "fixture.xlsx", existingAccounts: [], existingTransactions: [])
        #expect(result.items.count == 2)
        let debit = try #require(result.items.first)
        #expect(debit.amount == 45000) // A large amount must never become an Excel date.
        #expect(!debit.isIncome)
        #expect(debit.merchant == "Sample & Store")
        #expect(Calendar.current.component(.year, from: debit.date) == 2026)
        #expect(result.items.last?.isIncome == true)
        #expect(result.items.last?.amount == 100)
    }

    @Test func preambleColumnDirectionAndNumericFormats() {
        let rows = "Account Statement\nMetadata\nDate\tDescription\tDebit\tCredit\tBalance\n11 Nov 2026\tCredit Card Payment\t1,234.567\t0\t9,000.000\n12 Nov 2026\tRefund\t0\t12.500\t9,012.500"
        let items = StatementService.parseCSVRows(rows)
        #expect(items.count == 2)
        #expect(items.first?.isIncome == false)
        #expect(items.first?.amount == 1234.567)
        #expect(items.first?.transactionType == .transferOut)
        #expect(items.last?.transactionType == .refund)
        #expect(StatementService.parseAmount("1,234") == 1234)
        #expect(StatementService.parseAmount("1.234,56") == 1234.56)
        #expect(StatementService.parseAmount("(12.500)") == 12.5)
        let signed = StatementService.parseCSVRows("Date,Description,Amount\n2026-11-11,Refund adjustment,-5.000")
        #expect(signed.first?.isIncome == false)
    }

    @Test func feesSharingReferencesAreRetainedAndRepeatedRowsFlagged() throws {
        let date = try #require(StatementService.parseDate("2026-11-11"))
        let existing = MoneyTransaction(amount: 20, isIncome: false, merchant: "Transfer", category: .transfers, date: date, source: .bank)
        existing.smsReference = "SYNTHETIC001"
        let transfer = ParsedStatementItem(date: date, merchant: "Transfer", amount: 20, isIncome: false, reference: "SYNTHETIC001")
        let fee = ParsedStatementItem(date: date, merchant: "Bank fee", amount: 0.1, isIncome: false, reference: "SYNTHETIC001")
        let result = StatementService.flagDuplicates(in: StatementParseResult(items: [transfer, fee, fee], detectedBank: nil, format: .csv), against: [existing])
        #expect(result.items.map(\.isDuplicate) == [true, false, true])
        #expect(result.items[1].transactionType == .fee)
    }

    @Test func analysisIsReadOnlyAndConfirmedImportPreservesBalances() throws {
        let schema = DataStore.schema
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
        let context = ModelContext(container)
        let account = Account(name: "Synthetic", kind: .bank, balance: 123)
        let existing = MoneyTransaction(amount: 4, isIncome: false, merchant: "Existing", category: .other, source: .bank, accountID: account.id)
        context.insert(account); context.insert(existing); try context.save()
        let data = Data("Date,Description,Debit,Credit\n11 Nov 2026,Sample,5,0".utf8)
        _ = StatementLearningEngine.analyzeSampleStatement(fileData: data, filename: "synthetic.csv")
        let result = StatementService.parse(fileData: data, filename: "synthetic.csv", existingAccounts: [account], existingTransactions: [existing])
        #expect(try context.fetchCount(FetchDescriptor<MoneyTransaction>()) == 1)
        #expect(account.balance == 123 && existing.amount == 4)
        let imported = StatementService.importConfirmedTransactions(result.items, into: account.id, sourceBank: nil, context: context)
        #expect(imported.importedCount == 1)
        #expect(try context.fetchCount(FetchDescriptor<MoneyTransaction>()) == 2)
        #expect(account.balance == 123 && existing.amount == 4 && existing.merchant == "Existing")
    }

    @Test func malformedZIPAndUnreadablePDFFailWithoutFabricatedTransactions() {
        let invalidZip = StatementService.parse(fileData: Data([0x50,0x4b,3,4,0,0]), filename: "bad.xlsx", existingAccounts: [], existingTransactions: [])
        #expect(invalidZip.items.isEmpty)
        let pdf = PDFDocument().dataRepresentation() ?? Data()
        #expect(StatementService.parsePDF(data: pdf, accounts: []).items.isEmpty)
        #expect(BankProfileRegistry.matchProfile(for: "Unrecognized institution").profile.id == "generic")
    }

    @Test func ambiguousDatesAndQuotedDescriptionsRequireSafeReview() {
        let ambiguous = StatementService.parse(fileData: Data("Date,Description,Amount\n01/02/2026,Sample,-5".utf8), filename: "ambiguous.csv", existingAccounts: [], existingTransactions: [])
        #expect(ambiguous.items.count == 1)
        #expect(ambiguous.items.first?.isSelected == false)
        #expect(!ambiguous.inconsistencies.isEmpty)
        let quoted = StatementService.parseCSVRows("Date,Description,Debit,Credit\n2026-11-11,\"Sample \"\"Shop\"\"\nbranch\",5,0")
        #expect(quoted.count == 1)
        #expect(quoted.first?.merchant == "Sample \"Shop\" branch")
    }
}
