# Data Model: An Agent Can Run a Few Agents of Its Own

## Agent (existing record, one field added)

| Field | Type | Notes |
|---|---|---|
| `startedByAgent` | `UUID?` | **New.** The agent whose `start_agent` call made this one. Set once, when the start succeeds, and never changed. Encoded only when present; older records decode it as nil. |

Derived:
- **isHelper**: `startedByAgent != nil`. Helpers don't get the tools (FR-008).
- **isManageable(by caller)**: `startedByAgent == caller.id && caller.id != self.id`. Stop and
  archive require it (FR-006). Because the caller must not itself be a helper, one level is the
  maximum.

`startedByWorkflow` and `startedByAgent` are independent. A workflow's agent that starts a helper
gives that helper `startedByAgent`, not `startedByWorkflow`.

## EndedReason (existing enum, one case added)

| Case | Summary | Notes |
|---|---|---|
| `stoppedByAgent` | "Stopped by the agent that started it" | Set only by the `stoppedByAgent` event. Older builds read it as `unrecognised`. |

## Agent.ArchivedReason (existing enum, one case added)

| Case | Notes |
|---|---|
| `byAgent` | Set only by `archivedByAgent`. Older builds read it as `byUser`. |

## AgentEvent (state table, two events added)

| Event | From | To | Ending | Archive reason |
|---|---|---|---|---|
| `stoppedByAgent` | starting, running, waitingOnUser | stopped | `.set(.stoppedByAgent)` | leave |
| `stoppedByAgent` | anything else | refused (no change) | — | — |
| `archivedByAgent` | same rows as `archivedByUser` | archived | same as `archivedByUser` | `.set(.byAgent)` |

Both copy the transitions of the `…ByUser` event they mirror, and the table tests must say
so row for row. Unarchiving stays `unarchivedByUser` only. An agent can't unarchive.

## Project limit (derived, not stored)

```
placesInUse(project) =
    count(agents where startedByAgent != nil
                   and standardize(cwd) == project
                   and state != .archived)
  + reservedStarts[project]

allowed = 3   // HelperLimit.perProject
```

- `reservedStarts: [URL: Int]` lives in memory on `DaemonCore`. It is incremented before the
  first `await` in the start path and decremented when the start succeeds or throws.
- The count doesn't depend on who the starter is. Every agent in the project shares the same three places.
- Stopped and finished helpers count. Only `.archived` frees a place.

## Helper summary (returned by `list_my_agents`, not stored)

| Field | Source |
|---|---|
| `id` | `agent.id` (the handle `stop_agent` / `archive_agent` take) |
| `title` | `agent.title` |
| `state` | `agent.state`, plus "coming back" when the daemon is picking it up |
| `outcome` | `agent.report?.outcome` and `agent.report?.message`, if any |
| `ending` | `agent.endedReason?.summary`, if stopped |

Plus `placesInUse` and `allowed` for the project.

## Validation rules (from the spec)

- Start: the prompt is non-empty after trimming. Settings are resolved exactly as a workflow's
  are (R4). The caller must not be a helper. `placesInUse < allowed`.
- Stop / archive: the target exists, `isManageable(by: caller)`, and the target is not already
  archived (the refusal says so). Stopping a stopped or finished target changes nothing and
  reports no error.
- A caller whose token isn't bound gets the same refusal as the other app tools: "That
  conversation is not open any more".
