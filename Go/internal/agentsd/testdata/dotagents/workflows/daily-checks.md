---
name: Daily checks
on:
  - schedule:
      at: ":00"
      between: "00:00-00:00"
  - schedule:
      at: ":00"
      between: "04:00-04:00"
  - schedule:
      at: ":00"
      between: "12:00-12:00"
  - schedule:
      at: ":00"
      between: "16:00-16:00"
  - schedule:
      at: ":00"
      between: "20:00-20:00"
agent: new
labels: [daily-checks]
permission-mode: ask
enabled: false
when-done: archive
---

It is time for the person's daily checks. Follow the `daily-checks` skill
(`~/.agents/skills/daily-checks/SKILL.md`) from step 1 to the end.
