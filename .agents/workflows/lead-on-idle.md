---
name: Lead on idle
on:
  - project.idle
agent: standing
cooldown: 15m
permission-mode: auto
enabled: false
---

The project went idle. As project lead: list the open PRs and open issues (`gh pr list --state open`, `gh issue list --state open`), and list your agents (list_my_agents).

- For each open PR, check its checks, mergeability and auto-merge. If it is stuck (conflicts, failing checks, behind, auto-merge off), message the agent that owns its branch to fix it, or resume/start one in that branch's worktree if none is alive. Every PR must have auto-merge on (squash).
- Archive helpers whose work has merged, park finished ones.
- If there is running capacity, start agents on unassigned open issues not labelled "parked", bugs before enhancements, each in a new worktree, raising a PR with auto-merge. Assign each issue to alexec when it moves in progress.
