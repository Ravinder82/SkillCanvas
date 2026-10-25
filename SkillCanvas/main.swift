import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct SkillItem: Identifiable, Hashable {
    let id: UUID
    var name: String
    var description: String
    var folder: URL
    var updated: Date
    init(name: String, description: String, folder: URL, updated: Date = .now) { self.id = UUID(); self.name = name; self.description = description; self.folder = folder; self.updated = updated }
}

enum InstallTarget: String, CaseIterable, Identifiable {
    case antigravity = "Antigravity", opencode = "OpenCode"
    var id: String { rawValue }
    var path: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch self {
        case .antigravity: return home.appendingPathComponent(".gemini/config/skills", isDirectory: true)
        case .opencode: return home.appendingPathComponent(".config/opencode/skills", isDirectory: true)
        }
    }
    var displayPath: String { path.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~") }
}

enum PackageKind { case chatGPT, gemini }

@MainActor final class AppModel: ObservableObject {
    @Published var skills: [SkillItem] = []
    @Published var selectedID: UUID?
    @Published var search = ""
    @Published var status: String?
    @Published var onboarding = !UserDefaults.standard.bool(forKey: "skillcanvas.onboarded")
    let base: URL
    let library: URL
    init() {
        base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("SkillCanvas", isDirectory: true)
        library = base.appendingPathComponent("Library", isDirectory: true)
        try? FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        refresh()
    }
    var selected: SkillItem? { skills.first { $0.id == selectedID } }
    var filtered: [SkillItem] { search.isEmpty ? skills : skills.filter { $0.name.localizedCaseInsensitiveContains(search) || $0.description.localizedCaseInsensitiveContains(search) } }
    func finishOnboarding() { UserDefaults.standard.set(true, forKey: "skillcanvas.onboarded"); onboarding = false }
    func refresh(select path: URL? = nil) {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: library, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? []
        skills = dirs.filter { $0.hasDirectoryPath && FileManager.default.fileExists(atPath: $0.appendingPathComponent("SKILL.md").path) }.map { folder in
            let text = (try? String(contentsOf: folder.appendingPathComponent("SKILL.md"), encoding: .utf8)) ?? ""
            let meta = Self.metadata(text, fallback: folder.lastPathComponent)
            let date = (try? folder.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .now
            return SkillItem(name: meta.0, description: meta.1, folder: folder, updated: date)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if let path, let item = skills.first(where: { $0.folder == path }) { selectedID = item.id }
        if selectedID == nil || !skills.contains(where: { $0.id == selectedID }) { selectedID = skills.first?.id }
    }
    static func metadata(_ text: String, fallback: String) -> (String, String) {
        var name = fallback, desc = "Reusable AI-agent workflow"
        let lines = text.components(separatedBy: .newlines)
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---" {
            for line in lines.dropFirst() { if line.trimmingCharacters(in: .whitespaces) == "---" { break }; if line.hasPrefix("name:") { name = line.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }; if line.hasPrefix("description:") { desc = line.dropFirst(12).trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) } }
        }
        return (name, desc)
    }
    func createSkill() {
        let folder = uniqueFolder("new-skill")
        let body = """
---
name: new-skill
description: Describe the reusable task this skill helps an AI agent complete.
---

# New Skill

## When to use
Use this skill when the user asks for the task described above.

## Workflow
1. Understand the desired outcome and constraints.
2. Follow a clear, repeatable workflow.
3. Verify important details before reporting completion.

## Output
Describe the expected final output and quality checks.
"""
        do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true); try body.write(to: folder.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8); refresh(select: folder); status = "Draft created. Edit SKILL.md and replace its example instructions." } catch { status = error.localizedDescription }
    }
    func importSkill() {
        let panel = NSOpenPanel(); panel.title = "Import skill folder"; panel.message = "Choose a folder containing SKILL.md."; panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let source = panel.url else { return }
        guard FileManager.default.fileExists(atPath: source.appendingPathComponent("SKILL.md").path) else { status = "Import rejected: selected folder does not contain SKILL.md."; return }
        let dest = uniqueFolder(source.lastPathComponent)
        do { try FileManager.default.copyItem(at: source, to: dest); refresh(select: dest); status = "Imported. Review skill instructions and scripts before installing." } catch { status = "Import failed: \(error.localizedDescription)" }
    }
    func saveEditor(_ text: String) {
        guard let item = selected else { return }
        do { try text.write(to: item.folder.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8); refresh(select: item.folder); status = "Skill saved." } catch { status = "Save failed: \(error.localizedDescription)" }
    }
    func install(_ targets: Set<InstallTarget>) {
        guard let item = selected else { status = "Select a skill first."; return }
        do {
            for target in targets {
                try FileManager.default.createDirectory(at: target.path, withIntermediateDirectories: true)
                let dest = target.path.appendingPathComponent(item.folder.lastPathComponent, isDirectory: true)
                guard !FileManager.default.fileExists(atPath: dest.path) else { throw NSError(domain: "SkillCanvas", code: 1, userInfo: [NSLocalizedDescriptionKey: "Install stopped: a folder already exists at \(dest.path). Nothing was overwritten."]) }
                try FileManager.default.copyItem(at: item.folder, to: dest)
            }
            status = "Installed to \(targets.map(\.rawValue).sorted().joined(separator: " and ")). Restart or refresh the target IDE if needed."
        } catch { status = error.localizedDescription }
    }
    func export(_ kind: PackageKind) {
        guard let item = selected else { status = "Select a skill first."; return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.zip]; panel.nameFieldStringValue = "\(slug(item.name))-\(kind == .chatGPT ? "chatgpt-plugin" : "gemini-gem").zip"
        guard panel.runModal() == .OK, let out = panel.url else { return }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("SkillCanvas-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: temp) }
            let root: URL
            if kind == .chatGPT {
                root = temp.appendingPathComponent(slug(item.name), isDirectory: true)
                let skills = root.appendingPathComponent("skills", isDirectory: true)
                try FileManager.default.createDirectory(at: skills, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: item.folder, to: skills.appendingPathComponent(item.folder.lastPathComponent, isDirectory: true))
                let manifest: [String: Any] = ["$schema": "https://agent-plugins.org/schemas/1.0.0/plugin.schema.json", "name": slug(item.name), "version": "1.0.0", "description": item.description]
                let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]); try data.write(to: root.appendingPathComponent("plugin.json"))
                try "# \(item.name)\n\nSkillCanvas prepared this portable plugin bundle. Use a supported ChatGPT/Codex plugin workflow to import or publish it. Account and workspace support may vary.\n".write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
            } else {
                root = temp.appendingPathComponent("Gemini-Gem-\(slug(item.name))", isDirectory: true)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: item.folder, to: root.appendingPathComponent("skill-files", isDirectory: true))
                let guide = """
# Configure this skill as a Gemini Gem

This ZIP is a preparation bundle, not automatic cloud installation.

1. Open Gemini and create or edit a Gem.
2. Adapt the `skill-files/\(item.folder.lastPathComponent)/SKILL.md` instructions to the Gem instruction field.
3. Add supported reference files from `skill-files/` if useful.
4. Test with a realistic prompt and refine the instructions.

Skill: \(item.name)
Description: \(item.description)

Do not upload secrets or unreviewed executable files.
"""
                try guide.write(to: root.appendingPathComponent("GEMINI_SETUP.md"), atomically: true, encoding: .utf8)
            }
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto"); p.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", root.path, out.path]; try p.run(); p.waitUntilExit(); guard p.terminationStatus == 0 else { throw NSError(domain: "SkillCanvas", code: 2, userInfo: [NSLocalizedDescriptionKey: "macOS ZIP export failed."]) }
            status = "Exported \(kind == .chatGPT ? "ChatGPT/Codex plugin" : "Gemini Gem starter") ZIP. It has not been uploaded to a cloud account."
        } catch { status = "Export failed: \(error.localizedDescription)" }
    }
    private func uniqueFolder(_ name: String) -> URL { var url = library.appendingPathComponent(name, isDirectory: true); var n = 2; while FileManager.default.fileExists(atPath: url.path) { url = library.appendingPathComponent("\(name)-\(n)", isDirectory: true); n += 1 }; return url }
    private func slug(_ value: String) -> String { let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-")); let parts = value.lowercased().unicodeScalars.map { allowed.contains($0) ? String($0) : "-" }; return parts.joined().split(separator: "-").joined(separator: "-").prefix(64).description.trimmingCharacters(in: CharacterSet(charactersIn: "-")) }
}

