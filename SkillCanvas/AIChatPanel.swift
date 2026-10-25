import SwiftUI
import AppKit

// MARK: - Layer: floating button + slide-over panel, on every page

struct AIChatLayer: View {
    @EnvironmentObject var ai: AIModel
    @EnvironmentObject var model: AppModel
    @State private var dragOrigin: CGPoint?
    @State private var dragging = false

    // Keeps the floating button fully on-screen, whatever the window size.
    static func clamp(_ p: CGPoint, size: CGSize) -> CGPoint {
        let half: CGFloat = 30, margin: CGFloat = 8
        let minX = half + margin, maxX = max(minX, size.width - half - margin)
        let minY = half + margin, maxY = max(minY, size.height - half - margin)
        return CGPoint(x: min(max(p.x, minX), maxX), y: min(max(p.y, minY), maxY))
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottomTrailing) {
                Color.clear
                if ai.open {
                    Group {
                        if ai.expanded {
                            AIChatPanel().frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            AIChatPanel().frame(width: 452).frame(maxHeight: .infinity)
                        }
                    }
                    .padding(ai.expanded ? 14 : 12)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: ai.expanded ? 16 : 22, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: ai.expanded ? 16 : 22, style: .continuous).stroke(Color.primary.opacity(0.10)))
                    .shadow(color: .black.opacity(0.28), radius: 28, y: 12)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                    .zIndex(3)
                } else {
                    let size = geo.size
                    let def = CGPoint(x: size.width - 49, y: size.height - 47)
                    let target = Self.clamp(ai.buttonPos ?? def, size: size)
                    Button {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { ai.open = true }
                    } label: {
                        ZStack(alignment: .topTrailing) {
                            AppIconImage(size: 54)
                            Circle().fill(ai.isStreaming ? Color.orange : Color.green)
                                .frame(width: 14, height: 14)
                                .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 2.5))
                                .offset(x: 3, y: -3)
                        }
                        .shadow(color: dragging ? .black.opacity(0.45) : .clear, radius: 16, y: 8)
                    }
                    .buttonStyle(.plain)
                    .scaleEffect(dragging ? 1.08 : 1)
                    .keyboardShortcut("k", modifiers: .command)
                    .help("Open the Chief (⌘K) — drag anywhere to move this button")
                    .padding(.trailing, 22).padding(.bottom, 20)
                    .offset(x: target.x - def.x, y: target.y - def.y)
                    .animation(.spring(response: 0.3, dampingFraction: 0.8), value: dragging)
                    .gesture(
                        DragGesture()
                            .onChanged { v in
                                if dragOrigin == nil { dragOrigin = target }
                                guard let origin = dragOrigin else { return }
                                ai.buttonPos = Self.clamp(CGPoint(x: origin.x + v.translation.width, y: origin.y + v.translation.height), size: size)
                                dragging = true
                            }
                            .onEnded { _ in
                                dragOrigin = nil
                                dragging = false
                                ai.buttonPos = Self.clamp(ai.buttonPos ?? def, size: size)
                                ai.persistButton()
                            }
                    )
                    .transition(.opacity)
                    .zIndex(2)
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: ai.open)
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: ai.expanded)
        }
        .sheet(isPresented: $ai.showSettings) {
            ProviderSettingsView().environmentObject(ai).environmentObject(model)
        }
    }
}

// MARK: - Panel

