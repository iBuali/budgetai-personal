import SwiftUI
import SwiftData

// MARK: - Wishlist Intelligence Dashboard (Card 2)

struct WishlistDashboardView: View {
    var onSimulateBuyNow: (Double, String) -> Void

    @Query(sort: \MoneyTransaction.date, order: .reverse) private var transactions: [MoneyTransaction]
    @Query(sort: \Account.createdAt) private var accounts: [Account]
    @Query private var budgets: [Budget]
    @Query private var goals: [SavingsGoal]
    @Query(sort: \Bill.nextDueDate) private var bills: [Bill]
    @AppStorage(Keys.currency) private var currency = "BHD"

    @State private var showAddSheet = false
    @State private var editingItem: WishlistItem? = nil
    @State private var inspectingItem: WishlistItem? = nil

    private let store = WishlistStore.shared

    var body: some View {
        let f = Finance(transactions: transactions, accounts: accounts, budgets: budgets, goals: goals, bills: bills)
        let projection = FinancialProjectionEngine.project(finance: f, period: .threeMonths, currency: currency)
        let sortedItems = store.items.sorted { lhs, rhs in
            if lhs.priority.sortRank != rhs.priority.sortRank {
                return lhs.priority.sortRank < rhs.priority.sortRank
            }
            return lhs.updatedAt > rhs.updatedAt
        }

        ScrollView {
            VStack(spacing: 14) {
                if sortedItems.isEmpty {
                    ContentUnavailableView {
                        Label("Your Wishlist is Empty", systemImage: "heart.text.square")
                    } description: {
                        Text("Add products or links you want to buy. FALAK tracks prices and tells you when each item fits your budget safely.")
                    } actions: {
                        Button("Add Wishlist Item") { showAddSheet = true }
                            .buttonStyle(.borderedProminent)
                    }
                    .padding(.top, 48)
                } else {
                    ForEach(sortedItems) { item in
                        let eval = WishlistEvaluator.evaluate(item: item, finance: f, projection: projection, currency: currency)
                        Button {
                            inspectingItem = item
                        } label: {
                            wishlistRow(item: item, eval: eval)
                        }
                        .buttonStyle(PressableStyle())
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 28)
        }
        .canvasBackground()
        .navigationTitle("Wishlist Intelligence")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Add", systemImage: "plus") { showAddSheet = true }
            }
        }
        .sheet(isPresented: $showAddSheet) {
            WishlistItemEditorSheet(existing: nil)
        }
        .sheet(item: $editingItem) { item in
            WishlistItemEditorSheet(existing: item)
        }
        .sheet(item: $inspectingItem) { item in
            let latest = store.items.first(where: { $0.id == item.id }) ?? item
            let eval = WishlistEvaluator.evaluate(item: latest, finance: f, projection: projection, currency: currency)
            WishlistItemDetailSheet(
                item: latest,
                evaluation: eval,
                currency: currency,
                onEdit: {
                    inspectingItem = nil
                    editingItem = latest
                },
                onSimulate: {
                    inspectingItem = nil
                    onSimulateBuyNow(latest.currentPrice, latest.name)
                }
            )
        }
    }

    private func wishlistRow(item: WishlistItem, eval: WishlistEvaluation) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                wishlistThumbnail(item: item, size: 52)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(item.name)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.ink)
                            .lineLimit(1)
                        Text(item.priority.rawValue)
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Theme.track, in: Capsule())
                            .foregroundStyle(Theme.secondaryInk)
                    }

                    HStack(spacing: 8) {
                        Text(Money.format(item.currentPrice, currency))
                            .font(.subheadline.weight(.bold).monospacedDigit())
                            .foregroundStyle(Theme.ink)
                        if let target = item.targetPrice, target > 0 {
                            Text("Target \(Money.format(target, currency))")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(item.hasReachedTargetPrice ? Theme.positive : Theme.secondaryInk)
                        }
                        if item.priceReductionPercent >= 1 {
                            Text("−\(Int(item.priceReductionPercent.rounded()))%")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(Theme.positive)
                        }
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }

            HStack {
                Text(eval.suitability.rawValue)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(eval.suitability.status.color.opacity(0.14), in: Capsule())
                    .foregroundStyle(eval.suitability.status.color)
                if item.hasReachedTargetPrice {
                    Text("Target Reached")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Theme.positive.opacity(0.14), in: Capsule())
                        .foregroundStyle(Theme.positive)
                }
                Spacer()
            }
        }
        .card(padding: 14)
    }

    @ViewBuilder
    private func wishlistThumbnail(item: WishlistItem, size: CGFloat) -> some View {
        if let urlStr = item.imageURL, let url = URL(string: urlStr) {
            AsyncImage(url: url) { phase in
                if let img = phase.image {
                    img.resizable().scaledToFill()
                } else {
                    CategoryIcon(category: SpendCategory(rawValue: item.categoryRaw) ?? .shopping, size: size)
                }
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        } else {
            CategoryIcon(category: SpendCategory(rawValue: item.categoryRaw) ?? .shopping, size: size)
        }
    }
}

