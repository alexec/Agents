---
description: "Tasks for #229: chat with an agent in a project the app makes"
---

# Tasks: Chat with an agent in a project the app makes

**Input**: [spec.md](spec.md), [plan.md](plan.md), [research.md](research.md), [data-model.md](data-model.md), [contracts/projects-list.md](contracts/projects-list.md), [quickstart.md](quickstart.md)

**Tests**: Included. The quickstart's section 1 lists one daemon test per start-up case, and the repo's practice is a test beside every daemon change. Web model logic gets a `node --test` case.

**Paths**:
- `K/` = `Packages/AgentsKit/Sources/AgentsKitCore`
- `AK/` = `Packages/AgentsKit/Sources/AgentsKit`
- `T/` = `Packages/AgentsKit/Tests/AgentsKitTests`
- `App/`, `Remote/` and `Web/` are as in the repo.

**Rules for every lane** (AGENTS.md):
- Before any `xcodebuild`, `swift build`, `swift test` or `scripts/web.sh build`, lease "build" with lease_resource, and release it the moment the command ends.
- Build through `scripts/build-cache.sh`.
- Verify only what the branch touches.
- Never point a test or walk at the real home or root. Use a scratch root **and** `AGENTS_PERSONAL_HOME` set to a scratch home.
- Each UI commit ends with one parity line per other client.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: can run in parallel (different files, no dependency on an unfinished task)
- **[Story]**: US1–US5 from spec.md

---

## Phase 1: Setup

**Purpose**: no new targets or dependencies. The only setup is a test file to grow through the phases.

- [X] T001 Create `T/Integration/ChatProjectTests.swift`, a Swift Testing suite modelled on `T/Integration/ProjectsTests.swift`. It needs a helper that makes a `DaemonCore` on a temp root, with `StoreLocations.personalHome` set to a temp home folder, never `NSHomeDirectory()`. It also needs a helper with `personalHome == nil`.

---

## Phase 2: Foundational (blocking)

**Purpose**: the chat folder, the wire mark and the state. Every story needs them.

- [X] T002 *(Done differently: `DaemonCore.chatProjectFolder()` in `AK/Daemon/DaemonCore+ChatProject.swift` resolves the home before appending, so the folder standardises the same before and after it exists; no `StoreLocations` change.)* In `K/Store/StoreLocations.swift`, add `public var chatFolder: URL?`: `personalHome?.appending(path: ".agents/chat", directoryHint: .isDirectory)`. Nil when `personalHome` is nil (data-model "Chat folder").
- [X] T003 [P] *(Built as `isChat: Bool?`, nil on every other project, so synthesised encoding omits it.)* In `K/Daemon/DaemonAPI.swift`, add `public var isChat: Bool = false` to `ProjectSummary` (`:565`):
  - Add it to `CodingKeys`.
  - Decode it in the hand-written `init(from:)` with `decodeIfPresent(Bool.self, forKey: .isChat) ?? false`.
  - Encode it **only when true** (write an `encode(to:)`, or keep synthesised encoding if it already omits defaults). Check that one is in place.
  - Rule, verbatim from data-model: "True for exactly the one summary whose folder equals this host's chat folder. Encoded only when true, and decoded with `decodeIfPresent`."
- [X] T004 [P] In `K/Daemon/DaemonAPI.swift`:
  - Add `public enum ChatProjectState: Codable, Hashable, Sendable` with the cases `ready(folder: URL)`, `archived(folder: URL)`, `noPersonalHome` and `failed(message: String)`. Encode it in the same tagged shape as `ChangesUnavailable`.
  - Add `Method.projectsChatState = "projects/chatState"` beside `projectsUnarchive` (`:193`), with an empty request.
- [X] T005 Create `AK/Daemon/DaemonCore+ChatProject.swift`:
  - A stored `chatProjectState` on DaemonCore, defaulting to `.noPersonalHome`, plus `func ensureChatProject()`. It implements the data-model start-up transitions **exactly**:

    ```text
    personalHome nil → noPersonalHome (nothing on disk)
    no record, path missing → mkdir, layOutOnce(chat: true) → ready
    no record, directory there → layOutOnce(chat: true) → ready
    no record, path is a file → failed("~/.agents/chat is a file")
    record, archived → archived (nothing on disk changes)
    record, live, directory there → ready (nothing changes)
    record, live, folder gone → mkdir only → ready
    any step throws → failed(message), logged; start carries on
    ```

  - Log each outcome other than "ready, nothing changed" with `DaemonLog.shared.write("chat project: …")`.
  - Depends on T002 and T004.
