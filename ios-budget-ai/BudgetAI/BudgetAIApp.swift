//
//  BudgetAIApp.swift
//  BudgetAI
//

import SwiftUI
import SwiftData

@main
struct BudgetAIApp: App {
    @State private var appState = AppState()

    init() {
        DataStore.warmUp()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
                .preferredColorScheme(.light)
                .tint(Theme.cobalt)
        }
        .modelContainer(DataStore.shared)
    }
}
