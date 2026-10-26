import SwiftUI
import SwiftData

/// Manage built-in and custom categories plus their sub-categories.
struct CategoriesView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \CustomCategory.createdAt) private var custom: [CustomCategory]
    @State private var editorTarget: CategoryEditorTarget?

    var body: some View {
        let registry = CategoryRegistry.shared
        List {
            Section {
                ForEach(SpendCategory.expenseCases.filter { $0 != .transfers }) { categoryBlock($0) }
            } header: {
                Text("Expenses")
            } footer: {
                Text("Tap + on a category to add sub-categories like Coffee under Food & Dining.")
            }
            Section("Income") {
                ForEach(SpendCategory.incomeCases) { categoryBlock($0) }
            }
            Section {
                Button("New category", systemImage: "plus.circle.fill") { editorTarget = .new(parent: nil, income: false) }
                Button("New income category", systemImage: "plus.circle") { editorTarget = .new(parent: nil, income: true) }
            }
        }
        .id(registry.order)
        .scrollContentBackground(.hidden)
        .canvasBackground()
        .navigationTitle("Categories")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("New category", systemImage: "plus") { editorTarget = .new(parent: nil, income: false) }
            }
        }
        .sheet(item: $editorTarget) { CategoryEditor(target: $0) }
        .onAppear { registry.reload(context: context) }
    }

    @ViewBuilder
    private func categoryBlock(_ category: SpendCategory) -> some View {
        HStack(spacing: 12) {
            CategoryIcon(category: category, size: 36)
            VStack(alignment: .leading, spacing: 1) {
                Text(category.title).foregroundStyle(Theme.ink)
                if !category.isBuiltIn { Text("Custom").font(.caption).foregroundStyle(Theme.secondaryInk) }
            }
            Spacer()
            Button {
                editorTarget = .new(parent: category.rawValue, income: category.isIncomeCategory)
            } label: {
                Image(systemName: "plus.circle").font(.title3)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Add sub-category to \(category.title)")
        }
        .contentShape(Rectangle())
        .onTapGesture { if let model = model(category) { editorTarget = .edit(model.id) } }

        ForEach(category.subcategories) { sub in
            HStack(spacing: 12) {
                Image(systemName: "arrow.turn.down.right").font(.caption).foregroundStyle(.tertiary)
                    .frame(width: 20)
                CategoryIcon(category: sub, size: 30)
                Text(sub.title).foregroundStyle(Theme.ink)
                Spacer()
            }
            .padding(.leading, 8)
            .contentShape(Rectangle())
            .onTapGesture { if let model = model(sub) { editorTarget = .edit(model.id) } }
        }
    }

    private func model(_ category: SpendCategory) -> CustomCategory? {
        custom.first { $0.key == category.rawValue }
    }
}

enum CategoryEditorTarget: Identifiable {
    case new(parent: String?, income: Bool)
    case edit(UUID)

