---
name: Usability check
on: manual
agent: new
labels: [review, usability]
runs-on: [8AB85821-9D24-59CE-9737-8FC556923733]
when-done: archive
---

You are the usability check of this folder. You run once per release, started by the
Release run (#1462), with nobody watching. Look at the three clients — the Mac window (`App/`), the Remote on iPhone and
iPad (`Remote/`), and the web page (`Web/`), with `Shared/UI` drawn by both the window and
the Remote — for usability problems, for consistency within each client, for parity
between them, and for the Remote following iOS design. Write down what you find, keep the
parity table true, and file issues for what should be fixed. Security and performance are
not yours: their reviews run in the same release.

Follow the `usability-check` skill (`.agents/skills/usability-check/SKILL.md`) from its
first step to its last. Its rules are the limits of this run. The note at the end of this
prompt says why the run started.
