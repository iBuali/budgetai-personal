import Foundation
import SwiftData

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
            "naft", "woqod", "al Maha", "shell", "totalenergies",
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
            "salary", "payroll", "wages", "stipend", "bonus", "allowance", "refund", "cashback", "dividend",
            "interest", "sio ", "social insurance", "tamkeen", "ministry of", "government support", "hesabi", "citizen account",
            "راتب", "رواتب", "أجر", "مكافأة", "علاوة", "بدل", "استرداد", "كاش باك", "أرباح", "تمكين",
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
    /// reuse that exact category and subcategory!
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

struct ParsedSMS {
    var amount: Double
    var currency: String?
    var isIncome: Bool
    var merchant: String
    var category: SpendCategory
    var subcategory: SpendCategory? = nil
    var date: Date?
    var accountHint: String?
    var cardDigits: String?
    /// Available balance stated in the SMS, if any.
    var balance: Double?
    /// Payment rail or helpful note (e.g. "BenefitPay · Fawri+", "Apple Pay", "ATM").
    var note: String? = nil
}

/// Bilingual (Arabic & English) bank SMS reader for Bahrain & GCC alerts.
/// Handles Arabic numerals (٠-٩), BenefitPay / Fawri+ / Apple Pay / mada / POS / ATM,
/// filters out OTPs and declined alerts, and applies smart merchant learning.
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
                // Strip invisible bidi formatting characters often injected in bank SMS
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

        // Split on blank lines (2+ newlines) or horizontal separators
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
            // Check if each paragraph actually has a number/amount, or if a single multi-line SMS had blank lines
            let withAmounts = paragraphs.filter { amount(in: $0) != nil }
            if withAmounts.count > 1 {
                return paragraphs
            }
        }
        return [normalized]
    }

    static func parse(_ raw: String, context: ModelContext? = nil) -> ParsedSMS? {
        let normalized = normalizeText(raw)
        guard nonTransactionReason(normalized) == nil else { return nil }

        guard let (amt, currency) = amount(in: normalized), amt > 0 else { return nil }
        let singleLine = normalized.replacingOccurrences(of: "\n", with: " ")
        let lower = singleLine.lowercased()

        let isIncome = detectIsIncome(in: lower)
        let rail = detectRail(in: singleLine)
        let extractedMerchant = merchant(in: normalized, isIncome: isIncome, rail: rail)
            ?? defaultMerchant(isIncome: isIncome, rail: rail)

        var category: SpendCategory
        var subcategory: SpendCategory? = nil

        if let context, let learned = Categorizer.learnedMatch(for: extractedMerchant, in: context, isIncome: isIncome) {
            category = learned.category
            subcategory = learned.subcategory
        } else {
            category = Categorizer.guess(extractedMerchant) ?? Categorizer.guess(singleLine) ?? (isIncome ? .income : .other)
        }

        if rail == "ATM Withdrawal" && !isIncome && category == .other {
            category = .transfers
        }
        if isIncome && category != .transfers && !category.isIncomeCategory {
            category = .income
        }
        if !isIncome && category.isIncomeCategory {
            category = .other
        }

        return ParsedSMS(
            amount: amt,
            currency: currency,
            isIncome: isIncome,
            merchant: extractedMerchant,
            category: category,
            subcategory: subcategory,
            date: extractDate(in: singleLine),
            accountHint: accountHint(in: singleLine),
            cardDigits: cardDigits(in: singleLine),
            balance: balance(in: normalized),
            note: rail
        )
    }

    private static func detectIsIncome(in lower: String) -> Bool {
        let incomePatterns = [
            "credited", "has been credited", "received", "deposit", "salary", "payroll", "refund",
            "cashback", "credit of", "has been added", "incoming transfer", "inward transfer",
            "fawri+ received", "benefitpay received", "transferred to your",
            "تم إيداع", "تم ايداع", "إيداع", "ايداع", "تمت إضافة", "تم اضافة", "حوالة واردة",
            "تحويل وارد", "إيداع راتب", "راتب", "استرداد", "مرتجع", "تم استلام", "وارد لحسابك", "تغذية حساب"
        ]
        let expensePatterns = [
            "debited", "has been debited", "purchase", "pos ", "spent", "paid", "withdrawn",
            "withdrawal", "payment of", "bill payment", "transaction at", "debit of", "used for",
            "charged", "outward transfer", "sent to",
            "تم خصم", "خصم مبلغ", "شراء", "عملية شراء", "نقاط البيع", "سحب صراف", "سحب نقدي",
            "سداد فاتورة", "دفع فاتورة", "حوالة صادرة", "تحويل صادر", "تم سحب", "خصم من"
        ]
        let incomeHit = incomePatterns.contains { lower.contains($0) }
        let expenseHit = expensePatterns.contains { lower.contains($0) }
        if incomeHit && !expenseHit { return true }
        if incomeHit && (lower.contains("credited to") || lower.contains("تم إيداع") || lower.contains("حوالة واردة")) { return true }
        return false
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

    private static func defaultMerchant(isIncome: Bool, rail: String?) -> String {
        if let rail {
            if rail == "ATM Withdrawal" { return "ATM Withdrawal" }
            if rail.contains("BenefitPay") || rail.contains("Fawri") {
                return isIncome ? "\(rail) Transfer" : "\(rail) Payment"
            }
        }
        return isIncome ? "Incoming transfer" : "Card purchase"
    }

    /// Extracts available balance in both English and Arabic formats:
    /// "Avl Bal BHD 1,234.500", "Available balance: 980.250", "الرصيد المتاح: 120.500 د.ب"
    static func balance(in raw: String) -> Double? {
        let text = normalizeText(raw).replacingOccurrences(of: "\n", with: " ")
        let balLabels = "(?:avl\\.?\\s*bal(?:ance)?|available\\s*(?:bal(?:ance)?)?|a/c\\s*bal(?:ance)?|current\\s*bal(?:ance)?|bal(?:ance)?|الرصيد\\s*المتاح|الرصيد\\s*الحالي|الرصيد\\s*الفعلي|إجمالي\\s*الرصيد|رصيدك|الرصيد)"
        let patterns = [
            // Currency before number: "Avl Bal: BHD 1,234.500" or "الرصيد: د.ب 120.500"
            "(?i)\(balLabels)\\s*(?:is|:|-|=)?\\s*(?:\(allCurrencyPattern))?\\s*\\.?\\s*([0-9][0-9,]*(?:\\.[0-9]+)?)",
            // Number before currency: "الرصيد المتاح 1,234.500 د.ب"
            "(?i)\(balLabels)\\s*(?:is|:|-|=)?\\s*([0-9][0-9,]*(?:\\.[0-9]+)?)\\s*(?:\(allCurrencyPattern))"
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

    /// Extracts card or account last 3-4 digits in English & Arabic:
    /// "card ending 1234", "XXXX1234", "a/c **5678", "بطاقة *1234", "حساب رقم **4821"
    static func cardDigits(in raw: String) -> String? {
        let text = normalizeText(raw)
        let patterns = [
            "(?i)ending\\s*(?:with|in)?\\s*[x*#]*([0-9]{3,4})",
            "(?i)[x*#]{2,}\\s*([0-9]{3,4})",
            "(?i)(?:card|a/c|acct|account|iban)\\s*(?:no\\.?|number|#)?\\s*[:\\-]?\\s*[x*#]+([0-9]{3,4})\\b",
            "(?i)(?:بطاقة|بطاقتك|حساب|حسابك)\\s*(?:رقم|مدى|ائتمانية|تنتهي\\s*بـ?)?\\s*[:\\-]?\\s*[x*#]*([0-9]{3,4})\\b"
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let r = Range(m.range(at: 1), in: text) else { continue }
            return String(text[r])
        }
        return nil
    }

    /// Extracts transaction date if present in the SMS.
    static func extractDate(in raw: String) -> Date? {
        let text = normalizeText(raw)
        let cal = Calendar.current
        let now = Date.now

        // 1. Explicit formats: yyyy-MM-dd, dd/MM/yyyy, dd-MM-yyyy, dd/MM/yy, dd-MMM-yyyy, dd-MMM
        let regexPatterns: [(String, [String])] = [
            ("\\b(20[0-9]{2}-[01][0-9]-[0-3][0-9])\\b", ["yyyy-MM-dd"]),
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
            let token = String(text[r])
            for fmt in formats {
                df.dateFormat = fmt
                if var parsed = df.date(from: token) {
                    if !fmt.contains("y") {
                        var comps = cal.dateComponents([.month, .day], from: parsed)
                        comps.year = cal.component(.year, from: now)
                        parsed = cal.date(from: comps) ?? parsed
                    }
                    if parsed <= now.addingTimeInterval(86_400),
                       !cal.isDate(parsed, inSameDayAs: now) {
                        return cal.date(bySettingHour: 12, minute: 0, second: 0, of: parsed)
                    }
                }
            }
        }
        return nil
    }

    private static func amount(in raw: String) -> (Double, String?)? {
        let text = normalizeText(raw).replacingOccurrences(of: "\n", with: " ")

        // Strip out the "Available Balance / الرصيد المتاح" clause when searching for the transaction amount
        // so balance-first or unusual layouts never confuse balance with transaction amount.
        let withoutBalance = text.replacingOccurrences(
            of: "(?i)(?:avl\\.?\\s*bal(?:ance)?|available\\s*bal(?:ance)?|الرصيد\\s*المتاح|الرصيد\\s*الحالي|رصيدك)\\s*(?:is|:|-|=)?\\s*(?:\(allCurrencyPattern))?\\s*\\.?\\s*[0-9][0-9,]*(?:\\.[0-9]+)?\\s*(?:\(allCurrencyPattern))?",
            with: " ",
            options: .regularExpression
        )

        let searchTargets = [withoutBalance, text]
        for target in searchTargets {
            // 1. Explicit labeled amount: "مبلغ: 12.500 د.ب", "بمبلغ 45.00 ر.س", "Amount: BHD 12.500"
            let labeledPatterns = [
                "(?i)(?:amount|amt|for|of|مبلغ|بمبلغ|مقداره|بقيمة|خصم|إيداع|ايداع|شراء)\\s*(?:is|:|-|=)?\\s*(\(allCurrencyPattern))\\s*\\.?\\s*([0-9][0-9,]*(?:\\.[0-9]+)?)",
                "(?i)(?:amount|amt|for|of|مبلغ|بمبلغ|مقداره|بقيمة|خصم|إيداع|ايداع|شراء)\\s*(?:is|:|-|=)?\\s*([0-9][0-9,]*(?:\\.[0-9]+)?)\\s*(\(allCurrencyPattern))"
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

            // 2. General currency + number or number + currency
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

        // 3. Fallback: first decimal number with 2 or 3 decimal places
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

    private static func merchant(in raw: String, isIncome: Bool, rail: String?) -> String? {
        let lines = raw.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }

        // 1. Check structured key:value lines (common in Al Rajhi, SNB, ila, BenefitPay, KFH Arabic & English SMS)
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

        return nil
    }

    private static func cleanMerchantCandidate(_ rawTail: String) -> String? {
        var tail = rawTail
        let stops = [
            " on ", " dated", ". ", ", ", "، ", " using", " with", " via", " ref", " card",
            " avl", " available", " bal", " a/c", " acct", " في ", " بتاريخ ", " بطاقة ",
            " الرصيد", " رصيد", " رقم ", " بنجاح", " يوم "
        ]
        for stop in stops {
            if let r = tail.lowercased().range(of: stop) {
                let len = tail.lowercased().distance(from: tail.lowercased().startIndex, to: r.lowerBound)
                tail = String(tail.prefix(len))
            }
        }
        // Strip trailing country/city codes often appended by POS terminals (e.g. "TALABAT MANAMA BH")
        tail = tail.replacingOccurrences(
            of: "(?i)\\s+(?:MANAMA|MUHARRAQ|RIFFA|BAHRAIN|BH|BHR|RIYADH|JEDDAH|DAMMAM|KSA|SAU|DUBAI|ABU DHABI|UAE|ARE|KUWAIT|KWT|DOHA|QAT|MUSCAT|OMN)\\s*$",
            with: "",
            options: .regularExpression
        )
        let cleaned = tail.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
        let lowerCleaned = cleaned.lowercased()
        let invalidPrefixes = ["your ", "account", "card", "حسابك", "حساب", "بطاقتك"]
        if cleaned.count >= 2 && cleaned.count <= 42 && !invalidPrefixes.contains(where: { lowerCleaned.hasPrefix($0) }) {
            // Preserve Arabic strings as-is; capitalize Latin words nicely
            if cleaned.unicodeScalars.contains(where: { (0x0600...0x06FF).contains($0.value) }) {
                return cleaned
            }
            return cleaned.capitalized
        }
        return nil
    }

    static func accountHint(in text: String) -> String? {
        let bankMappings: [(hint: String, patterns: [String])] = [
            ("NBB", ["nbb", "national bank of bahrain", "البنك الوطني", "بنك البحرين الوطني"]),
            ("BBK", ["bbk", "bank of bahrain and kuwait", "بنك البحرين والكويت"]),
            ("BisB", ["bisb", "bahrain islamic", "البحرين الإسلامي", "البحرين الاسلامي"]),
            ("KFH", ["kfh", "kuwait finance house", "بيت التمويل الكويتي", "بيتك"]),
            ("ila", ["ila bank", "ila ", "بنك إلى", "بنك الى"]),
            ("Al Salam", ["al salam", "alsalam", "بنك السلام"]),
            ("AUB", ["aub", "ahli united", "الأهلي المتحد"]),
            ("Bank ABC", ["bank abc", "المؤسسة العربية المصرفية"]),
            ("Khaleeji", ["khaleeji", "خليجي بنك", "المصرف الخليجي"]),
            ("Ithmaar", ["ithmaar", "بنك إثمار", "بنك اثمار"]),
            ("BenefitPay", ["benefitpay", "benefit pay", "بنفت"]),
            ("Beyon Money", ["beyon money", "بيون موني"]),
            ("stc pay", ["stc pay", "stcpay", "stc bank", "اس تي سي باي"]),
            ("Al Rajhi", ["alrajhi", "al rajhi", "مصرف الراجحي", "الراجحي"]),
            ("SNB", ["snb", "saudi national bank", "البنك الأهلي", "الأهلي السعودي"]),
            ("Riyad Bank", ["riyad bank", "بنك الرياض"]),
            ("Alinma", ["alinma", "مصرف الإنماء", "الإنماء", "الانماء"]),
            ("SAB", ["sab ", "saudi awwal", "البنك الأول", "ساب"]),
            ("Bank Albilad", ["albilad", "بنك البلاد", "البلاد"]),
            ("AlJazira", ["bank aljazira", "بنك الجزيرة"]),
            ("urpay", ["urpay", "يورباي"]),
            ("ENBD", ["emirates nbd", "enbd", "الإمارات دبي الوطني"]),
            ("ADCB", ["adcb", "أبوظبي التجاري"]),
            ("FAB", ["first abu dhabi", "fab ", "أبوظبي الأول"]),
            ("NBK", ["nbk", "national bank of kuwait", "الوطني الكويتي"]),
            ("QNB", ["qnb", "قطر الوطني"]),
            ("Bank Muscat", ["bank muscat", "بنك مسقط"]),
        ]
        let lower = text.lowercased()
        for (hint, patterns) in bankMappings {
            if patterns.contains(where: { lower.contains($0) }) {
                return hint
            }
        }
        return nil
    }
}
