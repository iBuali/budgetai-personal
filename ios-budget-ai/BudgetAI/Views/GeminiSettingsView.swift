import SwiftUI

struct GeminiSettingsView: View {
    @AppStorage(Keys.geminiModel) private var model = GeminiClient.defaultModel
    @State private var key = ""
    @State private var hasUserKey = GeminiAccount.userKey != nil
    @State private var testing = false
    @State private var status: (ok: Bool, text: String)?

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    IconBadge(symbol: "sparkles", color: Theme.cobalt, size: 48)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(GeminiAccount.isConfigured ? "Gemini connected" : "Connect Google Gemini")
                            .font(.headline).foregroundStyle(Theme.ink)
                        Text(hasUserKey ? "Using your API key from this iPhone's Keychain."
                             : (GeminiAccount.bundledKey != nil ? "Using the key built into the app." : "Paste an API key from your Google account."))
                            .font(.subheadline).foregroundStyle(Theme.secondaryInk)
                    }
                }
                .padding(.vertical, 4)
            }

            Section {
                SecureField(hasUserKey ? "Replace API key" : "Paste Gemini API key", text: $key)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .fontDesign(.monospaced)
                Button {
                    Task { await saveAndTest() }
                } label: {
                    HStack {
                        Text(key.isEmpty ? "Test connection" : "Save & test")
                        Spacer()
                        if testing { ProgressView() }
                    }
                }
                .disabled(testing || (key.isEmpty && !GeminiAccount.isConfigured))
                if let status {
                    Label(status.text, systemImage: status.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .font(.subheadline)
                        .foregroundStyle(status.ok ? Theme.positive : Theme.negative)
                }
            } header: {
                Text("API key")
            } footer: {
                Link(destination: URL(string: "https://aistudio.google.com/apikey")!) {
                    Label("Get a free key in Google AI Studio", systemImage: "arrow.up.right.square")
                        .font(.footnote.weight(.medium))
                }
                .padding(.top, 4)
            }

            Section {
                Picker("Model", selection: $model) {
                    ForEach(GeminiClient.models, id: \.self) { Text($0).tag($0) }
                }
            } header: {
                Text("Model")
            } footer: {
                Text("If a model isn't available on your key, Budget AI automatically falls back to the next one.")
            }

            Section("What AI does here") {
                Label("Reads bank SMS alerts into transactions", systemImage: "message.fill")
                Label("Categorizes merchants automatically", systemImage: "tag.fill")
                Label("Finds savings and forecasts your month", systemImage: "chart.line.uptrend.xyaxis")
                Label("Powers the financial advisor chat", systemImage: "bubble.left.and.text.bubble.right.fill")
            }
            .foregroundStyle(Theme.ink)

            if hasUserKey {
                Section {
                    Button("Remove API key", role: .destructive) {
                        GeminiAccount.save("")
                        hasUserKey = false
                        status = nil
                    }
                }
            }

            Section {
            } footer: {
                Text("Your key is stored in the iPhone Keychain. Only the data needed for a request (like an SMS or a spending summary) is sent to Google Gemini under your account. Your full data stays on this iPhone.")
            }
        }
        .scrollContentBackground(.hidden)
        .canvasBackground()
        .navigationTitle("Gemini AI")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
    }

    private func saveAndTest() async {
        let candidate = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let testKey = candidate.isEmpty ? GeminiAccount.apiKey : candidate else { return }
        testing = true
        status = nil
        defer { testing = false }
        do {
            try await AIService.testConnection(key: testKey, model: model)
            if !candidate.isEmpty {
                GeminiAccount.save(candidate)
                hasUserKey = true
                key = ""
            }
            UserDefaults.standard.removeObject(forKey: "aiFindingsDate")
            status = (true, "Connected. AI features are on.")
        } catch {
            status = (false, error.localizedDescription)
        }
    }
}
