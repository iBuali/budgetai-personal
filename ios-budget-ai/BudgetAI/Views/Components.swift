import SwiftUI

struct IconBadge: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 32

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .background(color.opacity(0.13), in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
    }
}

struct CategoryIcon: View {
    let category: SpendCategory
    var size: CGFloat = 32
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
    var size: CGFloat = 32

    var body: some View {
        Text(emoji)
            .font(.system(size: size * 0.5))
            .frame(width: size, height: size)
            .background(color.opacity(0.13), in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
    }
}

struct AccountIcon: View {
    let account: Account
    var size: CGFloat = 32
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

    var body: some View {
        let clamped = min(max(progress, 0), 1)
        ZStack {
            Circle().stroke(Theme.cobaltSoft, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: clamped)
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.spring(response: 0.55, dampingFraction: 0.84), value: clamped)
        }
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
        HStack(spacing: 3) {
            Image(systemName: "sparkles")
                .font(.system(size: 10, weight: .semibold))
            Text("AI")
                .font(.caption2.weight(.bold))
        }
        .foregroundStyle(Theme.cobalt)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Theme.cobaltSoft, in: Capsule())
        .fixedSize()
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
                Text(tx.merchant.isEmpty ? tx.displayCategory.title : tx.merchant)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                    .truncationMode(.tail)
                if tx.isPending {
                    let pendingLabel: (text: String, icon: String) = {
                        let bankClean = tx.smsBank?.trimmingCharacters(in: .whitespacesAndNewlines)
                        if bankClean == nil || bankClean?.isEmpty == true || bankClean?.lowercased().contains("unknown") == true {
                            return ("Unknown bank sender", "building.columns.fill")
                        }
                        if tx.accountID == nil {
                            return ("Unknown account", "creditcard.trianglebadge.exclamationmark")
                        }
                        if tx.smsTransactionType == .unknown {
                            return ("Unknown type", "questionmark.circle.fill")
                        }
                        return ("Waiting for approval", "clock.badge.exclamationmark.fill")
                    }()
                    HStack(spacing: 5) {
                        Image(systemName: pendingLabel.icon)
                            .font(.caption2.weight(.bold))
                        Text(pendingLabel.text)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                    }
                    .foregroundStyle(Theme.warning)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2.5)
                    .background(Theme.warning.opacity(0.14), in: Capsule())
                } else if tx.isPossibleDuplicate {
                    HStack(spacing: 5) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.caption2.weight(.bold))
                        Text("Possible duplicate")
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                    }
                    .foregroundStyle(Theme.negative)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2.5)
                    .background(Theme.negative.opacity(0.14), in: Capsule())
                } else {
                    Text("\(subtitle) • \(tx.date.formatted(date: .omitted, time: .shortened))")
                        .lineLimit(1)
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondaryInk)
                }
            }
            Spacer(minLength: 8)
            Text(tx.effectiveTransactionType == .internalTransfer ? Money.format(tx.amount, currency) : Money.format(tx.signedAmount, currency, signed: true))
                .font(.body.weight(.semibold).monospacedDigit())
                .foregroundStyle(tx.isPending ? Theme.secondaryInk : (tx.isIncome ? Theme.positive : (tx.isTransfer ? Theme.secondaryInk : Theme.negative)))
                .lineLimit(1)
                .layoutPriority(1)
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
        let pill = HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(text).font(.subheadline.weight(.medium)).foregroundStyle(Theme.ink).lineLimit(2)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        if #available(iOS 26.0, *) {
            pill
                .glassEffect(.regular, in: Capsule())
                .padding(.horizontal, 24)
        } else {
            pill
                .background(.regularMaterial, in: Capsule())
                .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
                .padding(.horizontal, 24)
        }
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

struct AccountPickerRow: View {
    let title: String
    @Binding var selection: UUID?
    let accounts: [Account]
    var noneLabel: String = "None"
    @State private var showSheet = false

    private var selectedAccount: Account? {
        accounts.first { $0.id == selection }
    }

    var body: some View {
        HStack {
            Text(title)
                .foregroundStyle(Theme.ink)
            Spacer()
            Button {
                showSheet = true
            } label: {
                HStack(spacing: 6) {
                    if let acc = selectedAccount {
                        AccountIcon(account: acc, size: 22)
                        Text(acc.name)
                            .lineLimit(1)
                    } else {
                        Text(noneLabel)
                    }
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Theme.secondaryInk)
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Theme.track.opacity(0.65), in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .sheet(isPresented: $showSheet) {
            NavigationStack {
                List {
                    Button {
                        selection = nil
                        showSheet = false
                    } label: {
                        HStack(spacing: 12) {
                            IconBadge(symbol: "questionmark.circle", color: Theme.secondaryInk, size: 32)
                            Text(noneLabel).foregroundStyle(Theme.ink)
                            Spacer()
                            if selection == nil {
                                Image(systemName: "checkmark").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.cobalt)
                            }
                        }
                    }
                    ForEach(accounts) { acc in
                        Button {
                            selection = acc.id
                            showSheet = false
                        } label: {
                            HStack(spacing: 12) {
                                AccountIcon(account: acc, size: 32)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(acc.name).foregroundStyle(Theme.ink)
                                    Text(acc.kind.title).font(.caption).foregroundStyle(Theme.secondaryInk)
                                }
                                Spacer()
                                if selection == acc.id {
                                    Image(systemName: "checkmark").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.cobalt)
                                }
                            }
                        }
                    }
                }
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { showSheet = false }
                    }
                }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }
}
