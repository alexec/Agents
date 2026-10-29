# Tasks: Auto Runtime

**Input**: [spec.md](spec.md), [plan.md](plan.md), [data-model.md](data-model.md),
[contracts/auto.md](contracts/auto.md)

Each phase is one PR, by its own agent, after the phase before it has auto-merge on (AGENTS.md
#2504). [P] = can run in parallel inside the phase.

## Phase 1 — Words and wire (FR-001, FR-004; Story 2 for sandbox and permission requests)

- [x] T001 Add `ModelLevel`, `PermissionLevel`, `Levels`, `AutoPick`, `AutoSettings`, `AutoMapping`, `NativeSetting`; `StartRequest.levels`; `Agent.auto`, `Agent.clientPermission`; methods `auto/state|set|changed|mappings|preview` in `Packages/Wire/daemon.schema.json` and `daemon.openrpc.json`; run `scripts/wire.sh gen`
- [x] T002 Fix Swift by hand where `WireSchemaTests` says (`Packages/AgentsKit/Sources/AgentsKitCore/Model/`)
- [x] T003 [P] `LevelWords` in `Packages/AgentsKit/Sources/AgentsKitCore/Runtimes/` (every word in the spec); replace `SandboxWords.choice/override` words; fixture `Fixtures/web/levels/words.json`
- [x] T004 [P] Web `Web/src/model/levels.ts` and `model/sandbox.ts` words from the fixture; `Web/test/levels.test.mjs`
- [x] T005 [P] Sandbox capsule words on Mac (`Shared/UI/Chat/SandboxCapsule.swift`), Remote (`StartAgent/ChoiceRows.swift`), web (`views/PromptMenus.tsx`); **follows Settings** mark in place of "Use runtime default"
- [x] T006 [P] Permission requests words: **Request cards** / **Yes to all** in `Shared/UI/Chat/ClientPermissionCapsule.swift`, Remote `ChoiceRows.swift`, web `PromptMenus.tsx`; `App/Sources/Settings/AgentRuntimesSettingsView.swift`
- [x] T007 Update `specs/071-web-remote/walks/parity/` rows; docs words in `docs/how-to/choose-runtime-model-mode.md` and `docs/reference/runtimes.md`

## Phase 2 — Daemon: levels and Auto (FR-003, FR-006–FR-008, FR-011, FR-012, FR-015–FR-019, FR-021)

- [x] T010 `Go/internal/agentsd/automap.go`: shipped table for 8 runtimes × 4 fields with access ranks; `autoCell` with overrides; check against `runtimeOffers`
- [x] T011 Test: no auto-mapped cell has a higher access rank than its level (SC-005); no empty cell (SC-004)
- [x] T012 `auto.json` in `<SettingsDir>`: `auto/state`, `auto/set`, `auto/changed` (as `sandbox/*` in `host.go`, `sandbox.go`)
- [x] T013 `autopick.go`: order, Include, availability, out, rate limited last, every level possible; reasons per runtime; `auto/preview`, `auto/mappings`
- [x] T014 `turns.go startFor`: resolve `auto`; fold levels into `StartOptions.Values`, sandbox, client permission; native values win; record `Agent.auto`; error `autoNoRuntime`
- [x] T015 Per-agent client permission: `alwaysApproves` reads the agent first (`host.go`, `turns.go:1274`); a level change on a running agent maps on the same runtime (`agents.go setOption`)
- [x] T016 Workflows and personas: `runtime: auto`, level words, `permission-requests:`, `sandbox:` (`settings.go`, `workflowfile.go`, `workflowruns.go`); refuse `auto` with a native value; pass effort
- [x] T017 `start_session`: inherit `auto` and levels (`helperstart.go`); pass effort
- [x] T018 Tests for T013–T017 in `Go/internal/agentsd/*_test.go`
- [x] T019 Mac fans `auto/set` out to each machine (`App/Sources/AppModel.swift`, as `sandboxSet`)

## Phase 3 — Mac: Auto and level pills (Story 1, Story 2)

- [x] T020 Auto first in the runtime chooser with "Picks <runtime> now" from `auto/preview` (`App/Sources/Chat/PromptBar.swift`)
- [x] T021 `Shared/UI/Chat/LevelPill.swift`: Model and Permission mode pills; menu header names the field; each item says the native value on the picked runtime
- [x] T022 **⋯ <runtime>'s own** menu with the runtime's options; **Custom** when a native value matches no level
- [x] T023 No Permission requests pill on Auto; header **Auto · <runtime>** (`PromptBar.swift runtimeLabel`)
- [x] T024 Send fails with reasons and keeps the prompt (`AppModel.startDraft`)

## Phase 4 — Mac: Settings ▸ Agent Runtimes ▸ Auto (Story 3, Story 4)

- [x] T030 `App/Sources/Settings/AutoSettingsView.swift`: Runtimes list (Include, drag, state)
- [x] T031 Mappings tables (Model, Permission mode, Permission requests, Sandbox) with marks, override menu, **Reset**

## Phase 5 — Remote (Story 6)

- [x] T040 `Remote/Sources/StartAgent/ChoiceRows.swift`: Runtime row with Auto; Model segmented control; Permission mode; Sandbox
- [x] T041 Chat pills, header and ⋯ own (`Remote/Sources/Chat/PromptBar.swift`)
- [x] T042 Settings Auto page; one runtime per table on iPhone

## Phase 6 — Web (Story 6)

- [x] T050 `Web/src/views/NewAgent.tsx`: Auto first; level menus in `PromptMenus.tsx`
- [x] T051 Chat header and ⋯ own
- [x] T052 Settings Auto page (new in `views/settings/`)

## Phase 7 — Checks, default, continue, docs (FR-013, FR-020, FR-022)

- [x] T060 Nightly runtime check reports `dropped` cells (`scripts/nightly-runtimes.py`, `.agents/workflows/nightly-runtimes.md`)
- [x] T061 Auto is the default runtime for a new install; an existing default stays
- [x] T062 **Continue on <runtime>** on the out note of an Auto session (all three clients)
- [x] T063 Docs: `docs/how-to/use-auto.md` (new), `choose-runtime-model-mode.md`, `docs/reference/runtimes.md`, `docs/reference/workflows.md`, `keep-going-when-a-runtime-runs-out.md`; close #2658