    var id: String {
        switch self {
        case .new(let parent, let income): "new-\(parent ?? "root")-\(income)"
        case .edit(let id): id.uuidString
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
    @State private var isEssential = false
    @State private var confirmDelete = false
    @State private var loaded = false

    static let palette = [0x1E3FAE, 0x2BB673, 0xF08A24, 0xF05252, 0x8B5CF6, 0x0EA5A4, 0xEC4899, 0xE9A23B, 0x0EA5E9, 0x6B7385]

    private var existing: CustomCategory? {
        if case .edit(let id) = target { return custom.first { $0.id == id } }
        return nil
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
                        TextField(parentKey.isEmpty ? "Category name" : "Sub-category name", text: $name)
                            .font(.title3.weight(.semibold))
                            .textInputAutocapitalization(.words)
                    }
                    .padding(.vertical, 4)
                }

                Section("Emoji") {
                    EmojiPicker(emoji: $emoji, suggestions: EmojiPicker.categorySuggestions)
                }

                Section {
                    Picker("Belongs to", selection: $parentKey) {
                        Text("Nothing (main category)").tag("")
                        ForEach(parentOptions) { Text($0.menuTitle).tag($0.rawValue) }
                    }
                    .disabled(existing.map { !children(of: $0.key).isEmpty } ?? false)
                    if parentKey.isEmpty {
                        if existing == nil {
                            Picker("Type", selection: $isIncome) {
                                Text("Expense").tag(false)
                                Text("Income").tag(true)
                            }
                            .pickerStyle(.segmented)
                        }
                        if !isIncome {
                            Toggle("Essential spending", isOn: $isEssential)
                        }
                    }
                } footer: {
                    Text(parentKey.isEmpty
                         ? (isEssential ? "Essential budgets are protected in Safe to Spend." : "Main categories can have their own budgets.")
                         : "Sub-category spending counts toward its main category's budget.")
                }

                if parentKey.isEmpty {
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
                }

                if existing != nil {
                    Section {
                        Button("Delete category", role: .destructive) { confirmDelete = true }
                    }
                }
            }
            .navigationTitle(existing == nil ? (parentKey.isEmpty ? "New category" : "New sub-category") : "Edit category")
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
                Text("Its transactions move to \(parentKey.isEmpty ? "Other" : "the main category"), and its sub-categories are removed.")
            }
            .onAppear(perform: load)
        }
    }

    private var preview: some View {
        let color = parentKey.isEmpty ? Color(hex: UInt32(colorHex)) : SpendCategory.unchecked(parentKey).color
        return Group {
            if emoji.isEmpty {
                IconBadge(symbol: parentKey.isEmpty ? "tag.fill" : SpendCategory.unchecked(parentKey).symbol, color: color, size: 52)
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
        case .new(let parent, let income):
            parentKey = parent ?? ""
            isIncome = income
        case .edit:
            guard let c = existing else { return }
            name = c.name
            emoji = c.emoji
            colorHex = c.colorHex
            parentKey = c.parentKey
            isIncome = c.isIncome
            isEssential = c.isEssential
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
            model.isEssential = isEssential
        } else {
            let parentIncome = parentKey.isEmpty ? isIncome : SpendCategory.unchecked(parentKey).isIncomeCategory
            model = CustomCategory(name: trimmed, emoji: emoji, colorHex: colorHex, parentKey: parentKey,
                                   isIncome: parentIncome, isEssential: isEssential)
            context.insert(model)
        }
        try? context.save()
        CategoryRegistry.shared.reload(context: context)
        if existing == nil { onCreate?(SpendCategory.unchecked(model.key)) }
        dismiss()
    }

    private func delete() {
        guard let c = existing else { return }
        let key = c.key
        let fallback = c.parentKey.isEmpty ? (c.isIncome ? SpendCategory.income.rawValue : SpendCategory.other.rawValue) : c.parentKey
        let subKeys = Set(children(of: key).map(\.key))
        let txs = (try? context.fetch(FetchDescriptor<MoneyTransaction>())) ?? []
        for tx in txs {
            if tx.categoryRaw == key { tx.categoryRaw = fallback; tx.subcategoryKey = "" }
            if tx.subcategoryKey == key || subKeys.contains(tx.subcategoryKey) { tx.subcategoryKey = "" }
        }
        let budgets = (try? context.fetch(FetchDescriptor<Budget>())) ?? []
        for b in budgets where b.categoryRaw == key { context.delete(b) }
        let bills = (try? context.fetch(FetchDescriptor<Bill>())) ?? []
        for b in bills where b.categoryRaw == key { b.categoryRaw = SpendCategory.bills.rawValue }
        for child in children(of: key) { context.delete(child) }
        context.delete(c)
        try? context.save()
        CategoryRegistry.shared.reload(context: context)
        dismiss()
    }
}

/// Grid of top-level categories with a "New" tile, plus sub-category chips for the selection.
struct CategoryPickerGrid: View {
    @Binding var category: SpendCategory
    @Binding var subcategory: SpendCategory?
    var income: Bool
    var onPick: () -> Void = {}
    @State private var editorTarget: CategoryEditorTarget?

    var body: some View {
        let registry = CategoryRegistry.shared
        let options = income ? SpendCategory.incomeCases : SpendCategory.expenseCases.filter { $0 != .transfers }
        VStack(alignment: .leading, spacing: 14) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 12) {
                ForEach(options) { c in
                    Button {
                        if category != c { subcategory = nil }
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

            let subs = category.subcategories
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(subs) { sub in
                        Button {
                            subcategory = subcategory == sub ? nil : sub
                        } label: {
                            Text(sub.emoji.isEmpty ? sub.title : "\(sub.emoji) \(sub.title)")
                                .font(.subheadline.weight(.medium))
                                .padding(.horizontal, 12).padding(.vertical, 7)
                                .foregroundStyle(subcategory == sub ? .white : Theme.ink)
                                .background(subcategory == sub ? category.color : Theme.track.opacity(0.8), in: Capsule())
                        }
                        .buttonStyle(PressableStyle())
                    }
                    Button { editorTarget = .new(parent: category.rawValue, income: income) } label: {
                        Label(subs.isEmpty ? "Add sub-category to \(category.shortTitle)" : "Add", systemImage: "plus")
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .foregroundStyle(Theme.cobalt)
                            .background(Theme.cobaltSoft, in: Capsule())
                    }
                    .buttonStyle(PressableStyle())
                }
            }
        }
        .id(registry.order)
        .padding(.vertical, 6)
        .sensoryFeedback(.selection, trigger: category)
        .sheet(item: $editorTarget) { target in
            CategoryEditor(target: target) { created in
                if created.isSubcategory {
                    subcategory = created
                } else {
                    category = created
                    subcategory = nil
                }
                onPick()
            }
        }
    }
}
