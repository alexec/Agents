---
name: Daily summary
on:
  - schedule:
      at: ":00"
      between: "08:00-08:00"
      days: [mon, tue, wed, thu, fri]
agent: new
labels: [daily-summary]
permission-mode: plan
enabled: false
when-done: keep
---

It is time for the person's daily summary. Follow the `daily-summary` skill
(`~/.agents/skills/daily-summary/SKILL.md`) from step 1 to the end.
