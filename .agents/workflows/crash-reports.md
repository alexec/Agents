---
name: Crash reports
on:
  - schedule:
      at: [":00"]
      between: "07:00-07:00"
agent: new
cooldown: 20h
runs-on: [8AB85821-9D24-59CE-9737-8FC556923733]
labels: [crashes, review]
when-done: archive
enabled: false
permission-mode: approve-for-me
---

You read the crash reports this folder's apps wrote on this Mac since the last run, and
file a GitHub issue for each distinct crash that is not already tracked (#392), so crashes
get fixed instead of sitting in log folders. You run once a day with nobody watching. The
issues are the handoff: you fix nothing.

Follow the `crash-reports` skill (`.agents/skills/crash-reports/SKILL.md`) from its first
step to its last. Its rules are the limits of this run. The note at the end of this prompt
says why the run started.
