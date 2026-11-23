import SwiftUI
import SwiftData

// MARK: - Transaction Detail Card (Isolated Overlay UI)

/// Displays contextual shared-expense suggestions, active adjustment audit info, and
/// one-tap reversal inside `TransactionDetailView`. Renders nothing when the feature is disabled.
struct SharedExpenseTransactionSection: View {
    let tx: MoneyTransaction

    @Environment(\.modelContext) private var context
    @Environment(AppState.self) private var appState
    @AppStorage(Keys.currency) private var currency = "BHD"
    @AppStorage(Keys.sharedExpenseIntelligenceEnabled) private var enabled = true

    private let adjustmentStore = SharedExpenseAdjustmentStore.shared
    private let memoryStore = SharedExpenseMemoryStore.shared

    @State private var showReverseConfirm = false
    @State private var reverseTargetID: UUID?

    var body: some View {
        if enabled {
            let activeExpenseAdj = adjustmentStore.activeAdjustment(forExpenseID: tx.id)
            let linkedReimbAdjs = adjustmentStore.activeAdjustments(forReimbursementID: tx.id)
            let pendingSug = adjustmentStore.pendingSuggestion(forTransactionID: tx.id)

            if let adj = activeExpenseAdj {
                activeAdjustmentSection(adj)
            } else if !linkedReimbAdjs.isEmpty {
                reimbursementLinksSection(linkedReimbAdjs)
            } else if let suggestion = pendingSug {
                suggestionSection(suggestion)
            }
        }
    }

    // MARK: Suggestion Card (Medium / Low Confidence)

