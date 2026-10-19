---
name: Fix failed checks
on:
  - checks.failed
agent: new
cooldown: 5m
labels: [github]
permission-mode: auto
enabled: false
when-done: archive
---

A pull request's checks failed. The event's data says which PR, branch, run and jobs.
Follow the `fix-failed-checks` skill (`.agents/skills/fix-failed-checks/SKILL.md`) from
step 1 to the end.
