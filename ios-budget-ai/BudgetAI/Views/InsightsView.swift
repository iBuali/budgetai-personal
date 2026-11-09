import SwiftUI

struct InsightsView: View {
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    Text("Plan ahead with smart money tools")
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondaryInk)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                        .padding(.top, -8)

                    NavigationLink(value: InsightRoute.timeMachine) {
                        featureCard(title: "Financial Time Machine",
                                    subtitle: "See where your money is heading. Simulate your balance 30 days to 1 year ahead.",
                                    symbol: "clock.arrow.2.circlepath",
                                    colors: [Color(hex: 0x1E3FAE), Color(hex: 0x6D4AE0)],
                                    available: true)
                    }
                    .buttonStyle(PressableStyle())

                    NavigationLink(value: InsightRoute.smsTestingLab) {
                        featureCard(title: "SMS Testing Lab",
                                    subtitle: "Bulk test Bahrain bank SMS, compare expected vs actual, self-learn patterns and publish parser knowledge.",
                                    symbol: "flask.fill",
                                    colors: [Color(hex: 0x22A565), Color(hex: 0x0EA5E9)],
                                    available: true)
                    }
                    .buttonStyle(PressableStyle())

                    featureCard(title: "Can I Afford It?",
                                subtitle: "Check if a purchase fits your plans before you buy.",
                                symbol: "cart.badge.questionmark",
                                colors: [Color(hex: 0x0EA5A4), Color(hex: 0x22A565)],
                                available: false)

                    featureCard(title: "Life Planner",
                                subtitle: "Plan big life goals like a home, a wedding or retirement.",
                                symbol: "map.fill",
                                colors: [Color(hex: 0xF08A24), Color(hex: 0xEC4899)],
                                available: false)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .canvasBackground()
            .navigationTitle("Insights")
            .navigationDestination(for: InsightRoute.self) { route in
                switch route {
                case .timeMachine: FinancialTimeMachineView()
                case .smsTestingLab: SMSTestingLabView()
                }
            }
        }
    }

    private func featureCard(title: String, subtitle: String, symbol: String, colors: [Color], available: Bool) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 54, height: 54)
                .background(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing),
                            in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .opacity(available ? 1 : 0.55)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    if !available {
                        Text("Coming soon")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Theme.track, in: Capsule())
                            .foregroundStyle(Theme.secondaryInk)
                            .fixedSize()
                    }
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryInk)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if available {
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
        }
        .card()
        .opacity(available ? 1 : 0.85)
        .accessibilityElement(children: .combine)
        .accessibilityHint(available ? "Opens \(title)" : "Coming soon")
    }
}

enum InsightRoute: Hashable { case timeMachine, smsTestingLab }
