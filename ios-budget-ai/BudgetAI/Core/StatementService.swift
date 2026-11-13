import Foundation
import SwiftData
import PDFKit
import UniformTypeIdentifiers
#if canImport(zlib)
import zlib
#endif

// MARK: - Statement Format & Model

enum StatementFileFormat: String, CaseIterable, Identifiable {
    case pdf = "PDF"
    case excelXLSX = "Excel (.xlsx)"
    case excelXLS = "Excel (.xls / XML)"
    case csv = "CSV / Delimited"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .pdf: return "doc.richtext"
        case .excelXLSX, .excelXLS: return "tablecells"
        case .csv: return "doc.text"
        }
    }
}

struct ParsedStatementItem: Identifiable, Hashable {
    var id: UUID = UUID()
    var date: Date
    var merchant: String
    var amount: Double
    var isIncome: Bool
    var reference: String?
    var category: SpendCategory
    var subcategoryKey: String = ""
    var rawDescription: String
    var isSelected: Bool = true
    var isDuplicate: Bool = false
    var duplicateReason: String? = nil
    var aiSuggestedCategory: Bool = false

    var transactionType: SMSTransactionType {
        let text = rawDescription.lowercased()
        if isIncome && (text.contains("refund") || text.contains("reversal")) { return .refund }
        if isIncome && (text.contains("salary") || text.contains("payroll")) { return .income }
        if text.contains(" charges") || text.contains("bank fee") || text.contains("service fee") || text.hasPrefix("vat charges") { return .fee }
        if category == .transfers || text.contains("fawri") || text.contains("transfer") || text.contains("payment received") || text.contains("credit card payment") {
            return isIncome ? .transferIn : .transferOut
        }
        return isIncome ? .income : .expense
    }

    init(
        id: UUID = UUID(),
        date: Date,
        merchant: String,
        amount: Double,
        isIncome: Bool,
        reference: String? = nil,
        category: SpendCategory = .other,
        rawDescription: String = "",
        isSelected: Bool = true,
        isDuplicate: Bool = false,
        duplicateReason: String? = nil,
        aiSuggestedCategory: Bool = false
    ) {
        self.id = id
        self.date = date
        self.merchant = merchant
        self.amount = abs(amount)
        self.isIncome = isIncome
        self.reference = reference
        self.category = category
        self.rawDescription = rawDescription.isEmpty ? merchant : rawDescription
        self.isSelected = isSelected
        self.isDuplicate = isDuplicate
        self.duplicateReason = duplicateReason
        self.aiSuggestedCategory = aiSuggestedCategory
    }
}

struct StatementParseResult {
    var items: [ParsedStatementItem]
    var detectedBank: String?
    var detectedAccountIBAN: String?
    var detectedCardLast4: String?
    var matchedAccountID: UUID?
    var format: StatementFileFormat
    var statementPeriodStart: Date?
    var statementPeriodEnd: Date?
    var rawTextSnippet: String = ""
    var profileName: String? = nil
    var confidenceScore: Double = 1.0
    var openingBalance: Double? = nil
    var closingBalance: Double? = nil
    var inconsistencies: [String] = []

    var totalItemsCount: Int { items.count }
    var newItemsCount: Int { items.filter { !$0.isDuplicate }.count }
    var duplicatesCount: Int { items.filter { $0.isDuplicate }.count }
}

// MARK: - Bank Statement Service

enum StatementService {

    // MARK: - Main Parser Entry Point

    static func parse(fileData: Data, filename: String, existingAccounts: [Account], existingTransactions: [MoneyTransaction]) -> StatementParseResult {
        let ext = (filename as NSString).pathExtension.lowercased()
        let isZip = fileData.count >= 4 && fileData[0] == 0x50 && fileData[1] == 0x4B && fileData[2] == 0x03 && fileData[3] == 0x04
        let isPDF = fileData.count >= 4 && fileData[0] == 0x25 && fileData[1] == 0x50 && fileData[2] == 0x44 && fileData[3] == 0x46

        var result: StatementParseResult

        if ext == "pdf" || isPDF {
            result = parsePDF(data: fileData, accounts: existingAccounts)
        } else if ext == "xlsx" || isZip {
            result = parseXLSX(data: fileData, accounts: existingAccounts)
        } else if ext == "xls" || ext == "xml" || ext == "html" || ext == "htm" {
            result = parseXLS(data: fileData, accounts: existingAccounts)
            if result.items.isEmpty && isZip {
                result = parseXLSX(data: fileData, accounts: existingAccounts)
            }
        } else if ext == "csv" || ext == "tsv" || ext == "txt" {
            result = parseCSV(data: fileData, accounts: existingAccounts)
            if result.items.isEmpty {
                let text = decodeString(from: fileData)
                let textItems = parseTextLinesToItems(text)
                if !textItems.isEmpty { result.items = textItems }
            }
        } else {
            // Unrecognized extension: attempt PDF, then XLSX/ZIP, then XLS/HTML, then CSV
            if isPDF || PDFDocument(data: fileData) != nil {
                result = parsePDF(data: fileData, accounts: existingAccounts)
            } else if isZip {
                result = parseXLSX(data: fileData, accounts: existingAccounts)
            } else {
                result = parseXLS(data: fileData, accounts: existingAccounts)
                if result.items.isEmpty {
                    result = parseCSV(data: fileData, accounts: existingAccounts)
                }
            }
        }

        if result.items.isEmpty && result.inconsistencies.isEmpty {
            result.inconsistencies.append("No transactions could be mapped safely. Manually map Date, Description and Debit/Credit or signed Amount columns in a CSV/Excel export.")
        }
        if result.items.contains(where: { !$0.isSelected && !$0.isDuplicate }) && result.inconsistencies.isEmpty {
            result.inconsistencies.append("The date order or column mapping is ambiguous. Manually map the columns and date format in a CSV/Excel export, or correct each row before selecting it.")
        }
        if let opening = result.openingBalance, let closing = result.closingBalance,
           !(result.profileName?.contains("Credit Card") ?? false) {
            let movement = result.items.reduce(0.0) { $0 + ($1.isIncome ? $1.amount : -$1.amount) }
            if abs(opening + movement - closing) > 0.005 {
                result.inconsistencies.append("Extracted transactions do not reconcile with the opening and closing balances. Check for missing rows or incorrect column mapping before importing.")
                for index in result.items.indices { result.items[index].isSelected = false }
            }
        }
        // Apply duplicate detection against existing transactions
        return flagDuplicates(in: result, against: existingTransactions)
    }

    // MARK: - Duplicate Detection

    static func flagDuplicates(in result: StatementParseResult, against existing: [MoneyTransaction]) -> StatementParseResult {
        var copy = result
        var consumed = Set<UUID>()
        var references = Set<String>()
        for idx in copy.items.indices {
            let item = copy.items[idx]
            copy.items[idx].isDuplicate = false
            copy.items[idx].duplicateReason = nil
            let match = existing.first { !consumed.contains($0.id) && (result.matchedAccountID == nil || $0.accountID == result.matchedAccountID) && findDuplicate(item, in: [$0]) != nil }
            var reason: String?
            if let match {
                consumed.insert(match.id)
                reason = findDuplicate(item, in: [match])
            }
            if let reference = item.reference?.trimmingCharacters(in: .whitespacesAndNewlines), !reference.isEmpty {
                let key = "\(reference.uppercased())|\(Calendar.current.startOfDay(for: item.date))|\(item.amount)|\(item.isIncome)"
                if !references.insert(key).inserted { reason = "Repeated transaction reference, date and amount in this file" }
            }
            if let dup = reason {
                copy.items[idx].isDuplicate = true
                copy.items[idx].isSelected = false // Uncheck duplicates by default to prevent re-importing
                copy.items[idx].duplicateReason = dup
            }
        }
        return copy
    }

    private static func findDuplicate(_ item: ParsedStatementItem, in existing: [MoneyTransaction]) -> String? {
        for tx in existing {
            // 1. Strict Reference match
            if let itemRef = item.reference?.trimmingCharacters(in: .whitespacesAndNewlines), !itemRef.isEmpty,
               let txRef = tx.smsReference?.trimmingCharacters(in: .whitespacesAndNewlines), !txRef.isEmpty {
                if itemRef.caseInsensitiveCompare(txRef) == .orderedSame && abs(tx.amount - item.amount) < 0.0005 && tx.isIncome == item.isIncome {
                    return "Matched Reference \(itemRef)"
                }
            }

            // 2. Amount and Direction match
            if abs(tx.amount - item.amount) < 0.001 && tx.isIncome == item.isIncome {
                // Same calendar day
                if Calendar.current.isDate(tx.date, inSameDayAs: item.date) {
                    let cleanTx = tx.merchant.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    let cleanItem = item.merchant.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    if !cleanTx.isEmpty && !cleanItem.isEmpty && cleanTx == cleanItem {
                        return "Identical amount & merchant on \(DateFormatter.localizedString(from: item.date, dateStyle: .short, timeStyle: .none))"
                    }
                }
            }
        }
        return nil
    }

