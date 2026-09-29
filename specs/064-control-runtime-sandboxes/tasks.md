---
description: "Tasks for 064, Control runtime sandboxes"
---

# Tasks: Control runtime sandboxes

**Input**: `specs/064-control-runtime-sandboxes/`: spec.md, plan.md, research.md, data-model.md, contracts/daemon-api.md, look/look.md (approved 2026-09-29)

**Tests**: requested (plan, Testing): unit tests against the real failures in `Packages/AgentsKit/Tests/AgentsKitTests/Fixtures/sandbox-failures/`, integration tests with `FakeLauncher`/`FakeACPAgent`, and live walks (run-app on a scratch root, test-servers on the devbox).

**Paths**: `Core` = `Packages/AgentsKit/Sources/AgentsKitCore`, `Kit` = `Packages/AgentsKit/Sources/AgentsKit`, `Tests` = `Packages/AgentsKit/Tests/AgentsKitTests`.

## Format: `[ID] [P?] [Story] Description`

---

## Phase 1: Setup (done for the look, a0d9cfeb)

- [X] T001 Redo research R9 under ACP with `scripts/sandbox-probe.sh`, and keep real failures in `Tests/Fixtures/sandbox-failures/` (209ee242)
- [X] T002 [P] `SandboxChoice`, `SandboxState`, `EffectiveSandbox`, `SandboxSettings`, `SandboxFailureRecord` in `Core/Model/SandboxSettings.swift` (unknown choice decodes as `runtime`; unknown resolution as `keptStopped`)
- [X] T003 [P] `SandboxCatalog` (routes, `measuredOn`, `why`, `failurePatterns`, `readsReply`, `hangsWhenOn`, `choices`, `state`) in `Core/Runtimes/SandboxCatalog.swift`
- [X] T004 [P] Every sentence in `Core/Runtimes/SandboxWords.swift`
- [X] T005 `SandboxSettingsStore` in `Kit/Store/SandboxSettingsStore.swift`; `sandbox/state`, `sandbox/set` (drops choices the catalog lacks), `sandbox/changed` in `Core/Daemon/DaemonAPI.swift`, `Kit/Daemon/DaemonCore+Sandbox.swift`, `Kit/Daemon/DaemonCore+Dispatch.swift`; device role reads state
- [X] T006 `Agent.sandboxOverride`, `Agent.effectiveSandbox` in `Core/Model/Agent.swift` (CodingKeys, decode, encode); `StartRequest.sandbox`
- [X] T007 `agents/setSandbox` with Codex's mode moved in step, and a hand-picked Codex mode writing the override (`setOption(fromSandbox:)`) in `Kit/Daemon/DaemonCore+Sandbox.swift`, `Kit/Daemon/DaemonCore+Commands.swift`
- [X] T008 `TranscriptEntry.Kind.sandboxFailure` (coding, drawn as a block in `Core/Model/OutcomePage.swift`)
- [X] T009 Mac: Settings section in `App/Sources/Settings/AgentRuntimesSettingsView.swift`; `SandboxCapsule` in `Shared/UI/Chat/SandboxCapsule.swift` placed in `App/Sources/Chat/PromptBar.swift`; `SandboxFailureCard` in `Shared/UI/Chat/SandboxFailureCard.swift` with `ChatActions.continueWithoutSandbox`/`keepStopped`; `AppModel` state, calls and server push

---

## Phase 2: Foundational (resolution and launch)

**Purpose**: every agent starts with its resolved choice. Both P1 stories need it: US2 to honour a choice, US1 to continue without the sandbox.

