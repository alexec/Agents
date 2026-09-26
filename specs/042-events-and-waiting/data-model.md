# Data Model: Events and Waiting

These are the types, files and state changes. Types in AgentsKitCore are shared by the Mac and
the phone. Everything marked (Mac) is daemon-only. The reasons behind each choice are in
[research.md](research.md), cited as Rn.

## Event (Core)

| Field | Type | Notes |
|---|---|---|
| `position` | `Int64` | Increasing and never reused (R6). Identity. |
| `name` | `String` | `subject.what_happened`, lowercase, dotted (FR-002) |
| `at` | `Date` | When it happened, or when it was noticed for missed changes (R8, R9) |
| `lastAt` | `Date?` | Set when repeats were folded in (R14) |
| `count` | `Int` | 1, or more when coalesced (FR-031) |
| `scope` | `EventScope` | `.mac` or `.project(URL)`, with the folder standardised |
| `sentence` | `String` | Plain language, written when it was raised, e.g. "Checks failed on #41 Fix login redirect" |
| `details` | `[String: String]` | Keys come from the kind (see [contracts/catalogue.md](contracts/catalogue.md)). Agents are named by id plus `agent_title`. |
| `publisher` | `EventPublisher?` | Only for `custom.*`: the agent's id and title at publish time |
| `message` | `String?` | Only for `custom.*`, ≤ 500 characters |
| `chainDepth` | `Int` | The depth a workflow fired from this event takes (R7) |
| `consequences` | `[Consequence]` | Appended as they happen (R13) |

Validation:

- `name` must match `^[a-z][a-z_]*\.[a-z][a-z0-9_]*$`.
- Every name outside `custom.` must be in the catalogue.
- `details` has at most 10 keys, and each value is at most 200 characters.
- `message` is at most 500 characters.

## EventScope (Core)

`enum EventScope: Codable, Hashable { case mac; case project(URL) }`. It is shown as "This Mac"
or as the project's name.

## Consequence (Core)

```text
enum Consequence: Codable, Hashable {
  case woke(agentID: UUID, title: String)
  case fired(workflowID: String, folder: URL, agentID: UUID?)
  case refused(workflowID: String, folder: URL, reason: WorkflowRefusal)
  case couldNotWake(agentID: UUID, title: String, reason: String)
}
```

Each case carries what it needs to link to its agent or workflow (FR-027). Titles are copied at
the time, so a consequence still reads correctly after its agent is archived.

## EventKind and EventCatalogue (Core)

| Field | Type | Notes |
|---|---|---|
| `name` | `String` | `pull_request.merged` |
| `subject` | `EventSubject` | `agent`, `workflow`, `pullRequest`, `branch`, `lease`, `mac`, `person`, `cost`, `server` or `custom`. These drive the page's filter capsules (Agents, Workflows, Pull requests, Branches, This Mac, Custom). |
| `scope` | `EventScopeKind` | `.mac`, `.project`, or `.either` (cost) |
| `details` | `[String]` | The keys it carries, which are also the keys a pattern may filter on |
| `meaning` | `String` | One sentence used by `list`, by `manage_workflows` and by the workflow row (FR-024) |
| `aliases` | `[String]` | Old trigger names that answer to it: `agent-finished`, etc. |
| `glyph` | `String` | ● ⟳ ⑂ ⎇ ⌘ ✦ (wireframes §5) |

`EventCatalogue.all` is a static array. `custom.<name>` is a family, not an entry: its details
are free-form, and `publisher` and `message` are always present. `EventCatalogue.describe()` is
the one text block that both `list` and `manage_workflows` return.

## EventPattern (Core)

| Field | Type | Notes |
|---|---|---|
| `name` | `String` | A full name, `subject.*`, or `custom.<name>` |
| `filters` | `[String: String]` | Each key must be in the kind's `details`, or free-form for `custom.*`. Values are compared as strings, and a number filter matches `"41"`. |

`matches(_ event: Event) -> Bool` is the single matcher used by waits and workflows alike (R1).
Parsing refuses an unknown name, `other.*` where `other` is not a subject, and an unknown filter
key. Each refusal gives the valid choices.

## WorkflowTrigger (Core, changed)

- A new case: `.event(EventPattern)`.
- New: `var pattern: [EventPattern]`, which gives today's cases' equivalents. For example,
  `agentStopped` gives `[agent.stopped, agent.failed]` (FR-022). `schedule` and `unrecognised`
  give `[]`.
- `summary` for `.event` uses the kind's `meaning`, narrowed by filters ("When pull request #41
  is merged").
