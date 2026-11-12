import Foundation

// MARK: - Bank Statement Knowledge Base & Detection Engine
// STRICT ISOLATION: This engine learns structural layouts, column names, sign conventions,
// and date formats. It NEVER stores personal financial data, account numbers, or balances.

enum StatementDocType: String, Codable, CaseIterable {
    case bankAccount = "Bank Account"
    case creditCard = "Credit Card"
    case generic = "General Financial"
}

enum AmountSignNotation: String, Codable, CaseIterable {
    /// Debit column vs Credit column (e.g. BisB Bank Account, NBB)
    case columnarDebitCredit
    /// Parentheses for sign: (-) 10.000 for Debit, (+) 100.000 for Credit (e.g. Al Salam Bank)
    case parenthesesSigned
    /// Credit Card: Negative is Payment Received (Credit/Income), Positive is Purchase (Debit/Expense) (e.g. BisB Credit Card)
    case creditCardNegativePayment
    /// Standard negative minus for expense, positive for income
    case standardSigned
}

struct BankProfileRule: Codable, Identifiable {
    var id: String
    var bankName: String
    var docType: StatementDocType
    var headerKeywords: [String]
    var signNotation: AmountSignNotation
    var datePatterns: [String]
    var primaryCurrency: String
    var swiftCode: String?
    var ibanPrefix: String?
    var notes: String
    var confidenceThreshold: Double

    init(
        id: String,
        bankName: String,
        docType: StatementDocType,
        headerKeywords: [String],
        signNotation: AmountSignNotation,
        datePatterns: [String],
        primaryCurrency: String = "BHD",
        swiftCode: String? = nil,
        ibanPrefix: String? = nil,
        notes: String = "",
        confidenceThreshold: Double = 0.85
    ) {
        self.id = id
        self.bankName = bankName
        self.docType = docType
        self.headerKeywords = headerKeywords
        self.signNotation = signNotation
        self.datePatterns = datePatterns
        self.primaryCurrency = primaryCurrency
        self.swiftCode = swiftCode
        self.ibanPrefix = ibanPrefix
        self.notes = notes
        self.confidenceThreshold = confidenceThreshold
    }
}

// MARK: - Structural Analysis Report

struct StatementAnalysisReport {
    var profile: BankProfileRule
    var confidenceScore: Double
    var detectedBank: String
    var detectedDocType: StatementDocType
    var detectedIBAN: String?
    var detectedCardLast4: String?
    var detectedDatesCount: Int
    var detectedTransactionsCount: Int
    var totalDebits: Double
    var totalCredits: Double
    var openingBalance: Double?
    var closingBalance: Double?
    var balanceReconciled: Bool?
    var inconsistencies: [String]
    var samplePreview: [ParsedStatementItem]
}

// MARK: - Bank Profile Registry & Learning Engine

enum BankProfileRegistry {

    private static let userProfilesKey = "budgetai_learned_bank_profiles_v1"

