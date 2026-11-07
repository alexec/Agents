---
name: branch-can-move-mid-merge
description: In the shared working tree another session can switch branches between your status check and your merge, so a merge silently lands on their branch instead of main.
metadata:
  type: feedback
---

`git merge` in the main checkout does **not** necessarily land where `git status`
said you were. Another session can `git checkout -b <their-branch>` in the shared tree in the
seconds between the two, and the merge then lands on *their* branch. Observed 2026-09-24: a
024 merge created `923aeef` on `025-surviving-a-restart`, and `main` was left behind at the
previous commit. It looks exactly like somebody rewound main, and nobody had.

**Why:** the failure is silent and the merge output looks completely normal. The only way to
tell is to check afterwards, and the only way to know what happened is the reflog — look for
`checkout: moving from main to …` sitting between your two operations.

**How to apply:** after any merge into main in the shared tree, verify with
`git merge-base --is-ancestor <your-commit> main` rather than trusting the merge output.
If it landed elsewhere and their branch has no commits of its own, `git branch -f main
<merge-commit>` is a pure fast-forward and touches nothing else — check first with
`git merge-base --is-ancestor main <merge-commit>` and
`git log --oneline <old-main>..<their-branch>`. Do **not** reset their branch.

**Best: merge from a worktree of your own.** `git worktree add /tmp/merge-main main`, merge
there, then remove it. The shared tree is usually checked out on somebody else's branch with
their uncommitted files in it — on 2026-09-24 it was on `025-surviving-a-restart` with
modifications to `DaemonCore.swift`, a file the branch being merged also touched, so merging
in place would have landed on their branch *and* collided with their work. A worktree of your
own has neither problem, and `main` is free to check out whenever the shared tree is on some
other branch. See [[three-lanes-one-tree]].

**Leave main unchecked-out after merging.** On 2026-09-24 `git worktree add /tmp/merge-027 main`
was refused because an earlier merge left `main` checked out in `/tmp/w026`. Alex approved
removing it (clean, nothing open in it). Remove your own merge worktree when you finish, so
the next lane's `worktree add … main` works.
