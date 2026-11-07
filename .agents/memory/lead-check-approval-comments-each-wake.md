---
name: lead-check-approval-comments-each-wake
description: "A lead with a needs-approval child PR must read its comments on every wake; dropping pr.commented missed Alex's \"Approved\" for 3 hours"
metadata:
  type: feedback
  modified: 2026-11-07T16:33:03.264Z
---

A lead whose child PR waits for Alex (`needs-approval`, lane parked) must check that PR's comments on every wake, not only on `pr.commented`.

**Why:** on 2026-11-07 (#3606 lead), I dropped `pr.commented` from the wait because it fired for every PR in the folder. Alex commented "Approved" on #3779 at 23:37. I only saw it at 02:50, and six children stayed blocked meanwhile.

**How to apply:** on each wake, run `gh pr view <n> --json comments` for each parked approval PR, filtering to Alex's comments without `<!--`. Since 2026-11-07 08:30 the daemon has #3819's keys, and it refuses an unnamed wait. Wait with `where: {"issue": [open children], "fixes": ["#child", …]}` and add `pr.commented`: with `fixes`, it wakes only on the epic's PRs, so approvals arrive by event. See [[approval-waits-hold-places]] and [[lead-waits-30m-on-many-events]].
