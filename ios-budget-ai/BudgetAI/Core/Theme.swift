import SwiftUI

enum Theme {
    static let canvas = Color(hex: 0xF4F6FA)
    static let surface = Color.white
    static let ink = Color(hex: 0x0E1525)
    static let secondaryInk = Color(hex: 0x6B7385)
    static let cobalt = Color(hex: 0x1E3FAE)
    static let brand = Color(hex: 0x1E3FAE)
    static let cobaltSoft = Color(hex: 0x1E3FAE).opacity(0.10)
    static let positive = Color(hex: 0x2BB673)
    static let negative = Color(hex: 0xF05252)
    static let warning = Color(hex: 0xE9A23B)
    static let track = Color(hex: 0xE6E9F0)
    static let cardRadius: CGFloat = 22
    static let corner: CGFloat = 16
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: opacity)
    }
}

struct CardModifier: ViewModifier {
    var padding: CGFloat

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            .shadow(color: Theme.ink.opacity(0.04), radius: 14, y: 4)
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