- [X] T006 In `AK/Daemon/Daemon.swift`, call `await core.ensureChatProject()` right after `await core.reconcileHome()` (`:145`), before `core.recover()`. This file is shared by the Mac and Linux daemons (research R1, FR-006).
- [X] T007 In `AK/Daemon/DaemonCore+Projects.swift`, in `allProjects(includeArchived:)` (`:29`), set `isChat = true` on the one summary whose `project.folder == Project.standardize(locations.chatFolder)`. Do nothing when `chatFolder` is nil. Depends on T002 and T003.
- [X] T008 In `AK/Daemon/DaemonCore+Dispatch.swift`, handle `DaemonAPI.Method.projectsChatState` beside `projectsUnarchive` (`:205`). Return the current `chatProjectState`, re-derived cheaply: a record that became archived or unarchived since start answers `archived` or `ready`.
- [X] T009 Regenerate `Web/src/protocol/generated.ts` with `scripts/web.sh types`. Check that `isChat?: boolean` and the `ChatProjectState` union appear. Don't hand-edit the file.

**Checkpoint**: the daemon makes and marks the chat project. The clients don't use it yet.

---

## Phase 3: User Story 1 - Start a chat without picking a project (P1) 🎯 MVP

**Goal**: the daemon makes `~/.agents/chat` as a project, and the Mac's New Chat opens the new-session form on it.

**Independent Test**: quickstart section 1 (the first three cases and the no-home case), then section 2, steps 1–3 and 6.

### Tests

- [X] T010 [P] [US1] In `T/Integration/ChatProjectTests.swift`, add these tests:
  - **noPersonalHomeMakesNothing**: with no home, no folder is made and no record is written, and `chatProjectState == .noPersonalHome`.
  - **freshHomeMakesAndMarks**: the folder exists with `.agents/` and `AGENTS.md`, there is exactly one record, and `allProjects()` has exactly one `isChat` summary, named `chat`.
  - **secondStartChangesNothing**: snapshot the contents and modification dates of every file under the chat folder, run `ensureChatProject()` again, and compare them.
  - **handMadeFolderIsAdopted**: an existing folder with a file in it and no record is laid out, and the file is untouched.
- [X] T011 [P] [US1] In `T/PersonalDotAgentsTests.swift`, add a test: a reconcile with `<home>/.agents/chat/.agents/skills/x` present leaves `chat/` and everything under it untouched (research R5).

### Implementation

- [X] T012 [US1] In `App/Sources/AppModel.swift`, add `func chatProjectKey(on host: HostID) -> ProjectKey?`. It returns the key of the summary with `isChat` on that host, or nil.
- [X] T013 [US1] In `App/Sources/Commands/AgentsCommands.swift`, inside `CommandGroup(replacing: .newItem)` (`:58`) after New Session in a Worktree:
  - Add **New Chat** with `.keyboardShortcut("n", modifiers: [.command, .shift])`. It calls `model.showProject(key)` for `chatProjectKey(on: .mac)` (`AppModel.swift:337`), then `requests.focusPrompt()`.
  - When the key is nil, keep it enabled. Ask `projects/chatState` and show the reason in a sheet or alert, with **Unarchive** for `archived` (existing `projects/unarchive`) (FR-011).
- [X] T014 [US1] In `App/Sources/Projects/ProjectListView.swift`, add **New Chat** as the first item of the sidebar's + (New project) menu, with the same action as T013.
- [X] T015 [US1] In `specs/071-web-remote/walks/parity.md`, add a row "New Chat (#229)" after the "Clicking a project row (#366)" row (`:54`). Fill the Mac cell from T013–T014, and mark web and remote "to come (#229 US4)" until those tasks land.

**Checkpoint**: on a scratch root with a scratch home, ⇧⌘N starts a chat in `<home>/.agents/chat`. This is the MVP.

---

## Phase 4: User Story 2 - Keep a file for a later chat (P1)

**Goal**: the shared folder explains itself, and its files outlive the chats that wrote them.

**Independent Test**: quickstart section 1, `AGENTS.md` sentence. Chat A writes a file and is archived and retired, then chat B reads it.

- [X] T016 [US2] In `AK/Projects/DotAgents.swift`, give `routerContents(for:)` (`:150`) a `chat: Bool = false` parameter. When true, add this before `## Context routing`:

  ```text
  ## This folder

  This folder is shared by every chat on this host. Save here what a later chat should find.
  ```

  Thread `chat:` through `apply(to:from:)` (`:79`).
