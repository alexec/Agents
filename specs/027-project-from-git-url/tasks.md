# Tasks: A Project From a Git URL

**Input**: [spec.md](./spec.md), [plan.md](./plan.md)

**Tests**: Included. Parsing and failure wording are pure and cheap to pin; the clone itself is
tested against real git on local bare repositories.

## Before you touch anything

- Other lanes share this working tree (`AppModel.swift` already carries another lane's edits).
  Add hunks; never revert or reformat what is there. Committing is a hunk-splitting job.
- `xcodegen generate` after adding any App source file.
- Walk on a scratch root with `AGENTS_CLONE_PARENT` set, never the real daemon or real `~`.

## Phase 1: Foundational

- [X] T001 [P] `GitRemote` in `Packages/AgentsKit/Sources/AgentsKitCore/Model/GitRemote.swift` (plan Research 1)
- [X] T002 [P] `GitRemoteTests` in `Tests/AgentsKitTests/Unit/GitRemoteTests.swift`: the three accepted forms, refused forms, folder names, identity equality across HTTPS/SSH/`.git`/trailing slash/case
- [X] T003 DaemonAPI: `projectsClone`, `projectsClones`, `cloneChanged`, `CloneRequest`, `CloneSummary`, `CloneNotification`, failures -32024…-32026

## Phase 2: US1 — paste a URL, get a project (P1)

- [X] T004 `GitClone` in `Sources/AgentsKit/Projects/GitClone.swift`: find git, run clone with no prompts, read remotes of an existing checkout, `explain` failures (Research 3–4)
- [X] T005 `DaemonCore+Cloning.swift`: `cloneProject(_:)` — validate, reserve destination, stage, clone, move, `addProject`, broadcast `clone/changed`; `allClones()`
- [X] T006 `DaemonCore`: `clones`, `cloneParent` (+`AGENTS_CLONE_PARENT`), `cloneURLRewrite`; Dispatch cases; `isHoldingAgents` counts clones; `shutDown` terminates them; `Daemon.start` clears `<root>/Clones`
- [X] T007 `CloneProjectTests`: a URL becomes a project at `<parent>/<name>` with the repo's history, selected summary returned, `clone/changed` start and finish broadcast
- [X] T008 App: `AppModel.clones`, `cloneProject(url:)` selecting the result, `clone/changed` handling, `projects/clones` in `refreshEverything`
- [X] T009 App: New project menu (Choose Folder… / Clone Git URL…), `CloneSheet` with live validation and destination line, pasteboard prefill; cloning rows in the list; empty-state button offers both
- [X] T010 Build the Mac scheme; walk it on a scratch root (run-app skill)

## Phase 3: US2 — a clone that cannot happen says why (P2)

- [X] T011 [P] `CloneFailureTests`: each known git sentence maps to its plain message; unknown falls back to the last `fatal:` line
- [X] T012 `CloneProjectTests`: not a URL refused with nothing created; unreachable repo fails, no project, no folder at the destination, staging empty; unrelated folder in the way refused and untouched; second clone to the same name refused while the first runs
- [X] T013 `CloneProjectTests`: leftover staging from a previous run is removed on start

## Phase 4: US3 — already cloned becomes the project (P3)

- [X] T014 Adopt an existing checkout whose remote matches (read only); unarchive if archived
- [X] T015 `CloneProjectTests`: existing checkout adopted with HEAD and a dirty file unchanged; SSH spelling of an HTTPS clone adopted; archived project brought back

## Phase 5: Polish

- [X] T016 Full package suite; Mac scheme build; note results in Implementation Notes below

## Implementation Notes (2026-09-24)

- **Results**: package suite 1221 tests pass (19 new: `GitRemoteTests`, `CloneFailureTests`,
  `CloneProjectTests`); the Mac scheme builds.
- **Walked over the socket, not by eye.** Scratch root `/tmp/run-clone`, `agentsd` started by hand
  with `AGENTS_CLONE_PARENT=/tmp/run-clone/home`, app attached with `--root`. A real
  `https://github.com/octocat/Hello-World.git` became a project at `home/Hello-World` with its
  history; `clone/changed` was heard; the SSH spelling adopted the same folder; a missing repo, a bad
  host and plain text each came back with their plain sentence and left nothing in `home`. The screen
  was locked, so **the sheet, the menu and the Cloning… row have not been seen**. That look is Alex's.
- **T012, part not done**: "second clone to the same name refused while the first runs" is in the
  code (`clones` checked and reserved with no await between) but has no test. A local clone finishes
  too fast to overlap, and holding one open would need a test-only hook in the clone path.
- **`waitUntilExit` hangs on a dispatch thread** after git has exited. `GitProcess.run` ends on
  `terminationHandler` instead. Worth knowing before copying `LoginShellPath`'s pattern anywhere else.
- **GitHub's not-found**: over HTTPS with prompts off, GitHub now says "Repository not found", not a
  username prompt, so a missing repo and a private one you cannot read get the same message. The
  message says both.
- Walked by Alex in the app on 2026-09-24 and approved for main. Committed alone from a worktree of
  main; the shared tree's `canStop` hunk in `AppModel.swift` is 026's and was left out.
