import Foundation

// JSON schemas advertised to the model. Keep names short and descriptions explicit.
enum ToolCatalog {
    static let definitions: [[String: Any]] = [
        tool("web_search", "Search the web keylessly. Returns top result titles, URLs and snippets. Use for current information, docs and references.", ["query": ["type": "string", "description": "Search query"]]),
        tool("fetch_page", "Download a URL and return its readable text (truncated). Use to read articles, documentation or GitHub pages found via web_search.", ["url": ["type": "string", "description": "Absolute http(s) URL to read"]]),
        tool("list_skills", "List every skill in the SkillCanvas library with its name and description.", [:]),
        tool("get_skill", "Read the full SKILL.md of one skill.", ["name": ["type": "string", "description": "Skill folder name"]]),
        tool("create_skill", "Create a new skill folder in the library with a SKILL.md. The library refreshes immediately.", [
            "name": ["type": "string", "description": "Folder slug, e.g. release-notes"],
            "description": ["type": "string", "description": "One-line description shown in the library"],
            "body": ["type": "string", "description": "Complete SKILL.md markdown including frontmatter"]
        ]),
        tool("update_skill", "Overwrite an existing skill's SKILL.md with new content.", [
            "name": ["type": "string", "description": "Skill folder name"],
            "body": ["type": "string", "description": "Complete new SKILL.md markdown"]
        ]),
        tool("search_library", "Search skills by keyword in name or description.", ["query": ["type": "string", "description": "Keyword"]]),
        tool("install_skill", "Copy a skill into local agent targets. Never overwrites an existing install.", [
            "name": ["type": "string", "description": "Skill folder name"],
            "targets": ["type": "array", "items": ["type": "string"], "description": "Subset of: Antigravity, OpenCode"]
        ]),
        tool("list_files", "List files and folders inside the skill library or an approved workspace folder.", [
            "path": ["type": "string", "description": "Path relative to the skill library, or absolute inside an approved root. Empty string = library root."]
        ]),
        tool("read_file", "Read a text file inside the skill library or an approved workspace folder.", [
            "path": ["type": "string", "description": "Path relative to the skill library, or absolute inside an approved root"]
        ]),
        tool("write_file", "Create or overwrite a text file inside the skill library or an approved workspace folder. Parent folders are created as needed.", [
            "path": ["type": "string", "description": "Path relative to the skill library, or absolute inside an approved root"],
            "content": ["type": "string", "description": "Full file content to write"]
        ]),
        tool("app_status", "Report SkillCanvas state: skill count, installed targets, provider info.", [:])
    ]

    private static func tool(_ name: String, _ desc: String, _ props: [String: Any]) -> [String: Any] {
        ["type": "function", "function": [
            "name": name,
            "description": desc,
            "parameters": ["type": "object", "properties": props, "required": props.isEmpty ? [] : Array(props.keys)]
        ]]
    }
}

@MainActor enum ToolExecutor {
    static func execute(call: ToolCall, model: AIModel) async -> ToolResult {
        let args = jsonArgs(call.arguments)
        func str(_ key: String) -> String { (args[key] as? String) ?? "" }
        do {
            switch call.name {
            case "web_search":
                return try await webSearch(str("query"))
            case "fetch_page":
                return try await fetchPage(str("url"))
            case "list_skills":
                return listSkills(model)
            case "get_skill":
                return try getSkill(model, name: str("name"))
            case "create_skill":
                return try createSkill(model, name: str("name"), description: str("description"), body: str("body"))
            case "update_skill":
                return try updateSkill(model, name: str("name"), body: str("body"))
            case "search_library":
                return searchLibrary(model, query: str("query"))
            case "install_skill":
                let targets = (args["targets"] as? [String]) ?? []
                return try installSkill(model, name: str("name"), targets: targets)
            case "list_files":
                return try listFiles(model, path: str("path"))
            case "read_file":
                return try readFile(model, path: str("path"))
            case "write_file":
                return try writeFile(model, path: str("path"), content: str("content"))
            case "app_status":
                return appStatus(model)
            default:
                return ToolResult(output: "Unknown tool: \(call.name)", summary: "Unknown tool \(call.name)")
            }
        } catch {
            return ToolResult(output: "Tool failed: \(error.localizedDescription)", summary: "Failed: \(error.localizedDescription)")
        }
    }

    private static func jsonArgs(_ raw: String) -> [String: Any] {
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return obj
    }

    private static func clip(_ s: String, _ limit: Int = 12000) -> String {
        s.count > limit ? String(s.prefix(limit)) + "\n…[truncated]" : s
    }

