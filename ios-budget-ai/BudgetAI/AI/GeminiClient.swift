import Foundation
import Security

enum GeminiError: LocalizedError {
    case notConfigured
    case http(Int, String)
    case empty
    case badJSON

    var errorDescription: String? {
        switch self {
        case .notConfigured: "Add your Gemini API key in Profile → Gemini AI."
        case .http(let code, let message):
            code == 400 || code == 403 ? "Gemini rejected the request: \(message)" : "Gemini error \(code): \(message)"
        case .empty: "Gemini returned an empty answer. Please try again."
        case .badJSON: "Gemini's answer couldn't be read. Please try again."
        }
    }
}

struct GeminiTurn {
    let isUser: Bool
    let text: String
}

/// Talks directly to the user's own Google Gemini account.
struct GeminiClient {
    static let models = ["gemini-3.8-flash", "gemini-3.6-flash", "gemini-3.5-flash-lite", "gemini-2.5-flash"]
    static let defaultModel = "gemini-3.8-flash"

    let apiKey: String
    let model: String

    func generate(system: String?, turns: [GeminiTurn], schema: [String: Any]? = nil, temperature: Double = 0.4) async throws -> String {
        // Try the chosen model, then fall back to other current models if it's unavailable to this key.
        var candidates = [model] + Self.models.filter { $0 != model }
        var lastError: Error = GeminiError.empty
        while !candidates.isEmpty {
            let current = candidates.removeFirst()
            do {
                return try await request(model: current, system: system, turns: turns, schema: schema, temperature: temperature)
            } catch GeminiError.http(let code, let message) where code == 404 || (code == 400 && message.lowercased().contains("model")) {
                lastError = GeminiError.http(code, message)
                continue
            }
        }
        throw lastError
    }

    private func request(model: String, system: String?, turns: [GeminiTurn], schema: [String: Any]?, temperature: Double) async throws -> String {
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent") else {
            throw GeminiError.empty
        }
        var body: [String: Any] = [
            "contents": turns.map { ["role": $0.isUser ? "user" : "model", "parts": [["text": $0.text]]] },
        ]
        if let system { body["systemInstruction"] = ["parts": [["text": system]]] }
        var config: [String: Any] = ["temperature": temperature]
        if let schema {
            config["responseMimeType"] = "application/json"
            config["responseSchema"] = schema
        }
        body["generationConfig"] = config

        var req = URLRequest(url: url, timeoutInterval: 45)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (200..<300).contains(status) else {
            let message = ((json?["error"] as? [String: Any])?["message"] as? String) ?? "Request failed"
            throw GeminiError.http(status, message)
        }
        let candidates = json?["candidates"] as? [[String: Any]]
        let parts = ((candidates?.first?["content"] as? [String: Any])?["parts"] as? [[String: Any]]) ?? []
        let text = parts.filter { ($0["thought"] as? Bool) != true }.compactMap { $0["text"] as? String }.joined()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw GeminiError.empty }
        return text
    }

    static func decodeObject(_ text: String) throws -> [String: Any] {
        guard let data = cleaned(text).data(using: .utf8),
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw GeminiError.badJSON }
        return obj
    }

    private static func cleaned(_ text: String) -> String {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("```") {
            t = t.replacingOccurrences(of: "```json", with: "").replacingOccurrences(of: "```", with: "")
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Key storage

enum KeychainStore {
    private static let service = "app.budgetai.gemini"

    static func set(_ value: String, for account: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service,
                                   kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(_ account: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

enum GeminiAccount {
    private static let keyName = "gemini_api_key"

    static var userKey: String? {
        guard let k = KeychainStore.get(keyName), !k.isEmpty else { return nil }
        return k
    }

    static var bundledKey: String? {
        if let k = Config.allValues["GEMINI_API_KEY"], !k.isEmpty { return k }
        if let k = Config.allValues["EXPO_PUBLIC_GEMINI_API_KEY"], !k.isEmpty { return k }
        return nil
    }

    static var apiKey: String? { userKey ?? bundledKey }
    static var isConfigured: Bool { apiKey != nil }

    static func save(_ key: String) {
        KeychainStore.set(key.trimmingCharacters(in: .whitespacesAndNewlines), for: keyName)
    }

    static var model: String {
        UserDefaults.standard.string(forKey: Keys.geminiModel) ?? GeminiClient.defaultModel
    }

    static func client() throws -> GeminiClient {
        guard let key = apiKey else { throw GeminiError.notConfigured }
        return GeminiClient(apiKey: key, model: model)
    }
}