struct AIChatPanel: View {
    @EnvironmentObject var ai: AIModel
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Color.primary.opacity(0.07)).frame(height: 1)
            if ai.showHistory { historyList }
            messages
            if let tool = ai.busyTool { busyBar(tool) }
            Rectangle().fill(Color.primary.opacity(0.07)).frame(height: 1)
            composer
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 10) {
            AppIconImage(size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text("The Chief").font(.system(size: 14, weight: .bold))
                Text(ai.active.map { "\($0.modelID)" } ?? "No provider connected")
                    .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            headerButton("plus", "New chat") { ai.newChat() }
            headerButton("clock", "History") { withAnimation { ai.showHistory.toggle() } }
            headerButton("gearshape", "Providers") { ai.showSettings = true }
            headerButton(ai.expanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                         ai.expanded ? "Shrink panel" : "Expand to full window") {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { ai.expanded.toggle() }
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            headerButton("xmark", "Close (⌘K)") { withAnimation { ai.open = false } }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
    }

    private func headerButton(_ icon: String, _ tip: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon).font(.system(size: 12, weight: .semibold)).frame(width: 26, height: 26) }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .background(Circle().fill(Color.primary.opacity(0.06)))
            .help(tip)
    }

    private var historyList: some View {
        VStack(alignment: .leading, spacing: 2) {
            if ai.history.isEmpty {
                Text("No previous chats yet.").font(.system(size: 11)).foregroundStyle(.secondary).padding(10)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(ai.history) { c in
                            HStack {
                                Image(systemName: "bubble.left").font(.system(size: 10)).foregroundStyle(.secondary)
                                Text(c.title).font(.system(size: 11)).lineLimit(1)
                                Spacer()
                                Button { ai.deleteConversation(c) } label: { Image(systemName: "trash").font(.system(size: 9)) }
                                    .buttonStyle(.plain).foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 7))
                            .contentShape(Rectangle())
                            .onTapGesture { withAnimation { ai.openConversation(c) } }
                        }
                    }.padding(8)
                }.frame(maxHeight: 170)
            }
        }.overlay(alignment: .topTrailing) {
            Button { withAnimation { ai.showHistory = false } } label: { Image(systemName: "chevron.up").font(.system(size: 10, weight: .bold)) }
                .buttonStyle(.plain).foregroundStyle(.secondary).padding(10)
        }
    }

    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(ai.messages) { msg in MessageRow(message: msg).id(msg.id) }
                    if ai.isStreaming && !ai.streamingText.isEmpty {
                        MessageRow(message: ChatMessage(role: .assistant, text: ai.streamingText)).id("streaming")
                    } else if ai.isStreaming {
                        HStack(spacing: 7) {
                            ProgressView().controlSize(.small)
                            Text(ai.busyTool == nil ? "Thinking…" : "Working…").font(.system(size: 11)).foregroundStyle(.secondary)
                        }.id("streaming").padding(.leading, 4)
                    }
                }
                .frame(maxWidth: ai.expanded ? 860 : .infinity, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(16)
            }
            .onChange(of: ai.messages) { _, _ in
                if ai.open {
                    if let last = ai.messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
                    else { proxy.scrollTo("streaming", anchor: .bottom) }
                }
            }
            .onChange(of: ai.streamingText) { _, _ in
                if ai.open, !ai.streamingText.isEmpty { proxy.scrollTo("streaming", anchor: .bottom) }
            }
        }
    }

    private func busyBar(_ tool: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.mini)
            Text("🔧 \(tool)").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            Spacer()
        }.padding(.horizontal, 14).padding(.vertical, 8).background(Color.primary.opacity(0.04))
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Ask the Chief to search, read, write…", text: $ai.input, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .lineLimit(1...6)
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
                .onSubmit { ai.send() }
            if ai.isStreaming {
                Button { ai.stop() } label: { Image(systemName: "stop.circle.fill").font(.system(size: 28)) }
                    .buttonStyle(.plain).foregroundStyle(.red)
            } else {
                Button { ai.send() } label: { Image(systemName: "arrow.up.circle.fill").font(.system(size: 28)) }
                    .buttonStyle(.plain)
                    .foregroundStyle(ai.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.secondary.opacity(0.5) : Color.accentColor)
                    .disabled(ai.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(12)
    }
}

// MARK: - One message row

struct MessageRow: View {
    @EnvironmentObject var ai: AIModel
    let message: ChatMessage
    @State private var expanded = false

    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 40)
                Text(message.text)
                    .font(.system(size: 13))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 13).padding(.vertical, 9)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .textSelection(.enabled)
            }
        case .tool:
            toolCard
        case .assistant, .system:
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 8) {
                    AppIconImage(size: 20)
                    if message.isError {
                        Text(message.text).font(.system(size: 12)).foregroundStyle(.red)
                            .padding(10).background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                    } else {
                        MarkdownLite(text: message.text).font(.system(size: 13))
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var toolCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() } } label: {
                HStack(spacing: 7) {
                    Text(Self.icon(for: message.toolName ?? "")).font(.system(size: 11))
                    Text(message.toolName ?? "tool").font(.system(size: 11, weight: .semibold)).monospaced()
                    Text(message.toolSummary ?? message.text.split(separator: "\n").first.map { String($0) } ?? "")
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 9))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if message.isError {
                Text(message.text).font(.system(size: 11)).foregroundStyle(.red).padding(.leading, 4)
            }
            if expanded {
                Text(message.text)
                    .font(.system(size: 11)).textSelection(.enabled)
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.black.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))
                    .padding(.leading, 4)
            }
        }
        .padding(.leading, 24)
    }

    static func icon(for name: String) -> String {
        switch name {
        case "web_search": "🔍"
        case "fetch_page": "🌐"
        case "list_skills", "get_skill", "search_library": "📚"
        case "create_skill", "update_skill": "✏️"
        case "install_skill": "📦"
        case "list_files", "read_file": "📄"
        case "write_file": "💾"
        case "app_status": "🎛️"
        default: "🔧"
        }
    }
}

