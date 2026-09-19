---

description: "Task list for Cursor makes four"
---

# Tasks: Cursor makes four

**Input**: Design documents from `specs/006-cursor-cli-runtime/`

**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/, quickstart.md

**Tests**: Included, and not optional. Two existing tests go red the moment the catalog entry lands
(`RuntimeDiscoveryTests` counts to three, `LiveRuntimeTests` asserts every runtime advertises config
options), so fixing them is the work rather than an extra. The one behaviour change, unknown
notifications, cannot be triggered by any runtime on this Mac and is reachable only through the fake
agent.

**Organization**: By user story, in the priority order the spec sets. Each story is shippable on its
own.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: can run in parallel (different files, no dependency on unfinished work)
- Paths are exact

---

## Phase 1: Setup

- [ ] T001 Confirm `cursor-agent` is installed and signed in: `cursor-agent --version` reports 2026.09.10-fd3934a or later, `cursor-agent status` reports logged in, and `cursor-agent acp --help` prints its usage even though `acp` is absent from `cursor-agent --help`
- [ ] T002 Record the baseline before anything changes: `swift test --package-path Packages/AgentsKit` is green, and `AGENTS_LIVE=1 swift test --package-path Packages/AgentsKit --filter LiveRuntimeTests` is green over three runtimes. No source file is added by this feature, so `xcodegen generate` is not needed and `project.yml` is not touched

---

## Phase 2: Foundational (blocks every story)

**Purpose**: put Cursor on the list and keep the suite honest. Every story needs Cursor to exist, and
two tests assume it does not. The tests in this phase are not new coverage, they are the existing
suite learning to count to four.

**⚠️ T004 and T005 must land in the same change as T003.** The moment the catalog has a fourth entry,
both tests fail. Splitting them leaves the repository red.

- [ ] T003 Add the Cursor entry to `Packages/AgentsKit/Sources/AgentsKit/Runtimes/RuntimeCatalog.swift`: `id: "cursor"`, `name: "Cursor"`, `executable: "cursor-agent"`, `arguments: ["acp"]`, and add it to `builtIn`. The executable MUST be `cursor-agent` and MUST NOT be `agent`, which on this Mac is Grok. Extend the type's doc comment, which today explains why Claude needs npm, to say that Cursor is itself and hides its `acp` subcommand from its own help
- [ ] T004 Update `Packages/AgentsKit/Tests/AgentsKitTests/Unit/RuntimeDiscoveryTests.swift`: the assertion `#expect(statuses.count == 3)` at line 35 becomes 4, and add a case asserting Cursor is located by its own binary name, matching the per-runtime recipe cases already at lines 24-31
- [ ] T005 Correct the `configOptions` assertions in `Packages/AgentsKit/Tests/AgentsKitTests/Live/LiveRuntimeTests.swift` lines 39-42. `#expect(!advertised.isEmpty)` and `#expect(advertised.contains { $0.category == "model" })` must hold only for a runtime that advertises options at all. Cursor advertises none; it puts its models in `session/new`, which `ACPTypes.swift:247` deliberately does not decode for any runtime. Fix the rule for every runtime, never with a branch on Cursor's id
- [ ] T006 [P] Update the comment at `Packages/AgentsKit/Tests/AgentsKitTests/Live/LiveRuntimeTests.swift` lines 18-19, which reads "One code path, three runtimes", to say four. It is the standing claim this whole feature is shaped around, so it should count correctly
- [ ] T007 [P] Add the Cursor recipe to the `RUNTIMES` dictionary in `scripts/acp-handshake.sh` lines 14-18 (`"cursor": ["cursor-agent", "acp"]`). This script keeps its own copy of the recipes, separate from `RuntimeCatalog`, so without this it cannot probe the runtime this feature adds

**Checkpoint**: Cursor is on the list, the suite is green over four runtimes, and the by-hand probe can reach it.

---

## Phase 3: User Story 1 - Start an agent on Cursor (Priority: P1) 🎯 MVP

