---
name: lanes-follow-ci-time
description: "Alex 2026-11-01: up to 7 lanes (was 4, then 3); open-PR limit scales with it; drop a lane when \"CI to merge\" time creeps up"
metadata:
  type: feedback
  modified: 2026-11-01T18:29:49.842Z
---

Up to 7 lanes at once (Alex, 2026-11-01: "due to recent improvements"). Before that: 4 (2026-10-27), and 3 in the Scrum Master prompt.

**Why:** Alex was not sure the GitHub runners had room for more than 3; CI and build improvements since then made more room.

**How to apply:** the open-PR rule scales with it: start no new lane while more than 6 counting PRs are open (needs-approval and hold:* PRs do not count). The folder's own running / not-archived limits (Folder Settings) are Alex's to set; on 2026-11-01 they were still 3 running / 5 not archived, so ask Alex to raise them. Still watch CI-to-merge time (baseline ~10–11 min on 2026-10-27): over ~15 min on two PRs in a row, start no new lane until fewer run. Related: [[no-new-agents-over-two-open-prs]], [[two-lanes-usage-budget]].
