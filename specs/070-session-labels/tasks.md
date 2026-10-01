---
description: "Dependency-ordered implementation tasks for session labels"
---

# Tasks: Session labels

**Input**: Design documents from `specs/070-session-labels/`.

**Prerequisites**: `plan.md`, `spec.md`, `research.md`, `data-model.md`, and
`contracts/labels-tools.md`.

**Tests**: Tests are included because the feature spec supplies independent test criteria
and acceptance scenarios for all four user stories.

**Organization**: Tasks are grouped by the four user stories in the spec's priority order.

## Phase 1: Setup

**Purpose**: Add shared label policy and its unit-level verification before connecting
storage or UI.

- [X] T001 Add normalization, trimming, owner, and limit cases to `Packages/AgentsKit/Tests/AgentsKitTests/Unit/SessionLabelTests.swift`; cover whitespace-only, over 24 characters, case-insensitive equality, and the five-label limit.
- [X] T002 Implement the `SessionLabel` value, owner representation, canonical spelling, and shared validation policy in `Packages/AgentsKit/Sources/AgentsKitCore/Model/SessionLabel.swift`; enforce “1 to 24 characters” and “up to 5 labels”.

## Phase 2: Foundational

**Purpose**: Persist labels compatibly on the session record and make project-scoped label
vocabulary available to later stories.

- [X] T003 Add old-record and round-trip coverage for absent and present labels in `Packages/AgentsKit/Tests/AgentsKitTests/Unit/AgentTests.swift`.
- [X] T004 Add `labels` to `Agent` Codable storage in `Packages/AgentsKit/Sources/AgentsKitCore/Model/Agent.swift`; default missing fields to an empty list and preserve unknown fields.
- [X] T005 Add project vocabulary and shared query tests in `Packages/AgentsKit/Tests/AgentsKitTests/Unit/SessionLabelTests.swift` and `Packages/AgentsKit/Tests/AgentsKitTests/Unit/SessionLabelQueryTests.swift`; include archived sessions, final-use removal, and `label:<value>` plus text.
- [X] T006 Implement project vocabulary in `Packages/AgentsKit/Sources/AgentsKitCore/Model/SessionLabel.swift` and shared query parsing/matching in `Packages/AgentsKit/Sources/AgentsKitCore/Model/SessionLabelQuery.swift`; include archived records and reuse canonical spelling while a value remains in use.

**Checkpoint**: Existing records still decode; label policy and project vocabulary are
shared by daemon, tools, and views.

## Phase 3: User Story 1 - Tell a session apart at a glance (Priority: P1)

**Goal**: People can add and remove labels from new-session, session-menu, and chat surfaces;
labels persist and appear on Mac and Remote without reopening a session.

**Independent Test**: Start sessions with labels from the Mac and Remote new-session forms,
add/remove labels from an existing session, and verify row/card/header updates on connected
views. Verify the Remote card shows no more than two chips and a `+N` count.

### Tests for User Story 1

- [X] T007 [US1] Add person label mutation integration coverage in `Packages/AgentsKit/Tests/AgentsKitTests/Integration/SessionLabelMutationTests.swift`; cover create, remove, persistence, unchanged invalid requests, and broadcast within five seconds.

### Implementation for User Story 1

- [X] T008 [US1] Add optional person labels to `StartRequest` and a person label-change request to `Packages/AgentsKit/Sources/AgentsKitCore/Daemon/DaemonAPI.swift`; the mutation request carries a session ID plus add/remove arrays and never accepts an owner field.
- [X] T009 [US1] Route person label-change calls through the daemon in `Daemon/Sources/main.swift` and `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Dispatch.swift`.
- [X] T010 [US1] Implement person-authorized add/remove and atomic refusal in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Sessions.swift`, and save start-request labels with person ownership before the first broadcast in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Commands.swift`.
- [X] T011 [US1] Add label mutation, project suggestions, and new-session label submission to `App/Sources/AppModel.swift` and `Remote/Sources/RemoteModel.swift`.
- [X] T012 [P] [US1] Add the Mac label editor and owner-distinguishing chips to `App/Sources/AgentList/AgentRow.swift`; include the session menu actions and accessible owner wording.
- [X] T013 [P] [US1] Use the shared label/text matcher in `App/Sources/Projects/SessionsColumn.swift`; show an explicit empty result for unmatched labels and validate list-to-label interaction in under ten seconds.
- [X] T014 [P] [US1] Add all labels and label actions to the Mac chat chrome in `App/Sources/Chat/ChatView.swift`.
- [X] T015 [P] [US1] Add removable label draft entry and submission to `App/Sources/Chat/PromptBar.swift` for Mac new sessions.
- [X] T016 [P] [US1] Add compact owner-distinguishing chips and `+N` overflow to `Remote/Sources/Projects/AgentCard.swift`; expose owner information in accessibility text.
- [X] T017 [P] [US1] Add full label chips and person label actions to `Remote/Sources/Chat/RemoteChatView.swift`.
- [X] T018 [P] [US1] Add removable label draft entry and submission to `Remote/Sources/StartAgent/StartAgentView.swift` for Remote new sessions.

