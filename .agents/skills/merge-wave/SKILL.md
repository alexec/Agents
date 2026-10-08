---
name: merge-wave
description: Merge a wave of ready lane branches into main together. They are merged in one scratch worktree, verified once on the combined tip by the paths they change, and main is fast-forwarded once. The wave does not install the app. Use when asked to merge, land or "run merge-wave on" one or more lane branches (agents/…), or to finish a lane's work onto main. Not for shipping on its own (ship-app) or testing one change (run-app).
---

# Merge a wave of lane branches

One script does the git work and decides what to build. Do not merge by hand, re-verify
each branch on its own, or settle `generated.ts` conflicts yourself.

```sh
W=.agents/skills/merge-wave/scripts/merge-wave.sh
```

Run it from your own worktree, never from the main checkout. It finds the main checkout
itself.

## Which branches

A branch is ready when its lane has rebased it onto main, verified it at that tip, and
said so in its ending with the sha. Pin that sha as `branch@sha`. The wave refuses a
branch that has moved past it. A branch without a pin is taken at its tip, on trust.

The first branch that still fast-forwards from main becomes the wave's base as it is, with
no rebuild. The rest are merged in the order given, one merge commit each.

## The loop

```sh
$W plan agents/fix-github-issue-139@1a2b3c agents/work-github-issue-47@4d5e6f   # touches nothing
$W start agents/fix-github-issue-139@1a2b3c agents/work-github-issue-47@4d5e6f
# prints WAVE=/tmp/wave-<stamp>, merges what needs no build, then the first step
```

`plan` (or `--dry-run`) shows which branch fast-forwards, which merge cleanly, which
conflicts the wave settles itself, which stop it, and the builds. A wave does not install.
It simulates the merges with `git merge-tree`, so no ref, worktree or file changes.

Then repeat until the step is `finish`:

```sh
$W next $WAVE
# step=build-host lease=build minutes=30  xcodegen generate … xcodebuild -scheme AgentsHost …
```

1. If `lease=build`, call `lease_resource` for "build" for `minutes`. If you are told you
   are in line, end your turn. You are started again when the lease is yours.
2. Run `$W step $WAVE build-host`. Naming the step guards against running the wrong one.
3. Call `release_resource` for "build" the moment it returns, before you read its output.

`lease=none` steps (`merge`, `finish`) need no lease. A step prints what it did and the
next step. Logs are in the wave's state folder, and each step prints the path.

Then:

```sh
$W finish $WAVE     # fast-forwards main, checks merge-base --is-ancestor for every branch
```

It prints a line per branch (merge sha, checks, or why it was dropped) and `SHIP=yes|no`.
`SHIP=yes` means product code changed. It does not mean install.

## What it settles, and what stops it

- **`generated.ts` conflicts:** the merge stays open and the next step is `rebuild-web`
  (under the lease). It runs `scripts/web.sh types` in the wave and commits the merge with
  the regenerated file. `Web/dist` is not checked in (#473); a branch from before that which
  still carries it conflicts with its removal, and the wave keeps it removed.
- **`specs/071-web-remote/walks/parity.md`:** both sides' rows are kept, as a union. If
  both lanes edited the same row, both copies stay: read the merged table before
  you finish and fix it in a follow-up if needed.
- **Any other conflict stops the wave** (`next` exits 3) and names the files. Either:
  - settle them in `$WAVE`, commit the merge, then run `$W resume $WAVE`; or
  - run `$W drop $WAVE <branch>` to leave it out and go on.

  When the conflict is not yours to judge, ask the branch's lane to rebase, then drop it.

## What it checks

The checks are picked from what the merged branches bring. The fast-forwarded base was
verified by its lane.

| Changed | Steps |
|---|---|
| `App/`, `Host/`, `Daemon/`, `Packages/` | `build-host` and `build-store` |
| `Remote*/`, `Shared/`, `Packages/AgentsKit` or `CodeText`, `project.yml` | `build-remote` (generic iOS Simulator) |
| `Web/` | `web`: a rebuild that must change nothing, `npm run check` and `npm test` |
| Swift packages | `test-*`: the suites `scripts/select-test-suites.sh` picks, as CI does (AgentsKit filtered) |
| shippable and `build-host` | `smoke`: the run-app check below |
| `docs/`, `specs/`, `.agents/` only | nothing, so straight to `finish` |

The Mac builds use the wave's `build/DD`, as run-app's `launch.sh` does, so the smoke
check rebuilds nothing. Every build and test goes through `scripts/build-cache.sh`, so a
fresh wave worktree replays what the lanes already compiled.

**Checks that passed before are not run again (#234).** Every pass is recorded by tree
hash in `<main>/.git/merge-wave-passed`. When the tree a check would run on already passed
it (a wave started again with the same branches, a bisect probe at the wave's base, which
is the last wave's tip), `next` says `lease=none … passed at this tree before` and `step`
marks it passed without building. Take no lease for those.

**This is the one place everything runs.** Lanes verify only the schemes and tests for
what they touched. The wave runs every check the merged paths need, the full test
suites included, once.

**The smoke check** (`smoke`) runs the run-app loop on the wave's tip. It starts
`launch.sh --slug w<stamp>` (its own control plane, host and window, behind Alex's), checks
that `daemon/ping` and `agents/list` answer on the socket, takes a screenshot to
`/tmp/run-w<stamp>-smoke.png`, and stops it with `stop.sh`. Read the screenshot. A
locked screen leaves no picture, but the socket check still counts.

**On a failure**, a failed `test-*` step runs once more first, because the suites flake
under load. Then the script bisects over the wave's merge commits, one `bisect` step
(leased) per probe. It finds the branch at fault, drops it, merges the rest again, and
starts the checks over. If the wave's base fails too, it stops: main is broken, not a
lane. Tell the lead which branch was dropped, and why, with the log path.

## Do not install

`SHIP=yes` means product code changed. Stop there. Do not run `ship.sh`. Do not copy a
build into `~/Applications`, `/Applications` or `~/AgentsApps`, and do not restart the
login-item jobs (`launchctl kickstart` on `com.alexecollins.agentshost.daemon` or
`.control`). Putting the app on this Mac is ship-app with `--install-mac`, and only when
Alex asks for that by name.

Then `$W clean $WAVE` removes the wave's own worktree and its `lead/wave-*` branch.
That is the only worktree the wave removes.

## Standing rules

- **Never edit or build in the main checkout.** The wave builds in `/tmp/wave-*`. `finish`
  only runs `git merge --ff-only` there. It does not build, and it does not install.
- **Never remove lane worktrees** (#119), and never delete lane branches.
- **Never close issues.** That is the lead's job.
- **Never kill Alex's windows.** The smoke check stops only the pids in its own root.
  Do not `pkill`, `killall` or ⌘Q anything.
- Never run the script against a main you were not told to merge into. To try it out,
  use `scripts/selftest.sh`. It works in a throwaway clone at `/tmp/mw-selftest` and
  covers two clean branches, two page changes with no bundle to settle, a real conflict, a failing check, a
  docs-only wave, and a wave started again that reuses the first one's passes. Its builds are a stub (`MERGE_WAVE_STUB`), except a real
  `web.sh` step if a wave reaches `rebuild-web`, so run it under the "build" lease.
- If main moved while the wave ran, `finish` refuses. Start a new wave with the same
  branches.
