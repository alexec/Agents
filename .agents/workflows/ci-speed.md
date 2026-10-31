---
name: Nightly CI speed check
on:
  - schedule:
      at: [":00"]
      between: "01:00-01:00"
agent: new
cooldown: 20h
runs-on: [8AB85821-9D24-59CE-9737-8FC556923733]
labels: [nightly, ci]
when-done: archive
permission-mode: approve-for-me
---

You are the nightly CI speed check. You run with nobody watching. Look at how long the
checks on the last few GitHub pull requests took to go green, counting the time they
sat queued for a runner, and if they ran over **15 minutes**, make one change that
brings them back under, on a pull request of its own.

Follow the `ci-speed` skill (`.agents/skills/ci-speed/SKILL.md`) from its first step to
its last. Its rules are the limits of this run. The note at the end of this prompt says
why the run started.