@main struct SkillCanvasApp: App {
    @StateObject private var model = AppModel()
    var body: some Scene { WindowGroup { MainView().frame(minWidth: 980, minHeight: 650).sheet(isPresented: $model.onboarding) { OnboardingView().environmentObject(model) }.environmentObject(model) }.windowStyle(.hiddenTitleBar).commands { CommandGroup(replacing: .newItem) { Button("New Skill") { model.createSkill() }.keyboardShortcut("n", modifiers: .command) } } }
}

enum Page: String, CaseIterable { case overview = "Overview", library = "Skill Library", installs = "Local Installs", packages = "Cloud Packages", settings = "Settings"; var icon: String { switch self { case .overview: "square.grid.2x2.fill"; case .library: "square.stack.3d.up.fill"; case .installs: "desktopcomputer"; case .packages: "shippingbox.fill"; case .settings: "gearshape.fill" } } }

struct MainView: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var ai = AIModel()
    @State private var page: Page = .overview
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) { AppIconImage(size: 38); VStack(alignment: .leading, spacing: 1) { Text("SkillCanvas").font(.system(size: 16, weight: .bold)); Text("AI capability studio").font(.system(size: 10)).foregroundStyle(.secondary) } }.padding(.horizontal, 17).padding(.top, 25).padding(.bottom, 25)
                Text("WORKSPACE").font(.system(size: 10, weight: .bold)).tracking(1.2).foregroundStyle(.tertiary).padding(.horizontal, 20).padding(.bottom, 5)
                ForEach(Page.allCases.filter { $0 != .settings }, id: \.self) { p in Button { page = p } label: { HStack(spacing: 12) { Image(systemName: p.icon).frame(width: 18); Text(p.rawValue); Spacer() }.font(.system(size: 13, weight: page == p ? .semibold : .medium)).foregroundStyle(page == p ? .white : Color.primary.opacity(0.78)).padding(.horizontal, 12).padding(.vertical, 10).background { if page == p { RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.gradient) } } }.buttonStyle(.plain).padding(.horizontal, 10) }
                Spacer()
                VStack(alignment: .leading, spacing: 8) { Label("Local-first by design", systemImage: "lock.shield").font(.system(size: 11, weight: .medium)); Text("Your library stays on this Mac. Install and export only when you choose.").font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }.padding(13).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12)).padding(12)
                Button { page = .settings } label: { Label("Settings", systemImage: "gearshape").font(.system(size: 12, weight: .medium)).frame(maxWidth: .infinity, alignment: .leading).padding(12) }.buttonStyle(.plain).padding(.horizontal, 8).padding(.bottom, 12)
            }.frame(width: 220).background(Color(nsColor: .underPageBackgroundColor)).overlay(alignment: .trailing) { Rectangle().fill(Color.primary.opacity(0.07)).frame(width: 1) }
            ZStack { Color(nsColor: .windowBackgroundColor); switch page { case .overview: DashboardView(page: $page); case .library: LibraryView(); case .installs: InstallsView(); case .packages: PackagesView(); case .settings: SettingsView() } }
        }.overlay(alignment: .bottom) { if let message = model.status { HStack(spacing: 9) { Image(systemName: "info.circle.fill").foregroundStyle(.blue); Text(message).font(.system(size: 11, weight: .medium)); Spacer(); Button { model.status = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain) }.padding(12).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)).padding(15).transition(.move(edge: .bottom).combined(with: .opacity)) } }.animation(.easeInOut(duration: 0.2), value: model.status).overlay { AIChatLayer().environmentObject(ai).environmentObject(model) }.onAppear { ai.app = model }
    }
}

