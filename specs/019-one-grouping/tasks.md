---
description: "Task list for One Grouping, and Everything Agrees With It"
---

# Tasks: One Grouping, and Everything Agrees With It

**Input**: Design documents from `/specs/019-one-grouping/`

**Prerequisites**: [plan.md](./plan.md), [spec.md](./spec.md), [quickstart.md](./quickstart.md). 020 landed first (`ce65026`); this reads its state machine and changes nothing in it.

**Tests**: Included, and shaped like 020's: the rule is pure and exhaustible, so the exhaustive test over four facts is the most valuable thing here; one unit test holds that counts equal the list; one source scan holds "exactly one place" the only way that claim can be held; one daemon test holds the two things about the app's question that a pure test cannot see.

**Organization**: Four phases in the plan's slice order. Phase 1 is the compiler-driven one — remove the defaults and fix what breaks — and every later phase is written against its signature.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: US1–US4 from the spec

## Path Conventions

- `Packages/AgentsKit/Sources/AgentsKitCore/Model/AgentGroup.swift` — the rule and the funnel. Linked by `agentsd` and both apps; no `import SwiftUI`.
- `Packages/AgentsKit/Sources/AgentsKitCore/Client/AgentsModel.swift` — the window's view of agents, shared by Mac and phone.
- `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Projects.swift` — the daemon's counts.
- `App/Sources/Projects/ProjectRow.swift` — the one Mac reader of counts.
- `Packages/AgentsKit/Tests/AgentsKitTests/{Unit,Integration}/` — Swift Testing.

---

## The decision this list is written on

`outcomeAsked` joins the facts the grouping consults. The spec's key-entities section says no fact is added; FR-018 says the distinction between the app's turn and the person's must come from the fact the app already uses. Those meet at `outcomeAsked`: set before the app's question is enqueued, cleared only by a person's prompt (`DaemonCore+Commands.swift:346`), never by the question itself — "not clearing is how the two are told apart at all". Reading it is not adding a fact; adding a second flag would be.

The daemon's counts stay, computed with `wantsEyes: false` written out with its reason. That is FR-004 satisfied — the caller that cannot know says so — not evaded. The Mac window then does not read them; the phone, which has nothing unseen, does.

---

## Phase 1: The funnel (US4, and US1 by construction)

**Purpose**: One place decides, no caller can omit a fact, and the compiler lists every caller.

- [ ] T001 [US4] In `Packages/AgentsKit/Sources/AgentsKitCore/Model/AgentGroup.swift:64` change the initialiser to `public init(for state: AgentState, wantsEyes: Bool, report: WorkReport?, outcomeAsked: Bool)` — no default on any of the four. Rewrite the doc comment's paragraph about the two arguments to say why none may default: a default of `false` is how the daemon's counts came to disagree with the window's list, and a caller that cannot know a fact has to say so where a reader can see it (FR-004)
- [ ] T002 [US4] In the same file replace `Agent.group` (`:101`) with `public func group(wantsEyes: Bool) -> AgentGroup { AgentGroup(for: state, wantsEyes: wantsEyes, report: report, outcomeAsked: outcomeAsked) }`. Comment that this is the one way to ask, that the argument is the fact only a window holds, and that `false` is honest from anything that is not a window and a lie from anything that is
- [ ] T003 [US4] In `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Projects.swift:47` change `counts[agent.group, default: 0]` to `counts[agent.group(wantsEyes: false), default: 0]` with a comment carrying the whole reason: the daemon has no window and stores nothing about a file being looked at (it refuses to show one with no window open), so this is the count *without eyes*; the Mac completes it from its own grouping and the phone, which has nothing unseen, takes it as is (FR-009)
- [ ] T004 [US1] In `Packages/AgentsKit/Sources/AgentsKitCore/Client/AgentsModel.swift:300` make `group(of:)` call `agent.group(wantsEyes: filesToShow[agent.id] != nil)`, keeping its comment about `filesToShow` being the unseen flag
- [ ] T005 [P] [US4] In `Remote/Sources/Preview/Canned.swift:135` change `agent.group` to `agent.group(wantsEyes: false)`, with one line saying the preview says what the daemon says
- [ ] T006 [P] [US4] Change every `.group` on an agent read from the daemon's side in `Packages/AgentsKit/Tests/AgentsKitTests/Integration/ElicitationTests.swift`, `UnreportedEndingTests.swift`, `AgentBirthTests.swift` and `OutcomeReportTests.swift` to `.group(wantsEyes: false)`. Add no helper: the argument is the point
- [ ] T007 [US4] In `Packages/AgentsKit/Tests/AgentsKitTests/Unit/AgentGroupTests.swift` delete `theOlderInitialiserIsTheNoEyesCase` — it tested the default that T001 removes — and update every remaining call to pass all four arguments
- [ ] T008 [US4] Rewrite `everyStateAndReportPairIsStillExactlyOneGroup` in the same file to walk `AgentState.allCases × [false, true] × (nil + WorkOutcome.allCases) × [false, true]` and assert each tuple lands in exactly one group. Name it `everyCombinationOfTheFourFactsIsExactlyOneGroup`. Comment that a fact added to the initialiser without a loop added here fails to compile, which is SC-006 (FR-002, FR-019)

