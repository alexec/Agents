# 051 walk notes

## Baseline (T002), before any change

Branch at `748445c` (main merged in). `swift test` in `Packages/AgentsKit`, twice, 2144 tests.

Failed in both runs, so failing on main without this lane:
- `noViewNamesAFontItself()`, `noTextIsPinnedToAPointSize()` (font-style checks over the app sources)
- `aQuietDirectLinkLosesAfterTheWindow()` (link timing)
- `theBinderWaitsForTheDaemonAndKeepsTheAnswerFromTheDevice()` (relay)

Failed in one run only (load flakes):
- run 1: `aDeviceBoundByTheBridgeCannotSpeakAsAnother()`, `anUnnamedDeviceIsWhoItFirstSaysItIs()`, `aDeviceDoesWhatTheRemoteDoesAndNothingPastIt()`
- run 2: `aPairedPhoneReachesTheDaemon()`, `aShellDoesNotHoldAWindowsConnectionOpen()`, `theDepthCeilingCountsFromTheRestoredRun()`, `aChainShortOfTheCeilingCarriesOnFromTheRestoredDepth()`, `theyComeBackMostRecentlyActiveFirst()`, `theyAreStartedOneAtATime()`, `anAgentFoundDeadOnStartUpIsPickedBackUpAndToldWhy()`, `theRestartWordsGoAheadOfWhatWasQueued()`, `severalInterruptedAgentsAreAllPickedBackUp()`

The restart-recovery tests (`theyComeBackMostRecentlyActiveFirst` and the rest) touch `loadFromDisk`, which US6 rewrites. Watch them in particular.

## Look gate (T019–T024), 2026-09-25

Scratch root `/tmp/run-051-look`, seeded with `scripts/seed-archived.swift` plus hand-written
`retirement` values, three tombstones, an event whose consequence names a retired agent, and
`retention.json`. The window was launched behind and driven only through accessibility and
window captures, because Alex was at the keyboard. Screenshots are in `look/`:

- `archived-list.png`: the Archived section with its three notes ("Retires in 5 days", "Next to
  be retired to stay under 2 GB" (truncated at this column width), "Kept: its worktree has work in
  it") and "3 older agents have been retired."
- `settings.png`: Settings ▸ Agents ▸ Archived agents. The confirmation sheet cannot show yet:
  `retention/set` does not preview until US3 (T039).
- `retired-page.png`: reached with a new debug-only `-open-agent <id>` launch argument. The link
  in an event's card is inside the card's single accessibility element, so no AX action reaches
  it.

The daemon answered `retention/state` with 3 archived, 172 KB and 3 retired. The project summary
had `retiredCount: 3`, and its cost ($5.61) included the retired agents' costs.

Two things found and fixed on the way: a retired agent's project URL has a trailing slash, so
`openAgent` now standardizes it; and the Mac's debug hook fires once, not on every reconnect.

Mistake on the way: `ui.swift press "Settings…"` matched "Services Settings…" and opened System
Settings on Alex's screen at 22:57:43. It was quit at once. Exact menu titles are pressed with
`/tmp/ax-exact.swift` from now on.

Alex approved the look as is (AskUserQuestion, 2026-09-25).

## US1 checkpoint on a scratch daemon, 2026-09-25

`/tmp/run-051`, seeded with 3 agents archived 31 days ago (2 MB transcripts), 2 at 29 days and
2 live. The branch's `agentsd` was started on it, with a held connection. At the first check,
30 s after start, `daemon.log` said "retiring … (age)" three times. `retired.jsonl` held exactly
the three seeded 31-day ids, and their folders were gone. `agents/list` still had the two 29-day
agents and the two live ones. `retention/state` said 2 archived (4 MB) and 3 retired.

## Routes to a retired agent (T045, SC-005)

Every route to an agent by id ends in one of two places, and both reach the retired page:

- `AppModel.openAgent(_:)` asks `agents/retired` for an id it has no agent for, and opens the
  tombstone's project. Used by the Events page (a consequence's link, the Waiting now strip), the
  Resources page, and the Go menu's next and previous. Seen on screen: `look/retired-page.png`.
- Routes that set `selection` directly: a workflow's row and page (Recent runs), a pull request
  row's agent and worktree, and the middle column. `ContentView` asks for the tombstone when the
  chat has a selection with no agent, and shows the retired page once it has one. Built; not yet
  clicked through.
- "Started by" on a live agent's row names a retired starter from its tombstone and adds
  "(retired)". This is the icon's help text on the Mac; `AgentsModelTests` checks it.