struct DashboardView: View {
    @EnvironmentObject var model: AppModel; @Binding var page: Page
    var body: some View { ScrollView { VStack(alignment: .leading, spacing: 23) {
        HStack(alignment: .top) { VStack(alignment: .leading, spacing: 6) { Text("Your AI capability studio").font(.system(size: 27, weight: .bold, design: .rounded)); Text("Build once. Install locally. Package for the cloud.").font(.system(size: 13)).foregroundStyle(.secondary) }; Spacer(); Button { model.createSkill(); page = .library } label: { Label("New Skill", systemImage: "plus").font(.system(size: 12, weight: .semibold)).padding(.horizontal, 13).padding(.vertical, 9) }.buttonStyle(.borderedProminent) }
        HStack(spacing: 20) { VStack(alignment: .leading, spacing: 11) { Label("READY TO ORGANIZE", systemImage: "circle.fill").font(.system(size: 9, weight: .bold)).tracking(1.2).foregroundStyle(.white.opacity(0.75)); Text("Turn your best workflows\ninto reusable capabilities.").font(.system(size: 23, weight: .bold, design: .rounded)).foregroundStyle(.white); Text("One calm workspace for local AI IDE skills and portable cloud packages.").font(.system(size: 12)).foregroundStyle(.white.opacity(0.78)).frame(maxWidth: 430, alignment: .leading); Button { page = .library } label: { Label("Explore Skill Library", systemImage: "arrow.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white).padding(10).background(.white.opacity(0.16), in: Capsule()) }.buttonStyle(.plain) }; Spacer(); ZStack { Circle().fill(.white.opacity(0.10)).frame(width: 152, height: 152); Circle().stroke(.white.opacity(0.20), lineWidth: 1).frame(width: 132, height: 132); AppIconImage(size: 116) }.padding(.trailing, 14) }.padding(24).background(LinearGradient(colors: [Color(red: 0.28, green: 0.23, blue: 0.67), Color(red: 0.22, green: 0.51, blue: 0.72)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 20))
        HStack(spacing: 12) { metric("\(model.skills.count)", "Skills in library", "square.stack.3d.up.fill", .purple); metric("2", "Local targets", "desktopcomputer", .teal); metric("2", "Cloud package formats", "shippingbox.fill", .orange) }
        VStack(alignment: .leading, spacing: 12) { Text("Quick actions").font(.system(size: 16, weight: .bold)); HStack(spacing: 12) { action("Import a skill", "Bring a folder with SKILL.md", "square.and.arrow.down", .blue) { model.importSkill(); page = .library }; action("Install locally", "Antigravity + OpenCode", "desktopcomputer", .teal) { page = .installs }; action("Prepare package", "Export a portable ZIP", "shippingbox", .orange) { page = .packages } } }
        VStack(alignment: .leading, spacing: 11) { HStack { Text("Skill library").font(.system(size: 16, weight: .bold)); Spacer(); Button("View all") { page = .library }.buttonStyle(.link) }; if model.skills.isEmpty { EmptyState(icon: "sparkles", title: "Your canvas is ready", message: "Import an existing skill or create your first one.") } else { ForEach(model.skills.prefix(4)) { item in Button { model.selectedID = item.id; page = .library } label: { HStack(spacing: 11) { Image(systemName: "puzzlepiece.extension.fill").foregroundStyle(.purple).frame(width: 37, height: 37).background(.purple.opacity(0.1), in: RoundedRectangle(cornerRadius: 10)); VStack(alignment: .leading, spacing: 3) { Text(item.name).font(.system(size: 12, weight: .semibold)).foregroundStyle(.primary); Text(item.description).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1) }; Spacer(); Image(systemName: "arrow.up.right").foregroundStyle(.tertiary) }.padding(10).background(.background, in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(.primary.opacity(0.06))) }.buttonStyle(.plain) } } }
    }.padding(28) } }
    func metric(_ value: String, _ title: String, _ icon: String, _ tint: Color) -> some View { VStack(alignment: .leading, spacing: 10) { Image(systemName: icon).foregroundStyle(tint).frame(width: 30, height: 30).background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 9)); Text(value).font(.system(size: 24, weight: .bold, design: .rounded)); Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary) }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(.background, in: RoundedRectangle(cornerRadius: 14)).overlay(RoundedRectangle(cornerRadius: 14).stroke(.primary.opacity(0.06))) }
    func action(_ title: String, _ detail: String, _ icon: String, _ tint: Color, run: @escaping () -> Void) -> some View { Button(action: run) { VStack(alignment: .leading, spacing: 8) { Image(systemName: icon).font(.system(size: 17)).foregroundStyle(tint).frame(width: 35, height: 35).background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10)); Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.primary); Text(detail).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.leading) }.frame(maxWidth: .infinity, alignment: .leading).padding(13).background(.background, in: RoundedRectangle(cornerRadius: 13)).overlay(RoundedRectangle(cornerRadius: 13).stroke(.primary.opacity(0.06))) }.buttonStyle(.plain) }
}

