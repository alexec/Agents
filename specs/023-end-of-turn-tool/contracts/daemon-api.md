# Contract: the daemon method

One new method, relayed by the MCP helper in `Daemon/Sources/main.swift` as the four existing app
tools are: connect, call, read `note`, disconnect, hand the sentence back.

## `agents/finishTurn`

**Params** — `DaemonAPI.FinishTurnRequest`

| Field | Type | Notes |
|---|---|---|
| `token` | string | The session's app token. |
| `outcome` | string | One of `done`, `nothing_to_do`, `needs_answer`, `partly_done`, `stuck`. |
| `message` | string | Trimmed. Empty is refused; over 1,000 characters is cut, as 014 does. |
| `prompts` | array of `{label, prompt}` | Zero to four. Already cleaned by the service; the daemon cuts to `SuggestedPrompt.limit` again as `suggestPrompts` does. |

**Result**

```json
{ "note": "Noted. This conversation now reads as \"Complete\" wherever the person looks. 3 shown above the prompt." }
```

**Errors** — the four from `agents/reportOutcome`, unchanged in code and wording:

| Code | When |
|---|---|
| `-32005` `noSuchAgent` | The token does not bind to a live agent |
| `-32602` `invalidParams` | `outcome` is not one of the five |
| `-32602` `invalidParams` | `message` is empty after trimming |
| `-32602` `invalidParams` | A permission request or elicitation for this agent is outstanding |

Every error is raised before any write. A refused call leaves `report` and `suggestedPrompts` as
they were.

**Side effects, in order**

1. `agent.report = report`, replacing any earlier report from this turn.
2. `agent.suggestedPrompts = prompts`, replacing any earlier chips, with `[]` if none were sent.
3. `record(.workReported(report), for: agentID)` — record before windows.
4. `changed(agent)` — one broadcast for both fields.
5. `reconsider()` — a report that needs a person begins a need, as 014's does.

## `agents/suggestPrompts` and `agents/reportOutcome`

Unchanged. `reportOutcome`'s checks and its record-then-broadcast tail are factored into private
helpers that `finishTurn` shares, so the four refusals cannot drift between the two methods. Their
integration suites (`SuggestedPromptTests`, `OutcomeReportTests`) are the proof that nothing moved.
