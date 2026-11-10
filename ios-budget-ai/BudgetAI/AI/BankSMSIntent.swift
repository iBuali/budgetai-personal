import AppIntents
import Foundation
import SwiftData

/// Run from a Shortcuts "Message received" automation to import bank SMS alerts automatically.
struct AddBankSMSIntent: AppIntent {
    static let title: LocalizedStringResource = "Add Bank SMS"
    static let description = IntentDescription("Reads a bank SMS alert and adds the transaction to Budget AI with an automatic category and real-time location.")
    static let openAppWhenRun: Bool = false

    @Parameter(title: "Message", inputOptions: String.IntentInputOptions(multiline: true))
    var message: String

    @Parameter(
        title: "Sender (Optional)",
        description: "In Shortcuts, set this to Shortcut Input → Sender so the bank sender ID or phone number is fetched from the SMS."
    )
    var sender: String?

    @Parameter(
        title: "Location (Optional)",
        description: "In Shortcuts, pass 'Current Location' from a 'Get Current Location' action to automatically capture where the purchase occurred."
    )
    var location: String?

    @Parameter(
        title: "Latitude (Optional)",
        description: "GPS latitude from Shortcuts 'Get Current Location'."
    )
    var latitude: Double?

    @Parameter(
        title: "Longitude (Optional)",
        description: "GPS longitude from Shortcuts 'Get Current Location'."
    )
    var longitude: Double?

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$message) from \(\.$sender) at \(\.$location) to Budget AI")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let resolvedSender = SMSParser.extractSenderOrPhone(in: message, explicitSender: sender)
        let outcome = await SMSImporter.importText(
            message,
            context: DataStore.shared.mainContext,
            forceApprove: false,
            accountID: nil,
            sender: resolvedSender,
            manualBank: nil,
            location: location,
            latitude: latitude,
            longitude: longitude,
            autoCaptureLocation: true
        )
        return .result(dialog: IntentDialog(stringLiteral: outcome.message))
    }
}

struct BudgetShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AddBankSMSIntent(),
            phrases: [
                "Add bank SMS to \(.applicationName)",
                "Import bank message in \(.applicationName)",
                "Add bank transaction at current location in \(.applicationName)"
            ],
            shortTitle: "Add Bank SMS",
            systemImageName: "message.badge.filled.fill"
        )
    }
}
