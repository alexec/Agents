# Tasks: Read Another Session's History

**Input**: Design documents in `specs/065-continue-successor/`

**Prerequisites**: `spec.md`, `plan.md`, `research.md`, `data-model.md`, and both contracts.

Tests are included because `plan.md` explicitly calls for unit and daemon integration coverage.
Tasks are grouped by user story; allowance behavior, runtime state and session-history reading
can be delivered as independently reviewable slices after shared transcript support is in place.

Revised 2026-09-28: runtime state is kept and shown for every runtime (US4), never enforced.

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

**Goal**: A recognised spent allowance ends the refused chat on its current runtime and marks
that runtime out. It does not start or wait for a successor, and does not stop other chats.

**Independent Test**: A fake runtime reports a spent allowance. The refused chat ends with the
existing note and `.allowanceSpent`; no second session or wait is created; the runtime's state
is out; a second chat on the same runtime is prompted and, when its turn works, the runtime is
available again; rate limits retry on the same chat.

- [ ] T010 [P] [US2] Add `AllowanceEndingTests.swift` in `Packages/AgentsKit/Tests/AgentsKitTests/Integration/` for spent allowance, exhausted credit, overage (completed and failed turns), no successor start, no allowance wait, the runtime marked out in each case, a second chat on the same runtime prompted as usual, and the per-chat rate-limit retry.
- [ ] T011 [US2] Change `applyRecognition` in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Pool.swift` so `.spent`, `.creditGone` and `.overage` append their existing `PoolWords` note, end the refused chat with `.allowanceSpent` (preserving a completed overage turn), and mark the runtime's `AllowanceState` out, with no `pendingCarry`.
- [ ] T012 [US2] Remove automatic carry, allowance-wait scheduling and the move-first check (`willCarry`, `carryOnIfPending`, `switchRuntime`, `startWaiting`, `resumeAllowanceWaits`, `moveFirstIfOut`, `carryTried`) from `DaemonCore+Pool.swift`, `DaemonCore+Blocks.swift` and their `DaemonCore` call sites; clear a decoded legacy wait during startup without starting a turn.
- [ ] T013 [US2] Move the rate-limit streak from `AllowanceState.rateLimitStreak` to a per-agent dictionary on `DaemonCore`, so three refusals in ten minutes on one chat stop that chat and mark the runtime out with `.rateLimitPersisted`; keep the field decodable and stop writing it.
- [ ] T014 [US2] Keep legacy agent fields decoding in `Packages/AgentsKit/Sources/AgentsKitCore/Model/Agent.swift`, but stop writing `poolEntryID`, `switchingOff` and `allowanceWait`; restore a stopped legacy agent without an ending reason as `.allowanceSpent` per `data-model.md`.

**Checkpoint**: A quota refusal ends its own chat and marks its runtime; nothing continues the chat.

## Phase 3: User Story 3 — Read what a session actually did (Priority: P2)

**Goal**: The history result describes recorded work faithfully and stays useful for long sessions.

**Independent Test**: Read one short and one over-budget transcript. The short result includes the
request, replies, tool activity and last plan; the long result preserves the first request, newest
complete turns and plan, and states how many turns were omitted.

- [ ] T015 [US3] Extend `SessionHistoryTests.swift` in `Packages/AgentsKit/Tests/AgentsKitTests/Unit/` to cover in-flight transcripts, archived transcripts, worktree and working-folder headers, subagent tool labels, omission of thoughts/usage/permission traffic/pool bookkeeping, and a plan that alone exceeds the history budget.
- [ ] T016 [US3] Complete history formatting in `Packages/AgentsKit/Sources/AgentsKitCore/Model/SessionHistory.swift` so each turn groups a user message with following entries, app-originated prompts are labeled, tool file paths are retained, and the last plan is included independently of the turn trim.
- [ ] T017 [US3] Ensure transcript loading in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Sessions.swift` uses the indexed `TranscriptReader` path and does not materialize the full transcript as one string before applying the history budget.

**Checkpoint**: History returned to an agent is bounded, readable, and representative of the source transcript.

