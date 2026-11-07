---
name: clean-up-worktrees
description: "Disk fills fast (80 GB of worktrees, 143 MB free on 2026-10-03): every helper removes its worktree when its work is committed and handed over, and build output never outlives the task"
metadata:
  type: feedback
---

Alex, 2026-10-03: "Seems like we need to keep the disk free a bit better. You must tell agents to clean up their worktree when done. Also, clean up the worktrees." The Mac had 143 MB free; `.agents/worktrees` held 80 GB, about 5–11 GB per lane, mostly build output (DerivedData, .build, node_modules).

**Why:** a full disk stops builds and agents, and can lose settings. On that day the project's running limit fell out of `.agents/project.json` and reverted to the default.

**How to apply:**
- The rule now lives in ~/.agents/AGENTS.md (personal instructions every agent reads, every runtime), added 2026-10-03 at Alex's go-ahead. Every start_agent prompt still ends with: "When your work is committed and named in your ending, end with finish_turn, with afterwards: park and leave_worktree: remove (the branch keeps your commits). If you can't remove it, delete its build output first (build/, .build, DerivedData, Web/node_modules)." This replaces the old #119 rule of never removing lane worktrees. Merge agents work from branches, not lane worktrees.
- Merge agents remove their own scratch worktree and temporary branch, as before.
- The lead archives helpers as soon as their branch is committed and verified; archiving takes the worktree away and the branch stays. Don't wait for the merge.
- Check `df -h /` on each wake. Below about 20 GB free, clean up before starting anything.
See [[park-finished-agents]], [[build-lease]].

**Known gap (#194):** leave_worktree: remove is refused when the branch has unmerged commits (every lane at finish), so agents delete build output and the lead archives them to remove the worktree. Archive each finished lane promptly.

**#194 live (2026-10-04):** the wave 14 merge agent removed its own worktree with leave_worktree: remove on an unmerged branch. Agents can follow the clean-up rule themselves now; the lead still archives promptly.

**Superseded 2026-10-08:** finish_turn is removed ([[finish-turn-removed-494]]). Park with park_agent (no id), move with move_worktree (leave_worktree: remove), wait with wait_for_event (agents / until_minutes).