struct LibraryView: View {
    @EnvironmentObject var model: AppModel
    @State private var editing = false; @State private var text = ""; @State private var installSheet = false; @State private var targets: Set<InstallTarget> = Set(InstallTarget.allCases); @State private var exportDialog = false
    var body: some View { HStack(spacing: 0) {
        VStack(alignment: .leading, spacing: 13) { HStack { Text("Skill Library").font(.system(size: 20, weight: .bold, design: .rounded)); Spacer(); Button { model.createSkill() } label: { Image(systemName: "plus").padding(7).background(.purple.opacity(0.12), in: Circle()) }.buttonStyle(.plain) }; TextField("Search skills", text: $model.search).textFieldStyle(.roundedBorder); Button { model.importSkill() } label: { Label("Import folder…", systemImage: "square.and.arrow.down").font(.system(size: 11)) }.buttonStyle(.plain).foregroundStyle(.secondary); ScrollView { VStack(spacing: 5) { ForEach(model.filtered) { item in Button { model.selectedID = item.id } label: { HStack(spacing: 9) { Image(systemName: "puzzlepiece.extension.fill").foregroundStyle(.purple).frame(width: 29, height: 29).background(.purple.opacity(0.1), in: RoundedRectangle(cornerRadius: 8)); VStack(alignment: .leading, spacing: 3) { Text(item.name).font(.system(size: 11, weight: .semibold)).lineLimit(1); Text(item.description).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(2) }; Spacer(minLength: 0) }.padding(8).background(model.selectedID == item.id ? Color.accentColor.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 9)) }.buttonStyle(.plain) } } }; Spacer() }.padding(16).frame(width: 255).background(Color(nsColor: .underPageBackgroundColor)); Rectangle().fill(.primary.opacity(0.07)).frame(width: 1)
        if let item = model.selected { ScrollView { VStack(alignment: .leading, spacing: 18) { HStack(alignment: .top) { VStack(alignment: .leading, spacing: 7) { Label("SKILL PACKAGE", systemImage: "puzzlepiece.extension.fill").font(.system(size: 9, weight: .bold)).tracking(1).foregroundStyle(.secondary); Text(item.name).font(.system(size: 25, weight: .bold, design: .rounded)); Text(item.description).font(.system(size: 12)).foregroundStyle(.secondary) }; Spacer(); Button("Edit SKILL.md", systemImage: "pencil") { text = (try? String(contentsOf: item.folder.appendingPathComponent("SKILL.md"), encoding: .utf8)) ?? ""; editing = true }.buttonStyle(.bordered) }; HStack { Button { installSheet = true } label: { Label("Install Locally", systemImage: "desktopcomputer").frame(maxWidth: .infinity).padding(.vertical, 6) }.buttonStyle(.borderedProminent); Button { exportDialog = true } label: { Label("Prepare Cloud Package", systemImage: "shippingbox").frame(maxWidth: .infinity).padding(.vertical, 6) }.buttonStyle(.bordered) }; VStack(alignment: .leading, spacing: 9) { Text("Package contents").font(.system(size: 14, weight: .bold)); Label("SKILL.md instructions and trigger description", systemImage: "doc.text"); Label("Optional references, assets, and scripts", systemImage: "folder"); Label("SkillCanvas never executes imported scripts", systemImage: "checkmark.shield").foregroundStyle(.secondary) }.font(.system(size: 11)).padding(15).frame(maxWidth: .infinity, alignment: .leading).background(.background, in: RoundedRectangle(cornerRadius: 13)); VStack(alignment: .leading, spacing: 9) { Text("SKILL.md preview").font(.system(size: 14, weight: .bold)); Text((try? String(contentsOf: item.folder.appendingPathComponent("SKILL.md"), encoding: .utf8)) ?? "Unreadable skill").font(.system(size: 10, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(13).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 11)) } }.padding(24) }.sheet(isPresented: $editing) { VStack(alignment: .leading, spacing: 12) { HStack { Text("Edit Skill").font(.system(size: 19, weight: .bold)); Spacer(); Button("Cancel") { editing = false }; Button("Save") { model.saveEditor(text); editing = false }.buttonStyle(.borderedProminent) }; TextEditor(text: $text).font(.system(size: 12, design: .monospaced)).padding(7).overlay(RoundedRectangle(cornerRadius: 8).stroke(.primary.opacity(0.1))) }.padding(18).frame(width: 690, height: 500).environmentObject(model) }.sheet(isPresented: $installSheet) { VStack(alignment: .leading, spacing: 15) { Text("Install skill locally").font(.system(size: 19, weight: .bold)); Text("Select destinations. Existing skill folders are never overwritten.").font(.system(size: 11)).foregroundStyle(.secondary); ForEach(InstallTarget.allCases) { target in Toggle(isOn: Binding(get: { targets.contains(target) }, set: { value in if value { targets.insert(target) } else { targets.remove(target) } })) { VStack(alignment: .leading, spacing: 4) { Text(target.rawValue).font(.system(size: 12, weight: .semibold)); Text(target.displayPath).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled) } }.toggleStyle(.checkbox) }; Spacer(); HStack { Spacer(); Button("Cancel") { installSheet = false }; Button("Install") { model.install(targets); installSheet = false }.buttonStyle(.borderedProminent).disabled(targets.isEmpty) } }.padding(22).frame(width: 500, height: 280).environmentObject(model) }.confirmationDialog("Export package", isPresented: $exportDialog, titleVisibility: .visible) { Button("ChatGPT / Codex Plugin ZIP") { model.export(.chatGPT) }; Button("Gemini Gem Starter ZIP") { model.export(.gemini) } } message: { Text("Packages are prepared locally. They are not automatically uploaded or installed in a cloud account.") }
        } else { EmptyState(icon: "square.stack.3d.up", title: "Your library starts here", message: "Create a skill or import a folder containing SKILL.md.").padding(24) }
    } }
}

