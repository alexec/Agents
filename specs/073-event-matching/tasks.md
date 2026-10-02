# Tasks: Finer event matching, step 1

**Input**: [plan.md](plan.md), [spec.md](spec.md), [research.md](research.md), [data-model.md](data-model.md), [contracts/](contracts/), [quickstart.md](quickstart.md)

**Tests**: requested. Unit tests come with the matcher and its words, ahead of the readers. The
scratch-root walk is last.

**Order**, as asked for:
1. the matcher and its wording, with tests;
2. the readers and the daemon's details;
3. the page, the web page and Copy as trigger;
4. the docs and the walk.

## Phase 1: Setup

- [ ] T001 Confirm the baseline: run `swift test --package-path Packages/AgentsKit --filter 'EventPattern|EventCatalogue|WorkflowTrigger|EventWait|WaitStatus|AppService|WorkflowFile'` on the untouched branch, and note any failures that are already on main.

## Phase 2: Foundational — the matcher, the catalogue and their words

**⚠️ Every story depends on this phase.**

- [X] T002 Add `DetailFilter` in `Packages/AgentsKit/Sources/AgentsKitCore/Model/DetailFilter.swift`. Its rules:
  - It holds `values: [String]`, never empty. A list of one equals the single value.
  - It is `ExpressibleByStringLiteral`.
  - `matches(_ detail: String?, isSet: Bool)`: a missing detail never matches. A set detail is split on `,` and compared by `SessionLabelPolicy.key`. Otherwise the match is exact.
  - Its words: `label` joins with `|`, `capsule` joins with ` | `, and `yaml` is `[a, b]` for a list, each value through `EventPattern.yamlScalar`.
  - Codable: a string, or an array of strings.
- [X] T003 Add `EventDetail` in `Packages/AgentsKit/Sources/AgentsKitCore/Model/EventDetail.swift`. Its fields:
  - `key`, `isSet`, `isContext`;
  - `values: [String]?`;
  - old words, each matched exactly or by a fixed prefix or suffix, mapping to a code;
  - `words(for values: [String]) -> String`, per contracts/catalogue.md.
- [X] T004 Add `code` to `EndedReason` in `Packages/AgentsKit/Sources/AgentsKitCore/Model/EndedReason.swift`, and to `WorkflowRefusal` in `Packages/AgentsKit/Sources/AgentsKitCore/Model/WorkflowOutcome.swift`. Both are snake_case of the case name; FR-007 and FR-010 list the values.
- [X] T005 Change `EventKind` in `Packages/AgentsKit/Sources/AgentsKitCore/Model/EventCatalogue.swift`:
  - It takes `[EventDetail]`, and `details: [String]` becomes a computed list of keys.
  - Every agent kind and `cost.limit_reached` carry the context details.
  - `agent.finished` adds `afterwards`; `agent.parked`, `agent.archived` and `workflow.completed` add `outcome`.
  - Every fixed set comes from contracts/catalogue.md.
  - Add `detail(_ key:, in name:)`, and union lookups for `subject.*`.
  - `describe()` lists the fixed values, and says once that agent events carry the context.
- [X] T006 Change `EventPattern` in `Packages/AgentsKit/Sources/AgentsKitCore/Model/EventPattern.swift`:
  - `filters` becomes `[String: DetailFilter]`.
  - `matches` asks the catalogue for `isSet`. A `custom.` event is never a set.
  - `parse(_:filters: [String: DetailFilter])` maps old words to codes and checks values. The new `badValue(name:key:valid:given:)` problem names the first wrong value.
  - The bad-key sentence is kept.
  - Codable follows research R1: `filters` holds singles and lists joined by `|`, plus `anyOf`. The decoder maps old words.
  - `matching(_:)` leaves out `agent` and the context details, except on `custom.` events.
  - `asTrigger` writes inline lists.
  - `summary` uses each detail's words, with "and …" phrases last; `label` joins a list with `|`.