- The phone: `RemoteRoute.agent` shows `RetiredAgentPage` when it has no agent but has a
  tombstone, and asks for one otherwise. This covers a notification tap, the events list and
  project rows. The look on the phone is Alex's (T062).
- Limitation: the Mac asks its own daemon (`host: .mac`). A retired agent on a server is reached
  only where the route knows the server, which today none of these do.

## Start and memory (T053, SC-003, SC-004), 2026-09-26

The same stores run with main's `agentsd` (`14c9723`) and this branch's. `/tmp/run-051-big` held
1,000 agents archived 3 days ago plus 10 live (47 MB); `/tmp/run-051-small` held the 10 live only.
Each daemon was started five times, timed from launch to an answer, and measured with
`footprint` just after it answered. Script: `/tmp/051-measure.py`.

| Daemon, store | Until `agents/list` answers | Footprint then | Until `daemon/ping` answers | Footprint then |
|---|---|---|---|---|
| main, 1,010 agents | 4,156 ms | 162 MB | 696 ms (still loading) | 46 MB |
| branch, 1,010 agents, first start (builds `archive.json`, 753 KB) | 882 ms | 57 MB | | |
| branch, 1,010 agents | 288 ms | 27 MB | 280 ms | 18 MB |
| branch, 10 agents | 133 ms | 7.9 MB | 177 ms | 6.0 MB |
| main, 10 agents | 135 ms | 7.9 MB | | |

- **SC-004 (within 20 MB of the store with none): met**, just: 27 MB against 7.9 MB is 19.1 MB more.
- **SC-003 (start within 10% of the store with none): not met as written.** Readiness is about 100 ms
  slower (280 against 177 ms, by ping), which is decoding the index's 1,000 slim records. Against
  main the same store starts 14 times faster and holds a sixth of the memory. Whether 100 ms is
  acceptable, or the index should be decoded lazily, is for Alex (raised at T063).

## Quickstart §2 over the socket (T057), 2026-09-26

On scratch roots, with the branch's `agentsd`:

- **Preview, then confirm**: 3 agents archived 10 days ago. `retention/set` to 7 days, unconfirmed,
  answered `applied: false` with 3 agents and 147 KB, and changed nothing. Confirmed, it
  retired the 3 (`retiredCount: 3`), and the 2-day agent stayed archived.
- **Retire now**: unconfirmed, it answered 1 agent and 49 KB. Confirmed, it retired the agent,
  and the tombstone says `person`. On a live agent it refused with `-32051`, "Only an archived
  agent can be retired."
- **A retired id**: `agents/unarchive` answered `-32050`, "“Seeded archived agent 1” was retired
  on 25 September, 10 days after it was archived."
- **Forever, no limit**: applied at once, since it retires nothing.
- **Cap and holds**: `RetirementTests` covers them. The holds use real git repositories and
  worktrees: an uncommitted file, then committed but unmerged, then merged, plus a shared
  worktree, a worktree the person made, a running workflow and a watching window. The quickstart's
  600 MB cap seeding was not repeated by hand.

The first try at Retire now answered "Method not found": that daemon copy was built before US7.
Rebuilt and rerun above.

## Killing the daemon mid-retire (T058, SC-006), 2026-09-26

Each round seeded 50 agents archived 31 days ago with 5 MB transcripts. It started the branch's
`agentsd`, and `kill -9`'d it between 29.97 s and 30.08 s after the socket appeared, so inside the
first check's retiring. Then it started it again and listed the agents. Script: `/tmp/051-kill.sh`.

| Round | Killed at | Retired when killed | Whole and listed after restart | Neither |
|---|---|---|---|---|
| 1 | 29.970 s | 2 | 48 | 0 |
| 2 | 29.982 s | 15 | 35 | 0 |
| 3 | 29.994 s | 10 | 40 | 0 |
| 4 | 30.006 s | 14 | 36 | 0 |
| 5 | 30.018 s | 14 | 36 | 0 |
| 6 | 30.030 s | 2 | 48 | 0 |
| 7 | 30.042 s | 15 | 35 | 0 |
| 8 | 30.054 s | 14 | 36 | 0 |
| 9 | 30.066 s | 24 | 26 | 0 |
| 10 | 30.078 s | 20 | 30 | 0 |

Every agent in every round was either whole and listed, or had its tombstone and no folder. None
was lost, and none was half-deleted and listed. The first attempt at this test reported 33
"neither" in round 1. That was the script: it listed agents from the killed daemon's leftover
socket before the new daemon was up. Fixed to wait for the new pid in `daemon.lock`.
