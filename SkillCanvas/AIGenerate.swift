import SwiftUI
import AppKit
import UniformTypeIdentifiers
import PDFKit

enum CreateMode: String, CaseIterable, Identifiable {
    case github = "GitHub repo"
    case prompt = "Prompt & files"
    var id: String { rawValue }
}

enum AIGenError: LocalizedError {
    case badRepo, videoUnsupported, noFiles, emptyResponse
    var errorDescription: String? {
        switch self {
        case .badRepo: "Enter a GitHub repo like https://github.com/owner/repo"
        case .videoUnsupported: "Videos are not supported yet — use images, documents, text or code files."
        case .noFiles: "Choose at least one file, or describe your idea in the prompt."
        case .emptyResponse: "The model returned an empty response. Try again or use another model."
        }
    }
}

// MARK: - Core generation engine (pure logic, no UI state)

enum AIGen {
    struct RepoBundle {
        var slug: String        // "owner/repo"
        var branch: String
        var description: String
        var tree: [String]      // file paths (sampled)
        var readme: String
    }

    struct Attachment {
        var name: String
        var text: String?
        var dataURL: String?    // images as data:<mime>;base64,
    }

    static let systemPrompt = """
    You are The Chief, an expert author of SKILL.md files for AI agent skills \
    (the kind used by Claude Code, Antigravity, OpenCode and similar agents).
    You write ONE complete SKILL.md file per request.
    Rules:
    - Return ONLY the raw SKILL.md content. No commentary, no markdown code fences.
    - Start with YAML frontmatter on its own lines:
      ---
      name: kebab-case-slug
      description: One sentence beginning with an action verb saying what the skill does and when to use it.
      ---
    - Then: a # Title, ## When to use, ## Workflow (numbered, concrete steps with real commands/paths/tools), ## Output (expected result and quality checks).
    - Be specific and practical. Never vague filler like "understand the task".
    - Keep the whole file under ~150 lines.
    """

    // MARK: GitHub (keyless)

    static func parseRepo(_ input: String) throws -> String {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.replacingOccurrences(of: "https://", with: "").replacingOccurrences(of: "http://", with: "")
        if let r = s.range(of: "github.com/") { s = String(s[r.upperBound...]) }
        s = s.replacingOccurrences(of: "www.github.com/", with: "")
        let parts = s.split(separator: "/").map(String.init)
        guard parts.count >= 2, !parts[0].isEmpty, !parts[1].isEmpty else { throw AIGenError.badRepo }
        var repo = parts[1]
        if repo.hasSuffix(".git") { repo = String(repo.dropLast(4)) }
        guard !repo.isEmpty else { throw AIGenError.badRepo }
        return "\(parts[0])/\(repo)"
    }