    // MARK: - Account Auto-Matching

    static func matchAccount(ibanOrAcc: String?, cardLast4: String?, bank: String?, in accounts: [Account]) -> Account? {
        // 1. Match card last 4 digits
        if let card = cardLast4?.trimmingCharacters(in: .whitespacesAndNewlines), card.count >= 4 {
            let suffix = String(card.suffix(4))
            if let matched = accounts.first(where: {
                $0.kind == .creditCard && ($0.smsMatch.contains(suffix) || $0.name.contains(suffix))
            }) {
                return matched
            }
        }

        // 2. Match IBAN or account suffix
        if let iban = ibanOrAcc?.trimmingCharacters(in: .whitespacesAndNewlines), iban.count >= 4 {
            let suffix4 = String(iban.suffix(4))
            if let matched = accounts.first(where: {
                $0.smsMatch.contains(suffix4) || $0.smsMatch.contains(iban) || $0.name.contains(suffix4)
            }) {
                return matched
            }
        }

        // 3. Match Bank name / institution
        if let b = bank?.trimmingCharacters(in: .whitespacesAndNewlines), !b.isEmpty {
            let bLower = b.lowercased()
            if let matched = accounts.first(where: {
                (!$0.institution.isEmpty && ($0.institution.lowercased().contains(bLower) || bLower.contains($0.institution.lowercased()))) ||
                (!$0.name.isEmpty && ($0.name.lowercased().contains(bLower) || bLower.contains($0.name.lowercased())))
            }) {
                return matched
            }
        }

        return nil
    }

    // MARK: - PDF Parsing

    static func parsePDF(data: Data, accounts: [Account]) -> StatementParseResult {
        guard let doc = PDFDocument(data: data) else {
            return StatementParseResult(items: [], detectedBank: nil, format: .pdf)
        }

        var fullText = ""
        for i in 0..<doc.pageCount {
            if let page = doc.page(at: i), let pageString = page.string {
                fullText += pageString + "\n"
            }
        }

        let detected = extractHeaderMetadata(from: fullText)
        let matchedAcc = matchAccount(ibanOrAcc: detected.iban, cardLast4: detected.cardLast4, bank: detected.bank, in: accounts)

        let table = StatementPDFTable.extract(doc)
        var items = table.map { parseCSVRows($0, profile: detected.profile) } ?? []
        if items.isEmpty {
            items = parseTextLinesToItems(fullText, profile: detected.profile)
        }
        var issues: [String] = []
        if items.isEmpty {
            issues.append(fullText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "This PDF has no readable text or is locked. Unlock it or use an OCR/text-based PDF or Excel export."
                : "The statement columns could not be mapped safely. Please manually map Date, Description and Debit/Credit or signed Amount in a CSV/Excel export.")
        } else if table == nil {
            for index in items.indices { items[index].isSelected = false }
            issues.append("This PDF layout is unrecognized. Review each extracted date, amount and direction before selecting transactions.")
        }
        if let table, !items.isEmpty, table.components(separatedBy: "\n").count - 1 != items.count {
            issues.append("Some dated rows could not be mapped safely. Check all rows and manually map the statement columns before importing.")
            for index in items.indices { items[index].isSelected = false }
        }

        return StatementParseResult(
            items: items,
            detectedBank: detected.bank,
            detectedAccountIBAN: detected.iban,
            detectedCardLast4: detected.cardLast4,
            matchedAccountID: matchedAcc?.id,
            format: .pdf,
            statementPeriodStart: detected.startDate,
            statementPeriodEnd: detected.endDate,
            rawTextSnippet: String(fullText.prefix(400)),
            profileName: "\(detected.profile.bankName) (\(detected.profile.docType.rawValue))",
            confidenceScore: detected.confidence,
            openingBalance: detected.openingBalance,
            closingBalance: detected.closingBalance,
            inconsistencies: issues
        )
    }

    // MARK: - CSV & Delimited Parsing

    static func parseCSV(data: Data, accounts: [Account]) -> StatementParseResult {
        let text = decodeString(from: data)
        let detected = extractHeaderMetadata(from: text)
        let matchedAcc = matchAccount(ibanOrAcc: detected.iban, cardLast4: detected.cardLast4, bank: detected.bank, in: accounts)

        var items = parseCSVRows(text, profile: detected.profile)
        if items.isEmpty {
            items = parseTextLinesToItems(text, profile: detected.profile)
        }

        return StatementParseResult(
            items: items,
            detectedBank: detected.bank,
            detectedAccountIBAN: detected.iban,
            detectedCardLast4: detected.cardLast4,
            matchedAccountID: matchedAcc?.id,
            format: .csv,
            statementPeriodStart: detected.startDate,
            statementPeriodEnd: detected.endDate,
            rawTextSnippet: String(text.prefix(400)),
            profileName: "\(detected.profile.bankName) (\(detected.profile.docType.rawValue))",
            confidenceScore: detected.confidence,
            openingBalance: detected.openingBalance,
            closingBalance: detected.closingBalance
        )
    }

    // MARK: - Excel (XLS / XML / HTML) Parsing

    static func parseXLS(data: Data, accounts: [Account]) -> StatementParseResult {
        let text = decodeString(from: data)
        let detected = extractHeaderMetadata(from: text)
        let matchedAcc = matchAccount(ibanOrAcc: detected.iban, cardLast4: detected.cardLast4, bank: detected.bank, in: accounts)

        var items: [ParsedStatementItem] = []

        let lower = text.lowercased()
        if lower.contains("<table") || lower.contains("<tr") {
            // HTML table export disguised as .xls
            items = parseHTMLTable(text)
        } else if lower.contains("<workbook") || lower.contains("<row") {
            // XML Spreadsheet 2003
            items = parseXMLSpreadsheet(text)
        } else {
            // CSV / Delimited
            items = parseCSVRows(text, profile: detected.profile)
        }

        if items.isEmpty {
            items = parseTextLinesToItems(text, profile: detected.profile)
        }

        return StatementParseResult(
            items: items,
            detectedBank: detected.bank,
            detectedAccountIBAN: detected.iban,
            detectedCardLast4: detected.cardLast4,
            matchedAccountID: matchedAcc?.id,
            format: .excelXLS,
            statementPeriodStart: detected.startDate,
            statementPeriodEnd: detected.endDate,
            rawTextSnippet: String(text.prefix(400)),
            profileName: "\(detected.profile.bankName) (\(detected.profile.docType.rawValue))",
            confidenceScore: detected.confidence,
            openingBalance: detected.openingBalance,
            closingBalance: detected.closingBalance
        )
    }

    // MARK: - Excel (XLSX) OpenXML Zip Parsing

