# Implementation Plan: Retire Archived Agents

**Branch**: `agents/write-spec-spec-only` (feature `051-retire-archived-agents`) | **Date**: 2026-09-25 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `specs/051-retire-archived-agents/spec.md`

## Summary

Archived agents stay in the daemon's agent table, as they do today, but **slim**. A slim agent
is the full record without the three lists that make up nearly all of it: the options and
commands the runtime advertised, and its plans. On the real store on 2026-09-25 an archived
record averaged 24.5 KB, and 1.4 KB without those three lists. Everything else about the agent
is still there. So the 138 places in the daemon that look an agent up by id keep working
unchanged. The alternative was to move archived agents out of the table, and that would have
meant auditing every one of those call sites (research R1).

A slim agent is made **whole** again when something needs the lists:

- a window or phone reports it is watching the agent
- the agent is unarchived
- it is branched from
- its transcript is paged

After ten minutes with nobody watching it, it goes back to slim. The full record stays on disk
the whole time. Saving a slim agent **never** writes the slim copy over it. `AgentStore.save`
reads the three lists back from disk first (R2).

At start the daemon does not read every archived `agent.json`. It reads **`archive.json`**, one
index file holding every archived agent's slim record, its size on disk and its archive time.
Any agent directory the index does not account for is read in full, which is how the index
mends itself after a crash or on the first start with this feature (R3).

**Retirement** is a pure decision in Core, `RetentionPlan`. It takes the slim archived agents,
their sizes, what holds each one, the settings, the clock and the last sane time. It returns:

- the agents to retire, in order
- what each row should say
- whether the archive is over the cap with nothing more it can retire

The daemon runs it at start (in the background), 30 s later, then hourly, and on every change
to the settings. For each agent it picks, retiring takes three steps, in this order:

1. Append a tombstone to **`retired.jsonl`**, and `fsync` it.
2. Remove the agent's worktree by archiving's own rule, if it is app-made, still exists and is
   clean.
3. Delete the agent's directory, then drop it from the table and from the index.

A start that finds a tombstone whose directory is still there finishes the job before listing
anything. So no agent is ever gone without a tombstone (FR-017, R4).

Tombstones are served, never mixed into `agents/list`:

- `agents/retired` returns them by project or by id.
- `ProjectSummary` gains `retiredCount`, and folds retired costs into its `costToDate`, so a
  project's total does not drop.
- Anything that names an agent the daemon no longer has asks `agents/retired` for it and shows
  the retired page.

The settings are a small daemon file, `retention.json`, following `cost/setLimits` and
`limits.json` exactly:

- `retention/state` reads them.
- `retention/set` changes them, with a `confirmed` flag. Unconfirmed, it answers with what the
  change would retire at once (FR-011).
- `retention/changed` is broadcast when they change.

The app pushes the same settings to every connected server on connect, as it does the cost
limits (037 R7). **Retire now** is `agents/retire`, with the same confirm shape.

On archiving, the daemon drops every per-agent map it keeps for live agents (FR-026, listed in
[data-model.md](data-model.md)). The one exception is `stops`: it is the counter stale work
checks, and it costs one `Int` (R6).

Each archived agent carries `retirement` on its record, set by the daemon at each check:

- `.at(date)` inside the last 7 days
- `.nextUnderCap`
- `.held(reason)`

The Mac and the phone draw the row note from it with one shared function.

## Technical Context

**Language/Version**: Swift 6 (strict concurrency), SwiftUI

**Primary Dependencies**:
- AgentsKit and AgentsKitCore, the in-repo package
- `git`, through `GitWorktrees` and `removalFacts`, which archiving already uses
- Nothing new. The Linux `agentsd` (037) builds the same code: nothing here imports Apple-only frameworks.