**Checkpoint**: A person can label, see, and remove session labels across both app surfaces.

## Phase 4: User Story 2 - An agent labels the work it starts and finishes (Priority: P1)

**Goal**: `start_agent`, `finish_turn`, and workflow front matter can create agent-owned
labels, including on agents started by another agent or workflow.

**Independent Test**: Start a labeled helper, add a label via `finish_turn`, and start a
workflow with labels. Confirm each session shows agent-owned labels and the operations take
effect when the record first appears or the turn ends.

### Tests for User Story 2

- [X] T019 [P] [US2] Add MCP `start_agent` and `finish_turn` label payload and application tests in `Packages/AgentsKit/Tests/AgentsKitTests/Integration/SessionLabelToolTests.swift`.
- [X] T020 [P] [US2] Add workflow front matter parsing and propagation tests in `Packages/AgentsKit/Tests/AgentsKitTests/Integration/WorkflowLabelTests.swift`.

### Implementation for User Story 2

- [X] T021 [US2] Extend the `start_agent` MCP schema and decoder in `Packages/AgentsKit/Sources/AgentsKit/ACP/Serve/AppService.swift` to accept optional `labels`.
- [X] T022 [US2] Carry start-helper labels through `Packages/AgentsKit/Sources/AgentsKitCore/Daemon/DaemonAPI.swift` and `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Helpers.swift`; create the helper with agent-owned labels.
- [X] T023 [US2] Extend the `finish_turn` schema, decoder, and finish sink in `Packages/AgentsKit/Sources/AgentsKit/ACP/Serve/AppService.swift` to accept `add_labels` and `remove_labels`.
- [X] T024 [US2] Carry finish-turn label changes through `Packages/AgentsKit/Sources/AgentsKitCore/Daemon/DaemonAPI.swift` and apply them atomically in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+AppTools.swift` before the final record save.
- [X] T025 [P] [US2] Add workflow `labels` to `WorkflowSettings` in `Packages/AgentsKit/Sources/AgentsKitCore/Model/WorkflowSettings.swift` and parse the sequence in `Packages/AgentsKit/Sources/AgentsKit/Workflows/WorkflowFile.swift`; keep `isEmpty` tied to runtime options so labels alone use the normal start path.
- [X] T026 [US2] Apply workflow labels to each newly started workflow session in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Workflows.swift`.

**Checkpoint**: Direct helpers, end-of-turn changes, and workflow starts all produce
agent-owned labels.

## Phase 5: User Story 3 - The person stays in charge of their own labels (Priority: P2)

**Goal**: Enforce ownership in daemon/core logic so agent calls cannot remove, rename, or
claim a person's label.

**Independent Test**: Add a person-owned label, ask an agent to remove it with matching and
different casing, and ask it to add the same value as its own. Verify no mutation and an
actionable refusal for each attempt; verify the person can remove an agent-owned label.

### Tests for User Story 3

- [X] T027 [US3] Add ownership refusal and atomicity scenarios in `Packages/AgentsKit/Tests/AgentsKitTests/Integration/SessionLabelToolTests.swift`; verify 20 of 20 person-label removal/rename attempts are refused with reasons and no changes.

### Implementation for User Story 3

- [X] T028 [US3] Enforce the agent ownership matrix in `Packages/AgentsKit/Sources/AgentsKitCore/Model/SessionLabel.swift`; agent removals may target only agent-owned values, while person changes may remove either owner class.
- [X] T029 [US3] Return actionable ownership refusals from `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+AppTools.swift` without partially applying finish-turn changes.
- [X] T030 [US3] Ensure the label owner is stated in textual/accessibility wording in `App/Sources/AgentList/AgentRow.swift` and `Remote/Sources/Projects/AgentCard.swift`, in addition to the filled/outlined chip styles.

**Checkpoint**: Ownership is enforced by shared policy and the person remains authoritative.

## Phase 6: User Story 4 - Find a session by what it is (Priority: P2)

**Goal**: Session search filters by `label:<value>`, combines with ordinary text, and agent
session listings include label values and owners.

**Independent Test**: In a project of labeled and unlabeled sessions, verify label-only,
combined, unmatched, and case-insensitive queries. Verify `list_sessions` and
`list_my_agents` return every label and owner.

### Tests for User Story 4

- [X] T031 [US4] Add label query parsing, conjunction, empty results, and case-insensitive match tests in `Packages/AgentsKit/Tests/AgentsKitTests/Unit/SessionLabelQueryTests.swift`.
- [X] T032 [US4] Add session-listing label and owner output tests in `Packages/AgentsKit/Tests/AgentsKitTests/Unit/SessionLookupTests.swift`.

### Implementation for User Story 4

