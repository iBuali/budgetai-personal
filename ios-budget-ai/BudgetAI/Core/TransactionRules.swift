import Foundation
import SwiftData
import Observation
import CoreLocation

// MARK: - Condition Logic & Fields

enum RuleConditionLogic: String, Codable, CaseIterable, Identifiable {
    case and = "AND"
    case or = "OR"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .and: return "AND — All selected conditions must match"
        case .or:  return "OR — Any selected condition can match"
        }
    }

    var shortTitle: String {
        switch self {
        case .and: return "AND (All match)"
        case .or:  return "OR (Any matches)"
        }
    }
}

enum RuleSMSMatchMode: String, Codable, CaseIterable, Identifiable, Hashable {
    case contains = "contains"
    case exactTemplate = "exact"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .contains:      return "Contains"
        case .exactTemplate: return "Exactly match"
        }
    }
}

enum RuleConditionField: String, Codable, CaseIterable, Identifiable {
    case originalSMS     = "originalSMS"
    case merchant        = "merchant"
    case senderIBAN      = "senderIBAN"
    case recipientIBAN   = "recipientIBAN"
    case accountDigits   = "accountDigits"
    case bank            = "bank"
    case smsSender       = "smsSender"
    case accountID       = "accountID"
    case location        = "location"
    case amount          = "amount"
    case direction       = "direction"
    case monthDay        = "monthDay"
    case dayOfWeek       = "dayOfWeek"
    case reference       = "reference"
    case note            = "note"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .originalSMS:   return "Original SMS"
        case .merchant:      return "Merchant / Recipient"
        case .senderIBAN:    return "Sender IBAN / Digits"
        case .recipientIBAN: return "Recipient IBAN / Digits"
        case .accountDigits: return "Card / Account Digits"
        case .bank:          return "SMS Bank"
        case .smsSender:     return "Phone Number"
        case .accountID:     return "Account"
        case .location:      return "Location"
        case .amount:        return "Amount"
        case .direction:     return "Transaction Type"
        case .monthDay:      return "Date (Day & Month)"
        case .dayOfWeek:     return "Day of Week"
        case .reference:     return "Reference Code"
        case .note:          return "Note"
        }
    }

    var symbol: String {
        switch self {
        case .originalSMS:   return "text.quote"
        case .merchant:      return "storefront.fill"
        case .senderIBAN:    return "arrow.up.right.square.fill"
        case .recipientIBAN: return "number.square.fill"
        case .accountDigits: return "creditcard.fill"
        case .bank:          return "building.columns.fill"
        case .smsSender:     return "phone.fill"
        case .accountID:     return "wallet.bifold.fill"
        case .location:      return "mappin.and.ellipse"
        case .amount:        return "banknote.fill"
        case .direction:     return "arrow.up.arrow.down.circle.fill"
        case .monthDay:      return "calendar"
        case .dayOfWeek:     return "calendar.day.timeline.left"
        case .reference:     return "barcode"
        case .note:          return "note.text"
        }
    }
}

enum RuleTransactionTypeOption: String, CaseIterable, Identifiable {
    case transferOut = "transfer_out"
    case transferIn = "transfer_in"
    case expense = "expense"
    case income = "income"
    case internalTransfer = "internal_transfer"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .transferOut:      return "Transfer Out"
        case .transferIn:       return "Transfer In"
        case .expense:          return "Expense"
        case .income:           return "Income"
        case .internalTransfer: return "Internal Transfer"
        }
    }

    static func from(txType: SMSTransactionType?, isIncome: Bool) -> RuleTransactionTypeOption {
        switch txType {
        case .transferOut:      return .transferOut
        case .transferIn:       return .transferIn
        case .internalTransfer: return .internalTransfer
        case .expense, .fee:    return .expense
        case .income, .refund:  return .income
        case .unknown, .none:   return isIncome ? .income : .expense
        }
    }

    static func parse(_ raw: String) -> RuleTransactionTypeOption? {
        let lower = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let direct = RuleTransactionTypeOption(rawValue: lower) { return direct }
        switch lower {
        case "transfer out", "out", "outward": return .transferOut
        case "transfer in", "in", "inward", "true": return .transferIn
        case "internal transfer", "internal": return .internalTransfer
        case "expense", "false": return .expense
        case "income": return .income
        default: return nil
        }
    }
}

enum RuleDateHelper {
    static let monthAbbreviations = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    static let weekdayNames = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]

    static func maxDays(inMonth month: Int) -> Int {
        switch month {
        case 2: return 29
        case 4, 6, 9, 11: return 30
        default: return 31
        }
    }

    static func monthDayValue(month: Int, day: Int) -> String {
        let m = min(12, max(1, month))
        let d = min(maxDays(inMonth: m), max(1, day))
        return String(format: "%02d-%02d", m, d)
    }

    static func monthDayDisplay(month: Int, day: Int) -> String {
        let m = min(12, max(1, month))
        let d = min(maxDays(inMonth: m), max(1, day))
        return "\(d)-\(monthAbbreviations[m - 1])"
    }

    static func parseMonthDay(_ value: String) -> (month: Int, day: Int)? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(whereSeparator: { $0 == "-" || $0 == "/" })
        guard parts.count == 2 else { return nil }
        if let m = Int(parts[0]), let d = Int(parts[1]), (1...12).contains(m), (1...31).contains(d) {
            return (m, d)
        }
        // Also accept "26-Nov"
        if let d = Int(parts[0]), let mIdx = monthAbbreviations.firstIndex(where: { $0.caseInsensitiveCompare(String(parts[1])) == .orderedSame }) {
            return (mIdx + 1, d)
        }
        return nil
    }

    static func weekdayDisplay(_ weekday: Int) -> String {
        let idx = min(7, max(1, weekday)) - 1
        return weekdayNames[idx]
    }

    static func parseWeekday(_ value: String) -> Int? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let n = Int(trimmed), (1...7).contains(n) {
            return n
        }
        if let idx = weekdayNames.firstIndex(where: { $0.lowercased() == trimmed || $0.lowercased().hasPrefix(trimmed) && trimmed.count >= 3 }) {
            return idx + 1
        }
        return nil
    }
}

