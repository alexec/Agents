---
name: check-go-darwin-before-arming
description: "before turning auto-merge on for an approved PR, check its non-required checks (go-darwin, web, docs-check); auto-merge ignores them"
metadata:
  type: feedback
  modified: 2026-11-05T07:03:01.304Z
---

2026-11-04: the Scrum Master armed auto-merge on approved PR #3503 while `go-darwin` was red on the PR's own new test; it merged at once and broke main (#3517). Earlier #3329 merged with `web` red (#3336).

**Why:** main's ruleset requires only test, go, lint and hold; `go-darwin`, `web`, `docs-check` and others can be red and auto-merge still merges.

2026-11-06: armed #3616 with `go-darwin` still running (no failure yet); it merged within seconds. "No failures" is not enough.

**How to apply:** arm only when every check, required or not, has COMPLETED and none failed; a PR with `go-darwin` still running waits (check again, or let its lane arm it). before `gh pr merge --auto` on a PR (above all an approved UI PR whose lane is parked), list its failed checks; if any failure is in the PR's own change, start a lane in its worktree to fix it first instead of arming. Rerun a failure that is unrelated (flaky on main). Related: [[approval-waits-hold-places]].