- [X] T033 [US4] Append label values with `person`/`agent` owners to the `list_sessions` text output in `Packages/AgentsKit/Sources/AgentsKitCore/Model/SessionLookup.swift`.
- [X] T034 [US4] Update the text result descriptions in `Packages/AgentsKit/Sources/AgentsKit/ACP/Serve/AppService.swift` and append label/owner text to `list_my_agents` in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Helpers.swift`.
- [X] T035 [US4] Use the shared matcher and a full-project archived query in `Remote/Sources/Projects/ProjectPageView.swift` and `Remote/Sources/RemoteModel.swift`; show an explicit unmatched-label empty state, including when matches lie beyond the normal ten archived cards.
- [X] T036 [US4] Add a 200-session filter performance check to `Packages/AgentsKit/Tests/AgentsKitTests/Unit/SessionLabelQueryTests.swift`; verify the filter completes under one second.

**Checkpoint**: People and agents can both find sessions by label with owner provenance.

## Phase 7: Polish and cross-cutting concerns

**Purpose**: Check archive retention and server routing, then update the public docs.

- [X] T037 Add archive/restore and independent-new-chat coverage in `Packages/AgentsKit/Tests/AgentsKitTests/Integration/SessionLabelMutationTests.swift`.
- [X] T038 Add server-hosted project label mutation and isolation coverage in `Packages/AgentsKit/Tests/AgentsKitTests/Integration/SessionLabelMutationTests.swift`.
- [X] T039 [P] Update `docs/reference/agent-tools.md` for `start_agent`, `finish_turn`, `list_sessions`, and `list_my_agents` label behavior.
- [X] T040 [P] Add `docs/how-to/label-a-session.md` covering labels, ownership, suggestions, and `label:<value>` filtering.
- [X] T041 [P] Update `docs/reference/workflows.md` with the workflow `labels` front matter.
- [X] T042 [P] Update `docs/reference/statuses.md` with label chips on rows/cards and archive persistence.
- [X] T043 [P] Update `docs/how-to/archive-park-stop.md` to state that labels remain on archived sessions.
- [X] T044 [P] Build the `Agents` and `Remote` schemes from `Agents.xcodeproj/project.pbxproj`; resolve feature-related compilation failures.
- [X] T045 [P] Run `swift test --package-path Packages/AgentsKit` for `Packages/AgentsKit/Package.swift` and `scripts/docs.sh check` for the changed `docs/` pages; fix feature-related failures.

## Dependencies & execution order

### Phase dependencies

- Setup precedes Foundational because `SessionLabel` defines the shared value and policy.
- Foundational precedes all story phases because every surface stores the same session data.
- User Stories 1 and 2 both depend only on Foundational and can proceed in parallel after
  their distinct MCP/UI seams are agreed.
- User Story 3 depends on the label mutation paths from User Stories 1 and 2.
- User Story 4 depends on labels being available on records; its query and listing work can
  otherwise proceed independently.
- Polish follows the stories because archive/server validation and final documentation
  span their settled contracts.

### User story dependencies

- **US1 (P1)**: Depends on Foundational only; delivers the person-visible MVP.
- **US2 (P1)**: Depends on Foundational only; agent label inputs can be developed alongside
  person UI once the shared model is set.
- **US3 (P2)**: Depends on US1 person mutations and US2 agent mutations to prove the complete
  ownership matrix.
- **US4 (P2)**: Depends on Foundational labels; discovery and filtering can run alongside
  US1/US2 after the data model is stable.

### Parallel opportunities

- T007's mutation test and the API request design can proceed once the shared model exists.
- In US1, Mac surfaces (T012–T015) and Remote surfaces (T016–T018) touch separate files and
  can be implemented in parallel after T011.
- In US2, MCP start/finish work (T021–T024) and workflow settings/parsing (T025) use separate
  files; workflow propagation T026 follows its settings work.
- In US4, query model tests and MCP result-formatting can proceed in parallel after the
  shared label representation is stable.
- Documentation updates T039–T043 touch separate pages and can run in parallel.

## Implementation strategy

### MVP first

Complete Setup and Foundational, then User Story 1. This delivers person-entered labels on
Mac and Remote, session persistence, and live propagation. Validate the US1 independent
test before continuing.

### Incremental delivery

After the MVP, add US2 agent/workflow input, then US3 ownership refusals, then US4 discovery
and filtering. Finish with archive/server validation and docs. Keep each story's independent
check runnable before moving to the next.

## Completion summary

- **Total tasks**: 45
- **Setup/foundational**: 6
- **US1**: 12 (T007–T018)
- **US2**: 8 (T019–T026)
- **US3**: 4 (T027–T030)
- **US4**: 6 (T031–T036)
- **Polish**: 9 (T037–T045)
- **Parallel opportunities**: Mac/Remote UI, MCP/workflow surfaces, independent discovery
  surfaces, and documentation pages.
- **Independent story checks**: specified at the start of each user story phase.
- **Suggested MVP**: User Story 1, after the shared model and persistence foundation.
- **Format validation**: all implementation tasks use checkbox, sequential ID, optional
  `[P]`/`[USn]` markers where applicable, and explicit repository paths.