struct RuleCondition: Codable, Hashable, Identifiable {
    var id: UUID = UUID()
    var field: RuleConditionField
    /// Raw value used for matching (e.g. UUID string for accountID, numeric string for amount, or place name).
    var value: String
    /// Human-readable value captured from the transaction (e.g. account name, formatted BHD amount, or location name).
    var displayValue: String
    /// Optional GPS latitude for coordinate-based location matching.
    var latitude: Double?
    /// Optional GPS longitude for coordinate-based location matching.
    var longitude: Double?
    /// Radius in meters for coordinate-based matching. Default is 10 meters.
    var radiusMeters: Double = 10.0
    /// Optional match mode for `.originalSMS` (`contains` or `exactTemplate`).
    var smsMatchMode: RuleSMSMatchMode? = nil

    enum CodingKeys: String, CodingKey {
        case id
        case field
        case value
        case displayValue
        case latitude
        case longitude
        case radiusMeters
        case smsMatchMode
    }

    init(
        id: UUID = UUID(),
        field: RuleConditionField,
        value: String,
        displayValue: String,
        latitude: Double? = nil,
        longitude: Double? = nil,
        radiusMeters: Double = 10.0,
        smsMatchMode: RuleSMSMatchMode? = nil
    ) {
        self.id = id
        self.field = field
        self.value = value
        self.displayValue = displayValue
        self.latitude = latitude
        self.longitude = longitude
        self.radiusMeters = radiusMeters
        self.smsMatchMode = smsMatchMode
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.field = try container.decode(RuleConditionField.self, forKey: .field)
        self.value = try container.decode(String.self, forKey: .value)
        self.displayValue = try container.decode(String.self, forKey: .displayValue)
        self.latitude = try container.decodeIfPresent(Double.self, forKey: .latitude)
        self.longitude = try container.decodeIfPresent(Double.self, forKey: .longitude)
        self.radiusMeters = try container.decodeIfPresent(Double.self, forKey: .radiusMeters) ?? 10.0
        self.smsMatchMode = try container.decodeIfPresent(RuleSMSMatchMode.self, forKey: .smsMatchMode)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(field, forKey: .field)
        try container.encode(value, forKey: .value)
        try container.encode(displayValue, forKey: .displayValue)
        try container.encodeIfPresent(latitude, forKey: .latitude)
        try container.encodeIfPresent(longitude, forKey: .longitude)
        if radiusMeters != 15.0 || latitude != nil {
            try container.encode(radiusMeters, forKey: .radiusMeters)
        }
        try container.encodeIfPresent(smsMatchMode, forKey: .smsMatchMode)
    }
}

// MARK: - Transfer Kind & Rule Actions

enum RuleTransferKind: String, Codable, CaseIterable, Identifiable {
    case internalTransfer = "internal"
    case externalTransfer = "external"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .internalTransfer: return "Internal Transfer"
        case .externalTransfer: return "External Transfer"
        }
    }
}

struct RuleActions: Codable, Hashable {
    /// Optional Category override. If nil, rule leaves transaction category unchanged.
    var setCategoryRaw: String?
    /// Legacy field for backward compatibility
    var categoryRaw: String?
    /// When the rule classifies a transaction as a Transfer, defines whether it is Internal or External.
    var transferKind: RuleTransferKind?
    /// Force-routes the transaction to a designated account.
    var overrideAccountID: UUID?
    /// For Internal Transfers: From Account (`accountID`).
    var fromAccountID: UUID?
    /// For Internal Transfers: To Account (`toAccountID`).
    var toAccountID: UUID?

    // Additional optional actions from available transaction fields:
    var setMerchant: String?
    var setBank: String?
    var setLocationName: String?
    var setLocationAddress: String?
    var setLatitude: Double?
    var setLongitude: Double?
    var setNote: String?
    var setGoalID: UUID?
    var setIsIncome: Bool?

    enum CodingKeys: String, CodingKey {
        case setCategoryRaw
        case categoryRaw
        case transferKind
        case overrideAccountID
        case fromAccountID
        case toAccountID
        case setMerchant
        case setBank
        case setLocationName
        case setLocationAddress
        case setLatitude
        case setLongitude
        case setNote
        case setGoalID
        case setIsIncome
    }

