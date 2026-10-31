---
name: Work a Linear issue
on:
  - issue.labelled:
      server: linear
      label: agent
agent: new
labels: [linear]
permission-mode: approve-for-me
enabled: false
when-done: park
---

A Linear issue got the `agent` label. The event's data says which issue (identifier,
title, url, team) and who added the label. Follow the `work-a-linear-issue` skill
(`.agents/skills/work-a-linear-issue/SKILL.md`) from step 1 to the end.
