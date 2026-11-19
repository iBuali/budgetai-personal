import SwiftUI
import UIKit

enum Theme {
    static let canvas = Color(light: Color(hex: 0xF4F3EF), dark: Color(hex: 0x070B14))
    static let surface = Color(light: .white, dark: Color(hex: 0x161D2E))
    static let card = Color(light: .white, dark: Color(hex: 0x161D2E))
    static let ink = Color(light: Color(hex: 0x1A1A18), dark: Color(hex: 0xF5F7FC))
    static let secondaryInk = Color(light: Color(hex: 0x6E6D68), dark: Color(hex: 0x9AA5BC))
    static let cobalt = Color(light: Color(hex: 0x1A1A18), dark: Color(hex: 0xB44CFF))
    static let brand = Color(light: Color(hex: 0x1A1A18), dark: Color(hex: 0xB44CFF))
    static let cobaltSoft = Color(light: Color(hex: 0xEFEEE9), dark: Color(hex: 0xB44CFF).opacity(0.18))
    static let positive = Color(light: Color(hex: 0x16A34A), dark: Color(hex: 0x34D399))
    static let income = Color(light: Color(hex: 0x16A34A), dark: Color(hex: 0x34D399))
    static let negative = Color(light: Color(hex: 0xDC2626), dark: Color(hex: 0xF87171))
    static let expense = Color(light: Color(hex: 0xDC2626), dark: Color(hex: 0xF87171))
    static let warning = Color(light: Color(hex: 0xD97706), dark: Color(hex: 0xFBBF24))
    static let track = Color(light: Color(hex: 0xE8E7E2), dark: Color.white.opacity(0.11))
    static let cardRadius: CGFloat = 18
    static let corner: CGFloat = 14
}

extension Color {
    init(light: Color, dark: Color) {
        self.init(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light)
        })
    }

    init(hex: UInt32, opacity: Double = 1) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: opacity)
    }
}

struct CardModifier: ViewModifier {
    var padding: CGFloat

    @ViewBuilder
    func body(content: Content) -> some View {
        let base = content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
        if #available(iOS 26.0, *) {
            base.glassEffect(.regular, in: .rect(cornerRadius: Theme.cardRadius))
        } else {
            base.background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        }
    }
}

extension View {
    func card(padding: CGFloat = 16) -> some View {
        modifier(CardModifier(padding: padding))
    }

    func canvasBackground() -> some View {
        scrollDismissesKeyboard(.immediately)
            .background(Theme.canvas.ignoresSafeArea())
    }
}

struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

enum AppAppearanceMode: String, CaseIterable, Identifiable, Hashable {
    case automatic = "automatic"
    case dark = "dark"
    case light = "light"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: "Automatic"
        case .dark: "On"
        case .light: "Off"
        }
    }

    var symbol: String {
        switch self {
        case .automatic: "circle.lefthalf.filled"
        case .dark: "moon.fill"
        case .light: "sun.max.fill"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .automatic: nil
        case .dark: .dark
        case .light: .light
        }
    }

    var interfaceStyle: UIUserInterfaceStyle {
        switch self {
        case .automatic: .unspecified
        case .dark: .dark
        case .light: .light
        }
    }

    @MainActor
    static func applyToWindows(_ mode: AppAppearanceMode) {
        let style = mode.interfaceStyle
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                window.overrideUserInterfaceStyle = style
            }
        }
    }
}
