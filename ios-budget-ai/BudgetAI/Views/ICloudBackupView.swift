import SwiftUI
import SwiftData

struct ICloudBackupView: View {
    @Environment(\.modelContext) private var context
    @Environment(AppState.self) private var appState
    private var backupService = ICloudBackupService.shared

    @State private var selectedBackupForRestore: BackupMetadata?
    @State private var showRestoreConfirmation = false
    @State private var showReplaceConfirmation = false
    @State private var showSuccessAlert = false
    @State private var successAlertMessage = ""
    @State private var showErrorAlert = false
    @State private var errorMessage = ""

    var body: some View {
        List {
            statusSection
            settingsSection
            backupsListSection
        }
        .scrollContentBackground(.hidden)
        .canvasBackground()
        .navigationTitle("iCloud Backup & Restore")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            backupService.checkICloudAvailability()
            backupService.refreshAvailableBackups()
        }
        .confirmationDialog(
            "Restore from Backup",
            isPresented: $showRestoreConfirmation,
            titleVisibility: .visible,
            presenting: selectedBackupForRestore
        ) { backup in
            Button("Merge & Prevent Duplicates (Recommended)") {
                executeRestore(backup: backup, mode: .merge)
            }
            Button("Replace Current Data", role: .destructive) {
                showReplaceConfirmation = true
            }
            Button("Cancel", role: .cancel) { }
        } message: { backup in
            Text("Backup from \(backup.formattedDate) contains \(backup.transactionsCount) transactions and \(backup.accountsCount) accounts. How would you like to restore?")
        }
        .confirmationDialog(
            "Replace All Current Data?",
            isPresented: $showReplaceConfirmation,
            titleVisibility: .visible
        ) {
            Button("Yes, Replace Everything", role: .destructive) {
                if let backup = selectedBackupForRestore {
                    executeRestore(backup: backup, mode: .replace)
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This will permanently overwrite current accounts, transactions, and settings on this device with the selected backup snapshot.")
        }
        .alert("Restore Completed", isPresented: $showSuccessAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(successAlertMessage)
        }
        .alert("Backup Error", isPresented: $showErrorAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(errorMessage)
        }
    }

    // MARK: - Status Card Section

    @ViewBuilder
    private var statusSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(Theme.cobaltSoft)
                            .frame(width: 48, height: 48)
                        Image(systemName: "icloud.fill")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(Theme.cobalt)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text("iCloud Backup")
                            .font(.headline)
                            .foregroundStyle(Theme.ink)

                        HStack(spacing: 6) {
                            Circle()
                                .fill(backupService.isICloudAvailable ? Theme.positive : Theme.warning)
                                .frame(width: 7, height: 7)
                            Text(backupService.isICloudAvailable ? "iCloud Connected" : "Local Storage Mode")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(Theme.secondaryInk)
                        }
                    }

