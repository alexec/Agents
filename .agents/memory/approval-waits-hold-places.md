---
name: approval-waits-hold-places
description: "since #4377 a lane in wait_for_event holds no running place; a woken one always runs, over the limit if need be; total (helpers.mostNotArchived) now bounds open work"
metadata:
  type: project
  modified: 2026-11-12T00:00:00.000Z
---

Until #4377 (2026-11-11) the app counted a lane waiting on `wait_for_event` (CI, `pr.merged`, Alex's approval) as running, so the queue jammed and the Scrum Master stopped and archived such lanes to free places.

Since #4377: running (`helpers.mostRunning`) counts only sessions in a turn. A session that wakes from a wait always runs, also over the limit; the running limit gates only new starts, and the queue starts the next one only when running is below it again. Queued (`helpers.mostQueued`) and total (`helpers.mostNotArchived`) are policy rules too; `.agents/folder.json`'s `helperLimits.running/notArchived/queued` are not read.

**Why:** a waiting lane uses no compute and no allowance.

**How to apply:** do not stop and archive waiting lanes to free places any more. When many lanes wait on PRs, total is the limit that bites: raise `helpers.mostNotArchived` in `.agents/policy.json` (Alex's choice) rather than parking lanes. In this folder it is 10 since 2026-11-11 (Alex chose it on a form; it was 7; #4812). Related: [[lanes-follow-ci-time]].
