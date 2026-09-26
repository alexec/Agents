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