    private func suggestionSection(_ suggestion: SharedExpenseSuggestion) -> some View {
        let suggestedCat = SpendCategory.resolve(suggestion.suggestedCategoryRaw)
        return Section {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(Theme.cobalt.opacity(0.16))
                            .frame(width: 42, height: 42)
                        Image(systemName: "person.2.wave.2.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(Theme.cobalt)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text("Possible Shared Expense")
                                .font(.headline)
                                .foregroundStyle(Theme.ink)
                            Text("\(Int((suggestion.confidence * 100).rounded()))%")
                                .font(.caption2.weight(.bold).monospacedDigit())
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Theme.cobalt.opacity(0.14), in: Capsule())
                                .foregroundStyle(Theme.cobalt)
                        }
                        Text(suggestion.promptMessage)
                            .font(.caption)
                            .foregroundStyle(Theme.secondaryInk)
                    }
                }

                VStack(spacing: 6) {
                    infoRow("Suggested Category", value: suggestedCat.title)
                    infoRow("Original Amount", value: Money.format(suggestion.originalExpenseAmount, currency))
                    infoRow("Estimated Personal Share", value: Money.format(suggestion.suggestedPersonalAmount, currency))
                    infoRow("Estimated Reimbursable", value: Money.format(suggestion.suggestedReimbursableAmount, currency), valueColor: Theme.positive)
                    if let reimb = suggestion.potentialReimbursementAmount {
                        infoRow("Potential Reimbursement", value: Money.format(reimb, currency), valueColor: Theme.positive)
                    }
                    infoRow("Expected Budget Impact", value: Money.format(suggestion.expectedBudgetImpact, currency, signed: true), valueColor: Theme.cobalt)
                }
                .padding(10)
                .background(Theme.track.opacity(0.45), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                VStack(spacing: 8) {
                    Button {
                        let all = (try? context.fetch(FetchDescriptor<MoneyTransaction>())) ?? []
                        let result = SharedExpenseIntelligenceService.shared.confirmSuggestion(
                            suggestion,
                            allTransactions: all,
                            currency: currency
                        )
                        switch result {
                        case .success(let adj):
                            appState.show("Adjusted personal spend to \(Money.format(adj.personalAmount, currency))")
                        case .failure:
                            appState.show("Could not validate reimbursement split")
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill")
                            Text("Confirm Shared Expense")
                                .font(.subheadline.weight(.semibold))
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Theme.cobalt, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)

                    Button(role: .destructive) {
                        let all = (try? context.fetch(FetchDescriptor<MoneyTransaction>())) ?? []
                        let expenseTx = all.first(where: { $0.id == suggestion.expenseTransactionID })
                        SharedExpenseIntelligenceService.shared.rejectSuggestion(suggestion, expenseTransaction: expenseTx)
                        appState.show("Kept as personal expense · FALAK will remember")
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "xmark.circle")
                            Text("Not Shared (Keep Personal)")
                                .font(.subheadline.weight(.medium))
                        }
                        .foregroundStyle(Theme.negative)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Theme.negative.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 4)
        } header: {
            Text("Shared Expense Intelligence")
        } footer: {
            Text("Original bank transaction stays unchanged. Budget impact is applied through a reversible adjustment layer.")
        }
    }

    // MARK: Active Adjustment Audit & Reversal Card

    private func activeAdjustmentSection(_ adj: SharedExpenseAdjustment) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    IconBadge(symbol: "person.2.fill", color: Theme.positive, size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Shared Expense Adjusted")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.ink)
                        Text("\(adj.confirmationSource.title) · \(Int((adj.aiConfidence * 100).rounded()))% confidence")
                            .font(.caption)
                            .foregroundStyle(Theme.secondaryInk)
                    }
                    Spacer()
                }

                VStack(spacing: 6) {
                    infoRow("Original Bank Amount", value: Money.format(adj.originalExpenseAmount, currency))
                    infoRow("Your Personal Spend", value: Money.format(adj.personalAmount, currency))
                    infoRow("Reimbursable Portion", value: Money.format(adj.reimbursableAmount, currency), valueColor: Theme.positive)
                    infoRow("Reimbursed So Far", value: Money.format(adj.totalReceivedReimbursementAmount, currency))
                    infoRow("Outstanding Reimbursement", value: Money.format(adj.outstandingReimbursementAmount, currency),
                            valueColor: adj.outstandingReimbursementAmount > 0.0005 ? Theme.warning : Theme.positive)
                    if let catRaw = adj.effectiveCategoryRaw {
                        infoRow("Budget Category", value: SpendCategory.resolve(catRaw).title)
                    }
                    infoRow("Linked Reimbursements", value: "\(adj.reimbursementAllocations.count)")
                }
                .padding(10)
                .background(Theme.track.opacity(0.45), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                if !adj.explanation.isEmpty {
                    Text(adj.explanation)
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryInk)
                }

                Button(role: .destructive) {
                    reverseTargetID = adj.id
                    showReverseConfirm = true
                } label: {
                    Label("Reverse Shared Adjustment", systemImage: "arrow.uturn.backward.circle")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Theme.negative)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Theme.negative.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            .padding(.vertical, 4)
            .confirmationDialog("Reverse shared expense adjustment?", isPresented: $showReverseConfirm, titleVisibility: .visible) {
                Button("Reverse & Restore Budget", role: .destructive) {
                    if let id = reverseTargetID {
                        _ = SharedExpenseIntelligenceService.shared.reverseAdjustment(id: id)
                        appState.show("Shared adjustment reversed · Original budget restored")
                    }
                }
            } message: {
                Text("This restores the full expense amount to your personal budget and updates shared expense learning memory. Your original bank transaction is untouched.")
            }
        } header: {
            Text("Shared Expense Intelligence")
        }
    }

    // MARK: Incoming Reimbursement Links Card

    private func reimbursementLinksSection(_ adjs: [SharedExpenseAdjustment]) -> some View {
        let totalAllocated = adjs
            .flatMap(\.reimbursementAllocations)
            .filter { $0.reimbursementTransactionID == tx.id }
            .reduce(0.0) { $0 + $1.allocatedAmount }
        return Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    IconBadge(symbol: "arrow.uturn.left.circle.fill", color: Theme.positive, size: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Linked as Reimbursement")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.ink)
                        Text("Excluded from new income · \(Money.format(totalAllocated, currency)) allocated across \(adjs.count) expense(s).")
                            .font(.caption)
                            .foregroundStyle(Theme.secondaryInk)
                    }
                }
                ForEach(adjs) { adj in
                    let alloc = adj.reimbursementAllocations
                        .filter { $0.reimbursementTransactionID == tx.id }
                        .reduce(0.0) { $0 + $1.allocatedAmount }
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(SpendCategory.resolve(adj.effectiveCategoryRaw).title)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Theme.ink)
                            Text("Allocated \(Money.format(alloc, currency)) · \(adj.confirmationSource.title)")
                                .font(.caption2)
                                .foregroundStyle(Theme.secondaryInk)
                        }
                        Spacer()
                        Button("Reverse") {
                            _ = SharedExpenseIntelligenceService.shared.reverseAdjustment(id: adj.id)
                            appState.show("Reimbursement link reversed")
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.negative)
                        .buttonStyle(.plain)
                    }
                    .padding(8)
                    .background(Theme.track.opacity(0.45), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
            .padding(.vertical, 4)
        } header: {
            Text("Shared Expense Intelligence")
        }
    }

    private func infoRow(_ label: String, value: String, valueColor: Color = Theme.ink) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(Theme.secondaryInk)
            Spacer()
            Text(value)
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(valueColor)
        }
    }
}

// MARK: - Settings Hub View (Review, Audit & Learning Memory)

struct SharedExpenseCenterView: View {
    @Environment(\.modelContext) private var context
    @Environment(AppState.self) private var appState
    @Query(sort: \MoneyTransaction.date, order: .reverse) private var transactions: [MoneyTransaction]
    @AppStorage(Keys.currency) private var currency = "BHD"
    @AppStorage(Keys.sharedExpenseIntelligenceEnabled) private var enabled = true

    private let adjustmentStore = SharedExpenseAdjustmentStore.shared
    private let memoryStore = SharedExpenseMemoryStore.shared

    @State private var confirmClearMemory = false