**Checkpoint**: The package builds, both apps build, and `AgentGroup(for:` is called from exactly one method.

---

## Phase 2: The window completes the count (US1, US2)

**Purpose**: The number on a project row is the number of rows under the heading, on the same window, at the same moment.

- [ ] T009 [US1] Add `public func counts(in folder: URL?) -> [AgentGroup: Int]` to `Packages/AgentsKit/Sources/AgentsKitCore/Client/AgentsModel.swift` beside `agents(in:group:)`, using the same standardised-folder filter and `group(of:)`. Comment that this is what FR-009 means by the count being completed by something that knows: the daemon's `ProjectSummary.counts` are computed without eyes, and this window has them (FR-006, FR-007)
- [ ] T010 [US2] Delete `wantsEyes(in:)` from `AgentsModel.swift:306` and its forwarder at `App/Sources/AppModel.swift:227`. Its replacement is `counts(in:)[.needsAttention] > 0`, which consults state through the grouping — the check it replaces never did, which is how a stopped agent went on wanting eyes (FR-011, FR-012)
- [ ] T011 [US1] In `App/Sources/Projects/ProjectRow.swift:57` and `:66–67` read `model.counts(in: summary.folder)` instead of `summary.counts`, and make `needsPerson` exactly `(counts[.needsAttention] ?? 0) > 0` (FR-008). Rewrite the comment above it: it used to explain two ways to want somebody, one the daemon counts and one only the window knows; now there is one grouping and this window asks it
- [ ] T012 [US1] Add `func counts(in folder: URL?) -> [AgentGroup: Int]` to `App/Sources/AppModel.swift` beside `agents(in:group:)` (`:223`), forwarding to `work.counts(in:)`
- [ ] T013 [P] [US1] In `Packages/AgentsKit/Sources/AgentsKitCore/Daemon/DaemonAPI.swift:177` and `:192` extend the doc comments on `counts` and `needsInput`: computed without knowing whether an agent asked to be looked at, complete for a surface that cannot show a file (the phone), and completed on the Mac by `AgentsModel.counts(in:)`
- [ ] T014 [P] [US1] Add `theCountsAreTheListUnderEveryHeading` to `Packages/AgentsKit/Tests/AgentsKitTests/Unit/AgentsModelTests.swift`: one project holding an agent in each of the five groups plus a `running` one with a file in `filesToShow`; assert `counts(in:)[g] == agents(in:group: g).count` for every `AgentGroup`, and that the file-showing agent is counted under `.needsAttention` and not `.running` (FR-020, SC-002)
- [ ] T015 [P] [US2] Add `aStoppedAgentThatAskedToBeLookedAtIsNotWanted` to the same file: an agent with a file in `filesToShow` whose state is `.stopped`; assert `counts(in:)[.needsAttention]` is nil or zero and the agent is under `.stopped` (US2-1, US2-2)

