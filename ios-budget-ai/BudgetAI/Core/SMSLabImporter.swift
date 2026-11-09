import Compression
import Foundation

// MARK: - SMS Testing Lab · Bulk Import (TXT, CSV, TSV, Excel .xlsx & Bahrain Sample Corpus)

enum SMSImportFormat: String {
    case txt = "TXT"
    case csv = "CSV"
    case xlsx = "Excel (.xlsx)"
    case sample = "Bahrain Sample Pack"
}

struct SMSBulkImportSummary {
    var format: SMSImportFormat
    var sourceName: String
    var totalRowsRead: Int
    var importedSamples: [LabSample]
    var skippedEmptyOrDuplicate: Int
    var labeledCount: Int
    var warnings: [String] = []
}

enum SMSBulkImportError: LocalizedError {
    case unreadableFile(String)
    case invalidXLSX(String)
    case emptyContent

    var errorDescription: String? {
        switch self {
        case .unreadableFile(let m): "Could not read file: \(m)"
        case .invalidXLSX(let m): "Invalid Excel (.xlsx) file: \(m)"
        case .emptyContent: "No SMS messages were found in the provided input."
        }
    }
}

enum SMSLabImporter {

    // MARK: File / Text Entrypoints

    static func importFile(at url: URL, existingKeys: Set<String> = []) throws -> SMSBulkImportSummary {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        let ext = url.pathExtension.lowercased()
        let name = url.lastPathComponent
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw SMSBulkImportError.unreadableFile(error.localizedDescription)
        }

        if ext == "xlsx" || (data.count >= 4 && data[0] == 0x50 && data[1] == 0x4B && data[2] == 0x03 && data[3] == 0x04) {
            let rows = try XLSXReader.readRows(from: data)
            return parseTabularRows(rows, format: .xlsx, sourceName: name, existingKeys: existingKeys)
        }

        guard let text = decodeString(from: data) else {
            throw SMSBulkImportError.unreadableFile("Unsupported text encoding.")
        }

        if ext == "csv" || ext == "tsv" || looksLikeDelimitedTable(text) {
            let delimiter: Character = ext == "tsv" ? "\t" : detectDelimiter(in: text)
            let rows = parseDelimited(text, delimiter: delimiter)
            return parseTabularRows(rows, format: .csv, sourceName: name, existingKeys: existingKeys)
        }

