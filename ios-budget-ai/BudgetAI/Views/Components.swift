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
    var body: some View { IconBadge(symbol: category.symbol, color: category.color, size: size) }
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
        .onAppear { withAnimation(.spring(response: 0.9, dampingFraction: 0.85).delay(0.1)) { shown = progress } }
        .onChange(of: progress) { _, v in withAnimation(.spring(response: 0.6, dampingFraction: 0.85)) { shown = v } }
    }
}

struct ProgressBar: View {
    let progress: Double
    var color: Color = Theme.cobalt
    var height: CGFloat = 7
    @State private var shown: Double = 0

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track)
                Capsule().fill(color).frame(width: max(height, geo.size.width * min(max(shown, 0), 1)))
            }
        }
        .frame(height: height)
        .onAppear { withAnimation(.spring(response: 0.8, dampingFraction: 0.85).delay(0.05)) { shown = progress } }
        .onChange(of: progress) { _, v in withAnimation(.spring(response: 0.5)) { shown = v } }
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
            CategoryIcon(category: tx.isIncome ? .income : tx.category)
            VStack(alignment: .leading, spacing: 3) {
                Text(tx.merchant)
                    .font(.body.weight(.medium))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                if tx.isPossibleDuplicate {
                    Label("Possible duplicate", systemImage: "exclamationmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(Theme.negative)
                } else {
                    HStack(spacing: 4) {
                        Text(tx.category.title)
                        if tx.source == .sms { Image(systemName: "message.fill").font(.caption2) }
                    }
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondaryInk)
                }
            }
            Spacer(minLength: 8)
            Text(Money.format(tx.signedAmount, currency, signed: true))
                .font(.body.weight(.semibold).monospacedDigit())
                .foregroundStyle(tx.isIncome ? Theme.positive : (tx.category == .transfers ? Theme.secondaryInk : Theme.negative))
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
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