## Phase 4: User Story 4 — See each runtime's state where runtimes are set up (Priority: P2)

**Goal**: Every runtime the app finds has a state, checked every four hours when out, and shown
on its Agent Runtimes card and on the phone. Nothing enforces it.

**Independent Test**: With no pool set up, fail one runtime and spend another's allowance. Both
show as out in `runtimes/allowances` with their next checks; a due check that passes brings one
back; Mark available brings the other back; a Grok reading appears on its row; a prompt to an
out runtime is sent.

- [ ] T018 [P] [US4] Add `RuntimeStateTests.swift` in `Packages/AgentsKit/Tests/AgentsKitTests/Integration/` for: failure marks out with no pool; a check runs when due with no pool, passes and fails as in `contracts/runtime-state.md`; a working turn brings it back; Mark available; a key's credit ledger and expiry; a runtime out in `allowances.json` before launch is still out after; a prompt to an out runtime is sent without delay.
- [ ] T019 [US4] Drop the `pool.isEffective` guards and `pool.entries` walks from `markRuntimeFailed`, `checkDueAllowances`, `settlePoolClocks`, `measureAllowances` and `applyAllowances` in `DaemonCore+Pool.swift`; derive the runtime from the credential key; ask Grok for a reading when Grok is located, not when it is in a pool.
- [ ] T020 [US4] Rename, with no behaviour change, as one commit: `AgentsKitCore/Pool/` to `AgentsKitCore/Runtimes/Allowance/`, `PoolEntry` to `RuntimePayment`, `PoolStore` to `AllowanceStore`, `DaemonCore+Pool.swift` to `DaemonCore+Allowances.swift`; update tests and callers.
- [ ] T021 [US4] Add `RuntimePayments` and `payments.json` in `AllowanceStore`, with the one-time move from `pool.json` described in `data-model.md`, and a unit test `RuntimePaymentMigrationTests.swift` covering keyed, credit and plain sign-in entries and a second launch.
- [ ] T022 [US4] Add `RuntimeAllowances` (from `PoolStatus`: rows per located runtime and keyed credential, `startingOnOut` without `instead`) and the methods `runtimes/allowances`, `runtimes/markAvailable`, `runtimes/setPayment` and the notification `runtimes/allowancesChanged` to `DaemonAPI.swift` and `DaemonCore+Dispatch.swift`, allowing paired devices the first two; keep `pool/applyAllowances`.
- [ ] T023 [US4] Reword the pool sentences in `PoolWords` and in `raiseAllowanceOut`/`raiseAllowanceBack` per `contracts/runtime-state.md` ("failed and left the pool" and "is back in the pool" go), and update `PoolWordsTests`.
- [ ] T024 [P] [US4] Add the state line, the plan-left line, **Mark available** and, on a keyed runtime, **Credit on this key…** (moving `App/Sources/Pool/AddCreditSheet.swift` to `App/Sources/Settings/`) to `App/Sources/Settings/AgentRuntimesSettingsView.swift`; ask for readings when the page opens; switch `AppModel` from `poolStatus` to `runtimeAllowances`.
- [ ] T025 [P] [US4] Change the prompt bar notice in `App/Sources/Chat/PromptBar.swift` to `RuntimeAllowances.startingOnOut`, without the offer of another runtime, and with Send left enabled.
- [ ] T026 [P] [US4] Add `Remote/Sources/Projects/RuntimesView.swift` (rows, read-only, Mark available as a swipe action) in place of `Remote/Sources/Pool/PoolPageView.swift`, reached from **Spending** in `TotalsView.swift`; switch `RemoteModel` to `runtimes/allowances`.
- [ ] T027 [US4] Walk it with the run-app skill on a scratch root: seed an out runtime with `pool/applyAllowances` (`since` at least 4h ago), see the card, the prompt bar notice, a check passing in `daemon.log`, and Mark available; screenshot the Agent Runtimes page.

**Checkpoint**: The person can see which runtimes are out, and when each is checked, without a pool.

## Phase 5: Remove the pool and update public guidance

