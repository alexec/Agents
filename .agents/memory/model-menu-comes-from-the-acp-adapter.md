---
name: model-menu-comes-from-the-acp-adapter
description: A missing or mislabelled model in the app's start form is almost always the globally installed ACP adapter lagging, not our OptionCache.
metadata:
  type: project
---

The model menu's contents come from `npx -y @agentclientprotocol/claude-agent-acp`, which
resolves to the **global npm install** if one exists (`npm ls -g --depth=0`) — so it never
lands in the npx cache and never auto-updates. That adapter pins
`@anthropic-ai/claude-agent-sdk`, which vendors its own Claude Code binary; its version and
build date are in `node_modules/@anthropic-ai/claude-agent-sdk/manifest.json`. That vendored
binary, not the `claude` on PATH, decides what models the app offers.

On 2026-09-24 the menu still said "Opus 5" a day after Opus 5.5 shipped. Chain: adapter
0.78.0 → SDK 0.3.270 → Claude Code 2.1.270 (built 2026-09-12), which predates Opus 5.5.
`npm i -g @agentclientprotocol/claude-agent-acp@latest` (0.81.2 → Claude Code 2.1.280) fixed
it, confirmed by a fresh `session/new` advertising "Opus 5.5".

**Why:** three caches sit in this path and only one is ours. Claude Code keeps per-surface
model catalogs in `~/.claude/cache/model-catalog/` — the interactive CLI is surface `cc`, the
ACP adapter is `ccd`. A `cc` file refreshing daily while `ccd` sits days old is the tell that
the adapter is stale rather than the server withholding a model; the signed `published-*.json`
lists both surfaces, so you can check whether the server already offers it to `ccd`.

**How to apply:** before suspecting [[option-cache-never-expires]], check `savedAt` in
`~/Library/Application Support/Agents/option-cache.json` — if it is recent, the runtime really
did say that, and the adapter is where to look. Probe it directly rather than guessing: spawn
the adapter, send `initialize` (`protocolVersion: 1`) then `session/new` with a plain `cwd`
path, and read `configOptions`. Strip `CLAUDE_*` from the environment first so this session's
CLI does not leak in, but never `env -i` — see [[driving-agentsd-by-hand]]. No need to clear
our cache afterwards: `settleDraft` refreshes behind the next start form and broadcasts
`draftOptions` when the offers have moved. Deleting `option-cache.json` under a live daemon
does nothing anyway — `rememberedOptions` is read from disk once per process and rewritten
whole on the next save.
