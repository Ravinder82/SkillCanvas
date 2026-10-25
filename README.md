# SkillCanvas for macOS

**A simple skills + plugins management and control center.** Manage reusable AI-agent skills, install them into Antigravity and OpenCode, and prepare cloud packages for ChatGPT/Codex and Gemini.

## Included
- Native SwiftUI macOS app with onboarding and a polished dashboard
- Local skill library: create, import, edit, search, preview
- Safe local installation to Antigravity and OpenCode global skill paths
- ChatGPT/Codex plugin ZIP export (`plugin.json` + `skills/`)
- Gemini Gem starter ZIP export with setup guide
- Local-first storage; no API keys, network, telemetry, or paid services required

## Install
1. Unzip `SkillCanvas.zip`.
2. Open the `SkillCanvas` folder.
3. Double-click `INSTALL.command`.
4. If blocked, right-click the file and choose Open, or run `chmod +x INSTALL.command && ./INSTALL.command` in Terminal.

Requires macOS 14+ and Xcode Command Line Tools (`xcode-select --install`). The installer compiles the native app with `swiftc` and places it at `~/Applications/SkillCanvas.app`. No administrator privileges are required. This source bundle is not code-signed or notarized; macOS may show a first-run warning.

## First run
1. Launch SkillCanvas and complete onboarding.
2. Open Skill Library and create a new skill or import a folder containing `SKILL.md`.
3. Select **Install Locally** to copy it into Antigravity, OpenCode, or both.
4. Select **Prepare Cloud Package** to export a ChatGPT/Codex plugin ZIP or Gemini Gem starter ZIP.

## Notes
- Antigravity global skill path: `~/.gemini/config/skills/`
- OpenCode global skill path: `~/.config/opencode/skills/`
- ChatGPT/Codex packages are prepared locally and require supported platform import/install flows.
- Gemini exports are preparation bundles, not direct installation into a Gemini account.
- Existing skill folders are never overwritten. The app does not execute imported scripts.
- App data is stored under `~/Library/Application Support/SkillCanvas/Library/`.

## Project layout
- `SkillCanvas/main.swift` — native macOS application source
- `INSTALL.command` — builds and installs the app bundle
- `Examples/research-brief/` — sample skill
- `Docs/PLATFORM_PATHS.md` — target path and package notes
