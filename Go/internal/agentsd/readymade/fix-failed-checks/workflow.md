---
name: Fix failed checks
on:
  - checks.failed:
      server: [github, gitlab]
agent: new
cooldown: 5m
labels: [dev-loop]
permission-mode: approve-for-me
enabled: false
when-done: archive
---

A pull request's checks, or a merge request's pipeline, failed. The event's data says which
pull request or merge request, branch, run and jobs, and the event's server says which
forge. Follow the `fix-failed-checks` skill (`.agents/skills/fix-failed-checks/SKILL.md`)
from step 1 to the end.
