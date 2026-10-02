# Suite comparison: the branch against main

**Date:** 2026-10-01

**What was compared:**

| Side | Commit |
|---|---|
| main | `729244a9` (#100 and #98) |
| the branch | `d3bc030b` (the R2 fix), which is that main with 071 on top |

**How it was run:**
- Each side was checked out in a detached worktree of its own (`/tmp/071-compare-main`, `/tmp/071-compare-branch`).
- Six rounds were run. Each round was the full `swift test` of AgentsKit, then ControlPlane, on main, then on the branch.
- Runs alternated, so each side ran under the same load. Other lanes were running their own work on this Mac at the time.

Since then, the branch has been rebased onto main `40a4ae54` (#93, #84, #83). Its commits after `d3bc030b` change only `Web/`, so the Swift suites compared here are the ones it carries.

## Results

| Package | Side | Tests | Runs with a failure |
|---|---|---|---|
| AgentsKit | main | 3096 | 6 of 6 |
| AgentsKit | the branch | 3120 | 6 of 6 |
| ControlPlane | main | all | 0 of 6 |
| ControlPlane | the branch | all, with 071's | 0 of 6 |

**AgentsKit tests that failed, by how many of the six runs:**

| Test | main | the branch |
|---|---|---|
| `aChildPastItsDeadlineIsStopped` | 5 | 6 |
| `a100SkillReconcileIsQuick` | 5 | 5 |
| `aWaitSurvivesTwentyRestarts` | 1 | 1 |
| Eight daemon-access tests (`aDeviceBoundByTheBridgeCannotSpeakAsAnother`, `aStrangerLearnsOnlyThatTheDaemonIsThere`, `onlyAnOperatorSetsTheHelperLimits` and five more), together | 2 | 0 |
| `theWindowSizeReachesTheChild` | 1 | 0 |
| `aChainShortOfTheCeilingCarriesOnFromTheRestoredDepth` | 1 | 0 |
| `severalInterruptedAgentsAreAllPickedBackUp` | 1 | 0 |
| `theRestartWordsGoAheadOfWhatWasQueued` | 1 | 0 |
| `theChildGetsARealControllingTerminal` | 0 | 1 |
| `aReplyTooLateIsNoAnswerAndTheNextCallStillWorks` | 0 | 1 |

## Reading it

- **The two that fail almost every time fail on both sides:** `aChildPastItsDeadlineIsStopped` and `a100SkillReconcileIsQuick`. They are timing budgets, and fail under this Mac's load whatever the commit. That is the suite's known flakiness under load, not 071.
- **Main failed more than the branch:** 15 distinct tests against 5.
- **Two tests failed only on the branch, once each:** `theChildGetsARealControllingTerminal` (PTYTests) and `aReplyTooLateIsNoAnswerAndTheNextCallStillWorks` (DroppedReplyTests).
  - Neither touches code 071 changed.
  - Run alone, six times on each side, both passed every time on both.
- **ControlPlane passed all six runs on both sides,** including 071's listener, browser-client and security tests.

**Conclusion:** the branch adds no failure that main doesn't have, or that doesn't pass when run on its own.

The logs are in `/tmp/071-compare/`, as `<side>-<package>-<run>.log`, with `summary.txt`.
