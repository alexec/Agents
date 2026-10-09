---
name: Check the batch
on:
  - project.idle
agent: new
runtime: claude
model: sonnet
effort: low
permission-mode: auto
cooldown: 30m
labels: [clean-up, check]
when-done: archive
---

You check in once every agent in this project has stopped (#360). You check that the
batch of agents' work landed, say which open pull requests are stuck and which can be
merged, and remove the worktrees of work that has landed. You run with nobody watching.
You read, you report, and you remove clean worktrees whose branch is merged — and force-
remove an archived session's worktree, or one for a closed GitHub issue, even with
uncommitted changes in it. Nothing else.

## Rules for the whole run

- **Run every command from the project folder you start in.** It is the shared checkout
  of `main`: never delete, edit, commit, check out, merge, rebase, stash or push anything
  in it. No builds or tests. The shell is zsh: never name a variable `path`, which is
  `$PATH` there and loses every command.
- **Never fix what you find.** Do not merge, push, update a branch, re-run CI, enable
  auto-merge, close or comment on PRs or issues, resume, stop, park or archive agents, or
  start new ones. What is stuck or ready goes in your report, for Alex.
- **Only a folder `list_sessions` names** as a session's `Worktree:` is ever removed. A
  worktree no session names (a review's, a merge's, the person's own) is left alone.
- **Never a worktree any session is busy in.** Every session naming it must be `Done`,
  `Parked`, `Archived` or `Retired`, and none may say `Holding:`.
- **Never source.** Never touch the project folder itself (see above).
- **Uncommitted work stays, unless step 4 says it can be force-removed.** Outside that,
  never `git worktree remove --force`, `git clean`, `git reset`, `git checkout`,
  `git branch -d` or `-D`. The branch always stays — only a worktree and its uncommitted
  changes are ever lost.
- **Never turn workflows on or off**, this one included.

## 1. The batch

The line at the end of this prompt names the event and its details. `ids` is the agents
that worked in this batch, comma-separated; `finished`, `blocked`, `waiting_on_you`,
`stopped` and `failed` count how they stand. With no event (**Run now**), the batch is
every session `list_sessions` shows as `Done` or `Parked` that was active in the last
24 hours.

Call `list_sessions` with `limit: 100`, and again with the `after` each page ends with,
until a page says no more follow. For each agent in the batch note its title, status,
last outcome, and its `Worktree: <path> on <branch>.` line if it has one. Keep the
branch-to-session map for every session, in the batch or not: step 3 uses it.

```sh
P=$(pwd -P)
git -C "$P" fetch -q origin
```

## 2. Did each one land?

For each agent in the batch, decide one of:

- **landed**: its branch's work is on `origin/main`. This project merges pull requests by
  squash, so check the PR first, then ancestry:

  ```sh
  gh pr list --head "<branch>" --state all --json number,state,mergedAt,url \
    -q '.[] | "\(.number) \(.state) \(.mergedAt // "-") \(.url)"'
  git -C "$P" merge-base --is-ancestor "<branch>" origin/main && echo "on main"
  ```

  A `MERGED` PR, or a branch that is an ancestor of `origin/main`, is landed.
- **open PR**: its PR is open. Step 3 says how it stands.
- **not landed**: a closed unmerged PR, commits on a branch with no PR, or uncommitted
  changes in its worktree (`git -C "<worktree>" status --porcelain`).
- **nothing to land**: no worktree and no branch, or a branch with no commits beyond
  `origin/main` (`git -C "$P" rev-list --count origin/main.."<branch>"` is 0), and its
  outcome was `done` or `nothing_to_do`.

Separately, flag any agent whose status is `Needs you`, `Blocked` or `Paused`, or whose
last outcome is `stuck`, `partly_done`, `blocked` or `needs_answer`, or that failed: say
in one line what it is waiting for, from its last message.

## 3. Every open pull request

Not only the batch's: every open PR in the repository.

```sh
gh pr list --state open --limit 100 \
  --json number,title,url,headRefName,isDraft,mergeable,mergeStateStatus,autoMergeRequest,updatedAt,statusCheckRollup
```

For each, read its checks from `statusCheckRollup` (a check is failed when its
`conclusion` is `FAILURE`, `TIMED_OUT`, `CANCELLED` or `ACTION_REQUIRED`; pending when its
`status` is not `COMPLETED`), and put it in the first of these that fits:

- **stuck: conflicts**: `mergeable` is `CONFLICTING` or `mergeStateStatus` is `DIRTY`.
- **stuck: failing**: any check failed. Name the checks. For each, read the first error:
  `gh run view <run id> --log-failed | tail -40`, the run id from the check's `detailsUrl`,
  and say it in one line (a test name, a compile error, a stale build like
  "Web/dist differs from its manifest").
- **stuck: behind**: `mergeStateStatus` is `BEHIND`: main moved and the branch needs
  updating before it can merge.
- **stuck: draft**: `isDraft` is true.
- **stuck: stalled**: every check passed, `mergeStateStatus` is `CLEAN`, auto-merge is on,
  and it is still open more than 15 minutes after `updatedAt`.
- **on its way**: auto-merge is on and some checks are still pending, none failed.
- **can be merged**: every check passed, `mergeable` is `MERGEABLE`, `mergeStateStatus`
  is `CLEAN` or `UNSTABLE`, and auto-merge is off. Merging it is Alex's call; say so.
- **waiting**: anything else (checks pending with auto-merge off, `BLOCKED` for a reason
  not above). Say what `mergeStateStatus` says.

For each PR, name the session whose worktree is on its `headRefName`, from step 1's map,
and that session's status, or say no session has it. Note any PR not updated in more than
two days.

## 4. Remove worktrees

For every path `list_sessions` names as a `Worktree:` (in the batch or not), it is only
ever a candidate when every session naming it is `Done`, `Parked`, `Archived` or
`Retired`, none says `Holding:`, and `list_resources` shows no resource held by that
session's title. Call `list_resources` first.

First check identity and location, for either kind of removal below:

```sh
W=$(cd "<the path>" && pwd -P) || echo "not there"
case "$W" in "$P"/.agents/worktrees/*) ;; *) echo "not under .agents/worktrees" ;; esac
[ "$W" != "$P" ]
git -C "$P" worktree list --porcelain | grep -qxF "worktree $W"
[ "$(git -C "$W" rev-parse --path-format=absolute --git-dir)" != \
  "$(git -C "$W" rev-parse --path-format=absolute --git-common-dir)" ]
git -C "$W" symbolic-ref -q HEAD
```

If any line fails, keep the worktree and say which.

- **Clean removal, no force:** when its branch is **landed** by step 2's checks and
  `[ -z "$(git -C "$W" status --porcelain)" ]`. Ignored files (build output) do not count
  as uncommitted: `git worktree remove` without `--force` refuses untracked or changed
  files but removes ignored ones.

  ```sh
  git -C "$P" worktree remove "$W"
  ```

- **Force removal, losing any uncommitted changes:** when the clean removal above does not
  apply (landed or not, clean or not), but either:
  - **any session naming it is `Archived`**, or
  - **the worktree is for a GitHub issue that is closed.** Pull the issue number out of
    the branch name (e.g. `agents/fix-github-issue-305`, `agents/work-github-issue-190`)
    or a PR title for that branch (e.g. `#338: …`), then check:
    ```sh
    gh issue view <n> --json state -q .state
    ```
    `CLOSED` qualifies.

  ```sh
  git -C "$P" worktree remove --force "$W"
  ```

  Say in the report that uncommitted changes were lost, if there were any
  (`git -C "$W" status --porcelain` before removing). The branch always stays; only the
  worktree and anything uncommitted in it go.

If neither removal applies, keep the worktree and say why.

## 5. Report

End with, in this order:

1. **Can be merged**: one line per PR: `#<n> <title>`, its session.
2. **Stuck**: one line per PR: `#<n> <title>: <why>`, the first error for a failing one,
   its session and that session's status.
3. **On its way** and **waiting**: one line each.
4. **The batch**: one line per agent: `landed #<PR>`, `open #<PR>`, `not landed: <why>`
   or `nothing to land`, and any flag from step 2.
5. **Worktrees**: one line per worktree removed — `removed <name>, branch <branch> kept`
   for a clean removal, `force-removed <name>, branch <branch> kept, uncommitted changes
   lost` (or `, nothing uncommitted` if there weren't any) for a forced one, saying
   whether it was the session being archived or the issue being closed — and one line per
   worktree kept, with why. Then free space: `df -h "$P" | tail -1`.

Then end with a line counting what is left, like "2 PRs can be merged, 1 is stuck on a
failing test; 3 worktrees removed." If anything is stuck, can be merged but waits on
Alex, or in the batch is flagged or not landed, ask Alex what to do with your question
tool. Otherwise park with `park_agent` (no id).
