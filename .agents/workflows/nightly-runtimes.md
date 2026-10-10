---
name: Weekly runtime check
on:
  - schedule:
      at: [":00"]
      between: "03:00-03:00"
      days: [sat]
agent: new
runtime: claude
model: haiku
effort: default
permission-mode: auto
cooldown: 6d
hosts: [8AB85821-9D24-59CE-9737-8FC556923733]
labels: [weekly, runtimes]
when-done: archive
---

Update each agent runtime to its latest release and test it against the app (#39), with
`scripts/nightly-runtimes.py`. Run every command from the project folder, and change no file
or branch yourself: the script works in a tree of its own.

1. Call `list_my_agents` and note the runtimes it says are available. Then run
   `scripts/nightly-runtimes.py plan --available <those ids, comma-separated>`.
   If it prints `Nothing changed.`, say nothing else, and call `request_archive` (no id).
2. Lease the resource `build` with `lease_resource` for 60 minutes (if you are in line, keep
   waiting with `lease_resource`), run `scripts/nightly-runtimes.py build`, and release
   `build` with `release_resource` the moment it ends, whether it passed or not.
3. Run `scripts/nightly-runtimes.py check`. It starts and stops a scratch host of its own;
   never stop any other `agentsd` or `agents-control`. (`--assess` adds the runtime
   assessment of #47 for each runtime whose turn passed, about five minutes each. It is off:
   add it only when Alex asks for it.)
4. Run `scripts/nightly-runtimes.py report`. It opens or updates one pull request per pinned
   runtime that passed, and one issue per cause of failure (runtimes that failed for the same
   cause share it). What already fails on main is listed, not filed.
5. If you started any helper agent, archive it with `archive_agent` (never delete its
   worktree).

Finish with `done`, and in the message list each runtime tested with its versions and what
the report opened, plus anything already failing on main and each runtime skipped and why. Then call `request_archive` (no id).
