import SwiftUI
import SwiftData

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

/// Pick an emoji from a categorized, searchable bottom-sheet grid.
struct EmojiPicker: View {
    @Binding var emoji: String
    var suggestions: [String]
    @State private var showSheet = false

    static let categorySuggestions = ["🛒", "🍔", "☕️", "🚗", "⛽️", "🛍️", "💡", "🏠", "💊", "🎬", "📺", "🎓", "✈️", "🎁", "👶", "🐶",
                                      "💪", "💇", "🧾", "📱", "🎮", "🕌", "❤️", "💼", "💰", "📈", "🏦", "🧸", "🍕", "🥗", "🚕", "🏖️"]
    static let accountSuggestions = ["🏦", "💳", "💵", "👛", "💰", "📈", "🏠", "🚗", "🪙", "💎", "🏧", "🧾", "📊", "🛟", "🔐", "🌍"]

    var body: some View {
        HStack(spacing: 12) {
            Button {
                showSheet = true
            } label: {
                HStack(spacing: 10) {
                    Text("Emoji")
                        .foregroundStyle(Theme.ink)
                    Spacer()
                    Text(emoji.isEmpty ? "❓" : emoji)
                        .font(.system(size: 24))
                        .frame(width: 40, height: 40)
                        .background(Theme.track.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !emoji.isEmpty {
                Button("Clear") {
                    emoji = ""
                }
                .font(.subheadline)
                .foregroundStyle(Theme.secondaryInk)
            }
        }
        .sensoryFeedback(.selection, trigger: emoji)
        .sheet(isPresented: $showSheet) {
            EmojiPickerSheet(emoji: $emoji, suggestions: suggestions)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }
}

private struct EmojiGroup: Identifiable {
    let id: String
    let title: String
    let icon: String
    let items: [(emoji: String, keywords: String)]
}

private struct EmojiPickerSheet: View {
    @Binding var emoji: String
    let suggestions: [String]
    @Environment(\.dismiss) private var dismiss
    @State private var selectedGroupID = "suggested"
    @State private var searchText = ""

    private var groups: [EmojiGroup] {
        [
            EmojiGroup(id: "suggested", title: "Suggested", icon: "😀", items: suggestions.map { ($0, "") } + [
                ("😀", "smile happy face"), ("🥳", "party celebrate"), ("😎", "cool"), ("🤩", "star"),
                ("💼", "work job business"), ("💰", "money bag cash"), ("💳", "card credit"), ("🏦", "bank")
            ]),
            EmojiGroup(id: "people", title: "People", icon: "👋", items: [
                ("👋", "wave hello"), ("🙌", "hands celebrate"), ("👏", "clap"), ("🤝", "handshake deal"),
                ("👶", "baby kid child"), ("👧", "girl"), ("👦", "boy"), ("👩", "woman"),
                ("👨", "man"), ("👪", "family"), ("🧑‍💻", "tech developer"), ("💇", "hair salon haircut"),
                ("💆", "spa massage"), ("🏋️", "gym workout"), ("🧘", "yoga"), ("🩺", "doctor health")
            ]),
            EmojiGroup(id: "nature", title: "Animals & Nature", icon: "🦄", items: [
                ("🦄", "unicorn"), ("🐶", "dog pet"), ("🐱", "cat pet"), ("🐾", "paw pet"),
                ("🐟", "fish"), ("🌿", "plant leaf"), ("🌸", "flower"), ("🌳", "tree"),
                ("☀️", "sun"), ("🌙", "moon"), ("🌧️", "rain"), ("🌊", "ocean sea"),
                ("🔥", "fire"), ("⭐️", "star"), ("🌈", "rainbow"), ("❄️", "snow")
            ]),
            EmojiGroup(id: "food", title: "Food & Drink", icon: "🍔", items: [
                ("🍔", "burger food"), ("🍕", "pizza"), ("🌮", "taco"), ("🍣", "sushi"),
                ("🥗", "salad healthy"), ("🍝", "pasta"), ("🥪", "sandwich"), ("🍗", "chicken"),
                ("☕️", "coffee cafe"), ("🍵", "tea"), ("🧃", "juice"), ("🥤", "drink soda"),
                ("🍰", "cake dessert"), ("🍩", "donut"), ("🍦", "ice cream"), ("🛒", "grocery cart")
            ]),
            EmojiGroup(id: "activities", title: "Activities", icon: "⚾", items: [
                ("🎃", "halloween"), ("🎄", "christmas"), ("🎆", "fireworks"), ("🎇", "sparkler"),
                ("🧨", "firecracker"), ("✨", "sparkles"), ("🎈", "balloon"), ("🎉", "party"),
                ("🎀", "ribbon"), ("🎁", "gift present"), ("🎟️", "ticket"), ("🎫", "ticket event"),
                ("🏆", "trophy award"), ("🥇", "gold medal"), ("⚽️", "soccer football"), ("⚾️", "baseball"),
                ("🏀", "basketball"), ("🎾", "tennis"), ("🎳", "bowling"), ("⛳️", "golf"),
                ("🎮", "gaming game"), ("🎲", "dice"), ("🎯", "target goal"), ("🎬", "movie cinema")
            ]),
            EmojiGroup(id: "travel", title: "Travel & Places", icon: "✈️", items: [
                ("✈️", "flight plane travel"), ("🚗", "car auto"), ("🚕", "taxi uber"), ("🚌", "bus"),
                ("🚆", "train"), ("⛽️", "fuel gas petrol"), ("🅿️", "parking"), ("🏠", "home house rent"),
                ("🏢", "office building"), ("🏨", "hotel"), ("🏖️", "beach vacation"), ("🗺️", "map"),
                ("🧳", "luggage"), ("🚀", "rocket"), ("🛳️", "cruise ship"), ("🌍", "world globe")
            ]),
            EmojiGroup(id: "objects", title: "Objects", icon: "💡", items: [
                ("💡", "light idea electricity"), ("📱", "phone mobile"), ("💻", "laptop computer"), ("📺", "tv streaming"),
                ("🎧", "headphones music"), ("📷", "camera"), ("🛍️", "shopping bag"), ("👗", "clothes fashion"),
                ("👟", "shoes"), ("💊", "medicine health pharmacy"), ("🎓", "education school"), ("📚", "books"),
                ("🧾", "receipt bill"), ("💵", "cash dollar"), ("🪙", "coin"), ("💎", "gem diamond"),
                ("🔑", "key"), ("🔧", "tools repair"), ("🧸", "toy"), ("📦", "package box")
            ]),
            EmojiGroup(id: "symbols", title: "Symbols", icon: "❤️", items: [
                ("❤️", "heart love charity"), ("🧡", "orange heart"), ("💚", "green heart"), ("💙", "blue heart"),
                ("🕌", "mosque zakat"), ("📈", "chart stocks invest"), ("📊", "analytics"), ("💰", "savings"),
                ("🔐", "lock security"), ("🛟", "emergency fund"), ("⚡️", "electric bill"), ("💧", "water bill"),
                ("📶", "wifi internet"), ("✅", "check"), ("♻️", "recycle"), ("🏧", "atm")
            ])
        ]
    }

    private var activeGroup: EmojiGroup {
        groups.first { $0.id == selectedGroupID } ?? groups[0]
    }

    private var displayedEmojis: [String] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if q.isEmpty {
            var seen = Set<String>()
            return activeGroup.items.map(\.emoji).filter { seen.insert($0).inserted }
        }
        var seen = Set<String>()
        return groups.flatMap(\.items)
            .filter { $0.keywords.contains(q) || $0.emoji.contains(q) }
            .map(\.emoji)
            .filter { seen.insert($0).inserted }
    }

    var body: some View {
        VStack(spacing: 12) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(groups) { group in
                        let isSelected = group.id == selectedGroupID && searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        Button {
                            searchText = ""
                            withAnimation(.snappy(duration: 0.2)) {
                                selectedGroupID = group.id
                            }
                        } label: {
                            Text(group.icon)
                                .font(.system(size: 20))
                                .frame(width: 40, height: 36)
                                .background(
                                    isSelected ? Theme.track : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
            .padding(.top, 14)

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondaryInk)
                TextField("Search emojis", text: $searchText)
                    .font(.subheadline)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.subheadline)
                            .foregroundStyle(Theme.secondaryInk)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Theme.track.opacity(0.65), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(.horizontal, 16)

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text(searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? activeGroup.title : "Search Results")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.secondaryInk)
                        .padding(.horizontal, 16)

                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 8), spacing: 10) {
                        ForEach(displayedEmojis, id: \.self) { e in
                            Button {
                                emoji = e
                                dismiss()
                            } label: {
                                Text(e)
                                    .font(.system(size: 26))
                                    .frame(width: 38, height: 38)
                                    .background(
                                        emoji == e ? Theme.cobaltSoft : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 16)
                }
            }
        }
        .background(Theme.surface.ignoresSafeArea())
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
                IconBadge(symbol: "arrow.left.arrow.right", color: SpendCategory.internalTransferColor)
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
                } else if tx.needsBillReview {
                    HStack(spacing: 5) {
                        Image(systemName: "calendar.badge.plus")
                            .font(.caption2.weight(.bold))
                        Text("Add as recurring bill?")
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                    }
                    .foregroundStyle(Theme.cobalt)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2.5)
                    .background(Theme.cobalt.opacity(0.14), in: Capsule())
                } else {
                    HStack(spacing: 4) {
                        Text(subtitle)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Text("• \(DateFormatCache.shortTime(tx.date))")
                            .lineLimit(1)
                            .layoutPriority(1)
                    }
                    .font(.caption)
                    .minimumScaleFactor(0.8)
                    .foregroundStyle(Theme.secondaryInk)
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 4) {
                if let delta = tx.billPriceDelta {
                    Image(systemName: delta > 0 ? "arrowtriangle.up.fill" : "arrowtriangle.down.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(delta > 0 ? Theme.negative : Theme.positive)
                        .accessibilityLabel(delta > 0 ? "Price increased" : "Price decreased")
                }
                Text(tx.effectiveTransactionType == .internalTransfer ? Money.format(tx.amount, currency) : Money.format(tx.signedAmount, currency, signed: true))
                    .font(.body.weight(.semibold).monospacedDigit())
                    .foregroundStyle(tx.isPending ? Theme.secondaryInk : (tx.isIncome ? Theme.positive : (tx.isTransfer ? Theme.secondaryInk : Theme.negative)))
                    .lineLimit(1)
            }
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

struct DrawerMenuToolbarButtons: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        HStack(spacing: 12) {
            Button {
                withAnimation(.snappy(duration: 0.28)) {
                    appState.showNotifications = false
                    appState.showDrawer = true
                }
            } label: {
                Image(systemName: "line.3.horizontal")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Theme.ink)
            }
            .accessibilityLabel("Menu")

            Button {
                withAnimation(.snappy(duration: 0.22)) {
                    appState.showDrawer = false
                    appState.showNotifications.toggle()
                }
            } label: {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "bell")
                        .font(.body.weight(.medium))
                        .foregroundStyle(Theme.ink)
                    if appState.hasUnreadAlerts {
                        Circle()
                            .fill(Theme.negative)
                            .frame(width: 7, height: 7)
                            .offset(x: 2, y: -1)
                    }
                }
            }
            .accessibilityLabel("Notifications")
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
        Button {
            showSheet = true
        } label: {
            HStack {
                Text(title)
                    .foregroundStyle(Theme.ink)
                    .layoutPriority(1)
                Spacer()
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
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
                        .contentShape(Rectangle())
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
                            .contentShape(Rectangle())
                        }
                    }
                }
                .scrollContentBackground(.hidden)
                .canvasBackground()
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