- [X] T007 Update callers that build patterns from `[String: String]` to compile:
  - `Packages/AgentsKit/Sources/AgentsKitCore/Model/WorkflowTrigger.swift`: the `patterns` filter and wire encode/decode, with lists as JSON arrays;
  - `Packages/AgentsKit/Sources/AgentsKitCore/Model/WorkflowTriggerWords.swift`: `filters` becomes `[String: DetailFilter]`;
  - `Packages/AgentsKit/Sources/AgentsKitCore/Model/WaitStatus.swift`: the agent filter.
- [X] T008 [P] Unit tests in `Packages/AgentsKit/Tests/AgentsKitTests/Unit/DetailFilterTests.swift`:
  - any of, a list of one, set matching with case and spaces, an empty labels detail, a missing detail;
  - the Codable forms.
- [X] T009 [P] Extend `Packages/AgentsKit/Tests/AgentsKitTests/Unit/EventPatternTests.swift`. Cover:
  - SC-001: each of T1, T2, T4, T6, T9, T10, T12, T14-less-except and W1 matches its event and not a near miss;
  - US4: a bad value, a list with one bad value, and an open detail accepting anything;
  - `subject.*` checked against the union;
  - old words mapped (US3 scenarios 2 and 3), and an unmappable old word refused;
  - the encoding: singles byte for byte as before (FR-028), and a list decoded by a stand-in for the old `[String: String]` decoder (FR-029);
  - `summary`, `label` and `asTrigger` for T1 and T4, including the asTrigger round trip (FR-024);
  - `matching` dropping `agent` and the context details (FR-025), with a `custom.` event kept whole.
- [X] T010 [P] Extend `Packages/AgentsKit/Tests/AgentsKitTests/Unit/EventCatalogueTests.swift`: `describe()` lists the values and the context line, and every agent kind carries the context details.
- [X] T011 Fix existing tests that build `EventPattern` from `[String: String]` variables. The literal forms keep compiling.

**Checkpoint**: the matcher and its words are done and tested. Commit.

## Phase 3: User Story 1 — labels, runtime, started_by, afterwards (P1) 🎯 MVP

**Goal**: agent events carry the agent's context, and `agent.finished` carries `afterwards`.

**Independent test**: an integration test finishes three fake-runtime agents, and only the one
labelled `bug` that parks fires T1.

- [X] T012 [US1] Change `agentDetails(_:)` in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+EventWaits.swift` to add:
  - `labels`: sorted label keys, comma-joined;
  - `runtime`: `agent.runtimeID`;
  - `started_by`: `agent` if `startedByAgent`, `workflow` if `startedByWorkflow`, else `person` (research R4).
- [X] T013 [US1] Add `afterwards` (`park` or `stay`, from `parkedNow`) in `raiseAgentEnding`, in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Events.swift`, and pass it from `move` in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore.swift`. Add `outcome` to `agent.parked` and `agent.archived` when the agent has a report.
- [X] T014 [US1] Add `outcome` to `workflow.completed` in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Workflows.swift`, from the run's agent's report.
- [X] T015 [US1] Integration test in `Packages/AgentsKit/Tests/AgentsKitTests/Integration/`, beside the existing event or workflow trigger tests. Cover:
  - the event carries labels, runtime, started_by and afterwards;
  - a label added after the event leaves the logged event unchanged;
  - T1 fires on a labelled agent that parks, and not otherwise.

## Phase 4: User Story 2 — any of, never dropped (P1)

**Goal**: all three readers take lists and refuse what they can't take.

- [X] T016 [US2] In `Packages/AgentsKit/Sources/AgentsKit/Workflows/WorkflowFile.swift`, read a sequence of scalars under a detail as a list, inline or as a block. Refuse anything else with `should be one value or a list of values`. Throw `badValue` problems with `problem.message`.
- [X] T017 [US2] Change `DaemonAPI.EventWaitRequest.where` to `[String: DetailFilter]?` in `Packages/AgentsKit/Sources/AgentsKitCore/Daemon/DaemonAPI+Events.swift`.
  - In `Packages/AgentsKit/Sources/AgentsKit/ACP/Serve/AppService.swift`, `eventCall` reads lists and refuses any other value with the FR-016 sentence.
  - In `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+EventWaits.swift`, `waitForEvent` resolves `agent` titles in each value.
