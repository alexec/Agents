# Contract: the catalogue's details

**Context**: on every `agent.*` event, and on `cost.limit_reached` when it is about an agent.

| Key | Set | Values | Words |
|---|---|---|---|
| `labels` | yes | open | `labelled bug`, `labelled bug or regression` |
| `runtime` | no | `RuntimeCatalog.builtIn` ids | `on Claude`, `on Gemini or Grok` |
| `started_by` | no | `person`, `workflow`, `agent` | `started by you`, `started by a workflow`, `started by another agent` |

**Per kind**: a detail not listed here is open, with the words `key value`.

| Kind | Key | Values | Old words, matched lowercased |
|---|---|---|---|
| `agent.finished` | `outcome` | `done`, `nothing_to_do`, `needs_answer`, `partly_done`, `stuck`, `blocked` | — |
| `agent.finished` | `afterwards` | `park`, `stay` | — |
| `agent.stopped` | `by` | `you`, `cost_limit`, `unknown` | `stopped by you`, `reached its cost limit`, `stopped` |
| `agent.failed` | `reason` | `allowance_spent`, `rate_limited`, `process_died`, `sign_in_refused`, `runtime_error`, `sandbox_failed`, `max_tokens`, `max_turn_requests`, `refusal`, `daemon_gone`, `stopped_by_agent`, `unrecognised` | each `EndedReason.summary`, lowercased |
| `agent.parked` | `outcome` | as `agent.finished` | — |
| `agent.archived` | `by` | `you`, `agent` | `another agent` |
| `agent.archived` | `outcome` | as `agent.finished` | — |
| `agent.retired` | `because` | `age`, `cap`, `person` | — |
| `workflow.completed` | `outcome` | as `agent.finished` | — |
| `workflow.refused` | `reason` | `run_in_flight`, `chain_too_deep`, `archived`, `over_limit`, `unreadable`, `trigger_not_supported`, `agent_unavailable`, `no_triggering_agent`, `missed_while_closed`, `folder_gone`, `day_limit_reached`, `setting_refused`, `awaiting_approval` | each `WorkflowRefusal.message` with a fixed wording; see the list below |
| `lease.released` | `how` | `expired`, `ended`, `released` | — |
| `person.away`, `person.back` | `why` | `locked`, `idle` | — |
| `cost.allowance_back` | `how` | `worked`, `another host`, `person`, `time`, `check` | — |

**Old words for `workflow.refused reason` that vary**, matched by their fixed part:
- `this chain is already … deep` maps to `chain_too_deep`;
- `this project already runs its … workflows` maps to `over_limit`;
- `… workflows are already running, across every project` maps to `over_limit`;
- `"…" is not something this version can watch for` maps to `trigger_not_supported`.

**How codes are said**:
- **Summary**: a code reads as its own words. A `reason` reads as the `EndedReason.summary` or the
  refusal message, lowercased. An `outcome` is said with `_` read as a space.
- **Status line**: a code stays a code.

**`describe()`**, as the wait tool lists it and as the workflow tool's description carries it:
- Each kind's line lists its own details, with `=a|b|c` after any detail that has fixed values.
- One line says that every agent event also carries `labels`, `runtime` and `started_by`
  (FR-006).