- [X] T017 [US2] In `AK/Daemon/DaemonCore+Projects.swift`, add a `layOutOnce(_:chat:)` overload, or a parameter on `layOutOnce` (`:298`), that passes `chat` to `DotAgents.apply`. `ensureChatProject` (T005) uses it. Every other caller is unchanged.
- [ ] T018 [P] [US2] In `T/Integration/ChatProjectTests.swift`, add these tests:
  - **agentsMdNamesTheSharedFolder**: the first layout's `AGENTS.md` contains the sentence.
  - **editedAgentsMdIsLeft**: delete the sentence, run `ensureChatProject()` again, and the sentence is not back.
  - **fileOutlivesRetire**: start an echo agent in the chat project, write a file into the folder, archive the agent and retire it (`retire(_:because:)`, `AK/Daemon/DaemonCore+Retention.swift:407`), and the file is still there.
- [X] T019 [P] [US2] In `T/DotAgentsTests.swift`, add a test: `routerContents(for:chat: false)` is byte-for-byte what it was, so existing projects are unaffected (FR-014).

---

## Phase 5: User Story 3 - Find chats in the sidebar (P1)

**Goal**: chats list under **chat** like any project's sessions, and archiving the project is honoured.

**Independent Test**: quickstart section 2, step 5. Section 1, archived case.

- [ ] T020 [P] [US3] In `T/Integration/ChatProjectTests.swift`, add these tests:
  - **archivedIsHonoured**: archive the chat project and run `ensureChatProject()`. It is still archived, nothing on disk changed, `chatProjectState == .archived`, and `projects/chatState` answers `archived`.
  - **unarchiveMakesItReady**: after `projects/unarchive`, `projects/chatState` answers `ready`.
  - **liveRecordFolderGoneIsRemade**: delete the folder, run `ensureChatProject()`, and the folder exists again, with no `AGENTS.md` written.
  - **pathIsAFile**: put a file at the path. The state is `failed`, `ensureChatProject` returns, and `allProjects()` still lists other projects.
