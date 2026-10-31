---
name: free-disk-space
description: Free disk space on this Mac (#199, #1796) until 20% of the disk is free. Bound the shared build cache (Swift and Go), delete the build output that finished agents left in their worktrees, remove the worktrees of archived agents whose work is all on their branch, end leaked headless Chromes and their clones, remove old Xcode device support and unavailable simulators, and remove the Xcode DerivedData of removed worktrees. Nothing else. Use when the Free disk space workflow runs on machine.disk_low, or when Alex asks to free disk space.
---

# Free disk space

This is the method of the Free disk space workflow
(`.agents/workflows/free-disk-space.md`). The workflow says what the method is for and
starts it. A person or an agent can also follow it by hand. Where it says that nobody is
at the keyboard, that is true only of a run of the workflow.

**Work to the target, not to the threshold (#1796).** The target is 20% of the disk free
(about 92 GB on a 494 GB disk). After each of steps 3 to 6, run:

```sh
scripts/free-disk.sh status   # exits 0 at the target, 1 under it
```

When it says `reached`, go to step 7. Otherwise go on to the next step, until the steps
run out. Stopping at the threshold brings the next low event a few hours later.

## Rules for the whole run

- **Run every command from the folder you start in.** It is the shared checkout
  of `main`: never delete, edit, commit, check out, merge, rebase, stash or push anything
  in it. No builds or tests. The shell is zsh: never name a variable `path`, which is
  `$PATH` there and loses every command.
- **Only a folder `list_sessions` names** as a session's `Worktree:` is ever looked at.
  A worktree no session names (a review's, a merge's, the person's own) is left alone.
- **Never a worktree any session is busy in.** Every session naming it must be `Done`,
  `Archived`, and none may say `Holding:`. `Working`, `Waiting`, `Blocked`,
  `Needs you` and `Paused` all leave it alone.
- **Never source, and never uncommitted work.** `rm` only a folder that passes the check in
  step 4. Never `git worktree remove --force`, `git clean`, `git reset`, `git checkout`,
  `git branch -d` or `-D`.
- **End a process only with `scripts/free-disk.sh chromes`.** It ends only headless
  Chromes with a profile under `/tmp` that started more than 6 hours ago. Never `kill`,
  `pkill` or `killall` anything yourself: not the person's own Chrome, not the sign-up
  Chrome (`--user-data-dir=…/.agents/signups/chrome-profile`), not a build.
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
   until a page says no more follow: a folder has more sessions than one page (#210). A
   line with `Worktree: <path> on <branch>.` ties that folder to that session. Group the lines by path.
2. A path is **finished** if every session naming it is `Done` or
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

## 3. Bound the build cache

Bound the build cache every worktree shares (#234). It is outside every worktree,
everything in it can be fetched or compiled again, and the script leaves alone each folder
that a running build uses, and Go's part while Go runs. The Swift part and Go's part each have a bound of
their own, so a large Go cache never costs the Swift one:

```sh
scripts/build-cache.sh prune                                # low: 15 GB, of it Go 3 GB
scripts/build-cache.sh prune --max-gb 6 --go-max-gb 1       # critical
```

Each build also prunes it to 15 GB behind itself (#2346), so this step frees little
unless a bound was raised. The last line says `after: <GB>; freed <GB>`: put both in the
report. If it exits non-zero, say so with its output in the report, and go on.

## 4. Free build output

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

A folder git ignores and tracks nothing in is build output, by the folder's own
`.gitignore`: deleting it loses nothing a build cannot make again. Anything else is kept.

## 5. Remove archived worktrees

At both levels, for each archived path `W` that passed step 2.4 and step 4:

```sh
git -C "$P" fetch -q origin                                        # the remote branches now
git -C "$W" symbolic-ref -q HEAD                                   # on a branch
[ -z "$(git -C "$W" status --porcelain --untracked-files=all)" ]  # nothing uncommitted
[ -z "$(git -C "$W" rev-list -n 1 HEAD --not --remotes)" ]        # every commit pushed
git -C "$P" worktree remove "$W"                                   # no --force
```

If any line fails, keep it and say why. The fourth line passes only when HEAD is on a
remote branch or on main: a commit that no remote branch has is work that is not pushed,
and its worktree stays. A detached HEAD is kept: its commits are on no
branch. The branch stays, with every commit: never delete it. Git itself refuses to remove
a worktree with changes or untracked files, or one that is locked.

## 6. Leaked Chromes and Xcode leftovers

```sh
scripts/free-disk.sh chromes       # ends leaked headless walk Chromes, then removes clones no process uses
scripts/free-disk.sh xcode         # older iOS DeviceSupport builds per device, unavailable simulators
scripts/free-disk.sh deriveddata   # Xcode DerivedData of worktrees that are gone (--dry-run to look first)
```

A walk's headless Chrome that was left running keeps an APFS clone of the Chrome app (up
to 3 GB) until it ends. Walks end theirs now (`Web/test/walk/cdp.mjs`), but one stopped
with `kill -9` still leaks. Xcode keeps a DeviceSupport folder (about 6.5 GB) for every
OS build a device has run; only the newest per device model is kept, and Xcode makes it
again when a device needs it.

Xcode builds each worktree into `~/Library/Developer/Xcode/DerivedData/Agents-<hash>`
(3 to 4 GB), not into the worktree, so step 4 does not find it and step 5 leaves it
(#2683). `deriveddata` removes an `Agents-*` folder only when its `info.plist` names a
`WorkspacePath` under `$P/.agents/worktrees/` that is gone, and no running `xcodebuild`
names the folder or that worktree. It keeps a folder with no `info.plist`, a folder of
any other project, and Xcode's shared caches (`ModuleCache.noindex`, `SDK*`). It prints
each folder it removes and its size.

## 7. Report

```sh
df -k "$P" | tail -1
```

```sh
scripts/free-disk.sh status
```

If the target is not reached, say how far short it is, and name the five largest worktrees left:

```sh
du -sk "$P"/.agents/worktrees/* 2>/dev/null | sort -rn | head -5
```

End with one line per worktree touched (`freed <GB> from <name>` or `removed <name>,
branch <branch> kept`), then the build cache before and after, the Chromes ended and
clones removed, the Xcode folders and DerivedData folders removed, then the free space before and after and how
far from the target, then what was kept and why (busy, holding, not named by a session,
not clean). Then call `archive_session` with no id.
