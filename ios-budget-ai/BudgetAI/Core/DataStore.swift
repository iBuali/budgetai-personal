import Foundation
import SwiftData

enum DataStore {
    static let schema = Schema([
        Account.self, MoneyTransaction.self, Budget.self, SavingsGoal.self,
        Bill.self, NetWorthSnapshot.self, ChatMessage.self,
    ])

    static let shared: ModelContainer = {
        do {
            return try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema))
        } catch {
            // Last resort so the app still opens; data won't persist this session.
            return try! ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true))
        }
    }()
}