struct SheetPickerOption<Value: Hashable>: Identifiable {
    let id: Value
    let title: String
    var subtitle: String? = nil
    var symbol: String? = nil
    var color: Color = Theme.cobalt
}

struct SheetPickerAddConfig {
    let title: String
    let placeholder: String
    let message: String
    let onAdd: (String) -> Void
}

struct SheetPickerRow<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [SheetPickerOption<Value>]
    var addConfig: SheetPickerAddConfig? = nil
    @State private var showSheet = false
    @State private var showAddAlert = false
    @State private var newItemText = ""

    private var selectedOption: SheetPickerOption<Value>? {
        options.first { $0.id == selection }
    }

    var body: some View {
        Button {
            showSheet = true
        } label: {
            HStack {
                Text(title)
                    .foregroundStyle(Theme.ink)
                    .layoutPriority(1)
                Spacer()
                HStack(spacing: 6) {
                    if let opt = selectedOption {
                        if let sym = opt.symbol {
                            IconBadge(symbol: sym, color: opt.color, size: 22)
                        }
                        Text(opt.title)
                            .lineLimit(1)
                    } else {
                        Text("None")
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
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showSheet) {
            NavigationStack {
                List {
                    ForEach(options) { opt in
                        Button {
                            selection = opt.id
                            showSheet = false
                        } label: {
                            HStack(spacing: 12) {
                                if let sym = opt.symbol {
                                    IconBadge(symbol: sym, color: opt.color, size: 32)
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(opt.title).foregroundStyle(Theme.ink)
                                    if let sub = opt.subtitle, !sub.isEmpty {
                                        Text(sub).font(.caption).foregroundStyle(Theme.secondaryInk)
                                    }
                                }
                                Spacer()
                                if selection == opt.id {
                                    Image(systemName: "checkmark")
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(Theme.cobalt)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                    }
                }
                .scrollContentBackground(.hidden)
                .canvasBackground()
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { showSheet = false }
                    }
                    if addConfig != nil {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Add", systemImage: "plus") {
                                newItemText = ""
                                showAddAlert = true
                            }
                        }
                    }
                }
                .alert(addConfig?.title ?? "Add", isPresented: $showAddAlert) {
                    TextField(addConfig?.placeholder ?? "", text: $newItemText)
                    Button("Add") {
                        addConfig?.onAdd(newItemText)
                        showSheet = false
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    if let msg = addConfig?.message {
                        Text(msg)
                    }
                }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }
}
