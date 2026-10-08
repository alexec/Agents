# Implementation Plan: Chat with an agent in a project the app makes

**Branch**: `agents/spec-229-chat-project` | **Date**: 2026-10-06 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `specs/229-projectless-chat/spec.md`

## Summary

Each host's daemon makes `<personal home>/.agents/chat` at start and lays it out once as an ordinary project, through `layOutOnce`. It does nothing when the root has no personal home, or when a record of the project already exists, archived or not.

The daemon marks that one project in `projects/list` with a new optional `isChat` field. A new `projects/chatState` call says why a host has none. Clients find the chat project by the mark, never by building a path.

Each client gets **New Chat**, which opens the existing new-session form on the chosen host's chat project:
- **Mac**: File menu with ⇧⌘N, and the sidebar's + menu.
- **Remote**: the sidebar's toolbar.
- **Web**: the sidebar's + menu.

Chats are ordinary sessions, so nothing else in the session model changes.

The not-a-repository states mostly exist already:
- Worktree choices hide on all three clients.
- The Mac and Remote Changes panes say the folder isn't tracked by git.
- A move into a worktree is refused with a sentence.

The one gap is the web Changes view, which shows nothing for `unavailable`. It gets the same one-line state.

## Technical Context

**Language/Version**: Swift 6 (AgentsKit, App, Remote, Shared/UI); TypeScript with Preact (Web)

**Primary Dependencies**: none new

**Storage**: `<root>/projects.json` (the existing project record); the chat folder on disk at `<personal home>/.agents/chat`

**Testing**: Swift Testing in `Packages/AgentsKit/Tests/AgentsKitTests` (daemon), `scripts/web.sh` checks (web), and run-app with `AGENTS_PERSONAL_HOME` set to a scratch home for the Mac walk

**Target Platform**: macOS daemon and window; Linux agentsd (same `Daemon.start`); iOS/iPadOS Remote; web page served by the host

**Project Type**: desktop app + daemon, mobile client, web client

**Performance Goals**: no measurable cost at daemon start, which adds one `stat` when the record exists, and one stamp per `projects/list` (a folder compare)

**Constraints**:
- The daemon never makes the folder for a root with no personal home, so scratch roots and tests are safe.
- Older clients must decode the list unchanged.
- There is no new start kind.

**Scale/Scope**:
- One project per host.
- Three clients, about 10 source files and 6 docs pages.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Check | Status |
|---|---|---|
| I. Spec-led | The spec has acceptance scenarios. Alex settled its open questions on 2026-10-06. | Pass |
| II. Capability-driven runtimes | No runtime-specific behaviour. Chats start like any session, and no extra folder is needed. | Pass |
| III. Scoped access | A chat's folder is its project folder, so the sandboxes and `FolderScope` apply unchanged. The daemon writes only inside the personal home it was given (`StoreLocations.personalHome`). | Pass |
| IV. Inspectable | The chat project is visible like any project. A failure to make it is logged and shown by New Chat (FR-011). | Pass |
| V. Docs and quality | The spec's Docs section lists 6 pages. `generated.ts` is regenerated from source (`scripts/web.sh types`). | Pass |
| Constraint: no user-home config outside granted folders | The daemon, not an agent, makes `~/.agents/chat`, inside the app-owned `~/.agents`. | Pass |

Post-design re-check: still passes. No deviations, so Complexity Tracking is empty.

## Project Structure

### Documentation (this feature)

```text
specs/229-projectless-chat/
├── spec.md
├── plan.md              # this file
├── research.md          # Phase 0
├── data-model.md        # Phase 1
├── quickstart.md        # Phase 1
├── contracts/
│   └── projects-list.md # the isChat mark on projects/list
├── checklists/requirements.md
└── tasks.md             # /speckit-tasks, not yet
```

### Source Code (repository root)

```text
Packages/AgentsKit/Sources/
├── AgentsKitCore/Daemon/DaemonAPI.swift            # ProjectSummary.isChat (optional, default false); projects/chatState + ChatProjectState
├── AgentsKitCore/Store/StoreLocations.swift        # chatFolder: personalHome/.agents/chat
├── AgentsKit/Daemon/Daemon.swift                   # call ensureChatProject() after reconcileHome()
├── AgentsKit/Daemon/DaemonCore+ChatProject.swift   # new: ensureChatProject(), chatProjectState
├── AgentsKit/Daemon/DaemonCore+Projects.swift      # stamp isChat in the list; AGENTS.md sentence on first layout
└── AgentsKit/Projects/DotAgents.swift              # routerContents(for:chat:) adds the shared-folder line

Packages/AgentsKit/Tests/AgentsKitTests/Integration/ChatProjectTests.swift   # new

App/Sources/
├── Commands/AgentsCommands.swift                   # File ▸ New Chat ⇧⌘N, New Chat on ▸ <server>
├── Projects/…(the sidebar + menu)                  # New Chat item
└── AppModel.swift                                  # chatProject(on:) → showProject(key)

Remote/Sources/
├── Sidebar/RemoteSidebar.swift                     # toolbar New Chat (host menu when several)
└── RemoteModel.swift                               # chatProject(on:)

Web/src/
├── protocol/generated.ts                           # regenerated: isChat?
├── views/NewProject.tsx                            # New Chat in the + menu (host submenu when several)
├── model/projects (or store)                       # chatProject(host)
└── views/Changes.tsx                               # "This folder is not a Git repository." for unavailable

docs/ (6 pages, per the spec's Docs section)
specs/071-web-remote/walks/parity.md                # New Chat row; Changes not-a-repo row
```

**Structure Decision**: the existing layout. Daemon logic goes in one new `DaemonCore+ChatProject.swift` extension, beside the other `DaemonCore+*` files. Each client changes only where it already starts a session or adds a project.

## Phases

- **Phase 0**: [research.md](research.md). There were no NEEDS CLARIFICATION items left after Alex's answers. The research records the code decisions.
- **Phase 1**: [data-model.md](data-model.md), [contracts/projects-list.md](contracts/projects-list.md), [quickstart.md](quickstart.md).
- **Order for tasks**:
  1. Daemon and contract, with tests.
  2. Mac.
  3. Web: New Chat and the Changes state.
  4. Remote.
  5. Docs and parity.

  Each client step can land on its own once step 1 is in. Older clients are unaffected.

## Complexity Tracking

None.
