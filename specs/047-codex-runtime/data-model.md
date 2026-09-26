# Data Model: Codex as a Runtime

Only additions and changes are listed. Everything else is 043/048 as merged.

## Runtime (AgentsKitCore/Model/Runtime.swift): one field added

| Field | Type | Codex | Notes |
|---|---|---|---|
| `usesAppCopyOnly` | `Bool`, default `false` | `true` | When true, `RuntimeDiscovery.locate` looks only at the app's toolset (Mac `tools/<id>/current`, server `~/.agents-server/tools/<id>/current`). It is decoded with a default, so an older phone or Mac reads `false` (R1). The same field as 046's. |

`RuntimeCatalog.codex`:

```text
id: "codex"   name: "Codex"   executable: "codex-acp"   arguments: []
usesAppCopyOnly: true
install: .toolset(runtimeID: "codex")
installPage: https://github.com/agentclientprotocol/codex-acp
```

`builtIn` becomes `[claude, grok, copilot, cursor, codex]`. 046 adds `gemini`, and the
order is whichever merges first.

## Toolset (AgentsKitCore/Runtimes/Toolset.swift): no new fields

- `shimLines` stays as it is. The installers write the shim as
  `bin/<runtime.executable>` (Claude: `npx`, Codex: `codex-acp`) rather than a fixed
  `bin/npx`.
- `App/Resources/toolsets/codex/manifest.json`:
  `runtimeID "codex"`, `node v24.21.0` (the Linux sha256 values, the same as Claude's),
  `package "@agentclientprotocol/codex-acp"`, `packageVersion "1.13.1"`,
  `entry "dist/index.js"`, `minFreeBytes 1073741824`.
- Toolset id: as 043, the SHA-256 of the manifest and the lock, first 16 hex characters.

## Installed Mac toolset state (derived, not stored)

| State | Test | Shown as |
|---|---|---|
| missing | no `tools/<id>/current/ok` | 048's `missing`, with an install button |
| installing | an install task under way | 048's `installing(progress:)` |
| failed | the last install threw | 048's `installFailed(reason:)` |
| current | `current` → the bundled id, whole | `available` |
| **outdated** (new, 046's T035) | `current` → another id, whole | `available`, `RuntimeStatus.outdated = true`, with an **Update** button beside the tick |

Transitions: missing → installing → current | failed; failed → installing (on retry);
current → outdated (app update) → installing (Update) → current. Old ids are removed only
when no agent still runs from them (046's T037).

## ToolPolicy: one lever and one field added

```text
Lever.environmentJSON(variable: String, value: JSONValue)
    // Set `variable` to `value` serialised, in the runtime's launch environment only.
ToolPolicy.preferredAuthMethods: [String] = []
    // The sign-in sheet's order. Unlisted methods keep their order after these.
    // Empty keeps today's rule (the first method without a terminal).
```

`ToolPolicyCatalog.codex`:

| Part | Value |
|---|---|
| removed | `spawn_agent`, `send_input`, `wait`, `close_agent` (agents); Codex memories (artefacts); ChatGPT apps/connectors (artefacts); goals (standing arrangements) |
| kept | `request_user_input`: "It is the escalation path: the adapter raises it as a form elicitation, which the daemon holds and the phone can answer." |
| residue | whatever the spike finds is still listed after its feature is off (R5) |
| lever | `.environmentJSON(variable: "CODEX_CONFIG", value: {"features":{"multi_agent":false,"memories":false,"apps":false,"goals":false,"default_mode_request_user_input":true}})` |
| escalationTool | `"request_user_input"` |
| preferredAuthMethods | `["chat-gpt", "chat-gpt-device-code", "api-key"]` |

## CredentialKind: made per runtime, and one kind added

| Kind | Runtime | Recognised by | Lent as | Cleared when lent | Display |
|---|---|---|---|---|---|
| `oauthToken` | claude | `sk-ant-oat` | `CLAUDE_CODE_OAUTH_TOKEN` | `ANTHROPIC_API_KEY` | Subscription token |
| `apiKey` | claude | `sk-ant-api` | `ANTHROPIC_API_KEY` | `CLAUDE_CODE_OAUTH_TOKEN` | API key |
| **`openAIAPIKey`** | codex | `sk-` and not `sk-ant-` | `CODEX_API_KEY` | `OPENAI_API_KEY` | OpenAI API key |

- `CredentialKind.runtimeID` and `CredentialKind.variables(for runtimeID:)` replace
  `allVariables`. `LentEnvironment.applied` clears only the lent runtime's variables.
- `init?(secret:)` checks `sk-ant-` before `sk-`.
- Keychain records stay keyed by runtime id (043), so `record("codex")` sits beside
  `record("claude")`.

## Server launch environment for Codex (additions)

| Variable | Value | When |
|---|---|---|
| `CODEX_CONFIG` | the policy JSON | always (Mac and server) |
| `NO_BROWSER` | `1` | a server's daemon only (`--serve`) |
| `CODEX_API_KEY` | the lent key | a server, when a window lent one |
| `DEFAULT_AUTH_REQUEST` | `{"methodId":"api-key"}` | a server with a lent key, **only if** the spike shows the environment key alone is not enough (R9) |

## Validation rules (from the spec)

- The Mac never sends a Settings key to a Mac agent (FR-010). `launchEnvironment` is
  already server-only (`exitsWhenIdle`).
- Nothing about ChatGPT is ever lent (FR-020). There is no ChatGPT credential kind, and
  `NO_BROWSER` hides the method on servers.
- `ToolPolicyCatalog.builtIn` and `RuntimeCatalog.builtIn` have the same ids (the existing
  totality test).
- Every runtime with `install: .toolset` has a bundled toolset folder with a manifest whose
  `runtimeID` matches (a new test).
