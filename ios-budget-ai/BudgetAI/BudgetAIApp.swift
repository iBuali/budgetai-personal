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
    @AppStorage(Keys.appearanceMode) private var appearanceModeRaw = AppAppearanceMode.automatic.rawValue

    init() {
        UIScrollView.appearance().keyboardDismissMode = .onDrag
        DataStore.warmUp()
    }

    var body: some Scene {
        let mode = AppAppearanceMode(rawValue: appearanceModeRaw) ?? .automatic
        WindowGroup {
            RootView()
                .environment(appState)
                .tint(Theme.cobalt)
                .scrollDismissesKeyboard(.immediately)
                .preferredColorScheme(mode.colorScheme)
                .onAppear {
                    AppAppearanceMode.applyToWindows(mode)
                }
                .onChange(of: appearanceModeRaw) { _, raw in
                    AppAppearanceMode.applyToWindows(AppAppearanceMode(rawValue: raw) ?? .automatic)
                }
        }
        .modelContainer(DataStore.shared)
    }
}
