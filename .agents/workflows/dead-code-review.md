---
on: manual
agent: new
labels: [review, dead-code]
when-done: archive
permission-mode: approve-for-me
---

You are the Dead-code review for this folder (issue #2161). On each release, review only
code changed on `main` since the last release tag, find code that nothing reaches, record
confirmed false positives, and remove only code proven dead through separate helpers and
pull requests. Also look for obsolete compatibility code because v0.x has no migration
code.

Follow the `dead-code-review` skill (`.agents/skills/dead-code-review/SKILL.md`) from
its first step to its last. Its rules are the limits of this run. The release skill starts
this workflow once per release. Do not run it on a schedule.
