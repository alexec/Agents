# Research: Session labels

## Decisions

### Persist labels on each session record

**Decision**: Add an optional-on-disk, empty-by-default typed labels collection to `Agent`.
Save it through `AgentStore` and the daemon's existing `changed(_:)` path.

**Rationale**: A session is already the durable unit shown on Mac and Remote. The daemon is
the only writer, and agent-change broadcasts already update all connected devices. Archive
and unarchive keep the same record, and slim archived records are made whole before save.
This keeps server projects consistent because each server daemon owns the same kind of
records.

**Alternatives considered**: A separate label database would add synchronization, archive,
and server-sharing paths. Keeping labels only in UI state would lose them on restart and
would not let agents discover them.

### Derive project suggestions from labels in use

**Decision**: Build the project's suggestion vocabulary from its session records, including
archived sessions. Each label entry retains its canonical display spelling while it is
attached. A duplicate normalized label added elsewhere reuses that spelling. Once no
session has the label, omit it from suggestions; a later addition establishes a new
canonical spelling.

**Rationale**: This gives labels their required project scope without a second project
store. The record owner and host already identify the project. Archived labels are still
attached to sessions and remain discoverable.

**Alternatives considered**: A persistent project registry would preserve a spelling even
after the label had been removed everywhere, but it conflicts with the requirement that an
unused label leaves the project list and creates cleanup state. First surviving spelling is
the canonical value until the project no longer uses that normalized label.

### Normalize and validate in shared core logic

**Decision**: Trim surrounding whitespace, reject empty values, reject values over 24
characters, compare normalized values without regard to case, and cap each session at five
distinct labels. Keep the first spelling established for a normalized project label. Make
one shared policy function produce accepted changes and actionable refusal messages.

**Rationale**: Person UI, MCP tools, workflows, and server projects must agree on the same
rules. The daemon can use this logic as the authority while the UI uses it for responsive
validation and suggestions.

**Alternatives considered**: Letting each surface normalize on its own permits duplicates
and inconsistent refusal behavior. Counting before normalization permits spelling
variations to evade the five-label limit.

### Represent ownership as person or session agent

**Decision**: Each session label has owner `person` or `agent`. An agent-owned label is
owned by the agent represented by that session, regardless of whether it was supplied at
`start_agent`, by `finish_turn`, or by a workflow. The person chose this rule for helpers:
the helper owns the labels supplied when it starts. A separate chat that reads an older
session's history starts with no inherited labels.

**Rationale**: The spec distinguishes two authorities and does not require attribution to a
particular tool call or workflow run. Session-scoped ownership allows the new agent to
continue managing agent labels while preserving person labels against agent changes.

**Alternatives considered**: Assigning helper labels to its starter would require a new
cross-session mutation tool and leave the helper unable to remove its own labels. A
workflow-owner case would add a third visible authority contrary to the two-chip styles
in the spec. Automatic inheritance would imply a successor link that feature 065 does not
create; the person chose independent new chats.

### Extend MCP and person-facing mutations at their existing boundaries

**Decision**: Add `labels` to the existing `start_agent` input, add `add_labels` and
`remove_labels` to `finish_turn`, add owner-aware label values to `list_sessions` and
`list_my_agents`, and add a typed daemon request for person label changes. Add person labels
to `StartRequest` so the initial record and first broadcast already carry them. `SessionLookup`
formats `list_sessions`; `DaemonCore+Helpers` formats `list_my_agents`. Validate and
apply all changes before saving the agent record; refuse a whole invalid request without
partial mutation.

**Rationale**: `AppService` owns MCP schemas and decoding; daemon APIs carry typed requests;
the daemon owns records and can enforce the person/agent authority distinction. `SessionLookup`
already formats project-scoped discovery.

**Alternatives considered**: Adding a separate label MCP tool is possible, but duplicates
the requested end-of-turn operation and requires briefing changes. Allowing agents to
mutate the record through a generic endpoint would broaden authority unnecessarily.

### Treat workflow labels as file configuration

**Decision**: Add a `labels` setting to workflow front matter and `WorkflowSettings`, then
apply it when each workflow-started agent is created. Workflow files remain the source of
configuration; no separate UI editor is required.

**Rationale**: `WorkflowFile` already parses front matter and `DaemonCore+Workflows` creates
each run's agents from those settings. The workflow page presents settings derived from the
file and does not rewrite its prompt/configuration content.

**Alternatives considered**: A separate workflow-label database would split the source of
truth. A page-only control would not cover manually edited files or scheduled starts.

### Share label filtering across the two app session lists

**Decision**: Put `label:<value>` parsing and text conjunction in shared core logic used by
both `SessionsColumn` and the Remote project page. Remote must search all archived sessions
for the project, including records beyond the ten it normally fetches for display.

**Rationale**: The Mac list already owns grouping, search, and empty-search state. The
Remote project page has no search field and holds only a short page of archived records.
Shared matching preserves current title/report search and avoids a phone-only spelling
rule; a daemon-backed archived search avoids false empty results.

**Alternatives considered**: A separate label picker can complement typed filtering, but
does not satisfy the specified `label:perf` query. Filtering only Remote's loaded agents
would miss archived matches. Replacing text search would regress an existing path.

## Repository patterns confirmed

- `Agent` is a Codable record saved whole by `AgentStore`; old records need a decoding
  default when new optional fields are absent.
- `DaemonCore.changed(_:)` persists and broadcasts changes; do not save labels from views.
- `AgentRow` and Remote `AgentCard` resolve current values by ID, which is appropriate for
  live label updates. `SessionsColumn` owns Mac search and empty results.
- `AppService` defines MCP schemas and routes calls; `DaemonAPI` and `DaemonCore` are the
  relay and policy boundary.
- `WorkflowFile` and `WorkflowSettings` define file-based workflow settings; workflow starts
  converge on `DaemonCore+Workflows`.
- `.specify/memory/constitution.md` is the untouched template, so no repository-specific
  gates could be derived from it.
