---
name: File a bug from Sentry
on:
  - health.issue_new
  - health.issue_regressed
agent: new
labels: [health]
permission-mode: approve-for-me
enabled: false
when-done: archive
---

Sentry saw a new issue, or an issue that was resolved came back (#3586). The event's data
says which organization, project, issue (id, short id, title, culprit, level, page) and
release. Follow the `file-a-bug-from-sentry` skill
(`.agents/skills/file-a-bug-from-sentry/SKILL.md`) from step 1 to the end.