    // Built-in Knowledge Base learned from real Bahrain and Regional bank statements
    static var builtInProfiles: [BankProfileRule] {
        [
            // 1. BisB Bank Account Statement (CSV, Excel, PDF)
            BankProfileRule(
                id: "bisb_account",
                bankName: "BisB",
                docType: .bankAccount,
                headerKeywords: ["bisb", "bahrain islamic bank", "bibbbhbminv", "account statement", "building 722, al salam tower"],
                signNotation: .columnarDebitCredit,
                datePatterns: ["dd MMM yy", "dd MMM yyyy", "dd/MM/yyyy"],
                primaryCurrency: "BHD",
                swiftCode: "BIBBBHBMINV",
                ibanPrefix: "BH85BIBB",
                notes: "Columnar Debit/Credit. Amounts prefixed with 'BHD '. Row dates in 'dd MMM yy' format."
            ),

            // 2. BisB Credit Card Statement (PDF, Excel)
            BankProfileRule(
                id: "bisb_credit_card",
                bankName: "BisB",
                docType: .creditCard,
                headerKeywords: ["credit card statement", "bisb", "visa infinite", "card holder name", "total credit limit"],
                signNotation: .creditCardNegativePayment,
                datePatterns: ["EEE MMM dd yyyy", "MMM dd yyyy", "dd MMM yyyy"],
                primaryCurrency: "BHD",
                swiftCode: "BIBBBHBMINV",
                notes: "Credit card billing. Negative amount (e.g. -98) = Payment Received (Credit). Positive = Purchase (Debit). Includes MCC codes."
            ),

            // 3. Al Salam Bank Statement (PDF, Text)
            BankProfileRule(
                id: "alsalam_account",
                bankName: "Al Salam Bank",
                docType: .bankAccount,
                headerKeywords: ["al salam bank", "alsabhbm", "statement of account", "saving deposit"],
                signNotation: .parenthesesSigned,
                datePatterns: ["dd MMM yyyy", "dd-MMM-yyyy", "dd/MM/yyyy"],
                primaryCurrency: "BHD",
                swiftCode: "ALSABHBM",
                ibanPrefix: "BH69ALSA",
                notes: "Debits formatted with '(-) 10.000', Credits with '(+) 100.000'. Value date column present."
            ),

            // 4. ila Bank (CSV, PDF, Excel)
            BankProfileRule(
                id: "ila_bank",
                bankName: "ila Bank",
                docType: .bankAccount,
                headerKeywords: ["ila bank", "ilab", "bank abc"],
                signNotation: .columnarDebitCredit,
                datePatterns: ["yyyy-MM-dd", "dd/MM/yyyy"],
                primaryCurrency: "BHD",
                swiftCode: "ILABBHBM",
                ibanPrefix: "BH29ILAB",
                notes: "Standard ISO dates and columnar debit/credit."
            ),

            // 5. NBB (National Bank of Bahrain)
            BankProfileRule(
                id: "nbb_account",
                bankName: "NBB",
                docType: .bankAccount,
                headerKeywords: ["national bank of bahrain", "nbb", "nbobbhbm"],
                signNotation: .columnarDebitCredit,
                datePatterns: ["dd-MMM-yyyy", "dd/MM/yyyy", "dd MMM yyyy"],
                primaryCurrency: "BHD",
                swiftCode: "NBOBBHBM",
                ibanPrefix: "BH68NBOB",
                notes: "Columnar Debit and Credit amounts with transaction references."
            ),

            // 6. BBK (Bank of Bahrain and Kuwait)
            BankProfileRule(
                id: "bbk_account",
                bankName: "BBK",
                docType: .bankAccount,
                headerKeywords: ["bank of bahrain and kuwait", "bbk", "bbkubhbm"],
                signNotation: .columnarDebitCredit,
                datePatterns: ["dd/MM/yyyy", "dd-MM-yyyy"],
                primaryCurrency: "BHD",
                swiftCode: "BBKUBHBM",
                ibanPrefix: "BH56BBKU",
                notes: "Standard British/Bahrain date notation with debit/credit columns."
            )
        ]
    }

    /// Returns active rules combining built-ins and any learned custom patterns
    static var allProfiles: [BankProfileRule] {
        var profiles = builtInProfiles
        let custom = loadUserLearnedProfiles()
        for c in custom {
            if let idx = profiles.firstIndex(where: { $0.id == c.id }) {
                profiles[idx] = c
            } else {
                profiles.append(c)
            }
        }
        return profiles
    }

    // MARK: - Profile Matching

    static func matchProfile(for text: String) -> (profile: BankProfileRule, confidence: Double) {
        let lower = text.lowercased()
        var bestProfile: BankProfileRule = builtInProfiles[0]
        var highestScore: Double = 0.0

        for p in allProfiles {
            var score = 0.0
            var matchedKeywords = 0

            for kw in p.headerKeywords {
                if lower.contains(kw) {
                    matchedKeywords += 1
                }
            }

            if matchedKeywords > 0 {
                score += Double(matchedKeywords) / Double(p.headerKeywords.count) * 0.70
            }

            if let swift = p.swiftCode?.lowercased(), lower.contains(swift) {
                score += 0.20
            }

            if let iban = p.ibanPrefix?.lowercased(), lower.contains(iban) {
                score += 0.15
            }

            // Document type reinforcement
            if p.docType == .creditCard && (lower.contains("credit card") || lower.contains("card holder") || lower.contains("total credit limit")) {
                score += 0.15
            } else if p.docType == .bankAccount && (lower.contains("account statement") || lower.contains("statement of account") || lower.contains("saving deposit") || lower.contains("current account")) {
                score += 0.10
            }

            if score > highestScore {
                highestScore = score
                bestProfile = p
            }
        }

        let normalizedScore = min(1.0, highestScore)
        return (bestProfile, normalizedScore)
    }

    // MARK: - MCC Code Intelligent Category Mapper