- [X] T010 [P] Unit tests in `Tests/Unit/SandboxSettingsTests.swift`: settings round-trip, a missing key is `runtime`, `setting(.runtime)` removes the key, unknown values decode safely, the store sets an unreadable file aside, `Agent` without the new keys decodes with nil
- [X] T011 [P] Unit tests in `Tests/Unit/SandboxCatalogTests.swift`: `choices` per runtime (Claude, Codex, Grok: runtime/on/off; Gemini: runtime/off; Cursor, Copilot, Antigravity, OpenCode: none), `state` per route (Codex from the mode), every runtime in `RuntimeCatalog.builtIn` has an entry
- [X] T012 `resolvedSandbox(for:caller:)` in `Kit/Daemon/DaemonCore+Sandbox.swift`: override, else default, else `runtime`; a choice not in `SandboxCatalog.choices` becomes `runtime`; helper cap: a caller whose `effectiveSandbox.state == .on` makes Off `runtime` with reason "Limited by the agent that started it"
- [X] T013 TaskLocal `LaunchSandbox` in `Kit/Daemon/DaemonCore+Sandbox.swift`, bound around `launcher.launch` in `freshSession`, `liveSession` (`Kit/Daemon/DaemonCore+Commands.swift`) and the draft in `options()`; a draft carries the default's choice and is reused only when the start resolves to the same (no `OptionsRequest.sandbox` needed)
- [X] T014 `ProcessSessionLauncher.launch` in `Kit/Daemon/DaemonCore.swift`: Grok's route arguments before the runtime's own, Gemini's route environment merged last; nothing for `runtime`
- [X] T015 Claude: `_meta.claudeCode.options.sandbox = {"enabled": Bool}` for On/Off where the app builds Claude's `_meta` options, on new and resumed sessions; nothing for `runtime`
- [X] T016 Codex: a start or resume resolved to Off starts in `agent-full-access`; On from Full access in `read-only` (FR-005c), in the start path of `Kit/Daemon/DaemonCore+Commands.swift`
- [X] T017 Write `effectiveSandbox` after each handshake (`SandboxCatalog.state`, Codex from the mode in force, the helper reason)
- [X] T018 Integration tests in `Tests/Integration/SandboxLaunchTests.swift` with `FakeLauncher`: Grok Off launches with `--sandbox off` first; Gemini Off has `GEMINI_SANDBOX=false`; default `runtime` adds nothing (SC-006); an override beats the default and clearing it inherits; another runtime unaffected; workflow and helper starts inherit; helper cap; a change applies at the next turn's launch; Codex default Off starts in Full access

**Checkpoint**: choices reach the runtime.

---

## Phase 3: User Story 1 — Recover when a sandbox cannot start (P1) 🎯 MVP

**Goal**: a sandbox that failed to set up stops the agent with the card, and **Continue without sandbox** carries on.

**Independent Test**: induce each shape (a fixture through `FakeACPAgent`; live: Claude On on the devbox, Grok On inside an outer `sandbox-exec`); the card appears, nothing retries by itself, Continue re-sends and the agent runs with Off; a `not-*` denial gives no card.

- [X] T019 [P] [US1] `SandboxFailureDetector` in `Core/Runtimes/SandboxFailureDetector.swift`: `match(runtimeID:text:) -> String?` (the trimmed matching lines, ANSI stripped), from `SandboxCatalog.failurePatterns`
- [X] T020 [P] [US1] Unit tests in `Tests/Unit/SandboxFailureDetectorTests.swift`: each fixture matches its runtime; each `not-*` fixture and an auth, allowance and permission-refusal text match nothing; a runtime without patterns matches nothing
- [X] T021 [US1] `ACPSession` keeps the last 8 KB of stderr (`Kit/ACP/`), readable when a launch or turn fails
- [X] T022 [US1] `EndedReason.sandboxFailed` in `Core/Model/EndedReason.swift`: stopped, needs the person, never retried; words for the row and state line
- [X] T023 [US1] Will not start: in `startFailure` and the `liveSession` catch, check the handshake/`session/new` error and stderr before sign-in, allowance and generic handling; record `.sandboxFailure` (`recoveryOffered = SandboxCatalog.canTurnOff`) and end `sandboxFailed`; a new agent's start also returns `sandboxWillNotStart {runtimeID, detail, offOffered}` (`Core/Daemon/DaemonAPI.swift`)
- [X] T024 [US1] Mid-turn: `ACPSession` keeps the turn's `TurnEvidence` (finished tool calls' output, the reply) until the reply's notifications have drained; `finishTurn` checks it (Codex's reply too, `readsReply`), records the card and ends `sandboxFailed` (FR-006a), with `completedToolCalls` counted; the card waits on `Agent.pendingSandboxFailure`
- [X] T025 [US1] Hang: Gemini's handshake has a deadline (90 s) while its resolved choice is not Off; running out of it is `sandboxWillNotStart`, or the card with `hang: true` on a pick-up. Before this, such a Gemini waited for ever
- [X] T026 [US1] `agents/answerSandbox` in `Kit/Daemon/DaemonCore+Sandbox.swift` and dispatch: refused unless `pendingSandboxFailure` is set; keep stopped clears it with a note; carry on needs `recoveryOffered`, sets the override Off (Codex: Full access), notes it, and sends what was queued, else the continuation after completed tool calls, else the last prompt again with `beginTurn(recorded: false)` (R12); a new prompt from the person clears a waiting card
- [X] T027 [US1] Integration tests in `Tests/Integration/SandboxRecoveryTests.swift`: each shape through `FakeACPAgent` with fixture text gives one card and a stopped agent; no turn starts within the wait (SC-009); keep stopped; carry on re-sends and relaunches with Off; continuation after tools; refused when not pending; a `not-*` tool output gives no card (SC-004)
- [X] T028 [US1] Mac: after `sandboxWillNotStart` the new-chat form keeps the prompt and offers **Start without sandbox**, resubmitting with `sandbox: .off` (`App/Sources/AppModel.swift`, `App/Sources/Chat/PromptBar.swift`)

