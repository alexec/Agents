---
name: Work an issue
on:
  - issue.labelled:
      server: github
      label: agent
agent: new
labels: [github]
permission-mode: auto
enabled: false
when-done: park
---

An issue got the `agent` label. The event's data says which issue (number, title, url)
and who added the label. Follow the `work-an-issue` skill
(`.agents/skills/work-an-issue/SKILL.md`) from step 1 to the end.