        return try importRawText(text, sourceName: name, existingKeys: existingKeys)
    }

    static func importRawText(_ raw: String, sourceName: String = "Pasted Text", existingKeys: Set<String> = []) throws -> SMSBulkImportSummary {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw SMSBulkImportError.emptyContent }

        if looksLikeDelimitedTable(trimmed) {
            let delimiter = detectDelimiter(in: trimmed)
            let rows = parseDelimited(trimmed, delimiter: delimiter)
            if rows.count >= 2 {
                return parseTabularRows(rows, format: .csv, sourceName: sourceName, existingKeys: existingKeys)
            }
        }

        let chunks = splitBulkText(trimmed)
        guard !chunks.isEmpty else { throw SMSBulkImportError.emptyContent }

        var seen = existingKeys
        var samples: [LabSample] = []
        var skipped = 0

        for item in chunks {
            let sample = LabSample(text: item.text, sender: item.sender, source: sourceName)
            if seen.contains(sample.dedupeKey) {
                skipped += 1
                continue
            }
            seen.insert(sample.dedupeKey)
            samples.append(sample)
        }

        return SMSBulkImportSummary(
            format: .txt,
            sourceName: sourceName,
            totalRowsRead: chunks.count,
            importedSamples: samples,
            skippedEmptyOrDuplicate: skipped,
            labeledCount: 0
        )
    }

    // MARK: TXT Splitter

    /// Splits a raw TXT file into individual SMS messages.
    /// Supports:
    /// - Blank-line or `---` / `===` separated multi-line SMS blocks
    /// - One-SMS-per-line logs (when multiple lines each contain an amount or bank keyword)
    /// - Optional `Sender: <ID>` or `[<Sender>] <SMS>` prefixes
    static func splitBulkText(_ raw: String) -> [(sender: String?, text: String)] {
        let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.components(separatedBy: "\n")

        // Check if separated by explicit dividers or blank lines
        var blocks: [[String]] = []
        var current: [String] = []
        for line in lines {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty || t == "---" || t == "===" || t.hasPrefix("----") {
                if !current.isEmpty {
                    blocks.append(current)
                    current = []
                }
            } else {
                current.append(t)
            }
        }
        if !current.isEmpty { blocks.append(current) }

        // If everything landed in a single block with multiple lines, check whether each line is its own SMS
        if blocks.count == 1, let only = blocks.first, only.count > 1 {
            let singleLineLikeCount = only.filter { lineLooksStandaloneSMS($0) }.count
            if singleLineLikeCount >= max(2, Int(Double(only.count) * 0.6)) {
                blocks = only.map { [$0] }
            }
        } else if blocks.count > 1 {
            // Even when blank lines exist, a block might itself be a list of single-line SMS messages
            var expanded: [[String]] = []
            for block in blocks {
                if block.count > 2 {
                    let standalone = block.filter { lineLooksStandaloneSMS($0) }.count
                    if standalone >= Int(Double(block.count) * 0.75) {
                        expanded.append(contentsOf: block.map { [$0] })
                        continue
                    }
                }
                expanded.append(block)
            }
            blocks = expanded
        }

        return blocks.compactMap { block -> (String?, String)? in
            var lines = block
            var explicitSender: String? = nil

            if let first = lines.first {
                if let range = first.range(of: "^(?i)(?:sender|from)\\s*[:\\-]\\s*(.+)$", options: .regularExpression),
                   lines.count > 1 {
                    let header = String(first[range])
                    if let colon = header.firstIndex(where: { $0 == ":" || $0 == "-" }) {
                        explicitSender = header[header.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                        lines.removeFirst()
                    }
                }
            }

            var joined = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !joined.isEmpty else { return nil }

            // Support `[BisB] Fawri+ payment...` or `BBK | Your card...` prefix on single-line logs
            if explicitSender == nil,
               let regex = try? NSRegularExpression(pattern: "^\\[([A-Za-z0-9_+\\-\\s]{2,18})\\]\\s+(.+)$", options: [.dotMatchesLineSeparators]),
               let match = regex.firstMatch(in: joined, range: NSRange(joined.startIndex..., in: joined)),
               let r1 = Range(match.range(at: 1), in: joined),
               let r2 = Range(match.range(at: 2), in: joined) {
                explicitSender = String(joined[r1]).trimmingCharacters(in: .whitespaces)
                joined = String(joined[r2]).trimmingCharacters(in: .whitespacesAndNewlines)
            }

            return joined.isEmpty ? nil : (explicitSender, joined)
        }
    }

    private static func lineLooksStandaloneSMS(_ line: String) -> Bool {
        if SMSParser.amount(in: line) != nil { return true }
        if SMSParser.nonTransactionReason(line) != nil { return true }
        let lower = line.lowercased()
        return lower.contains("bhd") || lower.contains("fawri") || lower.contains("debited")
            || lower.contains("credited") || lower.contains("otp") || lower.contains("د.ب")
    }

    // MARK: CSV / TSV / Tabular Parser

    static func looksLikeDelimitedTable(_ text: String) -> Bool {
        let firstLine = text.prefix(500).split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let lower = firstLine.lowercased()
        let hasDelimiter = firstLine.contains(",") || firstLine.contains("\t") || firstLine.contains(";")
        guard hasDelimiter else { return false }
        let headerHints = ["sms", "message", "text", "body", "raw_sms", "sender", "expected", "bank", "amount", "category", "type"]
        return headerHints.filter { lower.contains($0) }.count >= 2
    }

    static func detectDelimiter(in text: String) -> Character {
        let sample = text.prefix(1000).split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let tabs = sample.filter { $0 == "\t" }.count
        let commas = sample.filter { $0 == "," }.count
        let semis = sample.filter { $0 == ";" }.count
        if tabs > commas && tabs > semis { return "\t" }
        if semis > commas { return ";" }
        return ","
    }

    /// RFC-4180 compliant CSV/TSV parser supporting quoted fields, escaped quotes `""`, and multi-line cells.
    static func parseDelimited(_ text: String, delimiter: Character = ",") -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        let chars = Array(text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n"))
        var i = 0

        while i < chars.count {
            let c = chars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < chars.count && chars[i + 1] == "\"" {
                        field.append("\"")
                        i += 2
                        continue
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(c)
                }
            } else {
                if c == "\"" && field.isEmpty {
                    inQuotes = true
                } else if c == delimiter {
                    row.append(field.trimmingCharacters(in: .whitespacesAndNewlines))
                    field = ""
                } else if c == "\n" {
                    row.append(field.trimmingCharacters(in: .whitespacesAndNewlines))
                    field = ""
                    if row.contains(where: { !$0.isEmpty }) {
                        rows.append(row)
                    }
                    row = []
                } else {
                    field.append(c)
                }
            }
            i += 1
        }
        if !field.isEmpty || !row.isEmpty {
            row.append(field.trimmingCharacters(in: .whitespacesAndNewlines))
            if row.contains(where: { !$0.isEmpty }) {
                rows.append(row)
            }
        }
        return rows
    }

    static func parseTabularRows(
        _ rows: [[String]],
        format: SMSImportFormat,
        sourceName: String,
        existingKeys: Set<String>
    ) -> SMSBulkImportSummary {
        guard !rows.isEmpty else {
            return SMSBulkImportSummary(format: format, sourceName: sourceName, totalRowsRead: 0, importedSamples: [], skippedEmptyOrDuplicate: 0, labeledCount: 0)
        }

        let firstRow = rows[0]
        let mapping = ColumnMapping.detect(from: firstRow)
        let dataRows = mapping.hasHeader ? Array(rows.dropFirst()) : rows

        var seen = existingKeys
        var samples: [LabSample] = []
        var skipped = 0
        var labeled = 0

        for row in dataRows {
            func cell(_ idx: Int?) -> String? {
                guard let idx, idx >= 0, idx < row.count else { return nil }
                let v = row[idx].trimmingCharacters(in: .whitespacesAndNewlines)
                return v.isEmpty ? nil : v
            }

            let smsText: String? = {
                if let idx = mapping.textCol, let v = cell(idx) { return v }
                // Fallback: pick the longest cell in the row that looks like an SMS body
                return row.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { $0.count >= 12 }
                    .max(by: { $0.count < $1.count })
            }()

            guard let text = smsText, !text.isEmpty else {
                skipped += 1
                continue
            }

            let sender = cell(mapping.senderCol)
            var expected = LabExpected()
            if let b = cell(mapping.bankCol) { expected.bank = normalizeBankName(b) }
            if let aStr = cell(mapping.amountCol), let val = Money.parse(aStr.replacingOccurrences(of: "[^0-9.,]", with: "", options: .regularExpression)) {
                expected.amount = val
            }
            if let tStr = cell(mapping.typeCol) {
                let parsedType = parseExpectedType(tStr)
                if parsedType.nonTx {
                    expected.nonTransaction = true
                } else if let t = parsedType.type {
                    expected.type = t.rawValue
                }
            }
            if let dStr = cell(mapping.directionCol), let dir = parseExpectedDirection(dStr) {
                expected.direction = dir.rawValue
            }
            if let accStr = cell(mapping.accountCol) {
                let digits = String(accStr.filter(\.isNumber).suffix(4))
                if !digits.isEmpty { expected.account = digits }
            }
            if let catStr = cell(mapping.categoryCol), let cat = parseExpectedCategory(catStr) {
                expected.category = cat.rawValue
            }
            if let nonTxStr = cell(mapping.nonTxCol) {
                let l = nonTxStr.lowercased()
                if l == "true" || l == "yes" || l == "1" || l == "skip" || l == "otp" {
                    expected.nonTransaction = true
                }
            }

            var sample = LabSample(text: text, sender: sender, source: sourceName, expected: expected)
            if let approvedStr = cell(mapping.approvedCol) {
                let l = approvedStr.lowercased()
                if l == "true" || l == "yes" || l == "1" || l == "approved" {
                    sample.isTestCase = true
                    sample.approvedAt = .now
                }
            }

            if seen.contains(sample.dedupeKey) {
                skipped += 1
                continue
            }
            seen.insert(sample.dedupeKey)
            if sample.expected.isLabeled { labeled += 1 }
            samples.append(sample)
        }

        return SMSBulkImportSummary(
            format: format,
            sourceName: sourceName,
            totalRowsRead: dataRows.count,
            importedSamples: samples,
            skippedEmptyOrDuplicate: skipped,
            labeledCount: labeled
        )
    }

    private struct ColumnMapping {
        var hasHeader = false
        var textCol: Int? = nil
        var senderCol: Int? = nil
        var bankCol: Int? = nil
        var amountCol: Int? = nil
        var typeCol: Int? = nil
        var directionCol: Int? = nil
        var accountCol: Int? = nil
        var categoryCol: Int? = nil
        var nonTxCol: Int? = nil
        var approvedCol: Int? = nil

        static func detect(from row: [String]) -> ColumnMapping {
            var m = ColumnMapping()
            for (idx, raw) in row.enumerated() {
                let h = raw.lowercased()
                    .replacingOccurrences(of: "[^a-z0-9]", with: "_", options: .regularExpression)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
                switch h {
                case "sms", "message", "text", "body", "raw_sms", "sms_text", "sms_body", "content", "msg":
                    m.textCol = idx; m.hasHeader = true
                case "sender", "from", "sender_id", "phone", "short_code", "shortcode":
                    m.senderCol = idx; m.hasHeader = true
                case "bank", "expected_bank", "institution", "bank_name":
                    m.bankCol = idx; m.hasHeader = true
                case "amount", "expected_amount", "value", "total", "amt":
                    m.amountCol = idx; m.hasHeader = true
                case "type", "transaction_type", "tx_type", "expected_type":
                    m.typeCol = idx; m.hasHeader = true
                case "direction", "expected_direction", "flow", "in_out":
                    m.directionCol = idx; m.hasHeader = true
                case "account", "expected_account", "account_suffix", "card", "last4", "card_digits", "iban_suffix":
                    m.accountCol = idx; m.hasHeader = true
                case "category", "expected_category", "spend_category", "cat":
                    m.categoryCol = idx; m.hasHeader = true
                case "non_transaction", "is_non_transaction", "skip", "ignore":
                    m.nonTxCol = idx; m.hasHeader = true
                case "approved", "is_test_case", "test_case", "locked":
                    m.approvedCol = idx; m.hasHeader = true
                default:
                    break
                }
            }
            if !m.hasHeader {
                if row.count == 1 {
                    m.textCol = 0
                } else if row.count >= 2 {
                    // Heuristic: if col 0 is short (sender) and col 1 is long (SMS)
                    if row[0].count <= 16 && row[1].count > row[0].count {
                        m.senderCol = 0
                        m.textCol = 1
                    } else {
                        m.textCol = 0
                    }
                }
            }
            return m
        }
    }

    private static func normalizeBankName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for bank in BahrainBankCatalog.bahrainBanks where SMSKnowledge.sameBank(bank, trimmed) {
            return bank
        }
        return trimmed
    }

    private static func parseExpectedType(_ raw: String) -> (type: SMSTransactionType?, nonTx: Bool) {
        let k = raw.lowercased().replacingOccurrences(of: "[\\s\\-]+", with: "_", options: .regularExpression)
        if k == "skip" || k == "non_transaction" || k == "not_a_transaction" || k == "otp" || k == "ignored" {
            return (nil, true)
        }
        if let exact = SMSTransactionType(rawValue: k) { return (exact, false) }
        switch k {
        case "debit", "purchase", "pos", "bill", "expense": return (.expense, false)
        case "credit", "salary", "deposit", "income": return (.income, false)
        case "transfer_out", "outward_transfer", "outgoing_transfer", "fawri_out": return (.transferOut, false)
        case "transfer_in", "inward_transfer", "incoming_transfer", "fawri_in": return (.transferIn, false)
        case "internal", "internal_transfer", "own_transfer": return (.internalTransfer, false)
        case "fee", "bank_fee", "charge": return (.fee, false)
        case "refund", "reversal": return (.refund, false)
        default: return (nil, false)
        }
    }

    private static func parseExpectedDirection(_ raw: String) -> SMSDirection? {
        let k = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if let exact = SMSDirection(rawValue: k) { return exact }
        switch k {
        case "in", "credit", "incoming", "received", "cr": return .incoming
        case "out", "debit", "outgoing", "sent", "paid", "dr": return .outgoing
        case "internal", "between_accounts", "self": return .internalMove
        default: return nil
        }
    }

    private static func parseExpectedCategory(_ raw: String) -> SpendCategory? {
        let k = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "[\\s\\-]+", with: "_", options: .regularExpression)
        if let exact = SpendCategory(rawValue: k) { return exact }
        return SpendCategory.allCases.first { $0.title.lowercased() == raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private static func decodeString(from data: Data) -> String? {
        for enc: String.Encoding in [.utf8, .utf16, .unicode, .windowsCP1256, .isoLatin1] {
            if let s = String(data: data, encoding: enc) { return s }
        }
        return nil
    }

    // MARK: - Curated Bahrain Multi-Bank Test Corpus

    /// Built-in realistic Bahrain bank SMS pack covering BisB, BBK, NBB, ila, Al Salam, KFH, BenefitPay, AUB, Khaleeji,
    /// plus deliberate edge cases (shortcodes, Arabic phrasing, novel merchants, and non-transaction OTPs) so developers
    /// can immediately test bulk evaluation, Expected vs Actual, Self-Learning, and Publishing.
    static func bahrainSamplePack() -> [LabSample] {
        struct Seed {
            var sender: String?
            var text: String
            var expected: LabExpected
            var approved: Bool = true
        }

        let seeds: [Seed] = [
            // 1. BisB Outgoing Fawri+
            Seed(
                sender: "BisB",
                text: "Fawri+ payment BHD3.000, ref: BIB103KAK000KZUM was credited to IBAN ending 0846 on 2026/10/27 15:26. Balance BHD263.195. Tel: 17515151",
                expected: LabExpected(bank: "BisB", amount: 3.000, type: SMSTransactionType.transferOut.rawValue, direction: SMSDirection.outgoing.rawValue, category: SpendCategory.transfers.rawValue)
            ),
            // 2. BisB POS Purchase at Lulu
            Seed(
                sender: "BisB",
                text: "Your BisB card ending 4412 was used for BHD 18.750 at LULU HYPERMARKET MANAMA on 2026/10/28 19:10. Avl Bal BHD 244.445. Tel: 17515151",
                expected: LabExpected(bank: "BisB", amount: 18.750, type: SMSTransactionType.expense.rawValue, direction: SMSDirection.outgoing.rawValue, account: "4412", category: SpendCategory.groceries.rawValue)
            ),
            // 3. BisB Visa Credit Card Payment
            Seed(
                sender: "17515151",
                text: "Dear ISA, Thank you for paying BHD 457.558 on 24/10 for your VISA INFINITE card. Available Bal BHD 5000. Tel 17515151",
                expected: LabExpected(bank: "BisB", amount: 457.558, type: SMSTransactionType.expense.rawValue, direction: SMSDirection.outgoing.rawValue, category: SpendCategory.visaTransfer.rawValue)
            ),
            // 4. BBK POS Purchase at Talabat
            Seed(
                sender: "BBK",
                text: "BBK Alert: Your debit card ending 9081 was debited for BHD 6.450 at TALABAT BAHRAIN on 29/10/2026 13:05. Available Balance: BHD 812.300. Tel 17205555",
                expected: LabExpected(bank: "BBK", amount: 6.450, type: SMSTransactionType.expense.rawValue, direction: SMSDirection.outgoing.rawValue, account: "9081", category: SpendCategory.dining.rawValue)
            ),
            // 5. BBK Incoming Fawri+
            Seed(
                sender: "BBK",
                text: "BBK: You have received a Fawri+ transfer of BHD 45.000 in your account ending 9081 from ALI AHMED on 29/10/2026 16:40. Avl Bal BHD 857.300.",
                expected: LabExpected(bank: "BBK", amount: 45.000, type: SMSTransactionType.transferIn.rawValue, direction: SMSDirection.incoming.rawValue, account: "9081", category: SpendCategory.transfers.rawValue)
            ),
            // 6. BBK Salary Credit
            Seed(
                sender: "BBK",
                text: "BBK: Salary of BHD 1,250.000 has been credited to your account ending 9081 on 28/10/2026. Available Balance is BHD 2,062.300.",
                expected: LabExpected(bank: "BBK", amount: 1250.000, type: SMSTransactionType.income.rawValue, direction: SMSDirection.incoming.rawValue, account: "9081", category: SpendCategory.income.rawValue)
            ),
            // 7. NBB Bill Payment (Batelco)
            Seed(
                sender: "NBB",
                text: "NBB: Bill payment of BHD 19.500 to BATELCO from account ending 3310 on 27/10/2026 11:20. Avl Bal: BHD 540.100. Call 17228800",
                expected: LabExpected(bank: "NBB", amount: 19.500, type: SMSTransactionType.expense.rawValue, direction: SMSDirection.outgoing.rawValue, account: "3310", category: SpendCategory.bills.rawValue)
            ),
            // 8. NBB ATM Cash Withdrawal
            Seed(
                sender: "NBB",
                text: "NBB Alert: Cash withdrawal of BHD 50.000 using card ending 3310 at NBB ATM SEEF MALL on 26/10/2026. Balance: BHD 490.100.",
                expected: LabExpected(bank: "NBB", amount: 50.000, type: SMSTransactionType.expense.rawValue, direction: SMSDirection.outgoing.rawValue, account: "3310")
            ),
            // 9. ila Bank Apple Pay Purchase (Starbucks)
            Seed(
                sender: "ila",
                text: "ila Bank: Apple Pay purchase of BHD 2.600 at STARBUCKS SEEF using card ending 7721 on 29/10/2026 08:45. Available Balance BHD 119.400. Tel 17123456",
                expected: LabExpected(bank: "ila", amount: 2.600, type: SMSTransactionType.expense.rawValue, direction: SMSDirection.outgoing.rawValue, account: "7721", category: SpendCategory.dining.rawValue)
            ),
            // 10. ila Bank Refund
            Seed(
                sender: "ila",
                text: "ila Bank: A refund of BHD 14.900 from AMAZON has been credited back to your card ending 7721 on 28/10/2026. Avl Bal BHD 134.300.",
                expected: LabExpected(bank: "ila", amount: 14.900, type: SMSTransactionType.refund.rawValue, direction: SMSDirection.incoming.rawValue, account: "7721", category: SpendCategory.shopping.rawValue)
            ),
            // 11. Al Salam Bank IBAN Outgoing Transfer
            Seed(
                sender: "Al Salam",
                text: "Fawri+ transfer of BHD 25.000 from BH69ALSA00219XXXXX5512 to IBAN ending 1190 on 29/10/2026 14:12. Balance BHD 640.000. Thank you, Al Salam Bank",
                expected: LabExpected(bank: "Al Salam", amount: 25.000, type: SMSTransactionType.transferOut.rawValue, direction: SMSDirection.outgoing.rawValue, account: "5512", category: SpendCategory.transfers.rawValue)
            ),
            // 12. KFH Arabic POS Purchase (Bapco fuel)
            Seed(
                sender: "KFH",
                text: "بيت التمويل الكويتي: تم خصم 8.500 د.ب من بطاقتك المنتهية بـ 6104 لدى BAPCO TAZWEED بتاريخ 2026/10/28. الرصيد المتاح 310.250 د.ب",
                expected: LabExpected(bank: "KFH", amount: 8.500, type: SMSTransactionType.expense.rawValue, direction: SMSDirection.outgoing.rawValue, account: "6104", category: SpendCategory.transport.rawValue)
            ),
            // 13. BenefitPay Wallet Payment
            Seed(
                sender: "BenefitPay",
                text: "BenefitPay payment of BHD 4.200 to AL JAZIRA SUPERMARKET from account ending 4412 on 28/10/2026 18:02. Ref: BP9981221. Tel 13300300",
                expected: LabExpected(bank: "BenefitPay", amount: 4.200, type: SMSTransactionType.expense.rawValue, direction: SMSDirection.outgoing.rawValue, account: "4412", category: SpendCategory.groceries.rawValue)
            ),
            // 14. Bank Fee
            Seed(
                sender: "AUB",
                text: "AUB: Service fee of BHD 1.100 has been debited from your account ending 2209 on 25/10/2026. Avl Bal BHD 980.000. Tel 17229999",
                expected: LabExpected(bank: "AUB", amount: 1.100, type: SMSTransactionType.fee.rawValue, direction: SMSDirection.outgoing.rawValue, account: "2209", category: SpendCategory.bills.rawValue)
            ),
            // 15. OTP (Non-transaction)
            Seed(
                sender: "BisB",
                text: "Your OTP for online purchase of BHD 42.000 is 839201. Do not share this code with anyone. BisB",
                expected: LabExpected(nonTransaction: true)
            ),
            // 16. Self-Learning Challenge #1: Shortcode sender `88188` without bank name in body (needs sender→bank rule for BBK)
            Seed(
                sender: "88188",
                text: "Card ending 9081 used for BHD 11.200 at CAREEM RIDE on 29/10/2026 20:15. Avl Bal BHD 801.100.",
                expected: LabExpected(bank: "BBK", amount: 11.200, type: SMSTransactionType.expense.rawValue, direction: SMSDirection.outgoing.rawValue, account: "9081", category: SpendCategory.transport.rawValue)
            ),
            // 17. Self-Learning Challenge #2: Novel local merchant `MANAMA ROASTERY` (needs keyword rule → dining)
            Seed(
                sender: "NBB",
                text: "NBB: Your card ending 3310 was used for BHD 3.800 at MANAMA ROASTERY on 29/10/2026 09:30. Avl Bal BHD 486.300.",
                expected: LabExpected(bank: "NBB", amount: 3.800, type: SMSTransactionType.expense.rawValue, direction: SMSDirection.outgoing.rawValue, account: "3310", category: SpendCategory.dining.rawValue)
            ),
            // 18. Self-Learning Challenge #3: Ambiguous compact debit alert format (needs pattern rule → expense)
            Seed(
                sender: "BisB",
                text: "BisB Alert: BHD 15.000 on card 4412 at ZARA CITY CENTRE 29/10/2026 21:00. Bal BHD 229.445.",
                expected: LabExpected(bank: "BisB", amount: 15.000, type: SMSTransactionType.expense.rawValue, direction: SMSDirection.outgoing.rawValue, account: "4412", category: SpendCategory.shopping.rawValue)
            )
        ]

        return seeds.map { s in
            LabSample(
                text: s.text,
                sender: s.sender,
                source: "Bahrain Sample Pack",
                expected: s.expected,
                isTestCase: s.approved,
                approvedAt: s.approved ? .now : nil
            )
        }
    }
}

