# Data Model: One Set of Skills and Instructions for Every Agent

## PersonalLayout (the rule, static)

What the home layout is, as data, beside `DotAgents` for projects.

| Field | Value |
|---|---|
| `folder` | `.agents` under the home |
| `router` | `AGENTS.md` |
| `resourceFolders` | `skills`, `personas` |
| `runtimes` | `[RuntimeLinkRule]`, from research R1 |
| `mcpFile` | `mcp.json` |
| `pluginsFolder` | `plugins` |

## RuntimeLinkRule

| Field | Meaning |
|---|---|
| `runtimeID` | `claude`, `codex`, `grok`, `cursor`, `copilot`; Gemini has no rule until probed |
| `configFolder` | `.claude`, `.codex`, `.grok`, `.cursor`, `.copilot`: where its links go. A runtime gets links only when `RuntimeDiscovery.locate` finds it (the folder alone is not proof: Antigravity makes `~/.gemini`) |
| `readsSharedSkills` | true for Codex, Grok, Cursor, Copilot |
| `skillsFolder` | `.claude/skills` for Claude; nil for the others |
| `instructionsFile` | `.claude/CLAUDE.md`, `.codex/AGENTS.md`, `.grok/AGENTS.md`, `.copilot/copilot-instructions.md`; nil for Cursor |
| `adopts` | true for Claude only (R3) |
| `takesStdioServers` | false for Copilot only (R9): its stdio servers go through the bridge (R11) |
| `pluginHandover` | `sessionMeta` (Claude), `sessionMetaWithServers` (Grok), `codexMarketplace` (Codex), `extensionLink` (Gemini), `none` (Cursor, Copilot) — R12 |

`managed` names, never touched in any `skillsFolder`: `synced`, anything holding a `.bucket-*`
file or `.sync-manifest.json`.

## PlacedLinks (stored, `<root>/personal-layout.json`)

```json
{ "home": "/Users/alex", "codexPlugins": { "house-style": "9f2c…" }, "links": { ".claude/skills/grill-me": "../../.agents/skills/grill-me",
                                   ".claude/CLAUDE.md": "../.agents/AGENTS.md" } }
```

- A path is added when the app places a link there.
- A path in `links` with nothing on disk is one the person removed: not placed again.
- A path whose destination is a skill no longer in `~/.agents/skills` is dropped (with the
  dangling link, if still there), so the skill added again is linked again.
- A different `home` from the one being laid out resets the record.
- `codexPlugins`: `{ "<plugin>": "<fingerprint>" }`, the last fingerprint added to Codex (R12).
  A plugin whose fingerprint differs is added again; one missing from `~/.agents/plugins` is
  removed from Codex and dropped from here.
- Gemini extension links (`.gemini/extensions/<plugin>`) are recorded in `links` like skill
  links, so the same removed-stays-removed and dangling rules (FR-008, FR-009) apply.

## PersonalSkill (read model, for Settings ▸ Shared; see SharedSnapshot)

| Field | Meaning |
|---|---|
| `name` | folder name in `~/.agents/skills` |
| `path` | its absolute path, for Reveal in Finder |
| `runtimeIDs` | installed runtimes that see it: every installed `readsSharedSkills` runtime, plus Claude when `~/.claude/skills/<name>` resolves to it |
| `clash` | when Claude has its own different `~/.claude/skills/<name>`: that path; the shared one is then not what Claude uses |

Also listed: a skill that is only in `~/.claude/skills` because it clashed, with `runtimeIDs =
[claude]`, so nothing is hidden.

## Reconcile (state per step)

For each skill `s` in `~/.agents/skills`, for Claude when installed, at `p = .claude/skills/s`:

| On disk at `p` | Recorded? | Action |
|---|---|---|
| nothing | no | place link, record |
| nothing | yes | leave (removed by the person) |
| link into `~/.agents/skills/s` | any | leave; record if not |
| other link | any | leave |
| real folder | — | clash (the adopt step runs first and has already moved a free name) |

Adopt, before that: each real folder `~/.claude/skills/n` not managed, with no
`~/.agents/skills/n`: move it across, then the table above links it back.

Instructions follow the same table with `AGENTS.md` as the target, after the first real
instructions file (Claude, Codex, Copilot, Grok order) has moved in when `~/.agents/AGENTS.md`
is missing; with no file anywhere, a short `~/.agents/AGENTS.md` is written.

## PersonalMCPServer (read from `~/.agents/mcp.json`, never stored)

| Field | From `mcp.json` |
|---|---|
| `name` | the key under `mcpServers` |
| `transport` | `stdio` when `command` is present; else `type` (`http` default, or `sse`) |
| `command`, `args`, `env` | stdio |
| `url`, `headers` | http, sse |

Parsed into the existing `MCPServer`. An entry with neither `command` nor `url`, or a file that
is not JSON, is a **problem** `{message, line?}`: the whole file is then skipped for sessions
(Story 6 scenario 4), and the problem goes to the Shared tab and the log (without values).

## SessionServers (per session, built by R10, never stored)

`[MCPServer]` in the order kept: app's own → chosen → personal → plugin servers (Grok). Beside
it, `dropped: [(name, reason)]` for the log, where the reason is `nameTaken`,
`transportNotAdvertised(sse|http)` or `mcpFileProblem`.

## BridgeRoute (in memory, `MCPBridge`)

| Field | Meaning |
|---|---|
| `id` | random, URL-safe; the path `/mcp/<id>` |
| `key` | random 32 bytes, the bearer the runtime must send |
| `appToken` | the session's app token: the route ends with it |
| `server` | the stdio `MCPServer` it stands for, and the session's folder |
| `process` | nil until the first `POST`; then the running server and a table of waiting ids |

States: **made** (in the session's `mcpServers` as http) → **running** (first POST) →
**ended** (token dropped, `DELETE`, daemon exit). A POST to an ended route gets `404`.

## PluginInfo (read model)

| Field | Meaning |
|---|---|
| `name`, `version`, `description` | from `.claude-plugin/plugin.json` (or `plugin.json`), else the folder name |
| `path` | the folder |
| `contents` | counts: `skills`, `commands`, `agents`, `hooks`, `mcpServers` |
| `reach` | per installed runtime: a `Reach` |

## Reach (read model, per item per runtime)

One of: `gets(means)`, where the means is text such as "through a link in ~/.claude/skills",
"sent at start", "through the bridge", "handed at start" or "added to Codex";
`ownCopy(file)` (the runtime uses a same-named copy of its own); `leftOut(reason)`;
`noWay(reason)`; `unchecked` (Gemini until R14); `notInstalled`.

## SharedSnapshot (the `personal/shared` result)

`home`, `laidOut`, `runtimes` (installed ones, catalog order), `instructions`, `skills`
(`[PersonalSkill]` with `source: personal | plugin(name)` and `description` from SKILL.md's front
matter), `mcp` (`file`, `problem?`, `servers`, `app`, `runtimeOnly`), `plugins`, `otherFiles`,
and `needsALook` (clashes, left-outs, no-ways, problems, each pointing at its page). Shape in
[contracts/personal-shared.md](contracts/personal-shared.md).
