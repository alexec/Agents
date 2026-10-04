# Feature Specification: Chat with an agent without a project

**Feature Branch**: `agents/build-free-spec-work`

**Created**: 2026-10-04

**Status**: Draft

**Input**: Issue #229, "Chat with an agent without a project: a temporary folder per chat plus a shared folder across chats" (Alex, 2026-10-04). The issue's five open questions are answered here with a recommended default each. They are repeated under [Open questions](#open-questions-for-alex) for Alex to confirm or change.

## Why this feature exists

Everything in Agents starts from a project. An agent gets a project folder, and the folder is the agent's home: its sidebar group, its workflows, its dashboard, its limits. Alex also wants to **just chat with an agent**: ask something, have it write a file or two, and not pick or create a project first.

A chat still needs a folder, since every runtime works in one. It gets two:

- **Its own folder**, made for it, its working folder for the whole chat. It is thrown away some time after the chat is over.
- **One shared folder**, the same for every chat. A chat can save a file there and a later chat can read it, so something worth keeping outlives the chat that made it.

How the code stands today (paths under `Packages/AgentsKit/Sources/`):

- **Every folder an agent runs in becomes a project.** An agent's project is `worktree?.project ?? cwd` (`AgentsKitCore/Model/Agent.swift:230`). The project list is derived from every agent's project folder plus `projects.json` and the retirement tombstones (`AgentsKit/Daemon/DaemonCore+Projects.swift:28`). A fresh start also runs `layOutOnce(cwd)` (`DaemonCore+Commands.swift:422`), which writes a `projects.json` record and lays out `.agents/` and `AGENTS.md` in the folder (`DaemonCore+Projects.swift:242`, `DotAgents.swift:79`). It refuses only `/`, the home folder and its ancestors (`DotAgents.isLayable`, `:109`). So a chat in `/tmp/x` or `~/.agents/chats/<id>` would today appear as a new project named after a random folder, with an `AGENTS.md` written into it.
- **A second folder is mostly supported.** `additionalDirectories` is on `StartRequest` and `Agent` (`AgentsKitCore/Daemon/DaemonAPI.swift:729`, `Agent.swift:81`). It is sent to runtimes that advertise the capability (`AgentsKit/ACP/ACPSession.swift:405`), and the app's own `FolderScope` includes it, so file tools, serving and terminals allow it (`Agent.swift:232`, `FolderScope.swift:19`). **But** a brand-new start leaves it out of the first session (`freshSession`, `DaemonCore+Commands.swift:448`). Only resumes pass it (`DaemonCore+Runtimes.swift:182,200`).
- **Nothing ever deletes an agent's plain folder.** `removeWorktreeIfDone` (`DaemonCore+Worktrees.swift:318`) removes only clean, app-made git worktrees, on archive (`DaemonCore+Commands.swift:1869`) and on retire (`DaemonCore+Retention.swift:406`). Retire runs on archived agents after the retention period, 30 days by default, or sooner under the size cap (2 GB by default; `AgentsKitCore/Model/RetentionSettings.swift:10`).
- **A gone folder is a known state.** `DaemonCore+MissingFolders.swift` (#119) refuses sends to an agent whose folder is gone and offers "continue in project", which means nothing for a chat.
- **Sandboxes (064) are on/off with no list of writable folders.** With a sandbox on, Claude and Codex were measured refusing writes outside the project (`specs/064-control-runtime-sandboxes/research.md` R9). Nobody has measured whether each runtime's sandbox allows writes into its `additionalDirectories`.
- **Starting.**
  - The Mac starts from the prompt bar. The folder defaults to the selected project, and other folders come from a chooser (`App/Sources/Chat/PromptBar.swift:1118,1297`).
  - The Remote starts only from a project page (`Remote/Sources/StartAgent/StartAgentView.swift:14`, opened from `Projects/ProjectPageView.swift:61`).
  - The web page starts from a project page too (`Web/src/views/NewAgent.tsx:42`).
  - None of them has a way to start without a project.
- **The one sidebar (#145)** lists Activity, then this Mac's projects, then each server's, on the Mac (`App/Sources/Projects/ProjectListView.swift`) and on the web page (`Web/src/views/Sidebar.tsx`, grouped by `projectFolder` in `Web/src/model/groups.ts:111`). The Remote adds host headings when there are several hosts (`Remote/Sources/RemoteModel.swift:232`).
- **Hosts (058)**: a project has no host field. It belongs to the host whose daemon holds it, and clients key projects by host and folder (`AgentsKitCore/Hosts/Host.swift:333`).
- **The home `.agents` folder** (`AgentsKit/Projects/PersonalDotAgents.swift`) holds AGENTS.md, skills, personas and plugins, and is reconciled before every session. Nothing chat-like or scratch-like exists anywhere yet.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Start a chat with no project (Priority: P1)

Alex opens the Mac window, chooses **New Chat**, types "summarise this PDF and draft a reply", attaches the PDF, and sends. No project is picked or created. The agent works in a folder made for this chat, writes `reply.md` there, and Alex reads it in the Files pane.

**Why this priority**: This is the whole idea of the issue. Without it nothing else here matters.

**Independent Test**:
- On a scratch root, start a chat from the Mac.
- Check that the agent's working folder is a new, empty folder under the chats folder (FR-002).
- Check that no project row appeared, and that no `projects.json` record, `.agents/` layout or `AGENTS.md` was written for it.
- Check that a file the agent writes shows in the Files pane.

**Acceptance Scenarios**:

1. **Given** the Mac window, **when** Alex chooses New Chat (sidebar, File menu or its key) and sends a first message, **then** a chat starts on this Mac, in a folder made for it, with the runtime and model chosen the same way as for any start.
2. **Given** a chat has started, **then** no project for its folder appears in the sidebar, the project list, `projects.json` or the Events page's project filter.
3. **Given** a chat has started, **then** its folder holds no `.agents/` layout and no `AGENTS.md` written by the app. The agent still gets the person's own instructions, skills and personas from `~/.agents`, as every agent does.
4. **Given** a chat, **when** the agent writes a file into its folder, **then** the Files pane, a live document and the HTML page (#67) show it as they would in a project.
5. **Given** the Remote or the web page, **when** Alex chooses New Chat, **then** the same happens, on the host Alex picks (User Story 5).

---

### User Story 2 - Keep a file across chats in the shared folder (Priority: P1)

In one chat Alex says "save the packing list somewhere I can find it next time". The agent writes `packing-list.md` into the shared folder. A week later, in a new chat, Alex says "update my packing list". The agent finds it in the shared folder and edits it.

**Why this priority**: Without a place that outlives a chat, a throwaway chat can't build on anything. The issue makes this half of the idea.

**Independent Test**:
- Start chat A and have it write a file into the shared folder.
- Archive chat A, then retire it.
- Start chat B, read the file and change it.
- Repeat with one runtime that advertises additional folders and one that doesn't.

**Acceptance Scenarios**:

1. **Given** a new chat, **then** it is given the shared folder as a second folder from its very first turn, not only after a resume (FR-006).
2. **Given** a runtime that advertises additional folders, **then** the shared folder is passed that way.
3. **Given** a runtime that doesn't advertise additional folders, **then** the chat's opening instructions name the shared folder's path and say what it is for.
4. **Given** a runtime whose sandbox is on, **when** the agent writes into the shared folder, **then** either the write succeeds, or the chat was told when it started that its sandbox keeps the shared folder read-only. A write is never refused without the agent having been told why (FR-008).
5. **Given** chat A wrote a file to the shared folder, **when** chat A is archived and retired, **then** the file is still there.
6. **Given** the app's own file tools (the Files pane, `show_file`, serving), **then** they allow the shared folder for every chat, as `FolderScope` already does for additional folders.

---

### User Story 3 - Find chats in one place, not one project each (Priority: P1)

Alex has had a dozen chats this week. In the sidebar they sit together under one **Chats** entry, newest first, each named by its title like any session. They are not a dozen rows of random folder names.

**Why this priority**: Without this, each chat becomes a project row named after a random folder (see "How the code stands today"). The sidebar would fill with noise on the first day.

**Independent Test**:
- Start three chats on this Mac and one on a server.
- Check that the Mac and the web page each show one Chats entry for this Mac, holding three sessions.
- Check that the server's chat sits under that server's Chats entry.
- Check that the Remote shows the same under its host headings.

**Acceptance Scenarios**:

1. **Given** chats on a host, **then** the sidebar shows one **Chats** entry for that host, placed after Activity and before the projects. On the Mac and the web page it reads `Chats` for this Mac and `host:Chats` for a server, as server projects read `host:Project` today. On the Remote it sits under the host's heading.
2. **Given** no chats on a host, **then** no Chats entry shows for it. The New Chat command is still there.
3. **Given** the Chats entry, **then** it behaves like a project's session list: statuses, unread marks (#70), labels, Park, Archive, Archived folds and search all work as they do for a project.
4. **Given** the Chats entry is selected, **then** its page has no Workflows, Dashboard, Pins, Move or worktree controls (FR-016).
5. **Given** list_sessions or read_session from inside a chat, **then** they list and read the other chats on the same host, as an agent in a project sees its project's sessions.

---

### User Story 4 - A chat's folder is cleaned up after the chat (Priority: P2)

Alex archives a chat. It can still be unarchived and carried on, files and all, for as long as archived sessions are kept. When the chat is retired, with its conversation, its folder is deleted too. Nothing a chat made stays on disk for ever, except what went into the shared folder.

**Why this priority**: The folders must stay bounded (the robustness priority). It is P2 only because nobody notices the leak in the first week.

**Independent Test**:
- Start a chat, write a 10 MB file, and archive it. The folder is still there.
- Unarchive it, send, and check that it carries on with its file.
- Archive it again and retire it, by Retire now or by moving the clock past retention. The folder is gone, and the shared folder is untouched.
- Kill the daemon mid-chat, delete the chat's record by hand on a scratch root, and restart. The orphaned folder is removed by the next sweep (FR-013).

**Acceptance Scenarios**:

1. **Given** a chat is archived, **then** its folder is kept, so that unarchive works.
2. **Given** an archived chat is retired (by age, by the size cap or by the person), **then** its folder is deleted with its conversation. The tombstone does not keep a project row alive, because a chat has none.
3. **Given** the retention size cap, **then** a chat's folder counts towards it, together with its conversation, so a chat full of large files is retired sooner and not kept beyond the cap.
4. **Given** a chat folder with no live, parked or archived chat behind it (a crash, a lost record), **then** a daily sweep removes it once it is older than a day.
5. **Given** the app deletes a chat's folder, **then** it deletes only a folder it made inside the chats folder, never a path outside it, and never one the chat was "kept as a project" from (User Story 6).
6. **Given** a live or parked chat whose folder was deleted by someone else, **then** the next send makes a fresh empty folder and the chat is told its earlier files are gone. A chat never gets #119's "continue in project".

---

### User Story 5 - Chat on a server, and from the phone and the web page (Priority: P2)

On the iPhone, Alex taps **New Chat**, picks the Linux server as the host, and asks a question that needs a lot of CPU. The chat's folder and shared folder are on that server. On the web page, the same choice is the same two fields.

**Why this priority**: The #233 rule requires all three clients. Servers come along almost for free, because a chat lives on whichever host holds it, like a project.

**Independent Test**:
- From each of the three clients, start a chat on this Mac and one on the devbox server (test-servers skill).
- Check where each chat's folders are.
- Check that each chat shows under the right host's Chats entry on all three clients.

**Acceptance Scenarios**:

1. **Given** New Chat on any client, **then** it starts on this Mac by default. When the person has servers, a host picker lets them choose one.
2. **Given** a chat on a server, **then** its own folder and the shared folder are on that server. Each host has its own shared folder. Files are not copied between hosts.
3. **Given** the Remote, **then** New Chat is on the projects list (the top level), not only on a project page, because a chat has no project.
4. **Given** the web page, **then** New Chat is in the sidebar and opens the new-agent form without the project, worktree and folders fields.
5. **Given** an older Remote that doesn't know about chats, **then** it shows a host's chats as a project named `Chats` and carries on working: sends, answers and stops still work.

---

### User Story 6 - Keep a chat as a project (Priority: P3)

A chat turned into real work: the agent has written a small script and a README. Alex chooses **Keep as Project…** and picks where the folder should go. The chat's folder moves there and becomes a project, and the chat carries on inside it as an ordinary session of that project.

**Why this priority**: It is useful, but chats work without it. It also depends on #61's move machinery.

**Independent Test**: Keep a chat as a project into a scratch folder. Check that the project appears with the chat as its session, that the chats folder no longer holds it, and that retiring the session later does not delete the new project folder.

**Acceptance Scenarios**:

1. **Given** a chat, **when** Alex chooses Keep as Project and a destination, **then** the folder is moved there, the destination becomes a project, and the session is moved into it.
2. **Given** a kept chat, **then** the app never deletes its folder again. It is a project folder now.
3. **Given** the destination already exists and isn't empty, **then** the move is refused with a sentence, and nothing changes.
4. **Given** a chat that is running, **then** Keep as Project is offered only once its turn has ended.

### Edge Cases

- **A chat starts a helper** (`start_agent`): the helper is a chat too, in the same Chats entry. It works in the parent's folder, and its own folder is not made. The folder is deleted only when the parent and every helper sharing it have been retired. Helper limits (#64) for a host's chats use the defaults, since chats have no `.agents/project.json`.
- **A chat asks to move into a worktree** (finish_turn `worktree:`): refused with a sentence. A chat's folder is not a git repository.
- **Workflows**: none live in Chats. A project's workflow can't target a chat. A wait from inside a chat hears the host's chat events, the same way a project agent hears its project's (`DaemonCore+EventWaits.swift`).
- **Two chats write the same shared file at once**: last write wins, as with any two agents in one project. The app adds no locking.
- **The person deletes the shared folder**: it is made again, empty, at the next chat start.
- **A runtime whose sandbox can't be told about extra folders** (Cursor, Copilot, the runtime-controlled ones in `SandboxCatalog.swift`): the chat is told at its start that the shared folder may be read-only for it (FR-008).
- **A chat with an attachment**: the attachment is written into the chat's own folder, as it is into the project folder today.
- **Unarchiving a chat whose folder was already retired**: impossible, because retiring deletes the conversation too.
- **Moving a chat to another machine (#61)**: not offered for chats in this spec.
- **Disk space (`mac.disk_low`)**: the chats folder counts as a volume holding the Agents root, so it is already covered by the disk checks.
- **Labels**: chats on one host share one label vocabulary, as a project's sessions do.
- **The home folder rule**: the chats folder sits inside the person's `~/.agents`. The app must never lay it out as a project (no `AGENTS.md` or `.agents/` written into a chat folder), whatever `DotAgents.isLayable` says about the path.

## Requirements *(mandatory)*

### Functional Requirements

**Folders**

- **FR-001**: A start MUST be able to say it is a **chat**, with no folder given. Each client's New Chat sends this.
- **FR-002**: For a chat, the host's daemon MUST make the chat's own folder at `~/.agents/chats/<agent-id>/`. That folder MUST be the chat's working folder.
- **FR-003**: The daemon MUST make sure `~/.agents/chats/shared/` exists, and give it to every chat as an additional folder.
- **FR-004**: The daemon MUST record on the agent that it is a chat, and that it made the chat's folder. Cleanup keys off that record, never off the path's shape alone.
- **FR-005**: A chat's folder MUST NOT be laid out (no `projects.json` record, no `.agents/` layout, no `AGENTS.md`), and MUST NOT appear as a project anywhere a project list is derived from agents' folders.
- **FR-006**: Every new session MUST send its additional folders on its very first turn, whenever the runtime advertises the capability. This fixes today's gap in `freshSession` for every agent, not only chats, and SHOULD land first, on its own.
- **FR-007**: When the runtime doesn't advertise additional folders, the chat's opening instructions MUST name the shared folder's path and say it is for files worth keeping across chats.
- **FR-008**: For each runtime with a sandbox on, the plan MUST measure whether writes to an additional folder are allowed. Where they are not, and the app can't widen the sandbox for that runtime, the chat's opening instructions MUST say the shared folder may be read-only. The runtime catalogue MUST record the answer per runtime.

**Starting and listing**

- **FR-009**: The Mac window MUST offer New Chat in the sidebar, the File menu and a keyboard shortcut. It opens the prompt bar with no project and no folder chooser, and a host picker when there are servers.
- **FR-010**: The Remote MUST offer New Chat on its projects list, with a host picker when there are several hosts.
- **FR-011**: The web page MUST offer New Chat in its sidebar, with a host picker when there are several hosts. Its form MUST leave out the project, worktree and extra-folders fields.
- **FR-012**: All three clients MUST show one **Chats** entry per host that has chats, after Activity and before the projects, holding those chats as sessions (User Story 3). The project-only parts of a project page (FR-016) MUST be absent from it.

**Cleanup and bounds**

- **FR-013**: When a chat is retired, the daemon MUST delete its folder, unless another unretired chat shares it (Edge Cases, helpers) or the chat was kept as a project. Archive MUST NOT delete it.
- **FR-014**: A chat's folder size MUST count towards the retention size cap, with its conversation.
- **FR-015**: A sweep, at daemon start and then daily, MUST remove any folder under `~/.agents/chats/` other than `shared/` that is older than a day and belongs to no chat record. It MUST NOT follow symlinks out of the chats folder.
- **FR-016**: For a chat, the daemon MUST refuse workflows, the dashboard, pins, worktrees, Move between machines and "continue in project", each with a sentence saying chats don't have it.
- **FR-017**: A chat whose folder is gone MUST get a fresh empty folder on its next send, and be told its earlier files are gone, instead of #119's missing-folder refusal.
- **FR-018**: The shared folder's size MUST be shown with the retention settings, with an **Open** command and a **Clear** command, and the app MUST raise a warning (a strip and an event) when the shared folder grows past a limit, 1 GB by default. The app MUST NOT delete files from the shared folder by itself (see Open questions, Q3).

**Keep as project (P3)**

- **FR-019**: Keep as Project MUST move the chat's folder to a destination the person picks, record it as a project, and move the session into it. Afterwards the folder MUST no longer be the app's to delete.

**Compatibility**

- **FR-020**: A client that doesn't know about chats MUST still be able to show a host's chats (User Story 5, scenario 5). The listing MUST carry the chats under a project-shaped group so older readers don't drop them.
- **FR-021**: Existing agents and projects MUST be unaffected, apart from FR-006's fix.

### Key Entities

- **Chat**: an agent with the chat mark. It has no project. Its working folder was made for it, under the host's chats folder.
- **Chat folder**: `~/.agents/chats/<agent-id>/` on the chat's host. The app made it, and the app deletes it at retirement.
- **Shared folder**: `~/.agents/chats/shared/` on each host. It is given to every chat on that host and is never deleted by the app.
- **Chats entry**: the per-host group of chats in the sidebar. It is a listing, not a project, and has no `projects.json` record.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A chat can be started from each of the three clients in at most two actions before typing (New Chat, then send). No folder or project needs choosing.
- **SC-002**: After 50 chats on one host, the sidebar shows exactly one Chats entry for that host, and no new project rows.
- **SC-003**: After every chat on a host has been retired, `~/.agents/chats/` holds only `shared/`. That covers chats that crashed mid-turn, once the next daily sweep has run.
- **SC-004**: A file written to the shared folder by one chat is readable by a chat started later, on every runtime that has a session at all. Whether it is writable is recorded per runtime (FR-008).
- **SC-005**: With retention at its defaults, the disk taken by chat folders never exceeds the retention cap. The shared folder past its limit is always visible to the person, never silently growing.

## Docs *(mandatory)*

- `docs/how-to/chat-without-a-project.md` — new: start a chat on each client, the two folders, the shared folder, cleanup, Keep as Project.
- `docs/explanation/projects-hosts-worktrees.md` — change: chats are the one kind of session without a project, and live per host.
- `docs/how-to/give-an-agent-more-folders.md` — change: the first turn now gets extra folders too (FR-006), and what happens when a runtime doesn't advertise them.
- `docs/how-to/archive-park-stop.md` — change: a chat's folder goes when the chat is retired, not when it's archived.
- `docs/reference/settings.md` — change: the shared folder's size, Open, Clear and limit, beside retention.
- `docs/reference/runtimes.md` — change: per runtime, whether the sandbox allows writes into extra folders.
- `docs/reference/keyboard-shortcuts.md` — change: New Chat.
- `docs/how-to/use-agents-in-a-browser.md` — change: New Chat on the web page.
- `docs/reference/agent-tools.md` — change: which tools refuse inside a chat (FR-016).

## Assumptions

- **Chats end at retire, not at archive** (issue question 1). Retire is when the conversation goes. Deleting the folder at archive would break unarchive and push the chat into #119's missing-folder path.
- **Chats sit in one Chats entry per host** in the one sidebar (#145), not in a separate section (issue question 2). It is the smallest change to the sidebar all three clients share, and it keeps the web page and the Remote in step (#233).
- **One shared folder per person per host** (issue question 3), at `~/.agents/chats/shared/`. It is offered to chats only, not to project agents. A project agent can still be given it by hand as an extra folder.
- **Keep as Project is in scope as P3** (issue question 4).
- **The shared folder is not memory** (issue question 5). It holds files a chat chose to keep, not facts the app feeds every agent. `specs/research/shared-memories.md` (#51) stays separate: its user memory lives in instruction files and `remember`/`recall` tools. A later spec may let chats read user memory too.
- **Folder name is the agent id.** It is unique, it never collides, and it can be found from a record. Titles change; ids don't.
- **The chats folder lives in `~/.agents`** because that is already the person's own app-owned folder on every host, and reconciled before every session. The constitution's rule about user-home configuration is kept: chats are given only their two folders.
- **The web page ships with its host**, so it changes with it. Phones may be older (FR-020).
- **Each client's change is in this spec** (#233): Mac, Remote and web all get New Chat and the Chats entry. The `Web/` row in `specs/071-web-remote/walks/parity.md` is updated by the build.

## Open questions for Alex

Each has the default this spec assumes. Claude (#229/#231 specs) needs Alex to confirm or change them before planning.

1. **When does a chat's folder go?** Default: at **retire** (30 days after archive by default, or sooner under the size cap), not at archive. Alex, is a month of keeping archived chats' files right, or should chats have a shorter retention of their own (for example 7 days)?
2. **Where do chats show?** Default: one **Chats** entry per host, after Activity, on all three clients. Alternative: a separate section below the projects. Alex, which?
3. **Bounding the shared folder.** Default: never auto-delete, but show its size, offer Clear, and warn past 1 GB (FR-018). Alternative: delete files untouched for N days. Alex, is "warn, never delete" right, and is 1 GB the right line?
4. **Shared folder for project agents too?** Default: chats only. Alex, should every agent get `~/.agents/chats/shared/` as an extra folder, so a project agent can pick up something a chat kept?
5. **Helpers from a chat.** Default: allowed, sharing the parent's folder (Edge Cases). Alternative: refused in chats. Alex, which?
6. **Keep as Project.** Default: in scope, as P3. Alex, should it wait for a later spec?
7. **Sandboxes.** If a runtime's sandbox can't be widened to the shared folder, the default is to tell the chat it may be read-only (FR-008). Alternative: turn that runtime's sandbox off for chats only, since a chat's folder holds nothing of value. Alex, which?