    init(
        setCategoryRaw: String? = nil,
        categoryRaw: String? = nil,
        transferKind: RuleTransferKind? = nil,
        overrideAccountID: UUID? = nil,
        fromAccountID: UUID? = nil,
        toAccountID: UUID? = nil,
        setMerchant: String? = nil,
        setBank: String? = nil,
        setLocationName: String? = nil,
        setLocationAddress: String? = nil,
        setLatitude: Double? = nil,
        setLongitude: Double? = nil,
        setNote: String? = nil,
        setGoalID: UUID? = nil,
        setIsIncome: Bool? = nil
    ) {
        self.setCategoryRaw = setCategoryRaw ?? categoryRaw
        self.categoryRaw = self.setCategoryRaw
        self.transferKind = transferKind
        self.overrideAccountID = overrideAccountID
        self.fromAccountID = fromAccountID
        self.toAccountID = toAccountID
        self.setMerchant = setMerchant
        self.setBank = setBank
        self.setLocationName = setLocationName
        self.setLocationAddress = setLocationAddress
        self.setLatitude = setLatitude
        self.setLongitude = setLongitude
        self.setNote = setNote
        self.setGoalID = setGoalID
        self.setIsIncome = setIsIncome
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try container.decodeIfPresent(String.self, forKey: .setCategoryRaw)
            ?? container.decodeIfPresent(String.self, forKey: .categoryRaw)
        self.setCategoryRaw = raw
        self.categoryRaw = raw
        self.transferKind = try container.decodeIfPresent(RuleTransferKind.self, forKey: .transferKind)
        self.overrideAccountID = try container.decodeIfPresent(UUID.self, forKey: .overrideAccountID)
        self.fromAccountID = try container.decodeIfPresent(UUID.self, forKey: .fromAccountID)
        self.toAccountID = try container.decodeIfPresent(UUID.self, forKey: .toAccountID)
        self.setMerchant = try container.decodeIfPresent(String.self, forKey: .setMerchant)
        self.setBank = try container.decodeIfPresent(String.self, forKey: .setBank)
        self.setLocationName = try container.decodeIfPresent(String.self, forKey: .setLocationName)
        self.setLocationAddress = try container.decodeIfPresent(String.self, forKey: .setLocationAddress)
        self.setLatitude = try container.decodeIfPresent(Double.self, forKey: .setLatitude)
        self.setLongitude = try container.decodeIfPresent(Double.self, forKey: .setLongitude)
        self.setNote = try container.decodeIfPresent(String.self, forKey: .setNote)
        self.setGoalID = try container.decodeIfPresent(UUID.self, forKey: .setGoalID)
        self.setIsIncome = try container.decodeIfPresent(Bool.self, forKey: .setIsIncome)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(setCategoryRaw ?? categoryRaw, forKey: .setCategoryRaw)
        try container.encodeIfPresent(setCategoryRaw ?? categoryRaw, forKey: .categoryRaw)
        try container.encodeIfPresent(transferKind, forKey: .transferKind)
        try container.encodeIfPresent(overrideAccountID, forKey: .overrideAccountID)
        try container.encodeIfPresent(fromAccountID, forKey: .fromAccountID)
        try container.encodeIfPresent(toAccountID, forKey: .toAccountID)
        try container.encodeIfPresent(setMerchant, forKey: .setMerchant)
        try container.encodeIfPresent(setBank, forKey: .setBank)
        try container.encodeIfPresent(setLocationName, forKey: .setLocationName)
        try container.encodeIfPresent(setLocationAddress, forKey: .setLocationAddress)
        try container.encodeIfPresent(setLatitude, forKey: .setLatitude)
        try container.encodeIfPresent(setLongitude, forKey: .setLongitude)
        try container.encodeIfPresent(setNote, forKey: .setNote)
        try container.encodeIfPresent(setGoalID, forKey: .setGoalID)
        try container.encodeIfPresent(setIsIncome, forKey: .setIsIncome)
    }

    var category: SpendCategory? {
        get {
            guard let raw = setCategoryRaw ?? categoryRaw, !raw.isEmpty else { return nil }
            return SpendCategory(rawValue: raw)
        }
        set {
            setCategoryRaw = newValue?.rawValue
            categoryRaw = newValue?.rawValue
        }
    }

    var isTransferCategory: Bool {
        guard let cat = category else { return transferKind != nil }
        return cat == .transfers || cat == .internalTransfer || transferKind != nil
    }

    var effectiveTransferKind: RuleTransferKind? {
        if let transferKind { return transferKind }
        if category == .internalTransfer { return .internalTransfer }
        if category == .transfers { return .externalTransfer }
        return nil
    }
}

// MARK: - Transaction Rule Model

struct TransactionRule: Codable, Hashable, Identifiable {
    var id: UUID = UUID()
    var name: String
    var isEnabled: Bool = true
    var logic: RuleConditionLogic = .and
    var conditions: [RuleCondition]
    var actions: RuleActions
    var sourceTransactionID: UUID?
    var createdAt: Date = .now

    /// Normalized signature of this rule's conditions used to detect conflicting/duplicate rules.
    var conditionSignature: String {
        let sorted = conditions
            .map { cond -> String in
                if cond.field == .location, let lat = cond.latitude, let lon = cond.longitude {
                    return "location=geo:\(String(format: "%.4f,%.4f,%.0fm", lat, lon, cond.radiusMeters))"
                }
                if cond.field == .originalSMS {
                    let mode = (cond.smsMatchMode ?? .contains).rawValue
                    let val = cond.smsMatchMode == .exactTemplate
                        ? TransactionRuleStore.normalizeOriginalSMSForExactMatch(cond.value)
                        : cond.value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    return "originalSMS:\(mode)=\(val)"
                }
                return "\(cond.field.rawValue)=\(cond.value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
            }
            .sorted()
            .joined(separator: "&")
        return "\(logic.rawValue):\(sorted)"
    }
}

// MARK: - Candidate Context for Matching Future Transactions

struct RuleEvaluationContext {
    var merchant: String
    var recipientIBAN: String?
    var senderIBAN: String? = nil
    var trueRecipientIBAN: String? = nil
    var accountDigits: String?
    var bank: String?
    var smsSender: String?
    var accountID: UUID?
    var locationName: String?
    var latitude: Double?
    var longitude: Double?
    var amount: Double
    var isIncome: Bool
    var transactionType: SMSTransactionType? = nil
    var date: Date? = nil
    var reference: String?
    var note: String
    var rawText: String?

    init(from tx: MoneyTransaction) {
        self.merchant = tx.merchant
        self.recipientIBAN = tx.smsRecipientSuffix
        if let raw = tx.rawText?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            let parties = SMSParser.extractTransferParties(in: raw)
            self.senderIBAN = parties.senderSuffix
            self.trueRecipientIBAN = parties.recipientSuffix
        } else if tx.isIncome || tx.isTransferIn {
            self.senderIBAN = tx.smsRecipientSuffix
            self.trueRecipientIBAN = tx.smsAccountSuffix
        } else {
            self.senderIBAN = tx.smsAccountSuffix
            self.trueRecipientIBAN = tx.smsRecipientSuffix
        }
        self.accountDigits = tx.smsAccountSuffix
        self.bank = tx.smsBank
        self.smsSender = tx.smsSender
        self.accountID = tx.accountID
        self.locationName = tx.locationName
        self.latitude = tx.latitude
        self.longitude = tx.longitude
        self.amount = tx.amount
        self.isIncome = tx.isIncome
        self.transactionType = tx.effectiveTransactionType
        self.date = tx.date
        self.reference = tx.smsReference
        self.note = tx.note
        self.rawText = tx.rawText
    }

    init(
        merchant: String,
        recipientIBAN: String? = nil,
        senderIBAN: String? = nil,
        trueRecipientIBAN: String? = nil,
        accountDigits: String? = nil,
        bank: String? = nil,
        smsSender: String? = nil,
        accountID: UUID? = nil,
        locationName: String? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil,
        amount: Double,
        isIncome: Bool,
        transactionType: SMSTransactionType? = nil,
        date: Date? = nil,
        reference: String? = nil,
        note: String = "",
        rawText: String? = nil
    ) {
        self.merchant = merchant
        self.recipientIBAN = recipientIBAN
        self.senderIBAN = senderIBAN
        self.trueRecipientIBAN = trueRecipientIBAN
        self.accountDigits = accountDigits
        self.bank = bank
        self.smsSender = smsSender
        self.accountID = accountID
        self.locationName = locationName
        self.latitude = latitude
        self.longitude = longitude
        self.amount = amount
        self.isIncome = isIncome
        self.transactionType = transactionType
        self.date = date
        self.reference = reference
        self.note = note
        self.rawText = rawText
    }
}