    // MARK: - Web (keyless)

    private static func webSearch(_ query: String) async throws -> ToolResult {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return ToolResult(output: "Empty query.", summary: "Empty query") }
        var comps = URLComponents(string: "https://html.duckduckgo.com/html/")!
        comps.queryItems = [URLQueryItem(name: "q", value: q)]
        var req = URLRequest(url: comps.url!)
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 20
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw NSError(domain: "web_search", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "Search endpoint returned \(http.statusCode)"])
        }
        let html = String(data: data, encoding: .utf8) ?? ""
        let results = parseDDG(html)
        if results.isEmpty {
            return ToolResult(output: "No results parsed for \"\(q)\". Try rephrasing the query or use fetch_page with a known URL.", summary: "No results for \(q)")
        }
        let text = results.prefix(8).enumerated().map { i, r in
            "\(i + 1). \(r.title)\n   URL: \(r.url)\n   \(r.snippet)"
        }.joined(separator: "\n")
        return ToolResult(output: clip("Results for \"\(q)\":\n\n\(text)"), summary: "\(results.count) results for \(q)")
    }

    private static func parseDDG(_ html: String) -> [(title: String, url: String, snippet: String)] {
        var out: [(String, String, String)] = []
        let linkRegex = try! NSRegularExpression(pattern: "class=\"result__a\"[^>]*href=\"([^\"]+)\"[^>]*>(.*?)</a>", options: [.dotMatchesLineSeparators])
        let snippetRegex = try! NSRegularExpression(pattern: "class=\"result__snippet\"[^>]*>(.*?)</a>", options: [.dotMatchesLineSeparators])
        func matches(_ rx: NSRegularExpression, _ s: String) -> [(String, String)] {
            let range = NSRange(s.startIndex..., in: s)
            return rx.matches(in: s, range: range).compactMap { m in
                guard m.numberOfRanges >= 2, let r = Range(m.range(at: 1), in: s) else { return nil }
                let second = m.numberOfRanges > 2 ? Range(m.range(at: 2), in: s) : nil
                return (String(s[r]), second.map { String(s[$0]) } ?? "")
            }
        }
        let links = matches(linkRegex, html)
        let snippets = matches(snippetRegex, html).map { stripTags($0.0) }
        for (i, pair) in links.enumerated() {
            var url = pair.0.replacingOccurrences(of: "&amp;", with: "&")
            if let components = URLComponents(string: url.hasPrefix("//") ? "https:\(url)" : url),
               let uddg = components.queryItems?.first(where: { $0.name == "uddg" })?.value {
                url = uddg
            }
            guard url.hasPrefix("http") else { continue }
            out.append((stripTags(pair.1), url, i < snippets.count ? clip(snippets[i], 300) : ""))
            if out.count >= 10 { break }
        }
        return out
    }

    private static func fetchPage(_ urlString: String) async throws -> ToolResult {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return ToolResult(output: "fetch_page needs an absolute http(s) URL.", summary: "Invalid URL")
        }
        var req = URLRequest(url: url)
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 25
        let (data, resp) = try await URLSession.shared.data(for: req)
        let mime = (resp as? HTTPURLResponse)?.mimeType ?? ""
        let raw = String(data: data, encoding: .utf8) ?? (String(data: data, encoding: .isoLatin1) ?? "")
        let text = mime.contains("html") || raw.hasPrefix("<") ? stripHTML(raw) : raw
        guard !text.isEmpty else { return ToolResult(output: "Could not read \(trimmed).", summary: "Fetch failed") }
        return ToolResult(output: clip(text), summary: "Read \(url.host ?? trimmed)")
    }

    private static func stripHTML(_ html: String) -> String {
        var s = html
        let patterns = ["<script[^>]*>[\\s\\S]*?</script>", "<style[^>]*>[\\s\\S]*?</style>", "<noscript[^>]*>[\\s\\S]*?</noscript>", "<head[^>]*>[\\s\\S]*?</head>"]
        for p in patterns { s = (try? NSRegularExpression(pattern: p, options: [.caseInsensitive])).map { rx in
            rx.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: " ") } ?? s }
        s = s.replacingOccurrences(of: "<br[^>]*>|</p>|</div>|</li>|</h[1-6]>|</tr>", with: "\n", options: .regularExpression)
        s = stripTags(s)
        s = s.replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'")
        s = s.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripTags(_ s: String) -> String {
        (try? NSRegularExpression(pattern: "<[^>]+>", options: [.dotMatchesLineSeparators]))
            .map { $0.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: " ") } ?? s
    }

    // MARK: - Skill library

    private static func listSkills(_ model: AIModel) -> ToolResult {
        guard let app = model.app else { return ToolResult(output: "Library not ready.", summary: "No library") }
        if app.skills.isEmpty { return ToolResult(output: "The skill library is empty.", summary: "Library empty") }
        let text = app.skills.map { "- \($0.name): \($0.description)" }.joined(separator: "\n")
        return ToolResult(output: "\(app.skills.count) skills:\n\(text)", summary: "Listed \(app.skills.count) skills")
    }

    private static func skillFolder(_ model: AIModel, name: String) throws -> URL {
        guard let app = model.app else { throw simple("Library not ready.") }
        let wanted = name.trimmingCharacters(in: .whitespaces)
        if let item = app.skills.first(where: { $0.folder.lastPathComponent == wanted || $0.name == wanted }) { return item.folder }
        let direct = app.library.appendingPathComponent(wanted)
        if FileManager.default.fileExists(atPath: direct.appendingPathComponent("SKILL.md").path) { return direct }
        throw simple("No skill named \"\(name)\". Use list_skills to see available names.")
    }

    private static func getSkill(_ model: AIModel, name: String) throws -> ToolResult {
        let folder = try skillFolder(model, name: name)
        let text = (try? String(contentsOf: folder.appendingPathComponent("SKILL.md"), encoding: .utf8)) ?? ""
        return ToolResult(output: clip("Skill \(folder.lastPathComponent):\n\n\(text)"), summary: "Read \(folder.lastPathComponent)/SKILL.md")
    }

    private static func createSkill(_ model: AIModel, name: String, description: String, body: String) throws -> ToolResult {
        guard let app = model.app else { throw simple("Library not ready.") }
        let slug = slugify(name)
        guard !slug.isEmpty else { throw simple("Provide a usable name.") }
        var folder = app.library.appendingPathComponent(slug, isDirectory: true)
        var n = 2
        while FileManager.default.fileExists(atPath: folder.path) {
            folder = app.library.appendingPathComponent("\(slug)-\(n)", isDirectory: true); n += 1
        }
        var md = body
        if md.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            md = "---\nname: \(slug)\ndescription: \(description.isEmpty ? "Describe this skill." : description)\n---\n\n# \(slug)\n\n## When to use\nDescribe the task.\n\n## Workflow\n1. Steps.\n"
        } else if !md.hasPrefix("---"), !description.isEmpty {
            md = "---\nname: \(slug)\ndescription: \(description)\n---\n\n\(md)"
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try md.write(to: folder.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        app.refresh(select: folder)
        return ToolResult(output: "Created skill \"\(folder.lastPathComponent)\" in the library.", summary: "Created \(folder.lastPathComponent)")
    }

    private static func updateSkill(_ model: AIModel, name: String, body: String) throws -> ToolResult {
        let folder = try skillFolder(model, name: name)
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw simple("body is required to update a skill.") }
        try body.write(to: folder.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        model.app?.refresh(select: folder)
        return ToolResult(output: "Updated \(folder.lastPathComponent)/SKILL.md.", summary: "Updated \(folder.lastPathComponent)")
    }

    private static func searchLibrary(_ model: AIModel, query: String) -> ToolResult {
        guard let app = model.app else { return ToolResult(output: "Library not ready.", summary: "No library") }
        let q = query.lowercased()
        let hits = app.skills.filter { $0.name.lowercased().contains(q) || $0.description.lowercased().contains(q) }
        if hits.isEmpty { return ToolResult(output: "No skills match \"\(query)\".", summary: "No matches") }
        return ToolResult(output: hits.map { "- \($0.name): \($0.description)" }.joined(separator: "\n"), summary: "\(hits.count) matches")
    }

    private static func installSkill(_ model: AIModel, name: String, targets: [String]) throws -> ToolResult {
        guard let app = model.app else { throw simple("Library not ready.") }
        let folder = try skillFolder(model, name: name)
        var chosen: [InstallTarget] = []
        for t in targets {
            let normalized = t.lowercased()
            if normalized.contains("gravity") { chosen.append(.antigravity) }
            if normalized.contains("opencode") { chosen.append(.opencode) }
        }
        if chosen.isEmpty { chosen = InstallTarget.allCases }
        var done: [String] = []
        for target in chosen {
            try FileManager.default.createDirectory(at: target.path, withIntermediateDirectories: true)
            let dest = target.path.appendingPathComponent(folder.lastPathComponent, isDirectory: true)
            if FileManager.default.fileExists(atPath: dest.path) {
                done.append("\(target.rawValue): already installed (not overwritten)")
                continue
            }
            try FileManager.default.copyItem(at: folder, to: dest)
            done.append("\(target.rawValue): installed")
        }
        app.refresh()
        return ToolResult(output: done.joined(separator: "\n"), summary: "Install: \(done.joined(separator: ", "))")
    }

    // MARK: - Scoped file access

    private static func roots(_ model: AIModel) -> [URL] {
        guard let app = model.app else { return [] }
        return [app.library] + model.workspaces.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    private static func resolve(_ model: AIModel, path raw: String) throws -> URL {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard let app = model.app else { throw simple("Library not ready.") }
        var candidate: URL
        if trimmed.isEmpty {
            candidate = app.library
        } else if trimmed.hasPrefix("/") {
            candidate = URL(fileURLWithPath: trimmed, isDirectory: false)
        } else {
            candidate = app.library.appendingPathComponent(trimmed)
        }
        let resolved = candidate.standardizedFileURL.resolvingSymlinksInPath()
        for root in roots(model) {
            let r = root.standardizedFileURL.resolvingSymlinksInPath()
            if resolved.path == r.path || resolved.path.hasPrefix(r.path + "/") { return resolved }
        }
        throw simple("Access refused: \"\(trimmed)\" is outside the skill library and approved workspace folders. Add the folder in Settings, or work inside the library.")
    }

    private static func listFiles(_ model: AIModel, path: String) throws -> ToolResult {
        let dir = try resolve(model, path: path)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir) else { throw simple("No such path: \(path)") }
        guard isDir.boolValue else {
            let text = (try? String(contentsOf: dir, encoding: .utf8)) ?? "(binary or unreadable)"
            return ToolResult(output: clip(text), summary: "Read \(dir.lastPathComponent)")
        }
        let items = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? [])
            .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
        if items.isEmpty { return ToolResult(output: "Directory is empty: \(dir.lastPathComponent)", summary: "Empty folder") }
        let lines = items.prefix(100).map { "- \($0.lastPathComponent)\(($0.path.contains("/") ? "" : ""))" }.joined(separator: "\n")
        return ToolResult(output: "\(items.count) entries in \(dir.path):\n\(lines)", summary: "Listed \(items.count) items")
    }

    private static func readFile(_ model: AIModel, path: String) throws -> ToolResult {
        let file = try resolve(model, path: path)
        guard FileManager.default.fileExists(atPath: file.path) else { throw simple("No such file: \(path)") }
        let text = (try? String(contentsOf: file, encoding: .utf8)) ?? (try? String(contentsOf: file, encoding: .isoLatin1)) ?? ""
        guard !text.isEmpty else { return ToolResult(output: "File is empty or binary: \(file.lastPathComponent)", summary: "Empty file") }
        return ToolResult(output: clip(text), summary: "Read \(file.lastPathComponent) (\(text.split(separator: "\n").count) lines)")
    }

    private static func writeFile(_ model: AIModel, path: String, content: String) throws -> ToolResult {
        guard !path.trimmingCharacters(in: .whitespaces).isEmpty else { throw simple("path is required.") }
        let file = try resolve(model, path: path)
        let dir = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try content.write(to: file, atomically: true, encoding: .utf8)
        if let app = model.app, file.path.hasPrefix(app.library.path) { app.refresh() }
        return ToolResult(output: "Wrote \(file.path) (\(content.count) chars).", summary: "Wrote \(file.lastPathComponent)")
    }

    private static func appStatus(_ model: AIModel) -> ToolResult {
        guard let app = model.app else { return ToolResult(output: "App not ready.", summary: "No app") }
        let installed = InstallTarget.allCases.filter { FileManager.default.fileExists(atPath: $0.path.path) }
        let provider = model.active.map { "\($0.name) (\($0.preset), model \($0.modelID))" } ?? "none connected"
        let lines = [
            "Skills in library: \(app.skills.count)",
            "Installed targets: \(installed.isEmpty ? "none yet" : installed.map(\.rawValue).joined(separator: ", "))",
            "Active provider: \(provider)",
            "Workspace folders: \(model.workspaces.isEmpty ? "none" : model.workspaces.joined(separator: ", "))"
        ]
        return ToolResult(output: lines.joined(separator: "\n"), summary: "Reported app status")
    }

    private static func slugify(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        let parts = value.lowercased().unicodeScalars.map { allowed.contains($0) ? String($0) : "-" }
        return parts.joined().split(separator: "-").joined(separator: "-").prefix(64).description.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    private static func simple(_ message: String) -> NSError {
        NSError(domain: "SkillCanvas.Tools", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
