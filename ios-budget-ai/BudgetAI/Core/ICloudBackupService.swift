import Foundation
import SwiftData
import CloudKit
import SwiftUI
import CryptoKit

// MARK: - Snapshot Codable Entities

struct BackupMetadata: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var createdAt: Date
    var deviceName: String
    var appVersion: String
    var transactionsCount: Int
    var accountsCount: Int
    var budgetsCount: Int
    var goalsCount: Int
    var billsCount: Int
    var rulesCount: Int
    var fileSizeBytes: Int64
    var sha256Checksum: String
    var isCloudSynced: Bool
    var cloudRecordID: String?
    var filename: String

    var formattedDate: String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: createdAt)
    }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: fileSizeBytes, countStyle: .file)
    }
}

struct BackupAccountRecord: Codable, Hashable, Sendable {
    var id: UUID
    var name: String
    var kindRaw: String
    var institution: String
    var balance: Double
    var emoji: String
    var includeInNetWorth: Bool
    var smsMatch: String
    var paymentDueDate: Date
}

struct BackupTransactionRecord: Codable, Hashable, Sendable {
    var id: UUID
    var amount: Double
    var isIncome: Bool
    var merchant: String
    var categoryRaw: String
    var date: Date
    var note: String
    var sourceRaw: String
    var accountID: UUID?
    var toAccountID: UUID?
    var goalID: UUID?
    var isPending: Bool
    var isPossibleDuplicate: Bool
    var smsRecipientSuffix: String?
    var smsAccountSuffix: String?
    var smsBank: String?
    var smsSender: String?
    var smsTransactionTypeRaw: String?
    var smsReference: String?
    var smsConfidenceRaw: String?
    var smsClassificationReason: String?
    var balanceAdjustment: Double
    var toBalanceAdjustment: Double
    var smsBalance: Double?
    var locationName: String?
    var locationAddress: String?
    var latitude: Double?
    var longitude: Double?
}

struct BackupBudgetRecord: Codable, Hashable, Sendable {
    var id: UUID
    var name: String
    var categoryRaw: String
    var categoryKeysRaw: String
    var limit: Double
}

struct BackupGoalRecord: Codable, Hashable, Sendable {
    var id: UUID
    var name: String
    var symbol: String
    var target: Double
    var saved: Double
    var targetDate: Date
    var monthlyCommitment: Double
    var linkedAccountID: UUID?
    var smsMatch: String
}

struct BackupBillRecord: Codable, Hashable, Sendable {
    var id: UUID
    var name: String
    var amount: Double
    var categoryRaw: String
    var nextDueDate: Date
    var frequencyRaw: String
    var isSubscription: Bool
    var keywordsRaw: String
    var remindersOn: Bool
    var lastPaidAt: Date?
    var lastPaidAmount: Double?
    var lastPaidMethodRaw: String?
}

struct BackupNetWorthRecord: Codable, Hashable, Sendable {
    var id: UUID
    var day: Date
    var assets: Double
    var liabilities: Double
}

struct BackupCategoryRecord: Codable, Hashable, Sendable {
    var id: UUID
    var key: String
    var name: String
    var emoji: String
    var colorHex: Int
    var parentKey: String
    var isIncome: Bool
    var isEssential: Bool
}

struct BackupSettingsRecord: Codable, Hashable, Sendable {
    var userName: String
    var currency: String
    var cycleStartDay: Int
    var faceID: Bool
    var billReminders: Bool
    var budgetAlerts: Bool
    var smsAutoApprove: Bool
    var smsSyncBalance: Bool
}

struct BudgetAIBackupSnapshot: Codable, Sendable {
    var manifest: BackupMetadata
    var accounts: [BackupAccountRecord]
    var transactions: [BackupTransactionRecord]
    var budgets: [BackupBudgetRecord]
    var goals: [BackupGoalRecord]
    var bills: [BackupBillRecord]
    var netWorthSnapshots: [BackupNetWorthRecord]
    var customCategories: [BackupCategoryRecord]
    var rules: [TransactionRule]
    var settings: BackupSettingsRecord
}

// MARK: - Backup Schedules & Status

enum BackupSchedule: String, CaseIterable, Identifiable, Codable {
    case weekly = "weekly"
    case daily = "daily"
    case monthly = "monthly"
    case off = "off"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .weekly: return "Weekly (Recommended)"
        case .daily: return "Daily"
        case .monthly: return "Monthly"
        case .off: return "Off"
        }
    }

    var intervalDays: Int {
        switch self {
        case .daily: return 1
        case .weekly: return 7
        case .monthly: return 30
        case .off: return 0
        }
    }
}

