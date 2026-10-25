import SwiftUI
import Foundation

struct ChatMessage: Identifiable, Codable, Equatable {
    enum Role: String, Codable { case user, assistant, tool, system }
    var id = UUID()
    var role: Role
    var text: String
    var toolName: String?
    var toolSummary: String?
    var toolID: String?
    var toolCallsJSON: String?
    var isError = false
    var date = Date()
}

struct Conversation: Identifiable, Codable, Equatable {
    var id = UUID()
    var title = "New chat"
    var messages: [ChatMessage] = []
    var date = Date()
}

struct ToolCall: Identifiable, Equatable {
    var id: String
    var name: String
    var arguments: String
}

struct ToolResult: Equatable {
    var output: String
    var summary: String
}

@MainActor final class AIModel: ObservableObject {
    // Connection state
    @Published var providers: [AIProvider] = []
    @Published var activeID: UUID?
    // Chat state
    @Published var messages: [ChatMessage] = []
    @Published var history: [Conversation] = []
    @Published var input = ""
    @Published var isStreaming = false
    @Published var busyTool: String?
    @Published var streamingText = ""
    @Published var open = false
    @Published var expanded = false
    @Published var buttonPos: CGPoint?
    @Published var showSettings = false
    @Published var showHistory = false
    @Published var workspaces: [String] = []

    weak var app: AppModel?
    private let base: URL

    init() {
        base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SkillCanvas", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        load()
        if let arr = UserDefaults.standard.array(forKey: "skillcanvas.chiefButton") as? [Double], arr.count == 2 {
            buttonPos = CGPoint(x: arr[0], y: arr[1])
        }
    }

    // Persist the dragged position of the floating Chief button (absolute window coords).
    func persistButton() {
        guard let p = buttonPos else { return }
        UserDefaults.standard.set([Double(p.x), Double(p.y)], forKey: "skillcanvas.chiefButton")
    }

    var active: AIProvider? { providers.first { $0.id == activeID } }

    // MARK: - Persistence

    private var providersURL: URL { base.appendingPathComponent("providers.json") }
    private var chatsURL: URL { base.appendingPathComponent("chats.json") }
    private var workspacesURL: URL { base.appendingPathComponent("workspaces.json") }

    private func load() {
        if let data = try? Data(contentsOf: providersURL),
           let list = try? JSONDecoder().decode([AIProvider].self, from: data) {
            providers = list
            activeID = list.first?.id
        }
        if let data = try? Data(contentsOf: chatsURL),
           let list = try? JSONDecoder().decode([Conversation].self, from: data) {
            history = list
        }
        if let data = try? Data(contentsOf: workspacesURL),
           let list = try? JSONDecoder().decode([String].self, from: data) {
            workspaces = list
        }
    }
    private func save() {
        if let data = try? JSONEncoder().encode(providers) { try? data.write(to: providersURL) }
        if let data = try? JSONEncoder().encode(history) { try? data.write(to: chatsURL) }
        if let data = try? JSONEncoder().encode(workspaces) { try? data.write(to: workspacesURL) }
    }
    func saveChats() { save() }

    // MARK: - Provider management

    func createProvider(_ p: AIProvider, key: String) throws {
        if let error = p.validate() { throw NSError(domain: "SkillCanvas", code: 10, userInfo: [NSLocalizedDescriptionKey: error]) }
        var provider = p
        provider.hasKey = !key.isEmpty
        if provider.hasKey { Keychain.set(key, account: provider.id.uuidString) }
        if let idx = providers.firstIndex(where: { $0.id == provider.id }) { providers[idx] = provider } else { providers.append(provider) }
        activeID = provider.id
        save()
    }
    func deleteProvider(_ p: AIProvider) {
        providers.removeAll { $0.id == p.id }
        Keychain.delete(account: p.id.uuidString)
        if activeID == p.id { activeID = providers.first?.id }
        save()
    }
    func activate(_ p: AIProvider) { activeID = p.id; save() }