struct InstallsView: View {
    @EnvironmentObject var model: AppModel
    var body: some View { ScrollView { VStack(alignment: .leading, spacing: 23) { VStack(alignment: .leading, spacing: 6) { Text("Local Installs").font(.system(size: 27, weight: .bold, design: .rounded)); Text("Copy compatible skills into your AI IDEs' global skill directories.").font(.system(size: 12)).foregroundStyle(.secondary) }; HStack(spacing: 13) { targetCard(.antigravity, "Google AI IDE", .blue, "Global skills shared across Antigravity workspaces."); targetCard(.opencode, "AI coding agent", .purple, "OpenCode discovers skills from its global config directory.") }; VStack(alignment: .leading, spacing: 10) { Text("Install workflow").font(.system(size: 15, weight: .bold)); Text("1. Import or create a skill in Skill Library.\n2. Review its SKILL.md and any scripts.\n3. Choose Install Locally and select one or both targets.\n4. Refresh or restart the target IDE if it does not detect the skill immediately.").font(.system(size: 12)).foregroundStyle(.secondary); Button("Open Skill Library") { model.status = "Select Skill Library in the sidebar, then choose a skill to install." }.buttonStyle(.bordered) }.padding(17).frame(maxWidth: .infinity, alignment: .leading).background(.background, in: RoundedRectangle(cornerRadius: 14)); Label("Safety: existing skill folders are never overwritten. Imported scripts are copied but never executed by SkillCanvas.", systemImage: "checkmark.shield.fill").font(.system(size: 11)).foregroundStyle(.secondary) }.padding(28) } }
    func targetCard(_ target: InstallTarget, _ subtitle: String, _ color: Color, _ note: String) -> some View { VStack(alignment: .leading, spacing: 12) { Image(systemName: target == .antigravity ? "paperplane.fill" : "terminal.fill").font(.system(size: 19)).foregroundStyle(color).frame(width: 42, height: 42).background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 12)); Text(target.rawValue).font(.system(size: 16, weight: .bold)); Text(subtitle).font(.system(size: 10)).foregroundStyle(.secondary); Text(target.displayPath).font(.system(size: 10, design: .monospaced)).padding(8).frame(maxWidth: .infinity, alignment: .leading).background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 7)).textSelection(.enabled); Text(note).font(.system(size: 10)).foregroundStyle(.secondary); Label("Supported destination", systemImage: "checkmark.circle.fill").font(.system(size: 10, weight: .medium)).foregroundStyle(.green) }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(.background, in: RoundedRectangle(cornerRadius: 14)).overlay(RoundedRectangle(cornerRadius: 14).stroke(.primary.opacity(0.06))) }
}

