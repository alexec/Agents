# Data Model: Projects, not agents

## Project

A directory the user works in. Lives in `AgentsKit/Model/Project.swift`.

| Field | Type | Meaning |
|---|---|---|
| `folder` | `URL` | The directory. Resolved, standardised, no trailing slash. This is the identity. |
| `archivedAt` | `Date?` | When the user archived it. `nil` means live. |
| `addedAt` | `Date` | When the record was made. Orders projects that have no agents yet. |
| `unknownFields` | `[String: JSONValue]` | Kept and written back, as `Agent` does, so an older build does not delete what a newer one wrote. |

Derived, never stored:

| Property | Rule |
|---|---|
| `id` | The `folder`. A project *is* its directory; there is no second identity to keep in step. |
| `name` | `folder.lastPathComponent`, extended leftwards until unique across the listed set (see `ProjectNaming` below). |
| `isArchived` | `archivedAt != nil`. |
| `exists` | Whether the directory is there, stamped by the daemon when it lists. |
| `lastActivityAt` | The newest `lastActivityAt` of its agents, or `addedAt` when it has none. |

### Invariants

- Exactly one project per distinct folder. Two records for one folder is a bug, not a state.
- Exactly one agent with `role == .lead` per project. Zero means one has not been made yet, which
  `projects/list` fixes on sight; two is a bug.
- A project record exists only when there is something to remember: it is archived, or it was added
  before any agent ran in it. Every other project is derived from its agents.
- Archiving never touches the directory. Nothing in this feature creates, moves, renames or deletes
  anything under `folder`.

### Lifecycle

```text
                 first agent starts in the folder
   (nothing) ─────────────────────────────────────▶ live, derived, no record
                 user adds the folder
   (nothing) ─────────────────────────────────────▶ live, record with addedAt

   live ──── archive (no live agents) ───▶ archived (archivedAt set)
   live ──── archive (a live agent)   ───▶ refused, naming the agents
   archived ──── unarchive ───────────────▶ live (archivedAt cleared)
```

A derived project that is archived gains a record at that moment. A record whose project is
unarchived and which has agents could be dropped; it is kept, because `addedAt` is cheap and losing
it would reorder a sidebar for no gain.

### The lead's own lifecycle

```text
   project appears in projects/list ──▶ lead record written (no runtime, nothing spent)
   first prompt to the lead         ──▶ runtime starts via liveSession(for:)   [research §10]
   project archived                 ──▶ lead's state becomes .archived with the project
   project unarchived               ──▶ lead's state restored, transcript intact
```

The lead is created by `projects/list`, because that is the one call every window makes and the one
place a project is known to exist. Writing a record is a file write: no process, no tokens (FR-036).
A lead is never created by `start_agent`, and there is no other route to `.lead`.

## Storage

One file: `~/Library/Application Support/Agents/projects.json`, a JSON array of project records,
written whole on every change. Added to `StoreLocations` as `projects`.

```json
[
  { "folder": "file:///Users/alex/work/api", "addedAt": "2026-09-18T10:00:00.000Z" },
  { "folder": "file:///Users/alex/side/toy", "addedAt": "2026-09-01T09:00:00.000Z",
    "archivedAt": "2026-09-17T18:22:04.512Z" }
]
```

The lead is not in this file. It is an agent, found by `cwd` and `role`, so `projects.json` keeps
holding only what cannot be derived (research §13).

Whole-file writes are right here: the list is tens of entries for one person, it changes when a user
archives something, and one file that can be read with `cat` matches how agents are stored. A missing
or unreadable file is an empty list — every live project still appears, derived from its agents, and
only archived state is lost. That is the failure worth having.

## Agent

One new field, optional on read, so no migration:

| Field | Type | Meaning |
|---|---|---|
| `role` | `AgentRole` | `.worker` (the default, and what every existing record decodes as) or `.lead`. |

```swift
public enum AgentRole: String, Codable, Hashable, Sendable, CaseIterable {
    case worker
    case lead
}
```

A lead is an agent in every other respect — runtime, folder, conversation, state, transcript, cost,
context meter — which is what lets the chat view, the prompt bar, the permission flow and the store
work on it with no special case (research §13). Three guards make it a lead, and they are the whole
difference:

1. It is created with its project, never by the user, and never by `start_agent`.
2. It alone is given the `project` MCP server.
3. It cannot be archived, unarchived or deleted apart from its project.

Two existing fields do new work:

- **`cwd`** decides which project the agent belongs to. Matched exactly, after the same
  standardisation the project folder gets. `additionalDirectories` is ignored for this: a folder an
  agent may reach is not a folder it belongs to (FR-005).
- **`lastActivityAt`** orders every list in this feature, and for an archived agent it is when it was
  archived (research §2).

## AgentGroup

Derived, never stored. Lives in `AgentsKit/Model/AgentGroup.swift` so `swift test` can exhaust it.

| Group | Holds | Shown |
|---|---|---|
| `needsInput` | `state == .waitingOnUser` | First. |
| `working` | `state == .running` | Second. |
| `completed` | `state == .finished`, `state == .stopped` | Third, each row saying which and why. |
| `archived` | `state == .archived` | Only when the user turns the list on, below the rest. |

The lead is in none of them. It is pinned above the groups, and `AgentGroup(for:)` is only ever asked
about workers.

`AgentGroup(for: AgentState) -> AgentGroup` is total: every case of `AgentState` maps to exactly one
group, and a test asserts that over `AgentState.allCases`. A worker is therefore never in two groups
and never in none.

Within a group, agents are ordered by `lastActivityAt` descending.

## ProjectNaming

A pure function, `AgentsKit/Model/ProjectNaming.swift`:

```swift
func displayNames(for folders: [URL]) -> [URL: String]
```

Each folder gets its last path component, extended leftwards one component at a time until unique
within the set. Computed over the whole set so that a name is stable while the set is, and minimal.
Its own unit tests: no collision, one collision, a collision that needs two components, a folder at
the root, two folders whose paths differ only in case.

## ProjectSummary

What the daemon sends the app. A project plus the parts only the daemon can know:

| Field | Type | Meaning |
|---|---|---|
| `project` | `Project` | The record, or a derived one. |
| `name` | `String` | Disambiguated against the whole list the daemon is returning. |
| `exists` | `Bool` | Whether the directory is there now. |
| `lastActivityAt` | `Date` | Newest agent activity, or `addedAt`. |
| `counts` | `[AgentGroup: Int]` | How many workers in each group, so a sidebar row can say "needs you" without the app re-deriving it. |
| `leadID` | `UUID` | The project's lead, so the panel can pin it and selecting a project can open it. |
| `leadNeedsInput` | `Bool` | Whether the lead is waiting on the user. Counted into the sidebar's mark even though the lead is in no group (FR-045). |

`counts` is what lets FR-016 work for a project that is not selected, and it is the daemon's answer
rather than the app's so that every window agrees.
