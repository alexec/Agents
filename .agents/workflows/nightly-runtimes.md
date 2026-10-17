---
name: Weekly runtime check
on:
  - schedule:
      at: [":00"]
      between: "03:00-03:00"
      days: [sat]
agent: new
runtime: claude
model: sonnet
permission-mode: auto
cooldown: 6d
hosts: [8AB85821-9D24-59CE-9737-8FC556923733]
labels: [weekly, runtimes]
when-done: archive
---

Update each agent runtime to its latest release and test it against the app (#39), with
`scripts/nightly-runtimes.py`. Run every command from the project folder, and change no file
or branch yourself: the script works in a tree of its own.

1. Call `list_sessions` with `started_by: me` and note the runtimes it says are available. Then run
   `scripts/nightly-runtimes.py plan --assess --available <those ids, comma-separated>`.
   If it prints `Nothing changed.`, say nothing else, and call `archive_session` (no id).
2. Lease the resource `build` with `lease_resource` for 60 minutes (if you are in line, keep
   waiting with `lease_resource`), run `scripts/nightly-runtimes.py build`, and release
   `build` with `release_resource` the moment it ends, whether it passed or not.
3. Run `scripts/nightly-runtimes.py check --assess`. It starts and stops a scratch host of its
   own; never stop any other `agentsd` or `agents-control`. Each runtime whose turn passed
   gets the runtime assessment of #47, about five minutes each, on its own allowance (#1284).
4. Run `scripts/nightly-runtimes.py report`. It opens or updates one pull request per pinned
   runtime that passed, and one issue per cause of failure (runtimes that failed for the same
   cause share it). An assessment step that failed last time too is listed, not filed. It
   also opens or updates one pull request, with auto-merge, on `nightly/runtime-assessments`:
   each runtime's record in `.agents/reviews/runtimes/` and its row in
   `docs/reference/integrations.md`.
5. If you started any helper agent, archive it with `archive_session` (never delete its
   worktree).

Finish with `done`, and in the message list each runtime tested with its versions and what
the report opened, plus anything already failing on main and each runtime skipped and why. Then call `archive_session` (no id).
