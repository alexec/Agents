# Contract: Starting an Antigravity agent

> **Revised 2026-09-26 (Alex): Google sign-in only.** No key is lent to Antigravity (the Gemini
> key is Gemini's), so the "key lent" steps below are history. `GEMINI_API_KEY` and
> `GOOGLE_API_KEY` are always removed from the process, and the sign-in sheet hides
> `gemini-api-key` and `agent-platform`.

## Command

`<root>/tools/antigravity/current/bin/agy_acp_server` (Mac) or
`~/.agents-server/tools/antigravity/current/bin/agy_acp_server` (server). The shim execs
`../agy_acp_server.par` with the platform's `arguments` (`--uid=` on Linux) and `"$@"`.
Working directory: the agent's folder. Never an `agy` or `agy_acp_server` from the PATH.

## Environment (this process only)

| Variable | Value |
|---|---|
| `GEMINI_HOME` | `<root>/runtimes/antigravity/home` (created 0700 if missing) |
| `AGY_ACP_DISABLE_WORKSPACE_TRUST` | `1` |
| `GOOGLE_API_KEY` | removed |
| `GEMINI_API_KEY` | the lent key when lending; otherwise removed (so a stray one in the daemon's environment is not used silently) |
| `CLAUDE*` | removed, as for every runtime (`RuntimeEnvironment`) |

## Order on the wire

1. `initialize` (client capabilities as for every runtime). Allow ≥ 30 s (cold ≈ 6–8 s).
2. **If a key is lent**: `authenticate {"methodId": "gemini-api-key"}` → `{}`.
3. `session/new {cwd, mcpServers: [<app's MCP server>], _meta: {"agy": {"disabledTools": ["start_subagent"]}}}`
   — same `_meta` on `session/load` and `session/resume`.
4. On `-32000` from step 3: the agent is **Needs signing in**, with `authMethods` from step 1.
   The sheet's **Log in with Google** sends `authenticate {"methodId": "oauth-personal"}` on a
   probe session, then the waiting start repeats from step 3.

## Turn outcome

- `session/prompt` result `stopReason` as usual.
- If the turn's agent text begins `Agent execution error:` → the turn is **failed** with that
  sentence (quotes and code stripped to the inner message). Containing `API key not valid` or
  `API_KEY_INVALID` → refused-key failure with **Replace key**.

## Questions

`session/request_permission` whose `toolCall.toolCallId` starts `interaction_` is a question
from `ask_question`: title = the question, options = the answers (single choice). Shown as the
app's permission card; the chosen `optionId` is returned.

## Sign-out

`logout` (advertised as `agentCapabilities.auth.logout`).
