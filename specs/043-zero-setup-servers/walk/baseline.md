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
