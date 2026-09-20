# Contract: the daemon method

One method, relayed by the MCP helper in `Daemon/Sources/main.swift` exactly as the other three app
tools are: the helper connects, calls, reads `note` out of the result, disconnects, and hands the
agent back whatever sentence came with it.

## `agents/reportOutcome`

**Params** — `DaemonAPI.ReportOutcomeRequest`

| Field | Type | Notes |
|---|---|---|
| `token` | string | The session's app token. Not an agent id — anything on this Mac can reach the socket, and the token is the only thing that says which agent this is. |
| `outcome` | string | One of `done`, `nothing_to_do`, `needs_answer`, `partly_done`, `stuck`. |
| `message` | string | Trimmed. Empty is refused; over 1,000 characters is cut. |

**Result**

```json
{ "note": "Noted. The person will see this conversation under \"Needs attention\", with your message on it." }
```

**Errors**

| Code | When | Message |
|---|---|---|
| `-32005` `noSuchAgent` | The token does not bind to a live agent | `That conversation is not open any more, so nothing was recorded.` |
| `-32602` `invalidParams` | `outcome` is not one of the five | `Nothing was recorded: outcome has to be one of done, nothing_to_do, needs_answer, partly_done or stuck.` |
| `-32602` `invalidParams` | `message` is empty after trimming | `Nothing was recorded: say in a sentence how it went. An outcome with no words is no more use than the turn simply ending.` |
| `-32602` `invalidParams` | A permission request or elicitation for this agent is outstanding | `Nothing was recorded: you have a question waiting to be answered, so this work is not over. Answer it first, or let it be answered.` |

No new error code. `showFile` already refuses with `invalidParams` and a sentence, for the reason it
gives: an agent told the rule once should not be told it differently by every door.

**Side effects, in order**

1. `agent.report` is set, replacing any earlier report from this turn.
2. `record(.workReported(report), for: agentID)` — the record first, then the windows, which is the
   order that leaves something true behind when the daemon is killed mid-call.
3. `changed(agent)` broadcasts `agent/changed`. No new notification: the report rides on the agent,
   and every window already applies `agent/changed` through `AgentsModel`.
4. If the report's group differs from the agent's previous group, the project's summary is rebroadcast
   so the sidebar dot follows. This is the existing `projectChanged` path in `DaemonCore+Projects`.

## What changes in methods that already exist

### `agents/prompt`

`DaemonAPI.PromptRequest` gains `from: PromptOrigin = .person`. A remote built before 014 omits it
and its prompts are the person's, which is correct.

`enqueue` gains two lines: a prompt `from: .person` clears `agent.report` (FR-006) and
`agent.outcomeAsked` (FR-023); a prompt `from: .app` clears neither.

### Turn end — `DaemonCore+Commands.finishTurn`

After `move(agentID, on: .turnEnded(reason))` and `releaseRuntime`, and **before** `drainQueue`:

```text
ask once, when all of these hold:
  reason == .endTurn                 // FR-025: an ending short is never asked about
  agent.report == nil                // it said nothing
  agent.outcomeAsked == false        // FR-021: never twice
  agent.queuedPrompts.isEmpty        // FR-023: the person has moved on; their prompt wins
  agent.state == .finished           // not archived, not stopped
then:
  agent.outcomeAsked = true
  enqueue(PromptRequest(agentID:, text: <the question>, from: .app), first: false)
```

Setting the flag before enqueuing is what makes the bound structural: the turn that question causes
runs through `finishTurn` too, finds the flag already set, and stops there.

The daemon restarting between the ending and the question means no question — nothing is owed after
the fact, and `outcomeAsked` stays `false` on a record whose turn is long over, which is harmless
because only a fresh `.endTurn` opens the gate.

### `agents/list`, `agents/get`, `project/changed`

Nothing structural. `Agent` carries two more fields; `ProjectSummary.counts` is computed from
`agent.group`, which now sees the report, so `needsInput` follows with no change to its own code.