// MARK: - Markdown-lite (bold, inline code, bullets, code fences)

struct MarkdownLite: View {
    let text: String

    enum Block: Identifiable {
        case code(String, id: UUID)
        case text([String], id: UUID)
        var id: UUID { switch self { case .code(_, let id): id; case .text(_, let id): id } }
    }

    private var blocks: [Block] {
        var out: [Block] = []
        var paragraph: [String] = []
        var code: [String] = []
        var inCode = false
        func flush() {
            if !paragraph.isEmpty { out.append(.text(paragraph, id: UUID())); paragraph = [] }
            if !code.isEmpty { out.append(.code(code.joined(separator: "\n"), id: UUID())); code = [] }
        }
        for line in text.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if inCode { flush() }
                inCode.toggle()
                continue
            }
            if inCode { code.append(line) } else if line.trimmingCharacters(in: .whitespaces).isEmpty { flush() } else { paragraph.append(line) }
        }
        flush()
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(blocks) { block in
                switch block {
                case .code(let code, _):
                    CodeBlockView(code: code)
                case .text(let lines, _):
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                            if let bullet = bulletLine(line) {
                                HStack(alignment: .top, spacing: 6) {
                                    Text("•").foregroundStyle(.secondary)
                                    markdownInline(bullet)
                                }.fixedSize(horizontal: false, vertical: true)
                            } else {
                                markdownInline(line).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
        }
    }

    private func bulletLine(_ line: String) -> String? {
        for prefix in ["- ", "• ", "* ", "– "] {
            if line.hasPrefix(prefix) { return String(line.dropFirst(prefix.count)) }
        }
        if let range = line.range(of: #"^\d+\.\s"#, options: .regularExpression) { return String(line[range.upperBound...]) }
        return nil
    }

    private func markdownInline(_ line: String) -> Text {
        (try? AttributedString(markdown: line, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            .map(Text.init) ?? Text(line)
    }
}

struct CodeBlockView: View {
    let code: String
    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack {
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                } label: { Label("Copy", systemImage: "doc.on.doc").font(.system(size: 10)) }
                .buttonStyle(.plain).foregroundStyle(.secondary)
            }
            ScrollView(.horizontal) {
                Text(code).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
    }
}

// MARK: - Provider settings

struct ProviderDraft: Identifiable {
    var id = UUID()
    var provider: AIProvider
    var key = ""
    var isNew = true
}

struct ProviderSettingsView: View {
    @EnvironmentObject var ai: AIModel
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss: DismissAction
    @State private var draft: ProviderDraft?
    @State private var busy = false
    @State private var status: String?
    @State private var statusOK = false
    @State private var modelList: [String] = []

    init() {}

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("AI Providers", systemImage: "cpu").font(.system(size: 15, weight: .bold))
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.escape).buttonStyle(.borderedProminent).controlSize(.small)
            }.padding(16)
            Rectangle().fill(Color.primary.opacity(0.07)).frame(height: 1)
            if let draft { form(draft) } else { list }
        }
        .frame(width: 560, height: 620)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Connections").font(.system(size: 12, weight: .bold)).foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        modelList = []; status = nil
                        draft = ProviderDraft(provider: AIProvider(name: "", preset: ProviderPreset.openai.rawValue, endpoint: ProviderPreset.openai.endpoint, modelID: ProviderPreset.openai.modelHint))
                    } label: { Label("New connection", systemImage: "plus") }.buttonStyle(.borderedProminent).controlSize(.small)
                }
                if ai.providers.isEmpty {
                    emptyCard
                } else {
                    ForEach(ai.providers) { p in providerCard(p) }
                }
                Text("Workspace folders").font(.system(size: 12, weight: .bold)).foregroundStyle(.secondary).padding(.top, 6)
                Text("The Chief may read and write inside the skill library and these folders — nothing else.").font(.system(size: 11)).foregroundStyle(.secondary)
                HStack {
                    Button { ai.addWorkspace() } label: { Label("Add folder", systemImage: "folder.badge.plus") }.buttonStyle(.bordered).controlSize(.small)
                    Spacer()
                }
                ForEach(ai.workspaces, id: \.self) { path in
                    HStack {
                        Image(systemName: "folder").foregroundStyle(.secondary)
                        Text(path).font(.system(size: 11)).lineLimit(1)
                        Spacer()
                        Button { ai.removeWorkspace(path) } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain).foregroundStyle(.red)
                    }.padding(8).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                }
            }.padding(16)
        }
    }

    private var emptyCard: some View {
        VStack(spacing: 8) {
            Image(systemName: "cpu").font(.system(size: 26)).foregroundStyle(.secondary)
            Text("No provider yet").font(.system(size: 13, weight: .semibold))
            Text("Add any OpenAI-compatible endpoint: OpenAI, OpenRouter, Groq, Ollama, LM Studio, or a custom server.")
                .font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.frame(maxWidth: .infinity).padding(24).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
    }

    private func providerCard(_ p: AIProvider) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Circle().fill(p.id == ai.activeID ? Color.green : Color.secondary.opacity(0.4)).frame(width: 8, height: 8)
                Text(p.name).font(.system(size: 13, weight: .semibold))
                if p.id == ai.activeID { Text("ACTIVE").font(.system(size: 9, weight: .bold)).padding(.horizontal, 6).padding(.vertical, 2).background(Color.green.opacity(0.15), in: Capsule()).foregroundStyle(.green) }
                Spacer()
                if p.id != ai.activeID {
                    Button("Use") { ai.activate(p) }.buttonStyle(.bordered).controlSize(.mini)
                }
                Button("Test") { Task { await testExisting(p) } }.buttonStyle(.bordered).controlSize(.mini).disabled(busy)
                Button("Edit") { modelList = []; status = nil; draft = ProviderDraft(provider: p, key: "", isNew: false) }.buttonStyle(.bordered).controlSize(.mini)
                Button { ai.deleteProvider(p) } label: { Image(systemName: "trash") }.buttonStyle(.bordered).controlSize(.mini).foregroundStyle(.red)
            }
            Text("\(p.preset) · \(p.endpoint) · \(p.modelID) · key \(p.hasKey ? "stored ✓" : "none")")
                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
        }.padding(12).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }

    private func form(_ d: ProviderDraft) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Button { status = nil; draft = nil } label: { Label("Back", systemImage: "chevron.left") }.buttonStyle(.borderless).controlSize(.small)
                    Spacer()
                    Text(d.isNew ? "New connection" : "Edit connection").font(.system(size: 13, weight: .bold))
                    Spacer()
                }
                field("Name") {
                    TextField("My GPT", text: Binding(get: { d.provider.name }, set: { draft?.provider.name = $0 }))
                        .textFieldStyle(.roundedBorder)
                }
                field("Provider") {
                    Picker("", selection: Binding(get: { d.provider.preset }, set: { newPreset in
                        draft?.provider.preset = newPreset
                        let preset = ProviderPreset(rawValue: newPreset) ?? .custom
                        if preset != .custom {
                            let oldDefault = ProviderPreset(rawValue: d.provider.preset)?.endpoint ?? ""
                            if d.provider.endpoint.isEmpty || d.provider.endpoint == oldDefault { draft?.provider.endpoint = preset.endpoint }
                            let oldHint = ProviderPreset(rawValue: d.provider.preset)?.modelHint ?? ""
                            if d.provider.modelID.isEmpty || d.provider.modelID == oldHint { draft?.provider.modelID = preset.modelHint }
                        }
                        status = nil
                    })) {
                        ForEach(ProviderPreset.allCases) { Text($0.rawValue).tag($0.rawValue) }
                    }.labelsHidden()
                }
                field("Endpoint URL") {
                    TextField("https://api.openai.com/v1", text: Binding(get: { d.provider.endpoint }, set: { draft?.provider.endpoint = $0; status = nil }))
                        .textFieldStyle(.roundedBorder)
                }
                field("API Key") {
                    HStack {
                        SecureField(d.isNew && !d.provider.hasKey ? "sk-… (stored in Keychain)" : (d.provider.hasKey ? "•••••• (saved — type to replace)" : "optional for local servers"),
                                    text: Binding(get: { d.key }, set: { draft?.key = $0; status = nil }))
                            .textFieldStyle(.roundedBorder)
                        if d.provider.hasKey && !d.isNew {
                            Button("Clear") { Keychain.delete(account: d.provider.id.uuidString); draft?.provider.hasKey = false }
                                .buttonStyle(.bordered).controlSize(.mini)
                        }
                    }
                }
                field("Model ID") {
                    HStack {
                        TextField("gpt-4o-mini", text: Binding(get: { d.provider.modelID }, set: { draft?.provider.modelID = $0; status = nil }))
                            .textFieldStyle(.roundedBorder)
                        Button("List models") { Task { await fetchModels() } }.buttonStyle(.bordered).controlSize(.small).disabled(busy)
                    }
                    if !modelList.isEmpty {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 2) {
                                ForEach(modelList, id: \.self) { m in
                                    Button { draft?.provider.modelID = m } label: {
                                        HStack { Text(m).font(.system(size: 11)); Spacer(); if m == d.provider.modelID { Image(systemName: "checkmark").font(.system(size: 9)) } }
                                            .padding(.horizontal, 8).padding(.vertical, 5)
                                    }.buttonStyle(.plain).background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 6))
                                }
                            }
                        }.frame(maxHeight: 150).padding(6).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                if let status {
                    HStack(spacing: 6) {
                        Image(systemName: statusOK ? "checkmark.circle.fill" : "xmark.circle.fill")
                        Text(status).font(.system(size: 12))
                    }.foregroundStyle(statusOK ? .green : .red)
                }
                HStack {
                    Spacer()
                    Button {
                        draft = nil; status = nil
                    } label: { Text("Cancel") }.buttonStyle(.bordered)
                    Button { Task { await createTapped() } } label: {
                        HStack(spacing: 6) { if busy { ProgressView().controlSize(.mini) }; Text(d.isNew ? "Create" : "Save") }
                    }.buttonStyle(.borderedProminent).disabled(busy)
                }
            }.padding(18)
        }
    }

    private func field<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            content()
        }
    }

    private func createTapped() async {
        guard var d = draft else { return }
        busy = true; status = nil
        defer { busy = false }
        if let err = d.provider.validate() { status = err; statusOK = false; return }
        if ProviderPreset(rawValue: d.provider.preset)?.needsKey == true && d.key.isEmpty && !d.provider.hasKey {
            status = "This provider needs an API key."; statusOK = false; return
        }
        do {
            status = "Testing connection…"
            if !d.key.isEmpty { Keychain.set(d.key, account: d.provider.id.uuidString); d.provider.hasKey = true }
            try await AIHttp.test(d.provider)
            try ai.createProvider(d.provider, key: d.key)
            status = "Connected to \(d.provider.modelID) ✓"; statusOK = true
            draft = nil
            model.status = "AI provider \"\(d.provider.name)\" connected."
            ai.showSettings = false
            ai.showSettings = true
        } catch {
            status = error.localizedDescription; statusOK = false
        }
    }

    private func testExisting(_ p: AIProvider) async {
        busy = true; status = nil
        defer { busy = false }
        do {
            try await AIHttp.test(p)
            status = "\(p.name): connected ✓"; statusOK = true
        } catch {
            status = "\(p.name): \(error.localizedDescription)"; statusOK = false
        }
    }

    private func fetchModels() async {
        guard let d = draft else { return }
        busy = true
        defer { busy = false }
        do {
            if !d.key.isEmpty { Keychain.set(d.key, account: d.provider.id.uuidString) }
            modelList = try await AIHttp.listModels(d.provider)
            if modelList.isEmpty { status = "This endpoint did not return a model list."; statusOK = false }
        } catch {
            status = "Model list failed: \(error.localizedDescription)"; statusOK = false
        }
    }
}
