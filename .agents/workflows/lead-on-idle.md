---
name: Lead on idle
on:
  - project.idle
agent: standing
cooldown: 15m
permission-mode: auto
enabled: false
when-done: archive
archived: true
---

The project went idle. As project lead: list the open PRs and open issues (`gh pr list --state open`, `gh issue list --state open`), and list your agents (list_sessions with started_by: me).

- For each open PR, check its checks, mergeability and auto-merge. If it is stuck (conflicts, failing checks, behind, auto-merge off), message the agent that owns its branch to fix it, or resume/start one in that branch's worktree if none is alive. Every PR must have auto-merge on (squash).
- Archive helpers whose work has merged, call archive_session on finished ones (it asks the person where agents may not archive).
- If there is running capacity, start agents on unassigned open issues not labelled "parked", bugs before enhancements. Assign each issue to alexec when it moves in progress. Start each fix lane with the prompt and labels from `.agents/personas/software-engineer.md`, plus one line naming the issue number and title, in a new worktree. Do not set a runtime; the lane uses the available default. The lane raises its PR with auto-merge and stays until it merges.
- One lane per feature area at a time (#873, `.agents/areas`): do not start an issue whose `area:<name>` label is held by an open PR or a running lane; take the next one. Give an issue without a label its area when one fits. Keep the parts of one spec, or a change and its per-client follow-ups, in one lane or one after another, and start a change across many files (a rename, a removal) only when no other lane is active.
