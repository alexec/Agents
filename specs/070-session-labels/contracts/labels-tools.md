# Label contracts

This file records the user-visible tool and daemon behavior. Wire keys use the repository's
existing Codable camel-case request conventions; MCP argument names are snake case.

## Shared label rules

- Trim surrounding whitespace before storing or comparing.
- Accept 1–24 characters after trimming; reject empty and over-limit values.
- Compare without regard to case. Preserve the project's canonical spelling while at least
  one session uses the normalized value.
- Allow at most five distinct labels per session.
- Validate a change as a whole. On refusal, return a reason and leave the session unchanged.
- The owner is either `person` or `agent`. Person changes may add/remove either owner.
  Agent changes may add allowed labels and remove only agent-owned labels.
- If an agent adds a value already present as a person-owned label on that session, keep
  the person-owned value and return a refusal explaining the ownership conflict.

## MCP `start_agent`

Add optional argument:

```json
{"labels": ["perf", "#42"]}
```

Labels are validated before the helper is created and are stored on that helper as
agent-owned labels. The project label vocabulary supplies canonical spelling. Invalid
values or more than five distinct labels refuse the start without creating a partial helper.
Omission preserves existing behavior.

## MCP `finish_turn`

Add optional arguments:

```json
{"add_labels": ["perf"], "remove_labels": ["spike"]}
```

Both arrays default to empty. Apply both atomically to the calling session before its final
record update. The agent may remove only agent-owned labels. A request to remove a
person-owned value returns an actionable refusal and changes none of the requested labels.
If `add_labels` contains a normalized person-owned value already on the session, preserve
that entry and refuse the label change. Existing finish-turn outcome, report, title,
suggestions and after-turn behavior remain as specified by the current contract.

## Person-started sessions

Add an optional labels array to the existing `DaemonAPI.StartRequest`. The daemon
validates the whole request before creating an `Agent`, assigns `person` ownership to
all accepted labels, and writes them on the initial record. The first card therefore
already carries its labels. Old clients that omit the field still start without labels.

## MCP `list_sessions` and `list_my_agents`

Both tools return text, as they do today. Append each session's display labels and their
owners in readable text, for example `Labels: perf (person), #42 (agent).` Sessions without
labels need no label clause. Existing session identity, title, state, and project scoping
do not change.

## Person-facing daemon mutation

The typed label-change request identifies the session and carries `add` and `remove` arrays.
It does not accept an owner from the caller: the daemon assigns `person` to additions and
permits removals of either owner. On success, the daemon saves through `changed(_:)` and
broadcasts the updated `Agent`. On refusal, no field changes.

## Workflow front matter

Add optional `labels` to the existing workflow settings front matter:

```yaml
labels:
  - nightly
  - maintenance
```

Apply the labels as agent-owned labels to every session that workflow run starts. Validate
them using shared label rules. Labels alone do not require runtime-option negotiation:
`WorkflowSettings.isEmpty` continues to mean no runtime options were requested. A workflow
with no `labels` retains existing behavior.

## Archive and separate chats

Archiving and unarchiving the same session do not alter its label list. A new chat that
uses `read_session` to inspect an older chat starts with no inherited labels.
