# Baseline before 046 code (2026-09-25, branch at c5ce35f = main e7155e7 + specs)

`swift test` in Packages/AgentsKit: 2047 tests in 237 suites, 3 failed, all main's known flakes:

- `aListCanLeaveThemOffArchivedAgentsOnly()` (DaemonTests.swift:983, 987)
- `anAgentCanStartInANewWorktreeOnALocalBranch()` (WorktreeStartTests.swift:621)
- `aLeaseThatRanOutWhileTheDaemonWasDownIsHandedOnAsItComesBack()` (LeaseTests.swift:134)

Any other failure after a 046 change is 046's until shown otherwise.

Also on the base commit (c5ce35f, checked in /tmp/w-046-base 2026-09-25): run together with
`--filter "aStoppedAgentIsPickedUpRatherThanCopied|aPickedUpAgentKeepsTheCommandsItsNewRuntimeDoesNotRepeat"`,
both fail `launcher.launchCount == 2` (1 run of 2 on base, 3 of 3 on the branch); each passes alone.
Not 046's; a race between those two tests.

## Before merging (2026-09-25, branch 59876e7, main 44d753d merged in)

The Mac was heavily loaded by other lanes (load average 35–51). Four full runs on the branch
failed with 34–181 issues spread over unrelated suites; every failing group rerun alone passed
(ConnectionRoleTests, AfterTurnTests, Wakefulness, the new Gemini pick-up tests, 26 tests, twice).
main's own full run at the same time (detached worktree on 44d753d) failed the same
ConnectionRoleTests (aDeviceBoundByTheBridgeCannotSpeakAsAnother, aDeviceDoesWhatTheRemoteDoes…,
aHelperReachesTheAgentTools…, anUnnamedDeviceIsWhoItFirstSaysItIs, aStrangerLearnsOnly…,
onlyAWindowsConnectionCanBeGivenToADevice) plus its two font-rule failures, which this branch
fixes. Earlier the same day, at normal load, the branch passed 2,155 of 2,155.
Both Xcode schemes and the Linux agentsd (--check) build.
