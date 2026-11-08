---
name: run-app-stop-glob-eats-sibling-tmp-dirs
description: "stop.sh <root> deletes /tmp/run-<slug>-* globally, including shot dirs you made yourself under that prefix"
metadata:
  type: feedback
  modified: 2026-11-01T00:37:46.776Z
---

`stop.sh $ROOT` removes `/tmp/run-<slug>-*` and `/tmp/run-<slug>.*` as part of cleanup — not just the
build log and Chrome profiles it created, but anything else matching that glob, including a
screenshots directory you made yourself (e.g. `/tmp/run-3089-shots/`) or a renamed/copied PNG under
that prefix (e.g. `/tmp/run-3089-lineage-mac-zoom.png`).

**Why:** hit a second time on #3089's screenshot walk (same mistake this memory already recorded
once): copied/renamed screenshots into `/tmp/run-3089-shots/` for `pr-shots.sh`, then ran
`stop.sh /tmp/run-3089` per "When you are done" — it silently deleted the whole shots directory
along with the root, losing the renamed copies and forcing a relaunch and redo of the whole walk.

**How to apply:** before starting a run-app walk, check this memory. When a walk produces
screenshots meant to survive the lane (for `pr-shots.sh`, or to hand to the user), copy/move them to
a path with a disjoint name as the very next step after taking the shot — e.g. `/tmp/shots-<slug>/`
— never batched at the end right before `stop.sh`, and never anywhere matching `/tmp/run-<slug>*`.
