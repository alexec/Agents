# Research: Retire Archived Agents

Each decision below says what was chosen, why, and what else was considered. Figures come from
the real store on 2026-09-25: 283 agents in 814 MB, 268 of them archived.

## R1. Archived agents stay in the agent table, slimmed

**Decision**: Keep archived agents in `DaemonCore.agents`, with `advertisedOptions`,
`availableCommands` and `plans` emptied in memory. `Agent.isSlim` marks the record. It is kept
in memory only and left out of `CodingKeys`, like `rawState` and `host`.

**Rationale**:
- Those three lists are 94% of an archived record: 24,486 B on average, and 1,393 B without
  them.
- The daemon reads agents by id in 138 places across 27 files, and walks `agents.values` in 38
  more. Every one of those keeps working for an archived agent without being touched.
- SC-004 allows 20 MB for 1,000 archived agents. Slim agents take about 1.4 MB.

**Alternatives considered**:
- *A separate `archived: [UUID: ArchivedSummary]` table, with archived agents out of `agents`.*
  It is cleaner, but every call site that misses it becomes "That agent is not here" for an
  archived agent. Unarchive, branch, starter names, workflow Recent runs, events and the
  worktree pages would all need auditing, and a miss is a visible regression.
- *Only slimming the wire, as `archivedCommands: false` already does.* That does nothing for
  the daemon's memory or its start.

## R2. Saving a slim agent never loses the lists

**Decision**: `AgentStore.save` does not write a slim agent as it is. It reads `agent.json` off
disk, puts that file's `advertisedOptions`, `availableCommands` and `plans` into the agent, and
writes the result. If the file cannot be read, the save is refused and logged, the same way an
invalid record is refused today. The whole agent is never written with those lists empty.

**Rationale**: A slim agent is changed now and then (retirement notes, an unread flag, a title),
and each change goes through `changed` and then `save`. Writing a slim copy would throw away the
options and commands for good, and unarchiving would bring back a chat with no command menu.
Doing the merge in the store means no caller can forget it.

**Alternatives considered**:
- *Never saving a slim agent, and writing only the index.* Then `agent.json` would drift from
  the index, and a lost index could not be rebuilt truthfully.
- *Writing the lists to a separate file.* That changes the record format for every agent to
  solve a problem only archived ones have.

## R3. Start reads one index, not every archived record

**Decision**: `archive.json` holds each archived agent's slim record, `sizeOnDisk` and
`archivedAt`. It is written whole and atomically whenever an archived agent is archived,
unarchived, retired, or its slim fields, size or note change.

At start the daemon:

1. lists `agents/`
2. reads `archive.json`
3. reads in full every directory the index does not name
4. puts any of those that turn out to be archived into the index, and writes it once

A missing or unreadable index is simply the case where the index names nothing. That is also
the first start after this feature ships.

**Rationale**: Listing a directory of 1,000 entries is cheap. Decoding 1,000 files of 24 KB
each is what makes start slow. On the other side, the daemon can crash between writing
`agent.json` and writing `archive.json`:

- If it crashes before the index has the entry, the directory is read in full at start and
  added.
- If it crashes after an unarchive but before the index lost the entry, the index says archived
  and `agent.json` says live. The rule is that `agent.json` wins. At start, an indexed entry
  whose file is newer than the index is read in full.

**Alternatives considered**:
- *Decoding only a few keys of each `agent.json`.* `JSONDecoder` parses the whole document
  whatever it is asked for.
- *SQLite.* A new dependency and a new failure mode, for a list the size of a small JSON file.

## R4. Tombstones in one append-only file, written first

**Decision**:
- A tombstone is one line of `retired.jsonl`. The whole file is loaded at start into
  `retired: [UUID: Tombstone]`: a year of heavy use is under 30 MB, and a typical store holds a
  few hundred KB.
- `retire` appends the line and calls `fsync` before anything else, and only then deletes the
  directory.
- At start, any id in both `retired` and `agents/` has its directory deleted before the table
  is filled. Retiring is then finished, and the agent is never listed live next to its own
  tombstone.
- Deleting removes `transcript.jsonl`, then `agent.json`, then the directory, so a half-deleted
  directory is never read as an agent: without `agent.json` it is unreadable, and it is skipped.

