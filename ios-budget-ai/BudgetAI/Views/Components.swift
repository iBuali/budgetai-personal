import SwiftUI

struct IconBadge: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 44

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.4, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .background(color.opacity(0.13), in: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
    }
}

struct CategoryIcon: View {
    let category: SpendCategory
    var size: CGFloat = 44
    var body: some View {
        if category.emoji.isEmpty {
            IconBadge(symbol: category.symbol, color: category.color, size: size)
        } else {
            EmojiBadge(emoji: category.emoji, color: category.color, size: size)
        }
    }
}

struct EmojiBadge: View {
    let emoji: String
    let color: Color
    var size: CGFloat = 44

    var body: some View {
        Text(emoji)
            .font(.system(size: size * 0.5))
            .frame(width: size, height: size)
            .background(color.opacity(0.13), in: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
    }
}

struct AccountIcon: View {
    let account: Account
    var size: CGFloat = 40
    var body: some View {
        if account.emoji.isEmpty {
            IconBadge(symbol: account.kind.symbol, color: account.kind.color, size: size)
        } else {
            EmojiBadge(emoji: account.emoji, color: account.kind.color, size: size)
        }
    }
}

/// Text label for menus/pickers, which can't render custom icon views.
extension SpendCategory {
    var menuTitle: String { emoji.isEmpty ? title : "\(emoji)  \(title)" }
}

extension Account {
    var menuTitle: String { emoji.isEmpty ? name : "\(emoji)  \(name)" }
}

/// Pick an emoji from a curated grid or type any emoji with the keyboard.
struct EmojiPicker: View {
    @Binding var emoji: String
    var suggestions: [String]
    @State private var typed = ""

    static let categorySuggestions = ["🛒", "🍔", "☕️", "🚗", "⛽️", "🛍️", "💡", "🏠", "💊", "🎬", "📺", "🎓", "✈️", "🎁", "👶", "🐶",
                                      "💪", "💇", "🧾", "📱", "🎮", "🕌", "❤️", "💼", "💰", "📈", "🏦", "🧸", "🍕", "🥗", "🚕", "🏖️"]
    static let accountSuggestions = ["🏦", "💳", "💵", "👛", "💰", "📈", "🏠", "🚗", "🪙", "💎", "🏧", "🧾", "📊", "🛟", "🔐", "🌍"]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Text(emoji.isEmpty ? "–" : emoji)
                    .font(.system(size: 30))
                    .frame(width: 52, height: 52)
                    .background(Theme.track.opacity(0.6), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                TextField("Type any emoji", text: $typed)
                    .onChange(of: typed) { _, value in
                        if let last = value.last(where: { $0.unicodeScalars.contains { $0.properties.isEmojiPresentation || $0.properties.generalCategory == .otherSymbol } }) {
                            emoji = String(last)
                        }
                        if !value.isEmpty { typed = "" }
                    }
                if !emoji.isEmpty {
                    Button("Clear") { emoji = "" }.font(.subheadline)
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 8), spacing: 8) {
                ForEach(suggestions, id: \.self) { e in
                    Button { emoji = e } label: {
                        Text(e)
                            .font(.system(size: 22))
                            .frame(width: 36, height: 36)
                            .background(emoji == e ? Theme.cobaltSoft : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(emoji == e ? Theme.cobalt : .clear, lineWidth: 1.5))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.vertical, 4)
        .sensoryFeedback(.selection, trigger: emoji)
    }
}

extension View {
    /// Smoothly rolls digits upward when `value` increases and downward when `value` decreases.
    func animatedNumber(_ value: Double) -> some View {
        self
            .contentTransition(.numericText(value: value))
            .animation(.spring(response: 0.42, dampingFraction: 0.86), value: value)
    }
}

struct RingView: View {
    let progress: Double
    var lineWidth: CGFloat = 12
    var color: Color = Theme.cobalt
    @State private var shown: Double = 0

    var body: some View {
        ZStack {
            Circle().stroke(Theme.cobaltSoft, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(max(shown, 0), 1))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .onAppear { withAnimation(.spring(response: 0.85, dampingFraction: 0.82).delay(0.08)) { shown = progress } }
        .onChange(of: progress) { _, v in withAnimation(.spring(response: 0.55, dampingFraction: 0.84)) { shown = v } }
    }
}

struct ProgressBar: View {
    let progress: Double
    var color: Color = Theme.cobalt
    var height: CGFloat = 7
    var delay: Double = 0.04
    var trackColor: Color = Theme.track
    @State private var shown: Double = 0

