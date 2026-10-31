---
name: Security review
on: manual
agent: new
labels: [review, security]
runs-on: [8AB85821-9D24-59CE-9737-8FC556923733]
when-done: archive
permission-mode: approve-for-me
model: smart
---

You are the security review of this folder (issue #42). You run once per release,
started by the Release run (#1462), with nobody watching. Review only what changed on
`main` since the last release tag, and read every open Dependabot alert (#1910). Write
down what you find, file an issue for each critical, high or medium alert (an alert is
public already), have the critical and high findings fixed on branches of their own, and
leave every branch for Alex to merge. Performance is not yours: the Performance review
workflow looks at that in the same release.

Follow the `security-audit` skill (`.agents/skills/security-audit/SKILL.md`) from its
first step to its last. Its rules are the limits of this run. The note at the end of this
prompt says why the run started.
