# Data Model: What Survives a Restart

Five things become durable. Three are the daemon's, one is a line in a conversation, one
is the window's. Nothing existing changes shape; two existing types gain a conformance and
one gains a field.

---

## The daemon's: attention notes

**Where**: `<root>/attention.json`. New file, beside `projects.json`, `workflows.json` and
`devices.json`. Read whole, written whole, atomically. The daemon is its only writer.

### `AttentionRecords`

The whole file.

| Field | Type | Meaning |
|---|---|---|
| `raised` | `[RaisedNote]` | When each outstanding need was first seen. |
| `deliveries` | `[Delivery]` | Where each delivered need is showing. |
| `withdrawing` | `[PendingWithdrawal]` | Withdrawals decided but not yet handed over. |

### `RaisedNote`

| Field | Type | Meaning |
|---|---|---|
| `need` | `NeedID` | Which need. |
| `at` | `Date` | When the daemon first saw it. Never moves while the need is outstanding. |

Mirrors `DaemonCore.needRaisedAt` one-for-one. An array rather than a dictionary because
`NeedID` is a tagged object, not a string, and a JSON object cannot be keyed by one.

### `Delivery` *(existing type, gains `Codable`)*

| Field | Type | Meaning |
|---|---|---|
| `needID` | `NeedID` | Which need. |
| `to` | `Surface?` | Where it is showing. `nil` is nowhere reachable, or being watched. |
| `alertedAt` | `Date` | When the person was last actually buzzed. |
| `alertCount` | `Int` | How many times. |

No new fields. `NeedID` and `Surface` are already `Codable` as tagged objects. **Carries
nothing about what the need says** — FR-007. The headline lives on `Need`, which is
derived and never stored.

### `PendingWithdrawal`

| Field | Type | Meaning |
|---|---|---|
| `need` | `NeedID` | Which need is over. |
| `device` | `UUID` | Whose banner has to come down. |
| `decidedAt` | `Date` | When. Used for the seven-day cap. |

A withdrawal for the Mac is not in here: the Mac's notification is taken down by the
window, which connects before it can be wrong.

### Rules

