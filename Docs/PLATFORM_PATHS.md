# Platform paths and package formats

## Local skills
- Antigravity global skills: `~/.gemini/config/skills/<skill-folder>/SKILL.md`
- OpenCode global skills: `~/.config/opencode/skills/<skill-folder>/SKILL.md`

SkillCanvas copies skill folders only after explicit user action. It refuses to overwrite existing destination folders.

## ChatGPT/Codex package
Exports a portable plugin folder with `plugin.json` and `skills/<skill-folder>/SKILL.md`. Use a supported plugin workflow for your account/workspace. SkillCanvas does not log in or publish remotely.

## Gemini Gem starter package
Exports `SKILL.md` and manual setup instructions. This is not an automatic cloud installation; configure the Gem in Gemini and upload/reference files where the product supports them.

## Safety
Imported skill scripts are never executed by SkillCanvas. Inspect third-party instructions and scripts before enabling them in an agent with access to your terminal, files, or browser.
