# Data Model: Retire Archived Agents

## On the agent record (`Agent`, AgentsKitCore/Model/Agent.swift)

| Field | Type | Coded | Meaning |
|---|---|---|---|
| `archivedAt` | `Date?` | yes, `decodeIfPresent` | When it was last archived. Set by `move(.archivedByUser/.archivedByAgent)`, cleared by `.unarchivedByUser`. For a legacy archived record it is set to the first indexing time (FR-001, FR-008). |
| `retirement` | `Retirement?` | yes, `decodeIfPresent` | What the row says about retirement. Set only on archived agents, by the check; nil otherwise. |
| `isSlim` | `Bool` | **no** (not in `CodingKeys`, like `rawState`) | The three heavy lists are empty in memory and must be read back before a save (research R2). |

`Agent.slimmed()` returns a copy with `advertisedOptions`, `availableCommands` and `plans`
emptied and `isSlim = true`. `Agent.madeWhole(from disk: Agent)` puts them back.

**Invariants**, added to `AgentStore.refusal(for:)`:

- `archivedAt != nil` requires `state == .archived`.
- `retirement != nil` requires `state == .archived`.
- A slim agent is never encoded to `agent.json`. `save` merges from disk or refuses.

## Retirement (new, AgentsKitCore/Model/Retirement.swift)

```text
enum Retirement: Codable, Hashable, Sendable
  case at(Date)            // retired by age at this time; set when within 7 days
  case nextUnderCap        // the next to go if the archive grows
  case held(Hold)          // past its time, kept because of this
  case unknown(String)     // a case a newer daemon wrote; drawn as nothing

enum Hold: String, Codable, Hashable, Sendable
  case firstDay            // archived under 24 h ago (only reported in overCap)
  case worktreeHasWork     // app-made worktree with uncommitted or unmerged work
  case workflowRunning     // a workflow run it belongs to has not finished
  case openInWindow        // a window or device is watching it, or read it in the last 10 min
```

## Tombstone (new, AgentsKitCore/Model/Retirement.swift)

This is what is left of a retired agent (FR-015). It is under 2 KB, and a test encodes the
largest realistic one and checks that.

| Field | Type | From |
|---|---|---|
| `id` | `UUID` | record |
| `title` | `String?` | record, truncated to 200 characters |
| `project` | `URL` | `projectFolder` |
| `runtimeID` | `String` | record |
| `host` | `HostID` | the daemon's own host id (`.mac` on the Mac) |
| `createdAt`, `lastActivityAt`, `archivedAt`, `retiredAt` | `Date` | record, and now |
| `endedReason` | `EndedReason?` | record |
| `archivedReason` | `ArchivedReason` | record |
| `costToDate` | `[String: Decimal]` | record |
| `startedByWorkflow` | `String?` | record |
| `startedByRun` | `UUID?` | record |
| `startedByAgent` | `UUID?` | record |
| `worktreeName`, `worktreeBranch` | `String?` | `worktree` |
| `retiredBecause` | `RetiredBecause` | `.age`, `.cap`, `.person` |

Nothing else is kept: no transcript text, no prompts, no options, and no credentials.

## Retention settings (new, AgentsKitCore/Model/RetentionSettings.swift)

```text
struct RetentionSettings: Codable, Hashable, Sendable
  var keepFor: KeepFor   // .days7, .days14, .days30 (default), .days90, .forever
  var cap: Cap           // .gb1, .gb2 (default), .gb5, .gb10, .none
  var isOff: Bool { keepFor == .forever && cap == .none }
```

Unknown raw values decode to the default, so a newer file read by an older daemon never turns
retirement off by accident. "Off" is only ever what the person chose.

## Files (under the store root)

| File | Written | Read | Contents |
|---|---|---|---|
| `archive.json` | whole, atomically, on archive, unarchive, retire, and any check that changes a slim field, size or note | at start | `{ version: 1, writtenAt, entries: [{ agent: slim Agent, sizeOnDisk: Int, fileModifiedAt: Date }] }`. A cache: rebuilt if missing or unreadable (R3). |
| `retired.jsonl` | one tombstone appended per retirement, then `fsync` | at start, whole | One `Tombstone` per line. Never rewritten. A torn last line is skipped, like `events.jsonl`. |
| `retention.json` | whole, on `retention/set` and after each check | at start | `{ settings, lastCheck: Date?, lastCheckUptime: Duration? }`. The uptime is meaningful only within one daemon run; a new start treats it as absent (R5). |

`sizeOnDisk` is the total allocated size of the agent's directory. It is measured on archive,
at every check for agents it changed in since, and whenever an index entry is added.

## Daemon state (DaemonCore)