    var body: some View {
        List {
            Section {
                Toggle(isOn: $enabled) {
                    HStack(spacing: 12) {
                        IconBadge(symbol: "person.2.wave.2.fill", color: Theme.cobalt, size: 32)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("AI Shared Expense Intelligence")
                                .foregroundStyle(Theme.ink)
                            Text("Detect shared bills & reimbursements safely")
                                .font(.caption)
                                .foregroundStyle(Theme.secondaryInk)
                        }
                    }
                }
                .onChange(of: enabled) { _, newValue in
                    Ledger.notifyDataChanged()
                    appState.show(newValue ? "Shared Expense Intelligence enabled" : "Shared Expense Intelligence disabled")
                }
            } footer: {
                Text("When disabled, all budgets, spending totals, and transactions behave identically to standard FALAK with zero adjustments applied.")
            }

            if enabled {
                Section("Pending Suggestions (\(adjustmentStore.pendingSuggestions.count))") {
                    if adjustmentStore.pendingSuggestions.isEmpty {
                        Text("No uncertain shared expenses waiting for review.")
                            .font(.subheadline)
                            .foregroundStyle(Theme.secondaryInk)
                    } else {
                        ForEach(adjustmentStore.pendingSuggestions) { suggestion in
                            let tx = transactions.first(where: { $0.id == suggestion.expenseTransactionID })
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text(tx?.merchant ?? "Shared Expense")
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(Theme.ink)
                                    Spacer()
                                    Text("\(Int((suggestion.confidence * 100).rounded()))%")
                                        .font(.caption.weight(.bold).monospacedDigit())
                                        .foregroundStyle(Theme.cobalt)
                                }
                                Text(suggestion.promptMessage)
                                    .font(.caption)
                                    .foregroundStyle(Theme.secondaryInk)
                                HStack(spacing: 10) {
                                    Button("Confirm") {
                                        let res = SharedExpenseIntelligenceService.shared.confirmSuggestion(
                                            suggestion,
                                            allTransactions: transactions,
                                            currency: currency
                                        )
                                        if case .success = res {
                                            appState.show("Confirmed shared expense")
                                        }
                                    }
                                    .font(.caption.weight(.semibold))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(Theme.cobalt, in: Capsule())
                                    .foregroundStyle(.white)
                                    .buttonStyle(.plain)

                                    Button("Reject") {
                                        SharedExpenseIntelligenceService.shared.rejectSuggestion(suggestion, expenseTransaction: tx)
                                        appState.show("Suggestion rejected")
                                    }
                                    .font(.caption.weight(.semibold))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(Theme.negative.opacity(0.12), in: Capsule())
                                    .foregroundStyle(Theme.negative)
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }

                Section("Active Adjustments (\(adjustmentStore.activeAdjustments.count))") {
                    if adjustmentStore.activeAdjustments.isEmpty {
                        Text("No active shared expense budget adjustments.")
                            .font(.subheadline)
                            .foregroundStyle(Theme.secondaryInk)
                    } else {
                        ForEach(adjustmentStore.activeAdjustments) { adj in
                            let tx = transactions.first(where: { $0.id == adj.originalTransactionID })
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(tx?.merchant ?? "Expense")
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(Theme.ink)
                                    Spacer()
                                    Text(adj.confirmationSource.title)
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(Theme.positive)
                                }
                                Text("Personal \(Money.format(adj.personalAmount, currency)) · Reimbursable \(Money.format(adj.reimbursableAmount, currency)) · Outstanding \(Money.format(adj.outstandingReimbursementAmount, currency))")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(Theme.secondaryInk)
                                Button(role: .destructive) {
                                    _ = SharedExpenseIntelligenceService.shared.reverseAdjustment(id: adj.id)
                                    appState.show("Adjustment reversed")
                                } label: {
                                    Label("Reverse Adjustment", systemImage: "arrow.uturn.backward")
                                        .font(.caption.weight(.semibold))
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }

                Section {
                    HStack {
                        Text("Learned Patterns")
                            .foregroundStyle(Theme.ink)
                        Spacer()
                        Text("\(memoryStore.activeRecords.count)")
                            .foregroundStyle(Theme.secondaryInk)
                    }
                    if !memoryStore.activeRecords.isEmpty {
                        Button(role: .destructive) {
                            confirmClearMemory = true
                        } label: {
                            Label("Clear Shared Expense Memory", systemImage: "trash")
                        }
                    }
                } header: {
                    Text("Dedicated Learning Memory")
                } footer: {
                    Text("Stored separately from Transaction Rules. Clearing this memory never affects your existing rules or bank transactions.")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .canvasBackground()
        .navigationTitle("Shared Expenses")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Clear shared expense learning memory?", isPresented: $confirmClearMemory, titleVisibility: .visible) {
            Button("Clear Memory", role: .destructive) {
                memoryStore.clearAll()
                appState.show("Shared expense memory cleared")
            }
        } message: {
            Text("Transaction Rules and your bank transactions will remain untouched.")
        }
    }
}