    private static func ghGet(_ url: URL) async throws -> Data {
        var req = URLRequest(url: url)
        req.setValue("SkillCanvas/1.0 (skill generator)", forHTTPHeaderField: "User-Agent")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let detail = http.statusCode == 404 ? "Repository or file not found on GitHub (404)." : "GitHub replied \(http.statusCode)."
            throw NSError(domain: "SkillCanvas", code: 12, userInfo: [NSLocalizedDescriptionKey: detail])
        }
        return data
    }

    static func fetchRepo(_ input: String) async throws -> RepoBundle {
        let slug = try parseRepo(input)
        guard let api = URL(string: "https://api.github.com/repos/\(slug)") else { throw AIGenError.badRepo }
        let meta = try await ghGet(api)
        let obj = (try? JSONSerialization.jsonObject(with: meta)) as? [String: Any]
        let branch = (obj?["default_branch"] as? String) ?? "main"
        let desc = (obj?["description"] as? String) ?? ""

        var paths: [String] = []
        if let treeURL = URL(string: "\(api.absoluteString)/git/trees/\(branch)?recursive=1"),
           let treeData = try? await ghGet(treeURL),
           let t = (try? JSONSerialization.jsonObject(with: treeData)) as? [String: Any],
           let entries = t["tree"] as? [[String: Any]] {
            paths = entries.filter { ($0["type"] as? String) == "blob" }.compactMap { $0["path"] as? String }
            if paths.count > 250 { paths = Array(paths.prefix(250)) }
        }

        var readme = ""
        if let readmeURL = URL(string: "\(api.absoluteString)/readme"),
           let rd = try? await ghGet(readmeURL),
           let r = (try? JSONSerialization.jsonObject(with: rd)) as? [String: Any],
           let b64 = r["content"] as? String,
           let d = Data(base64Encoded: b64.replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: "\r", with: "")) {
            readme = String(data: d, encoding: .utf8) ?? ""
        }
        if readme.count > 12000 { readme = String(readme.prefix(12000)) }
        return RepoBundle(slug: slug, branch: branch, description: desc, tree: paths, readme: readme)
    }

    static func githubPrompt(_ repo: RepoBundle) -> String {
        var p = "Create a SKILL.md skill that teaches an AI agent to work effectively with the GitHub repository \"\(repo.slug)\".\n"
        p += "Default branch: \(repo.branch)\n"
        if !repo.description.isEmpty { p += "Repository description: \(repo.description)\n" }
        if !repo.tree.isEmpty { p += "\nFile tree (sample, \(repo.tree.count) files):\n" + repo.tree.joined(separator: "\n") + "\n" }
        if !repo.readme.isEmpty { p += "\nREADME:\n\(repo.readme)\n" }
        p += "\nThe skill should cover: what this repo is, how to set it up, how to build/test it, and the key workflows an agent would follow when using or contributing to it."
        return p
    }

    // MARK: Model call (OpenAI-compatible, non-streaming)

    static func complete(provider: AIProvider, system: String, content: Any, maxTokens: Int = 4096, temperature: Double = 0.4) async throws -> String {
        guard let url = provider.chatURL else { throw AIError.badEndpoint }
        let body: [String: Any] = [
            "model": provider.modelID,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": content]
            ],
            "max_tokens": maxTokens,
            "temperature": temperature
        ]
        let data = try await AIHttp.request(url, provider: provider, body: body)
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let msg = choices.first?["message"] as? [String: Any] else {
            throw AIError.server(200, "The model returned an unexpected response shape.")
        }
        if let s = msg["content"] as? String { return s }
        if let arr = msg["content"] as? [[String: Any]] { return arr.compactMap { $0["text"] as? String }.joined() }
        throw AIGenError.emptyResponse
    }

    static func looksLikeSkill(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return (t.hasPrefix("---") && t.contains("\nname:")) || (t.contains("## Workflow") && t.hasPrefix("#"))
    }

    // Instructions are embedded at BOTH ends of the user message: some OpenAI-compatible
    // proxies drop the system role and/or the head of long messages.
    static func completeSkill(provider: AIProvider, task: Any) async throws -> String {
        let tail = "\n\n===== FORMAT =====\nReply with ONLY one complete SKILL.md file: it must start with a '---' frontmatter block containing name: and description:, then # Title, ## When to use, ## Workflow (numbered concrete steps), ## Output. No prose before or after, no code fences."
        func enriched(_ retry: String) -> Any {
            if let s = task as? String { return systemPrompt + "\n\n===== TASK =====\n" + s + tail + retry }
            if var arr = task as? [[String: Any]] {
                arr.insert(["type": "text", "text": systemPrompt + "\n\n===== TASK =====\n"], at: 0)
                arr.append(["type": "text", "text": tail + retry])
                return arr
            }
            return task
        }
        var raw = try await complete(provider: provider, system: systemPrompt, content: enriched(""))
        if !looksLikeSkill(raw) {
            raw = try await complete(provider: provider, system: systemPrompt,
                content: enriched("\n\nIMPORTANT: Your previous reply was NOT a valid SKILL.md. Follow the FORMAT block exactly and output only the file."))
        }
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AIGenError.emptyResponse }
        return raw
    }

    // MARK: Normalize model output into a valid SKILL.md

    static func skillMarkdown(from raw: String, fallbackName: String, fallbackDesc: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Unwrap ONLY if the whole reply is fenced (``` at the very start).
        // Mid-document fences are legitimate SKILL.md content — never touch those.
        if text.hasPrefix("```") {
            let openEnd = text.index(text.startIndex, offsetBy: 3)
            if let e = text.range(of: "```", range: openEnd..<text.endIndex) {
                var inner = String(text[openEnd..<e.lowerBound])
                if let nl = inner.firstIndex(of: "\n") {
                    let head = inner[..<nl]
                    if head.isEmpty || head.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) {
                        inner = String(inner[inner.index(after: nl)...])
                    }
                }
                text = inner.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        // Drop any chatty preamble before the frontmatter or first heading.
        if !text.hasPrefix("---") {
            if let r = text.range(of: "---\nname:") { text = String(text[r.lowerBound...]) }
            else if let r = text.range(of: "---\ndescription:") { text = String(text[r.lowerBound...]) }
            else if let hash = text.range(of: "\n# ") { text = "#" + String(text[text.index(after: hash.lowerBound)...]) }
        }
        guard !text.hasPrefix("---") else { return text }
        // No frontmatter: build one from the first heading / fallbacks.
        var name = fallbackName, desc = fallbackDesc
        if let firstLine = text.components(separatedBy: "\n").first, firstLine.hasPrefix("# ") {
            name = String(firstLine.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            desc = "AI-agent skill: " + name
        }
        let slug = slugify(name)
        let cleanDesc = desc.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return "---\nname: \(slug.isEmpty ? "ai-skill" : slug)\ndescription: \(cleanDesc.isEmpty ? "Skill generated by The Chief" : cleanDesc)\n---\n\n" + text
    }

    static func slugify(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        let parts = value.lowercased().unicodeScalars.map { allowed.contains($0) ? String($0) : "-" }
        let slug = parts.joined().split(separator: "-").joined(separator: "-")
        return String(slug.prefix(64)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    static func writeSkill(library: URL, content: String) throws -> (folder: URL, name: String) {
        var name = "ai-skill"
        if content.hasPrefix("---"),
           let end = content.range(of: "\n---", range: content.index(content.startIndex, offsetBy: 4)..<content.endIndex) {
            for line in content[content.startIndex..<end.lowerBound].split(separator: "\n") {
                if line.hasPrefix("name:") { name = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces) }
            }
        }
        let slug = slugify(name).isEmpty ? "ai-skill" : slugify(name)
        var folder = library.appendingPathComponent(slug, isDirectory: true)
        var n = 2
        while FileManager.default.fileExists(atPath: folder.path) {
            folder = library.appendingPathComponent("\(slug)-\(n)", isDirectory: true)
            n += 1
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try content.write(to: folder.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        return (folder, name)
    }

    // MARK: Prompt + files mode

    static func loadAttachments(_ urls: [URL]) throws -> [Attachment] {
        guard !urls.isEmpty else { throw AIGenError.noFiles }
        var out: [Attachment] = []
        for url in urls {
            let ext = url.pathExtension.lowercased()
            if let ut = UTType(filenameExtension: ext), ut.conforms(to: .movie) || ut.conforms(to: .video) {
                throw AIGenError.videoUnsupported
            }
            if let ut = UTType(filenameExtension: ext), ut.conforms(to: .image) {
                let data = try Data(contentsOf: url)
                guard data.count <= 8_000_000 else {
                    throw NSError(domain: "SkillCanvas", code: 13, userInfo: [NSLocalizedDescriptionKey: "\"\(url.lastPathComponent)\" is larger than 8 MB — use a smaller image."])
                }
                let mime = ut.preferredMIMEType ?? "image/png"
                out.append(Attachment(name: url.lastPathComponent, text: nil, dataURL: "data:\(mime);base64,\(data.base64EncodedString())"))
                continue
            }
            if let ut = UTType(filenameExtension: ext), ut.conforms(to: .pdf),
               let doc = PDFDocument(url: url), let str = doc.string {
                out.append(Attachment(name: url.lastPathComponent, text: String(str.prefix(30000)), dataURL: nil))
                continue
            }
            var text = (try? String(contentsOf: url, encoding: .utf8))
                ?? (try? String(contentsOf: url, encoding: .isoLatin1))
            if text?.contains("\0") == true { text = nil }
            out.append(Attachment(name: url.lastPathComponent, text: text.map { String($0.prefix(30000)) }, dataURL: nil))
        }
        return out
    }

    static func promptContent(prompt: String, attachments: [Attachment]) -> (content: Any, textOnly: String, hasImages: Bool) {
        var text = "Create a SKILL.md skill based on my idea and the material below.\n\nMy idea:\n"
        text += prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "(infer the skill's purpose from the attachments)" : prompt
        let docs = attachments.filter { $0.text != nil }
        let images = attachments.filter { $0.dataURL != nil }
        if !docs.isEmpty {
            text += "\n\nAttached documents:"
            for a in docs { text += "\n\n--- \(a.name) ---\n\(a.text ?? "")" }
        }
        guard !images.isEmpty else { return (text, text, false) }
        text += "\n\nAttached images: \(images.map(\.name).joined(separator: ", ")). Look at each image and incorporate anything relevant to the skill."
        var parts: [[String: Any]] = [["type": "text", "text": text]]
        for img in images { parts.append(["type": "image_url", "image_url": ["url": img.dataURL!]]) }
        return (parts, text, true)
    }
}

// MARK: - Create sheet

struct AICreateSheet: View {
    @EnvironmentObject var ai: AIModel
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss: DismissAction
    @State private var mode: CreateMode = .github
    @State private var url = ""
    @State private var prompt = ""
    @State private var files: [URL] = []
    @State private var busy = false
    @State private var step = ""
    @State private var err: String?

    init() {}

    private var canRun: Bool {
        guard ai.active != nil else { return false }
        switch mode {
        case .github: return !url.trimmingCharacters(in: .whitespaces).isEmpty
        case .prompt: return !prompt.trimmingCharacters(in: .whitespaces).isEmpty || !files.isEmpty
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Label("Create a skill", systemImage: "sparkles").font(.system(size: 15, weight: .bold))
                Text("with The Chief").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.escape).buttonStyle(.bordered).controlSize(.small).disabled(busy)
            }.padding(16)
            Rectangle().fill(Color.primary.opacity(0.07)).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 15) {
                    Picker("", selection: $mode) { ForEach(CreateMode.allCases) { Text($0.rawValue).tag($0) } }
                        .pickerStyle(.segmented).labelsHidden()
                    if mode == .github {
                        field("GitHub repository URL") {
                            TextField("https://github.com/owner/repo", text: $url).textFieldStyle(.roundedBorder)
                        }
                        Text("The Chief fetches the repo's README and file tree from GitHub (no login needed) and writes a SKILL.md tailored to it.")
                            .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    } else {
                        field("What should this skill do?") {
                            TextField("e.g. A skill that turns meeting notes into action items and follow-up emails…", text: $prompt, axis: .vertical)
                                .lineLimit(3...8).textFieldStyle(.roundedBorder)
                        }
                        field("Attachments (optional)") {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(files, id: \.self) { f in
                                    HStack {
                                        Image(systemName: "doc").font(.system(size: 10)).foregroundStyle(.secondary)
                                        Text(f.lastPathComponent).font(.system(size: 11)).lineLimit(1)
                                        Spacer()
                                        Button { files.removeAll { $0 == f } } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 12)) }
                                            .buttonStyle(.plain).foregroundStyle(.tertiary).disabled(busy)
                                    }.padding(.horizontal, 8).padding(.vertical, 5).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 7))
                                }
                                Button { pickFiles() } label: { Label("Add files…", systemImage: "paperclip") }.buttonStyle(.bordered).controlSize(.small).disabled(busy)
                                Text("Images, text, markdown, PDF, CSV and code files. Videos are not supported yet.")
                                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                            }
                        }
                    }
                    if let err {
                        HStack(spacing: 6) { Image(systemName: "xmark.circle.fill"); Text(err) }.font(.system(size: 11)).foregroundStyle(.red)
                    }
                    if busy {
                        HStack(spacing: 8) { ProgressView().controlSize(.small); Text(step).font(.system(size: 11)).foregroundStyle(.secondary) }
                    }
                }.padding(18)
            }
            Rectangle().fill(Color.primary.opacity(0.07)).frame(height: 1)
            HStack {
                if ai.active == nil {
                    Label("Connect an AI provider first", systemImage: "cpu").font(.system(size: 11)).foregroundStyle(.orange)
                    Button("Open providers") { dismiss(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { ai.showSettings = true } }
                        .buttonStyle(.bordered).controlSize(.small)
                }
                Spacer()
                Button { run() } label: {
                    HStack(spacing: 6) { if busy { ProgressView().controlSize(.mini) }; Text("Create skill") }
                }.buttonStyle(.borderedProminent).disabled(!canRun || busy)
            }.padding(14)
        }
        .frame(width: 560, height: 540)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { mode = ai.createMode; err = nil }
    }

    private func field<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            content()
        }
    }

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.text, .plainText, .pdf, .json, .xml, .png, .jpeg, .heic, .tiff, .gif, .sourceCode]
        panel.message = "Images, documents, text and code — videos are not supported."
        if panel.runModal() == .OK {
            for u in panel.urls where !files.contains(u) { files.append(u) }
        }
    }

    @MainActor private func run() {
        guard let provider = ai.active else { return }
        busy = true; err = nil
        Task {
            defer { busy = false; step = "" }
            do {
                let folder: URL
                let name: String
                if mode == .github {
                    step = "Fetching repository from GitHub…"
                    let repo = try await AIGen.fetchRepo(url)
                    step = "Writing SKILL.md with \(provider.modelID)…"
                    let raw = try await AIGen.completeSkill(provider: provider, task: AIGen.githubPrompt(repo))
                    let fallback = repo.slug.split(separator: "/").last.map(String.init) ?? "repo-skill"
                    let md = AIGen.skillMarkdown(from: raw, fallbackName: fallback, fallbackDesc: repo.description.isEmpty ? "Skill for working with \(repo.slug)" : repo.description)
                    (folder, name) = try AIGen.writeSkill(library: model.library, content: md)
                } else {
                    step = "Reading attachments…"
                    let atts = try AIGen.loadAttachments(files)
                    let built = AIGen.promptContent(prompt: prompt, attachments: atts)
                    step = "Writing SKILL.md with \(provider.modelID)…"
                    var raw: String
                    do {
                        raw = try await AIGen.completeSkill(provider: provider, task: built.content)
                    } catch {
                        guard built.hasImages else { throw error }
                        // Model rejected image parts — retry with text only.
                        raw = try await AIGen.complete(provider: provider, system: AIGen.systemPrompt,
                                                       content: built.textOnly + "\n\nNote: the attached images could not be sent to this model — mention any image-only details as placeholders.")
                    }
                    let md = AIGen.skillMarkdown(from: raw, fallbackName: "ai-skill", fallbackDesc: String(prompt.prefix(90)))
                    (folder, name) = try AIGen.writeSkill(library: model.library, content: md)
                }
                model.refresh(select: folder)
                model.status = "The Chief created \"\(name)\"."
                dismiss()
            } catch {
                self.err = error.localizedDescription
            }
        }
    }
}