**Goal**: a user with Cursor installed and signed in picks it from the runtime list and works with it
exactly as they work with the other three.

**Independent Test**: start an agent on Cursor, send a prompt that reads and edits a file, and confirm
the transcript, the diff and the turn's cost have the same shape as the same prompt on Claude.

**Why there is almost no code here**: nothing in `Packages/AgentsKit/Sources` or `App/Sources`
branches on a runtime id, verified by grep. The picker, the daemon's account map, session start,
pick-up, adopt, the agent row and the session list all read `RuntimeCatalog`. This story is therefore
mostly proving that claim rather than writing to it, and every task below that fails is a bug in the
claim.

- [ ] T008 [US1] Run the live suite over all four runtimes: `AGENTS_LIVE=1 swift test --package-path Packages/AgentsKit --filter LiveRuntimeTests`. Cursor must start, hand back `protocolVersion == 1`, report `supportsLoad == true`, answer a prompt and be picked up again. Any `if` on a runtime id needed to make this pass means the design in plan.md decision 2 is wrong and the plan must be revisited before continuing
- [ ] T009 [US1] Run `AGENTS_LIVE=1 swift test --package-path Packages/AgentsKit --filter GrokServedToolsTests`, whose `everyRuntimeStillStartsWithEverythingAdvertised` case at line 74 loops over `RuntimeCatalog.builtIn`. Confirm Cursor still starts with every client capability advertised, including the file and terminal ones 003 turned on
- [ ] T010 [US1] By hand in the app: start an agent on Cursor in a scratch folder, send a prompt that reads a file and edits it. Confirm the reply streams, the tool call asks permission before writing, the edit arrives as a diff, and the agent appears under its project. Quickstart steps 1 and 2
- [ ] T011 [US1] Confirm what Cursor reports about tokens and cost reaches the record as reported, per currency, with nothing estimated, and that an agent showing no cost is because Cursor sent none rather than because the app dropped it
- [ ] T012 [US1] Confirm no model or mode is shown for a Cursor agent, and that this is the existing gate rather than a new one: Cursor sends `models` and `modes` on `session/new`, which are not decoded for any runtime, and sends no `configOptions` and no `providers`. Quickstart step 2
- [ ] T013 [US1] Confirm attachments respect what Cursor takes: a picture goes by value because `image` is true, a file goes as a `resource_link` because `embeddedContext` is false, and neither is refused. The choice is made at `App/Sources/Chat/PromptBar.swift:332-338`. Quickstart step 5
- [ ] T014 [US1] Confirm the roughly twenty commands Cursor sends unprompted as `available_commands_update` reach the prompt bar and are offered when the user types `/`, through the existing path in `App/Sources/Chat/PromptBar.swift:405-415`
- [ ] T015 [US1] Confirm a Cursor agent survives a restart of the window, and then of the daemon (`pkill -f agentsd`), resuming rather than starting over, which Cursor supports because it advertises `loadSession`. Quickstart step 7

**Checkpoint**: Cursor is a runtime of this app, start to finish. This is shippable on its own.

---

## Phase 4: User Story 2 - Say plainly why it cannot be used (Priority: P2)

**Goal**: a user without Cursor, or with it but signed out, is told which of those two it is and what
to do, and is never sent to the wrong command.

**Independent Test**: with `cursor-agent` off the path, confirm the runtime shows as missing and names
where the app looked. Then confirm no instruction the app can show names a binary the app does not
start.

