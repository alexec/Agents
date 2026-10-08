# Research: chat project (#229)

Paths under `Packages/AgentsKit/Sources/` unless they start with a client folder.

## R1. Where the daemon makes the chat project

- **Decision**: A new `DaemonCore.ensureChatProject()`, called from `Daemon.start()` right after `core.reconcileHome()` (`AgentsKit/Daemon/Daemon.swift:145`) and before `core.recover()`.
- **Rationale**:
  - `reconcileHome()` is already the startup step that touches the personal home, and returns at once when there is none (`DaemonCore+PersonalLayout.swift:12-13`).
  - Running before `recover()` means the project exists before any client lists projects.
  - It is synchronous file work: a `stat`, at most a `createDirectory` and `layOutOnce`.
- **Alternatives considered**:
  - At first New Chat, lazily. Rejected: the direction comment wants it there at start, and a client then could not know where to send New Chat without a round trip.
  - In the window. Rejected: servers have no window, and FR-006 wants every host.

## R2. When to do nothing

- **Decision**: Skip when any of these holds.
  - `locations.personalHome == nil`.
  - `projectRecords()` already has a record for the standardised folder, archived or not.
  - The path exists and is not a directory.
- **Rationale**:
  - `StoreLocations.personalHome(root:environment:)` (`AgentsKitCore/Store/StoreLocations.swift:61`) is nil for any non-standard root unless `AGENTS_PERSONAL_HOME` is set. That covers run-app and tests (FR-002).
  - A record means the person has seen it. Archiving is honoured (FR-003), and `Project.archivedAt` is the existing mark (`AgentsKitCore/Model/Project.swift:15`).
  - A record that exists while the folder is gone is #119's missing-folder state. Recreating the folder there is still safe and matches the spec's edge case. So for an *unarchived* record with no folder, the daemon makes the folder only, with no layout. A record exists, so `layOutOnce` would be a no-op anyway.
- **Alternatives considered**: a `projects.json` flag "chat project made once". Rejected: the record's presence says the same thing without a new field.

## R3. How clients find it

- **Decision**: Add `isChat: Bool` to `DaemonAPI.ProjectSummary` (`AgentsKitCore/Daemon/DaemonAPI.swift:565`).
  - It is encoded only when true, and decoded with `decodeIfPresent ?? false`.
  - The daemon stamps it where it builds summaries: the one project whose standardised folder equals the chat folder.
- **Rationale**:
  - The summary already has a hand-written `init(from:)` that tolerates new keys, so older Remotes ignore the field (FR-014).
  - The web types are generated from AgentsKitCore by `scripts/web.sh types`.
  - Clients never build `~/.agents/chat` themselves (FR-010), so a server whose home differs still works.
- **Alternatives considered**:
  - Put it on `Project` and in `projects.json`. Rejected: it is derived from the host's home, not the person's record.
  - Add a separate `projects/chat` command. Rejected: it is one more round trip, and the list is already pushed to every client.

## R4. The AGENTS.md sentence

- **Decision**: `DotAgents.routerContents(for:)` (`AgentsKit/Projects/DotAgents.swift:150`) gains a `chat: Bool` parameter.
  - When true, it adds a section before Context routing: "This folder is shared by every chat on this host. Save here what a later chat should find."
  - `ensureChatProject` lays out through a `layOutOnce(_:chat:)` overload, so only the first layout writes it (FR-004). Later layouts never rewrite `AGENTS.md`, because `apply` writes the router only `from == 0` and only if absent.
- **Alternatives considered**: put the sentence in the briefing for sessions in the chat project. Rejected: the spec wants it in the person's own file, which they can edit.

## R5. The personal-home reconcile and `chat/`

- **Finding**: `PersonalDotAgents` only lists the named subfolders it owns, such as skills, personas and plugins (`PersonalDotAgents.swift:235,273,350,371,383`). It never enumerates `~/.agents` itself, so a `chat/` folder is untouched.
- **Decision**: add a test that a reconcile with `chat/` present leaves it, and its `.agents/`, alone.
- **Finding**: `DotAgents.isLayable` allows `~/.agents/chat`, because it refuses only `/` and the home folder's ancestors (`DotAgents.swift:109`).
- **Watch**: `~/.agents/chat/.agents/skills` is the chat project's own folder, not a personal-skills link. The Gemini and Codex plugin passes key off `~/.agents/plugins` by path, so they don't mistake it.