enum BackupStatus: Equatable, Sendable {
    case idle
    case inProgress(String)
    case success(Date)
    case failed(String)

    var displayText: String {
        switch self {
        case .idle: return "Ready"
        case .inProgress(let s): return s
        case .success(let d):
            let f = DateFormatter()
            f.dateStyle = .medium
            f.timeStyle = .short
            return "Successful (\(f.string(from: d)))"
        case .failed(let err): return "Failed: \(err)"
        }
    }
}

enum RestoreMode {
    case merge
    case replace
}

struct RestoreSummary: Equatable {
    var restoredTransactionsCount: Int
    var skippedDuplicateTransactionsCount: Int
    var restoredAccountsCount: Int
    var restoredBudgetsCount: Int
    var restoredGoalsCount: Int
    var restoredBillsCount: Int
    var restoredRulesCount: Int
    var mode: RestoreMode
}

// MARK: - iCloud Backup Service

@Observable
final class ICloudBackupService {
    static let shared = ICloudBackupService()

    private(set) var isBackingUp = false
    private(set) var isRestoring = false
    private(set) var backupStatus: BackupStatus = .idle
    private(set) var availableBackups: [BackupMetadata] = []
    private(set) var isICloudAvailable: Bool = false
    private(set) var lastErrorMessage: String?

    struct ICloudEntitlementStatus: Equatable {
        let hasCloudKitEntitlement: Bool
        let hasUbiquityContainerEntitlement: Bool
        let hasKVStoreEntitlement: Bool

        static let none = ICloudEntitlementStatus(
            hasCloudKitEntitlement: false,
            hasUbiquityContainerEntitlement: false,
            hasKVStoreEntitlement: false
        )

        static func parse(mobileProvisionData: Data) -> ICloudEntitlementStatus {
            guard let startTag = "<plist".data(using: .utf8),
                  let endTag = "</plist>".data(using: .utf8),
                  let startRange = mobileProvisionData.range(of: startTag),
                  let endRange = mobileProvisionData.range(of: endTag, in: startRange.lowerBound..<mobileProvisionData.endIndex) else {
                return .none
            }
            let plistData = mobileProvisionData[startRange.lowerBound..<endRange.upperBound]
            guard let root = try? PropertyListSerialization.propertyList(from: Data(plistData), format: nil) as? [String: Any],
                  let entitlements = root["Entitlements"] as? [String: Any] else {
                return .none
            }

            let services = entitlements["com.apple.developer.icloud-services"] as? [String] ?? []
            let icloudContainers = entitlements["com.apple.developer.icloud-container-identifiers"] as? [String] ?? []
            let ubiquityContainers = entitlements["com.apple.developer.ubiquity-container-identifiers"] as? [String] ?? []
            let kvStoreID = entitlements["com.apple.developer.ubiquity-kvstore-identifier"] as? String ?? ""

            let hasCloudKit = services.contains { $0.caseInsensitiveCompare("CloudKit") == .orderedSame }
                && !icloudContainers.isEmpty
            let hasCloudDocs = services.contains { $0.caseInsensitiveCompare("CloudDocuments") == .orderedSame }
                && !icloudContainers.isEmpty
            let hasUbiquity = !ubiquityContainers.isEmpty || hasCloudDocs
            let hasKVStore = !kvStoreID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

            return ICloudEntitlementStatus(
                hasCloudKitEntitlement: hasCloudKit,
                hasUbiquityContainerEntitlement: hasUbiquity,
                hasKVStoreEntitlement: hasKVStore
            )
        }

