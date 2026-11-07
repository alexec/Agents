---
name: auto-approve-not-planned
description: "Issue #46 Auto-approve (model judges Cursor/Grok permission requests) closed as won't do 2026-09-29; spike results live in the issue comment"
metadata:
  type: project
  modified: 2026-09-29T23:03:38.618Z
---

Issue #46 (a model or rules decide client-side permission requests for Cursor/Grok/OpenCode) was spiked and then closed as **not planned** on 2026-09-29. The branch and worktree were deleted.

**Why:** Alex judged local models too complex to set up and not reliable enough yet. Apple Foundation Models asked about 14–27% of ordinary actions, the same failure that got 061's Auto-review dropped. Local Qwen3-4B was about 7% asks / 14% risky approvals at about 2 s per request. Rules alone were 4.6% / 27%. Alex first picked "rules only", then aborted the whole feature.

**How to apply:** Don't propose model-based or rule-based auto-approval for client-permission runtimes unless Alex reopens it. The full research (method, numbers, what slips through) is in the comment on alexec/Agents#46. The redacted eval set was not kept, because it came from private transcripts. Related: [[goose-not-planned]].
