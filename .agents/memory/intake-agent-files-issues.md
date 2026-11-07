---
name: intake-agent-files-issues
description: "In an intake session (session label `intake`), every request becomes a triaged GitHub issue, never a code change; broken again 2026-10-19"
metadata:
  type: feedback
  modified: 2026-10-20T19:25:16.580Z
---

When Claude is the intake agent, every request is filed as a GitHub issue labelled **bug**, even one that reads as "change X". Claude may triage it (find the files, the cause, a proposed fix), but it doesn't make a worktree, edit code or build.

**Why:** Alex stopped a sidebar font change mid-build on 2026-10-03 (it became #155): "You're an intake agent. You can triage an issue, but you always file a GitHub enhancement." The project lead starts the lanes that build. Later the same day, in the intake session that filed #145/#148/#154, Alex said it again with "bug": "You can triage an issue, but you always file a GitHub bug." The later wording wins.

**How to apply:** If the session has been raising issues, treat imperative requests ("Change the font…") as issues too. Put the triage in the body: file:line, the cause, the proposed fix, web parity, and "done when".

2026-10-03: Alex also asks the lead directly to file bugs and enhancements. Label new features `enhancement` (that label exists), defects `bug`; include why, what, details and related issues. Example: #195 low-disk event.

2026-10-19: Claude broke this again (#1560, a Remote swipe change). It made a worktree and edited code before Alex stopped the build: "You never fix issues. You only triage and raise issues." The session's `intake` label says this is an intake session. Check the labels at the start of the first turn. When `intake` is there, never make a worktree, edit or build.

2026-10-20: Alex said it again for a voice-mode exploration (#1792): "you are the product owner and it's your job to triage, investigate, discuss ideas with me. It's not your job to do the actual work or even delegate out to another agent." So read-only research agents are fine for investigation, but never start a lane or an agent to build or run a spike. File the issue and stop.

2026-10-20 (again, #1822): Claude made a worktree after filing the issue, then saw the `intake` label and removed it with no edits. Check the labels BEFORE the first tool call, not after filing. Also do not put `#<n>` on an intake session: that marks the issue as taken.
