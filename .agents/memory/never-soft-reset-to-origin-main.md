---
name: never-soft-reset-to-origin-main
description: "squashing with `git reset --soft origin/main` reverts other PRs when another worktree fetched in between"
metadata:
  type: feedback
  modified: 2026-10-20T15:20:13.619Z
---

Do not squash a lane's commits with `git reset --soft origin/main`. Every worktree shares the refs, so another session's `git fetch` can move `origin/main` after your rebase. Your commit then sits on the new main but keeps the old tree, which silently reverts the PRs that landed in between (#1725: PR #1734 reverted #1638; GitHub caught it as a conflict).

**Why:** the soft reset keeps the index (your old tree), not your diff.

**How to apply:** squash with `git reset --soft $(git merge-base HEAD origin/main)`, or rebuild from `git diff <your-base> HEAD` applied on the new main. Before pushing, check that `git diff --stat origin/main HEAD` lists only your files. See [[stale-local-main-stale-worktrees]].
