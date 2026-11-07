---
name: where-each-agent-reads-plugins
description: "Project plugin folders, manifests and marketplace index files per agent (Claude, Codex, Grok, Cursor, Copilot, Antigravity, Gemini), read from shipped binaries 2026-09-25"
metadata:
  type: reference
  modified: 2026-09-26T05:57:19.692Z
---

Read from the installed binaries on 2026-09-25 (Claude 2.1.282, Codex pinned toolset, Grok 1.0.41, cursor-agent 2026.09.10, Copilot 1.0.86) plus Antigravity/Gemini docs.

- **Claude**: no project `.claude/plugins`. Loads any `<project>/.claude/skills/<dir>` holding a plugin as `name@skills-dir` (after trust). Otherwise `--plugin-dir`, `CLAUDE_CODE_PLUGIN_DIRS` (absolute paths), or SDK `plugins: [{type:"local", path}]` via ACP `_meta.claudeCode.options.plugins`. Manifest `.claude-plugin/plugin.json`; index `.claude-plugin/marketplace.json`; project `.claude/settings.json` `extraKnownMarketplaces` + `enabledPlugins`.
- **Grok**: `.grok/plugins/` and `.claude/plugins/` in the project (needs trust), `~/.grok/plugins/`, `~/.claude/plugins/`; ACP `_meta.pluginDirs` (absolute strings, auto-trusted). Manifest `.grok-plugin/plugin.json` or `.claude-plugin/plugin.json` or convention dirs.
- **Codex**: no automatic project folder. Its repo convention is `<repo>/.agents/plugins/marketplace.json`, which must be added with `codex plugin marketplace add`. Only `~/.agents/plugins/marketplace.json` is found automatically. Manifest `.codex-plugin/plugin.json` (also reads `.claude-plugin`/`.cursor-plugin`).
- **Cursor**: no project folder. Reads `~/.cursor/plugins/local/`, its marketplaces, and Claude's installed plugins. Manifest `.cursor-plugin/plugin.json` | `.claude-plugin/plugin.json` | `plugin.json`.
- **Copilot**: marketplaces only (loads repo-local marketplaces live). Index `.plugin/`, `.github/plugin/` or `.claude-plugin/marketplace.json`; honours `.claude/settings.json` `extraKnownMarketplaces`/`enabledPlugins`.
- **Antigravity**: `<project>/.agents/plugins/` natively, `~/.gemini/config/plugins/`; `plugin.json` at the plugin root.
- **Gemini CLI** (0.61.0, read from the cached npx bundle 2026-09-26, never run): extensions only in `~/.gemini/extensions` (`gemini-extension.json`; `gemini extensions install|link`; no project extensions folder) — an extension bundles mcpServers, GEMINI.md context, `commands/*.toml`, `hooks/hooks.json`, `skills/`, `agents/*.md`, `policies/*.toml`, themes, settings→env. Skills natively in `~/.agents/skills` and `<project>/.agents/skills` (beat `.gemini/skills` in the same tier). Subagents `.gemini/agents/*.md` / `~/.gemini/agents` only. Context defaults to GEMINI.md; AGENTS.md needs `context.fileName`. MCP in `.gemini/settings.json` / `~/.gemini/settings.json` `mcpServers`. ACP via `--acp` (`--experimental-acp` still listed).

Common denominator: `.claude-plugin/plugin.json` is read by Claude, Grok, Codex, Cursor and Copilot.

Measured 2026-09-25 with scratch homes (CODEX_HOME / HOME=tmp): ONE index at `.agents/plugins/marketplace.json` with string sources `./.agents/plugins/<x>`, plus a `.claude-plugin/marketplace.json` link to it, is accepted by `claude plugin validate`, `codex plugin marketplace add` + `plugin add` (installs from a `.claude-plugin`-only plugin), and `copilot plugin marketplace add` + `install` (loads live, no copy). Cursor: `plugin marketplace add` wants a git URL and an account; its ACP mode ignores `--plugin-dir` — unreachable without `~/.cursor/plugins/local`. Gemini manifest never checked by a real Gemini: Alex stopped the `npx @google/gemini-cli` run, so don't retry it unasked.

Merged to main as b6acb2e 2026-09-25 (2ad393b folder/link/Claude+Grok _meta handover, 0c00730 index + gemini-extension.json); branch and worktree deleted; not live until the next restart. See [[next-up-017-workflow-settings]].