- [X] T018 [P] [US2] Tests:
  - `WorkflowFile` lists, and `outcome: complete` as the problem (`Packages/AgentsKit/Tests/AgentsKitTests/Unit/`);
  - an `AppServiceTests` `where` list, and the refusal;
  - an `EventWaitTests` wait with a list that a `stuck` finish doesn't wake;
  - `WorkflowTriggerEventTests`: the wire round trip with a list, and an old reader dropping it.

## Phase 5: User Story 3 — codes, not sentences (P2)

- [X] T019 [US3] Raise codes in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Events.swift`, keeping each sentence's words:
  - `agent.failed reason`: `EndedReason.code`;
  - `agent.stopped by`: `you`, `cost_limit` or `unknown`.
- [X] T020 [US3] In `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore.swift`, `agent.archived by` becomes `you` or `agent`.
- [X] T021 [US3] In `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Workflows.swift`, `workflow.refused reason` becomes `WorkflowRefusal.code`.
- [X] T022 [US3] Update tests that asserted the old detail values (grep `"reason"`, `"by"` in `Packages/AgentsKit/Tests`), and add one asserting the sentence is unchanged.

## Phase 6: User Story 4 — wrong values named (P2)

Built in T006. The tests are in T009 and T018. This phase only checks the gaps.

- [X] T023 [US4] Check that a wait with a wrong value is refused with the same sentence as the file's problem: add it to `Packages/AgentsKit/Tests/AgentsKitTests/Integration/EventWaitTests.swift`.

## Phase 7: User Story 5 — words everywhere, and Copy as trigger (P3)

- [X] T024 [US5] Show each filter with `DetailFilter.capsule` in the Mac Triggers capsules, in `App/Sources/Projects/WorkflowPage.swift`. Copy as trigger (`App/Sources/Events/EventDetailView.swift`) already reads `EventPattern.matching`, which T006 changed.
- [ ] T025 [US5] Check the Remote: `Remote/Sources/Projects/WorkflowPage.swift` and `WorkflowsSection.swift` show `workflow.summary` from AgentsKitCore, so they need no change. Build the Remote scheme for the generic simulator to confirm it compiles.
- [X] T026 [US5] Add `Packages/WebTypes/Overrides/EventPattern.ts` and `DetailFilter.ts`, then run `scripts/web.sh types`.
- [X] T027 [US5] In `Web/src/model/workflows.ts`, `triggerSummary`, `triggerFilters` and `causePhrase` read lists. Filters are said in words as in contracts/catalogue.md: labels, runtime, outcome, afterwards, started_by, and the reason and `by` codes. Add web tests under `Web/test/`.
- [X] T028 [US5] Rebuild the page with `scripts/web.sh build`, then run `scripts/web.sh check`.
- [ ] T029 [US5] Add the 073 row to `specs/071-web-remote/walks/parity.md`.

## Phase 8: Docs, the walk, cleanup

- [X] T030 [P] Update the docs the spec names:
  - `docs/reference/events.md`
  - `docs/reference/workflows.md`
  - `docs/how-to/wait-for-something.md`
  - `docs/how-to/set-up-a-workflow.md`
  - `docs/reference/agent-tools.md`
- [ ] T031 Full `swift test --package-path Packages/AgentsKit`. Compare any failures with the T001 baseline.
- [ ] T032 Walk quickstart.md on a run-app scratch root: T1 fires on the match and not on the near misses, over the socket. Screenshot the workflow page by window id. Stop the root.
- [ ] T033 Mark the spec's Status, and delete `build/DD`.

## Dependencies

- Phase 2 blocks everything else.
- US1 (Phase 3) and US2 (Phase 4) are independent of each other.
- US3 depends only on Phase 2.
- US5 depends on Phase 2. Its walk (T032) depends on US1.

**Parallel**:
- T008, T009 and T010 can run together.
- T018's test files can run together.
- T030 can run alongside Phase 7.

## Implementation strategy

The MVP is Phase 2 and US1: T1 writable and firing. Then the readers (US2), the codes (US3), the
words (US5), and the docs. Commit at each checkpoint.
