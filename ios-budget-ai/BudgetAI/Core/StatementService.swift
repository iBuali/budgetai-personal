import Foundation
import SwiftData
import PDFKit
import UniformTypeIdentifiers

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
        let result: StatementParseResult

        if ext == "pdf" {
            result = parsePDF(data: fileData, accounts: existingAccounts)
        } else if ext == "xlsx" {
            result = parseXLSX(data: fileData, accounts: existingAccounts)
        } else if ext == "xls" || ext == "xml" {
            result = parseXLS(data: fileData, accounts: existingAccounts)
        } else if ext == "csv" || ext == "tsv" || ext == "txt" {
            result = parseCSV(data: fileData, accounts: existingAccounts)
        } else {
            // Attempt PDF first, then text/XML
            if let _ = PDFDocument(data: fileData) {
                result = parsePDF(data: fileData, accounts: existingAccounts)
            } else {
                result = parseCSV(data: fileData, accounts: existingAccounts)
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

        let items = parseCSVRows(text)

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

    // MARK: - Excel (XLS / XML) Parsing

    static func parseXLS(data: Data, accounts: [Account]) -> StatementParseResult {
        let text = decodeString(from: data)
        let detected = extractHeaderMetadata(from: text)
        let matchedAcc = matchAccount(ibanOrAcc: detected.iban, cardLast4: detected.cardLast4, bank: detected.bank, in: accounts)

        // Many bank .xls exports are XML Spreadsheet 2003 format
        var items: [ParsedStatementItem] = []
        if text.contains("<Workbook") || text.contains("<Row") {
            items = parseXMLSpreadsheet(text)
        } else {
            items = parseCSVRows(text)
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

    // MARK: - Excel (XLSX) OpenXML Parsing

    static func parseXLSX(data: Data, accounts: [Account]) -> StatementParseResult {
        let extractedStrings = extractStringsFromOpenXML(data: data)
        let combined = extractedStrings.joined(separator: "\n")

        let detected = extractHeaderMetadata(from: combined)
        let matchedAcc = matchAccount(ibanOrAcc: detected.iban, cardLast4: detected.cardLast4, bank: detected.bank, in: accounts)

        var items = parseTextLinesToItems(combined)
        if items.isEmpty {
            items = parseCSVRows(combined)
        }

        return StatementParseResult(
            items: items,
            detectedBank: detected.bank,
            detectedAccountIBAN: detected.iban,
            detectedCardLast4: detected.cardLast4,
            matchedAccountID: matchedAcc?.id,
            format: .excelXLSX,
            statementPeriodStart: detected.startDate,
            statementPeriodEnd: detected.endDate,
            rawTextSnippet: String(combined.prefix(400))
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

        // IBAN detection: BH\d{2}[A-Z]{4}[0-9A-Z]{14} or generic IBAN
        if let ibanRange = text.range(of: #"\b[A-Z]{2}\d{2}[A-Z0-9]{11,30}\b"#, options: .regularExpression) {
            iban = String(text[ibanRange])
        } else if let acctRange = text.range(of: #"(?:Account|IBAN|Acc)(?:\s*(?:No|Number|#)?:?\s*)([0-9]{8,24})"#, options: [.regularExpression, .caseInsensitive]) {
            let matched = String(text[acctRange])
            iban = extractDigits(from: matched)
        }

        // Card Last 4 digits: e.g. **** 1234 or Card: ...1234
        if let cardRange = text.range(of: #"(?:Card|Credit Card|Card No)[\s\S]{0,25}?(?:[*Xx]{4,}|ending in|suffix)?\s*([0-9]{4})\b"#, options: [.regularExpression, .caseInsensitive]) {
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

    // MARK: - Line-by-Line Statement Parser

    static func parseTextLinesToItems(_ text: String) -> [ParsedStatementItem] {
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
        // Date formats commonly found in bank statements:
        // 2026-10-25, 25/10/2026, 25-10-2026, 25 Oct 2026, 25-Oct-2026, 10/25/2026
        let datePattern = #"\b(\d{1,4}[-/\.]\d{1,2}[-/\.]\d{1,4}|\d{1,2}\s+(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]*\s+\d{2,4}|\d{1,2}-(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]*-\d{2,4})\b"#

        guard let dateRange = line.range(of: datePattern, options: [.regularExpression, .caseInsensitive]) else {
            return nil
        }

        let dateStr = String(line[dateRange])
        guard let date = parseDate(dateStr) else { return nil }

        // Remaining text after or around date
        let remaining = line.replacingCharacters(in: dateRange, with: " ")

        // Amounts: Find numbers like 1,250.00, 15.500, -4.50, 4.500 CR, 100.00 DR
        let amountPattern = #"([+-]?\s*(?:BHD|BD|SAR|AED|USD|EUR|GBP)?\s*[\d,]+\.\d{2,3}(?:\s*(?:CR|DR|Cr|Dr))?)"#
        let regex = try? NSRegularExpression(pattern: amountPattern)
        let matches = regex?.matches(in: remaining, range: NSRange(remaining.startIndex..., in: remaining)) ?? []

        guard let firstMatch = matches.first, let range1 = Range(firstMatch.range, in: remaining) else {
            return nil
        }

        // If multiple amounts appear on the line (e.g. Debit, Credit, Balance),
        // determine whether debit or credit has a value.
        var candidateAmountStr = String(remaining[range1])
        var isIncome = false

        if matches.count >= 2 {
            // Often columns: Debit, Credit, Balance OR Amount, Balance
            let m0Str = String(remaining[Range(matches[0].range, in: remaining)!])
            let m1Str = String(remaining[Range(matches[1].range, in: remaining)!])

            // If line contains "CR" or "CREDIT", it's income
            if remaining.uppercased().contains("CR") || remaining.uppercased().contains("CREDIT") {
                isIncome = true
                candidateAmountStr = m0Str
            } else if m0Str.contains("-") {
                isIncome = false
                candidateAmountStr = m0Str
            } else {
                candidateAmountStr = m0Str
            }
        }

        let upperRemaining = remaining.uppercased()
        if upperRemaining.contains("CR") || upperRemaining.contains("CREDIT") || upperRemaining.contains("DEPOSIT") || upperRemaining.contains("SALARY") {
            isIncome = true
        }

        let cleanAmount = parseAmount(candidateAmountStr)
        guard cleanAmount > 0 else { return nil }

        if candidateAmountStr.contains("-") {
            isIncome = false
        }

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

        // Extract reference number if present (e.g. REF: 123456 or BIB103KAK000KZUM)
        var ref: String? = nil
        if let refRange = line.range(of: #"\b(?:REF|TRX|FT|BIB)[A-Z0-9]{6,25}\b"#, options: [.regularExpression, .caseInsensitive]) {
            ref = String(line[refRange])
        }

        // Deterministic Category Guessing using Categorizer
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

    // MARK: - CSV Parsing

    static func parseCSVRows(_ csvText: String) -> [ParsedStatementItem] {
        var items: [ParsedStatementItem] = []
        let lines = csvText.components(separatedBy: .newlines)
        guard lines.count > 1 else { return [] }

        // Identify separator: comma or tab or semicolon
        let firstLine = lines.first ?? ""
        let sep: Character = firstLine.contains("\t") ? "\t" : (firstLine.contains(";") ? ";" : ",")

        var headers: [String] = []
        var headerIndex = -1

        for (idx, line) in lines.enumerated() {
            let cells = splitCSVLine(line, separator: sep)
            let lowerCells = cells.map { $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
            if lowerCells.contains(where: { $0.contains("date") }) &&
               lowerCells.contains(where: { $0.contains("amount") || $0.contains("debit") || $0.contains("description") || $0.contains("particular") }) {
                headers = lowerCells
                headerIndex = idx
                break
            }
        }

        if headerIndex == -1 || headers.isEmpty {
            // Fallback to text line parser
            return parseTextLinesToItems(csvText)
        }

        let dateCol = headers.firstIndex(where: { $0.contains("date") || $0.contains("time") }) ?? 0
        let descCol = headers.firstIndex(where: { $0.contains("description") || $0.contains("narrative") || $0.contains("particular") || $0.contains("merchant") || $0.contains("details") }) ?? 1
        let amountCol = headers.firstIndex(where: { $0 == "amount" || $0.contains("transaction amount") })
        let debitCol = headers.firstIndex(where: { $0.contains("debit") || $0.contains("withdrawal") })
        let creditCol = headers.firstIndex(where: { $0.contains("credit") || $0.contains("deposit") })
        let refCol = headers.firstIndex(where: { $0.contains("ref") || $0.contains("cheque") || $0.contains("reference") })

        for i in (headerIndex + 1)..<lines.count {
            let line = lines[i].trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
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
                } else {
                    amount = debitVal
                    isIncome = false
                }
            } else if let amtIdx = amountCol, cells.count > amtIdx {
                let cellVal = cells[amtIdx]
                amount = parseAmount(cellVal)
                if cellVal.contains("-") || cellVal.uppercased().contains("DR") {
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

    // MARK: - XML Spreadsheet Parser

    static func parseXMLSpreadsheet(_ xml: String) -> [ParsedStatementItem] {
        var rows: [String] = []
        let rowComponents = xml.components(separatedBy: "<Row")
        for (idx, r) in rowComponents.enumerated() {
            if idx == 0 { continue }
            // Extract cell Data tags: <Data ss:Type="...">value</Data>
            var rowCells: [String] = []
            let dataComponents = r.components(separatedBy: "<Data")
            for d in dataComponents.dropFirst() {
                if let closeTag = d.range(of: ">"), let endTag = d.range(of: "</Data>") {
                    let content = String(d[closeTag.upperBound..<endTag.lowerBound])
                    rowCells.append(content)
                }
            }
            if !rowCells.isEmpty {
                rows.append(rowCells.joined(separator: "\t"))
            }
        }

        return parseCSVRows(rows.joined(separator: "\n"))
    }

    // MARK: - OpenXML / XLSX String Extraction

    static func extractStringsFromOpenXML(data: Data) -> [String] {
        // XLSX files are zip archives containing xml parts (sheet1.xml, sharedStrings.xml).
        // Extract UTF-8 text strings directly from uncompressed segments and XML tags.
        let stringData = decodeString(from: data)
        var result: [String] = []

        // Extract any embedded <t>text</t> or <v>value</v> XML fragments
        let tRegex = try? NSRegularExpression(pattern: #"<(?:t|v)>(.*?)</(?:t|v)>"#)
        if let matches = tRegex?.matches(in: stringData, range: NSRange(stringData.startIndex..., in: stringData)) {
            var currentRow: [String] = []
            for m in matches {
                if let r = Range(m.range(at: 1), in: stringData) {
                    let val = String(stringData[r])
                    currentRow.append(val)
                    if currentRow.count >= 4 {
                        result.append(currentRow.joined(separator: "\t"))
                        currentRow = []
                    }
                }
            }
        }

        if result.isEmpty {
            // Scan for readable ASCII/UTF-8 strings within the binary
            result = parseTextLinesToItems(stringData).map(\.rawDescription)
        }

        return result
    }

    // MARK: - Date & Amount Helpers

    static func parseDate(_ string: String) -> Date? {
        let clean = string.trimmingCharacters(in: .whitespacesAndNewlines)
        let formats = [
            "yyyy-MM-dd",
            "dd/MM/yyyy",
            "dd-MM-yyyy",
            "MM/dd/yyyy",
            "dd.MM.yyyy",
            "dd MMM yyyy",
            "dd-MMM-yyyy",
            "yyyy/MM/dd",
            "d/M/yyyy",
            "d-M-yyyy",
            "dd-MMM-yy",
            "dd/MM/yy"
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
        return nil
    }

    static func parseAmount(_ string: String) -> Double {
        let clean = string
            .replacingOccurrences(of: #"[^0-9\.\-]"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return abs(Double(clean) ?? 0.0)
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
