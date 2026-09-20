# Contract: what the app sends each runtime

Three places carry scoping, and no fourth. Everything below was sent to the real runtime and the
answer checked; see [research.md](../research.md) for the measurements.

---

## 1. The command line

`ProcessSessionLauncher` starts `runtime.executable` with `runtime.arguments + policy.launchArguments`.
Only Copilot has any.

```text
copilot --acp
        --disable-mcp-server software-factory
        --disable-builtin-mcps
        --excluded-tools task list_agents read_agent write_agent session_store_sql
```

- Names are bare. `task`, never `functions.task`.
- A name Copilot does not recognise produces `Info: Unknown tool name in the tool excludedlist:
  "…"`, arriving as agent message text, and the session starts with the rest applied.
- `--disable-mcp-server` is repeated per server; `--excluded-tools` takes all its names at once.

The other three runtimes get their existing arguments unchanged.

---

## 2. The environment

`LoginShellPath.environment()` as today, plus one variable per `EnvironmentFile` in the policy. Only
Grok has one.

```text
GROK_CONFIG_PATH=<root>/runtimes/grok-overlay.toml
```

The file is written before the process starts, whole, every time:

```toml
# Written by the Agents app. Do not edit: rebuilt on every launch.
[features]
image_gen = false
video_gen = false
```

`<root>` is the daemon's own root, so a second daemon has a second copy. Nothing is written to
`~/.grok`, and `GROK_CONFIG` with the same content inline does not work (R6).

---

## 3. `_meta` on the session

`ACPSession.sessionParams` merges `policy.sessionMeta` into the parameters of `session/new` and
`session/load`; `forkSession` merges the same object into its own. A runtime with a `words` lever
sends no `_meta` at all, exactly as today.

**Claude** — a denial list:

```json
{
  "cwd": "/path/to/project",
  "mcpServers": [{ "name": "agents", "command": "…", "args": ["…"] }],
  "_meta": {
    "claudeCode": {
      "options": {
        "disallowedTools": [
          "Workflow", "CronCreate", "CronList", "CronDelete", "ScheduleWakeup",
          "Monitor", "RemoteTrigger", "PushNotification",
          "Agent", "ListAgents", "SendMessage", "TaskOutput", "TaskStop",
          "ReportFindings", "DesignSync",
          "mcp__claude_ai_Claude_Docs", "mcp__claude_ai_Google_Drive"
        ]
      }
    }
  }
}
```

The adapter appends this to its own denials, so `AskUserQuestion` — which it disables only when the
client cannot render a form, and this client can — is unaffected. Do not send
`allowDangerouslySkipPermissions`, `settings`, `settingSources`, `env` or `mcpServers` inside this
object: everything else in `_meta.claudeCode.options` is spread over the adapter's own options and
is not ours to set.

**Grok** — an allowlist, as a profile:

```json
{
  "cwd": "/path/to/project",
  "mcpServers": [],
  "_meta": {
    "agentProfile": {
      "name": "agents-app",
      "description": "An agent hosted by the Agents app.",
      "tools": [
        "read_file", "list_dir", "grep", "search_replace", "write",
        "run_terminal_command", "todo_write", "ask_user_question",
        "web_search", "web_fetch", "open_page", "open_page_with_find"
      ]
    }
  }
}
```

Anything not listed goes, except the optional tools Grok's stock profile injects anyway —
`workflow`, `monitor`, `search_tool`, `use_tool`, `enter_plan_mode`, `exit_plan_mode`. The first two
are residue; the rest are welcome.

`yoloMode` and `autoMode` are also `_meta` fields on this runtime. This feature does not set them.

---

## What must be true after each of these

| Claim | How it is checked |
|---|---|
| No conflicting tool named in the policy appears in the agent's own account of its tools | Live test per runtime, and the check script |
| The escalation tool is still there | Live test per runtime that has one |
| Reading, searching, editing, writing and running commands are still there | Live test per runtime |
| The app's three served tools are still there and still callable | Existing live tests for suggestions and workflows, unchanged |
| A stale name does not stop a session | Live test: one nonsense name in the policy, session still starts |
