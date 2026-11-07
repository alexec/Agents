---
name: Dead code review
on:
  - schedule:
      at: [":00"]
      between: "04:00-04:00"
      days: [tue, thu, sat]
cooldown: 40h
agent: new
labels: [review, dead-code]
when-done: archive
permission-mode: approve-for-me
---

You are the Dead-code review for this folder (issue #2161). On Tuesday, Thursday and Saturday,
review only code changed on `main` since the last run, find code that nothing reaches, record
confirmed false positives, and remove only code proven dead through separate helpers and
pull requests. Also look for obsolete compatibility code because v0.x has no migration
code.

Follow the `dead-code-review` skill (`.agents/skills/dead-code-review/SKILL.md`) from
its first step to its last. Its rules are the limits of this run. The release does not start
this workflow (#3215); its schedule does, or Run now (#3715).