struct PackagesView: View {
    @EnvironmentObject var model: AppModel
    var body: some View { ScrollView { VStack(alignment: .leading, spacing: 22) { VStack(alignment: .leading, spacing: 6) { Text("Cloud Packages").font(.system(size: 27, weight: .bold, design: .rounded)); Text("Prepare portable bundles. No cloud login, upload, or publishing happens inside SkillCanvas.").font(.system(size: 12)).foregroundStyle(.secondary) }; HStack(spacing: 13) { card("sparkles", .green, "ChatGPT / Codex", "Agent Plugin bundle", "Creates a plugin.json manifest and a skills folder for supported plugin workflows.", "Export Plugin ZIP") { model.export(.chatGPT) }; card("diamond.fill", .blue, "Gemini", "Gem starter bundle", "Packages SKILL.md and setup instructions for you to configure a Gem manually.", "Export Gem ZIP") { model.export(.gemini) } }; VStack(alignment: .leading, spacing: 13) { Text("How it works").font(.system(size: 15, weight: .bold)); info("01", "Select a skill", "Review instructions and supporting files before export."); info("02", "Export a package", "SkillCanvas creates the platform-specific folder structure and ZIP locally."); info("03", "Finish in the platform", "Use the supported import/configuration flow. Availability depends on your account and workspace.") }.padding(17).frame(maxWidth: .infinity, alignment: .leading).background(.background, in: RoundedRectangle(cornerRadius: 14)); EmptyState(icon: "checkmark.shield", title: "You stay in control", message: "Exports happen on this Mac. SkillCanvas does not upload files or sign into cloud accounts.") }.padding(28) } }
    func card(_ icon: String, _ color: Color, _ title: String, _ subtitle: String, _ details: String, _ button: String, run: @escaping () -> Void) -> some View { VStack(alignment: .leading, spacing: 13) { Image(systemName: icon).font(.system(size: 22)).foregroundStyle(color).frame(width: 45, height: 45).background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 13)); Text(title).font(.system(size: 16, weight: .bold)); Text(subtitle).font(.system(size: 11, weight: .medium)).foregroundStyle(color); Text(details).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true); Spacer(minLength: 0); Button(action: run) { Label(button, systemImage: "arrow.down.to.line").frame(maxWidth: .infinity).padding(.vertical, 6) }.buttonStyle(.borderedProminent) }.padding(18).frame(maxWidth: .infinity, minHeight: 255, alignment: .topLeading).background(.background, in: RoundedRectangle(cornerRadius: 14)).overlay(RoundedRectangle(cornerRadius: 14).stroke(.primary.opacity(0.06))) }
    func info(_ n: String, _ title: String, _ text: String) -> some View { HStack(alignment: .top, spacing: 11) { Text(n).font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(.purple).frame(width: 27, height: 27).background(.purple.opacity(0.1), in: RoundedRectangle(cornerRadius: 7)); VStack(alignment: .leading, spacing: 4) { Text(title).font(.system(size: 11, weight: .semibold)); Text(text).font(.system(size: 10)).foregroundStyle(.secondary) } } }
}

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    var body: some View { ScrollView { VStack(alignment: .leading, spacing: 20) { Text("Settings").font(.system(size: 27, weight: .bold, design: .rounded)); VStack(alignment: .leading, spacing: 12) { Text("Local storage").font(.system(size: 14, weight: .bold)); Text(model.library.path).font(.system(size: 10, design: .monospaced)).textSelection(.enabled).foregroundStyle(.secondary); Label("Local-first; no telemetry or API keys required", systemImage: "lock.fill").font(.system(size: 11)).foregroundStyle(.green); Button("Show Library in Finder", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([model.library]) }.buttonStyle(.bordered) }.padding(17).frame(maxWidth: .infinity, alignment: .leading).background(.background, in: RoundedRectangle(cornerRadius: 14)); VStack(alignment: .leading, spacing: 10) { Text("Supported targets").font(.system(size: 14, weight: .bold)); Label("Antigravity global skills", systemImage: "checkmark.circle.fill"); Label("OpenCode global skills", systemImage: "checkmark.circle.fill"); Label("ChatGPT/Codex plugin ZIP export", systemImage: "checkmark.circle.fill"); Label("Gemini Gem starter ZIP export", systemImage: "checkmark.circle.fill"); Text("Cloud exports are prepared locally and require manual import/configuration in the relevant service.").font(.system(size: 10)).foregroundStyle(.secondary) }.font(.system(size: 11)).foregroundStyle(.green).padding(17).frame(maxWidth: .infinity, alignment: .leading).background(.background, in: RoundedRectangle(cornerRadius: 14)) }.padding(28) } }
}

