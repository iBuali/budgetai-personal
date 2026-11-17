import SwiftUI
import SwiftData

enum CategoryTab: String, CaseIterable, Identifiable {
    case income = "Income", expenses = "Expenses", transfers = "Transfers"
    var id: String { rawValue }
}

/// Manage built-in and custom categories.
struct CategoriesView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \CustomCategory.createdAt) private var custom: [CustomCategory]
    @State private var editorTarget: CategoryEditorTarget?
    @State private var selectedTab: CategoryTab = .expenses
    @State private var searchText = ""

    private var filteredCategories: [SpendCategory] {
        let base: [SpendCategory]
        switch selectedTab {
        case .income:
            base = SpendCategory.incomeCases
        case .expenses:
            base = SpendCategory.expenseCases
        case .transfers:
            base = SpendCategory.transferCases
        }
        guard !searchText.trimmingCharacters(in: .whitespaces).isEmpty else { return base }
        return base.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        let registry = CategoryRegistry.shared
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 6) {
                    ForEach(CategoryTab.allCases) { tab in
                        Button {
                            withAnimation(.snappy) { selectedTab = tab }
                        } label: {
                            Text(tab.rawValue)
                                .font(.subheadline.weight(selectedTab == tab ? .semibold : .medium))
                                .foregroundStyle(selectedTab == tab ? Theme.ink : Theme.secondaryInk)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .background(selectedTab == tab ? Theme.track : Color.clear, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }

                Text(selectedTab.rawValue)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.ink)
                    .padding(.horizontal, 4)
                    .padding(.top, 4)

                VStack(spacing: 8) {
                    ForEach(filteredCategories) { category in
                        categoryBlock(category)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .id(registry.order)
        .canvasBackground()
        .searchable(text: $searchText, prompt: "Search")
        .navigationTitle("Categories")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("New category", systemImage: "plus") {
                    editorTarget = .new(parent: nil, income: selectedTab == .income, transfer: selectedTab == .transfers)
                }
            }
        }
        .sheet(item: $editorTarget) { CategoryEditor(target: $0) }
        .onAppear { registry.reload(context: context) }
    }

    @ViewBuilder
    private func categoryBlock(_ category: SpendCategory) -> some View {
        let customModel = model(category)
        HStack(spacing: 12) {
            CategoryIcon(category: category, size: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(category.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.ink)
                if !category.isBuiltIn {
                    Text("Custom").font(.caption2).foregroundStyle(Theme.secondaryInk)
                } else if customModel != nil {
                    Text("Modified").font(.caption2).foregroundStyle(Theme.cobalt)
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color(uiColor: .tertiaryLabel))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture {
            if let customModel {
                editorTarget = .edit(customModel.id)
            } else if category.isBuiltIn {
                editorTarget = .editBuiltIn(category.rawValue)
            }
        }
    }

    private func model(_ category: SpendCategory) -> CustomCategory? {
        custom.first { $0.key == category.rawValue }
    }
}

enum CategoryEditorTarget: Identifiable {
    case new(parent: String?, income: Bool, transfer: Bool = false)
    case edit(UUID)
    case editBuiltIn(String)

    var id: String {
        switch self {
        case .new(let parent, let income, let transfer): "new-\(parent ?? "root")-\(income)-\(transfer)"
        case .edit(let id): id.uuidString
        case .editBuiltIn(let key): "builtin-\(key)"
        }
    }
}

struct CategoryEditor: View {
    let target: CategoryEditorTarget
    var onCreate: ((SpendCategory) -> Void)? = nil
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \CustomCategory.createdAt) private var custom: [CustomCategory]
    @State private var name = ""
    @State private var emoji = ""
    @State private var colorHex = 0x1E3FAE
    @State private var parentKey = ""
    @State private var isIncome = false
    @State private var isTransfer = false
    @State private var isEssential = false
    @State private var confirmDelete = false
    @State private var confirmReset = false
    @State private var loaded = false

    static let palette = [0x1E3FAE, 0x2BB673, 0xF08A24, 0xF05252, 0x8B5CF6, 0x0EA5A4, 0xEC4899, 0xE9A23B, 0x0EA5E9, 0x6B7385]

    private var existing: CustomCategory? {
        switch target {
        case .edit(let id):
            return custom.first { $0.id == id }
        case .editBuiltIn(let key):
            return custom.first { $0.key == key }
        case .new:
            return nil
        }
    }

    private var builtInKey: String? {
        switch target {
        case .editBuiltIn(let key):
            return key
        case .edit(let id):
            guard let key = custom.first(where: { $0.id == id })?.key,
                  SpendCategory.builtInInfo[key] != nil else { return nil }
            return key
        case .new:
            return nil
        }
    }

    private var isEditingBuiltIn: Bool {
        builtInKey != nil
    }

    private var parentOptions: [SpendCategory] {
        (isIncome ? SpendCategory.incomeCases : SpendCategory.expenseCases.filter { $0 != .transfers })
            .filter { $0.rawValue != existing?.key }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 14) {
                        preview
                        TextField("Category name", text: $name)
                            .font(.title3.weight(.semibold))
                            .textInputAutocapitalization(.words)
                    }
                    .padding(.vertical, 4)
                }

                Section("Emoji") {
                    EmojiPicker(emoji: $emoji, suggestions: EmojiPicker.categorySuggestions)
                }

                Section {
                    if existing == nil && !isEditingBuiltIn {
                        Picker("Type", selection: Binding(
                            get: { isTransfer ? CategoryTab.transfers : (isIncome ? .income : .expenses) },
                            set: { newTab in
                                isIncome = (newTab == .income)
                                isTransfer = (newTab == .transfers)
                                if isIncome || isTransfer { isEssential = false }
                            }
                        )) {
                            Text("Expense").tag(CategoryTab.expenses)
                            Text("Income").tag(CategoryTab.income)
                            Text("Transfer").tag(CategoryTab.transfers)
                        }
                        .pickerStyle(.segmented)
                    }
                    if !isIncome && !isTransfer {
                        Toggle("Essential spending", isOn: $isEssential)
                    }
                }

                Section("Color") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: 12) {
                        ForEach(Self.palette, id: \.self) { hex in
                            Button { colorHex = hex } label: {
                                Circle()
                                    .fill(Color(hex: UInt32(hex)))
                                    .frame(width: 36, height: 36)
                                    .overlay(Circle().stroke(.white, lineWidth: 3).padding(3).opacity(colorHex == hex ? 1 : 0))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Color")
                        }
                    }
                    .padding(.vertical, 6)
                }

                if isEditingBuiltIn {
                    if existing != nil {
                        Section {
                            Button("Reset to original", role: .destructive) { confirmReset = true }
                        }
                    }
                } else if existing != nil {
                    Section {
                        Button("Delete category", role: .destructive) { confirmDelete = true }
                    }
                }
            }
            .navigationTitle(existing == nil && !isEditingBuiltIn ? "New category" : "Edit category")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save).fontWeight(.semibold)
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .confirmationDialog("Delete this category?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive, action: delete)
            } message: {
                Text("Its transactions will move to Other.")
            }
            .confirmationDialog("Reset this category?", isPresented: $confirmReset, titleVisibility: .visible) {
                Button("Reset to original", role: .destructive, action: resetToDefault)
            } message: {
                Text("This will restore the original name, emoji, color and settings.")
            }
            .onAppear(perform: load)
        }
    }

    private var preview: some View {
        let color = parentKey.isEmpty ? Color(hex: UInt32(colorHex)) : SpendCategory.unchecked(parentKey).color
        let fallbackSymbol = builtInKey.flatMap { SpendCategory.builtInInfo[$0]?.symbol } ?? (parentKey.isEmpty ? "tag.fill" : SpendCategory.unchecked(parentKey).symbol)
        return Group {
            if emoji.isEmpty {
                IconBadge(symbol: fallbackSymbol, color: color, size: 52)
            } else {
                EmojiBadge(emoji: emoji, color: color, size: 52)
            }
        }
    }

    private func children(of key: String) -> [CustomCategory] { custom.filter { $0.parentKey == key } }

    private func load() {
        guard !loaded else { return }
        loaded = true
        switch target {
        case .new(let parent, let income, let transfer):
            parentKey = parent ?? ""
            isIncome = income
            isTransfer = transfer
        case .edit:
            guard let c = existing else { return }
            name = c.name
            emoji = c.emoji
            colorHex = c.colorHex
            parentKey = c.parentKey
            isIncome = c.isIncome
            isTransfer = c.isTransfer
            isEssential = c.isEssential
        case .editBuiltIn(let key):
            if let c = existing {
                name = c.name
                emoji = c.emoji
                colorHex = c.colorHex
                parentKey = c.parentKey
                isIncome = c.isIncome
                isTransfer = c.isTransfer
                isEssential = c.isEssential
            } else if let b = SpendCategory.builtInInfo[key] {
                name = b.title
                emoji = b.emoji
                colorHex = SpendCategory.builtInHex[key] ?? 0x1E3FAE
                parentKey = b.parentKey
                isIncome = b.isIncome
                isTransfer = b.isTransfer
                isEssential = b.isEssential
            }
        }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let model: CustomCategory
        if let existing {
            model = existing
            model.name = trimmed
            model.emoji = emoji
            model.colorHex = colorHex
            model.parentKey = parentKey
            model.isTransfer = isTransfer
            model.isEssential = isEssential
        } else if let key = builtInKey {
            model = CustomCategory(name: trimmed, emoji: emoji, colorHex: colorHex, parentKey: parentKey,
                                   isIncome: isIncome, isTransfer: isTransfer, isEssential: isEssential, key: key)
            context.insert(model)
        } else {
            let parentIncome = parentKey.isEmpty ? isIncome : SpendCategory.unchecked(parentKey).isIncomeCategory
            let parentTransfer = parentKey.isEmpty ? isTransfer : SpendCategory.unchecked(parentKey).isTransferCategory
            model = CustomCategory(name: trimmed, emoji: emoji, colorHex: colorHex, parentKey: parentKey,
                                   isIncome: parentIncome, isTransfer: parentTransfer, isEssential: isEssential)
            context.insert(model)
        }
        try? context.save()
        CategoryRegistry.shared.reload(context: context)
        if existing == nil { onCreate?(SpendCategory.unchecked(model.key)) }
        dismiss()
    }

    private func resetToDefault() {
        if let existing {
            context.delete(existing)
            try? context.save()
            CategoryRegistry.shared.reload(context: context)
        }
        dismiss()
    }

    private func delete() {
        guard let c = existing else { return }
        let key = c.key
        let fallback = c.parentKey.isEmpty
            ? (c.isTransfer ? SpendCategory.transfers.rawValue : (c.isIncome ? SpendCategory.income.rawValue : SpendCategory.other.rawValue))
            : c.parentKey
        let subKeys = Set(children(of: key).map(\.key))
        let txs = (try? context.fetch(FetchDescriptor<MoneyTransaction>())) ?? []
        for tx in txs {
            if tx.categoryRaw == key { tx.categoryRaw = fallback; tx.subcategoryKey = "" }
            if tx.subcategoryKey == key || subKeys.contains(tx.subcategoryKey) { tx.subcategoryKey = "" }
        }
        let budgets = (try? context.fetch(FetchDescriptor<Budget>())) ?? []
        for b in budgets {
            let remaining = b.categories.filter { $0.rawValue != key }
            if remaining.isEmpty {
                context.delete(b)
            } else if remaining.count != b.categories.count {
                b.categories = remaining
            }
        }
        let bills = (try? context.fetch(FetchDescriptor<Bill>())) ?? []
        for b in bills where b.categoryRaw == key { b.categoryRaw = SpendCategory.bills.rawValue }
        for child in children(of: key) { context.delete(child) }
        context.delete(c)
        try? context.save()
        CategoryRegistry.shared.reload(context: context)
        dismiss()
    }
}

