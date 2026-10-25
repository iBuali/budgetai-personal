import SwiftUI
import SwiftData

struct AdvisorChatView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \ChatMessage.date) private var messages: [ChatMessage]
    @Query(sort: \MoneyTransaction.date, order: .reverse) private var transactions: [MoneyTransaction]
    @Query private var accounts: [Account]
    @Query private var budgets: [Budget]
    @Query private var goals: [SavingsGoal]
    @Query private var bills: [Bill]
    @AppStorage(Keys.currency) private var currency = "BHD"
    @State private var draft = ""
    @State private var thinking = false
    @State private var confirmClear = false
    @FocusState private var focused: Bool

    private var suggestions: [String] {
        let sym = Money.symbol(currency)
        return [
            "How can I save \(sym) 100 this month?",
            "Forecast my month-end balance",
            "Which expenses should I cut?",
            "Am I on track with my goals?",
            "Should I pay off debt or save first?",
        ]
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    intro
                    ForEach(messages) { message in
                        MessageBubble(message: message).id(message.id)
                    }
                    if thinking {
                        HStack(spacing: 8) {
                            Image(systemName: "sparkles").foregroundStyle(Theme.cobalt).symbolEffect(.pulse)
                            Text("Analyzing your finances…").font(.subheadline).foregroundStyle(Theme.secondaryInk)
                        }
                        .padding(.horizontal, 4)
                        .id("thinking")
                    }
                }
                .padding(16)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: messages.count) { _, _ in
                withAnimation { proxy.scrollTo(messages.last?.id, anchor: .bottom) }
            }
            .onChange(of: thinking) { _, v in
                if v { withAnimation { proxy.scrollTo("thinking", anchor: .bottom) } }
            }
            .onAppear { proxy.scrollTo(messages.last?.id, anchor: .bottom) }
        }
        .canvasBackground()
        .safeAreaInset(edge: .bottom) { composer }
        .navigationTitle("AI Advisor")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            if !messages.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Clear", systemImage: "trash") { confirmClear = true }
                }
            }
        }
        .confirmationDialog("Clear conversation?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear", role: .destructive) {
                for m in messages { context.delete(m) }
                try? context.save()
            }
        }
    }

    @ViewBuilder
    private var intro: some View {
        if messages.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                IconBadge(symbol: "sparkles", color: Theme.cobalt, size: 52)
                Text("Your personal money advisor").font(.title2.bold()).foregroundStyle(Theme.ink)
                Text("I look at your spending, bills, budgets, assets and debts to give you advice that fits your real numbers.")
                    .foregroundStyle(Theme.secondaryInk)
                if !GeminiAccount.isConfigured {
                    GeminiConnectCard()
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(suggestions, id: \.self) { s in
                            Button { send(s) } label: {
                                Text(s)
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(Theme.cobalt)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 10)
                                    .background(Theme.surface, in: Capsule())
                                    .overlay(Capsule().stroke(Theme.cobalt.opacity(0.2)))
                            }
                            .buttonStyle(PressableStyle())
                        }
                    }
                }
            }
            .padding(.top, 8)
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Ask about your money…", text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .focused($focused)
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Theme.track))
                .submitLabel(.send)
                .onSubmit { send(draft) }
            Button { send(draft) } label: {
                Image(systemName: "arrow.up")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .background(canSend ? Theme.cobalt : Theme.secondaryInk.opacity(0.35), in: Circle())
            }
            .disabled(!canSend)
            .accessibilityLabel("Send")
            .sensoryFeedback(.impact(weight: .light), trigger: messages.count)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !thinking && GeminiAccount.isConfigured
    }

    private func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !thinking else { return }
        draft = ""
        context.insert(ChatMessage(isUser: true, text: trimmed))
        try? context.save()
        thinking = true
        let finance = Finance(transactions: transactions, accounts: accounts, budgets: budgets, goals: goals, bills: bills)
        let ctx = AIService.financialContext(finance, transactions: transactions)
        Task {
            do {
                let history = (try? context.fetch(FetchDescriptor<ChatMessage>(sortBy: [SortDescriptor(\.date)]))) ?? []
                let reply = try await AIService.advisorReply(history: history, context: ctx)
                context.insert(ChatMessage(isUser: false, text: reply.trimmingCharacters(in: .whitespacesAndNewlines)))
            } catch {
                context.insert(ChatMessage(isUser: false, text: error.localizedDescription, isError: true))
            }
            try? context.save()
            thinking = false
        }
    }
}

struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            if message.isUser { Spacer(minLength: 48) }
            Text(attributed)
                .font(.body)
                .foregroundStyle(message.isUser ? .white : (message.isError ? Theme.negative : Theme.ink))
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(message.isUser ? Theme.cobalt : Theme.surface,
                            in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .shadow(color: Theme.ink.opacity(message.isUser ? 0 : 0.04), radius: 8, y: 2)
                .textSelection(.enabled)
            if !message.isUser { Spacer(minLength: 32) }
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var attributed: AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: message.text, options: options)) ?? AttributedString(message.text)
    }
}