**Storage** (all under the store root):
- `agents/<id>/agent.json` and `transcript.jsonl` are unchanged. `Agent` gains `archivedAt: Date?` and `retirement: Retirement?`, both optional and decoded if present.
- `archive.json` (new) is the index of archived agents. It is written whole and atomically on archive, unarchive, retire and every check that changes a size or note. It is a cache: a missing or unreadable one is rebuilt by reading each directory once.
- `retired.jsonl` (new) is one tombstone per line, appended, never rewritten. Each tombstone is under 2 KB (FR-015).
- `retention.json` (new) holds the two settings and the last sane clock reading. It is written whole.

**Testing**:
- swift-testing in `Packages/AgentsKit`
- `RetentionPlan` is pure and gets the most tests: age, cap, the one-day floor, holds, clock jumps and legacy records.
- Store tests cover slim save, index rebuild, and the retire order with a kill at every step (SC-006). The kill is simulated with a store that throws after step *n*; no process is killed.
- Daemon tests with fake runtimes cover archive-then-retire, unarchive, branch, presence holding an agent open, the ten-minute let-go, and the map drop on archive.
- xcodebuild for the Agents and Remote schemes, one after the other.
- The run-app skill on a scratch root with a generated store of 1,000 archived agents, for SC-003 and SC-004.

**Target Platform**: The macOS app and `agentsd` (Mac and Linux). The iOS/iPadOS Remote shows the row notes, the retired page and the retired count. It gets no settings and no Retire now (FR-028).

**Project Type**: A desktop app with a daemon, and a companion iOS app

**Performance Goals**:
- Start with 1,000 archived agents within 10% of start with none (SC-003). That means one read of `archive.json` (about 1.5 MB) instead of 1,000 reads of 24 KB each.
- Daemon memory within 20 MB of a store with no archived agents (SC-004). About 1.4 KB per slim agent, so about 1.4 MB.
- A check does no git work unless an agent is past its time or over the cap. Then it runs one `removalFacts` per candidate, off the actor, like archiving does.

**Constraints**:
- A slim record must never reach `agent.json` (R2).
- The tombstone is written and synced before anything is deleted (FR-017).
- Nothing is retired within 24 h of archiving, or on a clock jump (FR-006).
- Older phones must keep decoding `Agent` and `ProjectSummary`. Only optional fields are added.

**Scale/Scope**:
- 4 daemon methods: `retention/state`, `retention/set`, `agents/retire`, `agents/retired`
- 1 notification: `retention/changed`
- 3 files: `archive.json`, `retired.jsonl`, `retention.json`
- 2 fields on `Agent`, 1 on `ProjectSummary`
- 1 Settings section on the Mac
- 1 row note, 1 retired page and 1 retired-count line, on both Mac and phone
- 1 menu item on the Mac

## Constitution Check

The constitution (`.specify/memory/constitution.md`) is still the unfilled template, so there
are no gates to check. The plan follows the repo's own working rules:

- **Settle the UX before depth.** Phase 2 builds the Settings section, the row notes, the
  retired page and the retired line first. They are driven by `retirement` values and
  tombstones written by hand into a scratch store, and screenshotted before any retiring code
  exists.
- **One path, not two.** Retirement has one entry, `retire(_:because:)`, used by the hourly
  check, the settings change and Retire now. Worktree removal reuses
  `removeWorktreeIfDone`'s facts and rule. Settings reach servers by the path cost limits
  already take.
- **Decide in one place.** `RetentionPlan` and the row words are pure and live in Core. The
  phone draws what the daemon sends and never decides.
- **Prove it running.** Quickstart §2 retires real agents on a scratch daemon with the clock
  injected. §3 measures start and memory on 1,000 generated archived agents. §4 kills the
  daemon mid-retire.
- **Never mutate source to prove a test.** The clock, the store's failure point and git's
  answers are injected.

Re-checked after design: still no violations. One exception is justified under Complexity
Tracking.

## Project Structure

### Documentation (this feature)

```text
specs/051-retire-archived-agents/
├── spec.md
├── plan.md              # this file
├── research.md          # R1–R10
├── data-model.md        # fields, files, the maps dropped on archive, state rules
├── quickstart.md        # scratch-root proof, 1,000-agent measure, kill test
├── contracts/
│   └── daemon-api.md    # methods, notification, failures, wire additions
├── checklists/
└── tasks.md             # /speckit-tasks, not yet
```

