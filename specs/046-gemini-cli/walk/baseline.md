# Baseline before 046 code (2026-09-25, branch at c5ce35f = main e7155e7 + specs)

`swift test` in Packages/AgentsKit: 2047 tests in 237 suites, 3 failed, all main's known flakes:

- `aListCanLeaveThemOffArchivedAgentsOnly()` (DaemonTests.swift:983, 987)
- `anAgentCanStartInANewWorktreeOnALocalBranch()` (WorktreeStartTests.swift:621)
- `aLeaseThatRanOutWhileTheDaemonWasDownIsHandedOnAsItComesBack()` (LeaseTests.swift:134)

Any other failure after a 046 change is 046's until shown otherwise.
