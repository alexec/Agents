# Contract: Agent Tools for Starting, Stopping and Archiving Agents

Two layers. Agents see the MCP tools. The helper relays each call to the daemon over the socket,
adding the session's token. As with every existing app tool, a refusal comes back as an MCP result
with `isError: true` and a sentence the agent can repeat to the person.

## MCP tools (served by `AppService`, left out of `tools/list` for helpers)

Names are matched by suffix, like the existing tools (a runtime may prefix them with `mcp__agents__`).
The names are added to `AppTool` so the phone can recognise them in a transcript.

### `start_agent`

```json
{
  "name": "start_agent",
  "title": "Start an agent in this project",
  "inputSchema": {
    "type": "object",
    "properties": {
      "prompt":          { "type": "string", "description": "What the new agent is to do. Sent as its first message." },
      "runtime":         { "type": "string", "description": "Optional. As a workflow's runtime:." },
      "model":           { "type": "string", "description": "Optional. As a workflow's model:." },
      "permission_mode": { "type": "string", "description": "Optional. As a workflow's permission-mode:." }
    },
    "required": ["prompt"]
  }
}
```

The description has to say: the agent starts in this project; at most three agents started
by agents can exist in the project at once, and archiving one frees its place; the person sees it
and can take it over; start one only when part of the work can run alongside the rest.

**Success text**: `Started "‹title›" (id ‹uuid›). ‹n› of 3 places in this project are now in use.`

**Refusals**:
| When | Text (shape) |
|---|---|
| empty prompt | `Nothing was started: say what the agent is to do.` |
| caller is a helper | `Nothing was started: an agent that another agent started cannot start agents of its own.` |
| limit reached | `Nothing was started: this project already has 3 agents started by agents — "‹a›", "‹b›", "‹c›". Archive one to free its place.` |
| setting refused | the workflow path's `SettingRefused` text, with "Nothing was started:" in front |
| cost limit / runtime missing / folder gone | the daemon's existing `start` error text |

### `stop_agent`

```json
{ "name": "stop_agent",
  "inputSchema": { "type": "object",
    "properties": { "id": { "type": "string", "description": "The id start_agent or list_my_agents gave." } },
    "required": ["id"] } }
```

**Success text**: `Stopped "‹title›". It keeps its place until it is archived.`
It also says so when the target had already ended: `"‹title›" had already stopped; nothing changed.`

### `archive_agent`

The same schema as `stop_agent`.

**Success text**: `Archived "‹title›". ‹n› of 3 places in this project are now in use.`

**Refusals (stop and archive)**:
| When | Text (shape) |
|---|---|
| id is not a UUID, or not an agent | `Nothing changed: there is no agent with that id.` |
| target is the caller | `Nothing changed: an agent cannot stop or archive itself.` |
| target not started by the caller | `Nothing changed: you can only stop or archive agents you started.` |
| target already archived | `Nothing changed: "‹title›" is already archived.` |
| caller is a helper | the same text as for start, reworded for stop/archive |

### `list_my_agents`

No arguments. Returns text, one line per helper the caller started that is not archived:

```
2 of 3 places in this project are in use.
- ‹uuid›: "‹title›" — working
- ‹uuid›: "‹title›" — finished: done — ‹report message›
```

With none: `You have not started any agents that are still here. ‹n› of 3 places in this project are in use.`

## Daemon methods (`DaemonAPI.Method`)

| Method | Request | Result |
|---|---|---|
| `agents/startHelper` | `StartHelperRequest { token, prompt, runtime?, model?, permissionMode? }` | `{ "note": String, "agentID": UUID }` |
| `agents/stopHelper` | `HelperRequest { token, agentID }` | `{ "note": String }` |
| `agents/archiveHelper` | `HelperRequest { token, agentID }` | `{ "note": String }` |
| `agents/listHelpers` | `ListHelpersRequest { token }` | `{ "note": String }` |

Errors use `JSONRPCError` with `DaemonAPI.Failure.noSuchAgent` for an unbound token or a missing
target, and a new `DaemonAPI.Failure.notYours` for every scope refusal (caller is a helper, target
not started by the caller, target is the caller, limit reached). The message is always the
sentence the agent is shown.

The existing `agents/start`, `agents/stop` and `agents/archive` are unchanged. The Mac and phone
continue to use them, so the person's powers are unaffected (FR-010).

## Helper process (`agentsd mcp <token> [--no-agent-tools]`)

A new optional third argument. When it is present, `AppService` is made with `managesAgents: false`
and leaves out the four tools. An older daemon never passes it, and an older helper would ignore it.
Both ship in one binary, so a mismatch only lasts until the running daemon is replaced.
