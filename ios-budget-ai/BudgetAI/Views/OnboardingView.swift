import SwiftUI
import SwiftData

struct OnboardingView: View {
    @Environment(\.modelContext) private var context
    @AppStorage(Keys.onboarded) private var onboarded = false
    @AppStorage(Keys.userName) private var userName = ""
    @AppStorage(Keys.currency) private var currency = "BHD"
    @State private var name = ""
    @State private var startingBalance = ""
    @State private var appeared = false
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    hero
                    VStack(spacing: 0) {
                        field(icon: "person.fill", title: "Your first name") {
                            TextField("Ahmed", text: $name)
                                .textContentType(.givenName)
                                .focused($focused)
                        }
                        Divider().padding(.leading, 52)
                        NavigationLink {
                            CurrencyPickerView(selection: $currency)
                        } label: {
                            field(icon: "dollarsign.circle.fill", title: "Currency") {
                                HStack {
                                    Text("\(currency) · \(Money.symbol(currency))").foregroundStyle(Theme.ink)
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        Divider().padding(.leading, 52)
                        field(icon: "building.columns.fill", title: "Current bank balance") {
                            TextField(Money.format(0, currency), text: $startingBalance)
                                .keyboardType(.decimalPad)
                                .focused($focused)
                        }
                    }
                    .card(padding: 4)

                    VStack(spacing: 12) {
                        Button(action: startFresh) {
                            Text("Get started").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 8)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)

                        Button(action: explore) {
                            Text("Explore with sample data").font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity).padding(.vertical, 6)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                    }
                    Label("Your data stays on this iPhone.", systemImage: "lock.shield.fill")
                        .font(.footnote)
                        .foregroundStyle(Theme.secondaryInk)
                        .frame(maxWidth: .infinity)
                }
                .padding(20)
            }
            .scrollDismissesKeyboard(.interactively)
            .canvasBackground()
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { focused = false }
                }
            }
        }
        .onAppear { withAnimation(.spring(response: 0.8, dampingFraction: 0.8)) { appeared = true } }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 68, height: 68)
                .background(Theme.cobalt, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .scaleEffect(appeared ? 1 : 0.6)
                .opacity(appeared ? 1 : 0)
            Text("Your money,\nclearly.")
                .font(.system(size: 40, weight: .bold))
                .foregroundStyle(Theme.ink)
            Text("Budgets, bills, net worth and an AI advisor that knows exactly how much you can safely spend today.")
                .font(.body)
                .foregroundStyle(Theme.secondaryInk)
        }
        .padding(.top, 24)
        .offset(y: appeared ? 0 : 16)
        .opacity(appeared ? 1 : 0)
    }

    private func field<Content: View>(icon: String, title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(Theme.cobalt).frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption).foregroundStyle(Theme.secondaryInk)
                content()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    private func startFresh() {
        userName = name.trimmingCharacters(in: .whitespaces)
        Ledger.eraseAll(context: context)
        let balance = Money.parse(startingBalance) ?? 0
        context.insert(Account(name: "Main account", kind: .bank, balance: balance))
        context.insert(Account(name: "Cash wallet", kind: .cash, balance: 0))
        Ledger.recordSnapshot(context: context)
        try? context.save()
        finish()
    }

    private func explore() {
        userName = name.trimmingCharacters(in: .whitespaces).isEmpty ? "Ahmed" : name.trimmingCharacters(in: .whitespaces)
        SampleData.load(into: context)
        finish()
    }

    private func finish() {
        Task { await Notifier.requestAuthorization() }
        onboarded = true
    }
}

struct CurrencyPickerView: View {
    @Binding var selection: String
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var all: [String] {
        let codes = Locale.commonISOCurrencyCodes.filter { !Money.popularCurrencies.contains($0) }
        guard !query.isEmpty else { return codes }
        return codes.filter { $0.localizedCaseInsensitiveContains(query) || name($0).localizedCaseInsensitiveContains(query) }
    }

    private var popular: [String] {
        guard !query.isEmpty else { return Money.popularCurrencies }
        return Money.popularCurrencies.filter { $0.localizedCaseInsensitiveContains(query) || name($0).localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        List {
            if !popular.isEmpty {
                Section("Popular") { ForEach(popular, id: \.self, content: row) }
            }
            Section("All currencies") { ForEach(all, id: \.self, content: row) }
        }
        .searchable(text: $query, prompt: "Search currency")
        .navigationTitle("Currency")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func name(_ code: String) -> String {
        Locale(identifier: "en_US").localizedString(forCurrencyCode: code) ?? code
    }

    private func row(_ code: String) -> some View {
        Button {
            selection = code
            dismiss()
        } label: {
            HStack {
                Text(Money.symbol(code))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.cobalt)
                    .frame(width: 44, alignment: .leading)
                VStack(alignment: .leading) {
                    Text(name(code)).foregroundStyle(Theme.ink)
                    Text(code).font(.caption).foregroundStyle(Theme.secondaryInk)
                }
                Spacer()
                if selection == code { Image(systemName: "checkmark").foregroundStyle(Theme.cobalt).fontWeight(.semibold) }
            }
        }
    }
}
