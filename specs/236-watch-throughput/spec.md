# Feature Specification: Watch throughput

**Feature Branch**: `236-watch-throughput`

**Created**: 2026-10-04

**Status**: Draft

**Input**: User description: "GitHub issue #236. Watch throughput: record per-session time splits (working, waiting for a lease, waiting on the person, waiting on agents or events, parked), sample machine signals (load against cores, swap, memory pressure, lease hold time against the usual), keep rolling baselines per kind of session, raise `project.slowdown` / `project.recovered` with hysteresis like `mac.disk_low` (#195), ship `.agents/workflows/investigate-slowdown.md` off by default to file or comment on one expedite issue, show a Throughput tile on the Dashboard with the Remote and web in step (#233), and prove it by replaying 2026-10-03/04."

## Why this feature exists

On 2026-10-04 Alex asked why agents had got slow (#234). The answer took an hour of
reading by hand:

- **Merge waves waited on a person.** On 10-03, the eleven merge agents from 11:41 PDT to
  19:53 PDT spent a median of **0 min** waiting on Alex. On 10-04 the wave 12+13 merge
  agent waited **70 min** (22:35–23:44 PDT), and the wave 14 merge agent waited
  **6 h 34 min** (01:00–07:34 PDT) of its 7 h 41 min. Both asked about the same timing
  tests (#225). (From the merge agents' `transcript.jsonl`: `elicitationAsked` →
  `elicitationAnswered`.)
- **Lane length hardly moved** (0.3–2 h). The long lanes were waiting, not working: #187
  waited all night for the screen. An alarm on raw length would have blamed the wrong
  thing.
- **The machine was oversubscribed, and nothing watched it.** Load was 113/175/117 on
  10 cores at 11:34 PDT, and 146.6 at 12:24. Swap was 4.5 of 6 GB. A host build that
  takes 2–4 min alone took 25–47 min (wf142: 2,844 s, from 13:55 PDT on 10-03).

The daemon already sees every moment a session starts or stops waiting. It just doesn't
add them up, compare them with the usual, or look at the machine. This feature does
that, says so once when things get slow (and once when they recover), and can start an
agent that finds the cause and writes it down the way #234 was written.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Each session's time is split by what it was waiting on (Priority: P1)

The lead opens a session that took 7 h 41 min. It shows **Working 1 h 07 · Waiting on
you 6 h 34 · Waiting for a lease 0 · Waiting on agents/events 0 · Parked 0**. The lead
can see at once that the time went on a question, not on work.

**Why this priority**: every other part of the feature (baselines, events, the workflow,
the tile) is built from these splits. This is also the per-agent view #234 asks for.

**Independent Test**: drive a scratch session through a turn, a lease wait, a form, a
`wait_for_event` and a park. Its splits add up to its wall-clock life (less Mac sleep),
each to within a second.

**Acceptance Scenarios**:

1. **Given** a session in a turn that calls `lease_resource` and is put in line, **When**
   the lease is granted 4 min later, **Then** those 4 min count as *waiting for a lease*,
   not *working*. This holds whether the call was held open or the turn ended while it
   waited in line.
2. **Given** a session that asked a form at 01:00 and was answered at 07:34, **When** its
   splits are read, **Then** *waiting on the person* is 6 h 34 min.
3. **Given** a session that ended its turn `blocked` on two agents with
   `check_again_in_minutes: 15`, **When** the first agent finishes 40 min later and the
   session resumes, **Then** 40 min count as *waiting on agents or events*.
4. **Given** a session parked overnight, **When** it is unparked, **Then** the night
   counts as *parked*, and nothing else.
5. **Given** the Mac slept for an hour during a session, **When** splits are read,
   **Then** that hour is *asleep* and is in no other split.

---

### User Story 2 - The project says once when it gets slow, and once when it recovers (Priority: P1)

At 01:15 PDT on 10-04, the wave 14 merge agent has been waiting on Alex for 15 minutes.
Merge agents usually wait 0 minutes. The project raises
`project.slowdown [signal: waiting_on_person, kind: merge, from: 0m, to: 15m,
worst: "Wave 14 merge (waiting on you 15m)"]`. It raises it once. It stays quiet while
the wait grows to 6 h, and raises `project.recovered` only after merge waits are back
near the usual.

**Why this priority**: an event is what turns watching into action. It is something
`wait_for_event`, a workflow `on:` and the lead can all use.

**Independent Test**: feed a scratch daemon synthetic sessions and machine samples with
a fake clock. Exactly one `project.slowdown` arrives per crossing, and one
`project.recovered` per recovery.

**Acceptance Scenarios**:

1. **Given** load at 2.3× cores for 10 minutes, **When** the next sample is taken,
   **Then** one `project.slowdown [signal: load]` is raised in each project with live
   sessions, and none on later samples while load stays high.
2. **Given** a raised `load` slowdown, **When** load falls below 1.5× cores for
   10 minutes, **Then** one `project.recovered [signal: load]` is raised.
3. **Given** load that dips under 2× cores for 3 minutes and climbs back, **When**
   samples continue, **Then** no `project.recovered` and no second `project.slowdown`
   are raised.
4. **Given** the daemon restarts while a signal is in slowdown, **When** it starts
   again, **Then** nothing is raised again for that signal (the state is kept on disk,
   as `diskLevels` is for #195).
5. **Given** fewer than 5 finished sessions of a kind, **When** one is slow, **Then**
   nothing is raised for that kind, because it has no baseline yet. The tile says
   "learning".

---

### User Story 3 - The machine is watched cheaply (Priority: P1)

Once a minute, the daemon reads load average, swap and the memory pressure level. That
costs a few system calls, with no processes started and no files walked. It keeps a
bounded history, so a later replay or investigation has the record that #234 lacked.

**Why this priority**: the real cause on 10-04 was the machine, and nobody had a record
of it.

**Independent Test**: run a scratch daemon for an hour. The machine history has 60
samples. Its size stays under the cap after a simulated 60 days. One sample costs under
1 ms of daemon time.

**Acceptance Scenarios**:

1. **Given** a build lease held for 31 min by a host build whose last 20 runs took a
   median of 3 min, **When** the lease is released, **Then** the hold is recorded
   against that command's usual time. With two more like it, a `lease_hold` slowdown is
   raised.
2. **Given** the Mac asleep, **When** it wakes, **Then** sampling resumes with no
   backlog and nothing is invented for the gap.

---

### User Story 4 - An agent finds the cause and writes it down (Priority: P2)

Alex turns on the *Investigate slowdown* workflow. The next `project.slowdown` starts an
agent. It reads the splits, the machine history, the build and wave logs, and the open
`expedite` issues. It then either comments on the open expedite issue that already
covers the cause, or files one new issue in the shape of #234: what was measured, why,
biggest first, and what to do. It changes no settings and stops nothing.

**Why this priority**: worth having once the signal exists, and useless without it.

**Independent Test**: run the workflow by hand ("Run now") with the replay's 10-04 01:15
event in its prompt, on a scratch project with a fake `gh`. It writes exactly one issue
body (or one comment). The body names build contention and the timing-test asks (#225),
with numbers that come from the replay.

**Acceptance Scenarios**:

1. **Given** an open issue labelled `expedite` that covers the signal (e.g. #234 for
   load), **When** the workflow runs, **Then** it comments on that issue with the new
   evidence and files nothing.
2. **Given** no open `expedite` issue covers it, **When** the workflow runs, **Then** it
   files one issue labelled `bug, expedite`, and the lead can find it.
3. **Given** the workflow ships in the repo, **When** a project opens, **Then** it is off
   (`enabled: false`) until the person turns it on.

---

### User Story 5 - Throughput on the Dashboard, on all three clients (Priority: P2)

The project's Dashboard shows a **Throughput** tile. It has:

- a status light (ok / slowdown, with the signals in slowdown);
- the median splits for each kind of session against their baselines;
- the machine signals now: load against cores, swap, memory pressure, and the build
  lease's hold against the usual;
- the five slowest sessions now, with their splits.

The Mac, the Remote and the web page all show the same tile.

**Why this priority**: the person needs to see it without waiting for an event. It is
also #234's per-agent tile.

**Independent Test**: on a scratch root seeded with the replay, the tile shows the same
values on the Mac (run-app) and the web page (headless Chrome), and on the Remote by
generic-sim build plus code reading.

**Acceptance Scenarios**:

1. **Given** a `load` slowdown, **When** the person opens the Dashboard on any client,
   **Then** the tile's light is red and says "Load 23 on 10 cores for 14 min".
2. **Given** no slowdown, **When** the tile is read, **Then** the light is green and the
   medians show beside their baselines.

---

### User Story 6 - Replaying 10-03/04 would have fired (Priority: P1)

A replay builds a synthetic timeline of 10-03/04 from what is on disk and runs it through
the same rules the daemon uses. It fires `project.slowdown`:

- for *waiting on the person* on wave 14 (01:15 PDT, 10-04);
- for *lease hold* on 10-03's slow builds;
- for *load* and *swap* on the 10-04 readings.

**Why this priority**: this is #236's "done when". It also guards the thresholds against
the one real incident we have.

**Independent Test**: the replay is a unit test over a committed fixture. See
§ Acceptance replay.

### Edge Cases

- **Two waits at once.** A session holds a form open while it is also in line for a
  lease. One split wins, by precedence: person > lease > agents/events > working >
  parked > idle. Splits never add up to more than wall-clock time.
- **Lease waits outside a turn.** After the 45 s hold, the lease call returns "still in
  line" and the turn usually ends. The session keeps counting *waiting for a lease* until
  it is granted or leaves the line (`Waiter` with `waitID == nil`).
- **Unaccounted endings and needs_answer, partly_done, stuck.** These are *waiting on the
  person* until the person's next prompt. A `done` ending is *idle*: not in a split that
  feeds a baseline.
- **Allowance waits (052).** A session waiting for a plan allowance to come back counts
  as *waiting on agents or events* with cause `allowance`, so it is not mistaken for slow
  work.
- **Daemon restart.** A daemon restart closes the open split at the last saved
  timestamp. The gap is *unknown*, never guessed into another split.
- **Clock jumps and sleep.** `mac.sleep`/`mac.wake` close and reopen splits. A
  wall-clock jump of more than 5 min between samples is treated as sleep.
- **Swap that never shrinks.** macOS keeps swap files after pressure has gone. Swap
  recovery also counts as met when the memory pressure level is normal for 30 min (see
  Q4).
- **Linux hosts.** Load comes from `/proc/loadavg`, swap from `/proc/meminfo`, and
  memory pressure from `/proc/pressure/memory` when it exists. Where it doesn't, that
  signal is "not available" and never fires.
- **A project with no sessions.** It gets no machine slowdown events, because the event
  fans out only to projects with a session that was not archived in the last hour.
- **Kinds with no baseline.** Kinds with fewer than 5 finished sessions say "learning"
  and never fire.
- **A wave the person answers in 5 min.** No event. The floor (15 min for person waits)
  keeps a baseline of 0 from firing on every question.

## Requirements *(mandatory)*

### Where the daemon sees each transition

Read from main at `28884102`. K = `Packages/AgentsKit/Sources/AgentsKit`,
C = `Packages/AgentsKit/Sources/AgentsKitCore`.

Today nothing keeps per-session durations. `turns.jsonl` holds transcript indexes only.
`move()` writes a timestamped `stateChanged` line for each state change, but the six
stored states do not separate the splits below. So the splits need their own small
accountant, fed from these points:

| Split | Starts at | Ends at |
|---|---|---|
| **Working** (in a turn, not waiting) | `beginTurn` → `move(.turnBegun/.promptSent)`: `K/Daemon/DaemonCore+Commands.swift:1208`, `:1259`. Every state change goes through `move()`: `K/Daemon/DaemonCore.swift:947`, which records at `:1033`. | `finishTurn`: `K/Daemon/DaemonCore+Commands.swift:1332`, `move(.turnEnded)` `:1445`. `turnFailed` `:1574`. Early end after finish_turn: `K/Daemon/DaemonCore+TurnEnds.swift:90`, `:116`. |
| **Waiting for a lease** | Queued: `LeaseBook.request` `C/Model/LeaseBook.swift:111`. The held-open call: `lease()` `K/Daemon/DaemonCore+Leases.swift:23`, `openWaitStarted` `:73-78`. Still in line after the 45 s hold: `waitLimitReached` `:549` (the `Waiter` keeps `askedAt`, `C/Model/Lease.swift:207`). | Granted: `settle` `K/Daemon/DaemonCore+Leases.swift:417`, `:428`, or `wake` `:453`. Left the line: `removeFromLine` `C/Model/LeaseBook.swift:199`, `giveUp` `:234`, `waitTimedOut` `:248`, `drop` `:210`. |
| **Holding a lease** (inside *working*, kept apart for the hold-time signal) | `lease.granted` via `raiseLeaseEvent` `K/Daemon/DaemonCore+EventSources.swift:198`. `Lease.grantedAt` `C/Model/Lease.swift:177`. | `release` `C/Model/LeaseBook.swift:162`, `end` `:182`, `lapse` `:273`, `dropLeases` `K/Daemon/DaemonCore+Leases.swift:308`. `lease.released` is raised from `:420`. |
| **Waiting on the person** | Permission: `K/Daemon/DaemonCore.swift:1393-1400` (`PermissionRequest.askedAt`, `C/Model/PermissionRequest.swift:13`). Form: `holdElicitation` `K/Daemon/DaemonCore+Serving.swift:85`, `askForm` `K/Daemon/DaemonCore+AppTools.swift:397`, `:437-440`. needs_answer / partly_done / stuck / unaccounted ending: `land()` `K/Daemon/DaemonCore+AppTools.swift:266` (`report.at`). | `answerPermission` `K/Daemon/DaemonCore+Commands.swift:2037-2050`. `answerElicitation` `K/Daemon/DaemonCore+Serving.swift:20`, `:55-58`. `withdrawElicitation` `:103`. The person's next prompt: `enqueue` `K/Daemon/DaemonCore+Commands.swift:621-624`. |
| **Waiting on agents or events** | `wait_for_event`: `K/Daemon/DaemonCore+EventWaits.swift:17`, with `eventWait.since` `:64-68` (`C/Model/EventWait.swift:12-24`). Blocked report: `land()` `K/Daemon/DaemonCore+AppTools.swift:296-310`, block built at `K/Daemon/DaemonCore+Blocks.swift:20`. Allowance: `Agent.allowanceWait` `C/Runtimes/Allowance/AllowanceWait.swift:5`. | `matchWaits` `K/Daemon/DaemonCore+EventWaits.swift:127`, `endWait` `:110`, deadline `:249`. `queueResume` `K/Daemon/DaemonCore+Blocks.swift:222` (`block.clearedAt`), `resumeDueBlocks` `:268`, `dropBlock` `:322`. |
| **Parked** | `park()` `K/Daemon/DaemonCore+Commands.swift:1910`. `whenTurnEnds` becomes parked in `move()`, `K/Daemon/DaemonCore.swift` ~`:995-1010`. | `unpark` `K/Daemon/DaemonCore+Commands.swift:1933`, `unparkQuietly` `:1941`, a prompt that unparks `K/Daemon/DaemonCore+Dispatch.swift:429`. |
| **Asleep** (taken out of all splits) | `machineChanged(.sleep)` `K/Daemon/DaemonCore+EventSources.swift:120-147` | `machineChanged(.wake)`, same place |
| *(clock ends)* | — | `archive()` `K/Daemon/DaemonCore+Commands.swift:1828` → `move(.archived…)`, `archivedAt` `K/Daemon/DaemonCore.swift:1018-1023` |

Gaps this feature closes:

- A lease wait inside a turn leaves the state `running`.
- No event is raised for being queued for a lease.
- Parking and unparking write no transcript line.
- An `endWait` leaves no timestamp.
- Nothing accounts for sleep.

### Functional Requirements

**Time splits**

- **FR-001**: The daemon MUST keep, for each session, the seconds spent in each split:
  *working*, *waiting for a lease*, *waiting on the person*, *waiting on agents or
  events*, *parked*, *idle* (finished, with nothing pending), *asleep* and *unknown*.
  It MUST also keep the split the session is in now and when it entered it.
- **FR-002**: Splits MUST be worked out by one pure function over the transitions in the
  table above, with precedence person > lease > agents/events > working > parked > idle.
  The daemon calls it from each of those points. Splits MUST add up to the session's
  wall-clock life.
- **FR-003**: Split totals MUST be kept on the session's record, so they survive restart
  and archive (`archive.json`). Each change of split MUST also be appended to a per-session
  log, bounded at 2,000 lines, so an investigation can read the timeline. Reading a
  session's splits MUST NOT replay its transcript.
- **FR-004**: Each session MUST have a **kind**:
  - *workflow run*, if a workflow started it;
  - *merge*, if it has the label `merge`, or its worktree is a merge-wave one (`wave-*`);
  - *lane*, if another agent started it;
  - *chat*, if the person started it.

  See Q2.
- **FR-005**: The splits MUST be readable by clients (session detail) and by agents
  through a read-only app tool, `read_throughput`. Agents cannot read the Agents root, so
  this is how the investigating workflow gets them.

**Machine signals**

- **FR-006**: The daemon MUST sample, about once a minute and never more often:
  - the 1- and 5-minute load average and the number of active cores;
  - swap used and swap total;
  - the memory pressure level (normal / warn / critical).

  It MUST use system calls only: no processes started, no files walked. It MUST run on
  the same 60 s rhythm as the disk check (`startWatchingDisk`,
  `K/Daemon/DaemonCore+Disk.swift:14-22`, started at `Daemon.swift:197`).
- **FR-007**: For each lease hold, the daemon MUST record the hold time and the
  **command** run under it. The command is the first build or test command the holder
  starts while holding the lease, normalised, e.g. `xcodebuild -scheme AgentsHost`,
  `swift test --package-path Packages/AgentsKit`, `scripts/web.sh test`. It is read from
  the holder's tool calls. The hold time MUST be compared with that command's rolling
  usual. A hold with no recognised command is compared with the resource's usual.
- **FR-008**: The machine history MUST be bounded:
  - one sample a minute for 24 h;
  - then one per 15 min (mean and max) for 30 days;
  - at most about 4,300 lines on disk, with the oldest dropped first.

  It MUST survive a restart. Sampling MUST pause while the Mac is asleep. A wall-clock
  gap of more than 5 min MUST be recorded as a gap, not filled in.

**Baselines**

- **FR-009**: For each project, kind of session and split, the daemon MUST keep the last
  20 finished sessions' values. The **baseline** is their median. The **recent value**
  is the median of the last 3 sessions of that kind, counting sessions still running at
  their totals so far, so that a wait in progress counts before it ends. A kind with
  fewer than 5 finished sessions has no baseline.
- **FR-010**: Lease hold baselines MUST be kept the same way, per command (last 20
  holds). Machine signals have fixed lines (FR-012) rather than baselines.

**Events**

- **FR-011**: Two events MUST be added to the event catalogue
  (`C/Model/EventCatalogue.swift`, beside `mac.disk_low` at `:142-147`) under a new
  `project` scope. They MUST be usable in `wait_for_event` and as workflow `on:`
  triggers:
  - `project.slowdown`, with details:
    - `signal` (fixed: `working`, `waiting_on_lease`, `waiting_on_person`,
      `waiting_on_agents`, `lease_hold`, `load`, `swap`, `memory_pressure`);
    - `kind` (fixed: `lane`, `merge`, `workflow`, `chat`; or `machine`);
    - `from` (the baseline or the line) and `to` (now);
    - `since`;
    - `worst`: up to 5 sessions, each with title, id and the split that dominates,
      trimmed to `EventDraft.maximumDetailLength`.
  - `project.recovered`, with details `signal`, `kind`, `from`, `to` and `lasted`.
- **FR-012**: A signal MUST go into slowdown when:

  | Signal | Slowdown when | Recovered when |
  |---|---|---|
  | session splits (per kind) | recent > max(2 × baseline, baseline + floor) | recent < max(1.5 × baseline, baseline + floor ÷ 2) |
  | `lease_hold` (per command) | median of the last 3 holds > max(2 × usual, usual + 5 min) | median of the last 3 < 1.5 × usual |
  | `load` | 5-min load ≥ 2 × cores for 10 min | 5-min load < 1.5 × cores for 10 min |
  | `swap` | used ≥ 50% of total and ≥ 2 GB, for 10 min | used < 35% of total, or pressure normal for 30 min |
  | `memory_pressure` | warn or critical for 10 min | normal for 10 min |

  Floors: 15 min for *waiting on the person*, *waiting on agents or events* and *waiting
  for a lease*; 10 min for *working*. All of these numbers MUST be settings with these
  defaults, readable from `.agents/project.json` under `"throughput"`, the way
  `"diskSpace"` is read (`ProjectConfig.swift:31`, `:61-70`).
- **FR-013**: Each signal MUST raise `project.slowdown` once per crossing and
  `project.recovered` once per recovery, through the one `raise()` funnel
  (`K/Daemon/DaemonCore+Events.swift:17-35`). The per-signal level MUST be persisted
  beside `diskLevels` in `EventState` (`K/Store/EventStore.swift:205`), so a restart
  does not raise it again. This is the #195 pattern: `DiskSpace.next(from:_:_:)`
  (`C/Model/DiskSpace.swift:178-195`), a pure function from the previous level and a
  reading to the new level and an optional crossing.
- **FR-014**: Session signals MUST be raised in the project the sessions belong to.
  Machine signals MUST be raised once in each project with a session not archived in the
  last hour. A machine slowdown names that project's worst sessions.
- **FR-015**: Signals MUST be checked:
  - on each sample;
  - when a session changes split (debounced to 2 s, like `scheduleDiskCheck`,
    `K/Daemon/DaemonCore+Disk.swift:35-46`);
  - after each lease release (`K/Daemon/DaemonCore+EventSources.swift:205-207`);
  - on wake.

**Workflow**

- **FR-016**: The repo MUST ship `.agents/workflows/investigate-slowdown.md` with
  `on: [project.slowdown]`, `agent: new`, `cooldown: 6h` and `enabled: false`. Its prompt
  is drafted in [`investigate-slowdown.md`](investigate-slowdown.md) beside this spec.
  The run gets the event's sentence and details in its prompt, as #199's run does
  (`K/Daemon/DaemonCore+Workflows.swift:863-879`).
- **FR-017**: The workflow's agent MUST only read: `read_throughput`, `list_sessions`,
  `read_session`, `list_resources`, build and wave logs, `gh issue list/view`. It MUST
  write exactly one of: a new issue labelled `bug, expedite`, or one comment on an open
  `expedite` issue that covers the same cause. It MUST NOT change settings, leases or
  workflows, stop, park or archive anything, build or test.

**Dashboard tile**

- **FR-018**: Each project's Dashboard MUST show a **Throughput** tile that the host
  keeps. It has:
  - a status light (ok / slowdown, with the signals in slowdown, and "learning" for kinds
    with no baseline yet);
  - for each kind, a table of recent against baseline for each split;
  - the machine signals now, with a sparkline over the last 24 h;
  - the 5 slowest sessions in progress, with their dominant split.

  How a host-kept tile fits the Dashboard is Q1.
- **FR-019**: The Mac (`App/Sources/Dashboard/DashboardPage.swift`), the Remote
  (`Remote/Sources/Dashboard/DashboardPage.swift`, through `Shared/UI/Dashboard/TileCard.swift`)
  and the web page (`Web/src/views/Dashboard.tsx`) MUST show the same tile in the same
  branch. The commit MUST carry the three-client lines (#233). The parity table
  (`specs/071-web-remote/walks/parity.md`) MUST gain a row. Session splits in session
  detail MUST also be on all three.
- **FR-020**: The tile MUST update when a signal crosses, and otherwise at most once a
  minute. It MUST NOT write a committed tile file every minute (`.agents/dashboard/` is
  committed).

**Replay**

- **FR-021**: A replay builder MUST derive a fixture from the logs (see § Acceptance
  replay). The fixture holds hashed session ids, kinds, timestamps, splits and machine
  samples only: no prompts, no messages, no paths in the home folder. The builder MUST
  never copy an agent record or an Agents root (a scratch daemon resumes copied agents
  live, #227/#228).
- **FR-022**: The same pure functions the daemon uses (FR-002, FR-009, FR-012) MUST run
  over the fixture in a unit test with a fake clock, and MUST give the events in SC-001.

### Key Entities

- **Time split**: one of *working*, *waiting for a lease*, *waiting on the person*,
  *waiting on agents or events*, *parked*, *idle*, *asleep*, *unknown*. A session has
  totals for each, a current split and when it entered it, and a bounded log of changes.
- **Session kind**: lane, merge, workflow run or chat.
- **Machine sample**: time, 1- and 5-min load, cores, swap used and total, memory
  pressure level.
- **Lease hold**: resource, holder, command, granted at, released at, and how it ended.
- **Baseline**: the last 20 values per project × kind × split, or per command for holds.
- **Signal level**: ok or slowdown, per project × signal (× kind or command), with since,
  persisted.

## Acceptance replay

### What is on disk for 2026-10-03/04

All times are PDT, with UTC in the files.

- **Session timelines**: `~/Library/Application Support/Agents/agents/<id>/transcript.jsonl`.
  All 144 agents from those two days are still there; retirement is after 7 days.
  - `stateChanged` gives running, finished, waitingOnUser, stopped and archived.
  - `elicitationAsked`/`elicitationAnswered` and `permissionAsked`/`permissionAnswered`
    give waits on the person.
  - `workReported` gives outcome and block.
  - `runtimeNote` lines "Leased build until …" and "Released build." give lease holds.
  - `toolCall`/`toolCallUpdate` give command spans.
  - `userMessage.from` gives person against app.
- **Lifecycle and leases**: the root's `events.jsonl` has:
  - `agent.started`, `parked`, `archived` and `blocked`;
  - `lease.granted`/`released` (367/356 from 10-03 00:00 PDT);
  - `person.away`/`back`;
  - `mac.sleep`/`wake`.
- **Waves**:
  - The `wave-<YYYYmmdd-HHMMSS>` worktree names give start times.
  - `git reflog --date=iso main` gives the fast-forwards.
  - `/private/tmp/main-restart-all-<sha>.log` and `/private/tmp/ship-app-<sha>/` give ship
    ends.
  - The merge agents are the sessions whose first prompt says "You are the merge agent
    for wave …".
- **Build times**: `/private/tmp/run-*-build.log`, about 60 from those days. Duration is
  modification time minus birth time (`stat -f '%B %m'`). This matches #234: wf142 2,844 s,
  storm 1,853 s, v187 1,779 s, b164 1,537 s, against c234's 145 s.
- **Load**: only two readings survive.
  - #234's reading at 11:34 PDT on 10-04: 113/175/117.
  - `/private/tmp/t225-load{1,2,3}.uptime` (12:20–12:26 PDT on 10-04): the 1-min load
    rises from 7.98 to 146.60. The 5-min load is over 20 in every sample, and the 15-min
    load was already 35 at 12:20.
- **Swap**: only #234's reading at 11:34 PDT on 10-04 (4.5 of 6 GB). Memory pressure:
  none recorded. The unified log may still hold memorystatus lines for a few days (Q5).

### How the fixture is built

A script (`scripts/throughput-replay.sh`, read-only) does this:

1. Walk the transcripts and `events.jsonl` for 10-03 00:00 to 10-05 00:00 PDT.
2. Turn each session into split transitions with the same rules as FR-002.
3. Classify each session's kind. Merge agents are told apart by their first prompt, since
   the label did not exist then.
4. Read the build log times as lease holds keyed by their command.
5. Add the load samples, and #234's 11:34 reading as a sample held for 10 min. That
   reading's 15-min average of 117 means the 5-min load was over 20 throughout
   11:19–11:34.
6. Write `specs/236-watch-throughput/replay/2026-10-03-04.jsonl`, with derived values only
   (FR-021).

The fixture is committed. The unit test (FR-022) and the workflow's "Run now" check
(User Story 4) both read it.

### What it must fire (computed by hand from the transcripts, 2026-10-04)

Merge agents' waits on the person:

| Merge agent (PDT start) | Life | Working | Waiting on the person |
|---|---|---|---|
| 11 agents on 10-03, 11:41–19:53 | 0.4–1.5 h | 0.2–1.4 h | 0 (one 18 min, the rest ≤ 5 min) |
| Wave 12 (21:15) | 0.36 h | 0.27 h | 5 min |
| Waves 12+13 (22:05) | 1.96 h | 0.79 h | **70 min** |
| Wave 14 (00:05, 10-04) | 7.68 h | 1.11 h | **6 h 34 min** (ask 01:00, answer 07:34) |
| Wave 15 (07:44) | 1.86 h | 1.19 h | 40 min (two asks) |

- With the baseline at 0 and a recent value of the last 3 including the one in flight:
  - Waves 12+13: the recent median is 5 min, under the 15-min floor. No event.
  - **Wave 14 fires at 01:15 PDT**: `waiting_on_person`, kind `merge`, from 0 to 15 min.
  - It recovers once the last 3 merges' median is back under 7.5 min. In the replay that
    happens after the two merges on the afternoon of 10-04, which waited 0 min each.
- **Lease hold fires on 10-03** once the median of the last 3 host-build holds passes
  2× the usual. wf142 (13:55–14:42, 2,844 s) and b164 (15:42–16:08, 1,537 s) are each
  about 10× a 2–4 min usual. The exact time is for the replay to compute.
- **Load fires** from #234's 11:34 reading on 10-04, and is in slowdown through 12:26 by
  the t225 samples.
- **Swap fires** from the same 11:34 reading (4.5/6 GB = 75%, ≥ 2 GB).
- **Lanes do not fire** on length alone. #187's night falls under *waiting for a lease*
  (screen) or *waiting on agents or events* (`person.back`), which is the right blame. The
  replay must show which, and SC-001's cap bounds how often lanes fire.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: The replay of 2026-10-03/04 raises `project.slowdown`:
  - for `waiting_on_person` (kind merge) at wave 14 by 01:20 PDT on 10-04;
  - for `lease_hold` on 10-03;
  - for `load` and `swap` on 10-04.

  It raises no more than 2 slowdowns per signal per day. Each one is followed by at most
  one `project.recovered`.
- **SC-002**: For every session in the replay, the splits add up to its life within
  1 second. The merge agents' *waiting on the person* matches the table above within a
  minute.
- **SC-003**: Machine sampling costs under 1 ms a sample and under 1 MB on disk after
  30 days. The daemon starts no process to sample.
- **SC-004**: Run on the replay's wave 14 event, the investigating workflow writes one
  issue or one comment. It names build contention (load, swap, slow holds) and the
  timing-test asks (#225), with numbers from the replay, and takes no other action.
- **SC-005**: The Throughput tile shows the same values on the Mac, the Remote and the
  web page for the same root, and the parity table has its row.
- **SC-006**: With this live, the lead can answer "where did the time go?" for any
  session or wave from the tile or `read_throughput`, without reading transcripts by
  hand.

## Docs *(mandatory)*

- `docs/reference/events.md` — add: `project.slowdown`, `project.recovered`, the
  `project` scope, and their details.
- `docs/reference/workflows.md` — add: the *Investigate slowdown* workflow, and that it
  is off by default.
- `docs/reference/settings.md` — add: the `"throughput"` keys in `.agents/project.json`
  and their defaults.
- `docs/explanation/throughput.md` — add: what the splits mean, how baselines and
  hysteresis work, and why length alone is the wrong signal (the #234 story).
- `docs/how-to/` (the Dashboard page) — change: the Throughput tile.
- `README.md` events list (`:256-261`) — change: the two events.

## Assumptions

- The Mac is the host that matters. Linux hosts get the same signals where `/proc`
  offers them, and none where it doesn't.
- Durations count wall-clock time, less sleep, not CPU time.
- Session kinds are decided by labels, worktree names and who started the session. No
  new field is asked of agents, apart from the lead labelling merge agents `merge` (Q2).
- The investigating workflow runs Claude, like the other shipped workflows. Filing a
  GitHub issue is allowed for this workflow only.
- The workflow ships only in this repo's `.agents/workflows/`. There is no mechanism to
  seed workflows into other projects (as for #199).
- This spec does not fix the slowness. #234's items (shared caches, the build lease at 2,
  #225, #202) are separate. This feature measures and reports.

## Open questions for Alex

Claude (#236 spec) has written down a recommendation for each. Alex, these are yours to
answer:

1. **How the Throughput tile is kept.** Every Dashboard tile today is an agent's
   committed file. 074 put built-in tiles out of scope, and per-minute values would churn
   git.
   - **(a) Recommended:** a host-kept tile, served live by a new `throughput/state` call
     (like `disk/state`), drawn first on the Dashboard, never written to
     `.agents/dashboard/`.
   - (b) The host writes an ordinary tile file only when a signal crosses.
   - (c) An agent keeps it, through a workflow.

   Alex, which?
2. **How merge sessions are told apart.**
   - **Recommended:** the lead labels merge agents `merge`, and `wave-*` worktrees count
     too.
   - Or a new `kind` argument on `start_agent`.

   Alex, is a label enough?
3. **The 2× and the floors.** The defaults (2× baseline, 15-min floor for person waits,
   last 3 against last 20) fire on wave 14 at 01:15 but not on waves 12+13 (70 min, with
   a 5-min median). Alex, should waves 12+13 have fired too? That needs a recent value of
   the single latest session for kinds with few runs.
4. **Swap recovery.** macOS swap rarely shrinks once used. Recommended: swap counts as
   recovered when memory pressure has been normal for 30 min, even if swap stays high.
   Alex, agreed?
5. **Saving the memory-pressure record now.** The unified log may still hold
   memorystatus history for 10-03/04, but only for a few more days. Saving it means a
   heavy `log show` while #234 has the machine. Alex, do you want it saved (after the
   pause), or is the 11:34 reading enough?
6. **What the investigating agent may do.** As specced it may file or comment on one
   issue and nothing else. Alex, should it also be allowed to message the project lead,
   or to start one expedite lane itself?