- [ ] T016 [US2] Confirm the missing case with `cursor-agent` temporarily off `PATH`: the runtime list shows Cursor as missing and names the directories searched, exactly as a missing Grok or Copilot does, through the existing `RuntimeAvailability.missing(lookedIn:)`. Quickstart step 1 in reverse
- [ ] T017 [US2] Fix the description hazard at `App/Sources/Runtimes/RuntimeAccountView.swift:35-36`, which renders `method.description` verbatim. Cursor's `cursor_login` description reads "Authenticate using existing Cursor login credentials. Run 'agent login' first if not logged in", and `agent` on this Mac is Grok. Either present the description plainly as the runtime's own words rather than as an instruction to follow, or suppress the sentence that gives a command. The rule is FR-005a: any command the app puts in front of a user is built from the catalog entry, and it must be right for every runtime rather than rewritten for Cursor
- [ ] T018 [P] [US2] Test the rule from T017 in `Packages/AgentsKit/Tests/AgentsKitTests/Unit/RuntimeAccountTests.swift`: an auth method whose description names a command MUST NOT produce a command the app tells the user to run. Drive it with Cursor's exact description text as data, naming no runtime in the code path
- [ ] T019 [US2] Confirm signing out is not offered for Cursor and that this is the existing capability gate: Cursor advertises no logout, so `RuntimeAccount.canLogOut` is false. Confirm the provider picker is likewise absent because it advertises no providers. Quickstart step 6
- [ ] T020 [US2] Confirm a `-32000` from a session method still maps to "needs signing in", the mapping 003 decided in its research section 9, and that the state is refreshed on the next handshake without restarting the app. Do this against the fake agent, not by signing out of Cursor

**Checkpoint**: the app is honest about Cursor whether or not it can be used, and points only at commands that work.

---

## Phase 5: User Story 3 - Answer the questions Cursor asks (Priority: P3)

**Goal**: nothing Cursor sends can hang a turn or vanish without trace.

**Independent Test**: drive the fake agent to send a notification with a method nobody knows and
confirm it is reported rather than dropped; run a real Cursor turn that triggers `cursor/create_plan`
and confirm it reaches `end_turn`.

**What research settled**: the first scenario of this story is already true for requests.
`ACPSession.handleIncoming` declines an unknown method with `-32601` at lines 449-450, deliberately,
and a Cursor turn answered that way runs to `end_turn` while one left unanswered does not finish. The
gap is notifications, and it belongs to every runtime rather than to Cursor.

