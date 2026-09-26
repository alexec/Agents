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
