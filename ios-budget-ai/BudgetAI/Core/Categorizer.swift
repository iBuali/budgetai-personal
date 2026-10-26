import Foundation

/// Fast on-device categorization used instantly and as a fallback when Gemini isn't connected.
enum Categorizer {
    static let rules: [(SpendCategory, [String])] = [
        (.subscriptions, ["netflix", "spotify", "shahid", "osn", "disney", "youtube", "icloud", "apple.com", "chatgpt", "openai", "anghami", "prime video", "starzplay"]),
        (.groceries, ["lulu", "carrefour", "jazira", "megamart", "alosra", "al osra", "geant", "spinneys", "supermarket", "hypermarket", "grocery", "tamimi", "panda", "waitrose", "danube"]),
        (.dining, ["talabat", "costa", "starbucks", "mcdonald", "kfc", "cafe", "coffee", "restaurant", "jahez", "deliveroo", "burger", "pizza", "shake shack", "tim hortons", "dunkin", "subway", "bakery", "keeta", "hungerstation"]),
        (.transport, ["careem", "uber", "bapco", "fuel", "petrol", "parking", "taxi", "enoc", "adnoc", "salik", "bolt"]),
        (.bills, ["batelco", "zain", "stc", "ewa", "electricity", "water", "viva", "etisalat", "internet", "fiber", "fibre", "ooredoo", "insurance"]),
        (.housing, ["rent", "landlord", "maintenance", "property"]),
        (.health, ["pharmacy", "hospital", "clinic", "dental", "boots", "aster", "doctor", "medical", "gym", "fitness"]),
        (.entertainment, ["vox", "cinema", "cineco", "steam", "playstation", "xbox", "concert", "ticket", "bowling"]),
        (.shopping, ["amazon", "zara", "h&m", "noon", "ikea", "shein", "apple store", "mall", "centrepoint", "max fashion", "namshi", "sharaf", "virgin", "sephora"]),
        (.education, ["school", "university", "course", "udemy", "tuition", "bookstore", "coursera"]),
        (.travel, ["gulf air", "emirates", "qatar airways", "flydubai", "booking.com", "airbnb", "hotel", "airline", "expedia", "agoda"]),
        (.income, ["salary", "payroll", "refund", "dividend", "interest"]),
        (.transfers, ["transfer", "atm", "withdrawal", "fawri"]),
    ]

    static func guess(_ text: String) -> SpendCategory? {
        let t = text.lowercased()
        guard !t.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        for (category, words) in rules where words.contains(where: { t.contains($0) }) {
            return category
        }
        return nil
    }
}

struct ParsedSMS {
    var amount: Double
    var currency: String?
    var isIncome: Bool
    var merchant: String
    var category: SpendCategory
    var date: Date?
    var accountHint: String?
    var cardDigits: String?
    /// Available balance stated in the SMS, if any.
    var balance: Double?
}

/// Regex-based bank SMS reader for GCC-style alerts. Used offline or when Gemini is unavailable.
enum SMSParser {
    private static let codes = "BHD|BD|SAR|SR|AED|KWD|KD|QAR|QR|OMR|USD|EUR|GBP|INR"

    static func parse(_ raw: String) -> ParsedSMS? {
        let text = raw.replacingOccurrences(of: "\n", with: " ")
        guard let (amount, currency) = amount(in: text), amount > 0 else { return nil }
        let lower = text.lowercased()
        let incomeWords = ["credited", "received", "deposit", "salary", "refund", "credit of", "has been added", "incoming"]
        let expenseWords = ["debited", "purchase", "spent", "paid", "withdrawn", "withdrawal", "payment", "transaction at", "debit"]
        let incomeHit = incomeWords.contains { lower.contains($0) }
        let expenseHit = expenseWords.contains { lower.contains($0) }
        let isIncome = incomeHit && !expenseHit ? true : (incomeHit && lower.contains("credited to your") ? true : false)

        let merchant = merchant(in: text, isIncome: isIncome) ?? (isIncome ? "Incoming transfer" : "Card purchase")
        var category = Categorizer.guess(merchant) ?? Categorizer.guess(text) ?? (isIncome ? .income : .other)
        if isIncome && category != .transfers { category = .income }
        if !isIncome && category == .income { category = .other }
        return ParsedSMS(amount: amount, currency: currency, isIncome: isIncome, merchant: merchant,
                         category: category, date: nil, accountHint: accountHint(in: text),
                         cardDigits: cardDigits(in: text), balance: balance(in: text))
    }

