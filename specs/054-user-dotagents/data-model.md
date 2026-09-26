# Data Model: One Set of Skills and Instructions for Every Agent

## PersonalLayout (the rule, static)

What the home layout is, as data, beside `DotAgents` for projects.

| Field | Value |
|---|---|
| `folder` | `.agents` under the home |
| `router` | `AGENTS.md` |
| `resourceFolders` | `skills`, `personas` |
| `runtimes` | `[RuntimeLinkRule]`, from research R1 |

## RuntimeLinkRule

| Field | Meaning |
|---|---|
| `runtimeID` | `claude`, `codex`, `grok`, `cursor`, `copilot`; Gemini has no rule until probed |
| `configFolder` | `.claude`, `.codex`, `.grok`, `.cursor`, `.copilot`: where its links go. A runtime gets links only when `RuntimeDiscovery.locate` finds it (the folder alone is not proof: Antigravity makes `~/.gemini`) |
| `readsSharedSkills` | true for Codex, Grok, Cursor, Copilot |
| `skillsFolder` | `.claude/skills` for Claude; nil for the others |
| `instructionsFile` | `.claude/CLAUDE.md`, `.codex/AGENTS.md`, `.grok/AGENTS.md`, `.copilot/copilot-instructions.md`; nil for Cursor |
| `adopts` | true for Claude only (R3) |

`managed` names, never touched in any `skillsFolder`: `synced`, anything holding a `.bucket-*`
file or `.sync-manifest.json`.

## PlacedLinks (stored, `<root>/personal-layout.json`)

```json
{ "home": "/Users/alex", "links": { ".claude/skills/grill-me": "../../.agents/skills/grill-me",
                                   ".claude/CLAUDE.md": "../.agents/AGENTS.md" } }
```

- A path is added when the app places a link there.
- A path in `links` with nothing on disk is one the person removed: not placed again.
- A path whose destination is a skill no longer in `~/.agents/skills` is dropped (with the
  dangling link, if still there), so the skill added again is linked again.
- A different `home` from the one being laid out resets the record.

## PersonalSkill (read model, for Settings ▸ Agents)

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
