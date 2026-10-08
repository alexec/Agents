# Feature Specification: Chat with an agent in a project the app makes

**Feature Branch**: `agents/spec-229-chat-project`

**Created**: 2026-10-04 · **Rewritten**: 2026-10-06

**Status**: Draft

**Input**: Issue #229, "Chat with an agent without a project". This follows Alex's direction comment (2026-10-04): the app makes a **chat** project at `~/.agents/chat`, so chats are ordinary agents in a project the app made itself. It also follows Alex's answers of 2026-10-06:

- **No per-chat folder.** Every chat works directly in `~/.agents/chat`.
- **Every host** (this Mac and each server) makes its own chat project.

This replaces the 2026-10-04 draft, which had a separate "Chats" entry, a folder per chat under `~/.agents/chats/<id>/` and a shared folder beside it.

## Why this feature exists

Everything in Agents starts from a project. Alex also wants to **just chat with an agent**: ask something, maybe have it write a file, and not pick or create a project first.

The smallest way to get there is to keep the model as it is. A chat is an ordinary agent in an ordinary project, **chat**, which the app makes for the person at `~/.agents/chat`. That folder is the chats' shared folder: what one chat saves there, a later chat can read.

How the code stands today (paths under `Packages/AgentsKit/Sources/`):

- **Any folder an agent starts in becomes a project.** `layOutOnce` (`AgentsKit/Daemon/DaemonCore+Projects.swift:298`) writes the `projects.json` record and lays out `.agents/` and `AGENTS.md` in the folder. Making the chat project is one call to it at daemon start.
- **The person's home is known per root.** `StoreLocations.personalHome` (`AgentsKitCore/Store/StoreLocations.swift:61`) is `AGENTS_PERSONAL_HOME` when set, the real home for the standard root, and **none** for any other root. So a scratch root (run-app, tests) never reaches the real `~/.agents/chat` unless it names a home of its own.
- **`~/.agents/chat` is layable.** `DotAgents.isLayable` (`AgentsKit/Projects/DotAgents.swift:109`) refuses only `/`, the home folder and its ancestors.
- **Worktree choices already hide for a folder that isn't a repository.**
  - Mac: `App/Sources/Chat/PromptBar.swift:302`.
  - Remote: `Remote/Sources/StartAgent/ChoiceRows.swift:16`.
  - Web: `Web/src/views/NewAgent.tsx:252`.