    /// "Avl Bal BHD 1,234.500", "Available balance: 980.250", "Bal BD 12.000"
    static func balance(in raw: String) -> Double? {
        let text = raw.replacingOccurrences(of: "\n", with: " ")
        let pattern = "(?i)\\b(?:avl\\.?\\s*bal(?:ance)?|available\\s*(?:bal(?:ance)?)?|a/c\\s*bal(?:ance)?|current\\s*bal(?:ance)?|bal(?:ance)?)\\s*(?:is|:|-)?\\s*(?:\(codes))?\\s*\\.?\\s*([0-9][0-9,]*(?:\\.[0-9]+)?)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard let last = matches.last, let r = Range(last.range(at: 1), in: text) else { return nil }
        return Money.parse(String(text[r]))
    }

    /// "card ending 1234", "XXXX1234", "a/c **5678"
    static func cardDigits(in raw: String) -> String? {
        let patterns = ["(?i)ending\\s*(?:with|in)?\\s*([0-9]{3,4})", "(?i)[x*#]{2,}\\s?([0-9]{3,4})", "(?i)(?:card|a/c|acct|account)\\s*(?:no\\.?)?\\s*[x*]*([0-9]{4})\\b"]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let m = regex.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)),
                  let r = Range(m.range(at: 1), in: raw) else { continue }
            return String(raw[r])
        }
        return nil
    }

    private static func amount(in text: String) -> (Double, String?)? {
        let patterns = [
            "(?i)\\b(\(codes))\\s?\\.?\\s?([0-9][0-9,]*(?:\\.[0-9]+)?)",
            "(?i)([0-9][0-9,]*(?:\\.[0-9]+)?)\\s?(\(codes))\\b",
        ]
        for (index, pattern) in patterns.enumerated() {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let r1 = Range(match.range(at: 1), in: text), let r2 = Range(match.range(at: 2), in: text) else { continue }
            let numberPart = index == 0 ? String(text[r2]) : String(text[r1])
            let codePart = (index == 0 ? String(text[r1]) : String(text[r2])).uppercased()
            if let value = Money.parse(numberPart) {
                return (value, normalise(codePart))
            }
        }
        // Fallback: first decimal number.
        if let regex = try? NSRegularExpression(pattern: "([0-9][0-9,]*\\.[0-9]{2,3})"),
           let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let r = Range(match.range(at: 1), in: text), let v = Money.parse(String(text[r])) {
            return (v, nil)
        }
        return nil
    }

    private static func normalise(_ code: String) -> String {
        switch code {
        case "BD": "BHD"
        case "KD": "KWD"
        case "QR": "QAR"
        case "SR": "SAR"
        default: code
        }
    }

    private static func merchant(in text: String, isIncome: Bool) -> String? {
        let markers = isIncome ? ["from ", " by "] : [" at ", " to ", " @ ", "merchant: ", "at:"]
        let lower = text.lowercased()
        for marker in markers {
            guard let range = lower.range(of: marker) else { continue }
            let start = text.index(text.startIndex, offsetBy: lower.distance(from: lower.startIndex, to: range.upperBound))
            var tail = String(text[start...])
            for stop in [" on ", " dated", ". ", ", ", " using", " with", " via", " ref", " card", " avl", " available", " bal"] {
                if let r = tail.lowercased().range(of: stop) {
                    tail = String(tail[tail.startIndex..<tail.index(tail.startIndex, offsetBy: tail.lowercased().distance(from: tail.lowercased().startIndex, to: r.lowerBound))])
                }
            }
            let cleaned = tail.trimmingCharacters(in: CharacterSet.whitespaces.union(.punctuationCharacters))
            if cleaned.count >= 2 && cleaned.count <= 40 && !cleaned.lowercased().hasPrefix("your") {
                return cleaned.capitalized
            }
        }
        return nil
    }

    private static func accountHint(in text: String) -> String? {
        let banks = ["NBB", "BBK", "BISB", "KFH", "AUB", "Ahli United", "Bank ABC", "Al Salam", "ila", "Khaleeji", "Ithmaar"]
        return banks.first { text.localizedCaseInsensitiveContains($0) }
    }
}