- A `RaisedNote` exists for every need the daemon currently believes outstanding; the
  entry is removed the moment the need is met, which is what makes a question asked again
  later a new need with a new time (FR-002 and the spec's second edge case).
- A `Delivery` exists only for a need that has been put somewhere. At most one per need,
  across every surface.
- A `PendingWithdrawal` is created when a delivered need is found to be over and its
  surface is a device. It is removed when the post has been handed to somebody, when its
  device is no longer known (FR-006), or after seven days.
- A record naming a surface the daemon does not know is dropped on load, not acted on.
- An unreadable file is no notes at all: the daemon starts, and behaves exactly as today's
  does (FR-026).

---

## The daemon's: workflow runs in flight

**Where**: `<root>/workflows.json`, as one more array on the existing `WorkflowRecords`.

### `WorkflowRecords` *(existing, gains one field)*

| Field | Type | Meaning |
|---|---|---|
| `states` | `[WorkflowState]` | Unchanged. |
| `lastTickAt` | `Date?` | Unchanged. |
| `runs` | `[WorkflowRun]` | **New.** Every run in flight. |

### `WorkflowRun` *(existing type, unchanged)*

Already `Codable` and already carries everything needed: `id`, `workflowID`, `folder`,
`trigger`, `triggeringAgentID`, `depth`, `agentID`, `startedAt`.

### Rules

- Written when a run is claimed, again when its agent id is known, and removed when the
  run is released — the three places that already touch `workflowRuns` in memory.
- Loaded into memory **before** recovery, keyed by `folder + workflowID` as in memory
  today. See research §7 for why the order is not negotiable.
- Pruned in `startWorkflows()`, once the agents and the workflow files are both known:
  - a run whose agent no longer exists, or is archived → released, and **nothing chained
    on its completion fires** (FR-012), because the run did not complete;
  - a run whose workflow file has gone → released the same way;
  - a run whose agent is still there → kept in flight, whatever state recovery left it in.
- A run older than seven days is released on load. A run in flight for a week is a run
  whose agent will not be finishing.

---

## The conversation's: a question that ended unanswered

**Where**: the agent's `transcript.jsonl`, as an ordinary appended entry.

**Shape**: `TranscriptEntry.Kind.runtimeNote(String)` — an existing kind, with its wording
a new constant on `RuntimeNote` beside `stoppedWithDaemon`. No new kind, so a build that
predates this feature reads the line rather than skipping it. See research §9.

### Rules

- Written when a permission request or an elicitation is outstanding and one of three
  things happens: the runtime process exits, the person stops the agent, or the daemon
  restarts.
- Written **before** the entry recording the ending (FR-015), so the conversation reads in
  the order things happened.
- Not written when the question was answered, declined, cancelled or withdrawn — each of
  those already appends its own closing entry.
- **Not** a passing note: it must not be added to `RuntimeNote.isPassing`, or the chat
  will drop it as soon as anything follows it.
- One line per question, so an agent holding two questions when its runtime exits gets two.

---

## The window's: drafts

**Where**: `UserDefaults`, one entry per draft, JSON-encoded. The types live in
`AgentsKitCore` so they can be tested; the store takes its `UserDefaults` as a parameter,
as `SidebarFrame` already does.

### `DraftKey`

| Case | Meaning |
|---|---|
| `agent(UUID)` | Words typed at an existing conversation. |
| `newAgent(folder: URL?)` | A conversation that does not exist yet. `nil` is the bar that has no project behind it. |

Rendered to a defaults key with a fixed prefix, so the whole set can be enumerated for
pruning without an index to keep in step.

### `Draft`

| Field | Type | Meaning |
|---|---|---|
| `text` | `String` | What has been typed and not sent. |
| `attachments` | `[Attachment]` | Staged beside it. `Attachment` is already `Codable`. |
| `mentions` | `[FileMention]` | Files named in the text. |
| `start` | `StartDraft?` | Present only for `newAgent`. |
| `editedAt` | `Date` | For the staleness sweep. |
| `droppedInlineData` | `Bool` | Whether something by value was too big to keep. |

### `StartDraft`

| Field | Type | Meaning |
|---|---|---|
| `cwd` | `URL?` | The folder chosen. |
| `runtimeID` | `String?` | The runtime chosen. |
| `folders` | `[URL]` | Additional folders. |
| `servers` | `[MCPServer]` | Servers attached. |
| `chosen` | `[String: JSONValue]` | Options set on the form. |

Every field mirrors one that `AppModel` holds today (`draftCwd`, `draftRuntimeID`,
`draftFolders`, `draftServers`, `draftChosen`).

### Rules

- Saved as typing settles, not on every keystroke.
- **Discarded the moment the text is sent** (FR-021). A draft exists only until it becomes
  a prompt.
- Discarded when its conversation no longer exists or has been archived (FR-022), swept
  when the agent list arrives from the daemon.
- Discarded after thirty days untouched, so twenty abandoned drafts do not become
  permanent.
- One draft per conversation, the same in every window (FR-023, as amended).
- Inline attachment data is capped per draft. Over the cap, the text and every
  by-reference attachment are kept, the inline blocks are not, and `droppedInlineData` is
  set so the strip can say so.
- An entry that will not decode is discarded, not migrated.

---

## What does not change

- `Need` stays derived and is never stored. There is still exactly one definition of what
  wants a person.
- `Agent`, `transcript.jsonl`, `projects.json`, `devices.json`, `limits.json` and
  `spend.json` are untouched.
- No wire method is added or altered. `attention/pending` already carries needs and
  deliveries to a surface that has just connected, and it will now be answering from facts
  that survived.
