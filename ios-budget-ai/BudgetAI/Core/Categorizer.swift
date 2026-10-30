import Foundation
import SwiftData

// MARK: - User-Specific SMS Rules & Corrections

/// Stores scoped user corrections for SMS sender bank identification and message classification.
/// Rules are strictly scoped to the specific sender ID or structural message template + counterparty
/// so corrections never apply globally to unrelated messages.
enum SMSUserRules {
    private static let senderBankKey = "smsUserSenderBankMap_v1"
    private static let classificationRulesKey = "smsUserClassificationRules_v1"

    struct ClassificationRule: Codable, Equatable {
        var signature: String
        var senderKey: String = ""
        var bankKey: String = ""
        var partyKey: String = ""
        var templateKey: String = ""
        var transactionTypeRaw: String
        var categoryRaw: String
        var subcategoryRaw: String? = nil
        var merchant: String? = nil
        var bank: String? = nil
        var accountIDString: String? = nil
        var toAccountIDString: String? = nil
        var goalIDString: String? = nil
        var updatedAt: Date
    }

    static func normalizeSender(_ sender: String) -> String {
        SMSParser.normalizeText(sender)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    /// Saves a user-assigned bank for a specific SMS sender ID or phone number.
    static func rememberBank(_ bank: String, forSender sender: String) {
        let key = normalizeSender(sender)
        let cleanBank = bank.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !cleanBank.isEmpty else { return }
        var map = (UserDefaults.standard.dictionary(forKey: senderBankKey) as? [String: String]) ?? [:]
        map[key] = cleanBank
        UserDefaults.standard.set(map, forKey: senderBankKey)
    }

    /// Looks up a previously saved bank for a specific SMS sender ID or phone number.
    static func bank(forSender sender: String?) -> String? {
        guard let sender else { return nil }
        let key = normalizeSender(sender)
        guard !key.isEmpty else { return nil }
        let map = (UserDefaults.standard.dictionary(forKey: senderBankKey) as? [String: String]) ?? [:]
        return map[key]
    }

    private static func normalizedTemplate(for rawSMS: String) -> String {
        var template = SMSParser.normalizeText(rawSMS).lowercased()
        // Replace dates/times
        template = template.replacingOccurrences(
            of: "\\b20[0-9]{2}[/-][01]?[0-9][/-][0-3]?[0-9](?:\\s+[0-9]{1,2}:[0-9]{2}(?::[0-9]{2})?)?\\b",
            with: "<date>",
            options: .regularExpression
        )
        template = template.replacingOccurrences(
            of: "\\b[0-3]?[0-9][/-][01]?[0-9][/-](?:20)?[0-9]{2}(?:\\s+[0-9]{1,2}:[0-9]{2}(?::[0-9]{2})?)?\\b",
            with: "<date>",
            options: .regularExpression
        )
        // Replace reference tokens after ref/reference
        template = template.replacingOccurrences(
            of: "(?i)(ref(?:erence)?\\s*(?:no\\.?|number|#|:)?\\s*)([a-z0-9\\-]+)",
            with: "$1<ref>",
            options: .regularExpression
        )
        // Replace decimal amounts and standalone numbers (except keep counterparty suffix separate below)
        template = template.replacingOccurrences(
            of: "\\b[0-9][0-9,]*(?:\\.[0-9]+)?\\b",
            with: "<num>",
            options: .regularExpression
        )
        return template.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Creates a scoped signature from the structural template of the SMS, the counterparty/suffix, and the bank.
    /// Numbers, dates, and reference IDs are replaced with placeholders so only messages with the exact same
    /// wording structure AND the same counterparty/suffix match.
    static func structuralSignature(for rawSMS: String, sender: String? = nil, bank: String? = nil, counterparty: String? = nil) -> String {
        let template = normalizedTemplate(for: rawSMS)
        let normSender = sender.map(normalizeSender) ?? ""
        let normBank = (bank ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normParty = (counterparty ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return "\(normSender)|\(normBank)|\(normParty)|\(template)"
    }

    static func rememberClassification(
        type: SMSTransactionType,
        category: SpendCategory,
        subcategory: SpendCategory? = nil,
        merchant: String? = nil,
        bank: String?,
        accountID: UUID? = nil,
        toAccountID: UUID? = nil,
        goalID: UUID? = nil,
        forRawSMS rawSMS: String,
        sender: String? = nil,
        counterparty: String? = nil
    ) {
        let trimmed = rawSMS.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let party = counterparty ?? SMSParser.extractRecipientOrMerchantKey(in: trimmed)
        let template = normalizedTemplate(for: trimmed)
        let normSender = sender.map(normalizeSender) ?? ""
        let normBank = (bank ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normParty = (party ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let sig = "\(normSender)|\(normBank)|\(normParty)|\(template)"
        let cleanMerchant = merchant?.trimmingCharacters(in: .whitespacesAndNewlines)

        var rules = allClassificationRules()
        rules.removeAll { existing in
            if existing.signature == sig { return true }
            if !existing.templateKey.isEmpty && existing.templateKey == template && existing.partyKey == normParty {
                if existing.senderKey == normSender || existing.senderKey.isEmpty || normSender.isEmpty {
                    return true
                }
            }
            return false
        }
        rules.append(
            ClassificationRule(
                signature: sig,
                senderKey: normSender,
                bankKey: normBank,
                partyKey: normParty,
                templateKey: template,
                transactionTypeRaw: type.rawValue,
                categoryRaw: category.rawValue,
                subcategoryRaw: subcategory?.rawValue,
                merchant: (cleanMerchant?.isEmpty == false) ? cleanMerchant : nil,
                bank: bank,
                accountIDString: accountID?.uuidString,
                toAccountIDString: toAccountID?.uuidString,
                goalIDString: goalID?.uuidString,
                updatedAt: .now
            )
        )
        if let data = try? JSONEncoder().encode(rules) {
            UserDefaults.standard.set(data, forKey: classificationRulesKey)
        }
    }

    /// Saves all user-selected options on an SMS transaction (type, category, subcategory, name/merchant, bank, source account, destination account, and goal)
    /// so future matching SMS messages automatically receive the same options.
    static func rememberTransactionRule(for tx: MoneyTransaction) {
        if let bank = tx.smsBank, !bank.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let sender = tx.smsSender, !sender.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            rememberBank(bank, forSender: sender)
        }
        guard let raw = tx.rawText, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let type = tx.effectiveTransactionType
        guard type != .unknown else { return }
        rememberClassification(
            type: type,
            category: tx.category,
            subcategory: tx.subcategory,
            merchant: tx.merchant,
            bank: tx.smsBank,
            accountID: tx.accountID,
            toAccountID: tx.toAccountID,
            goalID: tx.goalID,
            forRawSMS: raw,
            sender: tx.smsSender,
            counterparty: SMSParser.extractRecipientOrMerchantKey(in: raw)
        )
    }

    static func matchingRule(forRawSMS rawSMS: String, sender: String? = nil, bank: String? = nil, counterparty: String? = nil) -> ClassificationRule? {
        let trimmed = rawSMS.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let party = counterparty ?? SMSParser.extractRecipientOrMerchantKey(in: trimmed)
        let rules = allClassificationRules()
        guard !rules.isEmpty else { return nil }

        // 1. Try exact signature candidates first
        let candidateSignatures = [
            structuralSignature(for: trimmed, sender: sender, bank: bank, counterparty: party),
            structuralSignature(for: trimmed, sender: sender, bank: nil, counterparty: party),
            structuralSignature(for: trimmed, sender: nil, bank: bank, counterparty: party),
            structuralSignature(for: trimmed, sender: nil, bank: nil, counterparty: party)
        ]
        for sig in candidateSignatures {
            if let hit = rules.last(where: { $0.signature == sig }) {
                return hit
            }
        }

        // 2. Match by template + counterparty when bank was added or updated on the rule after initial receipt
        let template = normalizedTemplate(for: trimmed)
        let normSender = sender.map(normalizeSender) ?? ""
        let normParty = (party ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let hit = rules.last(where: { rule in
            guard !rule.templateKey.isEmpty, rule.templateKey == template, rule.partyKey == normParty else { return false }
            if !normSender.isEmpty && !rule.senderKey.isEmpty {
                return rule.senderKey == normSender
            }
            return true
        }) {
            return hit
        }

        return nil
    }

    static func allClassificationRules() -> [ClassificationRule] {
        guard let data = UserDefaults.standard.data(forKey: classificationRulesKey),
              let rules = try? JSONDecoder().decode([ClassificationRule].self, from: data) else {
            return []
        }
        return rules
    }

    static func clearAll() {
        UserDefaults.standard.removeObject(forKey: senderBankKey)
        UserDefaults.standard.removeObject(forKey: classificationRulesKey)
    }
}

// MARK: - Bahrain Bank Catalog

enum BahrainBankCatalog {
    /// Known Bahrain institutions and wallets for manual picker and deterministic identification.
    static let bahrainBanks: [String] = [
        "NBB",
        "BBK",
        "BisB",
        "ila",
        "KFH",
        "Al Salam",
        "AUB",
        "Bank ABC",
        "Khaleeji",
        "Ithmaar",
        "BenefitPay",
        "Beyon Money",
        "BFC Pay"
    ]
}

// MARK: - Categorizer

/// Fast on-device categorization with merchant memory from past transactions + Bilingual (EN/AR) Bahrain/GCC rules.
enum Categorizer {
    static let rules: [(SpendCategory, [String])] = [
        (.subscriptions, [
            "netflix", "spotify", "shahid", "osn", "disney", "youtube", "icloud", "apple.com/bill", "itunes",
            "chatgpt", "openai", "claude", "anthropic", "anghami", "prime video", "starzplay", "tod", "bein",
            "adobe", "microsoft 365", "google one", "dropbox", "canva", "playstation network", "xbox game pass",
            "نتفلكس", "سبوتيفاي", "شاهد", "أبل", "ايكلاود", "يوتيوب", "أنغامي", "أو إس إن"
        ]),
        (.groceries, [
            "lulu", "carrefour", "jazira", "al jazira", "megamart", "alosra", "al osra", "geant", "spinneys",
            "supermarket", "hypermarket", "grocery", "tamimi", "panda", "waitrose", "danube", "monoprix",
            "midway", "ramiz", "ramez", "nesto", "al maya", "choithrams", "union coop", "sultan center",
            "city centre hyper", "cold store", "baqala", "minimart", "coca-cola", "almarai",
            "لولو", "كارفور", "الجزيرة", "ميغامارت", "الأسرة", "الاسرة", "جيان", "سبينيس", "سوبرماركت",
            "هايبرماركت", "بقالة", "برادة", "التميمي", "تميمي", "بنده", "الدانوب", "نستو", "رامز", "مونوبري"
        ]),
        (.dining, [
            "talabat", "costa", "starbucks", "mcdonald", "kfc", "cafe", "coffee", "restaurant", "jahez",
            "deliveroo", "burger", "pizza", "shake shack", "tim hortons", "dunkin", "subway", "bakery",
            "keeta", "hungerstation", "mrsool", "toyou", "ninja", "cari", "cinnabon", "krispy kreme",
            "baskin", "hardee", "wendy", "papa john", "domino", "nando", "chilis", "pf chang", "paul",
            "caribou", "dose cafe", " % arabica", "arabica", "roastery", "shawarma", "grill", "bistro",
            "diner", "kitchen", "sweets", "patisserie", "chocolat", "ice cream", "gelato", "sushi", "albaik", "al baik",
            "طلبات", "كوستا", "ستاربكس", "ماكدونالدز", "كنتاكي", "كافيه", "مقهى", "قهوة", "مطعم", "جاهز",
            "هنقرستيشن", "مرسول", "كيتا", "تويو", "البيك", "شاورما", "برجر", "بيتزا", "مخبز", "حلويات",
            "دانكن", "تيم هورتنز", "باسكن", "هارديز", "صب واي", "دومينوز", "بابا جونز", "كاريبو"
        ]),
        (.transport, [
            "careem", "uber", "bapco", "tazweed", "fuel", "petrol", "gas station", "parking", "taxi",
            "enoc", "adnoc", "epco", "salik", "darb", "bolt", "jeeny", "saptco", "haramain", "metro",
            "bus", "car wash", "auto service", "tyre", "tire", "garage", "aldrees", "sasco", "petromin",
            "naft", "woqod", "al maha", "shell", "totalenergies",
            "كريم", "أوبر", "اوبر", "بابكو", "تزويد", "وقود", "بنزين", "محطة", "مواقف", "تاكسي", "أجرة",
            "سالك", "درب", "إينوك", "أدنوك", "الدريس", "ساسكو", "بترومين", "نفط", "جيني", "بولت", "غسيل سيارات"
        ]),
        (.bills, [
            "batelco", "beyon", "zain", "stc", "ewa", "electricity", "water", "viva", "etisalat", "e&",
            "du ", "internet", "fiber", "fibre", "ooredoo", "omantel", "vodafone", "mobily", "salam telecom",
            "sadad", "efawateer", "kahramaa", "dewa", "sewa", "fewa", "addc", "nwc", "sec ", "saudi electric",
            "insurance", "takaful", "gig ", "solidarity", "snic", "medgulf", "bupa", "tawuniya", "traffic", "municipality",
            "بتلكو", "بيون", "زين", "اس تي سي", "إيوا", "ايوا", "الكهرباء", "الماء", "المياه", "اتصالات",
            "أوريدو", "اوريدو", "موبايلي", "فودافون", "عمانتل", "سداد", "فاتورة", "فواتير", "تأمين", "تكافل",
            "كهرماء", "ديوا", "المرور", "بلدية"
        ]),
        (.housing, [
            "rent", "landlord", "maintenance", "property", "real estate", "eskant", "eskan", "mortgage",
            "hoa", "plumber", "electrician", "ac repair", "cleaning service",
            "إيجار", "ايجار", "عقار", "صيانة", "إسكان", "اسكان", "تمويل عقاري"
        ]),
        (.health, [
            "pharmacy", "hospital", "clinic", "dental", "dentist", "boots", "aster", "doctor", "medical",
            "gym", "fitness", "nahdi", "al dawaa", "aldawaa", "asser", "american mission", "amh", "kims",
            "royal bahrain hospital", "rbh", "al salam specialist", "ibn al nafees", "bahrain specialist",
            "nasser pharmacy", "ruiyan", "al ruiyan", "habitec", "optical", "eyecare", "lab", "diagnostics",
            "صيدلية", "مستشفى", "عيادة", "أسنان", "اسنان", "طبيب", "طبي", "مختبر", "نادي", "فتنس", "جيم",
            "النهدي", "الدواء", "رويان", "ناصر", "ابن النفيس", "الكندي", "السلام التخصصي", "بوتس", "أستر", "بصريات"
        ]),
        (.entertainment, [
            "vox", "cinema", "cineco", "epix", "mukta", "steam", "playstation", "xbox", "nintendo",
            "concert", "ticket", "bowling", "arcade", "magic island", "magic planet", "gravity", "karting",
            "padel", "stadium", "museum", "theme park", "boulevard",
            "سينما", "فوكس", "سينكو", "تذاكر", "بولينج", "بادل", "ألعاب", "ترفيه", "ملاهي"
        ]),
        (.shopping, [
            "amazon", "amzn", "zara", "h&m", "noon", "ikea", "shein", "apple store", "mall", "centrepoint",
            "centerpoint", "max fashion", "namshi", "sharaf", "sharaf dg", "virgin", "sephora", "jarir",
            "extra", "xcite", "bath & body", "victoria's secret", "pull&bear", "bershka", "stradivarius",
            "massimo dutti", "mango", "nike", "adidas", "puma", "foot locker", "decathlon", "sun & sand",
            "home centre", "home box", "pottery barn", "pan emirates", "abyat", "ace hardware", "daiso",
            "miniso", "mumuso", "ali express", "aliexpress", "temu", "iherb", "ounass", "faces", "mac cosmetics",
            "gold", "jewellery", "jewelry", "perfume", "arabian oud", "abdul samad al qurashi", "jashanmal",
            "أمازون", "امازون", "زارا", "اتش اند ام", "نون", "إيكيا", "ايكيا", "شي ان", "شي إن", "سنتربوينت",
            "ماكس", "نمشي", "شرف دي جي", "فيرجن", "سيفورا", "جرير", "اكسترا", "إكسترا", "الغزاوي", "سايت",
            "نايك", "أديداس", "ديكاتلون", "هوم سنتر", "هوم بوكس", "أبيات", "دايسو", "ميني سو", "علي اكسبرس",
            "تيمو", "اي هيرب", "أناس", "العربية للعود", "القرشي", "عطور", "مجوهرات", "ذهب"
        ]),
        (.education, [
            "school", "university", "college", "academy", "institute", "course", "udemy", "tuition",
            "bookstore", "coursera", "edx", "kindergarten", "nursery", "polytechnic", "uob", "asu", "aubh", "rcsi",
            "مدرسة", "جامعة", "كلية", "معهد", "أكاديمية", "حضانة", "روضة", "رسوم دراسية", "مكتبة"
        ]),
        (.travel, [
            "gulf air", "emirates", "qatar airways", "flydubai", "etihad", "saudia", "flynas", "flyadeal",
            "jazeera airways", "kuwait airways", "oman air", "salamair", "air arabia", "wizz", "british airways",
            "lufthansa", "turkish airlines", "booking.com", "airbnb", "hotel", "resort", "airline", "airways",
            "expedia", "agoda", "almosafer", "wego", "trip.com", "skyscanner", "duty free", "airport", "visa fee",
            "طيران الخليج", "الإماراتية", "القطرية", "الاتحاد", "السعودية", "طيران ناس", "أديل", "فلاي دبي",
            "العربية للطيران", "فندق", "منتجع", "بوكينج", "المسافر", "ويجو", "مطار", "سفر", "تأشيرة"
        ]),
        (.income, [
            "salary", "payroll", "wages", "stipend", "bonus", "allowance", "dividend",
            "interest", "sio ", "social insurance", "tamkeen", "ministry of", "government support", "hesabi", "citizen account",
            "راتب", "رواتب", "أجر", "مكافأة", "علاوة", "بدل", "أرباح", "تمكين",
            "التأمينات", "حساب المواطن", "دعم"
        ]),
        (.transfers, [
            "transfer", "atm ", "cash withdrawal", "fawri", "benefitpay", "sarie", "iban", "remittance",
            "western union", "bfc ", "lulu exchange", "al ansari", "zenj", "nec ", "nonoo", "stcpay", "urpay",
            "تحويل", "حوالة", "سحب نقدي", "صراف آلي", "صراف", "فوري", "بنفت", "سريع", "صرافة", "الأنصاري"
        ]),
    ]

    /// Fast keyword guess against built-in and custom categories.
    static func guess(_ text: String) -> SpendCategory? {
        let t = SMSParser.normalizeText(text).lowercased()
        guard !t.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }

        // Check custom categories by name first so user-created categories match automatically.
        for custom in CategoryRegistry.shared.topLevel {
            let name = custom.title.lowercased()
            if name.count >= 3 && t.contains(name) {
                return custom
            }
        }

        for (category, words) in rules where words.contains(where: { t.contains($0) }) {
            return category
        }
        return nil
    }

    /// Learns from the user's past transactions in SwiftData: if this merchant was categorized before,
    /// reuse that exact category and subcategory.
    static func learnedMatch(for merchant: String, in context: ModelContext, isIncome: Bool? = nil) -> (category: SpendCategory, subcategory: SpendCategory?)? {
        let cleaned = merchant.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count >= 2 else { return nil }
        let targetKey = Finance.merchantKey(cleaned)
        let lower = cleaned.lowercased()

        let descriptor = FetchDescriptor<MoneyTransaction>(
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        guard let history = try? context.fetch(descriptor) else { return nil }

        for tx in history where !tx.isPending && !tx.isTransfer {
            if let isIncome, tx.isIncome != isIncome { continue }
            guard tx.category != .other else { continue }
            let txMerchantLower = tx.merchant.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let txKey = Finance.merchantKey(tx.merchant)
            if txMerchantLower == lower || (!targetKey.isEmpty && txKey == targetKey) {
                return (tx.category, tx.subcategory)
            }
        }
        return nil
    }

    /// Returns a compact map of merchant -> category from the user's history to guide AI parsing.
    static func learnedExamples(in context: ModelContext, limit: Int = 35) -> [String: String] {
        let descriptor = FetchDescriptor<MoneyTransaction>(
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        guard let history = try? context.fetch(descriptor) else { return [:] }
        var map: [String: String] = [:]
        for tx in history where !tx.isPending && !tx.isTransfer && tx.category != .other {
            let m = tx.merchant.trimmingCharacters(in: .whitespacesAndNewlines)
            guard m.count >= 2, map[m] == nil else { continue }
            if let sub = tx.subcategory {
                map[m] = "\(tx.category.rawValue) (sub: \(sub.rawValue))"
            } else {
                map[m] = tx.category.rawValue
            }
            if map.count >= limit { break }
        }
        return map
    }
}

// MARK: - Parsed SMS Result

struct ParsedSMS {
    var amount: Double
    var currency: String?
    var isIncome: Bool
    var merchant: String
    var category: SpendCategory
    var subcategory: SpendCategory? = nil
    var date: Date?
    /// Legacy alias for `detectedBank`; nil when bank identification confidence is low.
    var accountHint: String?
    /// Legacy alias for source `accountSuffix` (or recipient suffix only when no source suffix exists on non-transfers).
    var cardDigits: String?
    /// Available balance stated in the SMS, if any.
    var balance: Double?
    /// Payment rail or helpful note (e.g. "Fawri+", "BenefitPay · Fawri+", "Apple Pay", "ATM").
    var note: String? = nil

    // Enhanced SMS classification & Bahrain bank fields
    var transactionType: SMSTransactionType = .expense
    var detectedBank: String? = nil
    var bankConfidence: SMSConfidence = .low
    var confidence: SMSConfidence = .high
    var classificationReason: String = ""
    var referenceNumber: String? = nil
    var accountSuffix: String? = nil
    var recipientSuffix: String? = nil
    var timeString: String? = nil
    var sender: String? = nil
    var accountID: UUID? = nil
    var toAccountID: UUID? = nil
    var goalID: UUID? = nil
    var matchedUserRule: Bool = false

    var requiresReview: Bool {
        confidence == .low || transactionType == .unknown
    }

    var isOrdinaryExpense: Bool {
        transactionType.countsAsExpense
    }
}

// MARK: - Deterministic SMS Parser

/// Deterministic Bahrain & GCC bank SMS parser with bank-specific rules, Fawri+ direction analysis,
/// reference/IBAN extraction, confidence scoring, and user correction learning.
enum SMSParser {
    private static let englishCodes = "BHD|BD|SAR|SR|AED|DHS|DH|KWD|KD|QAR|QR|OMR|RO|USD|EUR|GBP|INR|EGP|JOD|PKR"
    private static let arabicCodes = "د\\.ب\\.?|دينار بحريني|ر\\.س\\.?|ريال سعودي|ريال|د\\.إ\\.?|درهم|د\\.ك\\.?|دينار كويتي|ر\\.ق\\.?|ريال قطري|ر\\.ع\\.?|ريال عماني|دولار"
    private static var allCurrencyPattern: String { "(?:\(englishCodes)|\(arabicCodes))" }

    /// Normalizes Eastern Arabic / Persian digits (٠-٩ / ۰-۹) and punctuation to standard ASCII.
    static func normalizeText(_ raw: String) -> String {
        var out = String.UnicodeScalarView()
        out.reserveCapacity(raw.unicodeScalars.count)
        for s in raw.unicodeScalars {
            switch s.value {
            case 0x0660...0x0669: // Arabic-Indic ٠-٩
                if let ascii = UnicodeScalar(0x0030 + (s.value - 0x0660)) { out.append(ascii) }
            case 0x06F0...0x06F9: // Extended Arabic-Indic ۰-۹
                if let ascii = UnicodeScalar(0x0030 + (s.value - 0x06F0)) { out.append(ascii) }
            case 0x066B: // Arabic decimal separator ٫
                out.append(UnicodeScalar(0x002E)!) // '.'
            case 0x066C: // Arabic thousands separator ٬
                out.append(UnicodeScalar(0x002C)!) // ','
            case 0x200E, 0x200F, 0x202A...0x202E, 0x2066...0x2069:
                continue
            default:
                out.append(s)
            }
        }
        return String(out)
    }

    /// Returns a human-readable reason if the SMS is an OTP, declined transaction, or non-transaction alert.
    static func nonTransactionReason(_ raw: String) -> String? {
        let text = normalizeText(raw).lowercased()

        let otpKeywords = [
            "otp", "one time password", "one-time password", "verification code", "security code",
            "auth code", "authentication code", "do not share this code", "never share this code",
            "secret code", "passcode", "pin code", "3d secure",
            "رمز التحقق", "كود التحقق", "كلمة المرور لمرة واحدة", "الرقم السري المؤقت", "رمز التفعيل",
            "لا تشارك الرمز", "لا تشارك هذا الرمز", "رمز الأمان", "كود التفعيل"
        ]
        if otpKeywords.contains(where: { text.contains($0) }) {
            return "Skipped: OTP / verification code message."
        }

        let declinedKeywords = [
            "declined", "was declined", "transaction failed", "payment failed", "unsuccessful",
            "insufficient funds", "insufficient balance", "expired card", "incorrect pin", "blocked card",
            "تم رفض", "عملية مرفوضة", "مرفوضة", "فشلت العملية", "رصيد غير كاف", "غير كافي", "بطاقة موقوفة"
        ]
        if declinedKeywords.contains(where: { text.contains($0) }) {
            return "Skipped: Declined or failed transaction alert."
        }

        let infoOnlyKeywords = [
            "logged in", "login alert", "new device login", "statement is ready", "e-statement",
            "beneficiary added", "beneficiary activated",
            "تم تسجيل الدخول", "إضافة مستفيد", "تفعيل مستفيد", "كشف الحساب"
        ]
        if infoOnlyKeywords.contains(where: { text.contains($0) }) {
            return "Skipped: Informational bank alert (not a transaction)."
        }

        return nil
    }

    /// Splits a pasted block of text into individual SMS messages if multiple messages were pasted together.
    static func splitBatch(_ raw: String) -> [String] {
        let normalized = normalizeText(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return [] }

        let paragraphs = normalized
            .components(separatedBy: CharacterSet.newlines)
            .reduce(into: [[String]]()) { acc, line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty || trimmed == "---" || trimmed == "===" {
                    if acc.last?.isEmpty == false { acc.append([]) }
                } else {
                    if acc.isEmpty { acc.append([]) }
                    acc[acc.count - 1].append(trimmed)
                }
            }
            .compactMap { lines -> String? in
                let joined = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                return joined.isEmpty ? nil : joined
            }

        if paragraphs.count > 1 {
            let withAmounts = paragraphs.filter { amount(in: $0) != nil }
            if withAmounts.count > 1 {
                return paragraphs
            }
        }
        return [normalized]
    }

    // MARK: - Bank Identification

    /// Identifies the bank using user-saved sender rules, SMS sender ID, verified helpline numbers,
    /// bank-specific keywords, and verified message formats. Never guesses when confidence is low.
    static func identifyBank(in raw: String, sender: String? = nil) -> (bank: String?, confidence: SMSConfidence, reason: String?) {
        let text = normalizeText(raw)
        let lower = text.lowercased()

        // 1. User-remembered bank for this sender ID / phone number
        if let remembered = SMSUserRules.bank(forSender: sender) {
            return (remembered, .high, "Matched user-saved bank rule for sender '\(sender ?? "")'")
        }

        // 2. Verified Sender ID / Phone number match
        if let sender, !sender.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let normSender = SMSUserRules.normalizeSender(sender)
            if normSender.contains("17515151") || normSender == "bisb" || normSender.contains("bahrain islamic") {
                return ("BisB", .high, "Identified BisB from sender '\(sender)'")
            }
            if let senderBank = matchExplicitBankName(in: normSender, allowBenefitPay: true) {
                return (senderBank, .high, "Identified \(senderBank) from SMS sender '\(sender)'")
            }
        }

        // 3. Verified BisB helpline (17515151) and BIB reference format
        let hasBisBHelpline = lower.range(of: "(?:tel|call|phone|contact)?\\s*[:\\-]?\\s*(?:\\+?973\\s*)?1751\\s*5151\\b", options: .regularExpression) != nil
        let ref = referenceNumber(in: text)
        let hasBIBRef = ref?.uppercased().hasPrefix("BIB") == true

        if hasBisBHelpline && hasBIBRef {
            return ("BisB", .high, "Identified BisB via helpline 17515151 and BIB reference prefix")
        }
        if hasBisBHelpline {
            return ("BisB", .high, "Identified BisB via verified helpline 17515151")
        }

        // 4. Explicit bank name in the SMS text
        // Note: Do NOT infer "BenefitPay" merely from "Fawri+" or "Fawri" because all Bahrain banks send Fawri+ alerts.
        if let bodyBank = matchExplicitBankName(in: lower, allowBenefitPay: true) {
            return (bodyBank, .high, "Identified \(bodyBank) from bank name in SMS")
        }

        // 5. BIB reference prefix in verified Fawri+ template without helpline
        if hasBIBRef && lower.contains("fawri") && lower.contains("was credited to iban ending") {
            return ("BisB", .medium, "Identified BisB from BIB reference prefix and Fawri+ template")
        }

        // Confidence is low — never guess a bank.
        return (nil, .low, nil)
    }

    private static func matchExplicitBankName(in lower: String, allowBenefitPay: Bool) -> String? {
        let bankMappings: [(bank: String, patterns: [String])] = [
            ("NBB", ["\\bnbb\\b", "national bank of bahrain", "البنك الوطني", "بنك البحرين الوطني"]),
            ("BBK", ["\\bbbk\\b", "bank of bahrain and kuwait", "بنك البحرين والكويت"]),
            ("BisB", ["\\bbisb\\b", "bahrain islamic", "البحرين الإسلامي", "البحرين الاسلامي"]),
            ("KFH", ["\\bkfh\\b", "kuwait finance house", "بيت التمويل الكويتي", "بيتك"]),
            ("ila", ["\\bila bank\\b", "\\bila\\b", "بنك إلى", "بنك الى"]),
            ("Al Salam", ["al salam", "alsalam", "بنك السلام"]),
            ("AUB", ["\\baub\\b", "ahli united", "الأهلي المتحد"]),
            ("Bank ABC", ["bank abc", "المؤسسة العربية المصرفية"]),
            ("Khaleeji", ["khaleeji", "خليجي بنك", "المصرف الخليجي"]),
            ("Ithmaar", ["ithmaar", "بنك إثمار", "بنك اثمار"]),
            ("Beyon Money", ["beyon money", "بيون موني"]),
            ("BFC Pay", ["bfc pay", "bfc exchange"]),
            ("stc pay", ["stc pay", "stcpay", "stc bank", "اس تي سي باي"]),
            ("Al Rajhi", ["alrajhi", "al rajhi", "مصرف الراجحي", "الراجحي"]),
            ("SNB", ["\\bsnb\\b", "saudi national bank", "البنك الأهلي", "الأهلي السعودي"]),
            ("Riyad Bank", ["riyad bank", "بنك الرياض"]),
            ("Alinma", ["alinma", "مصرف الإنماء", "الإنماء", "الانماء"]),
            ("SAB", ["\\bsab\\b", "saudi awwal", "البنك الأول", "ساب"]),
            ("Bank Albilad", ["albilad", "بنك البلاد", "البلاد"]),
            ("AlJazira", ["bank aljazira", "بنك الجزيرة"]),
            ("urpay", ["urpay", "يورباي"]),
            ("ENBD", ["emirates nbd", "\\benbd\\b", "الإمارات دبي الوطني"]),
            ("ADCB", ["\\badcb\\b", "أبوظبي التجاري"]),
            ("FAB", ["first abu dhabi", "\\bfab\\b", "أبوظبي الأول"]),
            ("NBK", ["\\bnbk\\b", "national bank of kuwait", "الوطني الكويتي"]),
            ("QNB", ["\\bqnb\\b", "قطر الوطني"]),
            ("Bank Muscat", ["bank muscat", "بنك مسقط"]),
        ]
        for (bank, patterns) in bankMappings {
            for pattern in patterns {
                if pattern.hasPrefix("\\b") {
                    if lower.range(of: pattern, options: .regularExpression) != nil { return bank }
                } else if lower.contains(pattern) {
                    return bank
                }
            }
        }
        if allowBenefitPay {
            let benefitPatterns = ["benefitpay", "benefit pay", "بنفت باي", "تطبيق بنفت"]
            if benefitPatterns.contains(where: { lower.contains($0) }) || lower.trimmingCharacters(in: .whitespaces) == "benefit" {
                return "BenefitPay"
            }
        }
        return nil
    }

    static func accountHint(in text: String, sender: String? = nil) -> String? {
        let id = identifyBank(in: text, sender: sender)
        return id.confidence == .low ? nil : id.bank
    }

    // MARK: - Main Parse Entrypoint

    static func parse(_ raw: String, sender: String? = nil, context: ModelContext? = nil) -> ParsedSMS? {
        let normalized = normalizeText(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        guard nonTransactionReason(normalized) == nil else { return nil }

        guard let (amt, currency) = amount(in: normalized), amt > 0 else { return nil }
        let singleLine = normalized.replacingOccurrences(of: "\n", with: " ")
        let lower = singleLine.lowercased()

        let ref = referenceNumber(in: singleLine)
        let bal = balance(in: normalized)
        let (parsedDate, parsedTime) = extractDateAndTime(in: singleLine)
        let bankInfo = identifyBank(in: normalized, sender: sender)
        let rail = detectRail(in: singleLine)
        let suffixes = extractSuffixes(in: singleLine)

        // 1. Check Verified Rule: BisB / Bahrain Outgoing Fawri+ Payment credited to recipient IBAN
        // Confirmed format:
        // "Fawri+ payment BHD3.000, ref: BIB103KAK000KZUM was credited to IBAN ending 0846 on 2026/10/27 15:26. Balance BHD263.195. Tel: 17515151"
        if let bisbResult = parseVerifiedFawriPlusCreditedToIBAN(
            singleLine: singleLine,
            amount: amt,
            currency: currency,
            reference: ref,
            balance: bal,
            date: parsedDate,
            timeString: parsedTime,
            bankInfo: bankInfo,
            sender: sender,
            context: context
        ) {
            return bisbResult
        }

        // 2. Check User-Specific Correction Rules (scoped to template + counterparty + bank/sender)
        let partyKey = extractRecipientOrMerchantKey(in: normalized) ?? suffixes.recipientSuffix ?? suffixes.accountSuffix
        if let userRule = SMSUserRules.matchingRule(
            forRawSMS: normalized,
            sender: sender,
            bank: bankInfo.bank,
            counterparty: partyKey
        ), let ruleType = SMSTransactionType(rawValue: userRule.transactionTypeRaw) {
            let ruleCat = SpendCategory(rawValue: userRule.categoryRaw) ?? (ruleType.isTransferType ? .transfers : (ruleType.countsAsIncome ? .income : .other))
            let ruleSubcat = userRule.subcategoryRaw.flatMap(SpendCategory.init(rawValue:))
            let resolvedBank = userRule.bank ?? bankInfo.bank
            let isInc = ruleType.isIncomeDirection
            let defaultMerch = merchant(in: normalized, isIncome: isInc, rail: rail, recipientSuffix: suffixes.recipientSuffix)
                ?? defaultMerchant(for: ruleType, rail: rail, recipientSuffix: suffixes.recipientSuffix)
            let merch = (userRule.merchant?.isEmpty == false) ? userRule.merchant! : defaultMerch
            return ParsedSMS(
                amount: amt,
                currency: currency,
                isIncome: isInc,
                merchant: merch,
                category: ruleType.isTransferType && ruleCat == .other ? .transfers : ruleCat,
                subcategory: ruleSubcat,
                date: parsedDate,
                accountHint: resolvedBank,
                cardDigits: suffixes.accountSuffix,
                balance: bal,
                note: buildNote(rail: rail, reference: ref),
                transactionType: ruleType,
                detectedBank: resolvedBank,
                bankConfidence: resolvedBank != nil ? .high : bankInfo.confidence,
                confidence: .high,
                classificationReason: "Matched user-saved classification rule",
                referenceNumber: ref,
                accountSuffix: suffixes.accountSuffix,
                recipientSuffix: suffixes.recipientSuffix,
                timeString: parsedTime,
                sender: sender,
                accountID: userRule.accountIDString.flatMap(UUID.init(uuidString:)),
                toAccountID: userRule.toAccountIDString.flatMap(UUID.init(uuidString:)),
                goalID: userRule.goalIDString.flatMap(UUID.init(uuidString:)),
                matchedUserRule: true
            )
        }

        // 3. Classify the transaction using complete message structure and account context
        let classification = classifyTransaction(
            normalized: normalized,
            singleLine: singleLine,
            lower: lower,
            rail: rail,
            suffixes: suffixes,
            bank: bankInfo.bank,
            context: context
        )

        let txType = classification.type
        let isIncome = txType.isIncomeDirection
        let extractedMerchant = classification.counterparty
            ?? merchant(in: normalized, isIncome: isIncome, rail: rail, recipientSuffix: suffixes.recipientSuffix)
            ?? defaultMerchant(for: txType, rail: rail, recipientSuffix: suffixes.recipientSuffix)

        var category: SpendCategory
        var subcategory: SpendCategory? = nil

        switch txType {
        case .internalTransfer:
            category = .internalTransfer
        case .transferIn, .transferOut:
            category = .transfers
        case .income:
            if let context, let learned = Categorizer.learnedMatch(for: extractedMerchant, in: context, isIncome: true) {
                category = learned.category
                subcategory = learned.subcategory
            } else {
                category = .income
            }
        case .fee:
            category = .bills
        case .refund:
            if let context, let learned = Categorizer.learnedMatch(for: extractedMerchant, in: context, isIncome: false) {
                category = learned.category
                subcategory = learned.subcategory
            } else if let guessed = Categorizer.guess(extractedMerchant), guessed != .income, guessed != .transfers {
                category = guessed
            } else {
                category = .other
            }
        case .expense:
            if let context, let learned = Categorizer.learnedMatch(for: extractedMerchant, in: context, isIncome: false) {
                category = learned.category
                subcategory = learned.subcategory
            } else {
                let guessed = Categorizer.guess(extractedMerchant) ?? Categorizer.guess(singleLine)
                if let guessed, guessed != .income, guessed != .transfers {
                    category = guessed
                } else {
                    category = .other
                }
            }
        case .unknown:
            category = .other
        }

        return ParsedSMS(
            amount: amt,
            currency: currency,
            isIncome: isIncome,
            merchant: extractedMerchant,
            category: category,
            subcategory: subcategory,
            date: parsedDate,
            accountHint: bankInfo.bank,
            cardDigits: suffixes.accountSuffix,
            balance: bal,
            note: buildNote(rail: rail, reference: ref),
            transactionType: txType,
            detectedBank: bankInfo.bank,
            bankConfidence: bankInfo.confidence,
            confidence: classification.confidence,
            classificationReason: classification.reason,
            referenceNumber: ref,
            accountSuffix: suffixes.accountSuffix,
            recipientSuffix: suffixes.recipientSuffix,
            timeString: parsedTime,
            sender: sender,
            toAccountID: classification.toAccountID,
            goalID: classification.goalID
        )
    }

    // MARK: - Verified BisB Outgoing Fawri+ Rule

    private static func parseVerifiedFawriPlusCreditedToIBAN(
        singleLine: String,
        amount: Double,
        currency: String?,
        reference: String?,
        balance: Double?,
        date: Date?,
        timeString: String?,
        bankInfo: (bank: String?, confidence: SMSConfidence, reason: String?),
        sender: String?,
        context: ModelContext?
    ) -> ParsedSMS? {
        // Matches: "Fawri+ payment BHD3.000, ref: BIB103KAK000KZUM was credited to IBAN ending 0846 on 2026/10/27 15:26. Balance BHD263.195. Tel: 17515151"
        let pattern = "(?i)\\b(fawri\\+?|فوري\\+?)\\s+(?:payment|transfer)\\s+(?:\(allCurrencyPattern))?\\s*[0-9][0-9,]*(?:\\.[0-9]+)?\\s*(?:,\\s*ref(?:erence)?\\s*:\\s*([A-Z0-9\\-]+))?\\s+was\\s+credited\\s+to\\s+iban\\s+ending\\s+(?:with\\s+|in\\s+)?[x*#]*([0-9]{3,6})\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: singleLine, range: NSRange(singleLine.startIndex..., in: singleLine)) else {
            return nil
        }

        let serviceName: String = {
            if let r = Range(match.range(at: 1), in: singleLine) {
                return singleLine[r].contains("+") ? "Fawri+" : "Fawri"
            }
            return "Fawri+"
        }()

        let matchedRef: String? = {
            if let r = Range(match.range(at: 2), in: singleLine) {
                return String(singleLine[r])
            }
            return reference
        }()

        guard let recipRange = Range(match.range(at: 3), in: singleLine) else { return nil }
        let recipientIBANSuffix = String(singleLine[recipRange])

        // Check if user has a correction rule specifically for this message
        if let userRule = SMSUserRules.matchingRule(
            forRawSMS: singleLine,
            sender: sender,
            bank: bankInfo.bank,
            counterparty: "iban_\(recipientIBANSuffix)"
        ) ?? SMSUserRules.matchingRule(
            forRawSMS: singleLine,
            sender: sender,
            bank: bankInfo.bank,
            counterparty: recipientIBANSuffix
        ), let ruleType = SMSTransactionType(rawValue: userRule.transactionTypeRaw) {
            let resolvedBank = userRule.bank ?? bankInfo.bank
            let ruleCat = SpendCategory(rawValue: userRule.categoryRaw) ?? (ruleType.isTransferType ? .transfers : .other)
            let ruleSubcat = userRule.subcategoryRaw.flatMap(SpendCategory.init(rawValue:))
            let merch = (userRule.merchant?.isEmpty == false) ? userRule.merchant! : "IBAN ending \(recipientIBANSuffix)"
            let ruleToAcc = userRule.toAccountIDString.flatMap(UUID.init(uuidString:))
            let ruleGoal = userRule.goalIDString.flatMap(UUID.init(uuidString:))
                ?? (context.flatMap { findMatchingGoal(suffix: recipientIBANSuffix, accountID: ruleToAcc, in: $0)?.id })
            return ParsedSMS(
                amount: amount,
                currency: currency ?? "BHD",
                isIncome: ruleType.isIncomeDirection,
                merchant: merch,
                category: ruleType.isTransferType && ruleCat == .other ? .transfers : ruleCat,
                subcategory: ruleSubcat,
                date: date,
                accountHint: resolvedBank,
                cardDigits: nil,
                balance: balance,
                note: buildNote(rail: serviceName, reference: matchedRef),
                transactionType: ruleType,
                detectedBank: resolvedBank,
                bankConfidence: resolvedBank != nil ? .high : bankInfo.confidence,
                confidence: .high,
                classificationReason: "Matched user-saved classification rule",
                referenceNumber: matchedRef,
                accountSuffix: nil,
                recipientSuffix: recipientIBANSuffix,
                timeString: timeString,
                sender: sender,
                accountID: userRule.accountIDString.flatMap(UUID.init(uuidString:)),
                toAccountID: ruleToAcc,
                goalID: ruleGoal,
                matchedUserRule: true
            )
        }

        // Check if recipient IBAN suffix (e.g. 0846) belongs to one of the user's own accounts or a linked SavingsGoal in SwiftData
        var txType: SMSTransactionType = .transferOut
        var toAccID: UUID? = nil
        var matchedGoalID: UUID? = nil
        var merch = "IBAN ending \(recipientIBANSuffix)"
        var reason = "Verified \(bankInfo.bank ?? "Bahrain bank") \(serviceName) outgoing payment format (payment credited to recipient IBAN ending \(recipientIBANSuffix); reported balance is sender's balance after transfer)"

        if let context {
            if let ownDest = findMatchingAccount(suffix: recipientIBANSuffix, in: context) {
                let sourceID = Ledger.defaultAccountID(context: context, hint: bankInfo.bank)
                if sourceID == nil || sourceID != ownDest.id {
                    txType = .internalTransfer
                    toAccID = ownDest.id
                    reason = "Verified \(serviceName) transfer to user's own account (\(ownDest.name), ending \(recipientIBANSuffix))"
                }
            }
            if let goal = findMatchingGoal(suffix: recipientIBANSuffix, accountID: toAccID, in: context) {
                txType = .internalTransfer
                matchedGoalID = goal.id
                if toAccID == nil, let linkedAcc = goal.linkedAccountID {
                    toAccID = linkedAcc
                }
                merch = "Saved to \(goal.name)"
                reason = "Verified \(serviceName) transfer to linked savings goal '\(goal.name)' (IBAN/account ending \(recipientIBANSuffix))"
            }
        }

        return ParsedSMS(
            amount: amount,
            currency: currency ?? "BHD",
            isIncome: false,
            merchant: merch,
            category: txType == .internalTransfer ? .internalTransfer : .transfers,
            subcategory: nil,
            date: date,
            accountHint: bankInfo.bank,
            cardDigits: nil,
            balance: balance,
            note: buildNote(rail: serviceName, reference: matchedRef),
            transactionType: txType,
            detectedBank: bankInfo.bank,
            bankConfidence: bankInfo.confidence,
            confidence: .high,
            classificationReason: reason,
            referenceNumber: matchedRef,
            accountSuffix: nil,
            recipientSuffix: recipientIBANSuffix,
            timeString: timeString,
            sender: sender,
            toAccountID: toAccID,
            goalID: matchedGoalID
        )
    }

    // MARK: - Complete Message Classification

    private struct ClassificationOutcome {
        var type: SMSTransactionType
        var confidence: SMSConfidence
        var reason: String
        var counterparty: String? = nil
        var toAccountID: UUID? = nil
        var goalID: UUID? = nil
    }

    private static func classifyTransaction(
        normalized: String,
        singleLine: String,
        lower: String,
        rail: String?,
        suffixes: (accountSuffix: String?, recipientSuffix: String?),
        bank: String?,
        context: ModelContext?
    ) -> ClassificationOutcome {

        // 1. Explicit Refund / Reversal check (must come before generic credit/purchase keywords)
        let refundPatterns = [
            "\\brefund(?:ed)?\\b", "\\breversal\\b", "\\breversed\\b", "\\bcredited back\\b", "\\bchargeback\\b",
            "استرداد", "مرتجع", "عكس عملية", "إلغاء عملية شراء"
        ]
        if refundPatterns.contains(where: { lower.range(of: $0, options: .regularExpression) != nil }) {
            return ClassificationOutcome(
                type: .refund,
                confidence: .high,
                reason: "Matched explicit refund/reversal wording in SMS"
            )
        }

        // 2. Explicit Bank Fee / Service Charge check
        let feePatterns = [
            "\\bservice fee\\b", "\\btransfer fee\\b", "\\bbank fee\\b", "\\bcard fee\\b", "\\bannual fee\\b",
            "\\bmaintenance fee\\b", "\\blate fee\\b", "\\batm fee\\b", "\\bvat on fee\\b", "\\bbank charge(?:s)?\\b",
            "\\bservice charge(?:s)?\\b", "\\bfee of\\b", "\\bcharge of\\b.*\\bfee\\b",
            "رسوم خدمة", "رسوم تحويل", "رسوم سنوية", "رسوم البطاقة", "رسوم الصراف", "عمولة بنكية", "خصم رسوم"
        ]
        if feePatterns.contains(where: { lower.range(of: $0, options: .regularExpression) != nil }) {
            return ClassificationOutcome(
                type: .fee,
                confidence: .high,
                reason: "Matched explicit bank fee or service charge wording",
                counterparty: bank.map { "\($0) Fee" } ?? "Bank Fee"
            )
        }

        // 3. Explicit Internal Transfer wording or two user-owned account suffixes
        let internalPatterns = [
            "\\binternal transfer\\b", "\\btransfer between your accounts\\b", "\\btransferred between your accounts\\b",
            "\\bto your own account\\b", "تحويل بين حساباتك", "تحويل داخلي بين حساباتك"
        ]
        if internalPatterns.contains(where: { lower.range(of: $0, options: .regularExpression) != nil }) {
            let destAcc = suffixes.recipientSuffix.flatMap { suffix in context.flatMap { findMatchingAccount(suffix: suffix, in: $0) } }
            return ClassificationOutcome(
                type: .internalTransfer,
                confidence: .high,
                reason: "Matched explicit internal transfer between own accounts",
                counterparty: destAcc.map { "Transfer to \($0.name)" } ?? (suffixes.recipientSuffix.map { "Own account ending \($0)" } ?? "Internal transfer"),
                toAccountID: destAcc?.id
            )
        }

        if let context,
           let srcSuffix = suffixes.accountSuffix,
           let dstSuffix = suffixes.recipientSuffix,
           srcSuffix != dstSuffix,
           let srcAcc = findMatchingAccount(suffix: srcSuffix, in: context),
           let dstAcc = findMatchingAccount(suffix: dstSuffix, in: context),
           srcAcc.id != dstAcc.id {
            return ClassificationOutcome(
                type: .internalTransfer,
                confidence: .high,
                reason: "Both source account (\(srcSuffix)) and destination account (\(dstSuffix)) belong to user's accounts",
                counterparty: "\(srcAcc.name) → \(dstAcc.name)",
                toAccountID: dstAcc.id
            )
        }

        // 4. Explicit Salary / Payroll / Allowance Income check
        let salaryPatterns = [
            "\\bsalary\\b", "\\bpayroll\\b", "\\bwages\\b", "\\bstipend\\b", "\\bdividend\\b",
            "\\bsocial insurance\\b", "\\btamkeen\\b", "\\bministry of\\b",
            "راتب", "إيداع راتب", "ايداع راتب", "رواتب", "أرباح", "تمكين", "التأمينات", "حساب المواطن"
        ]
        let hasSalaryKeyword = salaryPatterns.contains(where: { lower.range(of: $0, options: .regularExpression) != nil })
        let hasDebitKeyword = lower.range(of: "\\b(?:debited|withdrawn|sent to|paid to|transfer to|used for)\\b|تم خصم|حوالة صادرة|تحويل صادر", options: .regularExpression) != nil

        if hasSalaryKeyword && !hasDebitKeyword {
            return ClassificationOutcome(
                type: .income,
                confidence: .high,
                reason: "Matched verified salary/income credit pattern",
                counterparty: lower.contains("salary") || lower.contains("راتب") ? "Salary" : nil
            )
        }

        // 5. Fawri+ / Fawri / Bank Transfer / IBAN Transfer analysis
        let isTransferContext = (rail?.contains("Fawri") == true)
            || lower.range(of: "\\b(?:fawri\\+?|iban|bank transfer|wire transfer|remittance|inward transfer|outward transfer|incoming transfer|outgoing transfer|sarie)\\b|فوري\\+?|حوالة|تحويل بنكي|تحويل فوري|آيبان", options: .regularExpression) != nil

        if isTransferContext {
            return classifyTransferMessage(
                normalized: normalized,
                singleLine: singleLine,
                lower: lower,
                rail: rail,
                suffixes: suffixes,
                bank: bank,
                context: context
            )
        }

        // 6. Card Purchases / POS / Online Purchases / Bill Payments / ATM Withdrawals
        let verifiedExpensePatterns = [
            "\\bcard\\b.*\\b(?:used for|purchase|charged|debited)\\b",
            "\\b(?:pos|apple pay|samsung pay|benefitpay)\\s*(?:purchase|payment|txn|transaction)\\b",
            "\\b(?:debited|has been debited|deducted|withdrawn|cash withdrawal|atm withdrawal|spent)\\b",
            "\\b(?:bill payment|sadad payment|paid to)\\b",
            "\\bpurchase\\s+(?:of|at|for|amount)\\b",
            "تم خصم", "خصم مبلغ", "شراء عبر", "عملية شراء", "نقاط البيع", "سحب صراف", "سحب نقدي", "سداد فاتورة", "دفع فاتورة"
        ]
        let isVerifiedExpense = verifiedExpensePatterns.contains(where: { lower.range(of: $0, options: .regularExpression) != nil })

        // Check for conflicting credit signals on non-transfer messages
        let creditSignals = [
            "\\bhas been credited\\b", "\\bcredited to your\\b", "\\bcredited with\\b", "\\breceived in your\\b",
            "\\bdeposit(?:ed)?\\b", "تم إيداع", "تم ايداع", "تمت إضافة", "وارد لحسابك"
        ]
        let hasCreditSignal = creditSignals.contains(where: { lower.range(of: $0, options: .regularExpression) != nil })

        if isVerifiedExpense && !hasCreditSignal {
            return ClassificationOutcome(
                type: .expense,
                confidence: .high,
                reason: "Matched verified purchase/debit/bill payment SMS pattern"
            )
        }

        // 7. Verified non-transfer Deposit / Credit to user's account
        if hasCreditSignal && !isVerifiedExpense && !lower.contains("credited to iban ending") {
            return ClassificationOutcome(
                type: .income,
                confidence: .medium,
                reason: "Matched account deposit/credit pattern"
            )
        }

        // 8. Uncertain / Ambiguous message — do not silently guess income or expense!
        return ClassificationOutcome(
            type: .unknown,
            confidence: .low,
            reason: "Uncertain SMS format or ambiguous transaction direction; marked for user review"
        )
    }

    private static func classifyTransferMessage(
        normalized: String,
        singleLine: String,
        lower: String,
        rail: String?,
        suffixes: (accountSuffix: String?, recipientSuffix: String?),
        bank: String?,
        context: ModelContext?
    ) -> ClassificationOutcome {
        // Verified Outgoing Transfer patterns:
        // - "Fawri+ transfer of BHD ... to ... from ..."
        // - "Fawri+ payment ... was credited to IBAN ending ..."
        // - "Transfer of BHD ... from your account ... to ..."
        // - "Your account ... has been debited ... Fawri+ / transfer to ..."
        // - "Outward transfer / Outgoing Fawri+ / sent via Fawri+"
        // - Arabic: "حوالة صادرة" / "تحويل صادر" / "تم خصم ... تحويل إلى" / "تم تحويل مبلغ ... من حسابك إلى"
        let outgoingPatterns = [
            "\\bfawri\\+?\\s+transfer\\s+of\\b.*\\bto\\b",
            "\\btransfer\\s+of\\b.*\\bto\\b.*\\bfrom\\b",
            "\\btransfer\\s+of\\b.*\\bfrom\\s+(?:your\\s+)?(?:a/c|acct|account|iban)\\b.*\\bto\\b",
            "\\b(?:debited|deducted)\\b.*\\b(?:fawri|transfer|iban|to)\\b",
            "\\b(?:fawri\\+?|transfer)\\b.*\\b(?:debited|deducted)\\s+from\\b",
            "\\b(?:outward|outgoing)\\s+(?:fawri\\+?|transfer|remittance)\\b",
            "\\bsent\\s+(?:via\\s+fawri\\+?|to\\s+iban)\\b",
            "\\bpayment\\b.*\\bwas\\s+credited\\s+to\\s+iban\\s+ending\\b",
            "حوالة صادرة", "تحويل صادر", "حوالة فوري\\+? صادرة", "تم خصم.*(?:فوري|تحويل|حوالة)", "تم تحويل مبلغ.*إلى"
        ]

        // Verified Incoming Transfer patterns:
        // - "You have received a Fawri+ transfer of BHD ... from ..."
        // - "Your account ending ... has been credited with BHD ... via Fawri+ from ..."
        // - "Incoming / Inward Fawri+ transfer ... to your account"
        // - "Fawri+ transfer of BHD ... from ... credited to your account"
        // - Arabic: "حوالة واردة" / "تحويل وارد" / "حوالة فوري+ واردة" / "تم إيداع حوالة" / "تم استلام تحويل"
        let incomingPatterns = [
            "\\breceived\\s+(?:a\\s+)?(?:fawri\\+?|transfer)\\b",
            "\\b(?:fawri\\+?|transfer)\\b.*\\breceived\\s+from\\b",
            "\\byour\\s+(?:a/c|acct|account|iban)\\b.*\\b(?:has\\s+been\\s+)?credited\\b",
            "\\bcredited\\s+to\\s+your\\s+(?:a/c|acct|account|iban)\\b",
            "\\b(?:inward|incoming)\\s+(?:fawri\\+?|transfer|remittance)\\b",
            "حوالة واردة", "تحويل وارد", "حوالة فوري\\+? واردة", "تم إيداع حوالة", "تم ايداع حوالة", "تم استلام حوالة", "تم استلام تحويل"
        ]

        let isOutgoing = outgoingPatterns.contains(where: { lower.range(of: $0, options: .regularExpression) != nil })
        let isIncoming = incomingPatterns.contains(where: { lower.range(of: $0, options: .regularExpression) != nil })

        if isOutgoing && !isIncoming {
            // Check if the destination suffix matches one of the user's own accounts or a linked SavingsGoal -> Internal Transfer
            if let context, let recipSuffix = suffixes.recipientSuffix {
                let ownDest = findMatchingAccount(suffix: recipSuffix, in: context)
                let matchedGoal = findMatchingGoal(suffix: recipSuffix, accountID: ownDest?.id, in: context)
                if let matchedGoal {
                    return ClassificationOutcome(
                        type: .internalTransfer,
                        confidence: .high,
                        reason: "Outgoing transfer to linked savings goal '\(matchedGoal.name)' (ending \(recipSuffix))",
                        counterparty: "Saved to \(matchedGoal.name)",
                        toAccountID: ownDest?.id ?? matchedGoal.linkedAccountID,
                        goalID: matchedGoal.id
                    )
                }
                if let ownDest {
                    let sourceID = suffixes.accountSuffix.flatMap { findMatchingAccount(suffix: $0, in: context)?.id }
                        ?? Ledger.defaultAccountID(context: context, hint: bank)
                    if sourceID == nil || sourceID != ownDest.id {
                        return ClassificationOutcome(
                            type: .internalTransfer,
                            confidence: .high,
                            reason: "Outgoing transfer to user's own account (\(ownDest.name), ending \(recipSuffix))",
                            counterparty: "Transfer to \(ownDest.name)",
                            toAccountID: ownDest.id
                        )
                    }
                }
            }
            return ClassificationOutcome(
                type: .transferOut,
                confidence: .high,
                reason: "Matched verified outgoing \(rail ?? "bank") transfer pattern"
            )
        }

        if isIncoming && !isOutgoing {
            if let context {
                // If an incoming transfer lands in an account/IBAN suffix linked to a SavingsGoal, link the goal
                let creditSuffix = suffixes.accountSuffix ?? suffixes.recipientSuffix
                if let matchedGoal = findMatchingGoal(suffix: creditSuffix, in: context) {
                    return ClassificationOutcome(
                        type: .internalTransfer,
                        confidence: .high,
                        reason: "Incoming transfer to linked savings goal '\(matchedGoal.name)'",
                        counterparty: "Saved to \(matchedGoal.name)",
                        toAccountID: matchedGoal.linkedAccountID,
                        goalID: matchedGoal.id
                    )
                }
                // Check if the sender suffix matches one of the user's own accounts -> Internal Transfer
                if let srcSuffix = suffixes.accountSuffix,
                   let recipSuffix = suffixes.recipientSuffix,
                   srcSuffix != recipSuffix,
                   let ownSrc = findMatchingAccount(suffix: srcSuffix, in: context) {
                    return ClassificationOutcome(
                        type: .internalTransfer,
                        confidence: .high,
                        reason: "Incoming transfer from user's own account (\(ownSrc.name), ending \(srcSuffix))",
                        counterparty: "Transfer from \(ownSrc.name)"
                    )
                }
            }
            return ClassificationOutcome(
                type: .transferIn,
                confidence: .high,
                reason: "Matched verified incoming \(rail ?? "bank") transfer pattern"
            )
        }

        // Direction cannot be determined reliably (e.g. isolated "Fawri+" or "credited" without verified structure)
        return ClassificationOutcome(
            type: .unknown,
            confidence: .low,
            reason: "Ambiguous \(rail ?? "transfer") direction; marked for user review"
        )
    }

    static func findMatchingAccount(suffix: String, in context: ModelContext) -> Account? {
        let clean = suffix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        let accounts = (try? context.fetch(FetchDescriptor<Account>(sortBy: [SortDescriptor(\.createdAt)]))) ?? []
        return accounts.first { acc in
            let m = acc.smsMatch.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !m.isEmpty else { return false }
            return clean.hasSuffix(m) || m.hasSuffix(clean)
        }
    }

    static func findMatchingGoal(suffix: String? = nil, accountID: UUID? = nil, in context: ModelContext) -> SavingsGoal? {
        let goals = (try? context.fetch(FetchDescriptor<SavingsGoal>(sortBy: [SortDescriptor(\.createdAt)]))) ?? []
        if let accountID, let matchByAccount = goals.first(where: { $0.linkedAccountID == accountID }) {
            return matchByAccount
        }
        if let suffix {
            let clean = suffix.trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty {
                if let matchBySuffix = goals.first(where: { goal in
                    let m = goal.smsMatch.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !m.isEmpty else { return false }
                    return clean.hasSuffix(m) || m.hasSuffix(clean)
                }) {
                    return matchBySuffix
                }
                if let acc = findMatchingAccount(suffix: clean, in: context),
                   let matchByLinkedAcc = goals.first(where: { $0.linkedAccountID == acc.id }) {
                    return matchByLinkedAcc
                }
            }
        }
        return nil
    }

    // MARK: - Field Extractors (Reference, Suffixes, Balance, Date/Time, Amount, Merchant)

    /// Extracts transaction reference numbers such as "ref: BIB103KAK000KZUM", "Ref No: 123456", "رقم المرجع: ...".
    static func referenceNumber(in raw: String) -> String? {
        let text = normalizeText(raw)
        let patterns = [
            "(?i)\\b(?:ref(?:erence)?\\s*(?:no\\.?|number|id|#)?|txn\\s*(?:id|ref|no\\.?)|transaction\\s*(?:id|ref)|auth(?:orization)?\\s*(?:code|id))\\s*[:\\-#=]\\s*([A-Z0-9][A-Z0-9\\-]{3,30})\\b",
            "(?i)\\b(?:ref(?:erence)?)\\s+([A-Z0-9][A-Z0-9\\-]{5,30})\\b",
            "(?i)(?:رقم\\s*المرجع|المرجع|رقم\\s*العملية)\\s*[:\\-#=]?\\s*([A-Za-z0-9\\-]{4,30})\\b"
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let r = Range(m.range(at: 1), in: text) else { continue }
            let candidate = String(text[r]).trimmingCharacters(in: .punctuationCharacters)
            if candidate.count >= 4 {
                return candidate
            }
        }
        return nil
    }

    /// Distinguishes the user's source account/card suffix (`accountSuffix`) from a recipient IBAN/account suffix (`recipientSuffix`).
    static func extractSuffixes(in raw: String) -> (accountSuffix: String?, recipientSuffix: String?) {
        let text = normalizeText(raw).replacingOccurrences(of: "\n", with: " ")

        var recipientSuffix: String?
        let recipientPatterns = [
            "(?i)(?:credited\\s+to|transferred\\s+to|sent\\s+to|\\bto)\\s+(?:iban|a/c|acct|account)\\s*(?:ending(?:\\s+with|\\s+in)?|no\\.?|number)?\\s*[:\\-]?\\s*[x*#]*([0-9]{3,6})\\b",
            "(?i)(?:beneficiary|recipient)\\s+(?:iban|a/c|acct|account)?\\s*(?:ending)?\\s*[:\\-]?\\s*[x*#]*([0-9]{3,6})\\b",
            "(?i)(?:إلى|الى|لصالح)\\s*(?:حساب|آيبان|ايبان)\\s*(?:ينتهي\\s*بـ?|رقم)?\\s*[:\\-]?\\s*[x*#]*([0-9]{3,6})\\b"
        ]
        for pattern in recipientPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern),
               let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
               let r = Range(m.range(at: 1), in: text) {
                recipientSuffix = String(text[r])
                break
            }
        }

        // Remove recipient clause before searching for source card/account suffix so recipient IBAN is never confused with user's card/account
        let textWithoutRecipient = text.replacingOccurrences(
            of: "(?i)(?:credited\\s+to|transferred\\s+to|sent\\s+to|\\bto)\\s+(?:iban|a/c|acct|account)\\s*(?:ending(?:\\s+with|\\s+in)?|no\\.?|number)?\\s*[:\\-]?\\s*[x*#]*[0-9]{3,6}\\b",
            with: " ",
            options: .regularExpression
        )

        var accountSuffix: String?
        let sourcePatterns = [
            "(?i)(?:from|your|using)\\s+(?:card|a/c|acct|account|iban)\\s*(?:ending(?:\\s+with|\\s+in)?|no\\.?|number)?\\s*[:\\-]?\\s*(?:xx|[x*#])*([0-9]{3,6})\\b",
            "(?i)(?:card|a/c|acct|account)\\s+ending\\s*(?:with|in)?\\s*[x*#]*([0-9]{3,6})\\b",
            "(?i)(?:card|a/c|acct|account|iban)\\s*(?:no\\.?|number|#)?\\s*[:\\-]?\\s*(?:xx|[x*#])+([0-9]{3,6})\\b",
            "(?i)(?:بطاقة|بطاقتك|حساب|حسابك)\\s*(?:رقم|مدى|ائتمانية|ينتهي\\s*بـ?|تنتهي\\s*بـ?)?\\s*[:\\-]?\\s*[x*#]*([0-9]{3,6})\\b"
        ]
        for pattern in sourcePatterns {
            if let regex = try? NSRegularExpression(pattern: pattern),
               let m = regex.firstMatch(in: textWithoutRecipient, range: NSRange(textWithoutRecipient.startIndex..., in: textWithoutRecipient)),
               let r = Range(m.range(at: 1), in: textWithoutRecipient) {
                accountSuffix = String(textWithoutRecipient[r])
                break
            }
        }

        return (accountSuffix, recipientSuffix)
    }

    /// Legacy helper returning the user's card/account suffix (or any suffix if non-transfer).
    static func cardDigits(in raw: String) -> String? {
        let s = extractSuffixes(in: raw)
        return s.accountSuffix
    }

    static func detectRail(in text: String) -> String? {
        let lower = text.lowercased()
        if lower.contains("benefitpay") || lower.contains("benefit pay") || lower.contains("بنفت") {
            if lower.contains("fawri+") || lower.contains("فوري+") { return "BenefitPay · Fawri+" }
            if lower.contains("fawri") || lower.contains("فوري") { return "BenefitPay · Fawri" }
            return "BenefitPay"
        }
        if lower.contains("fawri+") || lower.contains("فوري+") { return "Fawri+" }
        if lower.contains("fawri") || lower.contains("فوري") { return "Fawri" }
        if lower.contains("apple pay") || lower.contains("أبل باي") || lower.contains("ابل باي") { return "Apple Pay" }
        if lower.contains("atm ") || lower.contains("cash withdrawal") || lower.contains("سحب صراف") || lower.contains("صراف آلي") {
            return "ATM Withdrawal"
        }
        if lower.contains("mada") || lower.contains("مدى") { return "mada" }
        if lower.contains("knet") || lower.contains("كي نت") { return "KNET" }
        if lower.contains("sadad") || lower.contains("سداد") { return "SADAD" }
        return nil
    }

    private static func buildNote(rail: String?, reference: String?) -> String? {
        var parts: [String] = []
        if let rail, !rail.isEmpty { parts.append(rail) }
        if let reference, !reference.isEmpty { parts.append("Ref: \(reference)") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static func defaultMerchant(for type: SMSTransactionType, rail: String?, recipientSuffix: String?) -> String {
        switch type {
        case .transferOut:
            if let recipientSuffix { return "IBAN ending \(recipientSuffix)" }
            if let rail { return "\(rail) Transfer Out" }
            return "Outgoing transfer"
        case .transferIn:
            if let rail { return "\(rail) Transfer In" }
            return "Incoming transfer"
        case .internalTransfer:
            if let recipientSuffix { return "Own account ending \(recipientSuffix)" }
            return "Internal transfer"
        case .fee:
            return "Bank Fee"
        case .refund:
            return "Merchant Refund"
        case .income:
            return "Incoming credit"
        case .expense:
            if rail == "ATM Withdrawal" { return "ATM Withdrawal" }
            return "Card purchase"
        case .unknown:
            if let rail { return "\(rail) (Needs Review)" }
            return "Bank SMS (Needs Review)"
        }
    }

    /// Extracts available/reported balance in both English and Arabic formats:
    /// "Balance BHD263.195", "Avl Bal BHD 1,234.500", "Available balance: 980.250", "الرصيد المتاح: 120.500 د.ب"
    static func balance(in raw: String) -> Double? {
        let text = normalizeText(raw).replacingOccurrences(of: "\n", with: " ")
        let balLabels = "(?:avl\\.?\\s*bal(?:ance)?|available\\s*(?:bal(?:ance)?)?|a/c\\s*bal(?:ance)?|current\\s*bal(?:ance)?|new\\s*bal(?:ance)?|bal(?:ance)?|الرصيد\\s*المتاح|الرصيد\\s*الحالي|الرصيد\\s*الفعلي|إجمالي\\s*الرصيد|رصيدك|الرصيد)"
        let patterns = [
            // Currency before number: "Balance BHD263.195", "Avl Bal: BHD 1,234.500"
            "(?i)\\b\(balLabels)\\s*(?:is|:|-|=)?\\s*(?:\(allCurrencyPattern))\\s*\\.?\\s*([0-9][0-9,]*(?:\\.[0-9]+)?)",
            // Number before currency: "الرصيد المتاح 1,234.500 د.ب"
            "(?i)\\b\(balLabels)\\s*(?:is|:|-|=)?\\s*([0-9][0-9,]*(?:\\.[0-9]+)?)\\s*(?:\(allCurrencyPattern))",
            // Label with colon/is followed by decimal number without repeated currency: "Avl Bal: 263.195"
            "(?i)\\b\(balLabels)\\s*(?:is|:|=)\\s*([0-9][0-9,]*\\.[0-9]{2,3})\\b"
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            if let last = matches.last, let r = Range(last.range(at: 1), in: text),
               let v = Money.parse(String(text[r])) {
                return v
            }
        }
        return nil
    }

    /// Extracts transaction date and optional time ("2026/10/27 15:26", "2026-10-27", "24-Oct", etc.).
    static func extractDate(in raw: String) -> Date? {
        extractDateAndTime(in: raw).date
    }

    static func extractDateAndTime(in raw: String) -> (date: Date?, time: String?) {
        let text = normalizeText(raw)
        let cal = Calendar.current
        let now = Date.now

        // Extract standalone 24h or 12h time if present (e.g. "15:26" or "15:26:10")
        var extractedTime: String?
        if let timeRegex = try? NSRegularExpression(pattern: "\\b([0-2][0-9]:[0-5][0-9](?::[0-5][0-9])?)\\b"),
           let tm = timeRegex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let tr = Range(tm.range(at: 1), in: text) {
            extractedTime = String(text[tr])
        }

        let regexPatterns: [(String, [String])] = [
            ("\\b(20[0-9]{2}/[01]?[0-9]/[0-3]?[0-9]\\s+[0-2][0-9]:[0-5][0-9](?::[0-5][0-9])?)\\b",
             ["yyyy/MM/dd HH:mm:ss", "yyyy/MM/dd HH:mm", "yyyy/M/d HH:mm:ss", "yyyy/M/d HH:mm"]),
            ("\\b(20[0-9]{2}-[01]?[0-9]-[0-3]?[0-9]\\s+[0-2][0-9]:[0-5][0-9](?::[0-5][0-9])?)\\b",
             ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-M-d HH:mm:ss", "yyyy-M-d HH:mm"]),
            ("\\b([0-3]?[0-9]/[01]?[0-9]/20[0-9]{2}\\s+[0-2][0-9]:[0-5][0-9](?::[0-5][0-9])?)\\b",
             ["dd/MM/yyyy HH:mm:ss", "dd/MM/yyyy HH:mm", "d/M/yyyy HH:mm:ss", "d/M/yyyy HH:mm"]),
            ("\\b([0-3]?[0-9]-[01]?[0-9]-20[0-9]{2}\\s+[0-2][0-9]:[0-5][0-9](?::[0-5][0-9])?)\\b",
             ["dd-MM-yyyy HH:mm:ss", "dd-MM-yyyy HH:mm", "d-M-yyyy HH:mm:ss", "d-M-yyyy HH:mm"]),
            ("\\b(20[0-9]{2}/[01]?[0-9]/[0-3]?[0-9])\\b", ["yyyy/MM/dd", "yyyy/M/d"]),
            ("\\b(20[0-9]{2}-[01]?[0-9]-[0-3]?[0-9])\\b", ["yyyy-MM-dd", "yyyy-M-d"]),
            ("\\b([0-3]?[0-9]/[01]?[0-9]/20[0-9]{2})\\b", ["dd/MM/yyyy", "d/M/yyyy"]),
            ("\\b([0-3]?[0-9]-[01]?[0-9]-20[0-9]{2})\\b", ["dd-MM-yyyy", "d-M-yyyy"]),
            ("\\b([0-3]?[0-9]/[01]?[0-9]/[0-9]{2})\\b", ["dd/MM/yy", "d/M/yy"]),
            ("(?i)\\b([0-3]?[0-9][\\s\\-](?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]*(?:[\\s\\-,]+20[0-9]{2})?)\\b",
             ["dd-MMM-yyyy", "d-MMM-yyyy", "dd MMM yyyy", "d MMM yyyy", "dd-MMM", "d-MMM", "dd MMM", "d MMM"])
        ]

        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")

        for (pattern, formats) in regexPatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let r = Range(match.range(at: 1), in: text) else { continue }
            let token = String(text[r]).replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            for fmt in formats {
                df.dateFormat = fmt
                if var parsed = df.date(from: token) {
                    if !fmt.contains("y") {
                        var comps = cal.dateComponents([.month, .day], from: parsed)
                        comps.year = cal.component(.year, from: now)
                        parsed = cal.date(from: comps) ?? parsed
                    }
                    if !fmt.contains("H") {
                        if let extractedTime {
                            let parts = extractedTime.split(separator: ":").compactMap { Int($0) }
                            if parts.count >= 2 {
                                parsed = cal.date(bySettingHour: parts[0], minute: parts[1], second: parts.count >= 3 ? parts[2] : 0, of: parsed) ?? parsed
                            }
                        } else {
                            parsed = cal.date(bySettingHour: 12, minute: 0, second: 0, of: parsed) ?? parsed
                        }
                    }
                    return (parsed, extractedTime)
                }
            }
        }
        return (nil, extractedTime)
    }

    static func amount(in raw: String) -> (Double, String?)? {
        let text = normalizeText(raw).replacingOccurrences(of: "\n", with: " ")

        // Strip out the "Balance / Avl Bal / الرصيد المتاح" clause when searching for the transaction amount
        // so reported account balance is never mistaken for the transaction amount.
        let withoutBalance = text.replacingOccurrences(
            of: "(?i)\\b(?:avl\\.?\\s*bal(?:ance)?|available\\s*bal(?:ance)?|a/c\\s*bal(?:ance)?|current\\s*bal(?:ance)?|new\\s*bal(?:ance)?|bal(?:ance)?|الرصيد\\s*المتاح|الرصيد\\s*الحالي|الرصيد\\s*الفعلي|إجمالي\\s*الرصيد|رصيدك|الرصيد)\\s*(?:is|:|-|=)?\\s*(?:\(allCurrencyPattern))?\\s*\\.?\\s*[0-9][0-9,]*(?:\\.[0-9]+)?\\s*(?:\(allCurrencyPattern))?",
            with: " ",
            options: .regularExpression
        )

        let searchTargets = [withoutBalance, text]
        for target in searchTargets {
            // 1. Explicit labeled amount: "payment BHD3.000", "Amount: BHD 12.500", "مبلغ: 12.500 د.ب"
            let labeledPatterns = [
                "(?i)(?:amount|amt|payment|transfer|for|of|with|مبلغ|بمبلغ|مقداره|بقيمة|خصم|إيداع|ايداع|شراء)\\s*(?:is|:|-|=)?\\s*(\(allCurrencyPattern))\\s*\\.?\\s*([0-9][0-9,]*(?:\\.[0-9]+)?)",
                "(?i)(?:amount|amt|payment|transfer|for|of|with|مبلغ|بمبلغ|مقداره|بقيمة|خصم|إيداع|ايداع|شراء)\\s*(?:is|:|-|=)?\\s*([0-9][0-9,]*(?:\\.[0-9]+)?)\\s*(\(allCurrencyPattern))"
            ]
            for (idx, pattern) in labeledPatterns.enumerated() {
                if let regex = try? NSRegularExpression(pattern: pattern),
                   let match = regex.firstMatch(in: target, range: NSRange(target.startIndex..., in: target)),
                   let r1 = Range(match.range(at: 1), in: target),
                   let r2 = Range(match.range(at: 2), in: target) {
                    let numStr = idx == 0 ? String(target[r2]) : String(target[r1])
                    let curStr = idx == 0 ? String(target[r1]) : String(target[r2])
                    if let val = Money.parse(numStr), val > 0 {
                        return (val, normaliseCurrency(curStr))
                    }
                }
            }

            // 2. General currency + number (e.g. "BHD3.000", "BHD 3.000") or number + currency ("3.000 BHD", "3.000 د.ب")
            let generalPatterns = [
                "(?i)(?:^|\\s|:|\\()(\(allCurrencyPattern))\\s*\\.?\\s*([0-9][0-9,]*(?:\\.[0-9]+)?)",
                "(?i)\\b([0-9][0-9,]*(?:\\.[0-9]+)?)\\s*(\(allCurrencyPattern))(?:\\b|\\s|$|\\.|،|,)"
            ]
            for (idx, pattern) in generalPatterns.enumerated() {
                if let regex = try? NSRegularExpression(pattern: pattern),
                   let match = regex.firstMatch(in: target, range: NSRange(target.startIndex..., in: target)),
                   let r1 = Range(match.range(at: 1), in: target),
                   let r2 = Range(match.range(at: 2), in: target) {
                    let numStr = idx == 0 ? String(target[r2]) : String(target[r1])
                    let curStr = idx == 0 ? String(target[r1]) : String(target[r2])
                    if let val = Money.parse(numStr), val > 0 {
                        return (val, normaliseCurrency(curStr))
                    }
                }
            }
        }

        // 3. Fallback: first decimal number with 2 or 3 decimal places (excluding balance clause)
        if let regex = try? NSRegularExpression(pattern: "\\b([0-9][0-9,]*\\.[0-9]{2,3})\\b"),
           let match = regex.firstMatch(in: withoutBalance, range: NSRange(withoutBalance.startIndex..., in: withoutBalance)),
           let r = Range(match.range(at: 1), in: withoutBalance),
           let v = Money.parse(String(withoutBalance[r])), v > 0 {
            return (v, nil)
        }
        return nil
    }

    static func normaliseCurrency(_ rawCode: String) -> String {
        let cleaned = rawCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        switch cleaned {
        case "BD", "BHD", "د.ب", "د.ب.", "دينار بحريني": return "BHD"
        case "SR", "SAR", "ر.س", "ر.س.", "ريال سعودي", "ريال": return "SAR"
        case "AED", "DHS", "DH", "د.إ", "د.إ.", "درهم": return "AED"
        case "KD", "KWD", "د.ك", "د.ك.", "دينار كويتي": return "KWD"
        case "QR", "QAR", "ر.ق", "ر.ق.", "ريال قطري": return "QAR"
        case "RO", "OMR", "ر.ع", "ر.ع.", "ريال عماني": return "OMR"
        case "USD", "دولار": return "USD"
        default: return cleaned
        }
    }

    static func extractRecipientOrMerchantKey(in raw: String) -> String? {
        let s = extractSuffixes(in: raw)
        if let recip = s.recipientSuffix { return "iban_\(recip)" }
        if let m = merchant(in: raw, isIncome: false, rail: nil, recipientSuffix: nil) {
            return Finance.merchantKey(m)
        }
        if let m = merchant(in: raw, isIncome: true, rail: nil, recipientSuffix: nil) {
            return Finance.merchantKey(m)
        }
        return s.accountSuffix.map { "acct_\($0)" }
    }

    private static func merchant(in raw: String, isIncome: Bool, rail: String?, recipientSuffix: String?) -> String? {
        let lines = raw.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }

        // 1. Check structured key:value lines
        let linePrefixes = isIncome
            ? ["من:", "من :", "المحوّل:", "المرسل:", "الجهة:", "from:", "sender:", "by:"]
            : ["لدى:", "لدى :", "المتجر:", "اسم المتجر:", "إلى:", "الى:", "المستفيد:", "الجهة:", "الفاتورة:", "merchant:", "at:", "to:", "beneficiary:", "biller:"]

        for line in lines {
            let lowerLine = line.lowercased()
            for prefix in linePrefixes where lowerLine.hasPrefix(prefix) {
                let value = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                if let cleaned = cleanMerchantCandidate(value), !cleaned.isEmpty {
                    return cleaned
                }
            }
        }

        // 2. Inline marker extraction (single-line SMS)
        let singleLine = lines.joined(separator: " ")
        let markers = isIncome
            ? [" from ", " by ", " من ", " من حساب ", " بواسطة "]
            : [" at ", " to ", " @ ", " merchant: ", " at: ", " لدى ", " إلى ", " الى ", " لصالح ", " عبر "]

        let lower = singleLine.lowercased()
        for marker in markers {
            guard let range = lower.range(of: marker) else { continue }
            let offset = lower.distance(from: lower.startIndex, to: range.upperBound)
            let start = singleLine.index(singleLine.startIndex, offsetBy: offset)
            let tail = String(singleLine[start...])
            if let cleaned = cleanMerchantCandidate(tail), !cleaned.isEmpty {
                return cleaned
            }
        }

        if let recipientSuffix {
            return "IBAN ending \(recipientSuffix)"
        }
        return nil
    }

    private static func cleanMerchantCandidate(_ rawTail: String) -> String? {
        var tail = rawTail
        // If the tail is specifically "IBAN ending 0846...", preserve "IBAN ending 0846"
        if let ibanMatch = try? NSRegularExpression(pattern: "(?i)^(iban\\s+ending\\s+(?:with\\s+|in\\s+)?[x*#]*[0-9]{3,6})\\b"),
           let m = ibanMatch.firstMatch(in: tail, range: NSRange(tail.startIndex..., in: tail)),
           let r = Range(m.range(at: 1), in: tail) {
            let s = String(tail[r]).replacingOccurrences(of: "(?i)^iban", with: "IBAN", options: .regularExpression)
            return s
        }

        let stops = [
            " on ", " dated", ". ", ", ", "، ", " using", " with", " via", " ref", " card",
            " from ", " avl", " available", " bal", " a/c", " acct", " في ", " بتاريخ ", " بطاقة ",
            " الرصيد", " رصيد", " رقم ", " بنجاح", " يوم "
        ]
        for stop in stops {
            if let r = tail.lowercased().range(of: stop) {
                let len = tail.lowercased().distance(from: tail.lowercased().startIndex, to: r.lowerBound)
                tail = String(tail.prefix(len))
            }
        }
        tail = tail.replacingOccurrences(
            of: "(?i)\\s+(?:MANAMA|MUHARRAQ|RIFFA|BAHRAIN|BH|BHR|RIYADH|JEDDAH|DAMMAM|KSA|SAU|DUBAI|ABU DHABI|UAE|ARE|KUWAIT|KWT|DOHA|QAT|MUSCAT|OMN)\\s*$",
            with: "",
            options: .regularExpression
        )
        let cleaned = tail.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
        let lowerCleaned = cleaned.lowercased()
        let invalidPrefixes = ["your ", "account", "card", "iban", "حسابك", "حساب", "بطاقتك"]
        if cleaned.count >= 2 && cleaned.count <= 42 && !invalidPrefixes.contains(where: { lowerCleaned.hasPrefix($0) }) {
            if cleaned.unicodeScalars.contains(where: { (0x0600...0x06FF).contains($0.value) }) {
                return cleaned
            }
            return cleaned.capitalized
        }
        return nil
    }
}
