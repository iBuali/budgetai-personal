import AppIntents
import Foundation
import SwiftData

/// Run from a Shortcuts "Message received" automation to import bank SMS alerts automatically.
struct AddBankSMSIntent: AppIntent {
    static let title: LocalizedStringResource = "Add Bank SMS"
    static let description = IntentDescription("Reads a bank SMS alert and adds the transaction to Budget AI with an automatic category.")
    static let openAppWhenRun: Bool = false

    @Parameter(title: "Message", inputOptions: String.IntentInputOptions(multiline: true))
    var message: String

    @Parameter(
        title: "Sender (Optional)",
        description: "In Shortcuts, set this to Shortcut Input → Sender so the bank sender ID or phone number is fetched from the SMS."
    )
    var sender: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$message) from \(\.$sender) to Budget AI")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let resolvedSender = SMSParser.extractSenderOrPhone(in: message, explicitSender: sender)
        let outcome = await SMSImporter.importText(message, context: DataStore.shared.mainContext, sender: resolvedSender)
        return .result(dialog: IntentDialog(stringLiteral: outcome.message))
    }
}

struct BudgetShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AddBankSMSIntent(),
            phrases: ["Add bank SMS to \(.applicationName)", "Import bank message in \(.applicationName)"],
            shortTitle: "Add Bank SMS",
            systemImageName: "message.badge.filled.fill"
        )
    }
}