// MARK: - End-to-end self test (launch the binary with SKILLCANVAS_GENTEST=1)

@MainActor enum AIGenSelfTest {
    static func run(ai: AIModel, model: AppModel) {
        Task {
            let log = URL(fileURLWithPath: "/private/var/folders/nc/k_wj79mj0jz_fv0hwzlm4l3h0000gn/T/opencode/gentest.log")
            try? Data().write(to: log) // truncate
            func w(_ s: String) {
                guard let data = (s + "\n").data(using: .utf8), let h = FileHandle(forWritingAtPath: log.path) else { return }
                h.seekToEndOfFile()
                h.write(data)
                try? h.close()
            }
            w("== SkillCanvas AI generation self-test ==")
            guard let provider = ai.active else { w("FAIL: no active provider"); return }
            w("provider: \(provider.name) model: \(provider.modelID)")
            do {
                w("[1] github: fetching octocat/Spoon-Knife…")
                let repo = try await AIGen.fetchRepo("https://github.com/octocat/Spoon-Knife")
                w("    branch=\(repo.branch) tree=\(repo.tree.count) readme=\(repo.readme.count) chars")
                w("[1] github: generating SKILL.md…")
                let raw = try await AIGen.completeSkill(provider: provider, task: AIGen.githubPrompt(repo))
                w("    raw head: " + String(raw.prefix(300)).replacingOccurrences(of: "\n", with: " | "))
                let md = AIGen.skillMarkdown(from: raw, fallbackName: "spoon-knife", fallbackDesc: "test")
                guard md.hasPrefix("---") else { w("FAIL: no frontmatter"); return }
                let (folder, name) = try AIGen.writeSkill(library: model.library, content: md)
                w("    wrote \(folder.lastPathComponent) name=\(name) md=\(md.count) chars")
                let saved = (try? String(contentsOf: folder.appendingPathComponent("SKILL.md"), encoding: .utf8)) ?? ""
                guard saved.hasPrefix("---") else { w("FAIL: file missing"); return }
                w("[1] PASS")
                w("[2] prompt+files: generating from a temp markdown file…")
                let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("gentest-notes.md")
                try "# Meeting notes\n- ship the sidebar toggle\n- add AI create sheet".write(to: tmp, atomically: true, encoding: .utf8)
                let atts = try AIGen.loadAttachments([tmp])
                let built = AIGen.promptContent(prompt: "A skill that turns meeting notes into action items", attachments: atts)
                let raw2 = try await AIGen.completeSkill(provider: provider, task: built.content)
                let md2 = AIGen.skillMarkdown(from: raw2, fallbackName: "meeting-notes", fallbackDesc: "test")
                let (folder2, name2) = try AIGen.writeSkill(library: model.library, content: md2)
                w("    wrote \(folder2.lastPathComponent) name=\(name2) md=\(md2.count) chars")
                w("[2] PASS")
                w("TEST PASS")
                model.refresh()
            } catch {
                w("FAIL: \(error.localizedDescription)")
            }
        }
    }
}
