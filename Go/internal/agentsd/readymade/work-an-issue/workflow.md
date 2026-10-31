---
name: Work an issue
on:
  - issue.labelled:
      server: [github, gitlab]
      label: agent
agent: new
labels: [dev-loop]
permission-mode: ask
enabled: false
when-done: park
---

An issue got the `agent` label, on GitHub or on GitLab. The event's data says which issue
(number, title, url) and who added the label, and the event's server says which forge.
Follow the `work-an-issue` skill (`.agents/skills/work-an-issue/SKILL.md`) from step 1 to
the end.
