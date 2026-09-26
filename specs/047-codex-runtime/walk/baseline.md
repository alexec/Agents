# Baseline before 047's code (3ffe1c9, main e7155e7 merged)

`swift test` in Packages/AgentsKit, 2047 tests, two runs:
- run 1: 4 issues
- run 2: 6 issues, in:
  - ✘ Test aListCanLeaveThemOffArchivedAgentsOnly()
  - ✘ Test run with 2047 tests in 237 suites
  - ✘ Test twoHelpersFinishingGiveOneResumeNamingEach()
  - ✘ Test workThatWouldBeLostIsSaidFirst()

These are main's known timing flakes under load (memory: the suite is broadly flaky).
