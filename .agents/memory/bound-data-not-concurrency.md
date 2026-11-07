---
name: bound-data-not-concurrency
description: "Alex's performance principle — fix slowness by bounding what is held/returned (limits, pages, live-only), not by adding concurrency."
metadata:
  type: feedback
  modified: 2026-10-03T22:17:07.985Z
---

Performance is generally not solved with concurrency; it is solved by bounding the amount of data that can be returned or held (Alex, 2026-10-03).

**Why:** the 2026-10-03 review ([[robustness-performance-priority]]) found the big costs all scale with unbounded sets. Every agent ever held, archived included, sits in the daemon actor and in each client, and `agents/list` has no default limit (13.7 MB, 2.1 s at 5,000 agents). Parallel fetches or task groups only hide that.

**How to apply:** in reviews, issue fixes and bug lanes, propose a limit, page, cursor, cap or live-only set first. Don't suggest a task group, parallel calls or moving work off the main thread as the fix for a performance problem. Indexes and incremental updates come second, once the set is bounded.

**Every data store has a controlled size** (Alex, 2026-10-12), so the worst case is always known and performance stays predictable. A cap like `SpendLedger`'s 7 days is that control, not an oversight. History is fine when it rolls up: precise data for 7 days, then summaries (e.g. daily totals) for 90 days. Propose a roll-up, never an unbounded log.