## R6. Not a repository: what already works

| Place | Today | Change |
|---|---|---|
| New-session worktree choice | Hidden when `!isRepository`: `App/Sources/Chat/PromptBar.swift:302`, `Remote/Sources/StartAgent/ChoiceRows.swift:16`, `Web/src/views/NewAgent.tsx:252` | none |
| File ▸ New Session in a Worktree | Disabled unless `draftWorktrees.canMakeNew` (`App/Sources/Commands/AgentsCommands.swift:64`) | none |
| Changes pane, Mac | "this folder isn't tracked by git" (`App/Sources/Sidebar/ChangesPane.swift:269`) | none |
| Changes pane, Remote | "This folder is not a Git repository." (`Remote/Sources/Panes/RemoteChangesPane.swift:116`) | none |
| Changes, web | `GitView.unavailable` is only used to turn the diff choice off (`Web/src/model/diff.ts:56`); no state line | add the line, worded as the Remote's |
| Worktree list | `.notARepository` (`DaemonCore+Worktrees.swift:229`) | none |
| Move into a worktree (finish_turn `worktree:`) | Refused: "Moving needs a git repository, and … is not in one." (`DaemonCore+Moves.swift:66-68`) | none (FR-013 met). Add a test for the chat project |

## R7. Where New Chat goes on each client

- **Mac**:
  - `CommandGroup(replacing: .newItem)` (`App/Sources/Commands/AgentsCommands.swift:58`) gets **New Chat**, ⇧⌘N (free today: ⌘N is New Session, ⌥⌘N is New Session in a Worktree).
  - When any server lists a chat project, it also gets **New Chat on ▸** with one item per host.
  - The action is `model.showProject(chatKey)` (`App/Sources/AppModel.swift:337`), which opens the new-session form (#366; still so after #375, where the New session row calls it).
  - The sidebar's + menu gets the same item.
- **Remote**:
  - A New Chat toolbar button on `RemoteSidebar` (`Remote/Sources/Sidebar/RemoteSidebar.swift`). It is a menu of hosts when more than one lists a chat project.
  - It routes to `RemoteRoute.start` for that project, as the project's New session row does (#375, parity row).
- **Web**:
  - **New Chat** at the top of the + menu (`Web/src/views/NewProject.tsx:72`, `NewProjectItems`), with one item per host when several.
  - It goes to `go({ host, project: folder, n: 1 })`, as a project row click does.
- **Not available**: when no host lists a chat project, New Chat stays visible on all three but disabled, with the reason as its help text (FR-011). The client asks the new `projects/chatState` for the reason: `noPersonalHome`, `archived` or `failed(message)`. It is a separate call because `projects/list` is a bare array (`DaemonCore+Dispatch.swift:185`), which a wrapper would break for older clients. For `archived`, the item is enabled and offers Unarchive (existing `projects/unarchive`).

## R9. A server's chat home (found in the server walk, 2026-10-07)

- **Finding**: a server's daemon runs on `~/.agents-server/root` with `--serve`, and `StoreLocations.personalHome` is nil for every root but the Mac's standard one. 054 left servers' personal `~/.agents` for later (054 research R8). So the walk's server answered `noPersonalHome` and made no chat project.
- **Decision** (Alex): a `--serve` daemon with no personal home takes its account's `$HOME` (`ServerSignIn.home`, the server's shell's) as the chat home only: `DaemonCore.serverChatHome`, set in `Daemon.start` before `ensureChatProject`. 054's reconcile stays off on servers.
- **Why it is safe**: only the install script starts `--serve` (`HostInstallScript.swift`); no test does; the fake ssh sets `HOME` to its own folder.
- **Alternatives considered**: a full personal home on servers (054's whole reconcile on the server account's runtime folders); this Mac only.

## R8. Testing set-up

- Daemon tests sit in `Packages/AgentsKit/Tests/AgentsKitTests/Integration/` beside `ProjectsTests.swift`, with a temp root and `AGENTS_PERSONAL_HOME`, or by passing a `StoreLocations` with `personalHome` set.
- run-app does not set `AGENTS_PERSONAL_HOME` today, so a scratch root makes no chat project. The quickstart sets it to a scratch home for the walk. It never uses the real home (memory: never copy real agent records).
