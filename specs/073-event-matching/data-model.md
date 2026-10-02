# Data model: Finer event matching, step 1

## EventFilter (new, AgentsKitCore)

One detail's wanted values.

| Field | Type | Notes |
|---|---|---|
| `values` | `[String]` | Never empty. One value means equals, as today. More than one means any of. |

- `matches(_ detail: String?, isSet: Bool) -> Bool`:
  - A missing detail never matches.
  - On a set detail, the detail is split on `,` and each value is compared by
    `SessionLabelPolicy.key`.
  - Otherwise the comparison is exact string equality, as today.
- A list of one is the single value (FR-014): `EventFilter(["done"]) == EventFilter("done")`.
- It is `ExpressibleByStringLiteral`, so `["workflow": "nightly"]` still reads as a pattern's
  filters.
- **Codable**: a single value is a string. A list is an array of strings. It decodes either.
  This is the form for the wait request's `where`, not for `EventPattern`'s own storage (below).
- **Words**:
  - `label`: `done|nothing_to_do`;
  - `capsule`: `done | nothing_to_do`;
  - `yaml`: `done` or `[done, nothing_to_do]`, each value through `yamlScalar`.

## EventDetail (new, AgentsKitCore)

One entry per detail a catalogue kind carries.

| Field | Type | Notes |
|---|---|---|
| `key` | `String` | as on the event |
| `isSet` | `Bool` | `labels` only |
| `values` | `[String]?` | Fixed codes, or `nil` for open. |
| `oldWords` | `[(words, code)]` | Today's sentences, lowercased, matched whole or by their fixed prefix or suffix. |
| `phrase` | `([String]) -> String` | The summary's words for a list of values (FR-022). Defaults to `key a or b`. |
| `isContext` | `Bool` | `labels`, `runtime` and `started_by`: left out of Copy as trigger (FR-025). |

## EventKind (changed)

- `details: [String]` becomes `detailDescriptions: [EventDetail]`.
- `details` stays as the key list, so every caller that only lists keys is unchanged.
- Agent kinds get the three context details from one shared list (FR-006).
- `cost.limit_reached` gets them too, open when it isn't about an agent.

## EventPattern (changed)

| Field | Type | Was |
|---|---|---|
| `name` | `String` | same |
| `filters` | `[String: EventFilter]` | `[String: String]` |

**Encoding** (research R1):

```json
{"name": "agent.finished", "filters": {"labels": "bug"}}
{"name": "agent.finished", "filters": {"outcome": "done|nothing_to_do"},
 "anyOf": {"outcome": ["done", "nothing_to_do"]}}
```

The decoder maps old words to codes (R3).

## Event details added (daemon)

| Event | Details added |
|---|---|
| every `agent.*`, and `cost.limit_reached` about an agent | `labels` (keys, comma-joined, sorted; `""` with none), `runtime`, `started_by` |
| `agent.finished` | `afterwards`: `park` or `stay` |
| `agent.parked`, `agent.archived` | `outcome`, when the agent has a report |
| `workflow.completed` | `outcome`, when the run's agent has a report |

**Changed to codes**:
- `agent.failed reason`: `EndedReason.code`;
- `agent.stopped by`: `you`, `cost_limit` or `unknown`;
- `agent.archived by`: `you` or `agent`;
- `workflow.refused reason`: `WorkflowRefusal.code`.

An agent with no labels carries `labels: ""`. The set split gives no members, so a `labels` filter
never matches it.