**Rationale**: FR-017 and SC-006 want no moment when the agent has neither a record nor a
tombstone. Writing the tombstone first gives that. Using one file keeps retired agents out of
`agents/`, which is the directory the daemon lists and reads.

**Alternatives considered**:
- *Replacing `agent.json` with a small tombstone in the same directory.* The daemon would list
  and open a directory per retired agent for ever, and "not an agent" would become a third kind
  of file in `agents/`.
- *Keeping tombstones in `archive.json`.* That mixes a cache that can be rebuilt with a record
  that cannot. The index can be thrown away; tombstones cannot.

## R5. The retention rules, as one pure function

**Decision**: `RetentionPlan.decide(archived:holds:settings:now:saneNow:) -> RetentionDecision`
lives in Core. It answers with the ids to retire in order, the `Retirement` note for each
archived agent, and `overCap: OverCap?`. The rules are:

1. **Off**: when `keepFor == .forever` and `cap == .none`, nothing is retired and every note is
   nil (FR-010).
2. **Floor**: an agent with `archivedAt > now − 24 h` is never picked (FR-006).
3. **Held**: an agent with a hold is never picked. Its note is `.held(hold)` (FR-007).
4. **Age**: every other agent whose `archivedAt ≤ saneNow − keepFor` is picked (FR-002).
5. **Cap**: after age, while the total of `sizeOnDisk` over archived agents still kept is above
   the cap, the next agent is picked, oldest `archivedAt` first. Ties go to the oldest
   `lastActivityAt` (FR-003, and the edge case for legacy agents).
6. **Notes**:
   - `.at(archivedAt + keepFor)` when that is within 7 days
   - `.nextUnderCap` for the first agent rule 5 would pick next if the total grew by one more
     archiving. Rule 5 uses the total today; the note uses today's total plus the median
     archived size.
   - otherwise nil (FR-023)
7. **Over cap and stuck**: if the total is still over the cap after rule 5, `overCap` says by
   how much, and names the reasons still holding agents: "on its first day", "worktree has
   work in it", "a workflow run is going" and "open in a window" (FR-013).

**Clock sanity**: `retention.json` keeps `lastCheck` (wall clock) and `lastCheckUptime`
(`ContinuousClock`). At each check, `elapsedWall − elapsedUptime` is the jump.

- A forward jump of more than a day sets `saneNow = lastCheck + elapsedUptime`, so age counts
  only real time, until a day of real time has passed since the jump (edge case).
- An `archivedAt` in the future counts as now.
- Across a restart there is no uptime to compare. `saneNow` is `min(now, lastCheck + 1 day)`
  for the first check after a start, so a clock wound forward while the daemon was down retires
  nothing by age that day.

**Legacy**: a record with `state == .archived` and no `archivedAt` gets `archivedAt` set to the
start time when it is first indexed. It is written to the record and the index once (FR-008).

**Rationale**: Every rule is a function of values that can be passed in. The tests can walk the
clock, the sizes and the holds without a daemon, like `LeaseBook` and `EventLog`.

## R6. What archiving lets go of

