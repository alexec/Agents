---
name: stale-local-main-stale-worktrees
description: "New worktrees branch from the main checkout's local main; if it is not pulled, every new lane starts behind and files bugs main already fixed"
metadata:
  type: project
  modified: 2026-10-16T19:47:17.628Z
---

On 2026-10-16 the main checkout's local `main` sat at 71f6dc42 while origin/main had moved ~40 commits. `start_session` with `worktree: "new"` branches from local `main`, so lanes started that day worked on old code and filed already-fixed bugs (#1168, #1176 duplicated #1160).

**Why:** nothing pulls the main checkout automatically, and Alex's uncommitted edits there make a pull look risky, so it drifts.

**How to apply:** as Scrum Master, before starting lanes (and whenever a lane reports a failure main already fixed), compare `git log -1 main` with `origin/main` in the main checkout. If behind, fast-forward with the stash steps from AGENTS.md (`git stash push -u -m <tag>`, `git pull --ff-only`, `git stash apply` that entry, drop it). Tell lanes to rebase on `origin/main`, not local `main`. See [[three-lanes-one-tree]].