    var body: some View {
        GeometryReader { geo in
            let clamped = min(max(shown, 0), 1)
            let fillWidth = clamped <= 0.001 ? 0 : max(height, geo.size.width * clamped)
            ZStack(alignment: .leading) {
                Capsule().fill(trackColor)
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [color.opacity(0.86), color],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: fillWidth)
                    .shadow(color: color.opacity(clamped > 0.02 ? 0.22 : 0), radius: 3, y: 1)
                    .opacity(clamped <= 0.001 ? 0 : 1)
            }
        }
        .frame(height: height)
        .onAppear {
            withAnimation(.spring(response: 0.62, dampingFraction: 0.82).delay(delay)) {
                shown = progress
            }
        }
        .onChange(of: progress) { _, v in
            withAnimation(.spring(response: 0.5, dampingFraction: 0.84)) {
                shown = v
            }
        }
        .accessibilityElement()
        .accessibilityValue("\(Int(progress * 100)) percent")
    }
}

struct SectionTitle<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack {
            Text(title).font(.headline).foregroundStyle(Theme.ink)
            Spacer()
            trailing()
        }
    }
}

extension SectionTitle where Trailing == EmptyView {
    init(_ title: String) {
        self.title = title
        self.trailing = { EmptyView() }
    }
}

struct AIBadge: View {
    var body: some View {
        Label("AI", systemImage: "sparkles")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(Theme.cobalt)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Theme.cobaltSoft, in: Capsule())
    }
}

struct TransactionRow: View {
    let tx: MoneyTransaction
    let currency: String

    var body: some View {
        HStack(spacing: 12) {
            if tx.isTransfer && tx.toAccountID != nil {
                IconBadge(symbol: "arrow.left.arrow.right", color: Theme.cobalt)
            } else {
                CategoryIcon(category: tx.isIncome && tx.category == .other ? .income : tx.displayCategory)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(tx.merchant)
                    .font(.body.weight(.medium))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                if tx.isPending {
                    let pendingLabel: (text: String, icon: String) = {
                        let bankClean = tx.smsBank?.trimmingCharacters(in: .whitespacesAndNewlines)
                        if bankClean == nil || bankClean?.isEmpty == true || bankClean?.lowercased().contains("unknown") == true {
                            return ("Unknown bank sender", "building.columns")
                        }
                        if tx.accountID == nil {
                            return ("Unmatched account", "creditcard.trianglebadge.exclamationmark")
                        }
                        if tx.smsConfidence == .low || tx.category == .other || tx.smsTransactionType == .unknown {
                            return ("Needs review", "questionmark.circle")
                        }
                        return ("Waiting for approval", "clock.fill")
                    }()
                    Label(pendingLabel.text, systemImage: pendingLabel.icon)
                        .font(.subheadline)
                        .foregroundStyle(Theme.warning)
                } else if tx.isPossibleDuplicate {
                    Label("Possible duplicate", systemImage: "exclamationmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(Theme.negative)
                } else {
                    HStack(spacing: 4) {
                        Text(subtitle).lineLimit(1)
                        if tx.source == .sms { Image(systemName: "message.fill").font(.caption2) }
                        if tx.balanceAdjustment != 0 { Image(systemName: "equal.circle.fill").font(.caption2).foregroundStyle(Theme.cobalt) }
                    }
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondaryInk)
                }
            }
            Spacer(minLength: 8)
            Text(tx.effectiveTransactionType == .internalTransfer ? Money.format(tx.amount, currency) : Money.format(tx.signedAmount, currency, signed: true))
                .font(.body.weight(.semibold).monospacedDigit())
                .foregroundStyle(tx.isPending ? Theme.secondaryInk : (tx.isIncome ? Theme.positive : (tx.isTransfer ? Theme.secondaryInk : Theme.negative)))
                .animatedNumber(tx.effectiveTransactionType == .internalTransfer ? tx.amount : tx.signedAmount)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private var subtitle: String {
        if tx.category == .internalTransfer || tx.effectiveTransactionType == .internalTransfer {
            return SpendCategory.internalTransfer.title
        }
        return tx.category.title
    }
}

struct Toast: View {
    let text: String
    var symbol: String = "checkmark.circle.fill"
    var color: Color = Theme.positive

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(text).font(.subheadline.weight(.medium)).foregroundStyle(Theme.ink).lineLimit(2)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.1), radius: 16, y: 6)
        .padding(.horizontal, 24)
    }
}

struct GeminiConnectCard: View {
    var body: some View {
        NavigationLink {
            GeminiSettingsView()
        } label: {
            HStack(spacing: 12) {
                IconBadge(symbol: "sparkles", color: Theme.cobalt)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Connect your Gemini account").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
                    Text("Unlock personalized AI tips, SMS reading and the advisor chat.")
                        .font(.caption).foregroundStyle(Theme.secondaryInk)
                        .multilineTextAlignment(.leading)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .card()
        }
        .buttonStyle(PressableStyle())
    }
}
