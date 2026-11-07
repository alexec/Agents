---
name: approval-waits-hold-places
description: "the app counts a lane waiting on wait_for_event (e.g. Alex's approval) as running; stop+archive it and restart in its worktree on pr.commented"
metadata:
  type: project
  modified: 2026-11-03T03:23:38.095Z
---

2026-11-02: the folder limit for sessions started by sessions was 3 running / 5 not archived. A lane waiting for Alex's approval (`needs-approval`, wait_for_event on pr.commented) still counts as running in the app, though AGENTS.md says it holds no place, so the queue jammed.

**Why:** with the lead plus two approval waits, nothing else could run.

**How to apply:** the Scrum Master stops and archives such a lane once its branch is pushed and its PR is open (archiving keeps the worktree), comments on the PR, watches `pr.commented`, and on Alex's comment starts a new lane in the same worktree (worktree: `work-github-issue-<n>`) that carries on from step 4 of "A UI enhancement waits for Alex". Alex chose to raise the limit to 6 (2026-11-02); it was 5 for a while, then back to 3. The same goes for an epic lead whose only open child waits for approval: park it and close the epic yourself after the merge. Related: [[lanes-follow-ci-time]].
