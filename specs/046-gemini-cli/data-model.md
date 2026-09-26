# Data Model: Gemini CLI as a Fifth Runtime

Nothing new is stored per agent. Gemini is data in existing catalogs, plus one credential
kind and one toolset.

## Runtime (existing, `RuntimeCatalog`)

| Field | Gemini value |
|---|---|
| `id` | `gemini` |
| `name` | `Gemini` |
| `executable` | `npx` |
| `arguments` | `["-y", "@google/gemini-cli@0.61.0", "--acp"]` |

`builtIn` becomes `[claude, grok, copilot, cursor, gemini]`. The version string is the same
one as `toolsets/gemini/manifest.json` `packageVersion`; a unit test says so.

## ToolPolicy (existing, `ToolPolicyCatalog.gemini`)

- `removed`: `invoke_agent` (agents); `tracker_create_task`, `tracker_update_task`,
  `tracker_get_task`, `tracker_list_tasks`, `tracker_add_dependency`, `tracker_visualize`
  (standing arrangements).
- `kept`: none named (no question tool survives ACP mode).
- `residue`: none, unless the spike finds a deny that does not hide (then still none: a
  refused call is not residue, it cannot run).
- `lever`: `.launchArguments(flag: "", repeatsFlag: false, extra: [])` plus the file below —
  or a new `.fileArgument` case if an empty flag reads badly; decided in Phase 1.
- `environmentFiles`: one file, `gemini-policy.toml`, named by argument `--policy`.
- `escalationTool`: `nil` (R6).

## EnvironmentFile (existing, gains a form)

| Field | Change |
|---|---|
| `name`, `contents` | unchanged |
| `variable: String` | becomes optional |
| `argument: String?` | new: a launch flag the file's path follows, e.g. `--policy` |

Exactly one of `variable` and `argument` is set; the initialiser enforces it.
`RuntimePolicyFiles` writes both kinds to `<root>/runtimes/` and returns the environment
additions and the argument additions separately.

## CredentialKind (existing, 043)

| Case | Prefix | Runtime | Variable lent | Variables cleared when lending |
|---|---|---|---|---|
| `oauthToken` | `sk-ant-oat` | claude | `CLAUDE_CODE_OAUTH_TOKEN` | Claude's two |
| `apiKey` | `sk-ant-api` | claude | `ANTHROPIC_API_KEY` | Claude's two |
| `geminiAPIKey` (new) | `AIza` | gemini | `GEMINI_API_KEY` | `GEMINI_API_KEY`, `GOOGLE_API_KEY` |

Gains `runtimeID` and `clearedVariables(for runtimeID:)`; `allVariables` becomes per runtime.
`Secret`'s length check stays (`AIza` + > 4). Display: "Gemini API key".

## Runtime credential record (existing, App, 043)

Keyed by runtime id already (`credentials.record("claude")`). Gains a `gemini` record; no
shape change. Settings lists one row per runtime that has a bundled toolset.

## Toolset (existing, 043)

`App/Resources/toolsets/gemini/manifest.json`:

```json
{ "runtimeID": "gemini",
  "node": { "version": "v24.21.0", "sha256": { "x86_64": "…", "aarch64": "…" } },
  "package": "@google/gemini-cli", "packageVersion": "0.61.0",
  "entry": "bundle/gemini.js", "minFreeBytes": 419430400 }
```

On a server: `~/.agents-server/tools/gemini/<id>/` with `current` and `ok`, as Claude's.
The server's runtime recipe is `node <toolset>/node_modules/@google/gemini-cli/bundle/gemini.js --acp`.

## Turn usage (existing, from `PromptResult`)

`ACP.PromptResult` gains `quota: Quota?` read from `_meta.quota`:
`tokenCount {input, output}` and `modelUsage [{model, tokenCount}]`. Mapped into the turn's
existing usage (tokens, no cost). When `modelUsage` names one model and it differs from the
session's current model id, the agent's shown model follows it.
