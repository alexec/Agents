# 056 baseline (main 74f19e4 merged, before any 056 code), 2026-09-26

`swift test` in Packages/AgentsKit: 2498 tests, 286 suites, failed with 32 issues (the suite is flaky under load; compare against these names, not a count). Failing tests:

- `a100SkillReconcileIsQuick()`
- `aDeviceBoundByTheBridgeCannotSpeakAsAnother()`
- `aDeviceDoesWhatTheRemoteDoesAndNothingPastIt()`
- `aFailedInstallLeavesTheServerUsable()`
- `aHelperReachesTheAgentToolsAndNothingAWindowDoes()`
- `aMacIsRefused()`
- `aNewServerIsSetUpAndAnswers()`
- `anotherRuntimesToolsetInstallsInItsOwnFolderWhenWanted()`
- `anUnknownHostFailsWithItsName()`
- `anUnnamedDeviceIsWhoItFirstSaysItIs()`
- `anUpdateOnAnIdleServerEndsWithTheNewDaemonAnswering()`
- `aQuietDirectLinkLosesAfterTheWindow()`
- `aSecondConnectInstallsNothing()`
- `aServerANewerAppSetUpIsNotTouched()`
- `aStrangerLearnsOnlyThatTheDaemonIsThere()`
- `aWipedServerIsSetUpAgainWithoutAsking()`
- `connectingStartsTheDaemonOverSSHAndItAnswersThroughTheForward()`
- `endingARouteStopsItsProcessAndFailsTheCallWaitingOnIt()`
- `losingTheMasterIsOfflineAndTheServerKeepsRunning()`
- `onlyAWindowsConnectionCanBeGivenToADevice()`
- `removingStopsTheDaemonAndLeavesTheFoldersAlone()`
- `removingWithPurgeDeletesOnlyWhatAgentsInstalled()`
- `run`
- `twoConnectsAtOnceAreOne()`
- `withACredentialInSettingsClaudeIsInstalledAsTheServerConnects()`
- `withoutOneItWaitsUntilClaudeIsChosen()`

The Mac's Claude: `claude auth status` says `"authMethod": "claude.ai"` (Max).

## Phase 2 check (2026-09-26)

- swift test: 2503 tests, 51 issues. The 26 tests failing that did not fail at baseline all pass run alone (`swift test --filter`, 26/26): restart/resume load flakes.
- Agents (macOS), Remote (generic iOS Simulator), scripts/build-linux-agentsd.sh: all build.