/// Grid of categories with a "New" tile.
struct CategoryPickerGrid: View {
    @Binding var category: SpendCategory
    @Binding var subcategory: SpendCategory?
    var income: Bool
    var includeAllTypes: Bool = false
    var onPick: () -> Void = {}
    @State private var editorTarget: CategoryEditorTarget?

    var body: some View {
        let registry = CategoryRegistry.shared
        let options: [SpendCategory] = {
            if includeAllTypes {
                return SpendCategory.allCases.filter { $0 != .transfers }
            }
            return income
                ? (SpendCategory.incomeCases + [.internalTransfer])
                : SpendCategory.expenseCases.filter { $0 != .transfers && $0 != .visaTransfer }
        }()
        VStack(alignment: .leading, spacing: 14) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 12) {
                ForEach(options) { c in
                    Button {
                        subcategory = nil
                        category = c
                        onPick()
                    } label: {
                        VStack(spacing: 6) {
                            CategoryIcon(category: c, size: 44)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                                        .stroke(category == c ? c.color : .clear, lineWidth: 2)
                                )
                            Text(c.shortTitle)
                                .font(.caption2.weight(category == c ? .semibold : .regular))
                                .foregroundStyle(category == c ? Theme.ink : Theme.secondaryInk)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                    }
                    .buttonStyle(PressableStyle())
                }
                Button { editorTarget = .new(parent: nil, income: income) } label: {
                    VStack(spacing: 6) {
                        Image(systemName: "plus")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(Theme.cobalt)
                            .frame(width: 44, height: 44)
                            .background(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(Theme.cobalt.opacity(0.4), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])))
                        Text("New").font(.caption2).foregroundStyle(Theme.cobalt)
                    }
                }
                .buttonStyle(PressableStyle())
            }
        }
        .id(registry.order)
        .padding(.vertical, 6)
        .sensoryFeedback(.selection, trigger: category)
        .sheet(item: $editorTarget) { target in
            CategoryEditor(target: target) { created in
                category = created
                subcategory = nil
                onPick()
            }
        }
    }
}
