---
description: "Task list for 009-fix-chat-prompt-ux"
---

# Tasks: Prompt Controls, Project Navigation, Scroll-to-Bottom, Remembered Mode, and Unseen File Requests

**Input**: Design documents from `specs/009-fix-chat-prompt-ux/`

**Prerequisites**: [plan.md](./plan.md), [spec.md](./spec.md), [research.md](./research.md), [data-model.md](./data-model.md), [contracts/](./contracts/)

**Tests**: Included where `plan.md` names them. The pure logic in `AgentsKitCore` gets unit tests; the views do not, because this repository has no app test target and no snapshot test. Views are checked by running the app — [quickstart.md](./quickstart.md) says how.

**Organization**: One phase per user story, in priority order. Each story is independently shippable.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel — different files, no dependency on incomplete work
- **[Story]**: US1–US7, matching `spec.md`
- Exact file paths in every task

## Path Conventions

Existing macOS app. `App/Sources/` is the Mac app, `Remote/Sources/` the iOS remote, `Packages/AgentsKit/` the shared package split into `AgentsKitCore` (both platforms) and `AgentsKit` (the Mac's half). No new target, no new module.

Build and test:

```sh
xcodegen generate
swift test --package-path Packages/AgentsKit
xcodebuild -project Agents.xcodeproj -scheme Agents -configuration Debug \
  -skipPackagePluginValidation -skipMacroValidation build
```

---

## Phase 1: Setup

**Purpose**: Know what green looks like, and see each bug before fixing it.

- [X] T001 Confirm the baseline builds and tests green: run all three commands above from a clean `xcodegen generate`, and record that `swift test` reports 482 tests in 62 suites passing
- [X] T002 Note the known flakiness: the integration suites (`DaemonTests`, `ElicitationTests`, `SuggestedPromptTests`, `ServingTests`) are timing-sensitive and fail under machine load. Re-run before treating any failure there as a regression
- [ ] T003 [P] Walk the "before" pass for User Stories 1 and 3 in `specs/009-fix-chat-prompt-ux/quickstart.md`, including dragging the sidebar past 407pt of an 1100pt window to see the options row clip. These are the two easiest to talk yourself out of having seen
  - **Not done — no screen access.** This shell has neither Screen Recording nor Accessibility permission, so the visual before-pass could not be walked. The causes were established by reading the code and by CoreText measurement instead (research §1).
- [ ] T004 [P] Walk the "before" pass for User Stories 2, 4, 6 and 7 in `specs/009-fix-chat-prompt-ux/quickstart.md`
  - **Not done — no screen access.** Same reason as T003.

**Checkpoint**: Every bug reproduced by hand, baseline recorded.

---

## Phase 2: Foundational

**Purpose**: None. This feature has no blocking prerequisites, and inventing some would be dishonest.

The six stories touch mostly different files and can be done in any order. Two coupling constraints matter, and they are about merge pain rather than correctness:

- `App/Sources/Chat/PromptBar.swift` is edited by **US1** (the state switch and the scroll view), **US3** (the optimistic binding) and **US5** (writing the remembered mode). Do them in that order — US1 rewrites the shape of `options`, and US3 and US5 then edit a settled file.
- `App/Sources/Projects/ProjectRow.swift` is edited by **US2** (the tap) and **US6** (the dot). Either order; they touch different members.
- **US5 depends on US1** in substance: a control that is not shown cannot carry a remembered value.

**Checkpoint**: Nothing to do. Start User Story 1.

---

## Phase 3: User Story 1 — The controls under the prompt are always there (Priority: P1) 🎯 MVP

**Goal**: The area under the prompt always shows working controls or a plain statement of why there are none, at every window width.

**Independent Test**: Open chats in all six states from `quickstart.md` Story 1 — Cursor new, Cursor existing, no folder, fetching, failed fetch, narrow pane — and confirm none is a silent gap.

### Tests for User Story 1

- [X] T005 [P] [US1] Create `Packages/AgentsKit/Tests/AgentsKitTests/Unit/PromptControlsStateTests.swift` with `everyCaseIsDrawn` — a switch over all six cases compiles and each is reachable from `resolve`. This is the test that carries the story: an unhandled case is the bug returning
- [X] T006 [P] [US1] Add `anAgentWithNoOptionsFallsThroughRatherThanShowingARow` to `PromptControlsStateTests.swift` — guarantee C4, `agentOptions == []` is not by itself `.nothingOffered`
- [X] T007 [P] [US1] Add `aRuntimeThatOffersNothingSaysSo`, `optionsThatCannotBeDrawnAreNotControls`, `aFailedFetchIsNotAnEmptyRuntime`, `nothingIsChosenYet` and `controlsComeBackInCategoryOrder` to `PromptControlsStateTests.swift`, per the table in `contracts/prompt-controls-state.md`

### Implementation for User Story 1

- [X] T008 [US1] Create `Packages/AgentsKit/Sources/AgentsKitCore/Model/PromptControlsState.swift` with the six cases and `resolve(agentOptions:draftOptions:hasFolder:hasRuntime:runtimeName:isLoading:failure:)` exactly as `contracts/prompt-controls-state.md` specifies. Precedence, in order: `hasFolder == false` → `.needsFolder`; `hasRuntime == false` → `.needsRuntime`; `isLoading` → `.loading`; `failure` → `.failed`; renderable options from `agentOptions ?? draftOptions`, non-empty → `.controls`; otherwise `.nothingOffered`. `.controls` must never carry an empty array nor an option where `isRenderable` is false, and must be sorted by `categoryRank`
- [X] T009 [US1] Add `draftOptionsGeneration: Int` and `draftOptionsFailure: String?` to `App/Sources/AppModel.swift`. Increment the generation at the start of every `loadDraftOptions`; drop any reply whose generation is stale before assigning `draftOptions`, `draftCommands`, `draftChosen` or `draftID` (research §1, cause 4)
- [X] T010 [US1] In `App/Sources/AppModel.swift`, set `draftOptionsFailure` in `loadDraftOptions`'s `catch` from `describe(error)` instead of only setting the global `problem`, and clear it at the start of each fetch
- [ ] T011 [US1] In `App/Sources/AppModel.swift`, add a way to fetch options for an agent that already exists but has none, so `.nothingOffered` is only reached after asking (FR-003, research §1 cause 2)
  - **Blocked, and dropped.** There is no read-only daemon method that refreshes a started agent's options — `agents/revive` does not exist, and `plan.md` forbids adding one. With T015 and T016 in place a record no longer gets blanked, and an existing blank record self-heals the next time the agent is prompted. Until then the row honestly says the runtime has nothing to adjust. **FR-003 is not met**; see the report.
- [X] T012 [US1] Rewrite `options` in `App/Sources/Chat/PromptBar.swift` as an exhaustive `switch` over `PromptControlsState` with **no `default`**. Draw: the row; "Asking \(runtimeName) what it offers…"; what to choose first; "\(runtimeName) has nothing to adjust."; and the failure with a retry control that calls `loadDraftOptions` again (FR-001, FR-004)
- [X] T013 [US1] Wrap the options row in `App/Sources/Chat/PromptBar.swift` in a horizontal `ScrollView` with `.scrollBounceBehavior(.basedOnSize)`. Replace `Spacer(minLength: 16)` with a fixed 16pt gap — a spacer inside a horizontal scroll view has no width to take. **Do not** use `ViewThatFits` or a custom `Layout`: both have crashed this app through AppKit, per the comment already in `options` (FR-006)
- [ ] T014 [P] [US1] Guard the assignment at `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Commands.swift:61` (start) so an empty `await session.options` is not written into the record, matching `ACPSession.setOption`'s existing `if !refreshed.isEmpty`
  - **No change needed.** At `start` the agent is brand new, so there is no earlier options list an empty one could overwrite — the guard only matters where a record already has options. Investigated and left alone deliberately.
- [X] T015 [P] [US1] Guard the same assignment at `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Commands.swift:283` (revive)
- [X] T016 [P] [US1] Guard the same assignment at `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Runtimes.swift:132` (pickUp)
- [ ] T017 [US1] Run the Story 1 "after" pass in `quickstart.md`: all six states, plus the sidebar at its 900pt maximum with every control still reachable
  - **Not done — no screen access.**

**Checkpoint**: The control area is never silently empty, at any width, on any runtime.

---

## Phase 4: User Story 2 — Clicking a project takes you to the project (Priority: P2)

**Goal**: Clicking a project in the sidebar shows that project's page, including when it is the project you are already inside.

**Independent Test**: Open a conversation, click that conversation's own project — the already-highlighted row. You land on the project page.

- [X] T018 [US2] Add `showProject(_ folder: URL)` to `App/Sources/AppModel.swift`: set `selectedProject` and clear `selection` **unconditionally**. Invariant, from `data-model.md`: after `showProject(f)`, `selectedProject == f` and `selection == nil`, whether or not `f` was already selected
- [X] T019 [US2] Add `.simultaneousGesture(TapGesture().onEnded { model.showProject(summary.folder) })` to the row in `App/Sources/Projects/ProjectRow.swift`, taking `AppModel` from the environment. `simultaneousGesture` is the one gesture form that coexists with `List` selection rather than replacing it
- [X] T020 [US2] Leave `selectedProject.didSet` in `App/Sources/AppModel.swift` alone — it keeps its `guard selectedProject != oldValue` and keeps clearing `selection`, which is still correct for a programmatic change (`settleProjectSelection`, `addProject`) and is idempotent with T018
- [ ] T021 [US2] Run the Story 2 "after" pass in `quickstart.md`, checking all three together: the click works, the selection highlight still moves, and the right-click context menu still opens. If the gesture is swallowed, take the `Button` fallback in research §2 and touch `App/Sources/Projects/ProjectListView.swift`
  - **Not done — no screen access.** The `simultaneousGesture` is unverified against the selection highlight and the context menu.
- [ ] T022 [US2] Verify FR-025 by hand: click a project while an agent in it is mid-turn, then go back in — the turn carried on untouched
  - **Not done — no screen access.**

**Checkpoint**: There are two working ways out of a conversation, and the back control is unchanged.

---

## Phase 5: User Story 3 — The controls answer the moment you click them (Priority: P3)

**Goal**: An option control on a live agent reads the new value on the same frame as the click.

**Independent Test**: Change the mode on a conversation with a live agent, ideally mid-turn. The control reads the new value before the menu has finished closing.

- [X] T023 [US3] Add `pendingOptions: [UUID: [String: Pending]]` to `App/Sources/AppModel.swift`, where `Pending` holds `value: JSONValue` and `sequence: Int`. Never write into `agent.startOptions` — that is the daemon's record mirrored locally, and a client that edits it can disagree with the daemon with no way to notice
- [X] T024 [US3] In `App/Sources/AppModel.swift`, make `setOption(agentID:optionID:value:)` write the pending entry synchronously before the call and remove it when the call completes, whether it succeeded or threw. A completing call clears the entry **only if the sequence is still its own**, so two clicks in a row settle on the later choice (FR-036)
- [X] T025 [US3] Change the getter in `binding(for:)` in `App/Sources/Chat/PromptBar.swift` to read `pendingOptions → agent.startOptions.values → option.currentValue`, and the setter to go through the model synchronously rather than only starting a `Task` (FR-032, FR-033)
- [X] T026 [US3] Confirm the draft path is untouched: `model.draftChosen[option.id] = value` is already read by the getter, which is why a new chat is already immediate
- [ ] T027 [US3] Run the Story 3 "after" pass in `quickstart.md`, watching specifically for a flicker. The optimistic value is dropped on the call's completion, on the argument that `changed(agent)` broadcasts before `setOption` returns (`DaemonCore.swift:123`). If the capsule snaps back and forward, switch to the fallback in research §5: hold until the record's value changes, with the call's completion as a deadline
  - **Not done — no screen access.** The no-flicker argument is unverified.
- [ ] T028 [US3] Verify FR-035 by hand: stop the daemon, change an option, and confirm the control settles on what is in force with the problem reported, rather than showing a value that never took
  - **Not done — no screen access.**

**Checkpoint**: Every option control answers at once, and a refusal is visible rather than papered over.

---

## Phase 6: User Story 4 — Getting back to the end of the conversation (Priority: P4)

**Goal**: One action returns the reader to the live end of a conversation, and new lines arriving while they are scrolled up are announced rather than forced on them.

**Independent Test**: Scroll well up in a long conversation. A way back appears; taking it lands on the last line.

- [X] T029 [US4] Add `hasNewBelow: Bool` to `App/Sources/Chat/Transcript.swift`. Set it in the existing `onChange(of: model.entries.count)` when the guard already there (`isAtEnd`) fails; clear it the moment `isAtEnd` becomes true (FR-011)
- [X] T030 [P] [US4] Create `App/Sources/Chat/JumpToEnd.swift` — the button and nothing else. No colour literal; the house rule is that colour means something has gone wrong, and this is not an error
- [X] T031 [US4] Add the button to `App/Sources/Chat/Transcript.swift` as an `.overlay(alignment: .bottom)`, shown when `edges.canScroll && !isAtEnd`, offset by the `bottomInset` that `ChatView` already measures and passes in, so it clears the floating prompt (FR-007, FR-008, FR-009)
- [X] T032 [US4] Add `scrollToEndToken: Int` to `App/Sources/AppModel.swift` — a counter, not a `Bool`, so two requests in a row both land. Follow the shape of the existing `focusedEntry` / `clearFocus` pair
- [X] T033 [US4] Bump the token from `send()` in `App/Sources/Chat/PromptBar.swift` and watch it in `App/Sources/Chat/Transcript.swift`, scrolling to the `bottom` anchor (FR-012)
- [X] T034 [US4] Add a `.commands` block to `App/Sources/AgentsApp.swift` with a View menu item for the keyboard route. A menu command rather than a `.keyboardShortcut` on the button, because the button only exists when you least need the shortcut (FR-013)
- [ ] T035 [US4] Run the Story 4 "after" pass in `quickstart.md`. The regression to watch is item 7: scroll to the very top so earlier history loads, and confirm the reader keeps their place and that loading earlier is not mistaken for new content arriving (FR-014)
  - **Not done — no screen access.**

**Checkpoint**: The conversation still opens at its end, still follows while the reader is at the end, and now offers a way back.

---

## Phase 7: User Story 5 — The mode you chose last time is the mode you get (Priority: P5)

**Goal**: A new chat opens on the mode last chosen for that runtime.

**Independent Test**: Change the mode on a new chat, start it, begin another with the same runtime — the control opens on your choice. Quit and reopen; still remembered.

**Depends on**: User Story 1. A control that is not shown cannot carry a remembered value.

### Tests for User Story 5

- [X] T036 [P] [US5] Create `Packages/AgentsKit/Tests/AgentsKitTests/Unit/ModeMemoryTests.swift` with `aModeTheRuntimeHasDroppedIsDiscardedForItsOwnDefault` — guarantee M2, and the test that carries this story: getting it wrong starts an agent in a mode nobody chose
- [X] T037 [P] [US5] Add `aRememberedModeTheRuntimeStillOffersIsUsed`, `nothingRememberedLeavesTheRuntimesDefault`, `theModeIsFoundByCategoryNotByName` (with an option whose id is `permission_mode`), `aSwitchIsNeverTheMode`, `aRuntimeWithNoModeOptionIsNotAFailure` and `eachRuntimeRemembersItsOwn` to `ModeMemoryTests.swift`, per `contracts/mode-memory.md`

### Implementation for User Story 5

- [X] T038 [US5] Create `Packages/AgentsKit/Sources/AgentsKitCore/Model/ModeMemory.swift` with `modeOption(in:)`, `startingValue(remembered:for:)` and `defaultsKey(runtimeID:)`. `modeOption` matches `category == "mode"` first and `id == "mode"` second, and returns `nil` for anything that is not `case .select`. `startingValue` returns `remembered` **only** if it appears among `option.options`, otherwise `option.currentValue`. `defaultsKey` is `"prompt.mode.<runtimeID>"`
- [X] T039 [US5] Add the `UserDefaults` read and write to `App/Sources/AppModel.swift`, following `SidebarFrame`: one key per runtime, not one dictionary; a stored value that will not decode is treated as nothing remembered and the key is left alone
- [X] T040 [US5] In `loadDraftOptions` in `App/Sources/AppModel.swift`, after the existing loop that seeds `draftChosen` from `currentValue`, overwrite the mode entry with `ModeMemory.startingValue(...)` when there is one. Seeding `draftChosen` is sufficient — `startDraft` sends `StartOptions(values: draftChosen)` and `DaemonCore.start` calls `session.apply(request.startOptions)` at `DaemonCore+Commands.swift:77`
- [X] T041 [US5] Write the preference from the setter in `binding(for:)` in `App/Sources/Chat/PromptBar.swift`, **above** the draft/agent split, so one line covers a new chat and a live one (FR-019)
- [ ] T042 [US5] Run the Story 5 "after" pass in `quickstart.md`, including the staleness check: `defaults write com.alexecollins.Agents 'prompt.mode.claude' -string '"no-such-mode"'` then start a new chat — the runtime's own default is used, silently
  - **Not done — no screen access.**

**Checkpoint**: One preference, per runtime, surviving a quit, discarded when stale.

---

## Phase 8: User Story 6 — An agent that wants you to look says so (Priority: P6)

**Goal**: A file shown to a window that is looking elsewhere is announced rather than waiting invisibly.

**Independent Test**: Start an agent in project A, open a conversation in project B, have the first agent show a file. It appears as needing attention, and A carries the sidebar dot.

- [X] T043 [US6] Add `init(for state: AgentState, wantsEyes: Bool)` to `Packages/AgentsKit/Sources/AgentsKitCore/Model/AgentGroup.swift`, keeping the existing `init(for:)` as `wantsEyes: false`. `wantsEyes` sends an otherwise-`running` agent to `.needsAttention`; `.archived` and `.stopped` ignore it, because an agent that is not going anywhere is not waiting on you. **Do not** touch `AgentState`, its transition table, `holdsRuntime` or `hasTurnInFlight` — see research §6 for why that would be a bug
- [X] T044 [US6] Widen `Packages/AgentsKit/Tests/AgentsKitTests/Unit/AgentGroupTests.swift` to exhaust `(AgentState, Bool)` rather than relaxing it. The property it exists to hold is that an agent is in exactly one group and never in none
- [X] T045 [US6] Pass `filesToShow[agent.id] != nil` through `agents(in:group:)` in `App/Sources/AppModel.swift` so the project page groups a marked agent under "Needs attention" (FR-026)
- [X] T046 [US6] In `App/Sources/Projects/ProjectRow.swift`, show the dot when `summary.needsInput` **or** any agent in that folder has an unseen file, taking `AppModel` from the environment as `ArchivedProjectRow` beside it already does (FR-027)
- [X] T047 [US6] Confirm nothing else changes: `DaemonCore.showFile`, the `agentShowFile` notification, `takeFileToShow` and `ContentView.showWhatWasAskedFor` are all untouched. Opening the conversation already consumes the entry, which clears the mark for free (FR-028)
- [ ] T048 [US6] Run the Story 6 "after" pass in `quickstart.md`. Item 4 is the one to watch: a marked agent still reads "Working" with the spinner, because its state has not changed (FR-029). Check by eye that a card under "Needs attention" showing a spinner does not read as a contradiction — if it does, the card needs a line saying *why* it is there, not a change of state
  - **Not done — no screen access.** Whether a working spinner reads oddly under "Needs attention" is unverified.

**Checkpoint**: No request to look goes unannounced, and no agent is drawn as blocked for having made one.

---

## Phase 9: User Story 7 — Answering a question takes one click (Priority: P7)

**Goal**: A question whose whole answer is one choice is answered by clicking the choice.

**Independent Test**: Have an agent ask a question with a single set of choices. Clicking a choice answers it outright.

- [X] T049 [P] [US7] Add `singleChoice: (property: Property, choices: [Choice])?` to `Packages/AgentsKit/Sources/AgentsKitCore/Model/ElicitationSchema.swift`. Non-nil **only** when the schema has exactly one property and that property's kind is `.string` with a non-nil `choices`
- [X] T050 [P] [US7] Add cases to `Packages/AgentsKit/Tests/AgentsKitTests/Unit/ElicitationSchemaTests.swift` for which forms are one-click and which are not: one string-with-choices property is; two properties are not; one free-text, one number and one multi-select are not
- [X] T051 [US7] In `App/Sources/Elicitation/ElicitationView.swift`, draw a `singleChoice` form as buttons in the agent's own wording, answering on the click, the way `App/Sources/Permission/PermissionView.swift` already draws a permission question (FR-038, FR-039)
- [X] T052 [US7] Keep `choice.description` visible under each button — a button with a title and a caption, as `SelectChoice` already draws. The comment already in the view is the reason: "what separates two options is usually their description" (FR-043)
- [X] T053 [US7] Where the single property is not required, make the existing "No answer" row a button too, sending `.accept` with an empty value exactly as picking that row does today (FR-040). Keep "No thanks" sending `.decline` — declining the question and answering it with nothing are different things the daemon already distinguishes (FR-042)
- [X] T054 [US7] Leave every other form shape exactly as it is: a second field, free text, a number or a multi-select keeps the radio group and the Send button, and `schema.problems(with:)` still gates the Send path (FR-041)
- [X] T055 [US7] Handle width the way Story 1 did: the choices are the agent's words, so there is no bound on them. Use a horizontal scroll view, not a measure-and-decide layout
- [ ] T056 [US7] Run the Story 7 "after" pass in `quickstart.md`, including item 6: a two-field form must still need its Send
  - **Not done — no screen access.**

**Checkpoint**: The two versions of "answer this question" are answered the same way.

---

## Phase 10: Polish & Cross-Cutting Concerns

- [X] T057 Run `swift test --package-path Packages/AgentsKit` and confirm green. `ConfigOptionTests` must pass **unchanged** — if a change to `Options.swift` broke one of its 19 cases, the change is wrong, not the test
- [ ] T058 Run the full `quickstart.md` end to end, all seven stories, in one sitting
  - **Not done — no screen access.**
- [X] T059 [P] Check the six new user-facing strings from US1 against the house voice: plain, in the reader's language, saying what to do rather than what went wrong
- [X] T060 [P] Confirm no colour literal was added. The house rule is that colour means something has gone wrong; only the fetch-failed case in US1 may carry the app's existing error treatment
- [ ] T061 Clean up: `defaults delete com.alexecollins.Agents 'prompt.mode.claude'` and any test agents left behind
  - Nothing to clean: no manual runs happened, so no defaults were written and no test agents were started.
- [ ] T062 Update `specs/009-fix-chat-prompt-ux/checklists/requirements.md` with what the running app disagreed with, if anything — particularly the three "to confirm by running" arguments: the `simultaneousGesture` in US2, the no-flicker ordering in US3, and the spinner-under-Needs-attention reading in US6
  - Pending the manual passes above.

---

## Dependencies & Execution Order

### Phase dependencies

- **Setup (Phase 1)**: no dependencies
- **Foundational (Phase 2)**: empty. Nothing blocks
- **User Stories (Phases 3–9)**: any order, with the coupling noted in Phase 2
- **Polish (Phase 10)**: after the stories you intend to ship

### Story dependencies

- **US1 (P1)**: independent
- **US2 (P2)**: independent
- **US3 (P3)**: independent of behaviour, but edits `PromptBar.swift` after US1
- **US4 (P4)**: independent
- **US5 (P5)**: **depends on US1** — a control that is not shown cannot carry a remembered value. Also edits `PromptBar.swift`
- **US6 (P6)**: independent. Edits `ProjectRow.swift`, as US2 does
- **US7 (P7)**: independent, and touches nothing any other story touches

### Parallel opportunities

- T003 and T004 (the two "before" passes)
- T005–T007: the three `PromptControlsStateTests` tasks, same new file, so one author
- T014, T015, T016: the three daemon guards, three sites in two files, no overlap with the app work
- T036 and T037 (`ModeMemoryTests`), T049 and T050 (`ElicitationSchemaTests`)
- **US7 against everything**: it is the only story that shares no file with any other. Good work to hand to a second pair of hands

---

## Parallel Example: the daemon guards in User Story 1

```bash
# Three sites, the same one-line guard, no shared file with the app work:
Task: "Guard DaemonCore+Commands.swift:61 (start)"
Task: "Guard DaemonCore+Commands.swift:283 (revive)"
Task: "Guard DaemonCore+Runtimes.swift:132 (pickUp)"
```

---

## Implementation Strategy

### MVP: User Story 1 only

1. Phase 1 (Setup) — see the bugs first
2. Phase 3 (US1) — T005 through T017
3. **Stop and validate**: all six control-area states, plus the sidebar at 900pt
4. Ship

That alone turns "the controls sometimes vanish" into "the controls are always there or say why", which is the reported bug.

### Incremental after that

US2 next: it is four small tasks and removes a control that lies. Then US3, which finishes making the option row trustworthy — US1, US2 and US3 together are the whole of "the UI responds to me". US4 and US5 are comfort. US6 and US7 are independent and can go whenever.

### Two pairs of hands

One takes US1 → US3 → US5, in that order, because they share `PromptBar.swift`. The other takes US2 → US6 (both `ProjectRow.swift`) and US7, which shares nothing with anyone. US4 goes to whoever is free.

---

## Notes

- `[P]` means different files and no dependency on incomplete work
- No new target, no new module, no new dependency, no new daemon method, no protocol change
- Commit per task or per logical group; stop at any checkpoint and validate
- Three arguments in this plan are reasoned, not proven, and each has a named fallback: the `simultaneousGesture` in US2, the broadcast-before-response ordering in US3, and whether a spinner reads oddly under "Needs attention" in US6. T062 exists to record what the running app says