### Source Code

```text
Packages/AgentsKit/Sources/AgentsKitCore/
├── Model/Agent.swift                 # archivedAt, retirement; `slimmed()`; `isSlim` in memory only
├── Model/Retirement.swift            # NEW: Retirement (.at/.nextUnderCap/.held(Hold)), Hold, Tombstone
├── Model/RetentionSettings.swift     # NEW: keepFor (7/14/30/90/forever), cap (1/2/5/10 GB/none), isOff
├── Model/RetentionPlan.swift         # NEW: pure: candidates, order, floor, clock sanity, notes, overCap
├── Model/RetirementWords.swift       # NEW: row note, retired page lines, Settings sentences, confirm text
├── Daemon/DaemonAPI.swift            # methods, requests, RetentionState, RetirePreview, failures -32050/-32051
└── Client/AgentsModel.swift          # retention state, tombstones by id, retiredCount per project

Packages/AgentsKit/Sources/AgentsKit/
├── Store/AgentStore.swift            # slim-safe save; loadArchivedIndex; retire steps; finish on start
├── Store/ArchiveIndex.swift          # NEW: archive.json read/write/rebuild
├── Store/RetiredStore.swift          # NEW: retired.jsonl append+fsync, load
├── Store/RetentionStore.swift        # NEW: retention.json
└── Daemon/
    ├── DaemonCore.swift              # loadFromDisk reads index + live records; finishes interrupted retires
    ├── DaemonCore+Retention.swift    # NEW: check loop, holds, retire(_:because:), settings, preview
    ├── DaemonCore+Hydration.swift    # NEW: hydrate on watch/unarchive/branch/transcript; let go after 10 min
    ├── DaemonCore+Commands.swift     # archive sets archivedAt, slims, drops live maps; unarchive hydrates
    ├── DaemonCore+Runtimes.swift     # branch hydrates the source first
    ├── DaemonCore+Projects.swift     # retiredCount, retired costs in costToDate
    ├── DaemonCore+Attention.swift    # a presence watching a slim agent hydrates it
    └── DaemonCore+Dispatch.swift     # the four methods

App/Sources/
├── Settings/ArchiveSettingsView.swift  # NEW: count, size, keep-for, cap, over-cap line, confirm sheet
├── Projects/SessionsColumn.swift       # retired count line under Archived
├── AgentList/AgentRow.swift            # retirement note; Retire now in the menu
├── Chat/RetiredAgentView.swift         # NEW: shown for an id the daemon only has a tombstone for
└── AppModel.swift                      # retention calls; push to servers; openAgent falls back to tombstone

Remote/Sources/
├── Projects/ProjectPageView.swift      # retired count line
├── Projects/AgentCard.swift            # retirement note
└── Chat/RemoteRetiredView.swift        # NEW: the retired page

Shared/UI/                              # the note and the retired page body, if both apps can share them
```

**Structure Decision**: The existing layout. Pure rules go in AgentsKitCore/Model, next to 042's
`EventLog` and 036's `LeaseBook`. Files go in AgentsKit/Store. Daemon behaviour goes in a new
`DaemonCore+Retention` extension, following `+Leases` and `+Events`. There are no new targets.

## Complexity Tracking

| Exception | Why Needed | Simpler Alternative Rejected Because |
|-----------|------------|-------------------------------------|
| `stops` survives archiving (FR-026 says drop every live map) | It is the guard FR-027 requires. Stale work compares the count it saw with the current one, and a dropped entry reads as 0 again, so work that saw 0 would pass the guard. | Replacing it with a state check alone was considered. An archived agent can be unarchived and restarted before the stale work unwinds, and then its state no longer says "archived", while a counter still differs. One `Int` per agent is 8 bytes. |
| Slim agents in the main table rather than a separate archive table | Keeps 138 call sites correct without auditing each one. | A separate table is cleaner on paper, but every missed call site becomes "That agent is not here" for an archived agent: a regression across unarchive, branch, events, starter names and the workflow pages. |
