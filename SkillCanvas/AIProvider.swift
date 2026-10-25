import SwiftUI
import Foundation
import Security

// Universal OpenAI-compatible provider: Name, Provider preset, Endpoint, Key, Model ID.
struct AIProvider: Identifiable, Codable, Equatable {
    var id = UUID()
    var name = ""
    var preset = ProviderPreset.custom.rawValue
    var endpoint = ""
    var modelID = ""
    var hasKey = false

    var normalizedBase: String {
        var b = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        while b.hasSuffix("/") { b.removeLast() }
        if b.hasSuffix("/chat/completions") { b = String(b.dropLast("/chat/completions".count)) }
        while b.hasSuffix("/") { b.removeLast() }
        return b
    }
    var chatURL: URL? { URL(string: normalizedBase + "/chat/completions") }
    var modelsURL: URL? { URL(string: normalizedBase + "/models") }

    func validate() -> String? {
        if name.trimmingCharacters(in: .whitespaces).isEmpty { return "Give this connection a name." }
        guard !normalizedBase.isEmpty, URL(string: normalizedBase)?.scheme?.hasPrefix("http") == true else { return "Endpoint URL must start with http:// or https://" }
        guard !modelID.trimmingCharacters(in: .whitespaces).isEmpty else { return "Enter a Model ID." }
        return nil
    }
}

enum ProviderPreset: String, CaseIterable, Identifiable {
    case openai = "OpenAI", openrouter = "OpenRouter", groq = "Groq", together = "Together"
    case mistral = "Mistral", deepseek = "DeepSeek", ollama = "Ollama", lmstudio = "LM Studio"
    case custom = "Custom"
    var id: String { rawValue }
    var endpoint: String {
        switch self {
        case .openai: "https://api.openai.com/v1"
        case .openrouter: "https://openrouter.ai/api/v1"
        case .groq: "https://api.groq.com/openai/v1"
        case .together: "https://api.together.xyz/v1"
        case .mistral: "https://api.mistral.ai/v1"
        case .deepseek: "https://api.deepseek.com/v1"
        case .ollama: "http://localhost:11434/v1"
        case .lmstudio: "http://localhost:1234/v1"
        case .custom: ""
        }
    }
    var modelHint: String {
        switch self {
        case .openai: "gpt-4o-mini"
        case .openrouter: "openai/gpt-4o-mini"
        case .groq: "llama-3.3-70b-versatile"
        case .together: "meta-llama/Llama-3.3-70B-Instruct-Turbo"
        case .mistral: "mistral-small-latest"
        case .deepseek: "deepseek-chat"
        case .ollama: "llama3.2"
        case .lmstudio: "local-model"
        case .custom: ""
        }
    }
    var needsKey: Bool { self != .ollama && self != .lmstudio }
}

enum Keychain {
    private static let service = "SkillCanvas.providers"

    static func set(_ secret: String, account: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service,
                                   kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        guard !secret.isEmpty else { return }
        var attrs = base
        attrs[kSecValueData as String] = Data(secret.utf8)
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(attrs as CFDictionary, nil)
    }
    static func get(account: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func delete(account: String) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                       kSecAttrService as String: service,
                       kSecAttrAccount as String: account] as CFDictionary)
    }
}

enum AIError: LocalizedError {
    case badEndpoint, noKey, server(Int, String), notConnected
    var errorDescription: String? {
        switch self {
        case .badEndpoint: "That endpoint URL is not valid."
        case .noKey: "This provider needs an API key."
        case .server(let code, let msg): "Server replied \(code): \(msg)"
        case .notConnected: "No provider connected. Open ⚙️ and create one."
        }
    }
}

// Minimal OpenAI-compatible HTTP client shared by the connection test, model listing and chat.
enum AIHttp {
    static func request(_ url: URL, provider: AIProvider, body: [String: Any]?) async throws -> Data {
        var req = URLRequest(url: url)
        if body != nil {
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if provider.hasKey, let key = Keychain.get(account: provider.id.uuidString), !key.isEmpty {
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        if let body { req.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw AIError.server(http.statusCode, Self.message(from: data) ?? String(data: data.prefix(300), encoding: .utf8) ?? "unknown error")
        }
        return data
    }

    static func message(from data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let err = obj["error"] as? [String: Any], let m = err["message"] as? String { return m }
        if let m = obj["message"] as? String { return m }
        return nil
    }

    // Liveness check used by the Create button.
    static func test(_ provider: AIProvider) async throws {
        guard let url = provider.chatURL else { throw AIError.badEndpoint }
        if ProviderPreset(rawValue: provider.preset)?.needsKey == true && !provider.hasKey { throw AIError.noKey }
        let body: [String: Any] = ["model": provider.modelID,
                                   "messages": [["role": "user", "content": "Reply with the single word: ok"]],
                                   "max_tokens": 8,
                                   "temperature": 0]
        _ = try await request(url, provider: provider, body: body)
    }

    static func listModels(_ provider: AIProvider) async throws -> [String] {
        guard let url = provider.modelsURL else { throw AIError.badEndpoint }
        let data = try await request(url, provider: provider, body: nil)
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = obj["data"] as? [[String: Any]] else { return [] }
        return items.compactMap { $0["id"] as? String }.sorted()
    }
}
