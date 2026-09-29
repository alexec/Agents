# Tasks: Read Another Session's History

**Input**: Design documents in `specs/065-continue-successor/`

**Prerequisites**: `spec.md`, `plan.md`, `research.md`, `data-model.md`, and both contracts.

Tests are included because `plan.md` explicitly calls for unit and daemon integration coverage.
Tasks are grouped by user story; allowance behavior and session-history reading can be delivered
as independently reviewable slices after shared transcript support is in place.

## Phase 1: User Story 1 — Ask an agent to continue another session (Priority: P1)

**Goal**: An agent can find and read a session in its own project by id or exact title, without
changing the session it reads.

**Independent Test**: In a daemon integration test, a session reads a second session by title,
receives its history, and leaves the source transcript, record, activity time and status unchanged.
Also cover duplicate and missing titles, retired sessions, archived sessions, the caller's own
session, another project, and helper callers.

- [ ] T001 [P] [US1] Add `SessionHistoryTests.swift` in `Packages/AgentsKit/Tests/AgentsKitTests/Unit/` for transcript rendering and trimming, covering first request, latest complete turns, last plan, omitted-turn count, app-tool omission and the 80,000-character budget from `data-model.md`.
- [ ] T002 [P] [US1] Add `SessionLookupTests.swift` in `Packages/AgentsKit/Tests/AgentsKitTests/Unit/` for UUID-before-title lookup, trimmed exact titles, duplicate titles, archived sessions, retired tombstones, missing transcripts, project scoping and list ordering by newest activity first with UUID ascending ties.
- [ ] T003 [US1] Add `SessionToolsTests.swift` in `Packages/AgentsKit/Tests/AgentsKitTests/Integration/` for `list_sessions` and `read_session`, including helper access, no permission prompt, no session mutation, and the refusal sentences in `specs/065-continue-successor/contracts/session-tools.md`.
- [ ] T004 [US1] Add the pure `SessionHistory` renderer in `Packages/AgentsKit/Sources/AgentsKitCore/Model/SessionHistory.swift`, moving the turn rendering and trimming behavior out of `Packages/AgentsKit/Sources/AgentsKitCore/Pool/Handoff.swift` while using the header and omissions defined in `specs/065-continue-successor/contracts/session-tools.md`.
- [ ] T005 [US1] Add `list_sessions` and `read_session` tool definitions to `Packages/AgentsKit/Sources/AgentsKitCore/Model/AppTool.swift` and their parameter/result schemas to `Packages/AgentsKit/Sources/AgentsKit/ACP/Serve/AppService.swift`, registering both in `AppTool.all` so app-served calls are auto-allowed.
- [ ] T006 [US1] Add `agents/listSessions` and `agents/readSession` request and response types to `Packages/AgentsKit/Sources/AgentsKitCore/Daemon/DaemonAPI.swift`, and relay both methods through `Daemon/Sources/main.swift`.
- [ ] T007 [US1] Implement project-scoped listing and lookup in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Sessions.swift`, deriving scope only from the caller token, using live agent records and retired tombstones, and returning the contract's fixed refusal sentences.
- [ ] T008 [US1] Route both tools through `Packages/AgentsKit/Sources/AgentsKit/ACP/Serve/AppService.swift` for every agent, including helpers, and have reads use `TranscriptReader` and `SessionHistory` without recording, broadcasting or updating `lastActivityAt`.
- [ ] T009 [US1] Add the session-continuation instructions to `Packages/AgentsKit/Sources/AgentsKit/ACP/Serve/Briefing.swift`, including exact-title/id lookup, project-only access and the fact that reading leaves the source session unchanged.

**Checkpoint**: A new chat can name and read a session from its project; the source remains unchanged.

## Phase 2: User Story 2 — A spent allowance stops the chat and says so (Priority: P1)

**Goal**: A recognised spent allowance ends only the refused chat on its current runtime. It does
not start or wait for a successor and does not affect other chats using the same credential.

**Independent Test**: A fake runtime reports a spent allowance. The refused chat ends with the
existing note and `.allowanceSpent`; no second session or wait is created; a second chat on the
same runtime remains usable; rate limits retry on the same chat.

- [ ] T010 [P] [US2] Add `AllowanceEndingTests.swift` in `Packages/AgentsKit/Tests/AgentsKitTests/Integration/` for spent allowance, exhausted credit, overage, same-credential second chat, no successor start, no allowance wait, and the existing per-chat rate-limit retry.
- [ ] T011 [US2] Change recognition handling in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Pool.swift` so `.spent`, `.creditGone` and `.overage` append only their existing `PoolWords` note and end the refused chat with `.allowanceSpent`; preserve successful overage turns and keep rate-limit retry state keyed by agent id.
- [ ] T012 [US2] Remove automatic carry, allowance-wait scheduling and shared allowance-state updates from `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Pool.swift`, `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Blocks.swift` and their `DaemonCore` call sites; clear a decoded legacy wait during startup without starting a turn.
- [ ] T013 [US2] Keep legacy agent fields decoding in `Packages/AgentsKit/Sources/AgentsKitCore/Model/Agent.swift`, but stop writing `poolEntryID`, `switchingOff` and `allowanceWait`; ensure a stopped legacy agent without an ending reason is restored as `.allowanceSpent` where required by `specs/065-continue-successor/data-model.md`.

**Checkpoint**: A quota refusal ends its own chat with a clear status; no chat-wide allowance memory or automatic continuation remains.

## Phase 3: User Story 3 — Read what a session actually did (Priority: P2)

**Goal**: The history result describes recorded work faithfully and stays useful for long sessions.

**Independent Test**: Read one short and one over-budget transcript. The short result includes the
request, replies, tool activity and last plan; the long result preserves the first request, newest
complete turns and plan, and states how many turns were omitted.