    func addWorkspace() {
        let panel = NSOpenPanel(); panel.title = "Add workspace folder"; panel.canChooseFiles = false
        panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let path = url.path
        if !workspaces.contains(path) { workspaces.append(path); save() }
    }
    func removeWorkspace(_ path: String) { workspaces.removeAll { $0 == path }; save() }

    // MARK: - Conversations

    func newChat() {
        if !messages.isEmpty {
            let title = messages.first(where: { $0.role == .user })?.text.prefix(48).description ?? "New chat"
            history.insert(Conversation(title: title.isEmpty ? "New chat" : title, messages: messages), at: 0)
            if history.count > 50 { history.removeLast() }
        }
        messages = []
        streamingText = ""
        save()
    }
    func openConversation(_ c: Conversation) {
        if !messages.isEmpty { newChat() }
        messages = c.messages
        history.removeAll { $0.id == c.id }
        showHistory = false
    }
    func deleteConversation(_ c: Conversation) { history.removeAll { $0.id == c.id }; save() }

    // MARK: - Sending

    func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isStreaming else { return }
        guard let provider = active else {
            messages.append(ChatMessage(role: .tool, text: AIError.notConnected.localizedDescription, isError: true))
            showSettings = true
            return
        }
        input = ""
        messages.append(ChatMessage(role: .user, text: text))
        isStreaming = true
        streamingText = ""
        Task { await self.runAgent(provider: provider) }
    }

    func stop() {
        isStreaming = false
        busyTool = nil
        streamingText = ""
    }

    private func systemPrompt() -> String {
        let lib = app?.library.path ?? "the skill library"
        return """
        You are the Chief of Apps Operations inside SkillCanvas, a macOS app that manages reusable AI-agent skills.
        You are competent, warm and concise. You act through the tools you are given — prefer doing over describing.
        Skill library root: \(lib)
        Rules:
        - Use tools to read files, search the web, and edit the skill library instead of guessing.
        - Keep replies short and skimmable: a few sentences, bullets when listing steps.
        - Never invent file contents; read them first.
        - Writes are limited to the skill library and approved workspace folders; if a path is refused, tell the user and ask where it should go.
        - When you change a skill, briefly say what you changed and why.
        """
    }

    // MARK: - Agent loop (OpenAI-compatible function calling)

    private func runAgent(provider: AIProvider) async {
        defer { isStreaming = false; busyTool = nil; save() }
        var api = apiHistory()
        for _ in 0..<12 {
            guard isStreaming else { return }
            do {
                let (content, calls) = try await streamChat(provider: provider, messages: api, tools: ToolCatalog.definitions)
                if calls.isEmpty {
                    if content.isEmpty { finishAssistant("") }
                    return
                }
                var assistant = ChatMessage(role: .assistant, text: content)
                if let data = try? JSONSerialization.data(withJSONObject: calls.map { ["id": $0.id, "type": "function", "function": ["name": $0.name, "arguments": $0.arguments]] as [String: Any] }),
                   let json = String(data: data, encoding: .utf8) {
                    assistant.toolCallsJSON = json
                }
                messages.append(assistant)
                api.append(["role": "assistant", "content": content,
                            "tool_calls": calls.map { ["id": $0.id, "type": "function", "function": ["name": $0.name, "arguments": $0.arguments]] as [String: Any] }])
                for call in calls {
                    guard isStreaming else { return }
                    busyTool = call.name
                    let result = await ToolExecutor.execute(call: call, model: self)
                    busyTool = nil
                    messages.append(ChatMessage(role: .tool, text: result.output, toolName: call.name, toolSummary: result.summary, toolID: call.id))
                    api.append(["role": "tool", "tool_call_id": call.id, "content": result.output])
                }
            } catch is CancellationError {
                return
            } catch {
                messages.append(ChatMessage(role: .tool, text: error.localizedDescription, isError: true))
                return
            }
        }
        messages.append(ChatMessage(role: .tool, text: "Stopped: reached the 12-step tool limit for this turn.", isError: true))
    }

    private func finishAssistant(_ text: String) {
        streamingText = ""
        messages.append(ChatMessage(role: .assistant, text: text.isEmpty ? "…" : text))
    }

    private func apiHistory() -> [[String: Any]] {
        var out: [[String: Any]] = [["role": "system", "content": systemPrompt()]]
        for m in messages {
            switch m.role {
            case .user:
                out.append(["role": "user", "content": m.text])
            case .assistant:
                if let json = m.toolCallsJSON, let arr = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]] {
                    out.append(["role": "assistant", "content": m.text, "tool_calls": arr])
                } else if !m.text.isEmpty {
                    out.append(["role": "assistant", "content": m.text])
                }
            case .tool:
                out.append(["role": "tool", "tool_call_id": m.toolID ?? "", "content": m.text])
            case .system:
                break
            }
        }
        return out
    }

    // Streaming chat completion. Returns final text plus any requested tool calls.
    private func streamChat(provider: AIProvider, messages api: [[String: Any]], tools: [[String: Any]]) async throws -> (String, [ToolCall]) {
        guard let url = provider.chatURL else { throw AIError.badEndpoint }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if provider.hasKey, let key = Keychain.get(account: provider.id.uuidString), !key.isEmpty {
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        var body: [String: Any] = ["model": provider.modelID, "messages": api, "stream": true, "temperature": 0.4]
        if !tools.isEmpty { body["tools"] = tools; body["tool_choice"] = "auto" }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: req)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            var raw = ""
            for try await line in bytes.lines { raw += line }
            throw AIError.server(http.statusCode, AIErrorParser.message(raw) ?? String(raw.prefix(300)))
        }

        var content = ""
        var acc: [Int: ToolCall] = [:]
        var sawToolCall = false
        streamingText = ""

        for try await line in bytes.lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            var payload = trimmed
            if payload.hasPrefix("data:") { payload = String(payload.dropFirst(5)).trimmingCharacters(in: .whitespaces) }
            guard !payload.isEmpty else { continue }
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = obj["choices"] as? [[String: Any]],
                  let first = choices.first else { continue }

            // Non-streaming fallback: some servers ignore stream:true and send a full message.
            if let message = first["message"] as? [String: Any] {
                if let c = message["content"] as? String, !c.isEmpty { content += c; streamingText = content }
                collect(message["tool_calls"], into: &acc); sawToolCall = sawToolCall || !acc.isEmpty
            }
            if let delta = first["delta"] as? [String: Any] {
                if let c = delta["content"] as? String, !c.isEmpty { content += c; streamingText = content }
                collect(delta["tool_calls"], into: &acc); sawToolCall = sawToolCall || !acc.isEmpty
            }
        }
        streamingText = ""
        if sawToolCall {
            let calls = acc.keys.sorted().compactMap { acc[$0] }.filter { !$0.name.isEmpty }
            if !content.isEmpty { messages.append(ChatMessage(role: .assistant, text: content)) }
            return (content, calls)
        }
        return (content, [])
    }

    private func collect(_ raw: Any?, into acc: inout [Int: ToolCall]) {
        guard let list = raw as? [[String: Any]] else { return }
        for item in list {
            let idx = item["index"] as? Int ?? 0
            var call = acc[idx] ?? ToolCall(id: "call_\(idx)", name: "", arguments: "")
            if let id = item["id"] as? String, !id.isEmpty { call.id = id }
            if let fn = item["function"] as? [String: Any] {
                if let n = fn["name"] as? String, !n.isEmpty { call.name = n }
                if let a = fn["arguments"] as? String { call.arguments += a }
            }
            acc[idx] = call
        }
    }
}

enum AIErrorParser {
    static func message(_ raw: String) -> String? {
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let err = obj["error"] as? [String: Any], let m = err["message"] as? String { return m }
        return nil
    }
}