- [ ] T021 [US3] Add `case unknownNotification(String)` to `ACPSessionEvent` in `Packages/AgentsKit/Sources/AgentsKit/ACP/ACPSession.swift`, beside the existing `unknownUpdate(String)`
- [ ] T022 [US3] Stop dropping unknown notifications in `ACPSession.receive` at `Packages/AgentsKit/Sources/AgentsKit/ACP/ACPSession.swift:398`. Today `guard method == ACP.ClientMethod.sessionUpdate ... else { return }` discards every other method with no log and no event. Yield `.unknownNotification(method)` before returning. It MUST name no runtime: `cursor/update_todos` and a method invented next year arrive at the same place
- [ ] T023 [US3] Handle the new event in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore.swift` beside the `unknownUpdate` case at lines 248-249, writing one `DaemonLog` line naming the method. It MUST NOT reach `agent.json` or the transcript: an unknown notification is a fact about a runtime, not part of the user's conversation, which is how `unknownUpdate` is already treated
- [ ] T024 [P] [US3] Teach `Packages/AgentsKit/Tests/AgentsKitTests/Fake/FakeACPAgent.swift` to send a notification with an arbitrary method name, so the behaviour above can be driven at all. No runtime on this Mac sends one reliably
- [ ] T025 [US3] Test in `Packages/AgentsKit/Tests/AgentsKitTests/Integration/ACPSessionTests.swift`, beside the unknown-update assertion at lines 191-192: a notification with an unrecognised method yields `unknownNotification` carrying the method name, and does not disturb the session. Assert the negative too, that nothing is written to the transcript
- [ ] T026 [P] [US3] Confirm the existing request behaviour still holds with a test in `Packages/AgentsKit/Tests/AgentsKitTests/Integration/ServingTests.swift`, beside the "declined loudly" assertion at line 175: a request with a vendor-namespaced method the app does not know is answered `-32601` immediately, never left open. Use a method name shaped like `cursor/create_plan` as data
- [ ] T027 [US3] By hand, prove the turn survives: send a Cursor agent "Add a docstring to hello.py, then add a second function, then write a test for it. Plan the work first." Confirm a plan is drawn from the normal `session/update`, that `daemon.log` records `cursor/create_plan` being declined, and that the turn reaches its end. Quickstart step 3
- [ ] T028 [US3] Try once more to provoke `cursor/ask_question`, which did not fire in either research probe. If it appears, record what it sends in `specs/006-cursor-cli-runtime/research.md` section 4 and stop: mapping it onto the elicitation stack 003 finished is a decision to take with the evidence in hand, not a task to start speculatively. If it does not appear, record that too, so the next person does not repeat the search

**Checkpoint**: nothing Cursor sends is lost, and nothing it sends can hold a turn open.

---

## Phase 6: Polish & cross-cutting

- [ ] T029 [P] Add Cursor to the runtime list in `README.md`, which describes what the app does with a runtime and names the ones it knows
- [ ] T030 [P] Update `specs/006-cursor-cli-runtime/research.md` with anything implementation disproved, particularly if `cursor/ask_question` appeared or if the `-32601` behaviour differs on a later `cursor-agent`. The research is dated and version-stamped on purpose
- [ ] T031 Walk the whole of `specs/006-cursor-cli-runtime/quickstart.md` by hand, all eight steps plus the by-hand probe, and fix what does not match
- [ ] T032 Run the full suite one last time, unit and live, over four runtimes, and confirm the three existing runtimes behave exactly as before (SC-006)

---

## Dependencies & Execution Order

### Phase dependencies

- **Setup (Phase 1)**: no dependencies
- **Foundational (Phase 2)**: needs Setup. Blocks every story, because no story is testable until Cursor is on the list
- **User stories (Phases 3 to 5)**: all need Phase 2. After that they are independent of each other
- **Polish (Phase 6)**: needs whichever stories are being shipped

### Story dependencies

- **US1 (P1)**: needs only Phase 2. Shippable alone, and is the MVP
- **US2 (P2)**: needs only Phase 2. Independent of US1, though T016 is easier to judge once US1 has been seen working
- **US3 (P3)**: needs only Phase 2. The one story with real code in it, and the only one whose change affects the other three runtimes

### Inside Phase 2

T003, T004 and T005 land together or the repository is red. T006 and T007 are marked [P] because they
touch a comment and a shell script and cannot break a build.

### Parallel opportunities

This is a small feature and most of it is sequential verification of one runtime on one Mac. Genuine
parallelism:

- T006 and T007 alongside T003 to T005
- T018 alongside T017's implementation, in a different file
- T024 and T026 alongside T021 to T023, in test files
- T029 and T030 alongside anything

Three developers would get in each other's way. One is the right number.

---

## Parallel Example: Phase 2

```bash
# After T003 to T005 are written together, these two touch nothing that can break a build:
Task: "Update the three-runtimes comment in Live/LiveRuntimeTests.swift"
Task: "Add the cursor recipe to scripts/acp-handshake.sh"
```

---

## Implementation Strategy

### MVP: User Story 1 only

1. Phase 1, then Phase 2 in one change
2. Phase 3
3. **Stop and validate**: a Cursor agent does real work and survives a restart
4. This is worth shipping. Cursor is a runtime of the app, and the two remaining stories are honesty
   and robustness rather than capability

### Incremental

1. Phase 2 → Cursor exists, suite green over four
2. US1 → Cursor works → ship
3. US2 → the app is honest about it, and never points at Grok's binary → ship
4. US3 → nothing it sends is lost → ship

US3 is last by priority but it is the only phase that changes behaviour for Claude, Grok and Copilot
as well. If the silent drop at `ACPSession.swift:398` matters more than Cursor does, it can be lifted
out and done on its own, before any of this.

---

## Notes

- No source file is created by this feature. Four are edited, plus four test files, a shell script and
  the README
- The one rule that governs every task: no code path may branch on a runtime's identity. It is written
  into `LiveRuntimeTests.swift:18-19` and it is why there is no `cursor/` handler here
- Commit after each phase. Phase 2 is one commit, not five