// MARK: - Native Excel (.xlsx) Reader (Zero External Dependencies)
//
// An `.xlsx` workbook is a ZIP archive containing `xl/sharedStrings.xml` and `xl/worksheets/sheet1.xml`.
// `XLSXReader` unpacks the ZIP central directory, inflates Deflate streams via Apple's `Compression`
// framework, and parses the worksheet cells with `XMLParser`.

enum XLSXReader {
    static func readRows(from data: Data) throws -> [[String]] {
        let entries = try unzipEntries(from: data)
        guard !entries.isEmpty else {
            throw SMSBulkImportError.invalidXLSX("Archive contains no readable entries.")
        }

        let sharedStrings: [String] = {
            guard let xml = entries["xl/sharedstrings.xml"] ?? entries.first(where: { $0.key.hasSuffix("sharedstrings.xml") })?.value else {
                return []
            }
            let parser = SharedStringsParser()
            return parser.parse(xml)
        }()

        let sheetKeys = entries.keys
            .filter { $0.hasPrefix("xl/worksheets/sheet") && $0.hasSuffix(".xml") }
            .sorted()
        guard let firstSheetKey = sheetKeys.first, let sheetData = entries[firstSheetKey] else {
            throw SMSBulkImportError.invalidXLSX("No worksheet found in workbook.")
        }

        var allRows: [[String]] = []
        for key in sheetKeys {
            if let xml = entries[key] {
                let rows = WorksheetParser(sharedStrings: sharedStrings).parse(xml)
                allRows.append(contentsOf: rows)
            }
        }
        if allRows.isEmpty {
            allRows = WorksheetParser(sharedStrings: sharedStrings).parse(sheetData)
        }
        return allRows
    }

