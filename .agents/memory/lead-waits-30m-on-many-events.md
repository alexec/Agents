---
name: lead-waits-30m-on-many-events
description: "As lead, wait at most 30 minutes, and on pr.blocked and agent.finished as well as pr.merged"
metadata:
  type: feedback
  modified: 2026-10-17T20:36:47.827Z
---

Alex, 2026-10-17: "Don't wait for 3h for pr.merged, only wait 30m. You have other things that might happen, e.g. ci failure."

**Why:** a lead that waits only on merges misses red CI and stuck lanes for hours.

**How to apply:** every lead wait_for_event: `until_minutes: 30`, events `pr.merged`, `pr.blocked` (server github; since #5433 it replaces `checks.failed` and `pr.conflicted`) and `agent.finished`. There is no `ci.failed`. On a timeout, check open PRs' checks and lanes, then wait again. Related: [[lead-wakes-on-any-lane]], [[golang-migration-lead]].