- **Clicking a project row opens its new-session form** (#366, `4437e1cb`). Clicking the chat project's row is therefore already a New chat. This feature adds a direct way in that doesn't need the row found first.
- **Projects are ordered by when they were added** (#357). A chat project made today would sort after every existing project.
- **Additional folders on a first turn** were fixed by #230 (`afb43eb8`). Chats don't need them now: the shared folder *is* their working folder.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Start a chat without picking a project (Priority: P1)

Alex opens the Mac window and chooses **New Chat** (File menu or its key). The prompt bar opens on the chat project. Alex types "summarise this PDF and draft a reply", attaches the PDF and sends. The agent works in `~/.agents/chat`, writes `reply.md` there, and Alex reads it in the Files pane.

**Why this priority**: This is the whole idea of the issue.

**Independent Test**:
- On a scratch root with `AGENTS_PERSONAL_HOME` set to a scratch home, start the daemon.
- Check that `<home>/.agents/chat` exists and is a project named **chat**.
- Choose New Chat, send, and check that the agent's folder is `<home>/.agents/chat`.
- Check that a file it writes shows in the Files pane.

**Acceptance Scenarios**:

1. **Given** a host's daemon starts with a personal home, **when** `~/.agents/chat` is missing, **then** the daemon makes the folder and lays it out as a project, like any project added by hand. It gets a `projects.json` record, a `.agents/` layout and an `AGENTS.md`.
2. **Given** the chat project already exists, **when** the daemon starts again, **then** nothing in it changes. Its files, `AGENTS.md`, workflows and settings are left alone.
3. **Given** the Mac window, **when** Alex chooses New Chat, **then** the new-session form opens on the chat project of this Mac, with runtime, model and mode chosen as for any start.
4. **Given** a chat, **then** it is an ordinary session of the chat project. Statuses, unread marks, labels, Park, Archive, retention, search, workflows, pins and helper limits all work as in any project.
5. **Given** a root with no personal home (a scratch root without `AGENTS_PERSONAL_HOME`), **then** no chat project is made, and New Chat isn't offered.

---

### User Story 2 - Keep a file for a later chat (Priority: P1)

In one chat Alex says "save the packing list somewhere I can find it next time". The agent writes `packing-list.md` into its folder. A week later, in a new chat, Alex says "update my packing list". The new chat finds the file in the same folder and edits it.

**Why this priority**: Without a place that outlives a chat, chats can't build on each other. The chat project's folder is that place.

**Independent Test**: Start chat A and have it write a file. Archive chat A, then retire it. Start chat B, read the file and change it.

**Acceptance Scenarios**:

1. **Given** chat A wrote a file into the chat project, **when** chat A is archived or retired, **then** the file is still there.
2. **Given** a new chat, **then** it starts in the same folder as every earlier chat on that host, and can read what they left.
3. **Given** the chat project's `AGENTS.md`, **then** it says, in a sentence the app writes once, that the folder is shared by every chat and is the place to save what should be kept. The person may change or delete that sentence, and the app does not put it back.

---

### User Story 3 - Find chats in the sidebar (Priority: P1)

Alex's chats sit in the one sidebar (#145) under the **chat** project, newest first, each named by its title. On a server, they sit under `host:chat`, as server projects read today.

**Why this priority**: Without this, chats can't be found again.

**Independent Test**: Start two chats on this Mac and one on the devbox server (test-servers skill). Check that the Mac, the Remote and the web page each show the two under **chat** and the one under that server's **chat**.

**Acceptance Scenarios**:

1. **Given** chats on a host, **then** every client lists them under that host's chat project, like any project's sessions.
2. **Given** the sidebar order by date added (#357), **then** the chat project takes its place like any project. It gets no special position.
3. **Given** the person archives the chat project, **then** the daemon does not make it again or unarchive it at its next start. New Chat then says the chat project is archived and offers to unarchive it.

---

### User Story 4 - Chat on a server, from the phone and the web page (Priority: P2)

On the iPhone, Alex taps **New Chat**, picks the Linux server, and asks something that needs its CPU. The chat runs in the server's own `~/.agents/chat`. On the web page, the same choice is the same two steps.

**Why this priority**: #233 requires all three clients. Servers come almost for free, because each host's daemon makes its own chat project at start.

**Independent Test**: From each of the three clients, start a chat on this Mac and one on the devbox server. Check which folder each runs in, and where each is listed.

**Acceptance Scenarios**:

1. **Given** New Chat on any client, **then** it starts on this Mac by default. When there are servers, the person can pick another host.
2. **Given** a chat on a server, **then** it runs in that server's `~/.agents/chat`. Files are not copied between hosts. Each host's chat project is its own.
3. **Given** the Remote, **then** New Chat is on the projects list (the top level), so the chat project's row doesn't have to be found first.
4. **Given** the web page, **then** New Chat is in the sidebar and opens the new-session form on the chat project.
5. **Given** a client too old to know New Chat, **then** the chat project still shows as an ordinary project, and a chat can be started from its row.

---

### User Story 5 - No git where there is no repository (Priority: P2)

`~/.agents/chat` isn't a git repository. A chat's page shows no worktree choice, branch, Changes or diff controls that would fail there. If any are shown, they say plainly that the folder isn't a repository, rather than showing an error.

**Why this priority**: The chat project is the first project every person has that is not a repository. Every git-only part of the window will meet it.

**Independent Test**: Open a chat on each client. Look at the new-session form, the session's page, the Files and Changes panes, and the finish_turn `worktree:` argument. Check that none shows an error.

**Acceptance Scenarios**:

1. **Given** the new-session form on the chat project, **then** it offers no worktree choice. Today's `isRepository` checks already do this.
2. **Given** a chat's Changes pane (or its equivalent on each client), **then** it is hidden or shows a one-line "Not a git repository" state, never an error.
3. **Given** a chat asks to move into a worktree (finish_turn `worktree:`), **then** it is refused with a sentence saying the folder isn't a git repository.
4. **Given** the person runs `git init` in `~/.agents/chat`, **then** the chat project behaves as any repository project from then on. Nothing in the app stops it.

### Edge Cases

- **The person deletes `~/.agents/chat`**: it is an ordinary project folder that is gone, so #119's missing-folder handling applies to live chats. At its next start, the daemon makes the folder again and lays it out (User Story 1, scenario 1). A record that is there but archived counts as there (User Story 3, scenario 3).
- **`~/.agents/chat` exists but is a file or an unreadable folder**: the daemon logs a sentence and makes no chat project. New Chat says why, and nothing else at start is held up.
- **The person has a project at `~/.agents/chat` already, made by hand**: it is used as the chat project as it is. Nothing is laid out twice (`layOutOnce` is once per step).
- **Two chats write the same file at once**: last write wins, as with any two agents in one project.
- **The folder grows**: nothing deletes chat files. The size is the person's to manage, as in any project. Retention removes conversations, not project files.
- **Sandboxes (064)**: a chat writes inside its own working folder, so the sandboxes allow it as they do for any project.
- **A chat starts a helper** (`start_agent`): the helper is another session in the chat project, under the project's helper limits (#64).
- **The home `~/.agents` folder**: it holds the person's AGENTS.md, skills, personas and plugins. The chat project is a child folder of it, and its own `.agents/` is the chat project's, not the person's. Reconciling the personal folder must not treat `chat/` as one of its own entries, or remove it.
- **Renaming**: the project is named after its folder, **chat**. Renaming or moving the folder by hand makes it an ordinary project somewhere else. The next daemon start then makes a new `~/.agents/chat`.

## Requirements *(mandatory)*

### Functional Requirements

**Making the chat project**

- **FR-001**: At start, each host's daemon MUST work out the chat folder as `<personal home>/.agents/chat`. It MUST make the folder if missing, and lay it out once as a project, through the same path as any project.
- **FR-002**: The daemon MUST NOT make a chat project when its root has no personal home. Scratch roots and tests then never touch the real `~/.agents/chat`.
- **FR-003**: The daemon MUST NOT make the chat project again, unarchive it, or change its files, when a record of it already exists, archived or not.
- **FR-004**: When the chat project is laid out the first time, its `AGENTS.md` MUST say, in one sentence, that this folder is shared by every chat on this host and is the place to save what a later chat should find.
- **FR-005**: Making the chat project MUST NOT delay the daemon's start beyond a folder check. A failure to make it MUST be logged and MUST NOT stop the daemon.
- **FR-006**: Every host's daemon (Mac and Linux) MUST do FR-001 to FR-005. A server's daemon has no personal home (054 research R8), so it MUST use its account's `$HOME` as the home for the chat project, and for nothing else of `~/.agents` (Alex, 2026-10-07).

**Starting a chat**

- **FR-007**: The Mac window MUST offer New Chat in the File menu, with a keyboard shortcut, and in the sidebar's New menu. It opens the new-session form on the chat project of the chosen host, this Mac by default.
- **FR-008**: The Remote MUST offer New Chat on its projects list, with a host choice when there are several hosts.
- **FR-009**: The web page MUST offer New Chat in its sidebar, with a host choice when there are several hosts.
- **FR-010**: Each client MUST find the chat project from what the host reports, not by building a path itself. The host's project list MUST mark which project is its chat project.
- **FR-011**: When a host has no chat project (no personal home, archived, or failed to make), New Chat MUST say which of these it is. For an archived one, it MUST offer to unarchive.

**Not a repository**

- **FR-012**: Every place a client shows git-only controls for a session or project (worktree choice, branch, Changes, diff) MUST hide them, or show a one-line "Not a git repository" state, for a folder that isn't a repository. It MUST NOT show an error.
- **FR-013**: finish_turn's `worktree:` and any other worktree request MUST be refused with a sentence when the project isn't a repository.

**Compatibility**

- **FR-014**: Existing projects and agents MUST be unaffected. A client that doesn't know the chat-project mark MUST show it as an ordinary project.

### Key Entities

- **Chat project**: an ordinary project at `<personal home>/.agents/chat` on each host, made by that host's daemon. Its folder is the working folder of every chat, and so their shared folder. The host's project list marks it as the chat project.
- **Chat**: an ordinary session of the chat project. It has no new kind or mark of its own.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A chat can be started from each of the three clients in at most two actions before typing (New Chat, then send), with no folder to choose.
- **SC-002**: After 50 chats on one host, the sidebar holds exactly one chat project for that host and no new project rows.
- **SC-003**: A file written by one chat is readable and writable by a chat started a week later on the same host, after the first has been retired.
- **SC-004**: A scratch root with no personal home makes no folder under the real `~/.agents` in a full run-app walk.
- **SC-005**: Opening a chat on each client shows no git error anywhere on its pages.

## Docs *(mandatory)*

- `docs/how-to/chat-without-a-project.md`, new: start a chat on each client, where its files go, keeping a file for a later chat, chats on a server.
- `docs/explanation/projects-hosts-worktrees.md`, change: the chat project, one per host, made by the app; a project need not be a repository.
- `docs/how-to/add-a-project.md`, change: the chat project is already there, and archiving it is honoured.
- `docs/how-to/start-in-a-worktree.md`, change: not offered in a folder that isn't a repository, the chat project included.
- `docs/reference/keyboard-shortcuts.md`, change: New Chat.
- `docs/how-to/use-agents-in-a-browser.md`, change: New Chat on the web page.

## Assumptions

- **No per-chat folder** (Alex, 2026-10-06). Every chat works directly in `~/.agents/chat`. Nothing in the chat project is deleted by the app. Retention removes conversations, as everywhere.
- **One chat project per host** (Alex, 2026-10-06), each in that host's own personal home. On a server, which has none, it is the server account's home, for the chat project alone (Alex, 2026-10-07, after the server walk found servers made none).
- **The folder is `chat`, singular**, as in Alex's direction comment.
- **Nothing chat-specific in the session model.** A chat is a session of a project the app made, so labels, unread, retention, workflows, pins and helper limits need no new rules. The only new state is the host's "this is the chat project" mark (FR-010).
- **Where it sits in the sidebar**: like any project, by date added (#357). If Alex later wants it pinned first, that is a small follow-up.
- **The shared folder is not memory.** `specs/research/shared-memories.md` (#51) stays separate.
- **Each client's change is in this spec** (#233). Mac, Remote and web all get New Chat and the not-a-repository states. The plan updates `specs/071-web-remote/walks/parity.md` with a New Chat row.
