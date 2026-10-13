# Tasks: An agent writes a provider's tool map or commands

**Input**: [spec.md](spec.md), [plan.md](plan.md), [research.md](research.md),
[data-model.md](data-model.md), [contracts/](contracts/), [quickstart.md](quickstart.md).

**Tests**: the spec asks for them (FR-024, SC-003, SC-004), so each story has its tests first.

**Format**: `[ID] [P?] [Story] Description`. `[P]` can run in parallel (other files, no wait).

## Phase 1: Setup

- [ ] T001 Find how the control plane knows the host on its own machine (research R1) and write
  the answer at the top of research.md R1. If there is no such fact, add `local: Bool` to
  `HostRecord`, set when the control plane starts its own host, in
  `Packages/ControlPlane/Sources/ControlPlaneKit/ControlRecords.swift`.
- [ ] T002 [P] Measure, per runtime, whether its own tools can be turned off (research R2), as
  #015 did. Record it in research.md R2, with the versions.

## Phase 2: Foundational

- [ ] T003 [P] Add `ProviderDraftAPI.swift` in `Packages/AgentsKit/Sources/AgentsKitCore/Control/`:
  the methods and types of contracts/control-methods.md, `host/providerDraft`, and
  `ProviderAdd.cli` and `ProviderAdd.draft`.
- [ ] T004 [P] Add `StartRequest.purpose` and `AgentPurpose` in
  `Packages/AgentsKit/Sources/AgentsKitCore/Daemon/DaemonAPI.swift`; keep it in the agent's
  record; leave such agents out of `agents/list` for clients (FR-009).
- [ ] T005 [P] Add `ToolPolicyCatalog.writer(for:)` from T002's results in
  `Packages/AgentsKit/Sources/AgentsKitCore/Runtimes/ToolPolicyCatalog.swift`, with a test that
  it is total over the built-in runtimes and removes Bash, Write, Edit and web tools for Claude.
- [ ] T006 [P] `DraftRedaction` in `Packages/ControlPlane/Sources/ControlPlaneKit/Providers/DraftRedaction.swift`
  (research R4), with tests: long values, short whole words, URL-encoded and base64 forms.
- [ ] T007 [P] `DraftSafety` in `…/Providers/DraftSafety.swift` (FR-013, FR-014), with a table
  test of tools and commands that run and that ask.
- [ ] T008 Add `tools()` to `ProviderConnection` in `…/Providers/ProviderConnection.swift`: each
  tool's name, description, input schema and annotations. Test against the #691 test server.
- [ ] T009 Add `ProviderRecord.writtenBy` (data-model.md) and its coding, with a decoding test
  for a record without it.

**Checkpoint**: the types, the policy, redaction and safety exist and are tested alone.

## Phase 3: User Story 1 — a map for an MCP server (P1) 🎯 MVP

**Goal**: Write It for Me on the MCP server form gives a checked map that Add keeps.

**Independent test**: spec US1, with a stand-in runtime that writes a fixed map.

### Tests

- [ ] T010 [P] [US1] `ProviderDraftsTests` in `Packages/ControlPlane/Tests/ControlPlaneKitTests/`:
  draftStart with a renamed-tools server starts an agent on the local host with the writer
  purpose; `read_tools` answers the tools, redacted; `check_draft` runs the check and answers
  the list; `send_draft` ends the draft `done`; draftCancel stops the agent.
- [ ] T011 [P] [US1] Tests of the cheap answers (R8): a contract server answers "needs no map";
  the shipped DigitalOcean map's tools answer it, with no agent.
- [ ] T012 [P] [US1] Test of FR-011: another agent's call to a writer tool is refused.
- [ ] T013 [P] [US1] Test of FR-017: after 8 checks the tools answer "The time for this draft is
  over".
- [ ] T014 [P] [US1] Test of SC-003: a secret placed in a tool description, an error and a list
  result is in no step, log line or tool answer.
- [ ] T015 [P] [US1] Test of FR-005 and `writtenBy`: `providers/add` with the draft id and the
  same map sets it; with a changed map does not; Add still checks with no agent.

### Implementation

- [ ] T016 [US1] `ProviderDrafts` actor in `…/Providers/ProviderDrafts.swift`: drafts in
  memory, the 5-minute timer, steps, the owner's notification (R9), cancel on owner gone.
- [ ] T017 [US1] Start the agent over the control plane's own channel (R1), in
  `<control home>/drafts/<id>/`, with the prompt of R7 and the #691 format pages copied in.