- **Wire**: `.event(p)` encodes as `.unrecognised(name: p.name, keys: p.filters as JSONValue)`,
  and decodes back when the name parses (R12). The old nine cases are unchanged on the wire.

## WorkflowOutcome (Core, changed)

`.ran` and `.refused` gain `causingEvent: EventPosition?`. It is encoded only when present and
decoded if present, so older phones ignore it (FR-030).

## EventWait (Core)

It lives on `Agent.eventWait: EventWait?` (R3).

| Field | Type | Notes |
|---|---|---|
| `id` | `UUID` | |
| `patterns` | `[EventPattern]` | One or more, any of which will do (FR-006) |
| `from` | `Int64` | Matches only events with `position > from`. The default is the log's head at the time of the call (R6). |
| `deadline` | `Date?` | |
| `since` | `Date` | When it began |
| `ending` | `EventWaitEnding?` | `nil` while open |
| `resumePromptID` | `UUID?` | Set in the same write as `ending` when a resume is queued (R5) |

`EventWaitEnding`:

- `.matched(position, extraMatches: Int)`
- `.timedOut`
- `.cancelled(by: .agent | .person | .prompt | .stopped | .archived)`
- `.couldNotWake(reason)`

State transitions:

```text
            wait_for_event
  (none) ───────────────▶ open ──match, call open──────▶ (none)         answered in the call
                           │ ──match, call closed──────▶ ended(matched)  + prompt queued, same write
                           │ ──deadline────────────────▶ ended(timedOut) + prompt queued
                           │ ──cancel_wait / ✕ / prompt / stop / archive ─▶ (none)  no prompt
                           │ ──new wait_for_event──────▶ open (replaced)
                           └─ resume fails ────────────▶ (none) + consequence couldNotWake + transcript note
  ended ──prompt sent─────▶ (none)
```

After a restart:

- An `open` wait is re-armed, with its deadline timer and matching.
- An `ended` wait with an unsent `resumePromptID` sends the prompt once.
- Events are never back-filled (FR-014).

Grouping (`AgentGroup`): an open `eventWait` while the state is not `starting`, `running` or
`waitingOnUser` gives `.blocked`. As with a block, wanting a person still outranks it.

## WaitStatus (Core)

`static func status(for agent: Agent, names: (UUID) -> String) -> WaitStatus?`

- `line`: `◷ Waiting for pull_request.merged · #44 · since 23:30 · until 09:00`
- `mark`: `◷ Waiting for pull_request.merged #44`
- `cancellable`: `true` for an `eventWait`, and `false` for a 039 block (a block goes when the
  person prompts, as today)

A 039 block on agents and an `agent.finished` wait filtered to those agents give identical text
(FR-012, R4).

## Files (Mac)

### `events.jsonl`, under the store root

It is append-only, with one JSON object per line. There are three line shapes:

```text
{"event": {…Event without consequences…}}
{"consequence": {…Consequence…}, "position": 1042}
{"repeat": 1042, "at": "2026-09-25T07:40:12Z"}
```

On load, lines are folded in order. A torn last line is dropped. Pruning rewrites the file
through a temporary file and a rename (R14). The page reads from the in-memory copy, never from
the file.

### `events-state.json`, under the store root

```text
{
  "nextPosition": 1043,
  "branchTips": { "<folder>": { "main": "<oid>", "042-events…": "<oid>" } },
  "pullRequestsSeen": { "<folder>": [ { number, checks, review, conflicts, lastCommentAt } ] },
  "publishes": { "<agentID>": [ "2026-09-25T07:01:00Z", … ] },      // last hour only
  "costCrossings": { "2026-09-25": ["day", "agent:<id>"] }
}
```

It is written whole on change, the way `leases.json` is. `nextPosition` is written before the
event line is appended (R6).

## Wire (Core `DaemonAPI`)

| Shape | Fields |
|---|---|
| `EventsPage` | `events: [Event]` (newest first), `waiting: [WaitingAgent]`, `hasMore: Bool` |
| `EventsListRequest` | `before: Int64?`, `limit: Int` (≤ 200), `scope: EventScope?`, `subjects: [EventSubject]?` |
| `WaitingAgent` | `agentID`, `title`, `folder`, `status: WaitStatus`, `cancellable` |
| `CancelWaitRequest` | `agentID` |
| `events/changed` | `EventsChange { event: Event?, waiting: [WaitingAgent] }`. It carries the new or updated event (a repeat or a consequence) and the full waiting strip. |

The full request and reply shapes are in [contracts/daemon-api.md](contracts/daemon-api.md).
