# Baseline (T002)

Three full `swift test --package-path Packages/AgentsKit` runs on a frozen copy of this branch
right after merging main (`Merge main into agents/ios-works-when-not`, 2026-09-25), before any
046 code. 1989 tests in 228 suites each time.

| Run | Issues | Time |
|---|---|---|
| 1 | 4 | 44.6 s |
| 2 | 1 | 32.6 s |
| 3 | 2 | 31.5 s |

The failures are all main's own, and all are timing:

| Test | Runs failed |
|---|---|
| `LeaseTests.aLeaseThatRanOutWhileTheDaemonWasDownIsHandedOnAsItComesBack` | 2 of 3 |
| `WorktreeStartTests.anAgentCanStartInANewWorktreeOnALocalBranch` | 1 of 3 |
| `WorktreeStartTests.workThatWouldBeLostIsSaidFirst` | 1 of 3 |
| `PullRequestFireTests.anAgentNotStartedForAPullRequestCannotPushOrReply` | 1 of 3 |

The lease and worktree ones are the known flakes in the memory ("the suite is broadly flaky
under load"). A branch run failing only these is failing only main's.
