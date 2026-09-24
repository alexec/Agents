# Implementation Plan: A Project From a Git URL

**Branch**: `027-project-from-git-url` (built in the shared tree; see tasks.md) | **Date**: 2026-09-24 | **Spec**: [spec.md](./spec.md)

## Summary

New project becomes a menu: *Choose Folder…* (today's picker) and *Clone Git URL…*, which opens a
small sheet. The daemon clones into a staging folder inside its own root, then moves the result to
`~/<name>` and adds it through the existing `addProject` path. Nothing half-made ever sits in the
home folder, so cleaning up after a failure or a restart is deleting the staging folder. A clone in
progress is daemon state, broadcast to every window, and shown as a row in the Projects column.

## Technical Context

**Language/Version**: Swift 6, macOS 15 (as the rest of the app)
**Primary Dependencies**: Foundation `Process` running the user's `git`; no new packages
**Storage**: none new. Staging under `<root>/Clones/`, deleted wholesale on daemon start
**Testing**: swift-testing in `Packages/AgentsKit`, with real `git` against local `file://`-free bare repos (see Research 6)
**Target Platform**: the Mac app and `agentsd`. Remote/iPad untouched
**Constraints**: never write into, rename, or delete anything in the home folder that the clone did not put there

## Constitution Check

The constitution file is still the unfilled template; no gates apply. The standing rules from this
tree apply instead: settle the UX before depth (the sheet and the row are Phase 3, and are what gets
run and looked at), and prove with the run-app skill on a scratch root, not the real daemon.

## Research (decisions)

1. **Where the URL is understood — `GitRemote` in AgentsKitCore.** A pure value: parses HTTPS
   (`https://host/path`), `ssh://[user@]host[:port]/path` and scp-like `[user@]host:path`;
   refuses everything else, including `http://`, `git://`, `file://` and local paths. Gives
   `folderName` (last path component minus `.git`; refused if empty, `.` or `..`) and an
   `identity` (lowercased host without user/port, lowercased path without leading `/`, trailing
   `/` or `.git`) so HTTPS and SSH spellings compare equal (spec Edge Cases). In Core so the
   window can validate as the person types, before any call (US2 scenario 1), and the daemon
   validates again.
2. **Stage, then move.** `git clone` runs into `<root>/Clones/<uuid>/<name>`. On success it is
   moved to `~/<name>` with `FileManager.moveItem`, which fails rather than overwrite if something
   appeared there meanwhile — that failure is reported as the folder being in the way. On any
   failure the staging folder is removed. On daemon start `<root>/Clones` is removed whole, which
   is FR-011 with no bookkeeping. Rejected: cloning straight into `~/<name>` and remembering to
   delete it — a crash would leave a partial checkout in the person's home folder.
3. **Which git, and no prompts.** `git` is looked up on `LoginShellPath.directories()`; not found
   → "Git is not installed". Run with `LoginShellPath.environment()` plus
   `GIT_TERMINAL_PROMPT=0` and stdin from `/dev/null`. The daemon has no terminal, so ssh cannot
   prompt either; `GIT_SSH_COMMAND` is **not** set, because it would override the person's own
   `core.sshCommand`. `xcrun: error` on stderr (the `/usr/bin/git` shim without tools) also reads
   as not installed. Arguments: `clone --progress -- <url> <dest>` — the `--` stops a URL starting
   with `-` from being read as an option.
4. **Failures in plain words.** stderr is kept; `CloneFailure.explain` maps the known git
   sentences (repository not found, could not resolve host, could not read Username / terminal
   prompts disabled, Permission denied (publickey), Host key verification failed) to one sentence
   naming the host, and otherwise falls back to git's last `fatal:` line.
5. **Already cloned.** If `~/<name>` exists: a directory with `.git` whose
   `git config --get-regexp '^remote\..*\.url$'` includes a URL with the same `identity` is added
   as-is (read only; no fetch). `addProject` is already idempotent for an existing project, and
   unarchive is called first when the folder is an archived project (US3 scenario 3). Anything
   else → refused with `folderInTheWay`, naming the path.
6. **Tests use real git, offline.** A fixture makes a bare repo under the test's temp root and a
   clone URL for it. Local paths are not accepted from people (Research 1), so the daemon takes
   an injectable `cloneURLRewrite` hook used only by tests, mapping `https://example.test/x.git`
   to the local bare path. Parsing, naming and error mapping are unit tests with no git.
7. **Where it goes — `~` unless told otherwise.** `DaemonCore.cloneParent` defaults to the home
   folder; `AGENTS_CLONE_PARENT` overrides it, read once at daemon construction. Only for scratch
   runs and tests, so the run-app walk never writes into the real home folder.
8. **Progress.** Indeterminate, with the repository's name. Git's percentage lines are not parsed;
   the spec asks only that a clone be visibly under way (FR-006).
9. **The daemon stays up.** A clone in progress counts in `isHoldingAgents`, so the idle exit does
   not kill it with no window open. On `shutDown` running clone processes are terminated.

## Data model

- `GitRemote` (Core, `Sendable, Hashable`): `url: String`, `host: String`, `path: String`,
  `folderName: String`, `identity: String`. `init?(_ text: String)` trims whitespace.
- `DaemonAPI.CloneRequest { url: String }`.
- `DaemonAPI.CloneSummary { id: UUID, url: String, folder: URL, startedAt: Date }` — one per
  clone in progress.
- `DaemonAPI.CloneNotification { clone: CloneSummary, finished: Bool }`.
- `DaemonCore.clones: [UUID: RunningClone]` where `RunningClone` holds the summary and the
  `Process`.

## Contract

- `projects/clone` `CloneRequest` → `ProjectSummary`. Returns when the project exists. Errors:
  `notACloneURL` (-32024), `folderInTheWay` (-32025, message names the path), `cloneFailed`
  (-32026, message is the plain sentence). Broadcasts `clone/changed` (`finished: false`) on
  start and (`finished: true`) at the end, whichever way it ends, then `project/changed` on
  success via `addProject`.
- `projects/clones` → `[CloneSummary]`, for a window that connects mid-clone.

## Project Structure

```text
Packages/AgentsKit/Sources/AgentsKitCore/Model/GitRemote.swift        new
Packages/AgentsKit/Sources/AgentsKitCore/Daemon/DaemonAPI.swift          + method, notification, types, failures
Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Cloning.swift     new: clone, adopt, staging, cleanup
Packages/AgentsKit/Sources/AgentsKit/Projects/GitClone.swift             new: running git, explaining failures
Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore.swift             + clones, cloneParent
Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Dispatch.swift    + two cases
Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Lifetime.swift    + clones hold the daemon
Packages/AgentsKit/Sources/AgentsKit/Daemon/Daemon.swift                 + staging cleanup on start
App/Sources/Projects/ProjectListView.swift                              menu, cloning rows
App/Sources/Projects/CloneSheet.swift                                   new: the URL sheet
App/Sources/AppModel.swift                                              clones state, cloneProject()
Packages/AgentsKit/Tests/AgentsKitTests/Unit/GitRemoteTests.swift       new
Packages/AgentsKit/Tests/AgentsKitTests/Unit/CloneFailureTests.swift    new
Packages/AgentsKit/Tests/AgentsKitTests/Integration/CloneProjectTests.swift new
```
