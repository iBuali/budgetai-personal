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
            // If PDFKit couldn't find items (e.g. non-standard structure), fallback to text scan
            if result.items.isEmpty {
                let text = decodeString(from: fileData)
                let textItems = parseTextLinesToItems(text)
                if !textItems.isEmpty {
                    result.items = textItems
                }
            }
        } else if ext == "xlsx" || isZip {
            result = parseXLSX(data: fileData, accounts: existingAccounts)
            // If XLSX extraction had 0 items, fallback to XLS / CSV
            if result.items.isEmpty {
                let xlsResult = parseXLS(data: fileData, accounts: existingAccounts)
                if !xlsResult.items.isEmpty {
                    result = xlsResult
                } else {
                    let csvResult = parseCSV(data: fileData, accounts: existingAccounts)
                    if !csvResult.items.isEmpty { result = csvResult }
                }
            }
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

        // Apply duplicate detection against existing transactions
        return flagDuplicates(in: result, against: existingTransactions)
    }

    // MARK: - Duplicate Detection

    static func flagDuplicates(in result: StatementParseResult, against existing: [MoneyTransaction]) -> StatementParseResult {
        var copy = result
        for idx in copy.items.indices {
            let item = copy.items[idx]
            if let dup = findDuplicate(item, in: existing) {
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
                if itemRef.caseInsensitiveCompare(txRef) == .orderedSame {
                    return "Matched Reference \(itemRef)"
                }
            }

            // 2. Amount and Direction match
            if abs(tx.amount - item.amount) < 0.001 && tx.isIncome == item.isIncome {
                // Same calendar day
                if Calendar.current.isDate(tx.date, inSameDayAs: item.date) {
                    let cleanTx = tx.merchant.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    let cleanItem = item.merchant.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    if cleanTx == cleanItem || cleanTx.contains(cleanItem) || cleanItem.contains(cleanTx) {
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
                $0.institution.lowercased().contains(bLower) || bLower.contains($0.institution.lowercased()) ||
                $0.name.lowercased().contains(bLower) || bLower.contains($0.name.lowercased())
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

        let items = parseTextLinesToItems(fullText)

        return StatementParseResult(
            items: items,
            detectedBank: detected.bank,
            detectedAccountIBAN: detected.iban,
            detectedCardLast4: detected.cardLast4,
            matchedAccountID: matchedAcc?.id,
            format: .pdf,
            statementPeriodStart: detected.startDate,
            statementPeriodEnd: detected.endDate,
            rawTextSnippet: String(fullText.prefix(400))
        )
    }

    // MARK: - CSV & Delimited Parsing

    static func parseCSV(data: Data, accounts: [Account]) -> StatementParseResult {
        let text = decodeString(from: data)
        let detected = extractHeaderMetadata(from: text)
        let matchedAcc = matchAccount(ibanOrAcc: detected.iban, cardLast4: detected.cardLast4, bank: detected.bank, in: accounts)

        var items = parseCSVRows(text)
        if items.isEmpty {
            items = parseTextLinesToItems(text)
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
            rawTextSnippet: String(text.prefix(400))
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
            items = parseCSVRows(text)
        }

        if items.isEmpty {
            items = parseTextLinesToItems(text)
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
            rawTextSnippet: String(text.prefix(400))
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
        let sheetEntries = entries.filter { $0.key.lowercased().contains("worksheets/sheet") }
            .sorted(by: { $0.key < $1.key })

        for (_, sheetData) in sheetEntries {
            guard let sheetXml = String(data: sheetData, encoding: .utf8) else { continue }
            let rowsText = parseWorksheetXml(sheetXml, sharedStrings: sharedStrings)
            if !rowsText.isEmpty {
                combinedText += rowsText + "\n"
                let sheetItems = parseCSVRows(rowsText)
                items.append(contentsOf: sheetItems)
            }
        }

        if items.isEmpty && !combinedText.isEmpty {
            items = parseTextLinesToItems(combinedText)
        }

        let detected = extractHeaderMetadata(from: combinedText)
        let matchedAcc = matchAccount(ibanOrAcc: detected.iban, cardLast4: detected.cardLast4, bank: detected.bank, in: accounts)

        return StatementParseResult(
            items: items,
            detectedBank: detected.bank,
            detectedAccountIBAN: detected.iban,
            detectedCardLast4: detected.cardLast4,
            matchedAccountID: matchedAcc?.id,
            format: .excelXLSX,
            statementPeriodStart: detected.startDate,
            statementPeriodEnd: detected.endDate,
            rawTextSnippet: String(combinedText.prefix(400))
        )
    }

    // MARK: - Header & Bank Detection

    private static func extractHeaderMetadata(from text: String) -> (bank: String?, iban: String?, cardLast4: String?, startDate: Date?, endDate: Date?) {
        var bank: String? = nil
        var iban: String? = nil
        var cardLast4: String? = nil

        let lower = text.lowercased()

        // Bahrain & Regional Banks
        let banksCatalog = [
            ("bisb", "BisB"),
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

        // IBAN detection: e.g. BH29 ILAB 0000 0012 3438 76 or BH29ILAB00000012343876
        if let ibanRange = text.range(of: #"\b[A-Z]{2}\d{2}(?:[ ]?[A-Z0-9]{4}){2,7}(?:[ ]?[A-Z0-9]{1,4})?\b"#, options: .regularExpression) {
            let rawIban = String(text[ibanRange])
            iban = rawIban.replacingOccurrences(of: " ", with: "")
        } else if let acctRange = text.range(of: #"(?:Account|IBAN|Acc)(?:\s*(?:No|Number|#)?:?\s*)([0-9]{8,24})"#, options: [.regularExpression, .caseInsensitive]) {
            let matched = String(text[acctRange])
            iban = extractDigits(from: matched)
        }

        // Card Last 4 digits: e.g. **** 1234 or Card: ...1234 or ending in 1234
        if let cardRange = text.range(of: #"(?:Card|Credit Card|Card No)[\s\S]{0,35}?(?:[*Xx]{4,}|ending in|suffix|\.{3,})?\s*([0-9]{4})\b"#, options: [.regularExpression, .caseInsensitive]) {
            let cardMatch = String(text[cardRange])
            let digits = extractDigits(from: cardMatch)
            if digits.count >= 4 {
                cardLast4 = String(digits.suffix(4))
            }
        }

        return (bank, iban, cardLast4, nil, nil)
    }

    private static func extractDigits(from s: String) -> String {
        s.filter { $0.isNumber }
    }

    // MARK: - Multi-Strategy Text Statement Parser (PDF & Raw Text)

    static func parseTextLinesToItems(_ text: String) -> [ParsedStatementItem] {
        // Strategy 1: Multi-line Block Aggregation (handles statements where dates, descriptions, amounts span 2-6 lines)
        let blockItems = parseMultiLineBlocks(text)
        if !blockItems.isEmpty {
            return blockItems
        }

        // Strategy 2: Single-line regex matching
        let singleLineItems = parseSingleLines(text)
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

    private static func parseMultiLineBlocks(_ text: String) -> [ParsedStatementItem] {
        var items: [ParsedStatementItem] = []
        let rawLines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !isHeaderOrFooterLine($0) }

        guard !rawLines.isEmpty else { return [] }

        // Date pattern matching any date format
        let datePattern = #"\b(\d{1,4}[-/\.]\d{1,2}[-/\.]\d{1,4}|\d{1,2}[-/\. ]+(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]*[-/\. ]+\d{2,4})\b"#
        let dateRegex = try? NSRegularExpression(pattern: datePattern, options: .caseInsensitive)

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
            if let item = parseTransactionBlock(blockLines, dateRegex: dateRegex) {
                items.append(item)
            }
        }

        return items
    }

    private static func parseTransactionBlock(_ lines: [String], dateRegex: NSRegularExpression?) -> ParsedStatementItem? {
        guard let firstLine = lines.first else { return nil }

        // 1. Extract Date
        var detectedDate: Date? = nil
        var dateMatchString: String = ""

        for line in lines {
            let nsRange = NSRange(line.startIndex..., in: line)
            if let match = dateRegex?.firstMatch(in: line, range: nsRange),
               let r = Range(match.range, in: line) {
                dateMatchString = String(line[r])
                if let d = parseDate(dateMatchString) {
                    detectedDate = d
                    break
                }
            }
        }

        guard let date = detectedDate else { return nil }

        // 2. Extract Monetary Amounts across block lines
        let combinedBlock = lines.joined(separator: " ")
        let amountPattern = #"([+-]?\s*(?:BHD|BD|SAR|AED|USD|EUR|GBP|\$|€)?\s*[\d,]+\.\d{1,4}(?:\s*(?:CR|DR|Cr|Dr))?|\([\d,]+\.\d{1,4}\))"#
        let amtRegex = try? NSRegularExpression(pattern: amountPattern)
        let amtMatches = amtRegex?.matches(in: combinedBlock, range: NSRange(combinedBlock.startIndex..., in: combinedBlock)) ?? []

        guard !amtMatches.isEmpty else { return nil }

        var candidateAmountStr = ""
        var isIncome = false

        let upperBlock = combinedBlock.uppercased()
        if upperBlock.contains("CR") || upperBlock.contains("CREDIT") || upperBlock.contains("DEPOSIT") || upperBlock.contains("SALARY") || upperBlock.contains("REFUND") {
            isIncome = true
        }

        if amtMatches.count == 1 {
            candidateAmountStr = String(combinedBlock[Range(amtMatches[0].range, in: combinedBlock)!])
        } else {
            // First amount is almost universally the transaction debit or credit; second is balance
            candidateAmountStr = String(combinedBlock[Range(amtMatches[0].range, in: combinedBlock)!])
        }

        if candidateAmountStr.contains("-") || candidateAmountStr.contains("(") {
            isIncome = false
        } else if candidateAmountStr.contains("+") {
            isIncome = true
        }

        let cleanAmount = parseAmount(candidateAmountStr)
        guard cleanAmount > 0 else { return nil }

        // 3. Extract Merchant / Narrative Description
        var desc = combinedBlock
        // Remove date
        if !dateMatchString.isEmpty {
            desc = desc.replacingOccurrences(of: dateMatchString, with: " ")
        }
        // Remove amounts
        for m in amtMatches {
            if let r = Range(m.range, in: desc) {
                desc = desc.replacingCharacters(in: r, with: " ")
            }
        }

        // Clean noise tokens
        let cleanDesc = desc
            .replacingOccurrences(of: #"\b(?:CR|DR|BHD|BD|SAR|AED|USD|EUR|GBP|POS|PURCHASE|AUTH|DEBIT|CREDIT|BALANCE)\b"#, with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"[|;,\t\n\r]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " -/.:,").union(.whitespacesAndNewlines))

        guard !cleanDesc.isEmpty && cleanDesc.count >= 2 else { return nil }

        // 4. Extract Reference
        var ref: String? = nil
        if let refRange = combinedBlock.range(of: #"\b(?:REF|TRX|FT|BIB|AUTH|DOC)[#: ]*([A-Z0-9]{5,25})\b"#, options: [.regularExpression, .caseInsensitive]) {
            ref = String(combinedBlock[refRange])
        }

        // 5. Category Guessing
        let cat = Categorizer.guess(cleanDesc) ?? (isIncome ? .income : .other)

        return ParsedStatementItem(
            date: date,
            merchant: cleanDesc,
            amount: cleanAmount,
            isIncome: isIncome,
            reference: ref,
            category: cat,
            rawDescription: lines.joined(separator: " ")
        )
    }

    // MARK: - Strategy 2: Single-Line Regex Parser

    private static func parseSingleLines(_ text: String) -> [ParsedStatementItem] {
        var items: [ParsedStatementItem] = []
        let rawLines = text.components(separatedBy: .newlines)

        for line in rawLines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || isHeaderOrFooterLine(trimmed) {
                continue
            }

            if let item = parseStatementLine(trimmed) {
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
            // Find text lines between dates or adjacent
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
        if l.contains("page ") || l.contains("opening balance") || l.contains("closing balance") || l.contains("statement period") {
            return true
        }
        if l.contains("total debit") || l.contains("total credit") || l.contains("generated on") {
            return true
        }
        return false
    }

    // MARK: - Line Regex & Field Extraction

    static func parseStatementLine(_ line: String) -> ParsedStatementItem? {
        let datePattern = #"\b(\d{1,4}[-/\.]\d{1,2}[-/\.]\d{1,4}|\d{1,2}[-/\. ]+(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]*[-/\. ]+\d{2,4})\b"#

        guard let dateRange = line.range(of: datePattern, options: [.regularExpression, .caseInsensitive]) else {
            return nil
        }

        let dateStr = String(line[dateRange])
        guard let date = parseDate(dateStr) else { return nil }

        let remaining = line.replacingCharacters(in: dateRange, with: " ")

        // Amounts: Find numbers like 1,250.00, 15.500, (4.50), -4.50, 4.500 CR
        let amountPattern = #"([+-]?\s*(?:BHD|BD|SAR|AED|USD|EUR|GBP|\$)?\s*[\d,]+\.\d{1,4}(?:\s*(?:CR|DR|Cr|Dr))?|\([\d,]+\.\d{1,4}\))"#
        let regex = try? NSRegularExpression(pattern: amountPattern)
        let matches = regex?.matches(in: remaining, range: NSRange(remaining.startIndex..., in: remaining)) ?? []

        guard let firstMatch = matches.first, let range1 = Range(firstMatch.range, in: remaining) else {
            return nil
        }

        var candidateAmountStr = String(remaining[range1])
        var isIncome = false

        let upperRemaining = remaining.uppercased()
        if upperRemaining.contains("CR") || upperRemaining.contains("CREDIT") || upperRemaining.contains("DEPOSIT") || upperRemaining.contains("SALARY") || upperRemaining.contains("REFUND") {
            isIncome = true
        }

        if matches.count >= 2 {
            let m0Str = String(remaining[Range(matches[0].range, in: remaining)!])
            if upperRemaining.contains("CR") || upperRemaining.contains("CREDIT") {
                isIncome = true
            }
            candidateAmountStr = m0Str
        }

        if candidateAmountStr.contains("-") || candidateAmountStr.contains("(") {
            isIncome = false
        } else if candidateAmountStr.contains("+") {
            isIncome = true
        }

        let cleanAmount = parseAmount(candidateAmountStr)
        guard cleanAmount > 0 else { return nil }

        // Clean merchant / description text
        var desc = remaining
        for m in matches {
            if let r = Range(m.range, in: desc) {
                desc = desc.replacingCharacters(in: r, with: " ")
            }
        }
        let cleanDesc = desc
            .replacingOccurrences(of: #"\b(?:CR|DR|BHD|BD|SAR|AED|USD)\b"#, with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"[|;,]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleanDesc.isEmpty else { return nil }

        // Extract reference number
        var ref: String? = nil
        if let refRange = line.range(of: #"\b(?:REF|TRX|FT|BIB)[#: ]*([A-Z0-9]{6,25})\b"#, options: [.regularExpression, .caseInsensitive]) {
            ref = String(line[refRange])
        }

        let guessedCategory = Categorizer.guess(cleanDesc) ?? (isIncome ? .income : .other)

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

    static func parseCSVRows(_ csvText: String) -> [ParsedStatementItem] {
        var items: [ParsedStatementItem] = []
        let lines = csvText.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard lines.count >= 1 else { return [] }

        // Identify separator: tab, comma, semicolon, pipe
        let firstLine = lines.first ?? ""
        let sep: Character = {
            if firstLine.contains("\t") { return "\t" }
            if firstLine.contains(";") { return ";" }
            if firstLine.contains("|") { return "|" }
            return ","
        }()

        var headers: [String] = []
        var headerIndex = -1

        for (idx, line) in lines.enumerated() {
            let cells = splitCSVLine(line, separator: sep)
            let lowerCells = cells.map { $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
            if lowerCells.contains(where: { $0.contains("date") || $0.contains("time") }) &&
               lowerCells.contains(where: { $0.contains("amount") || $0.contains("debit") || $0.contains("credit") || $0.contains("description") || $0.contains("particular") || $0.contains("narrative") }) {
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
            dateCol = headers.firstIndex(where: { $0.contains("date") || $0.contains("time") }) ?? 0
            descCol = headers.firstIndex(where: { $0.contains("description") || $0.contains("narrative") || $0.contains("particular") || $0.contains("merchant") || $0.contains("details") || $0.contains("payee") || $0.contains("remarks") }) ?? 1
            amountCol = headers.firstIndex(where: { $0 == "amount" || $0.contains("transaction amount") || $0.contains("net amount") })
            debitCol = headers.firstIndex(where: { $0.contains("debit") || $0.contains("withdrawal") || $0.contains("paid out") || $0 == "dr" })
            creditCol = headers.firstIndex(where: { $0.contains("credit") || $0.contains("deposit") || $0.contains("paid in") || $0 == "cr" })
            refCol = headers.firstIndex(where: { $0.contains("ref") || $0.contains("cheque") || $0.contains("reference") || $0.contains("doc") })
            startRow = headerIndex + 1
        } else {
            // Headless table: heuristics
            startRow = 0
            let sampleCells = splitCSVLine(lines[0], separator: sep)
            var inferredDate = 0
            var inferredDesc = 1
            var inferredAmt: Int? = 2

            for (cIdx, cell) in sampleCells.enumerated() {
                if parseDate(cell) != nil {
                    inferredDate = cIdx
                } else if parseAmount(cell) > 0 {
                    inferredAmt = cIdx
                } else if cell.count > 3 {
                    inferredDesc = cIdx
                }
            }

            dateCol = inferredDate
            descCol = inferredDesc
            amountCol = inferredAmt
            debitCol = nil
            creditCol = nil
            refCol = nil
        }

        for i in startRow..<lines.count {
            let line = lines[i]
            if isHeaderOrFooterLine(line) { continue }
            let cells = splitCSVLine(line, separator: sep)
            guard cells.count > max(dateCol, descCol) else { continue }

            let dateRaw = cells[dateCol].trimmingCharacters(in: .whitespacesAndNewlines)
            guard let date = parseDate(dateRaw) else { continue }

            let descRaw = cells[descCol].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !descRaw.isEmpty else { continue }

            var amount: Double = 0
            var isIncome = false

            if let debitIdx = debitCol, let creditIdx = creditCol, cells.count > max(debitIdx, creditIdx) {
                let debitVal = parseAmount(cells[debitIdx])
                let creditVal = parseAmount(cells[creditIdx])
                if creditVal > 0 {
                    amount = creditVal
                    isIncome = true
                } else if debitVal > 0 {
                    amount = debitVal
                    isIncome = false
                }
            } else if let amtIdx = amountCol, cells.count > amtIdx {
                let cellVal = cells[amtIdx]
                amount = parseAmount(cellVal)
                if cellVal.contains("-") || cellVal.contains("(") || cellVal.uppercased().contains("DR") {
                    isIncome = false
                } else if cellVal.contains("+") || cellVal.uppercased().contains("CR") {
                    isIncome = true
                }
            } else {
                continue
            }

            guard amount > 0 else { continue }

            var refVal: String? = nil
            if let rIdx = refCol, cells.count > rIdx {
                let cleanR = cells[rIdx].trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleanR.isEmpty { refVal = cleanR }
            }

            let cat = Categorizer.guess(descRaw) ?? (isIncome ? .income : .other)

            items.append(ParsedStatementItem(
                date: date,
                merchant: descRaw,
                amount: amount,
                isIncome: isIncome,
                reference: refVal,
                category: cat,
                rawDescription: line
            ))
        }

        return items
    }

    private static func splitCSVLine(_ line: String, separator: Character) -> [String] {
        var fields: [String] = []
        var field = ""
        var insideQuotes = false

        for char in line {
            if char == "\"" {
                insideQuotes.toggle()
            } else if char == separator && !insideQuotes {
                fields.append(field.trimmingCharacters(in: CharacterSet(charactersIn: "\" \t")))
                field = ""
            } else {
                field.append(char)
            }
        }
        fields.append(field.trimmingCharacters(in: CharacterSet(charactersIn: "\" \t")))
        return fields
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
        var strings: [String] = []
        let siComponents = xml.components(separatedBy: "<si>")
        for si in siComponents.dropFirst() {
            // Find all <t> or <t ...>
            var text = ""
            let tComponents = si.components(separatedBy: "<t")
            for tc in tComponents.dropFirst() {
                if let close = tc.range(of: ">"), let end = tc.range(of: "</t>") {
                    text += String(tc[close.upperBound..<end.lowerBound])
                }
            }
            let clean = text
                .replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">")
                .replacingOccurrences(of: "&quot;", with: "\"")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            strings.append(clean)
        }
        return strings
    }

    private static func parseWorksheetXml(_ xml: String, sharedStrings: [String]) -> String {
        var rowLines: [String] = []
        let rowComponents = xml.components(separatedBy: "<row")

        for r in rowComponents.dropFirst() {
            var cells: [String] = []
            let cComponents = r.components(separatedBy: "<c")

            for c in cComponents.dropFirst() {
                var cellVal = ""
                let isSharedString = c.contains("t=\"s\"")
                let isInlineString = c.contains("t=\"inlineStr\"")

                if isInlineString, let start = c.range(of: "<t>"), let end = c.range(of: "</t>") {
                    cellVal = String(c[start.upperBound..<end.lowerBound])
                } else if let vStart = c.range(of: "<v>"), let vEnd = c.range(of: "</v>") {
                    let rawV = String(c[vStart.upperBound..<vEnd.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if isSharedString, let sIdx = Int(rawV), sIdx < sharedStrings.count {
                        cellVal = sharedStrings[sIdx]
                    } else {
                        // Check if rawV is an Excel serial date number e.g. 45200..46000
                        if let num = Double(rawV), num >= 35000 && num <= 65000 {
                            let timeInt = (num - 25569.0) * 86400.0
                            let d = Date(timeIntervalSince1970: timeInt)
                            let df = DateFormatter()
                            df.dateFormat = "yyyy-MM-dd"
                            df.locale = Locale(identifier: "en_US_POSIX")
                            cellVal = df.string(from: d)
                        } else {
                            cellVal = rawV
                        }
                    }
                }

                cellVal = cellVal
                    .replacingOccurrences(of: "&amp;", with: "&")
                    .replacingOccurrences(of: "&quot;", with: "\"")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                cells.append(cellVal)
            }

            if !cells.isEmpty {
                rowLines.append(cells.joined(separator: "\t"))
            }
        }

        return rowLines.joined(separator: "\n")
    }

    private static func extractZipEntries(from zipData: Data) -> [String: Data] {
        var entries: [String: Data] = [:]
        let count = zipData.count
        var offset = 0
        var iterations = 0

        while offset + 30 <= count && iterations < 500 {
            iterations += 1
            // Check for local header magic 0x04034b50 (PK\x03\x04)
            guard zipData[offset] == 0x50,
                  zipData[offset + 1] == 0x4B,
                  zipData[offset + 2] == 0x03,
                  zipData[offset + 3] == 0x04 else {
                offset += 1
                continue
            }

            let method = UInt16(zipData[offset + 8]) | (UInt16(zipData[offset + 9]) << 8)
            let compSize = Int(UInt32(zipData[offset + 18]) | (UInt32(zipData[offset + 19]) << 8) | (UInt32(zipData[offset + 20]) << 16) | (UInt32(zipData[offset + 21]) << 24))
            let uncompSize = Int(UInt32(zipData[offset + 22]) | (UInt32(zipData[offset + 23]) << 8) | (UInt32(zipData[offset + 24]) << 16) | (UInt32(zipData[offset + 25]) << 24))
            let nameLen = Int(UInt16(zipData[offset + 26]) | (UInt16(zipData[offset + 27]) << 8))
            let extraLen = Int(UInt16(zipData[offset + 28]) | (UInt16(zipData[offset + 29]) << 8))

            let nameStart = offset + 30
            let nameEnd = nameStart + nameLen
            guard nameEnd <= count else { break }

            let fileNameData = zipData.subdata(in: nameStart..<nameEnd)
            let fileName = String(data: fileNameData, encoding: .utf8) ?? String(decoding: fileNameData, as: UTF8.self)

            let dataStart = nameEnd + extraLen
            let dataEnd = dataStart + compSize

            if compSize > 0 && dataEnd <= count {
                let slice = zipData.subdata(in: dataStart..<dataEnd)
                if method == 0 {
                    // Stored uncompressed
                    entries[fileName] = slice
                } else if method == 8 {
                    // Deflate
                    #if canImport(zlib)
                    if let decompressed = decompressRawDeflate(data: slice, expectedSize: uncompSize) {
                        entries[fileName] = decompressed
                    }
                    #endif
                }
                offset = dataEnd
            } else {
                offset = dataStart
            }
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
                if bytesWritten > 0 {
                    output.append(buffer, count: bytesWritten)
                }

                if ret == Z_STREAM_END {
                    break
                }
                if ret != Z_OK && ret != Z_BUF_ERROR {
                    break
                }
                if stream.avail_in == 0 && bytesWritten == 0 {
                    break
                }
            }
            return output.isEmpty ? nil : output
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
            "MMM dd, yyyy",
            "MMM d, yyyy",
            "MMM dd yyyy",
            "MMM d yyyy",
            "dd MMMM yyyy",
            "MMMM dd, yyyy",
            "yyyyMMdd"
        ]

        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone.current

        for fmt in formats {
            df.dateFormat = fmt
            if let d = df.date(from: clean) {
                return d
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
            if parts.count == 2 && (parts[1].count == 2 || parts[1].count == 3) {
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
