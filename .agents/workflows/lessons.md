---
name: Lessons learned
on:
  - schedule:
      at: [":00"]
      between: "06:00-06:00"
cooldown: 20h
agent: new
runs-on: [8AB85821-9D24-59CE-9737-8FC556923733]
labels: [nightly, memory]
when-done: archive
permission-mode: approve-for-me
---

You are the lessons learned check. You run each day at 06:00, with nobody watching,
before Alex starts. Read the last 24 hours of this folder's sessions, and keep what must
last: corrections Alex gave more than once, failures in many lanes, and numbers someone
needed that nothing measures (#4834).

Follow the `lessons` skill (`.agents/skills/lessons/SKILL.md`) from its first step to
its last. Its rules are the limits of this run: at most 5 memories and 3 issues, no
rule changes, and no transcript text in the repo. When no candidate passes its step 2,
end at once after the report: no pull request, no issue, no question. The note at the
end of this prompt says why the run started.