                    Spacer()
                }

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Last Backup:")
                            .font(.subheadline)
                            .foregroundStyle(Theme.secondaryInk)
                        Spacer()
                        if let last = backupService.lastBackupDate {
                            Text(formatDate(last))
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Theme.ink)
                        } else {
                            Text("Never")
                                .font(.subheadline)
                                .foregroundStyle(Theme.secondaryInk)
                        }
                    }

                    HStack {
                        Text("Status:")
                            .font(.subheadline)
                            .foregroundStyle(Theme.secondaryInk)
                        Spacer()
                        statusBadge
                    }
                }

                Button {
                    executeManualBackup()
                } label: {
                    HStack {
                        Spacer()
                        if backupService.isBackingUp {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                .scaleEffect(0.85)
                            Text("Backing up...")
                                .fontWeight(.semibold)
                        } else {
                            Image(systemName: "arrow.clockwise.icloud.fill")
                            Text("Back Up Now")
                                .fontWeight(.semibold)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 11)
                    .background(Theme.cobalt, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .disabled(backupService.isBackingUp || backupService.isRestoring)
            }
            .padding(.vertical, 6)
        } header: {
            Text("Backup Status")
        } footer: {
            Text("Backups are encrypted and stored in your personal Apple iCloud account. Your financial data is private and accessible only on your devices signed in with your Apple ID.")
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch backupService.backupStatus {
        case .idle:
            Text("Ready")
                .font(.caption.weight(.medium))
                .foregroundStyle(Theme.secondaryInk)
        case .inProgress(let stage):
            HStack(spacing: 4) {
                ProgressView().scaleEffect(0.65)
                Text(stage)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Theme.cobalt)
            }
        case .success:
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.caption)
                Text("Success")
                    .font(.caption.weight(.semibold))
            }
            .foregroundStyle(Theme.positive)
        case .failed(let err):
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.caption)
                Text(err)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
            }
            .foregroundStyle(Theme.negative)
        }
    }

    // MARK: - Backup Settings Section

    @ViewBuilder
    private var settingsSection: some View {
        Section {
            Toggle(isOn: Binding(
                get: { backupService.isAutoBackupEnabled },
                set: { backupService.isAutoBackupEnabled = $0 }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Automatic iCloud Backup")
                        .font(.body)
                        .foregroundStyle(Theme.ink)
                    Text("Back up your data regularly in the background")
                        .font(.caption2)
                        .foregroundStyle(Theme.secondaryInk)
                }
            }

            if backupService.isAutoBackupEnabled {
                Picker("Frequency", selection: Binding(
                    get: { backupService.autoBackupSchedule },
                    set: { backupService.autoBackupSchedule = $0 }
                )) {
                    ForEach([BackupSchedule.weekly, BackupSchedule.daily, BackupSchedule.monthly]) { s in
                        Text(s.title).tag(s)
                    }
                }
            }
        } header: {
            Text("Backup Settings")
        } footer: {
            Text("When enabled, Budget AI securely backs up changes when the app is opened according to your chosen schedule.")
        }
    }

    // MARK: - Backups History List Section

    @ViewBuilder
    private var backupsListSection: some View {
        Section {
            if backupService.availableBackups.isEmpty {
                HStack(spacing: 12) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.title3)
                        .foregroundStyle(Theme.secondaryInk)
                    Text("No backups found yet. Tap \"Back Up Now\" above to create your first backup.")
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryInk)
                }
                .padding(.vertical, 8)
            } else {
                ForEach(backupService.availableBackups) { backup in
                    backupRow(backup)
                }
                .onDelete { offsets in
                    for index in offsets {
                        if backupService.availableBackups.indices.contains(index) {
                            backupService.deleteBackup(backupService.availableBackups[index])
                        }
                    }
                }
            }
        } header: {
            HStack {
                Text("Available Backups (\(backupService.availableBackups.count))")
                Spacer()
                if !backupService.availableBackups.isEmpty {
                    Text("Swipe to Delete")
                        .font(.caption2)
                        .foregroundStyle(Theme.secondaryInk)
                }
            }
        } footer: {
            Text("Tap \"Restore\" on any backup to recover your transactions, accounts, and budgets.")
        }
    }

    @ViewBuilder
    private func backupRow(_ backup: BackupMetadata) -> some View {
        HStack(spacing: 12) {
            Image(systemName: backup.isCloudSynced ? "icloud.fill" : "internaldrive")
                .font(.title3)
                .foregroundStyle(backup.isCloudSynced ? Theme.cobalt : Theme.secondaryInk)

            VStack(alignment: .leading, spacing: 3) {
                Text(backup.formattedDate)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.ink)

                HStack(spacing: 6) {
                    Text("\(backup.transactionsCount) txs")
                    Text("•")
                    Text("\(backup.accountsCount) accounts")
                    Text("•")
                    Text(backup.formattedSize)
                }
                .font(.caption2)
                .foregroundStyle(Theme.secondaryInk)
            }

            Spacer()

            Button {
                selectedBackupForRestore = backup
                showRestoreConfirmation = true
            } label: {
                Text("Restore")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Theme.cobaltSoft, in: Capsule())
                    .foregroundStyle(Theme.cobalt)
            }
            .buttonStyle(.plain)
            .disabled(backupService.isRestoring || backupService.isBackingUp)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Actions

    private func executeManualBackup() {
        Task {
            do {
                _ = try await backupService.createBackup(context: context)
                appState.show("iCloud backup completed successfully")
            } catch {
                errorMessage = error.localizedDescription
                showErrorAlert = true
            }
        }
    }

    private func executeRestore(backup: BackupMetadata, mode: RestoreMode) {
        Task {
            do {
                let summary = try await backupService.restoreBackup(from: backup, mode: mode, context: context)
                var msg = "Restored \(summary.restoredTransactionsCount) transactions and \(summary.restoredAccountsCount) accounts."
                if summary.skippedDuplicateTransactionsCount > 0 {
                    msg += "\n(\(summary.skippedDuplicateTransactionsCount) duplicate transactions were safely skipped)."
                }
                successAlertMessage = msg
                showSuccessAlert = true
                appState.show("Restore completed successfully")
            } catch {
                errorMessage = error.localizedDescription
                showErrorAlert = true
            }
        }
    }

    private func formatDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }
}