**Decision**: `archive` calls `forget(liveStateOf:)` after `move(.archived…)`. That removes the
agent's key from every per-agent map `DaemonCore` holds for live agents, listed field by field
in [data-model.md](data-model.md#maps-dropped-on-archive), and then slims the record. `stops`
is kept (Complexity Tracking in the plan).

The guard that FR-027 requires is `stops`, as it is today. The drop runs only after `stop` has
returned. Any work that saw the old count still sees a different one, because `archive`
increments `stops` before anything else.

A test archives an agent mid-turn and checks two things. First, the turn's late reply writes
nothing. Second, after the drop, every map in the list has no key for the agent. The test
reads the keys through a `liveStateKeys(for:)` debug accessor, so a map added later that is
not dropped fails it.

**Rationale**: The list grows with every feature, and the spec's assumptions ask for it field by
field. A test that enumerates the maps is what keeps the list from rotting.

## R7. Holds

**Decision**: holds are computed only for candidates, those past their time or chosen by the
cap, just before retiring, so the hourly check costs nothing when nothing is due. The holds are:

- **Worktree**: the agent has an app-made worktree, `removalFacts` says it exists, and it has
  `uncommitted > 0` or `unmerged` is true. It is *not* a hold when a non-archived agent uses the
  same worktree root. The agent is retired and the worktree is left alone (FR-018, spec Story 5
  scenario 2).
- **Workflow run**: `workflowRuns.values` contains a run whose `agentID` or
  `triggeringAgentID` is the agent.
- **Open**: any `presences` value has `watching == id`, or the agent was made whole in the last
  10 minutes (R10).

A candidate found held is skipped. Its note becomes `.held(hold)` and is saved, so the row
explains itself until the next check. Retire now uses the same holds, with an explicit check
when the menu opens, so the item can be disabled with its reason (FR-020).

## R8. Settings: a daemon file, pushed to servers like cost limits

**Decision**:
- `retention.json` holds `RetentionSettings { keepFor: KeepFor, cap: Cap }`, plus the clock
  fields from R5.
- `retention/state` returns `RetentionState`: the settings, `archivedCount`, `archivedBytes`,
  `retiredCount` and `overCap`.
- `retention/set { settings, confirmed }` works in two steps:
  - Unconfirmed, it runs `RetentionPlan` with the new settings and answers
    `RetirePreview { count, bytes }` without changing anything.
  - Confirmed, or when the preview is empty, it saves, runs a check at once, and broadcasts
    `retention/changed`.
- The app follows `setCostLimits`:
  - After setting its own daemon, it calls `retention/set` with `confirmed: true` on every
    connected server.
  - `refreshServer` does the same on connect.
  - A server with no answer keeps its own file until the next connect (FR-012).

**Rationale**: It is the same path the Mac's other rules already take to servers (037 R7), so
there is no second way of doing it.

**Alternatives considered**: *UserDefaults in the app.* The daemon runs without a window, and
on Linux, and it is the daemon that retires.

## R9. On the wire

**Decision**:
- **`Agent.archivedAt`** and **`Agent.retirement`** are optional coded fields. An older Remote
  keeps them in `unknownFields` and re-encodes them untouched.
- **`ProjectSummary.retiredCount: Int?`** is new. `costToDate` already exists and simply
  includes retired costs. Unknown keys are ignored by older decoders; only unknown *enum cases*
  break them (040's warning was about `AgentGroup` keys in `counts`).
- **`agents/retired { folder?, ids? }`** returns `[Tombstone]`, newest retired first, with a
  limit of 200.
- **`agents/list`** leaves out retired agents, since they are no longer in the table.
- **Slim agents** go on the wire as they are, and `archivedCommands` is honoured as today. When
  a watching presence makes an agent whole, it is broadcast again through `agent/changed`, which
  is how the Mac's archived chat gets its command list.
- **The retired page**: `openAgent(id)` on the Mac, and the phone's navigation to an agent,
  fall back to `agents/retired { ids: [id] }` when the model has no agent with that id. With a
  tombstone they show the retired page; without one, today's not-found behaviour.

**Failures**:
- `-32050 agentRetired`: any agent method that names an id found only as a tombstone. Its
  message is the retired sentence.
- `-32051 retireRefused`: Retire now on an agent that is not archived, or is held. Its message
  gives the reason.

## R10. When to check, and when to let go

**Decision**:
- The check runs 30 s after start, then hourly on a timer task like `eventPruner`, then after
  every `retention/set` and every archive or unarchive that crosses the cap. It runs on the
  actor, but git work happens in `removalFacts` off it, as archiving does. Start is never
  held up (FR-004): `loadFromDisk` finishes retires that were cut off (R4), but never starts new
  ones.
- An agent is made **whole** when:
  - a presence starts watching it
  - `transcript(_:)` is asked for it
  - `unarchive` or `branch` is called on it

  Making it whole reads `agent.json` and puts the three lists back. `lastWhole[id]` is set to
  now.
- A 60 s sweep slims again any archived agent with no watching presence whose `lastWhole` is
  older than 10 minutes (FR-025).

**Rationale**: Ten minutes covers going back and forth between chats without reading the record
again each time, and after that it is cheap to read again.