**Purpose**: Remove the pool and Continue with surfaces while keeping runtime state, legacy
transcript rendering and the standalone blocked-chat Carry on action.

- [ ] T028 [P] Remove the Pool page, Continue with and Matching models from `App/Sources/Pool/`, `App/Sources/Settings/PoolSettingsView.swift`, and their navigation, sidebar row and dot, Option-Command-P, settings pane and allowance-wait row references in `SidebarItem.swift`, `ProjectListView.swift`, `SettingsWindow.swift` and `AgentRow.swift`.
- [ ] T029 [P] Remove the Pool page and Continue with from the Remote, and pool navigation and allowance-wait presentation from `Remote/Sources/Projects/ProjectListView.swift`, `AgentCard.swift` and `Remote/Sources/Chat/RemoteChatView.swift`.
- [ ] T030 Remove `pool/state`, `pool/set`, `pool/markAvailable`, `pool/stopWaiting`, `pool/models`, `agents/continueWith` and `pool/changed` from `DaemonAPI.swift` and dispatch; remove `PoolPlan`, `MatchingModels`, `SettingsCarry`, `AllowanceWait` scheduling, `Handoff` and the switch history; keep `SwitchRecord` only if an old transcript view still needs it.
- [ ] T031 Remove `agent.runtime_switched` from `EventCatalogue.swift` and update `EventCatalogueTests.swift`; keep `cost.allowance_out` and `cost.allowance_back`, reworded.
- [ ] T032 Remove pool-specific tests that assert switching, waiting, Continue with or Matching models (`PoolSwitchTests`, `AllowanceWaitTests`, `PoolPlanTests`, `StartingOnOutTests`' "instead" cases, and the like); keep and re-seat without a pool the tests for allowance state, recognition, checks, readings, credit ledger, server sharing, same-chat rate retries, blocked-chat Carry on and old transcript decoding.
- [ ] T033 [P] Replace `docs/how-to/keep-going-when-a-runtime-runs-out.md`, remove `docs/explanation/runtime-pool.md`, and update `docs/how-to/index.md` and `docs/explanation/index.md`.
- [ ] T034 [P] Update `docs/reference/settings.md` (Pool pane out, runtime state on Agent Runtimes in), `statuses.md`, `events.md`, `agent-tools.md`, `runtimes.md` (the check table without "in the pool"), `keyboard-shortcuts.md` and `docs/how-to/limit-spending.md`.
- [ ] T035 Update `specs/065-continue-successor/quickstart.md` to the final behaviour and run it.
- [ ] T036 Reconcile all remaining pool references in `App/`, `Remote/`, `Packages/AgentsKit/`, `Daemon/` and `docs/` against `spec.md`, keeping compatibility fields and historical transcript display called out by `data-model.md`. Build both schemes and the Linux gate.

## Dependencies & Execution Order

### Phase Dependencies

- **US1** depends on the `SessionHistory` renderer and its unit coverage in T001 and T004.
- **US2** can proceed independently of the session tools.
- **US3** extends the history behaviour introduced in US1 and depends on T004.
- **US4** depends on US2's T011–T013 (the state is written where the ending is decided). T020,
  the rename, lands alone before T021–T026.
- **Phase 5** follows US2 and US4, so the new rows exist before the Pool page goes, and the
  prompt bar never loses its notice.

### Parallel Opportunities

- T001 and T002 can be authored in parallel; T003 follows when the daemon contracts are wired.
- T010 and T018 can be written independently of US1.
- T024, T025 and T026 are separate UI areas once T022 is in.
- T028, T029, T033 and T034 are separate UI and docs areas.

## Implementation Strategy

1. US1 and US3: the session tools. The MVP; safe to ship alone, since nothing else changes.
2. US2: the chat ends on its runtime; the pool stops carrying. The Pool page still shows state.
3. US4: tracking without the pool, the rename, the new rows.
4. Phase 5: remove the pool's surfaces, then docs and the quickstart.

Walk steps 3 and 4 on a scratch root before each merge; the phone's look is Alex's.
