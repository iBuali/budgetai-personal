//
//  BudgetAIApp.swift
//  BudgetAI
//

import SwiftUI
import SwiftData
import UIKit

@main
struct BudgetAIApp: App {
    @State private var appState = AppState()

    init() {
        UIScrollView.appearance().keyboardDismissMode = .onDrag
        DataStore.warmUp()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
                .preferredColorScheme(.light)
                .tint(Theme.cobalt)
                .scrollDismissesKeyboard(.immediately)
        }
        .modelContainer(DataStore.shared)
    }
}
