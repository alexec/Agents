---
name: Update the dashboard
on:
  - schedule:
      at: [":00"]
      between: "04:00-04:00"
agent: new
runtime: claude
model: haiku
effort: low
permission-mode: auto
cooldown: 20h
labels: [nightly, dashboard]
enabled: false
---

Bring this project's Dashboard up to date (#138), after the 03:00 runtime check. You keep
the tiles below, for this workflow, and set each one from its source. Run every command
from the project folder.

## Rules

- **Never invent a number.** Every value comes from the command named for it, run tonight.
  If a source can't be read (gh offline or signed out, a file missing), leave a number
  tile alone to go grey, or set a status tile to `unknown` with the reason in its line.
- **Read only, apart from `set_tile`.** No builds, no tests, no file edits, no `git fetch`,
  checkout, push or merge, no issue or PR edits. Never write `.agents/dashboard/` by hand.
- Leave tiles you are not told to keep below alone, and remove none.
- Give every tile the `source` written here, word for word, so its file changes only when
  its value does.

## Steps

1. Call `read_dashboard`. For each tile below kept by someone else, set it with
   `take_over: true`. If that is refused because its keeper is not archived, read the
   keeper's id from `.agents/dashboard/<id>.json`, call `read_session` on it, and set it
   again with `take_over: true`. If it is still refused, leave that tile and say so.
2. Set each tile, `stale_after_hours: 30`:

| id | title, type, section | value, from |
| --- | --- | --- |
| `github_issues` | Open issues, number, Project | `gh issue list --state open --limit 1000 --json number --jq length`; `unit` "of N total", N from the same with `--state all`; `good: down`. Source: `gh issue list --state open (unit: --state all)` |
| `open_bugs` | Open bugs, number, Project | `gh issue list --state open --label bug --limit 1000 --json number --jq length`; `good: down`. Source: `gh issue list --state open --label bug` |
| `open_prs` | Open pull requests, number, Delivery | `gh pr list --state open --limit 200 --json number --jq length`; `unit: PRs`, `good: down`. Source: `gh pr list --state open` |
| `ci_status` | CI on main, status, Delivery | `gh run list --workflow ci.yml --branch main --limit 5 --json status,conclusion,createdAt,headSha,url`: the newest completed run. `success` is `ok`, `failure` `bad`, anything else `warn`. Line: "Passed" or "Failed" (or the conclusion) at `<short sha>`, then its url; add "; a newer run is going" if one is. `since`: its createdAt as "3 Oct 04:00" local. Source: `gh run list --workflow ci.yml --branch main (newest completed)` |
| `total_commits` | Total commits, number, Project | `git rev-list --count main`; `good: up`. Source: `git rev-list --count main` |
| `not_shipped` | Merged, not shipped, number, Delivery | The newest `/tmp/main-restart-all-<sha>.log` (by `ls -t`) whose last line ends in `done`; `<sha>` is from its name. If `git merge-base --is-ancestor <sha> main` passes, the value is `git rev-list --count --first-parent <sha>..main`, `unit: on main`, `good: down`. With no such log (/tmp is emptied by a restart of the Mac) or a sha not on main, leave the tile. Source: `git rev-list --count --first-parent <shipped sha>..main, from /tmp/main-restart-all-*.log` |
| `runtime_check` | Nightly runtime check, status, Delivery | Read `~/Library/Application Support/Agents Nightly Runtimes/state.json` (each runtime's last tested version and result) and `runs/latest/run.json` beside it (`started`, and each runtime's `status`). `bad` if any runtime's result is `failed`, line "Failed: " and each as "Claude 0.85.1"; else `ok`, "All tested runtimes passed". Then add "; last run <started as 3 Oct 03:00>". `warn` instead if the latest run has a runtime still `testing` and no `report.md` beside it: "Last run <started> did not finish". `since`: `started`. A missing folder is `unknown`, "No nightly runtime check has run on this Mac". Source: `Agents Nightly Runtimes/state.json and runs/latest` |

Finish with `done`, and in the message give each tile's new value, and any tile left
alone and why. Then park.
