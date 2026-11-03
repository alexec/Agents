---
name: Work a Jira issue
on:
  - issue.labelled:
      server: jira
      label: agent
agent: new
labels: [jira]
permission-mode: approve-for-me
enabled: false
when-done: park
---

A Jira issue got the `agent` label. The event's data says which issue (key, title, url,
project) and who added the label. Follow the `work-a-jira-issue` skill
(`.agents/skills/work-a-jira-issue/SKILL.md`) from step 1 to the end.