- [ ] T018 [US1] Route `providers/draftStart`, `draftCancel`, `runtimes` and `host/providerDraft`
  in `WorkspaceProviders.answer` and `agentCall`; set `writtenBy` in `save`.
- [ ] T019 [US1] The writer's tools in `Packages/AgentsKit/Sources/AgentsKitCore/Model/AppTool.swift`,
  offered by `AppService` only to a writer; relayed in
  `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+ProviderDraft.swift`.
- [ ] T020 [US1] `read_tools`, `check_draft`, `send_draft`, `give_up` in `ProviderDrafts`, through
  `DraftRedaction` and `DraftSafety`.
- [ ] T021 [US1] The sheet: Write It for Me, the runtime menu, the read-only field, the step line,
  Details… and the done lines (L10a, L10b, L10d) in `App/Sources/Control/ProviderDraftView.swift`
  and `ControlProvidersPage.swift`; × and Back cancel.
- [ ] T022 [US1] Write a Tool Map on the refusal at Add (L10f, US1 AS7).

**Checkpoint**: US1 works on a scratch app with the stand-in runtime.

## Phase 4: User Story 2 — commands for a CLI (P1)

**Goal**: Write It for Me on Your commands gives a checked config.

**Independent test**: spec US2, with the fake `cws` fixture.

- [ ] T023 [P] [US2] Fixture `Packages/ControlPlane/Tests/Fixtures/cws`: a shell script with
  `--help`, `list --help`, `list`, `start`, `stop`.
- [ ] T024 [P] [US2] Tests: `read_help` runs only `cws … --help`; a word with a space or `;` is
  refused; a check with a safe `list` runs once; an unsafe one becomes a question; a preset CLI
  answers with no agent; a missing CLI refuses.
- [ ] T025 [US2] `read_help` and the commands check in `ProviderDrafts`, through `ChildProcess`
  with the 25 s timeout and the 16 KB cut.
- [ ] T026 [US2] The CLI field, and the Config editor for a config the fields can't hold (L10e).

## Phase 5: User Story 3 — prove start and stop on asking (P2)

**Goal**: a start or stop runs only after a yes in the sheet.

**Independent test**: spec US3.

- [ ] T027 [P] [US3] Tests: `prove_start` with no answer for 2 minutes (a short timing in the
  test) calls nothing and answers "The person said no."; a yes calls start once; a stop of a
  host with turns running is refused; the 5-minute limit stops while asking (SC-004).
- [ ] T028 [US3] `prove_start`, `prove_stop` and `providers/draftAnswer` in `ProviderDrafts`
  (R6); the check question uses the same path.
- [ ] T029 [US3] The question in the sheet (L10c).

## Phase 6: User Story 4 — write a new map in Edit… (P3)

- [ ] T030 [P] [US4] Test: draftStart with `provider` gives the agent the old map and its
  problem, and its secrets without the sheet typing them again.
- [ ] T031 [US4] Write It for Me in Edit…, with Save (L10f).

## Phase 7: Polish

- [ ] T032 [P] Docs: `docs/how-to/add-a-workspace-provider.md`, `docs/reference/workspace-providers.md`,
  `docs/explanation/control-plane.md`, `docs/reference/agent-tools.md` (spec, Docs).
- [ ] T033 [P] Parity: the Workspace providers row in `specs/071-web-remote/walks/parity.md` names
  Write It for Me; commit line `remote: by design, web: by design`.
- [ ] T034 Test of FR-025 and SC-005: Start and Stop of a provider with `writtenBy` start no agent.
- [ ] T035 Walk quickstart.md on a scratch app with the real default runtime; record SC-001 and
  SC-002 (5 tries each) in `specs/858-provider-map-writer/walks/`.

## Dependencies & Execution Order

- Phase 1 → Phase 2 → US1. US2 and US3 need US1's `ProviderDrafts` (T016–T020), then can run
  side by side. US4 needs US1. Polish last.
- Inside each story: tests first, and they fail before the code.

## Parallel Opportunities

- T002–T009 are in separate files.
- In US1, T010–T015 together; T019 (AgentsKit) beside T016–T018 (ControlPlaneKit).
- US2 and US3 in two lanes once T020 is merged.

## MVP

Phases 1–3 (US1). It is the case Alex asked about, and US2 adds the CLI on the same draft.
