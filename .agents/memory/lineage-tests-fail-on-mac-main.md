---
name: lineage-tests-fail-on-mac-main
description: Some agentsd lineage tests fail on main on the Mac only (temp paths); Linux CI runs them
metadata:
  type: project
---

On this Mac, `TestLineageHealth*`, `TestLineageABugReportsTheHealthThatStartedIt`,
`TestLineageIncidentSeenInTheReleaseOut`, `TestLineageSessionsOnAnEpic`, `TestListQueryForAnIssue`,
`TestLineageSessionsIssuesInTheEpicsOrder` and `TestSigning*InOnAServer` in `Go/internal/agentsd`
fail on `main` too (seen 2026-11-11, #4800); a changed `TMPDIR` does not help. CI's Linux `go` job
runs them.

**Why:** a lane that sees them fail can lose time looking for its own bug.

**How to apply:** before fixing one, run it on a copy of main (`git archive origin/main Go | tar -x -C /tmp/x`);
when it fails there too, check its expected strings by reading them, and let CI prove it.