    // MARK: Minimal ZIP Unpacker

    private static func unzipEntries(from data: Data) throws -> [String: Data] {
        let bytes = [UInt8](data)
        guard bytes.count >= 22 else { throw SMSBulkImportError.invalidXLSX("File is too small to be a ZIP archive.") }

        // Find End of Central Directory (EOCD) signature 0x06054b50 scanning backwards
        var eocdOffset: Int? = nil
        let minOffset = max(0, bytes.count - 65_557)
        for idx in stride(from: bytes.count - 22, through: minOffset, by: -1) {
            if bytes[idx] == 0x50 && bytes[idx + 1] == 0x4B && bytes[idx + 2] == 0x05 && bytes[idx + 3] == 0x06 {
                eocdOffset = idx
                break
            }
        }
        guard let eocd = eocdOffset else {
            throw SMSBulkImportError.invalidXLSX("ZIP central directory not found.")
        }

        let totalEntries = Int(readUInt16(bytes, eocd + 10))
        let cdOffset = Int(readUInt32(bytes, eocd + 16))
        guard cdOffset < bytes.count else {
            throw SMSBulkImportError.invalidXLSX("Corrupt central directory offset.")
        }

        var out: [String: Data] = [:]
        var cursor = cdOffset
        for _ in 0..<totalEntries {
            guard cursor + 46 <= bytes.count,
                  bytes[cursor] == 0x50, bytes[cursor + 1] == 0x4B,
                  bytes[cursor + 2] == 0x01, bytes[cursor + 3] == 0x02 else { break }

            let method = readUInt16(bytes, cursor + 10)
            let compSize = Int(readUInt32(bytes, cursor + 20))
            let uncompSize = Int(readUInt32(bytes, cursor + 24))
            let nameLen = Int(readUInt16(bytes, cursor + 28))
            let extraLen = Int(readUInt16(bytes, cursor + 30))
            let commentLen = Int(readUInt16(bytes, cursor + 32))
            let localHeaderOffset = Int(readUInt32(bytes, cursor + 42))

            let nameStart = cursor + 46
            guard nameStart + nameLen <= bytes.count else { break }
            let name = String(bytes: bytes[nameStart..<(nameStart + nameLen)], encoding: .utf8)?.lowercased() ?? ""
            cursor = nameStart + nameLen + extraLen + commentLen

            guard name.hasSuffix(".xml"),
                  localHeaderOffset + 30 <= bytes.count,
                  bytes[localHeaderOffset] == 0x50, bytes[localHeaderOffset + 1] == 0x4B,
                  bytes[localHeaderOffset + 2] == 0x03, bytes[localHeaderOffset + 3] == 0x04 else { continue }

            let localNameLen = Int(readUInt16(bytes, localHeaderOffset + 26))
            let localExtraLen = Int(readUInt16(bytes, localHeaderOffset + 28))
            let dataStart = localHeaderOffset + 30 + localNameLen + localExtraLen
            guard dataStart + compSize <= bytes.count else { continue }

            let slice = Data(bytes[dataStart..<(dataStart + compSize)])
            if method == 0 {
                out[name] = slice
            } else if method == 8 {
                if let inflated = inflateRawDeflate(slice, expectedSize: max(uncompSize, compSize * 4)) {
                    out[name] = inflated
                }
            }
        }
        return out
    }