    static func categoryForMCC(_ mcc: String) -> SpendCategory? {
        switch mcc {
        case "5411", "5422", "5499", "5441":
            return .groceries
        case "5812", "5814":
            return .dining
        case "5541", "5542":
            return .transport
        case "4111", "4121", "7523":
            return .transport
        case "5651", "5691", "5311", "5399", "5722", "5977":
            return .shopping
        case "8011", "8021", "8062", "5912":
            return .health
        case "4814", "4900":
            return .bills
        case "7832", "7922", "7999":
            return .entertainment
        case "6011", "6051", "0000":
            return .transfers
        default:
            return nil
        }
    }

    // MARK: - Narrative & Description Cleaner

    static func cleanMerchantDescription(_ raw: String, docType: StatementDocType) -> (merchant: String, category: SpendCategory?, ref: String?) {
        var clean = raw
        var extractedRef: String? = nil
        var inferredCategory: SpendCategory? = nil

        // 1. Extract MCC code if present (e.g. MCC: 5411 or MCC: 5814)
        if let mccRange = clean.range(of: #"MCC:\s*([0-9]{4})"#, options: .regularExpression) {
            let matched = String(clean[mccRange])
            let digits = matched.filter { $0.isNumber }
            inferredCategory = categoryForMCC(digits)
            clean = clean.replacingCharacters(in: mccRange, with: " ")
        }

        // 2. Extract Fawri / Fawateer / Reference tags
        if let refRange = clean.range(of: #"\b(?:BP[0-9]+[A-Z0-9]+|FT[0-9]+[A-Z0-9]+|ALS[0-9]+[A-Z0-9]+|BIB[0-9]+[A-Z0-9]+|NBB[0-9]+[A-Z0-9]+|KHC[0-9]+[A-Z0-9]+|ABCO[0-9]+)\b"#, options: .regularExpression) {
            extractedRef = String(clean[refRange])
            clean = clean.replacingCharacters(in: refRange, with: " ")
        }

        // 3. Strip FX rates, BD values, masked card numbers, charges
        clean = clean
            .replacingOccurrences(of: #"\$\s*Rate\s*=\s*[0-9\.]+,?\s*BD\s*Value\s*=\s*[0-9\.]+,?\s*FX\s*Rate\s*=\s*[0-9\%]+,?\s*FX\s*Value\s*=\s*[0-9\.]+"#, with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"[0-9]{4,6}\*+[0-9]{4}"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\b(?:Commission Amount|VAT Amount|VAT charges)\b[\s\S]*"#, with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"FAWRI\+\s*Payment\s*to\s+[A-Z0-9]+-[0-9]+"#, with: "Fawri+ Transfer", options: .regularExpression)
            .replacingOccurrences(of: #"FAWRI\+\s*Payment\s*From\s+IBAN:\s+[A-Z0-9]+-[0-9]+"#, with: "Fawri+ Received", options: .regularExpression)
            .replacingOccurrences(of: #"FAWATEER\s+([A-Za-z0-9 ]+?)\s+[0-9]+.*"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"Purchases\s*&\s*Services-\s*"#, with: "", options: .caseInsensitive)
            .replacingOccurrences(of: #"POS\s*PURCHASE\s*(?:AFS\s*Acquiring\s*ONUS,?)?\s*"#, with: "", options: .caseInsensitive)
            .replacingOccurrences(of: #"ATM\s*WITHDRAWAL\s*(?:BENEFIT\s*ATM\s*PAY\s*ACCOUNT,?)?\s*"#, with: "ATM Cash Withdrawal ", options: .caseInsensitive)
            .replacingOccurrences(of: #"Direct\s*Debit\s*-\s*EFTS\s*ASB\s*EFTS\s*Inward\s*DNS,?"#, with: "Utility Direct Debit", options: .caseInsensitive)
            .replacingOccurrences(of: #"[|;,\t\n\r]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " -/.:,").union(.whitespacesAndNewlines))

        // Fallback merchant name if all got trimmed
        if clean.isEmpty {
            clean = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return (clean, inferredCategory, extractedRef)
    }

    // MARK: - Learned User Profiles Storage

    static func loadUserLearnedProfiles() -> [BankProfileRule] {
        guard let data = UserDefaults.standard.data(forKey: userProfilesKey),
              let list = try? JSONDecoder().decode([BankProfileRule].self, from: data) else {
            return []
        }
        return list
    }

    static func saveLearnedProfile(_ profile: BankProfileRule) {
        var existing = loadUserLearnedProfiles()
        if let idx = existing.firstIndex(where: { $0.id == profile.id }) {
            existing[idx] = profile
        } else {
            existing.append(profile)
        }
        if let encoded = try? JSONEncoder().encode(existing) {
            UserDefaults.standard.set(encoded, forKey: userProfilesKey)
        }
    }
}

// MARK: - Safe Statement Learning & Diagnostic Engine
// STRICT ISOLATION: Runs detection tests and computes reconciliations without saving to user data or modifying balances.

enum StatementLearningEngine {

    /// Analyzes a sample statement file without touching or modifying any user account or database.
    /// Returns a full structural diagnostic report including detected bank, document type,
    /// IBAN/card numbers, profile confidence, transaction count, totals, balance reconciliation, and inconsistencies.
    static func analyzeSampleStatement(fileData: Data, filename: String) -> StatementAnalysisReport {
        let lower = filename.lowercased()
        let isPdf = lower.hasSuffix(".pdf") || (fileData.count >= 4 && fileData[0] == 0x25 && fileData[1] == 0x50 && fileData[2] == 0x44 && fileData[3] == 0x46)
        let isXlsx = lower.hasSuffix(".xlsx") || (fileData.count >= 4 && fileData[0] == 0x50 && fileData[1] == 0x4B)
        let isXls = lower.hasSuffix(".xls")

        let parseResult: StatementParseResult
        if isPdf {
            parseResult = StatementService.parsePDF(data: fileData, accounts: [])
        } else if isXlsx {
            parseResult = StatementService.parseXLSX(data: fileData, accounts: [])
        } else if isXls {
            parseResult = StatementService.parseXLS(data: fileData, accounts: [])
        } else {
            parseResult = StatementService.parseCSV(data: fileData, accounts: [])
        }

        let rawSnippet = parseResult.rawTextSnippet ?? ""
        let (matchedProfile, score) = BankProfileRegistry.matchProfile(for: rawSnippet.isEmpty ? (parseResult.detectedBank ?? filename) : rawSnippet)

        var totalDebits: Double = 0.0
        var totalCredits: Double = 0.0
        for item in parseResult.items {
            if item.isIncome {
                totalCredits += item.amount
            } else {
                totalDebits += item.amount
            }
        }

        var inconsistencies = parseResult.inconsistencies
        var balanceReconciled: Bool? = nil

        if let opening = parseResult.openingBalance, let closing = parseResult.closingBalance {
            if matchedProfile.docType == .bankAccount {
                // Bank Account: Opening + Credits - Debits == Closing
                let expectedClosing = opening + totalCredits - totalDebits
                let diff = abs(expectedClosing - closing)
                if diff < 0.05 {
                    balanceReconciled = true
                } else {
                    balanceReconciled = false
                    inconsistencies.append("Opening (\(String(format: "%.3f", opening))) + Credits (\(String(format: "%.3f", totalCredits))) - Debits (\(String(format: "%.3f", totalDebits))) = \(String(format: "%.3f", expectedClosing)), but Closing is \(String(format: "%.3f", closing)) (Difference: \(String(format: "%.3f", diff)))")
                }
            } else if matchedProfile.docType == .creditCard {
                // Credit Card: Opening + Debits(Purchases) - Credits(Payments) == Closing
                let expectedClosing = opening + totalDebits - totalCredits
                let diff = abs(expectedClosing - closing)
                if diff < 0.05 {
                    balanceReconciled = true
                } else {
                    balanceReconciled = false
                    inconsistencies.append("Credit Card Balance difference: expected \(String(format: "%.3f", expectedClosing)) vs closing \(String(format: "%.3f", closing))")
                }
            }
        }

        if parseResult.items.isEmpty {
            inconsistencies.append("No transactions detected in statement. May require OCR or layout refinement.")
        }

        return StatementAnalysisReport(
            profile: matchedProfile,
            confidenceScore: max(score, parseResult.confidenceScore ?? 0.0),
            detectedBank: parseResult.detectedBank ?? matchedProfile.bankName,
            detectedDocType: matchedProfile.docType,
            detectedIBAN: parseResult.detectedAccountIBAN,
            detectedCardLast4: parseResult.detectedCardLast4,
            detectedDatesCount: parseResult.items.count,
            detectedTransactionsCount: parseResult.items.count,
            totalDebits: totalDebits,
            totalCredits: totalCredits,
            openingBalance: parseResult.openingBalance,
            closingBalance: parseResult.closingBalance,
            balanceReconciled: balanceReconciled,
            inconsistencies: inconsistencies,
            samplePreview: Array(parseResult.items.prefix(10))
        )
    }
}