- [ ] T014 [US3] Extend `SessionHistoryTests.swift` in `Packages/AgentsKit/Tests/AgentsKitTests/Unit/` to cover in-flight transcripts, archived transcripts, worktree and working-folder headers, subagent tool labels, omission of thoughts/usage/permission traffic/pool bookkeeping, and a plan that alone exceeds the history budget.
- [ ] T015 [US3] Complete history formatting in `Packages/AgentsKit/Sources/AgentsKitCore/Model/SessionHistory.swift` so each turn groups a user message with following entries, app-originated prompts are labeled, tool file paths are retained, and the last plan is included independently of the turn trim.
- [ ] T016 [US3] Ensure transcript loading in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Sessions.swift` uses the indexed `TranscriptReader` path and does not materialize the full transcript as one string before applying the history budget.

**Checkpoint**: History returned to an agent is bounded, readable, and representative of the source transcript.

## Phase 4: Remove the pool and update public guidance

**Purpose**: Remove the pool and Continue with surfaces while preserving legacy transcript rendering and the standalone blocked-chat Carry on action.

- [ ] T017 [P] Remove the Pool page, Continue with sheet and Matching models UI from `App/Sources/Pool/`, and remove their navigation, shortcut, settings pane and allowance-wait row references from `App/Sources/Projects/SidebarItem.swift`, `App/Sources/Projects/ProjectListView.swift`, `App/Sources/Settings/SettingsWindow.swift` and `App/Sources/AgentList/AgentRow.swift`.
- [ ] T018 [P] Remove the Pool page and Continue with surfaces from `Remote/Sources/Pool/`, and remove pool navigation and allowance-wait presentation from `Remote/Sources/Projects/ProjectListView.swift`, `Remote/Sources/Projects/AgentCard.swift` and `Remote/Sources/Chat/RemoteChatView.swift`.
- [ ] T019 Remove pool persistence and obsolete pool API surface from `Packages/AgentsKit/Sources/AgentsKit/Store/PoolStore.swift`, `Packages/AgentsKit/Sources/AgentsKitCore/Daemon/DaemonAPI.swift` and `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Pool.swift`; retain `LimitRecognition`, `RateLimitPolicy`, `PoolWords` notes and legacy transcript decoding/drawing.
- [ ] T020 Remove `agent.runtime_switched`, `cost.allowance_out` and `cost.allowance_back` from `Packages/AgentsKit/Sources/AgentsKitCore/Model/EventCatalogue.swift` and update `Packages/AgentsKit/Tests/AgentsKitTests/Unit/EventCatalogueTests.swift`, while leaving old event log lines readable as historical data.
- [ ] T021 Update or remove pool-specific tests under `Packages/AgentsKit/Tests/AgentsKitTests/` that assert switching, shared allowance state, or allowance waits; preserve tests for allowance recognition, same-chat rate retries, blocked-chat Carry on and old transcript decoding.
- [ ] T022 [P] Replace `docs/how-to/keep-going-when-a-runtime-runs-out.md`, remove `docs/explanation/runtime-pool.md`, and update `docs/how-to/index.md` and `docs/explanation/index.md` to describe starting a new chat and reading the prior session.
- [ ] T023 [P] Update `docs/reference/settings.md`, `docs/reference/statuses.md`, `docs/reference/events.md`, `docs/reference/agent-tools.md`, `docs/reference/runtimes.md`, `docs/reference/keyboard-shortcuts.md` and `docs/how-to/limit-spending.md` to remove pool behavior and document the session tools and per-chat allowance ending.
- [ ] T024 Add `specs/065-continue-successor/quickstart.md` with a focused implementation verification sequence for session lookup/history, allowance ending, removed pool surfaces, legacy transcript readability and blocked-chat Carry on.
- [ ] T025 Reconcile all remaining pool references in `App/`, `Remote/`, `Packages/AgentsKit/`, `Daemon/` and `docs/` against `specs/065-continue-successor/spec.md`, preserving compatibility fields and historical transcript display explicitly called out by the data model.

## Dependencies & Execution Order

### Phase Dependencies

- **US1** depends on the `SessionHistory` renderer and its unit coverage in T001 and T004; its tools then expose that renderer through the daemon and MCP service.
- **US2** can proceed independently of the session tools after the current recognition path is understood. Pool UI removal waits until its daemon behavior is removed.
- **US3** extends the history behavior introduced in US1 and depends on T004.
- **Pool removal and docs (Phase 4)** follow US1–US3 so legacy compatibility and replacement behavior are defined before deletion.

### Story Dependencies

- **US1 (P1)**: core feature; no dependency on US2.
- **US2 (P1)**: independent per-chat ending behavior; shares the eventual pool cleanup in Phase 4.
- **US3 (P2)**: depends on the history renderer introduced in US1.

### Parallel Opportunities

- T001 and T002 can be authored in parallel; T003 follows when daemon tool contracts are wired.
- T010 can be written independently from US1 history work.
- T014 can be extended while T011–T013 are implemented, as they touch separate test and daemon files.
- T017, T018, T022 and T023 are separate UI/docs areas and can proceed in parallel after the feature behavior is settled.

## Implementation Strategy

1. Deliver US1 first: pure history rendering, project-scoped lookup, and both agent tools.
2. Deliver US2 next: make the allowance outcome explicitly per chat and preserve same-chat rate retries.
3. Complete US3 history fidelity and budget behavior.
4. Remove the pool and Continue with surfaces, then update docs and verify compatibility with old records and transcripts.

The MVP is US1 plus US3: a person can ask a new agent to continue work using a read-only view of
the old session. US2 can ship as a separately reviewable behavior change, but the removed pool
surfaces must not remain advertised after the pool behavior is removed.
