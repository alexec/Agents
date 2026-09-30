# Contract: Starting Codex

## Command

On the Mac:

```text
<root>/tools/codex/<id>/bin/codex-acp        # the shim; <id> is current's target, resolved
```

On a server:

```text
~/.agents-server/tools/codex/<id>/bin/codex-acp
```

The shim is 043's, with the adapter's entry in place of Claude's:

```sh
#!/bin/sh
# Agents: runs the Codex adapter this toolset was installed with.
d=$(cd "$(dirname "$0")/.." && pwd -P)
PATH="$d/node/bin:$PATH" exec "$d/node/bin/node" "$d/lib/node_modules/@agentclientprotocol/codex-acp/dist/index.js"
```

The adapter finds Codex's native binary through `@openai/codex`'s own `bin/codex.js`, under
the same `node_modules`. `CODEX_PATH` is never set.

The PATH is never searched (`usesAppCopyOnly: true`). A `codex`, `codex-acp` or `npx` of the
person's is never run.

## Environment

The login environment (`LoginShellPath.environment()`), as for every runtime, plus:

| Variable | Mac | Server |
|---|---|---|
| `CODEX_CONFIG` | policy JSON (below) | same |
| `NO_BROWSER` | unset | `1` |
| `CODEX_API_KEY` | unset by the app (the person's own passes through) | the lent key, when lent |
| `OPENAI_API_KEY` | unchanged | removed when a key is lent |
| `CODEX_HOME`, `CODEX_PATH` | never set by the app | never set by the app |

```json
{"features":{"apps":false,"default_mode_request_user_input":true,"goals":true,
             "in_app_local_automation":false,"memories":false,"multi_agent":true,
             "sleep_tool":false}}
```

`multi_agent` and `goals` are `true` because Codex's own sub-agents and its own task list are
tools the app no longer takes away (057 for the sub-agents, 2026-09-29 for the goals). The
sub-agents arrive as their own sessions and the app draws them; the goals do not, because the app
reads no runtime's goal metadata — Codex keeps the tool and the app says nothing about it.

If the adapter rejects the config, it fails the session open with a message naming
`CODEX_CONFIG` (R5). That surfaces as the agent's ending sentence and is caught by the
live test.

## ACP

- `initialize`: the app's existing client capabilities, which since 057 advertise JetBrains'
  `asyncTasks` and `nativeSubagentSessions` — the two that carry a subagent's own updates — so
  the adapter is free to use them. It does not advertise, and does not read, a goal extension.
- `session/new`: `cwd`, `mcpServers` = the app's MCP server (stdio), as for the others.
- Unsigned: error `-32000` "Authentication required", which becomes `needsSignIn`.
- Sign-in: `authenticate {methodId}` with `chat-gpt` (browser), `chat-gpt-device-code`
  (URL elicitation) or `api-key`. Sign-out: `logout`, advertised as `auth.logout`.
- Modes: `read-only`, `agent`, `agent-full-access`, through `session/set_mode`. The
  remembered mode is sent after `session/new`, as for the others.
- Questions: `elicitation/create` (form) for `request_user_input`.
- Usage: `usage_update {used, size}`. There is no cost.

## Mac toolset update (R11)

1. If `tools/codex/current` does not resolve to the bundled id, the row is `outdated` and
   offers **Update**.
2. **Update** installs the bundled id beside it (a `.part-<id>` folder, then `ok`, then a
   rename) and moves `current` by renaming a temporary link over it.
3. A Codex agent is launched through the resolved `<id>` path, never through `current`, and
   records that path. Old ids are removed only when no agent still runs from them.