**Checkpoint**: MVP — a failed sandbox is recognised and recoverable on the Mac.

---

## Phase 4: User Story 2 — Choose sandbox behavior before an agent starts (P1)

**Goal**: runtime defaults and per-agent overrides, on Mac and phone, reaching servers.

**Independent Test**: Claude default Off; a new agent writes outside its project; a Cursor agent is unaffected; an override On on one agent blocks it; clearing inherits.

- [ ] T029 [US2] Live check on a scratch root (run-app): Claude and Grok Off/On from Settings and from the pill take effect at the next turn (outside write on disk; Grok's process sandboxed per `sandbox_check`); `daemon.log` launch lines
- [X] T030 [P] [US2] Remote: `SandboxCapsule` in the Remote prompt bar and start form (`Remote/Sources/Chat/`, `Remote/Sources/StartAgent/ChoiceRows.swift`), `sandbox/state` read and `agents/setSandbox` in `RemoteModel`, `ChatActions` for the card in `Remote/Sources/Chat/RemoteChatView.swift`; `StartRequest.sandbox` from the phone
- [ ] T031 [US2] Servers: on the devbox (test-servers), a Mac default reaches the server daemon, again after reconnect; a Claude agent there resolves with the server's catalog
- [X] T032 [US2] Mid-turn change: the menu says "Applies from its next turn" while running; the running command is untouched

---

## Phase 5: User Story 3 — See what protection remains (P2)

**Goal**: the state is visible and explained everywhere.

**Independent Test**: each runtime's Settings page and pill say its state and why; after recovery the pill says Sandbox off.

- [X] T033 [US3] The pill shows `effectiveSandbox` when the agent has one (after recovery, a capped helper's reason as its tooltip), otherwise the resolved choice (`Shared/UI/Chat/SandboxCapsule.swift`)
- [ ] T034 [US3] With the sandbox Off, folder scope and app tool approvals still refuse or ask (SC-007): a scratch-root check through the socket

---

## Phase 6: Polish

- [ ] T035 [P] `docs/reference/runtimes.md`: the Sandbox rows of each runtime's table decided, and a "Command sandbox" section (routes, measured versions, why none)
- [ ] T036 [P] `docs/reference/settings.md`: **Command sandbox** on each runtime's page
- [ ] T037 [P] `docs/how-to/choose-runtime-model-mode.md`: the sandbox pill, and how it differs from the mode
- [ ] T038 [P] `docs/how-to/answer-a-question.md`: the card and its access change
- [ ] T039 `quickstart.md`: replace the probe steps with `scripts/sandbox-probe.sh`; record results
- [ ] T040 Full suite (compare failures with main before blaming the branch), both Xcode schemes, the Linux gate, `scripts/docs.sh check`
- [ ] T041 Walk the built commit on a scratch Mac app: Settings, pill, a real failure (the scratch app's Claude with On inside an outer `sandbox-exec`, or the devbox), Continue without sandbox, keep stopped; screenshots in `look/`
- [ ] T042 Clean up: stop scratch roots by pid, remove `~/agents-sbx-probe`, `/tmp/cx` and `/tmp/gm` on the devbox

## Dependencies

- Phase 1 done. Phase 2 blocks US1's recovery (it relaunches with Off) and US2.
- US1 (T019–T028) and US2 (T029–T032) can proceed in parallel after Phase 2; T030 is independent of US1 except the card's actions.
- US3 after Phase 2. Polish last.

## Parallel examples

- T010, T011, T019, T020 are separate new files.
- T030 (Remote) alongside T023–T026 (daemon).
- T035–T038 docs together.

## Implementation strategy

MVP is Phase 2 + US1 on the Mac: choices reach the runtime and a failure is recoverable. Then US2's phone and servers, US3's polish, docs, the walk.