struct OnboardingView: View {
    @EnvironmentObject var model: AppModel; @Environment(\.dismiss) var dismiss; @State private var page = 0
    let pages: [(String, String, String)] = [("Your AI skills, in one place", "A focused control center for reusable skills, local installs, and portable plugin packages.", "square.stack.3d.up.fill"), ("Install locally", "Copy compatible SKILL.md folders into Antigravity and OpenCode. Existing folders are never overwritten.", "desktopcomputer"), ("Package for the cloud", "Prepare a ChatGPT/Codex plugin ZIP or a Gemini Gem starter ZIP. You choose where and how to import it.", "shippingbox.fill")]
    var body: some View { VStack(spacing: 0) { HStack { Text("SKILLCANVAS").font(.system(size: 10, weight: .bold)).tracking(1.6).foregroundStyle(.secondary); Spacer(); Text("\(page + 1) / \(pages.count)").font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(.tertiary) }.padding(23); Spacer(); ZStack { Circle().fill(LinearGradient(colors: [.purple.opacity(0.14), .cyan.opacity(0.14)], startPoint: .topLeading, endPoint: .bottomTrailing)).frame(width: 120, height: 120); Image(systemName: pages[page].2).font(.system(size: 43, weight: .light)).foregroundStyle(LinearGradient(colors: [.purple, .cyan], startPoint: .topLeading, endPoint: .bottomTrailing)) }; Text(pages[page].0).font(.system(size: 24, weight: .bold, design: .rounded)).multilineTextAlignment(.center).padding(.top, 24); Text(pages[page].1).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 390).padding(.top, 10); Spacer(); HStack(spacing: 6) { ForEach(0..<pages.count, id: \.self) { i in Capsule().fill(i == page ? Color.accentColor : .primary.opacity(0.12)).frame(width: i == page ? 23 : 7, height: 7) } }; HStack { Button("Skip") { model.finishOnboarding(); dismiss() }.buttonStyle(.plain).foregroundStyle(.secondary); Spacer(); Button(page == pages.count - 1 ? "Open SkillCanvas" : "Continue") { if page == pages.count - 1 { model.finishOnboarding(); dismiss() } else { page += 1 } }.buttonStyle(.borderedProminent).controlSize(.large) }.padding(23) }.frame(width: 540, height: 470).background(Color(nsColor: .windowBackgroundColor)) }
}

struct EmptyState: View {
    let icon: String; let title: String; let message: String
    var body: some View { VStack(spacing: 8) { Image(systemName: icon).font(.system(size: 27)).foregroundStyle(.secondary); Text(title).font(.system(size: 13, weight: .semibold)); Text(message).font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 320) }.frame(maxWidth: .infinity).padding(27).background(.background, in: RoundedRectangle(cornerRadius: 14)).overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5, 4])).foregroundStyle(.primary.opacity(0.12))) }
}

struct AppIconImage: View {
    var size: CGFloat = 116
    var body: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .scaledToFill()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous).stroke(.white.opacity(0.22), lineWidth: max(1, size * 0.013)))
            .shadow(color: .black.opacity(0.30), radius: size * 0.086, y: size * 0.043)
    }
}
