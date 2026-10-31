---
name: Runtime check
on: manual
agent: new
runtime: claude
runs-on: [8AB85821-9D24-59CE-9737-8FC556923733]
labels: [release, runtimes]
when-done: archive
permission-mode: auto
---

You run once per release, started by the Release run (#1462). Update each agent runtime
to its latest release and test it against the app (#39), with
`scripts/nightly-runtimes.py`. Run every command from the folder, and change no file
or branch yourself: the script works in a tree of its own.

1. Call `list_sessions` with `started_by: me` and note the runtimes it says are available. Then run
   `scripts/nightly-runtimes.py plan --available <those ids, comma-separated>`. It plans
   only the runtimes with a new release since the last run: what changed is the scope
   (#1462). Never add `--assess` or `--force`.
   If it prints `Nothing changed.`, say nothing else, and call `archive_session` (no id).
   If it fails instead (it could not even prepare its tree, for example `git fetch`
   could not write `.git/FETCH_HEAD`), it has already filed or updated an issue for that
   on its own (#2912): do not call it `done` as if nothing needed testing. Say in your
   report that `plan` failed and name the issue, then stop; do not go on to `build`.
2. Lease the resource `build` with `lease_resource` for 60 minutes (if you are in line, keep
   waiting with `lease_resource`), run `scripts/nightly-runtimes.py build`, and release
   `build` with `release_resource` the moment it ends, whether it passed or not.
3. Run `scripts/nightly-runtimes.py check`. It starts and stops a scratch host of its
   own; never stop any other `agentsd` or `agents-control`.
4. Run `scripts/nightly-runtimes.py report`. It opens or updates one pull request per pinned
   runtime that passed, and one issue per cause of failure (runtimes that failed for the same
   cause share it), and one issue per runtime that no longer offers a model or mode an Auto
   mapping uses (#2658).
5. If you started any helper agent, archive it with `archive_session` (never delete its
   worktree).

Finish with `done`, and in the message list each runtime tested with its versions and what
the report opened, plus anything already failing on main and each runtime skipped and why. Then call `archive_session` (no id).