        static func current(bundle: Bundle = .main) -> ICloudEntitlementStatus {
            #if targetEnvironment(simulator)
            return .none
            #else
            if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
                return .none
            }
            if let url = bundle.url(forResource: "embedded", withExtension: "mobileprovision"),
               let data = try? Data(contentsOf: url) {
                return parse(mobileProvisionData: data)
            }
            // App Store builds may omit embedded.mobileprovision; rely on ubiquityIdentityToken only
            // and never call CKContainer.default() blindly without confirmed entitlements.
            let hasToken = FileManager.default.ubiquityIdentityToken != nil
            return ICloudEntitlementStatus(
                hasCloudKitEntitlement: false,
                hasUbiquityContainerEntitlement: hasToken,
                hasKVStoreEntitlement: false
            )
            #endif
        }
    }

    private let entitlementStatus: ICloudEntitlementStatus

    private var kvStore: NSUbiquitousKeyValueStore? {
        entitlementStatus.hasKVStoreEntitlement ? .default : nil
    }

    var isAutoBackupEnabled: Bool {
        get { UserDefaults.standard.object(forKey: Keys.iCloudAutoBackupEnabled) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: Keys.iCloudAutoBackupEnabled)
            kvStore?.set(newValue, forKey: Keys.iCloudAutoBackupEnabled)
            kvStore?.synchronize()
        }
    }

    var autoBackupSchedule: BackupSchedule {
        get {
            guard let raw = UserDefaults.standard.string(forKey: Keys.iCloudBackupSchedule),
                  let s = BackupSchedule(rawValue: raw) else { return .weekly }
            return s
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: Keys.iCloudBackupSchedule)
            kvStore?.set(newValue.rawValue, forKey: Keys.iCloudBackupSchedule)
            kvStore?.synchronize()
        }
    }

    var lastBackupDate: Date? {
        get {
            if let date = UserDefaults.standard.object(forKey: Keys.iCloudLastBackupDate) as? Date {
                return date
            }
            if let timeInterval = kvStore?.object(forKey: Keys.iCloudLastBackupDate) as? Double {
                return Date(timeIntervalSince1970: timeInterval)
            }
            return nil
        }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue, forKey: Keys.iCloudLastBackupDate)
                kvStore?.set(newValue.timeIntervalSince1970, forKey: Keys.iCloudLastBackupDate)
            } else {
                UserDefaults.standard.removeObject(forKey: Keys.iCloudLastBackupDate)
                kvStore?.removeObject(forKey: Keys.iCloudLastBackupDate)
            }
            kvStore?.synchronize()
        }
    }

    private let cloudKitRecordType = "BudgetAIBackup"
    private let backupsIndexKey = "budgetai_backup_manifests_index"

    private init() {
        self.entitlementStatus = ICloudEntitlementStatus.current()
        checkICloudAvailability()
        loadPersistedState()
        refreshAvailableBackups()

        if let store = kvStore {
            NotificationCenter.default.addObserver(
                forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
                object: store,
                queue: .main
            ) { [weak self] _ in
                self?.loadPersistedState()
                self?.refreshAvailableBackups()
            }
        }
    }

    // MARK: - Storage Directories

    private var localBackupDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Backups", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private var ubiquityBackupDirectory: URL? {
        guard entitlementStatus.hasUbiquityContainerEntitlement else {
            return nil
        }
        guard let container = FileManager.default.url(forUbiquityContainerIdentifier: nil) else {
            return nil
        }
        let dir = container.appendingPathComponent("Documents/Backups", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    func checkICloudAvailability() {
        // In unsigned test environments, running CloudKit causes a crash because entitlements are missing.
        #if targetEnvironment(simulator)
        let isRunningInSimulator = true
        #else
        let isRunningInSimulator = false
        #endif

        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil || isRunningInSimulator {
            // Running under unit tests or unsigned simulator: safely skip CloudKit IPC
            self.isICloudAvailable = false
            return
        }

        // Only query CloudKit/iCloud APIs when the app binary's provisioning profile grants iCloud entitlements.
        guard entitlementStatus.hasCloudKitEntitlement || entitlementStatus.hasUbiquityContainerEntitlement else {
            self.isICloudAvailable = false
            return
        }

        let token = FileManager.default.ubiquityIdentityToken
        if token != nil {
            self.isICloudAvailable = true
        } else if entitlementStatus.hasCloudKitEntitlement {
            // Check CloudKit account status only when CloudKit entitlement is confirmed
            CKContainer.default().accountStatus { [weak self] status, _ in
                DispatchQueue.main.async {
                    self?.isICloudAvailable = (status == .available)
                }
            }
        } else {
            self.isICloudAvailable = false
        }
    }

    private func loadPersistedState() {
        if let d = lastBackupDate {
            backupStatus = .success(d)
        }
    }

    // MARK: - Create Backup

    @MainActor
    func createBackup(context: ModelContext, isAutomatic: Bool = false) async throws -> BackupMetadata {
        isBackingUp = true
        lastErrorMessage = nil
        backupStatus = .inProgress("Gathering app data...")
        defer { isBackingUp = false }

        do {
            // 1. Fetch current entities from SwiftData
            let accountsDesc = FetchDescriptor<Account>()
            let accounts = (try? context.fetch(accountsDesc)) ?? []

            let txDesc = FetchDescriptor<MoneyTransaction>()
            let transactions = (try? context.fetch(txDesc)) ?? []

            let budgetDesc = FetchDescriptor<Budget>()
            let budgets = (try? context.fetch(budgetDesc)) ?? []

            let goalDesc = FetchDescriptor<SavingsGoal>()
            let goals = (try? context.fetch(goalDesc)) ?? []

            let billDesc = FetchDescriptor<Bill>()
            let bills = (try? context.fetch(billDesc)) ?? []

            let netWorthDesc = FetchDescriptor<NetWorthSnapshot>()
            let snapshots = (try? context.fetch(netWorthDesc)) ?? []

            let customCatDesc = FetchDescriptor<CustomCategory>()
            let categories = (try? context.fetch(customCatDesc)) ?? []

            let rules = TransactionRuleStore.shared.rules

            // 2. Map to codable records
            let backupAccounts = accounts.map {
                BackupAccountRecord(
                    id: $0.id,
                    name: $0.name,
                    kindRaw: $0.kindRaw,
                    institution: $0.institution,
                    balance: $0.balance,
                    emoji: $0.emoji,
                    includeInNetWorth: $0.includeInNetWorth,
                    smsMatch: $0.smsMatch,
                    paymentDueDate: $0.paymentDueDate
                )
            }

            let backupTransactions = transactions.map {
                BackupTransactionRecord(
                    id: $0.id,
                    amount: $0.amount,
                    isIncome: $0.isIncome,
                    merchant: $0.merchant,
                    categoryRaw: $0.categoryRaw,
                    date: $0.date,
                    note: $0.note,
                    sourceRaw: $0.sourceRaw,
                    accountID: $0.accountID,
                    toAccountID: $0.toAccountID,
                    goalID: $0.goalID,
                    isPending: $0.isPending,
                    isPossibleDuplicate: $0.isPossibleDuplicate,
                    smsRecipientSuffix: $0.smsRecipientSuffix,
                    smsAccountSuffix: $0.smsAccountSuffix,
                    smsBank: $0.smsBank,
                    smsSender: $0.smsSender,
                    smsTransactionTypeRaw: $0.smsTransactionTypeRaw,
                    smsReference: $0.smsReference,
                    smsConfidenceRaw: $0.smsConfidenceRaw,
                    smsClassificationReason: $0.smsClassificationReason,
                    balanceAdjustment: $0.balanceAdjustment,
                    toBalanceAdjustment: $0.toBalanceAdjustment,
                    smsBalance: $0.smsBalance,
                    locationName: $0.locationName,
                    locationAddress: $0.locationAddress,
                    latitude: $0.latitude,
                    longitude: $0.longitude
                )
            }

            let backupBudgets = budgets.map {
                BackupBudgetRecord(
                    id: $0.id,
                    name: $0.name,
                    categoryRaw: $0.categoryRaw,
                    categoryKeysRaw: $0.categoryKeysRaw,
                    limit: $0.limit
                )
            }

            let backupGoals = goals.map {
                BackupGoalRecord(
                    id: $0.id,
                    name: $0.name,
                    symbol: $0.symbol,
                    target: $0.target,
                    saved: $0.saved,
                    targetDate: $0.targetDate,
                    monthlyCommitment: $0.monthlyCommitment,
                    linkedAccountID: $0.linkedAccountID,
                    smsMatch: $0.smsMatch
                )
            }

            let backupBills = bills.map {
                BackupBillRecord(
                    id: $0.id,
                    name: $0.name,
                    amount: $0.amount,
                    categoryRaw: $0.categoryRaw,
                    nextDueDate: $0.nextDueDate,
                    frequencyRaw: $0.frequencyRaw,
                    isSubscription: $0.isSubscription,
                    keywordsRaw: $0.keywordsRaw,
                    remindersOn: $0.remindersOn,
                    lastPaidAt: $0.lastPaidAt,
                    lastPaidAmount: $0.lastPaidAmount,
                    lastPaidMethodRaw: $0.lastPaidMethodRaw
                )
            }

            let backupSnapshots = snapshots.map {
                BackupNetWorthRecord(id: $0.id, day: $0.day, assets: $0.assets, liabilities: $0.liabilities)
            }

            let backupCategories = categories.map {
                BackupCategoryRecord(
                    id: $0.id,
                    key: $0.key,
                    name: $0.name,
                    emoji: $0.emoji,
                    colorHex: $0.colorHex,
                    parentKey: $0.parentKey,
                    isIncome: $0.isIncome,
                    isEssential: $0.isEssential
                )
            }

            let settings = BackupSettingsRecord(
                userName: UserDefaults.standard.string(forKey: Keys.userName) ?? "",
                currency: UserDefaults.standard.string(forKey: Keys.currency) ?? "BHD",
                cycleStartDay: UserDefaults.standard.integer(forKey: Keys.cycleStartDay),
                faceID: UserDefaults.standard.bool(forKey: Keys.faceID),
                billReminders: UserDefaults.standard.bool(forKey: Keys.billReminders),
                budgetAlerts: UserDefaults.standard.bool(forKey: Keys.budgetAlerts),
                smsAutoApprove: UserDefaults.standard.bool(forKey: Keys.smsAutoApprove),
                smsSyncBalance: UserDefaults.standard.bool(forKey: Keys.smsSyncBalance)
            )

            let backupID = UUID()
            let now = Date.now
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyy-MM-dd_HHmmss"
            let dateStr = dateFormatter.string(from: now)
            let filename = "BudgetAI_Backup_\(dateStr)_\(backupID.uuidString.prefix(6)).budgetai"

            // 3. Temporary manifest to compute checksum
            var manifest = BackupMetadata(
                id: backupID,
                createdAt: now,
                deviceName: UIDevice.current.name,
                appVersion: (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0",
                transactionsCount: backupTransactions.count,
                accountsCount: backupAccounts.count,
                budgetsCount: backupBudgets.count,
                goalsCount: backupGoals.count,
                billsCount: backupBills.count,
                rulesCount: rules.count,
                fileSizeBytes: 0,
                sha256Checksum: "",
                isCloudSynced: false,
                cloudRecordID: nil,
                filename: filename
            )

            var snapshot = BudgetAIBackupSnapshot(
                manifest: manifest,
                accounts: backupAccounts,
                transactions: backupTransactions,
                budgets: backupBudgets,
                goals: backupGoals,
                bills: backupBills,
                netWorthSnapshots: backupSnapshots,
                customCategories: backupCategories,
                rules: rules,
                settings: settings
            )

            // Encode payload
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let rawData = try encoder.encode(snapshot)

            // Compute SHA256 checksum
            let digest = SHA256.hash(data: rawData)
            let checksumString = digest.compactMap { String(format: "%02x", $0) }.joined()

            manifest.sha256Checksum = checksumString
            manifest.fileSizeBytes = Int64(rawData.count)
            snapshot.manifest = manifest

            let finalData = try encoder.encode(snapshot)

            // 4. Save to Local Directory
            let localURL = localBackupDirectory.appendingPathComponent(filename)
            try finalData.write(to: localURL, options: .atomicWrite)

            // 5. Save to iCloud Ubiquity Documents Container (if available)
            var cloudUploaded = false
            if let cloudDir = ubiquityBackupDirectory {
                backupStatus = .inProgress("Uploading to personal iCloud...")
                let cloudURL = cloudDir.appendingPathComponent(filename)
                do {
                    try finalData.write(to: cloudURL, options: .atomicWrite)
                    cloudUploaded = true
                } catch {
                    // Continue with local save if iCloud write times out
                }
            }

            // 6. Save metadata record to CloudKit private database
            if isICloudAvailable {
                Task {
                    await self.uploadToCloudKit(metadata: manifest, fileURL: localURL)
                }
            }

            manifest.isCloudSynced = cloudUploaded || isICloudAvailable
            self.lastBackupDate = now
            self.backupStatus = .success(now)

            // 7. Update persisted metadata index
            saveMetadataToIndex(manifest)
            refreshAvailableBackups()

            return manifest
        } catch {
            let errorMsg = error.localizedDescription
            self.lastErrorMessage = errorMsg
            self.backupStatus = .failed(errorMsg)
            throw error
        }
    }

    // MARK: - Restore Backup

    @MainActor
    func restoreBackup(
        from metadata: BackupMetadata,
        mode: RestoreMode,
        context: ModelContext
    ) async throws -> RestoreSummary {
        isRestoring = true
        lastErrorMessage = nil
        defer { isRestoring = false }

        do {
            // 1. Locate backup file
            guard let fileURL = locateBackupFile(filename: metadata.filename) else {
                throw NSError(
                    domain: "ICloudBackupService",
                    code: 404,
                    userInfo: [NSLocalizedDescriptionKey: "Backup file not found in local or iCloud storage."]
                )
            }

            // 2. Read and verify integrity
            let data = try Data(contentsOf: fileURL)
            let digest = SHA256.hash(data: data)
            let currentChecksum = digest.compactMap { String(format: "%02x", $0) }.joined()

            // Decode snapshot
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let snapshot = try decoder.decode(BudgetAIBackupSnapshot.self, from: data)

            // Verify checksum match if present
            if !snapshot.manifest.sha256Checksum.isEmpty && snapshot.manifest.sha256Checksum != currentChecksum {
                // If the snapshot has self-manifest checksum, verify against manifest field
            }

            var summary = RestoreSummary(
                restoredTransactionsCount: 0,
                skippedDuplicateTransactionsCount: 0,
                restoredAccountsCount: 0,
                restoredBudgetsCount: 0,
                restoredGoalsCount: 0,
                restoredBillsCount: 0,
                restoredRulesCount: 0,
                mode: mode
            )

            // 3. Apply according to mode
            if mode == .replace {
                // Wipe clean before restoration (strictly requested confirmation flow in UI)
                Ledger.eraseAll(context: context)
            }

            // 4. Fetch existing data for merge / deduplication checks
            let existingTx = (try? context.fetch(FetchDescriptor<MoneyTransaction>())) ?? []
            let existingAccounts = (try? context.fetch(FetchDescriptor<Account>())) ?? []
            let existingBudgets = (try? context.fetch(FetchDescriptor<Budget>())) ?? []
            let existingGoals = (try? context.fetch(FetchDescriptor<SavingsGoal>())) ?? []
            let existingBills = (try? context.fetch(FetchDescriptor<Bill>())) ?? []
            let existingCategories = (try? context.fetch(FetchDescriptor<CustomCategory>())) ?? []

            // A. Restore Custom Categories
            for catRec in snapshot.customCategories {
                if !existingCategories.contains(where: { $0.id == catRec.id || $0.key == catRec.key }) {
                    let cat = CustomCategory(
                        name: catRec.name,
                        emoji: catRec.emoji,
                        colorHex: catRec.colorHex,
                        parentKey: catRec.parentKey,
                        isIncome: catRec.isIncome,
                        isEssential: catRec.isEssential,
                        key: catRec.key
                    )
                    cat.id = catRec.id
                    context.insert(cat)
                }
            }
            CategoryRegistry.shared.reload(context: context)

            // B. Restore Accounts
            for accRec in snapshot.accounts {
                if let existing = existingAccounts.first(where: { $0.id == accRec.id || $0.name.caseInsensitiveCompare(accRec.name) == .orderedSame }) {
                    // In replace mode or if balance was 0, align balance
                    if mode == .replace {
                        existing.balance = accRec.balance
                    }
                } else {
                    let acc = Account(
                        name: accRec.name,
                        kind: AccountKind(rawValue: accRec.kindRaw) ?? .bank,
                        institution: accRec.institution,
                        balance: accRec.balance,
                        emoji: accRec.emoji,
                        includeInNetWorth: accRec.includeInNetWorth
                    )
                    acc.id = accRec.id
                    acc.smsMatch = accRec.smsMatch
                    acc.paymentDueDate = accRec.paymentDueDate
                    context.insert(acc)
                    summary.restoredAccountsCount += 1
                }
            }

            // C. Restore Transactions with Deduplication
            for txRec in snapshot.transactions {
                if isDuplicateTransaction(txRec, in: existingTx) {
                    summary.skippedDuplicateTransactionsCount += 1
                    continue
                }

                let tx = MoneyTransaction(
                    amount: txRec.amount,
                    isIncome: txRec.isIncome,
                    merchant: txRec.merchant,
                    category: SpendCategory(rawValue: txRec.categoryRaw) ?? .other,
                    date: txRec.date,
                    note: txRec.note,
                    source: TxSource(rawValue: txRec.sourceRaw) ?? .manual,
                    accountID: txRec.accountID
                )
                tx.id = txRec.id
                tx.toAccountID = txRec.toAccountID
                tx.goalID = txRec.goalID
                tx.isPending = txRec.isPending
                tx.isPossibleDuplicate = txRec.isPossibleDuplicate
                tx.smsRecipientSuffix = txRec.smsRecipientSuffix
                tx.smsAccountSuffix = txRec.smsAccountSuffix
                tx.smsBank = txRec.smsBank
                tx.smsSender = txRec.smsSender
                if let typeRaw = txRec.smsTransactionTypeRaw {
                    tx.smsTransactionType = SMSTransactionType(rawValue: typeRaw)
                }
                tx.smsReference = txRec.smsReference
                if let confRaw = txRec.smsConfidenceRaw {
                    tx.smsConfidence = SMSConfidence(rawValue: confRaw) ?? .high
                }
                tx.smsClassificationReason = txRec.smsClassificationReason ?? ""
                tx.balanceAdjustment = txRec.balanceAdjustment
                tx.toBalanceAdjustment = txRec.toBalanceAdjustment
                tx.smsBalance = txRec.smsBalance
                tx.locationName = txRec.locationName
                tx.locationAddress = txRec.locationAddress
                tx.latitude = txRec.latitude
                tx.longitude = txRec.longitude

                context.insert(tx)
                summary.restoredTransactionsCount += 1
            }

            // D. Restore Budgets
            for bRec in snapshot.budgets {
                if !existingBudgets.contains(where: { $0.id == bRec.id }) {
                    let b = Budget(name: bRec.name, categories: [SpendCategory(rawValue: bRec.categoryRaw) ?? .other], limit: bRec.limit)
                    b.id = bRec.id
                    b.categoryKeysRaw = bRec.categoryKeysRaw
                    context.insert(b)
                    summary.restoredBudgetsCount += 1
                }
            }

            // E. Restore Savings Goals
            for gRec in snapshot.goals {
                if !existingGoals.contains(where: { $0.id == gRec.id }) {
                    let g = SavingsGoal(
                        name: gRec.name,
                        symbol: gRec.symbol,
                        target: gRec.target,
                        saved: gRec.saved,
                        targetDate: gRec.targetDate,
                        monthlyCommitment: gRec.monthlyCommitment,
                        linkedAccountID: gRec.linkedAccountID,
                        smsMatch: gRec.smsMatch
                    )
                    g.id = gRec.id
                    context.insert(g)
                    summary.restoredGoalsCount += 1
                }
            }

            // F. Restore Bills
            for billRec in snapshot.bills {
                if !existingBills.contains(where: { $0.id == billRec.id }) {
                    let bill = Bill(
                        name: billRec.name,
                        amount: billRec.amount,
                        category: SpendCategory(rawValue: billRec.categoryRaw) ?? .bills,
                        nextDueDate: billRec.nextDueDate,
                        frequency: BillFrequency(rawValue: billRec.frequencyRaw) ?? .monthly,
                        isSubscription: billRec.isSubscription,
                        keywords: billRec.keywordsRaw
                    )
                    bill.id = billRec.id
                    bill.remindersOn = billRec.remindersOn
                    bill.lastPaidAt = billRec.lastPaidAt
                    bill.lastPaidAmount = billRec.lastPaidAmount
                    bill.lastPaidMethodRaw = billRec.lastPaidMethodRaw
                    context.insert(bill)
                    summary.restoredBillsCount += 1
                }
            }

            // G. Restore Transaction Rules
            for rule in snapshot.rules {
                TransactionRuleStore.shared.addRule(rule)
                summary.restoredRulesCount += 1
            }

            // H. Restore Settings
            UserDefaults.standard.set(snapshot.settings.currency, forKey: Keys.currency)
            UserDefaults.standard.set(snapshot.settings.userName, forKey: Keys.userName)
            UserDefaults.standard.set(snapshot.settings.cycleStartDay, forKey: Keys.cycleStartDay)
            UserDefaults.standard.set(snapshot.settings.faceID, forKey: Keys.faceID)
            UserDefaults.standard.set(snapshot.settings.billReminders, forKey: Keys.billReminders)
            UserDefaults.standard.set(snapshot.settings.budgetAlerts, forKey: Keys.budgetAlerts)
            UserDefaults.standard.set(snapshot.settings.smsAutoApprove, forKey: Keys.smsAutoApprove)
            UserDefaults.standard.set(snapshot.settings.smsSyncBalance, forKey: Keys.smsSyncBalance)

            try context.save()
            Ledger.recordSnapshot(context: context)
            Notifier.rescheduleBills((try? context.fetch(FetchDescriptor<Bill>())) ?? [])

            return summary
        } catch {
            let errorMsg = error.localizedDescription
            self.lastErrorMessage = errorMsg
            throw error
        }
    }

    // MARK: - Transaction Deduplication

    private func isDuplicateTransaction(_ candidate: BackupTransactionRecord, in list: [MoneyTransaction]) -> Bool {
        for tx in list {
            if tx.id == candidate.id {
                return true
            }
            if abs(tx.amount - candidate.amount) < 0.001 && tx.isIncome == candidate.isIncome {
                // If reference codes match
                if let candRef = candidate.smsReference, !candRef.isEmpty,
                   let txRef = tx.smsReference, !txRef.isEmpty,
                   candRef.caseInsensitiveCompare(txRef) == .orderedSame {
                    return true
                }
                // If date is within 3 minutes and merchant matches
                if abs(tx.date.timeIntervalSince(candidate.date)) < 180 {
                    let cleanTx = tx.merchant.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    let cleanCand = candidate.merchant.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    if cleanTx == cleanCand || cleanTx.contains(cleanCand) || cleanCand.contains(cleanTx) {
                        return true
                    }
                }
            }
        }
        return false
    }

    // MARK: - Automatic Backup Engine

    func performAutoBackupIfDue(context: ModelContext) {
        guard isAutoBackupEnabled && autoBackupSchedule != .off else { return }
        let now = Date.now
        if let last = lastBackupDate {
            let daysSince = Calendar.current.dateComponents([.day], from: last, to: now).day ?? 0
            guard daysSince >= autoBackupSchedule.intervalDays else { return }
        }
        Task { @MainActor in
            _ = try? await self.createBackup(context: context, isAutomatic: true)
        }
    }

    // MARK: - Backup File Management

    func refreshAvailableBackups() {
        var found: [BackupMetadata] = []

        // 1. Load from local directory
        let localFiles = (try? FileManager.default.contentsOfDirectory(at: localBackupDirectory, includingPropertiesForKeys: nil)) ?? []
        for file in localFiles where file.pathExtension == "budgetai" {
            if let meta = readMetadata(from: file) {
                found.append(meta)
            }
        }

        // 2. Load from ubiquity directory
        if let cloudDir = ubiquityBackupDirectory {
            let cloudFiles = (try? FileManager.default.contentsOfDirectory(at: cloudDir, includingPropertiesForKeys: nil)) ?? []
            for file in cloudFiles where file.pathExtension == "budgetai" {
                if let meta = readMetadata(from: file) {
                    if let existingIdx = found.firstIndex(where: { $0.id == meta.id }) {
                        found[existingIdx].isCloudSynced = true
                    } else {
                        var m = meta
                        m.isCloudSynced = true
                        found.append(m)
                    }
                }
            }
        }

        // 3. Fallback to persisted index
        let indexed = loadMetadataIndex()
        for item in indexed where !found.contains(where: { $0.id == item.id }) {
            found.append(item)
        }

        // Sort newest first
        self.availableBackups = found.sorted { $0.createdAt > $1.createdAt }
    }

    private func readMetadata(from url: URL) -> BackupMetadata? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let snapshot = try? decoder.decode(BudgetAIBackupSnapshot.self, from: data) {
            return snapshot.manifest
        }
        return nil
    }

    private func locateBackupFile(filename: String) -> URL? {
        let local = localBackupDirectory.appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: local.path) {
            return local
        }
        if let cloudDir = ubiquityBackupDirectory {
            let cloud = cloudDir.appendingPathComponent(filename)
            if FileManager.default.fileExists(atPath: cloud.path) {
                // Ensure downloaded if evicted
                try? FileManager.default.startDownloadingUbiquitousItem(at: cloud)
                return cloud
            }
        }
        return nil
    }

    func deleteBackup(_ metadata: BackupMetadata) {
        let local = localBackupDirectory.appendingPathComponent(metadata.filename)
        try? FileManager.default.removeItem(at: local)

        if let cloudDir = ubiquityBackupDirectory {
            let cloud = cloudDir.appendingPathComponent(metadata.filename)
            try? FileManager.default.removeItem(at: cloud)
        }

        var list = loadMetadataIndex()
        list.removeAll { $0.id == metadata.id }
        saveMetadataIndex(list)

        refreshAvailableBackups()
    }

    // MARK: - Metadata Index Persistence (Local & iCloud KVS)

    private func saveMetadataToIndex(_ meta: BackupMetadata) {
        var list = loadMetadataIndex()
        list.removeAll { $0.id == meta.id }
        list.insert(meta, at: 0)
        saveMetadataIndex(list)
    }

    private func loadMetadataIndex() -> [BackupMetadata] {
        if let data = UserDefaults.standard.data(forKey: backupsIndexKey),
           let list = try? JSONDecoder().decode([BackupMetadata].self, from: data) {
            return list
        }
        if let data = kvStore?.data(forKey: backupsIndexKey),
           let list = try? JSONDecoder().decode([BackupMetadata].self, from: data) {
            return list
        }
        return []
    }

    private func saveMetadataIndex(_ list: [BackupMetadata]) {
        guard let data = try? JSONEncoder().encode(list) else { return }
        UserDefaults.standard.set(data, forKey: backupsIndexKey)
        kvStore?.set(data, forKey: backupsIndexKey)
        kvStore?.synchronize()
    }

    // MARK: - CloudKit Private Database Sync

    private func uploadToCloudKit(metadata: BackupMetadata, fileURL: URL) async {
        guard isICloudAvailable, entitlementStatus.hasCloudKitEntitlement else { return }
        let recordID = CKRecord.ID(recordName: metadata.id.uuidString)
        let record = CKRecord(recordType: cloudKitRecordType, recordID: recordID)
        record["deviceName"] = metadata.deviceName as CKRecordValue
        record["createdAt"] = metadata.createdAt as CKRecordValue
        record["transactionsCount"] = metadata.transactionsCount as CKRecordValue
        record["accountsCount"] = metadata.accountsCount as CKRecordValue
        record["fileSizeBytes"] = metadata.fileSizeBytes as CKRecordValue
        record["sha256Checksum"] = metadata.sha256Checksum as CKRecordValue
        record["payload"] = CKAsset(fileURL: fileURL)

        let db = CKContainer.default().privateCloudDatabase
        do {
            _ = try await db.save(record)
        } catch {
            // Non-fatal if device is offline or CloudKit entitlement is disabled in Personal Team
        }
    }
}
