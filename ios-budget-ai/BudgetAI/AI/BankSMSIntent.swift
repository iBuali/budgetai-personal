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

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$message) to Budget AI")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let outcome = await SMSImporter.importText(message, context: DataStore.shared.mainContext)
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