| New | Type | Meaning |
|---|---|---|
| `retired` | `[UUID: Tombstone]` | loaded from `retired.jsonl` at start |
| `retentionSettings` | `RetentionSettings` | from `retention.json` |
| `lastWhole` | `[UUID: Date]` | when a slim archived agent was last made whole; dropped when it is slimmed again |
| `archiveIndex` | `[UUID: IndexEntry]` | sizes and file dates for archived agents; written to `archive.json` |
| `retentionTimer` | `Task<Void, Never>?` | the hourly check, like `eventPruner` |
| `slimSweep` | `Task<Void, Never>?` | the 60 s let-go sweep (R10) |

### Maps dropped on archive

After `move(… .archivedBy…)` and `stop`, `archive` removes the agent's key from each of these
maps. **Already** marks the maps that some existing path drops today. The task is to make the
drop one call, `dropLiveState(for:)`, which a test enumerates (R6).

| Map | Keyed by | Today |
|---|---|---|
| `live` | agent | already (`forget`) |
| `eventTasks` | agent | already (`forget`) |
| `turnTasks` | agent | already, when the turn ends |
| `terminalServices` | agent | already (`killTerminals`) |
| `appTokens` | token → agent | already (`dropAppTokens`) |
| `shownPlanFiles` | agent | already (`archive`) |
| `openEventWaits`, `openEventWaitStarted` | agent | already (`endWait`) |
| `artifactEdits` | agent | only when the next prompt takes them. **Add** |
| `reportedChanges` | agent | never. **Add** |
| `shellWatchers` | agent | when the watching connection goes. **Add** |
| `interrupted` | agent | once told. **Add** |
| `resuming`, `sending` | agent | when the work ends. **Add** as a belt |
| `needsBriefing` | agent | on the next start of a conversation. **Add** |
| `held` | agent | when the queue drains. **Add** |
| `drafts` | draft id; entries naming the agent | **Add**, filtered by agent |
| `pendingPermissions`, `elicitations` | request; entries naming the agent | already answered or cancelled by `stop`; **Add** the filter as a belt |
| `deliveries`, `needRaisedAt`, `settlingTimers` | `NeedID`, naming the agent | when the need goes, which archiving causes. Checked by the test |
| `costReadings` | session reader | by its listener, deliberately late (see its comment). **Not** dropped here |
| `stops` | agent | **kept**: the stale-work guard (plan, Complexity Tracking) |

Maps keyed by connection (`presences`, `fileInterests`, `credentialOffers`,
`lentCredentials`) are not per agent and are not touched. Maps keyed by folder or name
(`reservedStarts`, `reservedWorktreeNames`, `fileWatches`, `branchWatchers`) are not per agent
either.

## Wire additions (DaemonAPI)

- `ProjectSummary.retiredCount: Int?`. `costToDate` includes retired costs.
- `RetentionState { settings, archivedCount, archivedBytes, retiredCount, overCap: OverCap? }`
- `OverCap { bytesOver: Int, holding: [Hold: Int] }`
- `RetirePreview { count: Int, bytes: Int }`
- Requests and methods are in [contracts/daemon-api.md](contracts/daemon-api.md).

## State transitions

```text
live states ──archive──▶ archived (whole) ──60 s sweep, 10 min unwatched──▶ archived (slim)
                             ▲    │                                              │
                             │    └──────────────◀── watched / transcript / branch ┘
                             │
             unarchive (made whole first; archivedAt, retirement cleared)
                             │
archived (either) ──check: past time or over cap, no hold, not first day──▶ retired
archived (either) ──Retire now, confirmed, no hold──────────────────────────▶ retired
retired ── nothing. It is terminal: only its tombstone remains.
```

## Retire steps (each resumable)

1. Append the tombstone to `retired.jsonl` and `fsync` it. **If this fails**, stop: nothing
   has changed (disk-full edge case).
2. Put the tombstone in `retired`. Close the transcript handle. Drop the agent from `agents`,
   `archiveIndex` and `lastWhole`.
3. If an app-made worktree exists, is clean and merged, and no agent that is not archived uses
   it, remove it and its merged app branch, by `removeWorktreeIfDone`'s rule.
4. Delete `transcript.jsonl`, then `agent.json`, then the directory.
5. Write `archive.json`. Broadcast `agent/removed` (new, below) and `project/changed`, and
   raise the `agent.retired` event.

A start that finds an id in `retired` whose directory still exists runs steps 2 to 5 for it
before `agents/list` can be answered.

`agent/removed { agentID }` is a new notification. A window removes the agent from its lists.
An older phone ignores the unknown notification and drops the agent at its next list refresh.
`agent.retired` is added to 042's catalogue, with details `agent`, `agent_title`, `project`
and `because`.