// MARK: - Add / Edit Wishlist Item Sheet

struct WishlistItemEditorSheet: View {
    let existing: WishlistItem?
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState
    @AppStorage(Keys.currency) private var currency = "BHD"

    @State private var nameOrLink = ""
    @State private var productURL = ""
    @State private var priceText = ""
    @State private var targetPriceText = ""
    @State private var imageURL = ""
    @State private var priority: WishlistPriority = .medium
    @State private var category: SpendCategory = .shopping
    @State private var hasDesiredDate = false
    @State private var desiredDate = Calendar.current.date(byAdding: .month, value: 1, to: .now) ?? .now
    @State private var detecting = false
    @State private var detectNote: String? = nil

    private var canSave: Bool {
        !nameOrLink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (Money.parse(priceText) ?? 0) > 0
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Product name or link", text: $nameOrLink)
                    Button {
                        Task { await runDetection() }
                    } label: {
                        HStack(spacing: 8) {
                            if detecting {
                                ProgressView().scaleEffect(0.8)
                            } else {
                                Image(systemName: "sparkles")
                            }
                            Text(detecting ? "Detecting price & image…" : "Detect Price & Image with AI")
                                .font(.subheadline.weight(.medium))
                        }
                    }
                    .disabled(detecting || nameOrLink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    if let detectNote {
                        Text(detectNote)
                            .font(.caption)
                            .foregroundStyle(Theme.secondaryInk)
                    }
                } header: {
                    Text("Product")
                }

                Section("Pricing") {
                    HStack {
                        Text("Current Price (\(Money.symbol(currency)))")
                        Spacer()
                        TextField("0.000", text: $priceText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .monospacedDigit()
                            .frame(width: 120)
                    }
                    HStack {
                        Text("Target Price (optional)")
                        Spacer()
                        TextField("Optional", text: $targetPriceText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .monospacedDigit()
                            .frame(width: 120)
                    }
                }

                Section("Preferences") {
                    Picker("Priority", selection: $priority) {
                        ForEach(WishlistPriority.allCases) { p in Text(p.rawValue).tag(p) }
                    }
                    Picker("Category", selection: $category) {
                        ForEach(SpendCategory.expenseCases) { cat in Text(cat.title).tag(cat) }
                    }
                    Toggle("Desired purchase date", isOn: $hasDesiredDate)
                    if hasDesiredDate {
                        DatePicker("Date", selection: $desiredDate, displayedComponents: .date)
                    }
                }

                if let existing {
                    Section {
                        Button("Remove from Wishlist", role: .destructive) {
                            WishlistStore.shared.delete(id: existing.id)
                            appState.show("Removed \(existing.name)")
                            dismiss()
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .canvasBackground()
            .navigationTitle(existing == nil ? "Add Wishlist Item" : "Edit Wishlist Item")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { saveItem() }
                        .fontWeight(.semibold)
                        .disabled(!canSave)
                }
            }
            .onAppear {
                guard let existing else { return }
                nameOrLink = existing.name
                productURL = existing.productURL ?? ""
                priceText = Money.number(existing.currentPrice, decimals: Money.digits(currency)).replacingOccurrences(of: ",", with: "")
                if let tp = existing.targetPrice, tp > 0 {
                    targetPriceText = Money.number(tp, decimals: Money.digits(currency)).replacingOccurrences(of: ",", with: "")
                }
                imageURL = existing.imageURL ?? ""
                priority = existing.priority
                category = SpendCategory(rawValue: existing.categoryRaw) ?? .shopping
                if let dd = existing.desiredDate {
                    hasDesiredDate = true
                    desiredDate = dd
                }
            }
        }
    }

    private func runDetection() async {
        let input = nameOrLink.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return }
        if input.lowercased().hasPrefix("http") || input.lowercased().hasPrefix("www.") {
            productURL = input
        }
        detecting = true
        let info = await InsightsAIService.detectProductMetadata(queryOrURL: input, currency: currency)
        detecting = false
        guard let info else {
            detectNote = "Could not detect price automatically — please enter it manually."
            return
        }
        if let n = info.name, !n.isEmpty { nameOrLink = n }
        if let p = info.price, p > 0 {
            priceText = Money.number(p, decimals: Money.digits(currency)).replacingOccurrences(of: ",", with: "")
        }
        if let img = info.imageURL, !img.isEmpty { imageURL = img }
        if let catRaw = info.categoryRaw, let c = SpendCategory(rawValue: catRaw) { category = c }
        detectNote = info.price == nil ? "\(info.sourceNote) · Enter price manually." : info.sourceNote
    }

    private func saveItem() {
        guard let price = Money.parse(priceText), price > 0 else { return }
        let target = Money.parse(targetPriceText).flatMap { $0 > 0 ? $0 : nil }
        let cleanName = nameOrLink.trimmingCharacters(in: .whitespacesAndNewlines)
        if var item = existing {
            item.name = cleanName
            item.productURL = productURL.isEmpty ? item.productURL : productURL
            item.currentPrice = price
            item.targetPrice = target
            item.imageURL = imageURL.isEmpty ? item.imageURL : imageURL
            item.priority = priority
            item.categoryRaw = category.rawValue
            item.desiredDate = hasDesiredDate ? desiredDate : nil
            WishlistStore.shared.update(item)
            appState.show("Updated \(cleanName)")
        } else {
            let item = WishlistItem(
                name: cleanName,
                productURL: productURL.isEmpty ? nil : productURL,
                currentPrice: price,
                originalPrice: price,
                targetPrice: target,
                imageURL: imageURL.isEmpty ? nil : imageURL,
                priority: priority,
                desiredDate: hasDesiredDate ? desiredDate : nil,
                categoryRaw: category.rawValue
            )
            WishlistStore.shared.add(item)
            appState.show("Added \(cleanName) to Wishlist")
        }
        dismiss()
    }
}

// MARK: - Wishlist Detail Sheet

private struct WishlistItemDetailSheet: View {
    let item: WishlistItem
    let evaluation: WishlistEvaluation
    let currency: String
    let onEdit: () -> Void
    let onSimulate: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 12) {
                        if let img = item.imageURL, let url = URL(string: img) {
                            AsyncImage(url: url) { phase in
                                if let image = phase.image {
                                    image.resizable().scaledToFill()
                                } else {
                                    CategoryIcon(category: SpendCategory(rawValue: item.categoryRaw) ?? .shopping, size: 54)
                                }
                            }
                            .frame(width: 54, height: 54)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        } else {
                            CategoryIcon(category: SpendCategory(rawValue: item.categoryRaw) ?? .shopping, size: 54)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.name).font(.headline).foregroundStyle(Theme.ink)
                            Text(evaluation.suitability.rawValue)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(evaluation.suitability.status.color)
                        }
                    }

                    LabeledContent("Current Price", value: Money.format(item.currentPrice, currency))
                    if let tp = item.targetPrice, tp > 0 {
                        LabeledContent("Target Price", value: Money.format(tp, currency))
                    }
                    if item.priceReductionPercent >= 1 {
                        LabeledContent("Price Drop", value: "−\(Int(item.priceReductionPercent.rounded()))%")
                    }
                    LabeledContent("Priority", value: item.priority.rawValue)
                }

                Section("Financial Purchase Intelligence") {
                    Text(evaluation.reason)
                        .font(.subheadline)
                        .foregroundStyle(Theme.ink)
                    Text(evaluation.recommendation)
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryInk)
                }

                Section {
                    Button {
                        onSimulate()
                    } label: {
                        Label("Simulate in Buy Now?", systemImage: "cart.badge.questionmark")
                            .fontWeight(.semibold)
                            .foregroundStyle(Theme.cobalt)
                    }
                    Button {
                        onEdit()
                    } label: {
                        Label("Update Price / Edit Item", systemImage: "pencil")
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .canvasBackground()
            .navigationTitle("Wishlist Item")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
