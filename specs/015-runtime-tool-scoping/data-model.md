# Data Model: Our Tools, Not Theirs

Nothing here is stored. No agent record grows a field, no transcript entry is added, and nothing is
written to disk except one generated config file (R11) that is rebuilt from the table below every
time it is needed. These are values in the source: a table of what each runtime may keep, and the
few shapes needed to turn that table into a launch and a session.

They live in `AgentsKitCore`, beside `RuntimeCatalog`, because a policy about a runtime belongs with
the description of that runtime.

---

## `RemitCategory`

What job of this app's a tool duplicates. Every removal and every piece of residue names exactly
one, which is what makes the table arguable rather than a list of names somebody disliked.

| Case | The app's answer to it |
|---|---|
| `standingArrangements` | `manage_workflows` |
| `escalation` | the runtime's own question tool, held by the daemon as an elicitation |
| `agents` | the app itself: starting, briefing, reading and stopping agents |
| `artefacts` | the conversation, the project's files, `show_file` |
| `suggestions` | `suggest_next_prompts` |

Each case carries the sentence an agent is told when it reaches for something in that category —
one place, so the briefing line and the permission refusal say the same words.

---

## `ToolPolicy`

One per runtime. Total over `RuntimeCatalog.builtIn`: a runtime without an entry is a bug a unit
test catches, not a runtime that silently keeps everything.

| Field | Type | What it is |
|---|---|---|
| `runtimeID` | `String` | The `Runtime.id` this applies to |
| `removed` | `[RemovedTool]` | Tools taken away, each with its category |
| `kept` | `[KeptTool]` | Tools deliberately left that look like they should go, each with its reason. The escalation tool lives here |
| `residue` | `[ResidualTool]` | Conflicting tools this runtime will not let us remove |
| `lever` | `Lever` | How the removal is asked for |
| `environmentFiles` | `[EnvironmentFile]` | Config the app generates and points the runtime at |

`removed` is the single list of names. The lever reads it; the check reads it; nothing repeats it.

---

## `RemovedTool`, `KeptTool`, `ResidualTool`

| Type | Fields | Notes |
|---|---|---|
| `RemovedTool` | `name: String`, `category: RemitCategory` | `name` is the runtime's own id for the tool, spelled the way its lever spells it — bare (`task`), whole-server (`mcp__claude_ai_Google_Drive`) or exact (`ScheduleWakeup`) |
| `KeptTool` | `name: String`, `because: String` | Exists to make the escalation tool's survival deliberate rather than accidental, and to stop a future reader "tidying" it into `removed` |
| `ResidualTool` | `name: String`, `category: RemitCategory`, `instead: String` | `instead` names the app tool to use. It is what the briefing line and the refusal both say |

---

## `Lever`

How a removal is asked for. Four ways of asking, not four runtimes — nothing downstream switches on
a runtime id.

| Case | Shape | Used by |
|---|---|---|
| `sessionMetaDenyList(path:)` | The removed names go into an array at this key path inside `session/new` `_meta`. Path today: `["claudeCode", "options", "disallowedTools"]` | Claude |
| `sessionMetaAllowList(path:keep:extra:)` | The names in `keep` go into an array at this key path; `extra` is whatever else that object needs. Path today: `["agentProfile", "tools"]`, with `name` and `description` as `extra` | Grok |
| `launchArguments(flag:repeatsFlag:extra:)` | The removed names follow `flag` on the command line — repeated per name when `repeatsFlag`, otherwise once with the names after it — and `extra` is the rest of the flags | Copilot |
| `words` | No mechanism. Everything conflicting is residue | Cursor |

An allowlist lever carries `keep` rather than deriving it from `removed`, because "everything except
these" and "only these" are different claims and only one of them is true of Grok.

---

## `EnvironmentFile`

A config file the app writes for a runtime that will only read policy from disk (R6, R11).

| Field | Type | What it is |
|---|---|---|
| `name` | `String` | The file's name under `<root>/runtimes/`, e.g. `grok-overlay.toml` |
| `contents` | `String` | Written whole, every time, from the policy |
| `variable` | `String` | The environment variable pointed at it, e.g. `GROK_CONFIG_PATH` |

Nothing reads these back. The file is an argument that happens to need a path.

---

## `ToolInventory`

Not part of the app. What the check script (R9) builds per runtime from a live run: the runtime's
id, the tools the agent says it has, and the run it came from (scoped or not). It exists so the
report can say *removed*, *residue*, *unaccounted for* rather than printing two lists and leaving
the reading to the person.

---

## The table itself

The values, as measured in [research.md](./research.md). This is the part that will age, and the
part the check keeps honest.

| Runtime | Lever | Removed | Kept, deliberately | Residue |
|---|---|---|---|---|
| Claude | `sessionMetaDenyList` | `Workflow`, `CronCreate`, `CronList`, `CronDelete`, `ScheduleWakeup`, `Monitor`, `RemoteTrigger` *(standing arrangements)*; `PushNotification` *(escalation)*; `Agent`, `ListAgents`, `SendMessage`, `TaskOutput`, `TaskStop` *(agents)*; `ReportFindings`, `DesignSync`, `mcp__claude_ai_Claude_Docs`, `mcp__claude_ai_Google_Drive` *(artefacts)* | `AskUserQuestion` — it is the escalation path | none |
| Grok | `sessionMetaAllowList` + `GROK_CONFIG_PATH` overlay | `scheduler_create`, `scheduler_delete`, `scheduler_list` *(standing arrangements)*; `send_feedback` *(escalation)*; `spawn_subagent`, `kill_command_or_subagent`, `get_command_or_subagent_output` *(agents)* | `ask_user_question` — the escalation path; `todo_write`, `enter_plan_mode`, `exit_plan_mode` — the work | `workflow`, `monitor` |
| Copilot | `launchArguments` | `task`, `list_agents`, `read_agent`, `write_agent` *(agents)*; `session_store_sql` *(artefacts)*; the whole `software-factory` server *(all five categories)*; the built-in MCP servers | its own question flow — the escalation path | `search_code_subagent` *(agents; its real id is unknown — R5)* |
| Cursor | `words` | none — there is no lever | — | `Task` *(agents)*, `CreateGoal`, `UpdateGoal` *(standing arrangements)* |

Copilot's suggestion tool, `prompt_suggest`, and its escalation tools, `escalation_raise` and
`escalation_await`, are removed by disabling the server that carries them rather than by name. That
is one removal with five categories against it, and the table says so rather than pretending it is
five removals.
