---
name: Free disk space
on:
  - mac.disk_low
agent: new
runtime: claude
model: sonnet
effort: low
permission-mode: auto
cooldown: 30m
labels: [disk, clean-up]
---

You free disk space on this Mac (#199), because a disk ran low. You run with nobody
watching. You delete build output that finished agents left in their worktrees, and when
the disk is critical, the worktrees of archived agents whose work is all on their branch.
Nothing else. A run is started in every project that has this workflow; you clean up
this project's worktrees only.

## Rules for the whole run

- **Run every command from the project folder you start in.** It is the shared checkout
  of `main`: never delete, edit, commit, check out, merge, rebase, stash or push anything
  in it. No builds or tests. The shell is zsh: never name a variable `path`, which is
  `$PATH` there and loses every command.
- **Only a folder `list_sessions` names** as a session's `Worktree:` is ever looked at.
  A worktree no session names (a review's, a merge's, the person's own) is left alone.
- **Never a worktree any session is busy in.** Every session naming it must be `Done`,
  `Parked` or `Archived`, and none may say `Holding:`. `Working`, `Waiting`, `Blocked`,
  `Needs you` and `Paused` all leave it alone.
- **Never source, and never uncommitted work.** `rm` only a folder that passes the check in
  step 3. Never `git worktree remove --force`, `git clean`, `git reset`, `git checkout`,
  `git branch -d` or `-D`.
- **Never turn workflows on or off**, this one included. Nobody is at the keyboard: do not
  ask; say what you left and why in your ending.

## 1. What happened

The line at the end of this prompt names the event and its details. `level: critical`
means the disk is critical; anything else, or no event at all (**Run now**), means low.
Note the free space now:

```sh
P=$(pwd -P)
df -k "$P" | tail -1
```

## 2. Which worktrees

1. Call `list_sessions` with `limit: 100`, and again with the `after` each page ends with,
   until a page says no more follow: a project has more sessions than one page (#210). A
   line with `Worktree: <path> on <branch>.` ties that folder to that session. Group the lines by path.
2. A path is **finished** if every session naming it is `Done`, `Parked` or
   `Archived` and none says `Holding:`. It is **archived** if every session naming it is
   `Archived` and none says `Holding:`. Every other path is kept.
3. Call `list_resources`. If a holder named there has the title of a session naming a
   finished path, keep that path too.
4. Keep a finished path only if all of these pass; otherwise keep it and say which
   failed. Set `W` to the path with its links resolved first, so it compares with `$P`:

   ```sh
   W=$(cd "<the path>" && pwd -P) || echo "not there"
   case "$W" in "$P"/.agents/worktrees/*) ;; *) echo "not under .agents/worktrees" ;; esac
   [ "$W" != "$P" ]
   git -C "$P" worktree list --porcelain | grep -qxF "worktree $W"
   [ "$(git -C "$W" rev-parse --path-format=absolute --git-dir)" != \
     "$(git -C "$W" rev-parse --path-format=absolute --git-common-dir)" ]
   ```

   The last line proves it is a linked worktree, never a main checkout.

## 3. Free build output (low and critical)

Call `list_sessions` again, every page, and drop any path whose sessions are no longer all finished,
or now hold something. Then, for each finished path, with `W` set to it:

```sh
find "$W" -name .git -prune -o -type d \
  \( -name build -o -name .build -o -name DerivedData -o -name node_modules \) -print -prune |
while IFS= read -r D; do
  R=${D#"$W"/}
  if git -C "$W" check-ignore -q -- "$R/" && [ -z "$(git -C "$W" ls-files -- "$R" | head -n 1)" ]; then
    echo "freed $(du -sk "$D" | cut -f1) KB $D"
    rm -rf -- "$D"
  else
    echo "kept $D: tracked or not ignored"
  fi
done
```

A folder git ignores and tracks nothing in is build output, by the project's own
`.gitignore`: deleting it loses nothing a build cannot make again. Anything else is kept.

Then bound the build cache every worktree shares (#234). It is outside every worktree,
everything in it can be fetched or compiled again, and the script leaves it alone while
any build is running:

```sh
scripts/build-cache.sh prune --max-gb 30    # at the critical level: --max-gb 10
```

## 4. Remove archived worktrees (critical only)

At the critical level only, for each archived path `W` that passed step 2.4 and step 3:

```sh
git -C "$W" symbolic-ref -q HEAD                                   # on a branch
[ -z "$(git -C "$W" status --porcelain --untracked-files=all)" ]  # nothing uncommitted
git -C "$P" worktree remove "$W"                                   # no --force
```

If any line fails, keep it and say why. A detached HEAD is kept: its commits are on no
branch. The branch stays, with every commit: never delete it. Git itself refuses to remove
a worktree with changes or untracked files, or one that is locked.

## 5. Report

```sh
df -k "$P" | tail -1
```

If the disk is still below the event's `threshold`, name the five largest worktrees left:

```sh
du -sk "$P"/.agents/worktrees/* 2>/dev/null | sort -rn | head -5
```

End with one line per worktree touched (`freed <GB> from <name>` or `removed <name>,
branch <branch> kept`), then the free space before and after, then what was kept and why
(busy, holding, not named by a session, not clean). Then call `park_agent` with no id.
