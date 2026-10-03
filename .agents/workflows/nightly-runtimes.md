---
name: Nightly runtime check
on:
  - schedule:
      at: [":00"]
      between: "03:00-03:00"
agent: new
runtime: claude
model: haiku
effort: low
permission-mode: auto
cooldown: 20h
labels: [nightly, runtimes]
---

Update each agent runtime to its latest release and test it against the app (#39), with
`scripts/nightly-runtimes.py`. Run every command from the project folder, and change no file
or branch yourself: the script works in a tree of its own.

1. Call `list_my_agents` and note the runtimes it says are available. Then run
   `scripts/nightly-runtimes.py plan --available <those ids, comma-separated>`.
   If it prints `Nothing changed.`, finish with `nothing_to_do`, say nothing else, and park.
2. Lease the resource `build` with `lease_resource` for 60 minutes (if you are in line, keep
   waiting with `lease_resource`), run `scripts/nightly-runtimes.py build`, and release
   `build` with `release_resource` the moment it ends, whether it passed or not.
3. Run `scripts/nightly-runtimes.py check`. It starts and stops a scratch host of its own;
   never stop any other `agentsd` or `agents-control`.
4. Run `scripts/nightly-runtimes.py report`. It opens or updates one pull request per pinned
   runtime that passed, and one issue per runtime that failed.
5. If you started any helper agent, archive it with `archive_agent` (never delete its
   worktree).

Finish with `done`, and in the message list each runtime tested with its versions and what
the report opened, plus each runtime skipped and why. Then park.
