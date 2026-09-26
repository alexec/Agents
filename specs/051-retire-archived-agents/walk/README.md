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