    private static func inflateRawDeflate(_ compressed: Data, expectedSize: Int) -> Data? {
        guard !compressed.isEmpty else { return Data() }
        var capacity = max(expectedSize + 1024, 16_384)
        for _ in 0..<4 {
            var destination = Data(count: capacity)
            let decodedBytes: Int = destination.withUnsafeMutableBytes { destPtr in
                compressed.withUnsafeBytes { srcPtr in
                    guard let dstBase = destPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                          let srcBase = srcPtr.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return 0 }
                    return compression_decode_buffer(dstBase, capacity, srcBase, compressed.count, nil, COMPRESSION_ZLIB)
                }
            }
            if decodedBytes > 0 && decodedBytes < capacity {
                destination.count = decodedBytes
                return destination
            }
            capacity *= 3
        }
        return nil
    }

    private static func readUInt16(_ b: [UInt8], _ o: Int) -> UInt16 {
        UInt16(b[o]) | (UInt16(b[o + 1]) << 8)
    }

    private static func readUInt32(_ b: [UInt8], _ o: Int) -> UInt32 {
        UInt32(b[o]) | (UInt32(b[o + 1]) << 8) | (UInt32(b[o + 2]) << 16) | (UInt32(b[o + 3]) << 24)
    }

    // MARK: XML Parsers for SharedStrings & Worksheet

    private final class SharedStringsParser: NSObject, XMLParserDelegate {
        private var strings: [String] = []
        private var currentSI = ""
        private var inSI = false
        private var inT = false

        func parse(_ data: Data) -> [String] {
            let parser = XMLParser(data: data)
            parser.delegate = self
            _ = parser.parse()
            return strings
        }

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            let local = elementName.split(separator: ":").last.map(String.init) ?? elementName
            if local == "si" {
                inSI = true
                currentSI = ""
            } else if inSI && local == "t" {
                inT = true
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if inSI && inT { currentSI += string }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            let local = elementName.split(separator: ":").last.map(String.init) ?? elementName
            if local == "t" {
                inT = false
            } else if local == "si" {
                strings.append(currentSI)
                inSI = false
            }
        }
    }

    private final class WorksheetParser: NSObject, XMLParserDelegate {
        private let sharedStrings: [String]
        private var rows: [[String]] = []
        private var currentRow: [Int: String] = [:]
        private var maxCol = -1
        private var currentColIndex = 0
        private var currentCellType = ""
        private var currentText = ""
        private var capturingValue = false

        init(sharedStrings: [String]) {
            self.sharedStrings = sharedStrings
        }

        func parse(_ data: Data) -> [[String]] {
            let parser = XMLParser(data: data)
            parser.delegate = self
            _ = parser.parse()
            return rows
        }

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            let local = elementName.split(separator: ":").last.map(String.init) ?? elementName
            switch local {
            case "row":
                currentRow = [:]
                maxCol = -1
                currentColIndex = 0
            case "c":
                if let ref = attributeDict["r"], let col = Self.columnIndex(fromCellRef: ref) {
                    currentColIndex = col
                }
                currentCellType = attributeDict["t"] ?? ""
                currentText = ""
            case "v", "t":
                capturingValue = true
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if capturingValue { currentText += string }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            let local = elementName.split(separator: ":").last.map(String.init) ?? elementName
            switch local {
            case "v", "t":
                capturingValue = false
            case "c":
                let resolved: String
                if currentCellType == "s", let idx = Int(currentText.trimmingCharacters(in: .whitespacesAndNewlines)),
                   idx >= 0 && idx < sharedStrings.count {
                    resolved = sharedStrings[idx]
                } else {
                    resolved = currentText
                }
                let trimmed = resolved.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    currentRow[currentColIndex] = trimmed
                    if currentColIndex > maxCol { maxCol = currentColIndex }
                }
                currentColIndex += 1
            case "row":
                if maxCol >= 0 {
                    let rowArray = (0...maxCol).map { currentRow[$0] ?? "" }
                    if rowArray.contains(where: { !$0.isEmpty }) {
                        rows.append(rowArray)
                    }
                }
            default:
                break
            }
        }

        private static func columnIndex(fromCellRef ref: String) -> Int? {
            let letters = ref.prefix { $0.isLetter }.uppercased()
            guard !letters.isEmpty else { return nil }
            var index = 0
            for scalar in letters.unicodeScalars {
                guard scalar.value >= 65 && scalar.value <= 90 else { return nil }
                index = index * 26 + Int(scalar.value - 64)
            }
            return index - 1
        }
    }
}