// MARK: - Transaction Rule Store

@Observable
final class TransactionRuleStore {
    static let shared = TransactionRuleStore()

    private static let storageKey = "transaction_rules_v1"

    private(set) var rules: [TransactionRule] = []

    init() {
        load()
    }

    func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode([TransactionRule].self, from: data) else {
            rules = []
            return
        }
        rules = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(rules) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }

    // MARK: Capture Available Fields from a Selected Transaction

    /// Automatically captures all non-empty fields available in the selected transaction.
    static func captureAvailableConditions(from tx: MoneyTransaction, accounts: [Account]) -> [RuleCondition] {
        var captured: [RuleCondition] = []

        // 1. Original SMS (first option)
        if let raw = tx.rawText?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            let primarySMS = raw.components(separatedBy: "\n\n---\n\n").first?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? raw
            if !primarySMS.isEmpty {
                captured.append(RuleCondition(
                    field: .originalSMS,
                    value: primarySMS,
                    displayValue: primarySMS,
                    smsMatchMode: .contains
                ))
            }
        }

        let cleanMerchant = tx.merchant.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanMerchant.isEmpty {
            captured.append(RuleCondition(
                field: .merchant,
                value: cleanMerchant,
                displayValue: cleanMerchant
            ))
        }

        let partyInfo: (senderSuffix: String?, recipientSuffix: String?, isIncoming: Bool) = {
            if let raw = tx.rawText?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
                return SMSParser.extractTransferParties(in: raw)
            }
            if tx.isIncome || tx.isTransferIn {
                return (tx.smsRecipientSuffix, tx.smsAccountSuffix, true)
            }
            return (tx.smsAccountSuffix, tx.smsRecipientSuffix, false)
        }()

        if let senderSuf = partyInfo.senderSuffix?.trimmingCharacters(in: .whitespacesAndNewlines), !senderSuf.isEmpty {
            captured.append(RuleCondition(
                field: .senderIBAN,
                value: senderSuf,
                displayValue: "**\(senderSuf)"
            ))
        }

        if let recip = partyInfo.recipientSuffix?.trimmingCharacters(in: .whitespacesAndNewlines), !recip.isEmpty {
            captured.append(RuleCondition(
                field: .recipientIBAN,
                value: recip,
                displayValue: "**\(recip)"
            ))
        } else if partyInfo.senderSuffix == nil,
                  let recip = tx.smsRecipientSuffix?.trimmingCharacters(in: .whitespacesAndNewlines), !recip.isEmpty {
            captured.append(RuleCondition(
                field: .recipientIBAN,
                value: recip,
                displayValue: "**\(recip)"
            ))
        }

        if let acctDigits = tx.smsAccountSuffix?.trimmingCharacters(in: .whitespacesAndNewlines), !acctDigits.isEmpty {
            captured.append(RuleCondition(
                field: .accountDigits,
                value: acctDigits,
                displayValue: "**\(acctDigits)"
            ))
        }

        if let sender = tx.smsSender?.trimmingCharacters(in: .whitespacesAndNewlines), !sender.isEmpty {
            captured.append(RuleCondition(
                field: .smsSender,
                value: sender,
                displayValue: sender
            ))
        }

        if let accountID = tx.accountID,
           let account = accounts.first(where: { $0.id == accountID }) {
            captured.append(RuleCondition(
                field: .accountID,
                value: accountID.uuidString,
                displayValue: account.name
            ))
        }

        let hasCoords = (tx.latitude != nil && tx.longitude != nil)
        let locName = tx.locationName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if hasCoords || (locName != nil && !locName!.isEmpty) {
            let placeName = (locName != nil && !locName!.isEmpty) ? locName! : "GPS Location"
            let display: String = {
                if hasCoords {
                    return "\(placeName) (within 10m)"
                } else {
                    return placeName
                }
            }()
            captured.append(RuleCondition(
                field: .location,
                value: placeName,
                displayValue: display,
                latitude: tx.latitude,
                longitude: tx.longitude,
                radiusMeters: 10.0
            ))
        }

        if tx.amount > 0 {
            let cur = UserDefaults.standard.string(forKey: Keys.currency) ?? "BHD"
            captured.append(RuleCondition(
                field: .amount,
                value: String(format: "%.3f", tx.amount),
                displayValue: Money.format(tx.amount, cur)
            ))
        }

        let txTypeOption = RuleTransactionTypeOption.from(txType: tx.effectiveTransactionType, isIncome: tx.isIncome)
        captured.append(RuleCondition(
            field: .direction,
            value: txTypeOption.rawValue,
            displayValue: txTypeOption.title
        ))

        let cal = Calendar.current
        let month = cal.component(.month, from: tx.date)
        let day = cal.component(.day, from: tx.date)
        captured.append(RuleCondition(
            field: .monthDay,
            value: RuleDateHelper.monthDayValue(month: month, day: day),
            displayValue: RuleDateHelper.monthDayDisplay(month: month, day: day)
        ))

        let weekday = cal.component(.weekday, from: tx.date)
        captured.append(RuleCondition(
            field: .dayOfWeek,
            value: "\(weekday)",
            displayValue: RuleDateHelper.weekdayDisplay(weekday)
        ))

        return captured
    }

    // MARK: Conflict & Duplicate Rule Prevention

    /// Returns an existing rule if it has the exact same condition signature (excluding `excludingRuleID`).
    func conflictingRule(for candidate: TransactionRule, excludingRuleID: UUID? = nil) -> TransactionRule? {
        let sig = candidate.conditionSignature
        return rules.first { existing in
            if let excludingRuleID, existing.id == excludingRuleID { return false }
            return existing.conditionSignature == sig
        }
    }

    // MARK: CRUD & Priority Management

    /// Adds a user-approved rule. If a rule with identical conditions already exists, updates it instead of creating a duplicate.
    @discardableResult
    func addRule(_ rule: TransactionRule) -> TransactionRule {
        guard !rule.conditions.isEmpty else { return rule }
        if let conflictIdx = rules.firstIndex(where: { $0.id == rule.id || $0.conditionSignature == rule.conditionSignature }) {
            var updated = rule
            updated.id = rules[conflictIdx].id
            rules[conflictIdx] = updated
            save()
            return updated
        }
        rules.append(rule)
        save()
        return rule
    }

    func updateRule(_ rule: TransactionRule) {
        guard let idx = rules.firstIndex(where: { $0.id == rule.id }) else { return }
        rules[idx] = rule
        save()
    }

    func toggleRule(id: UUID) {
        guard let idx = rules.firstIndex(where: { $0.id == id }) else { return }
        rules[idx].isEnabled.toggle()
        save()
    }

    func setRuleEnabled(id: UUID, isEnabled: Bool) {
        guard let idx = rules.firstIndex(where: { $0.id == id }) else { return }
        rules[idx].isEnabled = isEnabled
        save()
    }

    func deleteRule(id: UUID) {
        rules.removeAll { $0.id == id }
        save()
    }

    func deleteRules(at offsets: IndexSet) {
        for index in offsets.sorted(by: >) {
            if rules.indices.contains(index) {
                rules.remove(at: index)
            }
        }
        save()
    }

    func deleteAll() {
        rules.removeAll()
        UserDefaults.standard.removeObject(forKey: Self.storageKey)
    }

    func clearAll() {
        deleteAll()
    }

    /// Returns all rules associated with or matching a transaction, sorted by specificity (most specific first).
    func rulesForTransaction(_ tx: MoneyTransaction) -> [TransactionRule] {
        let context = RuleEvaluationContext(from: tx)
        return rules
            .filter { rule in
                rule.sourceTransactionID == tx.id || matches(rule: rule, context: context, ignoreEnabledState: true)
            }
            .sorted { Self.staticSpecificityScore(for: $0) > Self.staticSpecificityScore(for: $1) }
    }

    // MARK: - Specificity-Based Evaluation & Conflict Detection

    struct RuleSpecificityMatch {
        let rule: TransactionRule
        let score: Int
        let matchedConditions: [RuleCondition]

        var matchedSummary: String {
            matchedConditions.map { "\($0.field.label) (\($0.displayValue))" }.joined(separator: " + ")
        }
    }

    enum RuleResolutionResult {
        case noMatch
        case matched(RuleSpecificityMatch, reason: String)
        case conflict(matches: [RuleSpecificityMatch], score: Int, reason: String)

        var winningRule: TransactionRule? {
            if case .matched(let m, _) = self { return m.rule }
            return nil
        }

        var conflictingRules: [TransactionRule] {
            if case .conflict(let matches, _, _) = self { return matches.map(\.rule) }
            return []
        }
    }

    /// Specificity weight for a single condition. More precise signals (exact SMS template, exact amount,
    /// GPS location, recipient IBAN) outweigh broad signals (bank, phone number, direction).
    static func specificityWeight(for condition: RuleCondition) -> Int {
        switch condition.field {
        case .originalSMS:
            if condition.smsMatchMode == .exactTemplate {
                return 100
            }
            let len = condition.value.trimmingCharacters(in: .whitespacesAndNewlines).count
            return 45 + min(15, len / 6)
        case .reference:
            return 95
        case .amount:
            return 60
        case .location:
            if condition.latitude != nil && condition.longitude != nil {
                return condition.radiusMeters <= 25 ? 60 : 55
            }
            return 35
        case .senderIBAN:
            return 45
        case .recipientIBAN:
            return 45
        case .accountDigits:
            return 40
        case .merchant:
            return 35
        case .monthDay:
            return 35
        case .accountID:
            return 30
        case .note:
            return 30
        case .dayOfWeek:
            return 25
        case .smsSender:
            return 20
        case .bank:
            return 15
        case .direction:
            return 15
        }
    }

    /// Static specificity score for a rule (used for displaying specificity badges in the UI).
    static func staticSpecificityScore(for rule: TransactionRule) -> Int {
        guard !rule.conditions.isEmpty else { return 0 }
        switch rule.logic {
        case .and:
            let base = rule.conditions.reduce(0) { $0 + specificityWeight(for: $1) }
            let compoundBonus = max(0, rule.conditions.count - 1) * 15
            return base + compoundBonus
        case .or:
            return rule.conditions.map { specificityWeight(for: $0) }.max() ?? 0
        }
    }

    /// Evaluates a single rule against `context` and returns its dynamic specificity match if satisfied.
    func evaluateSpecificity(rule: TransactionRule, context: RuleEvaluationContext, ignoreEnabledState: Bool = false) -> RuleSpecificityMatch? {
        if !ignoreEnabledState && !rule.isEnabled { return nil }
        guard !rule.conditions.isEmpty else { return nil }

        switch rule.logic {
        case .and:
            guard rule.conditions.allSatisfy({ conditionMatches($0, context: context) }) else { return nil }
            let base = rule.conditions.reduce(0) { $0 + Self.specificityWeight(for: $1) }
            let compoundBonus = max(0, rule.conditions.count - 1) * 15
            return RuleSpecificityMatch(rule: rule, score: base + compoundBonus, matchedConditions: rule.conditions)

        case .or:
            let hits = rule.conditions.filter { conditionMatches($0, context: context) }
            guard !hits.isEmpty else { return nil }
            let strongest = hits.map { Self.specificityWeight(for: $0) }.max() ?? 0
            let extraHitBonus = max(0, hits.count - 1) * 5
            return RuleSpecificityMatch(rule: rule, score: strongest + extraHitBonus, matchedConditions: hits)
        }
    }

    /// Evaluates ALL enabled rules before executing any.
    /// - Selects the single most specific matching rule regardless of creation order.
    /// - If multiple rules tie for the highest specificity with different outcomes, returns `.conflict`
    ///   instead of silently picking one.
    func evaluateRules(for context: RuleEvaluationContext) -> RuleResolutionResult {
        let candidates = rules
            .filter(\.isEnabled)
            .compactMap { evaluateSpecificity(rule: $0, context: context, ignoreEnabledState: false) }
            .sorted { $0.score > $1.score }

        guard let top = candidates.first else { return .noMatch }
        let tiedTop = candidates.filter { $0.score == top.score }

        if tiedTop.count == 1 {
            let otherCount = candidates.count - 1
            let suffix = otherCount > 0 ? " (most specific of \(candidates.count) matching rules)" : ""
            let reason = "Rule: \(top.rule.name) · Matched \(top.matchedSummary)\(suffix)"
            return .matched(top, reason: reason)
        }

        // If all tied rules produce identical outcomes, no real conflict exists
        let firstActions = tiedTop[0].rule.actions
        if tiedTop.allSatisfy({ $0.rule.actions == firstActions }) {
            let reason = "Rule: \(top.rule.name) · Matched \(top.matchedSummary)"
            return .matched(top, reason: reason)
        }

        let names = tiedTop.map(\.rule.name).joined(separator: " vs ")
        let reason = "Rule conflict: \(names) have equal specificity (score \(top.score)) with different actions — review required"
        return .conflict(matches: tiedTop, score: top.score, reason: reason)
    }

    func evaluateRules(for tx: MoneyTransaction) -> RuleResolutionResult {
        evaluateRules(for: RuleEvaluationContext(from: tx))
    }

    /// Convenience helper returning the winning rule only when there is an unambiguous best match (nil on noMatch or conflict).
    func bestMatchingRule(for context: RuleEvaluationContext) -> TransactionRule? {
        evaluateRules(for: context).winningRule
    }

    func bestMatchingRule(for tx: MoneyTransaction) -> TransactionRule? {
        bestMatchingRule(for: RuleEvaluationContext(from: tx))
    }

    /// Returns true if `tx` was previously classified by a Transaction Rule that is currently switched OFF.
    /// Prevents `Categorizer.learnedMatch` from re-applying a disabled rule's category to future transactions.
    func wasClassifiedByDisabledRule(_ tx: MoneyTransaction) -> Bool {
        let disabledRules = rules.filter { !$0.isEnabled }
        guard !disabledRules.isEmpty else { return false }
        let reason = tx.smsClassificationReason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reason.isEmpty else { return false }

        for rule in disabledRules {
            let cleanName = rule.name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleanName.isEmpty && (reason == "Matched: \(cleanName)" || reason.hasPrefix("Rule: \(cleanName)") || reason.contains("(\(cleanName))")) {
                return true
            }
        }
        if reason.hasPrefix("Matched:") || reason.hasPrefix("Matched Rule") || reason.hasPrefix("Rule:") {
            let ctx = RuleEvaluationContext(from: tx)
            if disabledRules.contains(where: { matches(rule: $0, context: ctx, ignoreEnabledState: true) }) {
                return true
            }
        }
        return false
    }

    func matches(rule: TransactionRule, context: RuleEvaluationContext, ignoreEnabledState: Bool = false) -> Bool {
        if !ignoreEnabledState && !rule.isEnabled { return false }
        guard !rule.conditions.isEmpty else { return false }

        switch rule.logic {
        case .and:
            return rule.conditions.allSatisfy { conditionMatches($0, context: context) }
        case .or:
            return rule.conditions.contains { conditionMatches($0, context: context) }
        }
    }

    private func conditionMatches(_ condition: RuleCondition, context: RuleEvaluationContext) -> Bool {
        let target = condition.value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return false }
        let targetLower = target.lowercased()
        let rawLower = (context.rawText ?? "").lowercased()

        switch condition.field {
        case .originalSMS:
            guard !rawLower.isEmpty else { return false }
            let mode = condition.smsMatchMode ?? .contains
            switch mode {
            case .contains:
                return rawLower.contains(targetLower)
            case .exactTemplate:
                let normTarget = Self.normalizeOriginalSMSForExactMatch(target)
                guard !normTarget.isEmpty else { return false }
                let rawParts = (context.rawText ?? "").components(separatedBy: "\n\n---\n\n")
                return rawParts.contains { part in
                    Self.normalizeOriginalSMSForExactMatch(part) == normTarget
                }
            }

        case .merchant:
            let m = context.merchant.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !m.isEmpty && (m == targetLower || m.contains(targetLower) || targetLower.contains(m)) {
                return true
            }
            return !rawLower.isEmpty && rawLower.contains(targetLower)

        case .senderIBAN:
            let cleanTarget = targetLower.replacingOccurrences(of: "*", with: "")
            guard !cleanTarget.isEmpty else { return false }
            if let senderDigits = context.senderIBAN?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !senderDigits.isEmpty {
                let cleanSender = senderDigits.replacingOccurrences(of: "*", with: "")
                return cleanSender == cleanTarget || cleanSender.hasSuffix(cleanTarget) || cleanTarget.hasSuffix(cleanSender)
            }
            return false

        case .recipientIBAN:
            let cleanTarget = targetLower.replacingOccurrences(of: "*", with: "")
            guard !cleanTarget.isEmpty else { return false }
            if let trueRecip = context.trueRecipientIBAN?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !trueRecip.isEmpty {
                let cleanRecip = trueRecip.replacingOccurrences(of: "*", with: "")
                return cleanRecip == cleanTarget || cleanRecip.hasSuffix(cleanTarget) || cleanTarget.hasSuffix(cleanRecip)
            }
            // If senderIBAN was extracted and trueRecipientIBAN is nil (incoming SMS with sender only), do not match sender as recipient.
            if let senderDigits = context.senderIBAN, !senderDigits.isEmpty {
                return false
            }
            if let recip = context.recipientIBAN?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !recip.isEmpty {
                let cleanRecip = recip.replacingOccurrences(of: "*", with: "")
                if cleanRecip == cleanTarget || cleanRecip.hasSuffix(cleanTarget) || cleanTarget.hasSuffix(cleanRecip) {
                    return true
                }
            }
            return !rawLower.isEmpty && rawLower.contains(cleanTarget)

        case .accountDigits:
            let cleanTarget = targetLower.replacingOccurrences(of: "*", with: "")
            if let digits = context.accountDigits?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !digits.isEmpty {
                let cleanDigits = digits.replacingOccurrences(of: "*", with: "")
                if cleanDigits == cleanTarget || cleanDigits.hasSuffix(cleanTarget) || cleanTarget.hasSuffix(cleanDigits) {
                    return true
                }
            }
            return !rawLower.isEmpty && !cleanTarget.isEmpty && rawLower.contains(cleanTarget)

        case .bank:
            guard let bank = context.bank?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !bank.isEmpty else {
                return false
            }
            return bank == targetLower || bank.contains(targetLower) || targetLower.contains(bank)

        case .smsSender:
            guard let sender = context.smsSender?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !sender.isEmpty else {
                return false
            }
            return sender == targetLower || sender.contains(targetLower) || targetLower.contains(sender)

        case .accountID:
            guard let acct = context.accountID else { return false }
            return acct.uuidString.caseInsensitiveCompare(target) == .orderedSame

        case .location:
            // 1. Primary matching: GPS coordinates and radius-based distance
            if let ruleLat = condition.latitude, let ruleLon = condition.longitude {
                if let txLat = context.latitude, let txLon = context.longitude {
                    let distanceMeters = Self.distanceBetween(lat1: ruleLat, lon1: ruleLon, lat2: txLat, lon2: txLon)
                    let allowedRadius = condition.radiusMeters > 0 ? condition.radiusMeters : 10.0
                    return distanceMeters <= allowedRadius
                }
                // If transaction lacks coordinates, do not trigger false positive based solely on name
                return false
            }

            // 2. Fallback for legacy rules without coordinates: match location place name
            if let loc = context.locationName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !loc.isEmpty {
                if loc == targetLower || loc.contains(targetLower) || targetLower.contains(loc) {
                    return true
                }
            }
            return !rawLower.isEmpty && rawLower.contains(targetLower)

        case .amount:
            guard let expected = Double(target) else { return false }
            return abs(context.amount - expected) < 0.001

        case .direction:
            guard let expectedType = RuleTransactionTypeOption.parse(target) else {
                let expectedIncome = (targetLower == "in" || targetLower == "income" || targetLower == "true")
                return context.isIncome == expectedIncome
            }
            switch expectedType {
            case .transferIn:
                if let t = context.transactionType { return t == .transferIn }
                return context.isIncome
            case .transferOut:
                if let t = context.transactionType { return t == .transferOut }
                return !context.isIncome
            case .internalTransfer:
                return context.transactionType == .internalTransfer
            case .expense:
                if let t = context.transactionType { return t == .expense || t == .fee }
                return !context.isIncome
            case .income:
                if let t = context.transactionType { return t == .income || t == .refund }
                return context.isIncome
            }

        case .monthDay:
            guard let date = context.date, let expected = RuleDateHelper.parseMonthDay(target) else { return false }
            let cal = Calendar.current
            return cal.component(.month, from: date) == expected.month
                && cal.component(.day, from: date) == expected.day

        case .dayOfWeek:
            guard let date = context.date, let expectedWeekday = RuleDateHelper.parseWeekday(target) else { return false }
            return Calendar.current.component(.weekday, from: date) == expectedWeekday

        case .reference:
            if let ref = context.reference?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !ref.isEmpty {
                return ref == targetLower || ref.contains(targetLower)
            }
            return !rawLower.isEmpty && rawLower.contains(targetLower)

        case .note:
            let n = context.note.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return !n.isEmpty && (n == targetLower || n.contains(targetLower))
        }
    }

    // MARK: Applying Best-Matching Rule (Specificity-Based)

    /// Evaluates ALL enabled rules and executes ONLY the single most specific matching rule.
    /// If multiple rules tie for equal specificity with different outcomes, flags the conflict on `tx`
    /// for in-page user review without executing either rule.
    @discardableResult
    func applyBestMatchingRuleIfAny(to tx: MoneyTransaction, context: ModelContext? = nil) -> RuleResolutionResult {
        let resolution = evaluateRules(for: tx)
        switch resolution {
        case .noMatch:
            tx.ruleConflictIDsRaw = ""
        case .matched(let match, let reason):
            apply(rule: match.rule, to: tx, explanation: reason)
        case .conflict(let matches, _, let reason):
            tx.ruleConflictIDs = matches.map(\.rule.id)
            tx.smsClassificationReason = reason
        }
        return resolution
    }

    func apply(rule: TransactionRule, to tx: MoneyTransaction, explanation: String? = nil) {
        let actions = rule.actions

        // 1. Optional direction override
        if let setIsIncome = actions.setIsIncome {
            tx.isIncome = setIsIncome
        }

        // 2. Override Account (Force-routes the transaction to designated account)
        if let overrideID = actions.overrideAccountID ?? actions.fromAccountID {
            tx.accountID = overrideID
        }

        // 3. Category & Transfer handling
        if let transferKind = actions.effectiveTransferKind {
            switch transferKind {
            case .internalTransfer:
                tx.category = .internalTransfer
                tx.smsTransactionType = .internalTransfer
                tx.isIncome = false
                if let fromID = actions.fromAccountID ?? actions.overrideAccountID {
                    tx.accountID = fromID
                }
                if let toID = actions.toAccountID, toID != tx.accountID {
                    tx.toAccountID = toID
                }
            case .externalTransfer:
                tx.category = .transfers
                tx.smsTransactionType = tx.isIncome ? .transferIn : .transferOut
                tx.toAccountID = nil
                tx.goalID = nil
                if let fromID = actions.fromAccountID ?? actions.overrideAccountID {
                    tx.accountID = fromID
                }
            }
        } else if let cat = actions.category {
            tx.category = cat
            if cat == .transferIn {
                tx.isIncome = true
                tx.smsTransactionType = .transferIn
                tx.toAccountID = nil
            } else if cat.isTransferCategory {
                tx.isIncome = false
                tx.smsTransactionType = .transferOut
                tx.toAccountID = nil
            } else if cat.isIncomeCategory {
                tx.isIncome = true
                if tx.source == .sms {
                    tx.smsTransactionType = .income
                }
                tx.toAccountID = nil
            } else {
                if tx.source == .sms && (tx.smsTransactionType == nil || tx.smsTransactionType == .unknown || tx.smsTransactionType == .internalTransfer || tx.smsTransactionType == .transferOut || tx.smsTransactionType == .transferIn) {
                    tx.smsTransactionType = tx.isIncome ? .income : .expense
                }
                tx.toAccountID = nil
            }
            if let fromID = actions.fromAccountID ?? actions.overrideAccountID {
                tx.accountID = fromID
            }
        }

        // 4. Additional field actions
        if let merchant = actions.setMerchant?.trimmingCharacters(in: .whitespacesAndNewlines), !merchant.isEmpty {
            tx.merchant = merchant
        }
        if let bank = actions.setBank?.trimmingCharacters(in: .whitespacesAndNewlines), !bank.isEmpty {
            tx.smsBank = bank
        }
        if let locName = actions.setLocationName?.trimmingCharacters(in: .whitespacesAndNewlines), !locName.isEmpty {
            tx.locationName = locName
            if let addr = actions.setLocationAddress {
                tx.locationAddress = addr
            }
            if let lat = actions.setLatitude, let lon = actions.setLongitude {
                tx.latitude = lat
                tx.longitude = lon
            }
        }
        if let note = actions.setNote?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty {
            tx.note = note
        }
        if let goalID = actions.setGoalID {
            tx.goalID = goalID
        }

        tx.ruleConflictIDsRaw = ""
        tx.smsConfidence = .high
        tx.smsClassificationReason = explanation ?? "Rule: \(rule.name)"
        tx.aiCategorized = false
    }

    /// Normalizes an SMS message for "Exactly match" comparisons by masking dynamic fields
    /// that change on every alert: balances, reference codes, dates, and times.
    static func normalizeOriginalSMSForExactMatch(_ sms: String) -> String {
        // Convert Arabic-Indic / Persian digits to ASCII digits first
        let digitMap: [Character: Character] = [
            "٠": "0", "١": "1", "٢": "2", "٣": "3", "٤": "4",
            "٥": "5", "٦": "6", "٧": "7", "٨": "8", "٩": "9",
            "۰": "0", "۱": "1", "۲": "2", "۳": "3", "۴": "4",
            "۵": "5", "۶": "6", "۷": "7", "۸": "8", "۹": "9"
        ]
        var s = String(sms.map { digitMap[$0] ?? $0 })
            .lowercased()
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let replacements: [(pattern: String, token: String)] = [
            // 1. Balance clauses (English & Arabic)
            ("(?i)\\b(?:available\\s+balance|avail(?:able)?\\s+bal\\.?|avl\\.?\\s*bal\\.?|new\\s+balance|curr(?:ent)?\\s+bal(?:ance)?|bal(?:ance)?)\\s*(?:is|:)?\\s*(?:bhd|bd|usd|eur|gbp|sar|aed|kwd|qar|omr)?\\s*[0-9][0-9,]*(?:\\.[0-9]+)?\\s*(?:bhd|bd|usd|eur|gbp|sar|aed|kwd|qar|omr)?", "<BALANCE>"),
            ("(?:الرصيد\\s+المتاح|رصيدك\\s+المتاح|الرصيد\\s+الحالي|الرصيد)\\s*[:\\-]?\\s*[0-9][0-9,]*(?:\\.[0-9]+)?\\s*(?:د\\.ب|دب|ب\\.د|bhd|bd)?", "<BALANCE>"),
            // 2. Reference codes / transaction IDs (English & Arabic)
            ("(?i)\\b(?:ref(?:erence)?\\s*(?:no\\.?|number|id)?|txn\\s*id|trans(?:action)?\\s*id|rrn|auth\\s*(?:code)?)\\s*[:\\.#\\-]?\\s*[a-z0-9\\-]{4,32}", "<REF>"),
            ("(?:رقم\\s+المرجع|المرجع)\\s*[:\\-]?\\s*[a-z0-9\\-]{4,32}", "<REF>"),
            // 3. Dates (YYYY/MM/DD, DD/MM/YYYY, DD-MM-YY, DD Mon YYYY, DD-Mon, DD/MM)
            ("\\b\\d{4}[/\\-]\\d{1,2}[/\\-]\\d{1,2}\\b", "<DATE>"),
            ("\\b\\d{1,2}[/\\-]\\d{1,2}[/\\-]\\d{2,4}\\b", "<DATE>"),
            ("(?i)\\b\\d{1,2}[\\s\\-]+(?:jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)[a-z]*(?:[\\s,\\-]+\\d{2,4})?\\b", "<DATE>"),
            ("\\b\\d{1,2}/\\d{1,2}\\b", "<DATE>"),
            // 4. Times (HH:MM:SS, HH:MM AM/PM, HH:MM)
            ("(?i)\\b\\d{1,2}:\\d{2}(?::\\d{2})?(?:\\s*(?:am|pm))?\\b", "<TIME>")
        ]

        for (pattern, token) in replacements {
            s = s.replacingOccurrences(of: pattern, with: token, options: .regularExpression)
        }

        s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return s
    }

    // MARK: - Distance Calculation Helper

    /// Calculates the geodetic distance in meters between two GPS coordinates using WGS 84 ellipsoid (CoreLocation).
    static func distanceBetween(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
        let loc1 = CLLocation(latitude: lat1, longitude: lon1)
        let loc2 = CLLocation(latitude: lat2, longitude: lon2)
        return loc1.distance(from: loc2)
    }
}
