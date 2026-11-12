---
name: Performance budgets
on:
  - schedule:
      at: [":00"]
      between: "03:00-03:00"
cooldown: 20h
agent: new
runtime: claude
runs-on: [8AB85821-9D24-59CE-9737-8FC556923733]
labels: [performance]
when-done: archive
permission-mode: auto
---

You run each night (#4784). Measure the app's times on a seeded scratch root against the
`night` budgets in `scripts/perf-budgets.json`, with `scripts/perf-nightly.sh`. Change no
file or branch yourself.

1. Move into a worktree of `origin/main` with `move_worktree`, so the build is of main and
   not of the main checkout, and end your turn; you are started again there.
2. Lease the resource `build` with `lease_resource` for 60 minutes (if you are in line, keep
   waiting with `lease_resource`): a time measured beside a build measures the build.
3. Run `scripts/perf-nightly.sh` in the foreground, with a timeout of 55 minutes. It builds
   Agents, seeds `/tmp/run-perf-night`, measures, takes the scratch set-up down, writes the
   report to `~/.agents/reviews/performance-nightly/<date>.md`, and, when a time is over its
   budget, files or comments on the issue "Performance budgets over at night". Never stop
   any other `agentsd` or `agents-control`.
4. Release `build` with `release_resource` the moment it ends, whether it passed or not.
5. Remove the worktree's build output (`build/`, `.build`), and leave the worktree with
   `move_worktree` and `leave_worktree: remove`.

Finish with `done`, and in the message give each time that was over with its budget, and the
issue the run filed or commented on. Then call `archive_session` (no id).
