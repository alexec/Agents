# Data model: Session labels

## SessionLabel

Stored as an element of `Agent.labels` in that session's `agent.json` record.

| Field | Type | Rule |
| --- | --- | --- |
| `value` | String | Display spelling, trimmed at both ends; 1–24 characters. |
| `normalizedValue` | String | Shared comparison key derived from the trimmed value without regard to case. |
| `owner` | `person` or `agent` | Exactly one owner; `agent` means the agent represented by the containing session. |
| `addedAt` | Date | Used to order suggestions and deterministically select the project spelling when rebuilding a vocabulary. |

The session may carry no more than five distinct normalized values. A session has at most
one entry per normalized value. An absent `labels` field in an older record decodes as an
empty array. The field is part of Codable keys so a new record round-trips labels and older
unknown-field preservation continues to work.

## Project label vocabulary

Derived, not stored as a second authoritative record. Its scope is the `projectFolder` of
the current daemon's agents. Include archived agents because labels remain attached to
archived sessions. For each normalized value still present, expose the canonical trimmed
spelling found on its entries, ordered by first use and then normalized value for stable
ties. Adding a duplicate to another session reuses that canonical spelling.

When the final session entry is removed, the normalized value is absent from the derived
vocabulary and no longer appears as a suggestion. A later addition may establish a new
canonical spelling. Separate daemon roots and project folders have separate vocabularies.

## LabelChange

An in-memory, validated mutation request. It is not a separate persisted entity.

| Field | Type | Rule |
| --- | --- | --- |
| `add` | `[String]` | Each value is normalized and validated before mutation. |
| `remove` | `[String]` | Each value is matched by normalized value. |
| `actor` | person or current session agent | Determines which ownership rules apply. |

The policy validates the complete operation before committing it. An invalid value, a sixth
distinct label, conflicting add/remove entries, or an unauthorized removal refuses the
request with an actionable reason and leaves the record unchanged. Re-adding the same
normalized label by its current owner is idempotent. If an agent attempts to add a label
already present as the person's label, refuse and preserve the person-owned entry. A person
may remove either owner class. An agent may remove only `agent`-owned entries.

## Relationships and lifecycle

- One `Agent` has zero to five `SessionLabel` values.
- A project vocabulary is the distinct normalized union across that project's `Agent`
  records.
- `Agent` archive/unarchive transitions keep labels unchanged.
- A new chat that reads another session's history starts with no labels of its own.
- A person-started session stores person-owned labels on its initial record, before the
  first change notification is broadcast.
- `start_agent` and workflow starts create labels with owner `agent` on the new record.
- `finish_turn` applies additions and removals to the current agent before the turn's final
  record is persisted and broadcast.
- Person mutations use the same validator and the daemon's normal changed-agent path.