**Checkpoint**: The Mac row and panel agree by construction; the phone is unchanged and still agrees with the daemon.

---

## Phase 3: The app's own question is not work (US3)

**Purpose**: An agent answering the app stays where it was.

- [ ] T016 [US3] In `AgentGroup.init` in `Packages/AgentsKit/Sources/AgentsKitCore/Model/AgentGroup.swift` add, before the `.running` arm, `case .running where outcomeAsked:` mapping to the same expression as `.finished` — `(wantsEyes || wantsAnswer) ? .needsAttention : .finished`. The comment must say what the turn is: the app's one question after a silent ending, which costs money and is real but is work nobody asked for; that the flag is set before the question is enqueued and cleared only by a person's prompt, so `running && outcomeAsked` is that question and nothing else (FR-014, FR-018); that a person's prompt clears it and the same agent is then Working (FR-016); and that an agent which never answers ends `finished` with the flag set, which is the unaccounted ending 014 draws (FR-017)
- [ ] T017 [P] [US3] Add to `AgentGroupTests.swift`: `anAgentAnsweringTheAppStaysWhereItWas` — for each report in nil + `WorkOutcome.allCases` and each `wantsEyes`, `AgentGroup(for: .running, …, outcomeAsked: true)` equals `AgentGroup(for: .finished, …, outcomeAsked: true)`; and `aPersonsPromptMakesItWorkAgain` — `(.running, outcomeAsked: false)` is `.running` or `.needsAttention` by eyes alone (US3-1, US3-3, US3-4)
- [ ] T018 [US3] Add `theQuestionIsAskedWithTheFlagUpAndAPromptTakesItDown` to `Packages/AgentsKit/Tests/AgentsKitTests/Integration/UnreportedEndingTests.swift`, beside its existing scaffolding: let a turn end silently, wait for the question's turn to begin, and assert the agent the daemon holds is `.running` with `outcomeAsked == true` and `group(wantsEyes: false) == .finished`; then send a person's prompt and assert `outcomeAsked == false`. Comment that the daemon changes nothing here — the test holds that the two facts the grouping now reads are set the way the plan says they already are (US3-1, US3-4, US3-5)

**Checkpoint**: Quickstart checks 3 and 4 are true.

---

## Phase 4: Keeping it, and polish

- [ ] T019 Create `Packages/AgentsKit/Tests/AgentsKitTests/Unit/OneGroupingTests.swift` with a source scan over `Packages/AgentsKit/Sources`, `App/Sources` and `Remote/Sources`, copying the root discovery and `sources(under:)` helpers from `LifecycleWriterTests.swift`: assert the text `AgentGroup(for:` occurs in exactly one file and that file is `AgentGroup.swift`, and — as that suite insists — that the scan bites, by matching a fixture line. Doc-comment it with the spec's own reason: two functions is how this happened, and this is what stops a third (FR-021, SC-001, SC-007)
- [ ] T020 [P] Extend `noHeadingWasAddedRenamedOrRemoved` in `AgentGroupTests.swift` only if it does not already pin `AgentGroup.live`'s order and titles; otherwise leave it and say so in the commit (FR-022)
- [ ] T021 Run `swift test --package-path Packages/AgentsKit`, `xcodebuild -scheme Agents -configuration Debug -skipPackagePluginValidation -skipMacroValidation build` and the same for `-scheme Remote -destination 'generic/platform=iOS Simulator'`, all green
- [ ] T022 Walk [quickstart.md](./quickstart.md) checks 1–6 by hand in the built app and record what each did at the foot of this file. Check 5 needs the phone and is Alex's

---

## Dependencies & Execution Order

- Phase 1 first and whole: T001 breaks the build until T002–T007 are done, which is the intent.
- Phase 2 and Phase 3 are independent of each other and both depend on Phase 1.
- T019 depends on Phase 1 (it asserts the funnel) and should be written after T016 so the count is final.
- T021 after everything; T022 after T021.