- [ ] T021 [US3] Check, without changing anything, that the chat project gets no special position in `App/Sources/Projects/ProjectListView.swift`, `Remote/Sources/Sidebar/RemoteSidebar.swift` or `Web/src/views/Sidebar.tsx`. Ordering is by date added (#357). Record the finding in the T015 parity row's notes.

---

## Phase 6: User Story 4 - Chat on a server, from the phone and the web page (P2)

**Goal**: New Chat on the Remote and the web page, and a host choice on all three clients.

**Independent Test**: quickstart sections 3–5.

### Web

- [ ] T022 [P] [US4] In `Web/src/model/` (new `chat.ts`), add `chatProjects(store)`. It returns `{ host, folder }[]` for every online host whose project list has a summary with `isChat` and no `archivedAt`, with this Mac first.
  - Add `Web/test/chat.test.mjs` covering: none, this Mac only, this Mac plus a server, and an archived chat project excluded.
- [ ] T023 [US4] In `Web/src/views/NewProject.tsx`, add **New Chat** at the top of `NewProjectItems`:
  - With one chat project, it is a single item going to `go({ host, project: folder, n: 1 })`.
  - With several, it is one item per host, reading "New Chat on <host>".
  - With none, it is a disabled item. On choosing, it asks `projects/chatState` on this Mac and shows the reason, with an Unarchive button for `archived`.
  - Depends on T022.
- [ ] T024 [US4] In `specs/071-web-remote/walks/parity.md`, fill the web cell of the New Chat row.

### Remote

- [ ] T025 [P] [US4] In `Remote/Sources/RemoteModel.swift`, add `chatProjects` (the same rule as T022: hosts with an unarchived `isChat` summary, this Mac first) and `chatProjectState(on:)`, calling `projects/chatState`.
- [ ] T026 [US4] In `Remote/Sources/Sidebar/RemoteSidebar.swift`, add a toolbar item **New Chat** (`square.and.pencil`). With one chat project, it routes to `RemoteRoute.start` for it, as a project row tap does (#366). With several, it is a `Menu` of hosts. With none, it shows the reason as a sheet, with Unarchive for `archived`. Depends on T025.
- [ ] T027 [US4] In `specs/071-web-remote/walks/parity.md`, fill the Remote cell of the New Chat row.

### Mac servers

- [X] T028 [US4] In `App/Sources/Commands/AgentsCommands.swift`, when `AppModel` has an `isChat` summary on any server, add a **New Chat on ▸** submenu after New Chat (T013), with one item per host that has one. Each calls `showProject` with that host's key.

---

## Phase 7: User Story 5 - No git where there is no repository (P2)

**Goal**: no git errors anywhere for the chat project.

**Independent Test**: quickstart section 2, step 4. Section 3, step 2. The move test.

- [ ] T029 [P] [US5] In `Web/src/views/Changes.tsx`, when `list.git` is `{ unavailable: { notARepository: {} } }`, show the one-line state "This folder is not a Git repository." in place of the empty list, in the Remote's wording (`Remote/Sources/Panes/RemoteChangesPane.swift:116`). Show the other `ChangesUnavailable` cases with the same words the Remote uses.
  - Add a case to `Web/test/` (the module the words live in) for each case.
- [ ] T030 [P] [US5] In `T/Integration/ChatProjectTests.swift`, add these tests:
  - **moveIntoWorktreeIsRefused**: a move into a worktree from an agent in the chat project fails with "Moving needs a git repository, and chat is not in one." (`AK/Daemon/DaemonCore+Moves.swift:66-68`).
  - **worktreesListSaysNotARepository**: `listWorktrees(for: chatFolder)` returns `.notARepository`.
- [ ] T031 [US5] In `specs/071-web-remote/walks/parity.md`, update the Changes pane row: the web now shows the not-a-repository line, matching the Mac and Remote.

---

## Phase 8: Polish and cross-cutting

- [ ] T032 [P] Write `docs/how-to/chat-without-a-project.md` (new): New Chat on each client and its key, where files go, keeping a file for a later chat, chats on a server, and what an archived chat project means. Link it from `docs/how-to/index.md`.
- [ ] T033 [P] Update `docs/explanation/projects-hosts-worktrees.md`: the chat project, one per host and made by the app, and that a project need not be a repository.
- [ ] T034 [P] Update `docs/how-to/add-a-project.md`: the chat project is already there, and archiving it is honoured.
- [ ] T035 [P] Update `docs/how-to/start-in-a-worktree.md`: worktrees aren't offered in a folder that isn't a repository, the chat project included.
- [ ] T036 [P] Update `docs/reference/keyboard-shortcuts.md`: New Chat, ⇧⌘N.
- [ ] T037 [P] Update `docs/how-to/use-agents-in-a-browser.md`: New Chat in the + menu.
- [ ] T038 Run the quickstart:
  1. Daemon tests: `scripts/build-cache.sh swift test --package-path Packages/AgentsKit --filter "ChatProject|PersonalDotAgents|DotAgents"`, leasing "build".
  2. `scripts/web.sh` checks.
  3. Build `AgentsHost` and `AgentsStore`, and the Remote for the generic simulator.
  4. The run-app walk with `AGENTS_PERSONAL_HOME=/tmp/run-229/home`.
  5. The test-servers walk.

  Record what was and wasn't run.
- [ ] T039 Delete `/tmp/run-229` and the worktree's `build/` and `.build`.

---

## Dependencies and execution order

- **Setup (T001)** → **Foundational (T002–T009)** → the stories.
- Within Foundational:
  - T002, T003 and T004 can run in parallel.
  - T005 needs T002 and T004.
  - T006 needs T005.
  - T007 needs T002 and T003.
  - T008 needs T004 and T005.
  - T009 needs T003 and T004.
- **US1 (T010–T015)** needs Foundational only. **MVP.**
- **US2 (T016–T019)** needs T005. It is independent of the US1 client work.
- **US3 (T020–T021)** needs Foundational.
- **US4 (T022–T028)** needs T009 (web types) and T007. The web, Remote and Mac-server groups are independent of each other.
- **US5 (T029–T031)** needs nothing in this feature except T001 for its tests, so it can start at once.
- **Polish (T032–T039)** comes after the stories it describes.

## Parallel examples

- **After T001**: T002, T003, T004, plus T029 (web Changes), which is independent.
- **After Foundational**:
  - One lane: US1 Mac (T012–T014).
  - Another: US2 daemon (T016–T019).
  - Another: US4 web (T022–T023).
  - Another: US4 Remote (T025–T026).

  All are in different files.
- **Tests**: T010, T011, T018, T019, T020 and T030 are mostly in one file (`ChatProjectTests.swift`). Write them in sequence within it. T011 and T019 are other files, so they can be written in parallel.
- **Docs**: T032–T037 can all run in parallel.

## Implementation strategy

1. **MVP**: T001–T015. The daemon makes and marks the chat project, and the Mac has New Chat. Walk it on a scratch root with a scratch home.
2. **Increment 2**: US2 and US3, all daemon-side and test-heavy, so they share one build.
3. **Increment 3**: US4 web and Remote, plus US5's web Changes line (#233: all three clients in one branch, parity rows updated).
4. **Close**: docs, the full quickstart, and the merge wave.