    static func parseXLSX(data: Data, accounts: [Account]) -> StatementParseResult {
        // 1. If not a ZIP file, try parsing as HTML table, XML Spreadsheet, or CSV
        let isZip = data.count >= 4 && data[0] == 0x50 && data[1] == 0x4B && data[2] == 0x03 && data[3] == 0x04
        if !isZip {
            return parseXLS(data: data, accounts: accounts)
        }

        // 2. Unpack XLSX ZIP entries
        let entries = extractZipEntries(from: data)
        var items: [ParsedStatementItem] = []
        var combinedText = ""

        // Extract Shared Strings: xl/sharedStrings.xml
        var sharedStrings: [String] = []
        if let sstData = entries.first(where: { $0.key.lowercased().contains("sharedstrings.xml") })?.value,
           let sstXml = String(data: sstData, encoding: .utf8) {
            sharedStrings = parseSharedStrings(xml: sstXml)
        }

        // Extract Worksheets: xl/worksheets/sheet1.xml (or any sheet)
        let sheetEntries = entries.filter { $0.key.lowercased().hasPrefix("xl/worksheets/") && $0.key.lowercased().hasSuffix(".xml") && !$0.key.contains("/_rels/") }
            .sorted(by: { $0.key < $1.key })

        let detectedInZip = extractHeaderMetadata(from: sharedStrings.joined(separator: " "))

        let stylesXML = entries["xl/styles.xml"].flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let dateStyles = StatementWorkbookXML.dateStyles(stylesXML)
        let workbookXML = entries["xl/workbook.xml"].flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let date1904 = ["1", "true"].contains(StatementWorkbookXML.read(workbookXML)?.descendants("workbookPr").first?.attributes["date1904"] ?? "")
        for (_, sheetData) in sheetEntries {
            guard let sheetXml = String(data: sheetData, encoding: .utf8) else { continue }
            let rowsText = StatementWorkbookXML.worksheet(sheetXml, strings: sharedStrings, dateStyles: dateStyles, date1904: date1904)
            if !rowsText.isEmpty {
                combinedText += rowsText + "\n"
                let sheetItems = parseCSVRows(rowsText, profile: extractHeaderMetadata(from: rowsText).profile)
                items.append(contentsOf: sheetItems)
            }
        }

        let detected = extractHeaderMetadata(from: combinedText.isEmpty ? sharedStrings.joined(separator: " ") : combinedText)
        if items.isEmpty && !combinedText.isEmpty {
            items = parseTextLinesToItems(combinedText, profile: detected.profile)
        }

        let finalBank = detected.bank ?? detectedInZip.bank
        let finalIban = detected.iban ?? detectedInZip.iban
        let finalCard = detected.cardLast4 ?? detectedInZip.cardLast4
        let matchedAcc = matchAccount(ibanOrAcc: finalIban, cardLast4: finalCard, bank: finalBank, in: accounts)

        return StatementParseResult(
            items: items,
            detectedBank: finalBank,
            detectedAccountIBAN: finalIban,
            detectedCardLast4: finalCard,
            matchedAccountID: matchedAcc?.id,
            format: .excelXLSX,
            statementPeriodStart: detected.startDate ?? detectedInZip.startDate,
            statementPeriodEnd: detected.endDate ?? detectedInZip.endDate,
            rawTextSnippet: String(combinedText.prefix(400)),
            profileName: "\(detected.profile.bankName) (\(detected.profile.docType.rawValue))",
            confidenceScore: max(detected.confidence, detectedInZip.confidence),
            openingBalance: detected.openingBalance ?? detectedInZip.openingBalance,
            closingBalance: detected.closingBalance ?? detectedInZip.closingBalance
        )
    }

    // MARK: - Header & Bank Detection

    private static func extractHeaderMetadata(from text: String) -> (
        bank: String?,
        iban: String?,
        cardLast4: String?,
        startDate: Date?,
        endDate: Date?,
        openingBalance: Double?,
        closingBalance: Double?,
        profile: BankProfileRule,
        confidence: Double
    ) {
        var bank: String? = nil
        var iban: String? = nil
        var cardLast4: String? = nil
        var openingBalance: Double? = nil
        var closingBalance: Double? = nil
        var startDate: Date? = nil
        var endDate: Date? = nil

        let lower = text.lowercased()

        // Match against learned bank profile registry
        let (matchedProfile, confidence) = BankProfileRegistry.matchProfile(for: text)
        if confidence >= 0.25 {
            bank = matchedProfile.bankName
        }

        // Bahrain & Regional Banks catalog fallback
        if bank == nil {
            let banksCatalog = [
                ("bisb", "BisB"),
                ("bahrain islamic bank", "BisB"),
                ("ila bank", "ila Bank"),
                ("ila", "ila Bank"),
                ("nbb", "NBB"),
                ("national bank of bahrain", "NBB"),
                ("bbk", "BBK"),
                ("bank of bahrain and kuwait", "BBK"),
                ("al salam", "Al Salam Bank"),
                ("alsalam", "Al Salam Bank"),
                ("khaleeji", "Khaleeji Bank"),
                ("kfh", "KFH"),
                ("kuwait finance house", "KFH"),
                ("ahli united", "AUB"),
                ("aub", "AUB"),
                ("standard chartered", "Standard Chartered"),
                ("hsbc", "HSBC"),
                ("benefitpay", "BenefitPay"),
                ("citi", "Citibank")
            ]

            for (pattern, name) in banksCatalog {
                if lower.contains(pattern) {
                    bank = name
                    break
                }
            }
        }

        // IBAN detection: e.g. BH85BIBB00200001693876 or BH69ALSA00219442150020
        if let ibanRange = text.range(of: #"\b[A-Z]{2}\d{2}(?:[ ]?[A-Z0-9]{4}){2,7}(?:[ ]?[A-Z0-9]{1,4})?\b"#, options: .regularExpression) {
            let rawIban = String(text[ibanRange])
            iban = rawIban.replacingOccurrences(of: " ", with: "")
        } else if let acctRange = text.range(of: #"(?:Account|IBAN|Acc)(?:\s*(?:No|Number|#)?:?\s*)([0-9]{8,24})"#, options: [.regularExpression, .caseInsensitive]) {
            let matched = String(text[acctRange])
            iban = extractDigits(from: matched)
        }

        // Card Last 4 digits detection for PDF and Excel statements
        cardLast4 = extractCardLast4(from: text)

        // Opening balance extraction
        let openPatterns = [
            #"(?:Opening|Previous|Start|Beginning)\s*Balance[^\d\n\r]*([+-]?\s*(?:BHD|BD|SAR|AED|USD|\$)?\s*[\d,]+(?:\.\d{1,4})?)"#,
            #",Opening Balance[,\s]*([+-]?\s*(?:BHD|BD|SAR|AED|USD|\$)?\s*[\d,]+(?:\.\d{1,4})?)"#
        ]
        for pat in openPatterns {
            if let range = text.range(of: pat, options: [.regularExpression, .caseInsensitive]) {
                let match = String(text[range])
                let amt = parseAmount(match)
                if amt > 0 {
                    openingBalance = amt
                    break
                }
            }
        }

        // Closing balance extraction
        let closePatterns = [
            #"(?:Closing|Ending|New|Current|Carried Forward)\s*Balance[^\d\n\r]*([+-]?\s*(?:BHD|BD|SAR|AED|USD|\$)?\s*[\d,]+(?:\.\d{1,4})?)"#,
            #",Closing Balance[,\s]*([+-]?\s*(?:BHD|BD|SAR|AED|USD|\$)?\s*[\d,]+(?:\.\d{1,4})?)"#
        ]
        for pat in closePatterns {
            if let range = text.range(of: pat, options: [.regularExpression, .caseInsensitive]) {
                let match = String(text[range])
                let amt = parseAmount(match)
                if amt > 0 {
                    closingBalance = amt
                    break
                }
            }
        }

        // Statement Period Start / End Dates
        let periodPatterns = [
            #"(?:Period|From|Statement Period)[\s:]*([0-9A-Za-z\s\-\/\.]{6,16})\s*(?:To|until|-)\s*([0-9A-Za-z\s\-\/\.]{6,16})"#,
            #"([0-9]{1,2}[-/\. ][A-Za-z]{3}[-/\. ][0-9]{2,4})\s*(?:to|-)\s*([0-9]{1,2}[-/\. ][A-Za-z]{3}[-/\. ][0-9]{2,4})"#
        ]
        for pat in periodPatterns {
            if let regex = try? NSRegularExpression(pattern: pat, options: .caseInsensitive),
               let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) {
                if let r1 = Range(match.range(at: 1), in: text), let d1 = parseDate(String(text[r1])) {
                    startDate = d1
                }
                if let r2 = Range(match.range(at: 2), in: text), let d2 = parseDate(String(text[r2])) {
                    endDate = d2
                }
                if startDate != nil { break }
            }
        }

