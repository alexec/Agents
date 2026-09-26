# Baseline: main merged in at 107793b (main 8cc2b5e), before any 043 code

Six full `swift test --package-path Packages/AgentsKit` runs, 2026-09-25: 1830 tests in 204 suites each; every run fails, only on main's own tests:

| Test | Runs failed (of 6) |
|---|---|
| `noCallSiteNamesAStateColourItself` | 6 |
| `twoHelpersFinishingGiveOneResumeNamingEach` | 5 |
| `workThatWouldBeLostIsSaidFirst` | 3 |
| `anAgentCanStartInANewWorktreeOnALocalBranch` | 3 |
| `aBlockWhoseWaitsClosedBeforeItsTurnEndedIsResumedWhenItEnds` | 3 |
| `theEndingAPersonsPromptOvertookIsNotAskedAbout` | 2 |
| `archivingABlockedAgentIsNeverUndoneByAResume` | 2 |
| `theDepthCeilingCountsFromTheRestoredRun` | 1 |
| `stoppingABlockedAgentStopsItAndNothingIsSentLater` | 1 |
| `archivingKeepsTheBranchOfAnUnmergedWorktree` | 1 |
| `aPersonsPromptEndsTheBlockAndNothingIsSentLater` | 1 |
| `aChainShortOfTheCeilingCarriesOnFromTheRestoredDepth` | 1 |

`noCallSiteNamesAStateColourItself` fails 6/6: a source-scan test on main, not timing. The rest are main's known lease/blocked/helper/worktree timing flakes. 043 is judged against this list.

## Branch runs (T057), 2026-09-25

Six full runs at `4f265c6` (1886 tests): every run fails, on main's own tests as in the baseline
(`noCallSiteNamesAStateColourItself` 6/6, the worktree and ending-overtaken races), **plus two
that passed 6/6 in the baseline**:

| Test | Branch | Baseline | Alone on the branch |
|---|---|---|---|
| `aListCanLeaveThemOffArchivedAgentsOnly` (main's 949630f) | 4/6 | 0/6 | 5/5 pass |
| `aLeaseThatRanOutWhileTheDaemonWasDownIsHandedOnAsItComesBack` (036) | 4/6 | 0/6 | 5/5 pass |

Three more full runs skipping 043's two fake-ssh suites still failed them (2/3 and 1/3), so it
is not those suites' load alone. Neither test reaches 043's code paths: they drive the core
directly on a Mac daemon, where `launchEnvironment` returns at once. **Open:** a same-time run of
the baseline commit, to tell today's machine load from a change; a first attempt was cut off.

## After merging main `4f6a5a3` (at `8319a5a`), 2026-09-25

Both schemes and the Linux gate build. 043's 91 tests pass. Three full runs (1980 tests) fail
only on main's own: `noCallSiteNamesAStateColourItself` 3/3 (main's `WorktreeRow.swift:94`),
`anAgentCanStartInANewWorktreeOnALocalBranch` 2/3, `twoHelpers…`, `archivingABlockedAgent…`,
`theEndingAPersonsPromptOvertook…` 1/3 each. The two tests seen failing earlier on the branch
(`aListCanLeaveThemOffArchivedAgentsOnly`, `aLeaseThatRanOut…`) did not fail in any of the three.
