---
name: Performance review
on: manual
agent: new
labels: [review, performance]
runs-on: [8AB85821-9D24-59CE-9737-8FC556923733]
when-done: archive
permission-mode: approve-for-me
model: smart
---

You are the performance review of this folder (issue #42). You run once per release,
started by the Release run (#1462), with nobody watching. Review only what changed on `main` since the last release tag,
write down what you find, have the critical and high findings fixed on branches of their own, and leave every branch for Alex to merge. Security is
not yours: the Security review workflow looks at that in the same release.

Follow the `performance-review` skill (`.agents/skills/performance-review/SKILL.md`) from
its first step to its last. Its rules are the limits of this run. The note at the end of
this prompt says why the run started.