        return (bank, iban, cardLast4, startDate, endDate, openingBalance, closingBalance, matchedProfile, confidence)
    }

    private static func extractDigits(from s: String) -> String {
        s.filter { $0.isNumber }
    }

    /// Detects and extracts the last 4 digits of a card number from PDF or Excel statement text.
    static func extractCardLast4(from text: String) -> String? {
        // 1. Explicit masked card numbers (e.g. "4545 22** **** 1843", "**** **** **** 1843", "XXXX-1843", "•••• 1843", "512345******6789")
        let maskedPatterns = [
            #"(?:\b\d{4,6}[\s\-*]*)?(?:[*Xx•]{2,4}[\s\-]?){1,3}(\d{4})\b"#,
            #"\*{2,}(\d{4})\b"#,
            #"•{2,}\s*(\d{4})\b"#
        ]
        for pattern in maskedPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: []),
               let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
               match.numberOfRanges > 1,
               let range = Range(match.range(at: 1), in: text) {
                return String(text[range])
            }
        }

        // 2. Labeled card references (e.g. "Card No: 1843", "Credit Card ending in 1843", "Card Number,**** 1843", "Visa ...1843")
        let labeledPattern = #"(?:Credit\s*Card|Debit\s*Card|Card\s*(?:No\.?|Number|#)?|Visa|Mastercard|Amex|رقم\s*البطاقة)[^\n\r]{0,45}?(?:(?:[*Xx•\.]{2,}|ending(?:\s+in)?|suffix)\s*[:#\-]?\s*|[,:\t]\s*[*Xx•\s\-]*)(\d{4})\b"#
        if let regex = try? NSRegularExpression(pattern: labeledPattern, options: [.caseInsensitive]) {
            let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            for match in matches where match.numberOfRanges > 1 {
                guard let fullRange = Range(match.range(at: 0), in: text),
                      let digitRange = Range(match.range(at: 1), in: text) else { continue }
                let fullSnippet = String(text[fullRange]).lowercased()
                let candidate = String(text[digitRange])
                // Avoid mistaking a statement year (e.g. "Credit Card Statement 2026") for a card last 4
                let hasMaskOrHint = fullSnippet.contains("*") || fullSnippet.contains("x") || fullSnippet.contains("•")
                    || fullSnippet.contains("ending") || fullSnippet.contains("suffix")
                    || fullSnippet.contains("no") || fullSnippet.contains("number") || fullSnippet.contains("#")
                if !hasMaskOrHint, let yr = Int(candidate), (2015...2039).contains(yr) {
                    continue
                }
                return candidate
            }
        }

        return nil
    }

    // MARK: - Multi-Strategy Text Statement Parser (PDF & Raw Text)

    static func parseTextLinesToItems(_ text: String, profile: BankProfileRule? = nil) -> [ParsedStatementItem] {
        // Strategy 1: Multi-line Block Aggregation (handles statements where dates, descriptions, amounts span 2-6 lines)
        let blockItems = parseMultiLineBlocks(text, profile: profile)
        if !blockItems.isEmpty {
            return blockItems
        }

        // Strategy 2: Single-line regex matching
        let singleLineItems = parseSingleLines(text, profile: profile)
        if !singleLineItems.isEmpty {
            return singleLineItems
        }

        // Strategy 3: Columnar block alignment
        let columnarItems = parseColumnarBlocks(text)
        if !columnarItems.isEmpty {
            return columnarItems
        }

        return []
    }

    // MARK: - Strategy 1: Multi-Line Transaction Block Aggregator

    private static let transactionDatePattern = #"\b(?:(?:Mon|Tue|Wed|Thu|Fri|Sat|Sun)[a-z]*,?\s+)?(?:(?:\d{1,4}[-/\.]\d{1,2}[-/\.]\d{1,4})|(?:\d{1,2}[-/\. ]+(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]*[-/\. ]+\d{2,4})|(?:(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]*[-/\. ]+\d{1,2}[, ]+\d{2,4}))\b"#
    private static let transactionAmountPattern = #"(?:\([+-]\)\s*[\d,]+(?:\.\d{1,4})?|\([+-]?\s*[\d,]+(?:\.\d{1,4})?\)|(?:BHD|BD|SAR|AED|USD|EUR|GBP|\$|â‚¬)\s*[-+]?\s*[\d,]+(?:\.\d{1,4})?(?:\s*(?:CR|DR|Cr|Dr))?|[-+]?\s*(?:BHD|BD|SAR|AED|USD|EUR|GBP|\$|â‚¬)\s*[\d,]+(?:\.\d{1,4})?(?:\s*(?:CR|DR|Cr|Dr))?|(?<![A-Za-z0-9])[+-]?\d{1,3}(?:,\d{3})*\.\d{1,4}(?![A-Za-z0-9])(?:\s*(?:CR|DR|Cr|Dr))?|(?<![A-Za-z0-9])[+-]?\d+\.\d{1,4}(?![A-Za-z0-9])(?:\s*(?:CR|DR|Cr|Dr))?|(?<![A-Za-z0-9])[+-]\d{1,6}(?![A-Za-z0-9])|(?<![A-Za-z0-9])\b\d{1,5}\b(?![A-Za-z0-9]))"#

    private static func determineIsIncome(
        amountString: String,
        lineText: String,
        profile: BankProfileRule?
    ) -> Bool {
        let upperText = lineText.uppercased()
        let upperAmt = amountString.uppercased()

        if let notation = profile?.signNotation {
            switch notation {
            case .parenthesesSigned:
                // Al Salam Bank style: (+) is Credit/Income, (-) is Debit/Expense
                if upperAmt.contains("(+)") || upperText.contains("(+)") || upperAmt.hasPrefix("+") {
                    return true
                }
                if upperAmt.contains("(-)") || upperText.contains("(-)") || upperAmt.contains("(") || upperAmt.hasPrefix("-") {
                    return false
                }
            case .creditCardNegativePayment:
                // Credit card style:
                // "PAYMENT RECEIVED" or negative amount is payment towards card (credit/income)
                if upperText.contains("PAYMENT RECEIVED") || upperText.contains("PAYMENT - THANK YOU") || upperAmt.contains("-") || upperAmt.contains("(") {
                    return true
                }
                // Purchases/debits are positive
                return false
            case .columnarDebitCredit, .standardSigned:
                break
            }
        }

        if upperAmt.contains("DR") || upperAmt.contains("(-)") || upperAmt.contains("-") || (upperAmt.contains("(") && !upperAmt.contains("(+)")) { return false }
        if upperAmt.contains("CR") || upperAmt.contains("(+)") || upperAmt.hasPrefix("+") { return true }
        if profile?.signNotation == .standardSigned { return true }

        // Generic fallback heuristics
        if upperText.contains("PAYMENT RECEIVED") || upperText.contains("SALARY") || upperText.contains("DEPOSIT") || upperText.contains("REFUND") || upperText.contains("CREDIT") || upperAmt.contains("CR") || upperAmt.contains("(+)") || upperAmt.hasPrefix("+") {
            return true
        }
        if upperAmt.contains("(-)") || upperAmt.contains("(") || upperAmt.hasPrefix("-") || upperAmt.contains("DR") || upperText.contains("DEBIT") || upperText.contains("PURCHASE") || upperText.contains("WITHDRAWAL") {
            return false
        }

        return false
    }

    private static func parseMultiLineBlocks(_ text: String, profile: BankProfileRule? = nil) -> [ParsedStatementItem] {
        var items: [ParsedStatementItem] = []
        let rawLines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !isHeaderOrFooterLine($0) }

        guard !rawLines.isEmpty else { return [] }

        let dateRegex = try? NSRegularExpression(pattern: transactionDatePattern, options: .caseInsensitive)

        // Find line indices where a date appears
        var dateLineIndices: [Int] = []
        for (idx, line) in rawLines.enumerated() {
            let nsRange = NSRange(line.startIndex..., in: line)
            if dateRegex?.firstMatch(in: line, range: nsRange) != nil {
                dateLineIndices.append(idx)
            }
        }

        guard !dateLineIndices.isEmpty else { return [] }

        // Group lines between consecutive dates into blocks
        for (i, startIdx) in dateLineIndices.enumerated() {
            let endIdx: Int
            if i + 1 < dateLineIndices.count {
                endIdx = min(dateLineIndices[i + 1], startIdx + 8)
            } else {
                endIdx = min(rawLines.count, startIdx + 8)
            }

            let blockLines = Array(rawLines[startIdx..<endIdx])
            if let item = parseTransactionBlock(blockLines, dateRegex: dateRegex, profile: profile) {
                items.append(item)
            }
        }

        return items
    }

    private static func parseTransactionBlock(_ lines: [String], dateRegex: NSRegularExpression?, profile: BankProfileRule? = nil) -> ParsedStatementItem? {
        guard !lines.isEmpty else { return nil }

        // 1. Extract Date
        var detectedDate: Date? = nil
        var dateMatchString: String = ""

        for line in lines {
            let nsRange = NSRange(line.startIndex..., in: line)
            if let match = dateRegex?.firstMatch(in: line, range: nsRange),
               let r = Range(match.range, in: line) {
                let candidateDateStr = String(line[r])
                if let d = parseDate(candidateDateStr) {
                    detectedDate = d
                    dateMatchString = candidateDateStr
                    break
                }
            }
        }

        guard let date = detectedDate else { return nil }

        // 2. Extract Monetary Amounts across block lines
        let combinedBlock = lines.joined(separator: " ")

        // Strip out all dates from textForAmounts so day numbers and years (e.g. 13, 15, 2026, 01) are not detected as amounts
        var textForAmounts = combinedBlock
        if let dRegex = try? NSRegularExpression(pattern: transactionDatePattern, options: .caseInsensitive) {
            textForAmounts = dRegex.stringByReplacingMatches(
                in: textForAmounts,
                range: NSRange(textForAmounts.startIndex..., in: textForAmounts),
                withTemplate: " "
            )
        }

        // Strip out non-monetary numeric tokens so they don't get detected as amounts:
        // - IBANs e.g. BH690000000000
        // - References e.g. FT262747PTDP
        // - MCC: 5814
        // - Card numbers e.g. 4545 22** **** 1843
        textForAmounts = textForAmounts
            .replacingOccurrences(of: #"\b[A-Z]{2}\d{10,30}\b"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\b(?:FT|BP|BIB|ALS|NBB|REF|TRX)\d+[A-Z0-9]*\b"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\b(?:Debit\s*Card|Credit\s*Card|Card)\s*(?:No\.?|#)?\s*[0-9]{4}\b"#, with: " ", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"(?:[-â€“â€”]\s*)?MCC:\s*\d{4}"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"[0-9]{4,6}\*+[0-9]{4}"#, with: " ", options: .regularExpression)

        let amtRegex = try? NSRegularExpression(pattern: transactionAmountPattern)
        let amtMatches = amtRegex?.matches(in: textForAmounts, range: NSRange(textForAmounts.startIndex..., in: textForAmounts)) ?? []

        guard !amtMatches.isEmpty else { return nil }

        // First matched amount is transaction debit or credit
        let firstMatchRange = Range(amtMatches[0].range, in: textForAmounts)!
        let candidateAmountStr = String(textForAmounts[firstMatchRange])

        let isIncome = determineIsIncome(amountString: candidateAmountStr, lineText: combinedBlock, profile: profile)
        let cleanAmount = parseAmount(candidateAmountStr)
        guard cleanAmount > 0 else { return nil }

        // 3. Extract Merchant / Narrative Description
        var desc = combinedBlock
        if let dRegex = try? NSRegularExpression(pattern: transactionDatePattern, options: .caseInsensitive) {
            desc = dRegex.stringByReplacingMatches(
                in: desc,
                range: NSRange(desc.startIndex..., in: desc),
                withTemplate: " "
            )
        }
        for m in amtMatches {
            if let r = Range(m.range, in: textForAmounts) {
                let token = String(textForAmounts[r]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !token.isEmpty {
                    desc = desc.replacingOccurrences(of: #"(?<![A-Za-z0-9])"# + NSRegularExpression.escapedPattern(for: token) + #"(?![A-Za-z0-9])"#, with: " ", options: .regularExpression)
                }
            }
        }

        // Clean merchant narrative and map category/ref via knowledge base
        let docType = profile?.docType ?? .bankAccount
        let cleaned = BankProfileRegistry.cleanMerchantDescription(desc, docType: docType)
        let merchantName = cleaned.merchant
        guard !merchantName.isEmpty && merchantName.count >= 2 else { return nil }

        // 4. Reference
        var ref = cleaned.ref
        if ref == nil, let refRange = combinedBlock.range(of: #"\b(?:REF|TRX|FT|BIB|AUTH|DOC)[#: ]*([A-Z0-9]{5,25})\b"#, options: [.regularExpression, .caseInsensitive]) {
            ref = String(combinedBlock[refRange])
        }

        // 5. Category (MCC or AI Categorizer)
        let cat = cleaned.category ?? Categorizer.guess(merchantName) ?? (isIncome ? .income : .other)

        return ParsedStatementItem(
            date: date,
            merchant: merchantName,
            amount: cleanAmount,
            isIncome: isIncome,
            reference: ref,
            category: cat,
            rawDescription: lines.joined(separator: " ")
        )
    }

    // MARK: - Strategy 2: Single-Line Regex Parser

    private static func parseSingleLines(_ text: String, profile: BankProfileRule? = nil) -> [ParsedStatementItem] {
        var items: [ParsedStatementItem] = []
        let rawLines = text.components(separatedBy: .newlines)

        for line in rawLines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || isHeaderOrFooterLine(trimmed) {
                continue
            }

            if let item = parseStatementLine(trimmed, profile: profile) {
                items.append(item)
            }
        }

        return items
    }

    // MARK: - Strategy 3: Columnar PDF Alignment

    private static func parseColumnarBlocks(_ text: String) -> [ParsedStatementItem] {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !isHeaderOrFooterLine($0) }

        guard lines.count >= 6 else { return [] }

        var dates: [(index: Int, date: Date)] = []
        var amounts: [(index: Int, amount: Double)] = []

        for (idx, line) in lines.enumerated() {
            if let d = parseDate(line) {
                dates.append((idx, d))
            } else if let num = tryExtractSingleAmount(line) {
                amounts.append((idx, num))
            }
        }

        // If equal counts of dates and amounts in distinct blocks
        guard dates.count >= 2 && dates.count == amounts.count else { return [] }

        var items: [ParsedStatementItem] = []
        for i in 0..<dates.count {
            let d = dates[i].date
            let a = amounts[i].amount
            let desc = "Transaction \(i + 1)"
            let cat = Categorizer.guess(desc) ?? .other
            items.append(ParsedStatementItem(
                date: d,
                merchant: desc,
                amount: a,
                isIncome: false,
                category: cat
            ))
        }

        return items
    }

    private static func tryExtractSingleAmount(_ line: String) -> Double? {
        let clean = line.replacingOccurrences(of: #"[^\d\.]"#, with: "", options: .regularExpression)
        guard let val = Double(clean), val > 0 else { return nil }
        return val
    }

    static func isHeaderOrFooterLine(_ line: String) -> Bool {
        let l = line.lowercased()
        if l.contains("date") && (l.contains("description") || l.contains("amount") || l.contains("particulars") || l.contains("balance")) {
            return true
        }
        if l.contains("page ") || l.contains("statement period") || l.contains("total debit") || l.contains("total credit") || l.contains("generated on") {
            return true
        }
        return false
    }

    // MARK: - Line Regex & Field Extraction

    static func parseStatementLine(_ line: String, profile: BankProfileRule? = nil) -> ParsedStatementItem? {
        guard let dateRange = line.range(of: transactionDatePattern, options: [.regularExpression, .caseInsensitive]) else {
            return nil
        }

        let dateStr = String(line[dateRange])
        guard let date = parseDate(dateStr) else { return nil }

        // Strip out all dates so day numbers and years (e.g. 13, 15, 2026, 01) are not detected as amounts
        var textForAmounts = line
        if let dRegex = try? NSRegularExpression(pattern: transactionDatePattern, options: .caseInsensitive) {
            textForAmounts = dRegex.stringByReplacingMatches(
                in: textForAmounts,
                range: NSRange(textForAmounts.startIndex..., in: textForAmounts),
                withTemplate: " "
            )
        }

        // Amounts: Find numbers like 1,250.00, 15.500, (-) 10.000, (+) 100.000, -98, 2
        textForAmounts = textForAmounts
            .replacingOccurrences(of: #"\b[A-Z]{2}\d{10,30}\b"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\b(?:FT|BP|BIB|ALS|NBB|REF|TRX)\d+[A-Z0-9]*\b"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\b(?:Debit\s*Card|Credit\s*Card|Card)\s*(?:No\.?|#)?\s*[0-9]{4}\b"#, with: " ", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"(?:[-â€“â€”]\s*)?MCC:\s*\d{4}"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"[0-9]{4,6}\*+[0-9]{4}"#, with: " ", options: .regularExpression)

        let regex = try? NSRegularExpression(pattern: transactionAmountPattern)
        let matches = regex?.matches(in: textForAmounts, range: NSRange(textForAmounts.startIndex..., in: textForAmounts)) ?? []

        guard let firstMatch = matches.first, let range1 = Range(firstMatch.range, in: textForAmounts) else {
            return nil
        }

        let candidateAmountStr = String(textForAmounts[range1])
        let isIncome = determineIsIncome(amountString: candidateAmountStr, lineText: line, profile: profile)
        let cleanAmount = parseAmount(candidateAmountStr)
        guard cleanAmount > 0 else { return nil }

        // Clean merchant / description text
        var desc = line
        if let dRegex = try? NSRegularExpression(pattern: transactionDatePattern, options: .caseInsensitive) {
            desc = dRegex.stringByReplacingMatches(
                in: desc,
                range: NSRange(desc.startIndex..., in: desc),
                withTemplate: " "
            )
        }
        for m in matches {
            if let r = Range(m.range, in: textForAmounts) {
                let token = String(textForAmounts[r]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !token.isEmpty {
                    desc = desc.replacingOccurrences(of: #"(?<![A-Za-z0-9])"# + NSRegularExpression.escapedPattern(for: token) + #"(?![A-Za-z0-9])"#, with: " ", options: .regularExpression)
                }
            }
        }

        let docType = profile?.docType ?? .bankAccount
        let cleaned = BankProfileRegistry.cleanMerchantDescription(desc, docType: docType)
        let cleanDesc = cleaned.merchant
        guard !cleanDesc.isEmpty else { return nil }

        // Extract reference number
        var ref: String? = cleaned.ref
        if ref == nil, let refRange = line.range(of: #"\b(?:REF|TRX|FT|BIB)[#: ]*([A-Z0-9]{6,25})\b"#, options: [.regularExpression, .caseInsensitive]) {
            ref = String(line[refRange])
        }

        let guessedCategory = cleaned.category ?? Categorizer.guess(cleanDesc) ?? (isIncome ? .income : .other)

        return ParsedStatementItem(
            date: date,
            merchant: cleanDesc,
            amount: cleanAmount,
            isIncome: isIncome,
            reference: ref,
            category: guessedCategory,
            rawDescription: line.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    // MARK: - CSV & Delimited Rows Parsing

    static func parseCSVRows(_ csvText: String, profile: BankProfileRule? = nil) -> [ParsedStatementItem] {
        var items: [ParsedStatementItem] = []
        // Quoted descriptions may contain line breaks. Keep them within the same record.
        var normalized = ""
        var insideQuotes = false
        for character in csvText {
            if character == "\"" { insideQuotes.toggle() }
            normalized.append(insideQuotes && (character == "\n" || character == "\r") ? " " : character)
        }
        let lines = normalized.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \r")) }
            .filter { !$0.isEmpty }
        guard lines.count >= 1 else { return [] }

        // Identify separator: tab, comma, semicolon, pipe
        let separators: [Character] = ["\t", ";", "|", ","]
        func headerScore(_ separator: Character) -> Int {
            lines.prefix(100).map { line in
                let cells = splitCSVLine(line, separator: separator).map { $0.lowercased() }
                guard cells.contains(where: { $0.contains("date") || $0.contains("time") || $0.contains("التاريخ") }),
                      cells.contains(where: {
                          $0.contains("description") || $0.contains("amount") || $0.contains("debit")
                          || $0.contains("credit") || $0.contains("details") || $0.contains("narrative")
                          || $0.contains("particular") || $0.contains("withdrawal") || $0.contains("deposit")
                          || $0.contains("merchant") || $0.contains("payee") || $0.contains("memo")
                          || $0.contains("remarks") || $0.contains("transaction") || $0.contains("الوصف") || $0.contains("المبلغ")
                      }) else { return 0 }
                return cells.count
            }.max() ?? 0
        }
        let sep: Character = {
            if let bestHeaderSep = separators.max(by: { headerScore($0) < headerScore($1) }), headerScore(bestHeaderSep) > 0 {
                return bestHeaderSep
            }
            // Headless fallback: pick the separator that splits lines into the most columns (> 1)
            return separators.max { left, right in
                let lMax = lines.prefix(30).map { splitCSVLine($0, separator: left).count }.max() ?? 0
                let rMax = lines.prefix(30).map { splitCSVLine($0, separator: right).count }.max() ?? 0
                return lMax < rMax
            } ?? ","
        }()

        var headers: [String] = []
        var headerIndex = -1

        for (idx, line) in lines.enumerated() {
            let cells = splitCSVLine(line, separator: sep)
            let lowerCells = cells.map { $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
            if lowerCells.contains(where: { $0.contains("date") || $0.contains("time") || $0.contains("التاريخ") }) &&
               lowerCells.contains(where: {
                   $0.contains("amount") || $0.contains("amt") || $0.contains("debit") || $0.contains("credit")
                   || $0.contains("description") || $0.contains("particular") || $0.contains("narrative")
                   || $0.contains("details") || $0.contains("withdrawal") || $0.contains("deposit")
                   || $0.contains("merchant") || $0.contains("payee") || $0.contains("memo")
                   || $0.contains("remarks") || $0.contains("transaction") || $0.contains("الوصف") || $0.contains("المبلغ")
               }) {
                headers = lowerCells
                headerIndex = idx
                break
            }
        }

        let dateCol: Int
        let descCol: Int
        let amountCol: Int?
        let debitCol: Int?
        let creditCol: Int?
        let refCol: Int?
        let startRow: Int

        if headerIndex != -1 && !headers.isEmpty {
            dateCol = headers.firstIndex(where: { $0.contains("date") || $0.contains("time") || $0.contains("التاريخ") }) ?? 0
            descCol = headers.firstIndex(where: {
                $0.contains("description") || $0.contains("narrative") || $0.contains("narration")
                || $0.contains("particular") || $0.contains("merchant") || $0.contains("details")
                || $0.contains("payee") || $0.contains("remarks") || $0.contains("memo")
                || $0.contains("activity") || $0.contains("summary") || $0.contains("title")
                || $0.contains("الوصف") || $0.contains("البيان") || $0.contains("التفاصيل")
                || ($0.contains("transaction") && !$0.contains("date") && !$0.contains("amount") && !$0.contains("ref"))
            }) ?? 1
            amountCol = headers.firstIndex(where: { $0.contains("amount in ") })
                ?? headers.firstIndex(where: { $0 == "amount" || $0.contains("transaction amount") || $0.contains("net amount") })
                ?? headers.firstIndex(where: { ($0.contains("amount") || $0 == "amt" || $0.contains("المبلغ")) && !$0.contains("balance") && !$0.contains("foreign") })
            debitCol = headers.firstIndex(where: {
                ($0.contains("debit") || $0.contains("withdrawal") || $0.contains("paid out") || $0.contains("outflow") || $0.contains("money out") || $0 == "dr" || $0.hasPrefix("dr ") || $0.hasSuffix(" dr") || $0.contains("مدين"))
                && !$0.contains("card")
            })
            creditCol = headers.firstIndex(where: {
                ($0.contains("credit") || $0.contains("deposit") || $0.contains("paid in") || $0.contains("inflow") || $0.contains("money in") || $0 == "cr" || $0.hasPrefix("cr ") || $0.hasSuffix(" cr") || $0.contains("دائن"))
                && !$0.contains("card")
            })
            refCol = headers.firstIndex(where: { $0.contains("ref") || $0.contains("cheque") || $0.contains("reference") || $0.contains("doc") })
            startRow = headerIndex + 1
        } else {
            // Headless table: scan lines to find the first actual transaction-like row instead of assuming lines[0]
            startRow = 0
            var inferredDate = 0
            var inferredDesc = 1
            var inferredAmt: Int? = 2

            for line in lines {
                let sampleCells = splitCSVLine(line, separator: sep)
                guard sampleCells.count >= 2 else { continue }
                var foundDate: Int? = nil
                var foundAmt: Int? = nil
                var foundDesc: Int? = nil
                for (cIdx, cell) in sampleCells.enumerated() {
                    let trimmed = cell.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { continue }
                    if foundDate == nil, parseDate(trimmed) != nil {
                        foundDate = cIdx
                    } else if parseAmount(trimmed) > 0, foundAmt == nil {
                        foundAmt = cIdx
                    } else if trimmed.count > 2, parseDate(trimmed) == nil {
                        if foundDesc == nil || trimmed.count > sampleCells[foundDesc!].count {
                            foundDesc = cIdx
                        }
                    }
                }
                if let d = foundDate, let a = foundAmt {
                    inferredDate = d
                    inferredAmt = a
                    if let desc = foundDesc { inferredDesc = desc }
                    break
                }
            }

            dateCol = inferredDate
            descCol = inferredDesc
            amountCol = inferredAmt
            debitCol = nil
            creditCol = nil
            refCol = nil
        }

        let docType = profile?.docType ?? .bankAccount

        for i in startRow..<lines.count {
            let line = lines[i]
            let lowerLine = line.lowercased()

            // Skip opening/closing balance summary rows e.g. ",Opening Balance,,,BHD 431.841"
            if lowerLine.contains("opening balance") || lowerLine.contains("closing balance") {
                continue
            }
            if isHeaderOrFooterLine(line) { continue }

            let cells = splitCSVLine(line, separator: sep)
            guard cells.indices.contains(dateCol) else { continue }

            let dateRaw = cells[dateCol].trimmingCharacters(in: .whitespacesAndNewlines)
            guard let date = parseDate(dateRaw) else { continue }

            var descRaw = cells.indices.contains(descCol) ? cells[descCol].trimmingCharacters(in: .whitespacesAndNewlines) : ""
            if descRaw.isEmpty {
                let excluded: Set<Int> = Set([dateCol, amountCol, debitCol, creditCol, refCol].compactMap { $0 })
                descRaw = cells.enumerated()
                    .filter { !excluded.contains($0.offset) }
                    .map { $0.element.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty && parseDate($0) == nil && parseAmount($0) == 0 }
                    .max(by: { $0.count < $1.count }) ?? ""
            }
            guard !descRaw.isEmpty else { continue }

            var amount: Double = 0
            var isIncome = false

            if let debitIdx = debitCol, let creditIdx = creditCol, (cells.indices.contains(debitIdx) || cells.indices.contains(creditIdx)) {
                let debitVal = cells.indices.contains(debitIdx) ? parseAmount(cells[debitIdx]) : 0
                let creditVal = cells.indices.contains(creditIdx) ? parseAmount(cells[creditIdx]) : 0
                if creditVal > 0 && debitVal > 0 { continue }
                if creditVal > 0 {
                    amount = creditVal
                    isIncome = true
                } else if debitVal > 0 {
                    amount = debitVal
                    isIncome = false
                }
            } else if let debitIdx = debitCol, cells.indices.contains(debitIdx) {
                amount = parseAmount(cells[debitIdx])
            } else if let creditIdx = creditCol, cells.indices.contains(creditIdx) {
                amount = parseAmount(cells[creditIdx])
                isIncome = true
            } else if let amtIdx = amountCol, cells.indices.contains(amtIdx) {
                let cellVal = cells[amtIdx]
                amount = parseAmount(cellVal)
                isIncome = determineIsIncome(amountString: cellVal, lineText: line, profile: profile)
            } else {
                continue
            }

            guard amount > 0 else { continue }

            var refVal: String? = nil
            if let rIdx = refCol, cells.count > rIdx {
                let cleanR = cells[rIdx].trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleanR.isEmpty { refVal = cleanR }
            }

            let cleaned = BankProfileRegistry.cleanMerchantDescription(descRaw, docType: docType)
            if refVal == nil {
                refVal = cleaned.ref
            }
            let finalMerchant = cleaned.merchant.isEmpty ? descRaw : cleaned.merchant
            let cat = cleaned.category ?? Categorizer.guess(finalMerchant) ?? (isIncome ? .income : .other)

            items.append(ParsedStatementItem(
                date: date,
                merchant: finalMerchant,
                amount: amount,
                isIncome: isIncome,
                reference: refVal,
                category: cat,
                rawDescription: line,
                isSelected: headerIndex >= 0 && !(profile?.docType == .generic && isAmbiguousNumericDate(dateRaw))
            ))
        }

        return items
    }

    private static func splitCSVLine(_ line: String, separator: Character) -> [String] {
        var fields: [String] = [], field = ""
        var quoted = false
        let chars = Array(line)
        var i = 0
        while i < chars.count {
            let char = chars[i]
            if char == "\"" {
                if quoted && i + 1 < chars.count && chars[i + 1] == "\"" { field.append("\""); i += 1 }
                else { quoted.toggle() }
            } else if char == separator && !quoted {
                fields.append(field.trimmingCharacters(in: .whitespacesAndNewlines)); field = ""
            } else { field.append(char) }
            i += 1
        }
        fields.append(field.trimmingCharacters(in: .whitespacesAndNewlines))
        return fields
    }

    private static func isAmbiguousNumericDate(_ value: String) -> Bool {
        let parts = value.components(separatedBy: CharacterSet(charactersIn: "/-."))
        guard parts.count == 3, parts[0].count <= 2,
              let first = Int(parts[0]), let second = Int(parts[1]) else { return false }
        return (1...12).contains(first) && (1...12).contains(second) && first != second
    }

    // MARK: - HTML Table Parser (.xls HTML Exports)

    static func parseHTMLTable(_ html: String) -> [ParsedStatementItem] {
        var rowLines: [String] = []

        // Extract <tr>...</tr>
        let trRegex = try? NSRegularExpression(pattern: #"<tr[^>]*>(.*?)</tr>"#, options: [.caseInsensitive, .dotMatchesLineSeparators])
        let tdRegex = try? NSRegularExpression(pattern: #"<t[dh][^>]*>(.*?)</t[dh]>"#, options: [.caseInsensitive, .dotMatchesLineSeparators])
        let tagRegex = try? NSRegularExpression(pattern: #"<[^>]+>"#)

        let nsHtml = html as NSString
        let trMatches = trRegex?.matches(in: html, range: NSRange(location: 0, length: nsHtml.length)) ?? []

        for trMatch in trMatches {
            let trContent = nsHtml.substring(with: trMatch.range(at: 1))
            let nsTr = trContent as NSString
            let tdMatches = tdRegex?.matches(in: trContent, range: NSRange(location: 0, length: nsTr.length)) ?? []

            var cells: [String] = []
            for tdMatch in tdMatches {
                var cellRaw = nsTr.substring(with: tdMatch.range(at: 1))
                // Strip HTML tags
                if let tagRegex {
                    cellRaw = tagRegex.stringByReplacingMatches(in: cellRaw, range: NSRange(location: 0, length: (cellRaw as NSString).length), withTemplate: "")
                }
                // Unescape entities
                cellRaw = cellRaw
                    .replacingOccurrences(of: "&nbsp;", with: " ")
                    .replacingOccurrences(of: "&amp;", with: "&")
                    .replacingOccurrences(of: "&#39;", with: "'")
                    .replacingOccurrences(of: "&quot;", with: "\"")
                    .replacingOccurrences(of: "&lt;", with: "<")
                    .replacingOccurrences(of: "&gt;", with: ">")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                cells.append(cellRaw)
            }

            if !cells.isEmpty {
                rowLines.append(cells.joined(separator: "\t"))
            }
        }

        return parseCSVRows(rowLines.joined(separator: "\n"))
    }

    // MARK: - XML Spreadsheet Parser (SpreadsheetML 2003)

    static func parseXMLSpreadsheet(_ xml: String) -> [ParsedStatementItem] {
        var rows: [String] = []
        let rowComponents = xml.components(separatedBy: "<Row")
        for (idx, r) in rowComponents.enumerated() {
            if idx == 0 { continue }
            var rowCells: [String] = []
            let dataComponents = r.components(separatedBy: "<Data")
            for d in dataComponents.dropFirst() {
                if let closeTag = d.range(of: ">"), let endTag = d.range(of: "</Data>") {
                    let content = String(d[closeTag.upperBound..<endTag.lowerBound])
                        .replacingOccurrences(of: "&amp;", with: "&")
                        .replacingOccurrences(of: "&quot;", with: "\"")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    rowCells.append(content)
                }
            }
            if !rowCells.isEmpty {
                rows.append(rowCells.joined(separator: "\t"))
            }
        }

        return parseCSVRows(rows.joined(separator: "\n"))
    }

    // MARK: - OpenXML (XLSX) Helpers & ZIP Extraction

    private static func parseSharedStrings(xml: String) -> [String] {
        StatementWorkbookXML.sharedStrings(xml)
    }

    private static func extractZipEntries(from zipData: Data) -> [String: Data] {
        // Read the central directory: data-descriptor ZIPs have zero sizes in local headers.
        let bytes = [UInt8](zipData)
        func u16(_ i: Int) -> Int { Int(bytes[i]) | Int(bytes[i + 1]) << 8 }
        func u32(_ i: Int) -> Int { u16(i) | u16(i + 2) << 16 }
        guard bytes.count >= 22 else { return [:] }
        var end: Int?
        for i in stride(from: bytes.count - 22, through: max(0, bytes.count - 65557), by: -1) {
            if u32(i) == 0x06054b50 && i + 22 + u16(i + 20) == bytes.count { end = i; break }
        }
        guard let end, u16(end + 4) == 0, u16(end + 6) == 0 else { return [:] }
        let entryCount = u16(end + 10)
        var offset = u32(end + 16)
        guard entryCount <= 10000, offset <= end else { return [:] }
        var entries: [String: Data] = [:]
        var expandedBytes = 0
        for _ in 0..<entryCount {
            guard offset + 46 <= end, u32(offset) == 0x02014b50 else { return [:] }
            let flags = u16(offset + 8), method = u16(offset + 10)
            let compressedSize = u32(offset + 20), size = u32(offset + 24)
            let nameLength = u16(offset + 28), extraLength = u16(offset + 30), commentLength = u16(offset + 32)
            let local = u32(offset + 42)
            let next = offset + 46 + nameLength + extraLength + commentLength
            guard next <= end, size <= 32 * 1024 * 1024, expandedBytes + size <= 64 * 1024 * 1024,
                  flags & 1 == 0, local + 30 <= bytes.count, u32(local) == 0x04034b50 else { return [:] }
            let name = String(decoding: bytes[(offset + 46)..<(offset + 46 + nameLength)], as: UTF8.self)
            let start = local + 30 + u16(local + 26) + u16(local + 28)
            guard start + compressedSize <= bytes.count else { return [:] }
            let compressed = zipData.subdata(in: start..<(start + compressedSize))
            var decoded: Data?
            if method == 0 && size == compressedSize { decoded = compressed }
            #if canImport(zlib)
            if method == 8 { decoded = decompressRawDeflate(data: compressed, expectedSize: size) }
            if let decoded {
                let checksum = decoded.withUnsafeBytes { buffer in
                    crc32(0, buffer.bindMemory(to: Bytef.self).baseAddress, uInt(decoded.count))
                }
                guard UInt32(checksum) == UInt32(u32(offset + 16)) else { return [:] }
            }
            #endif
            guard let decoded, decoded.count == size else { return [:] }
            entries[name] = decoded
            expandedBytes += size
            offset = next
        }
        return entries
    }

    #if canImport(zlib)
    private static func decompressRawDeflate(data: Data, expectedSize: Int) -> Data? {
        guard !data.isEmpty else { return Data() }

        var stream = z_stream()
        // -15 = raw deflate without zlib header
        let status = inflateInit2_(&stream, -15, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard status == Z_OK else { return nil }
        defer { inflateEnd(&stream) }

        let bufferSize = 65536
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: bufferSize)

        return data.withUnsafeBytes { (rawBuffer: UnsafeRawBufferPointer) -> Data? in
            guard let baseAddress = rawBuffer.baseAddress else { return nil }
            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: baseAddress.assumingMemoryBound(to: Bytef.self))
            stream.avail_in = uInt(data.count)

            while true {
                let ret: Int32 = buffer.withUnsafeMutableBytes { (buf: UnsafeMutableRawBufferPointer) in
                    guard let dest = buf.baseAddress else { return Z_STREAM_ERROR }
                    stream.next_out = dest.assumingMemoryBound(to: Bytef.self)
                    stream.avail_out = uInt(bufferSize)
                    return inflate(&stream, Z_NO_FLUSH)
                }

                let bytesWritten = bufferSize - Int(stream.avail_out)
                if output.count + bytesWritten > expectedSize { return nil }
                if bytesWritten > 0 {
                    output.append(buffer, count: bytesWritten)
                }

                if ret == Z_STREAM_END {
                    return output.count == expectedSize ? output : nil
                }
                if ret != Z_OK || bytesWritten == 0 {
                    return nil
                }
                if stream.avail_in == 0 && bytesWritten == 0 {
                    break
                }
            }
            return nil
        }
    }
    #endif

    // MARK: - Date & Amount Helpers

    static func parseDate(_ string: String) -> Date? {
        var clean = string.trimmingCharacters(in: .whitespacesAndNewlines)
        clean = clean.trimmingCharacters(in: CharacterSet(charactersIn: ",;:.()[]{}|"))
        guard !clean.isEmpty else { return nil }

        // Remove ordinal suffixes e.g. 1st, 2nd, 3rd, 4th -> 1, 2, 3, 4
        clean = clean.replacingOccurrences(of: #"(\d+)(?:st|nd|rd|th)\b"#, with: "$1", options: .regularExpression)

        let formats = [
            "yyyy-MM-dd",
            "yyyy/MM/dd",
            "yyyy.MM.dd",
            "dd/MM/yyyy",
            "dd-MM-yyyy",
            "dd.MM.yyyy",
            "dd MMM yyyy",
            "dd-MMM-yyyy",
            "dd.MMM.yyyy",
            "d MMM yyyy",
            "d-MMM-yyyy",
            "d.MMM.yyyy",
            "dd/MM/yy",
            "dd-MM-yy",
            "dd.MM.yy",
            "dd-MMM-yy",
            "dd MMM yy",
            "d-MMM-yy",
            "d MMM yy",
            "EEE MMM dd yyyy",
            "EEE MMM d yyyy",
            "EEE, MMM dd, yyyy",
            "EEE, MMM d, yyyy",
            "EEE dd MMM yyyy",
            "EEE, dd MMM yyyy",
            "MMM dd yyyy",
            "MMM d yyyy",
            "MMM dd, yyyy",
            "MMM d, yyyy",
            "d/M/yyyy",
            "d-M-yyyy",
            "d.M.yyyy",
            "d/M/yy",
            "d-M-yy",
            "d.M.yy",
            "MM/dd/yyyy",
            "MM-dd-yyyy",
            "MM/dd/yy",
            "MM-dd-yy",
            "M/d/yyyy",
            "M/d/yy",
            "dd MMMM yyyy",
            "MMMM dd, yyyy",
            "yyyyMMdd"
        ]

        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone.current
        df.isLenient = false
        df.calendar = Calendar(identifier: .gregorian)

        for fmt in formats {
            df.dateFormat = fmt
            if let d = df.date(from: clean), Calendar.current.component(.year, from: d) >= 1900 {
                return d
            }
        }

        // Strip day of week prefix if present (e.g. "Wed May 13 2026" or "Wed, May 13 2026")
        let dayPrefixPattern = #"^(?:Mon|Tue|Wed|Thu|Fri|Sat|Sun)[a-z]*,?\s+"#
        if let dayRange = clean.range(of: dayPrefixPattern, options: [.regularExpression, .caseInsensitive]) {
            let withoutDay = String(clean[dayRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            for fmt in formats {
                df.dateFormat = fmt
                if let d = df.date(from: withoutDay) {
                    return d
                }
            }
        }

        // Try title-cased month names
        let words = clean.components(separatedBy: CharacterSet(charactersIn: " -/."))
        if words.count >= 3 {
            let titleCased = words.map { $0.capitalized }.joined(separator: "-")
            for fmt in ["dd-MMM-yyyy", "dd-MMM-yy", "d-MMM-yyyy", "d-MMM-yy"] {
                df.dateFormat = fmt
                if let d = df.date(from: titleCased) {
                    return d
                }
            }
        }

        return nil
    }

    static func parseAmount(_ string: String) -> Double {
        var s = string.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.replacingOccurrences(of: #"[^0-9\.\,\-]"#, with: "", options: .regularExpression)
        guard !s.isEmpty else { return 0.0 }

        if s.contains(",") && s.contains(".") {
            if let commaIdx = s.lastIndex(of: ","), let dotIdx = s.lastIndex(of: ".") {
                if commaIdx > dotIdx {
                    // European format 1.250,50
                    s = s.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".")
                } else {
                    // Standard format 1,250.50
                    s = s.replacingOccurrences(of: ",", with: "")
                }
            }
        } else if s.contains(",") {
            let parts = s.components(separatedBy: ",")
            if parts.count == 2 && (parts[1].count == 1 || parts[1].count == 2) {
                s = parts[0] + "." + parts[1]
            } else {
                s = s.replacingOccurrences(of: ",", with: "")
            }
        }

        s = s.replacingOccurrences(of: "-", with: "")
        return abs(Double(s) ?? 0.0)
    }

    private static func decodeString(from data: Data) -> String {
        if let s = String(data: data, encoding: .utf8) { return s }
        if let s = String(data: data, encoding: .utf16) { return s }
        if let s = String(data: data, encoding: .isoLatin1) { return s }
        if let s = String(data: data, encoding: .windowsCP1252) { return s }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Safe Import Execution (Never Modifies Account Balances)

    /// Imports confirmed transactions into SwiftData.
    /// STRICT RULE: Never updates or modifies account balances. Only inserts into history.
    @discardableResult
    static func importConfirmedTransactions(
        _ items: [ParsedStatementItem],
        into accountID: UUID?,
        sourceBank: String?,
        context: ModelContext
    ) -> (importedCount: Int, skippedCount: Int) {
        var imported = 0
        var skipped = 0

        for item in items {
            guard item.isSelected && !item.isDuplicate else {
                skipped += 1
                continue
            }

            let tx = MoneyTransaction(
                amount: item.amount,
                isIncome: item.isIncome,
                merchant: item.merchant,
                category: item.category,
                date: item.date,
                note: item.rawDescription != item.merchant ? item.rawDescription : "",
                source: .bank,
                accountID: accountID
            )

            tx.smsBank = sourceBank
            tx.smsReference = item.reference
            tx.smsClassificationReason = "Imported from Bank Statement"
            tx.smsTransactionType = item.transactionType
            tx.isPending = false
            tx.isPossibleDuplicate = false
            tx.aiCategorized = item.aiSuggestedCategory

            // DIRECT INSERT ONLY: Do NOT call Ledger.add or Ledger.applyBalance so balances remain unchanged
            context.insert(tx)
            imported += 1
        }

        if imported > 0 {
            try? context.save()
        }

        return (imported, skipped)
    }

    // MARK: - AI Categorization Suggestion

    static func requestAICategorySuggestions(for items: [ParsedStatementItem]) async throws -> [UUID: SpendCategory] {
        let unassigned = items.filter { $0.category == .other }
        guard !unassigned.isEmpty else { return [:] }

        let merchantList = Array(Set(unassigned.map(\.merchant)))
        let categoryMap = try await AIService.categorize(merchants: merchantList)

        var result: [UUID: SpendCategory] = [:]
        for item in unassigned {
            if let suggested = categoryMap[item.merchant], suggested != .other {
                result[item.id] = suggested
            }
        }
        return result
    }
}
