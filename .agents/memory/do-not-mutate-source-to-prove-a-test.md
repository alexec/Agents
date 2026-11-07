---
name: do-not-mutate-source-to-prove-a-test
description: "Don't edit source in place to prove a test bites — an interrupt leaves the mutation on disk, and in this shared tree that is a live file."
metadata: 
  type: feedback
  modified: 2026-09-20T04:24:15.538Z
---

Proving a new test actually fails by `sed`/`python`-mutating the source, running the
suite, then reverting: Alex stopped this mid-run on 2026-09-19, and the run had already
written the mutation. `isSameReason` sat on disk comparing the wrong thing, under a
comment saying it compared the other, and only a re-read caught it before the commit.

**Why:** the edit and the revert are two steps with a suite run between them, so any
interruption — a rejected call, an app restart, a crash — leaves the tree wrong in a way
that reads as finished work. Three lanes share this one working tree, so it is not only
my own next commit at risk.

**How to apply:** assert the property directly instead — two `settingRefused` values with
*different* details asserted equal-by-reason cannot pass if the detail is compared, so no
mutation is needed to know the test bites. When a mutation genuinely is the only way to
show it, do it in a throwaway `git worktree` and never in the shared tree. Related:
[[next-up-017-workflow-settings]].
