---
description: "Task list for Workflow Settings"
---

# Tasks: Workflow Settings

**Input**: Design documents from `/specs/017-workflow-settings/`

**Prerequisites**: [plan.md](./plan.md), [spec.md](./spec.md), [research.md](./research.md), [data-model.md](./data-model.md), [contracts/](./contracts/), [quickstart.md](./quickstart.md)

**Tests**: Included, and the balance is unusual for this repo: almost everything worth asserting here is pure, so the unit suites carry the weight. `WorkflowSettings.resolve` and `FrontMatterEdit.set` are both functions of their inputs, and both can be wrong in ways a person notices immediately — one starts an unattended agent with more permission than its file asked for, the other moves something in somebody's repository nobody asked it to move. The one integration suite exists for the claim a pure test cannot make: that a refused setting starts **no agent**, which is a fact about the daemon's state and not about a returned value.

**Organization**: Grouped by user story in the spec's priority order. US1 is shippable alone and is the MVP. US3 genuinely depends on US2 — the controls it adds live on the page US2 builds — and that dependency is stated rather than pretended away.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (US1–US4)

## Path Conventions

- `Packages/AgentsKit/Sources/AgentsKitCore/Model/` — what a window has to draw, so what crosses the daemon boundary. `WorkflowSettings` and `FrontMatterEdit` both live here.
- `Packages/AgentsKit/Sources/AgentsKit/{Workflows,Daemon,ACP}/` — reading files, firing workflows, talking to runtimes.
- `App/Sources/Projects/` — the project page and what it now opens.
- `Packages/AgentsKit/Tests/AgentsKitTests/{Unit,Integration}/` — Swift Testing.
- Nothing in `Remote/Sources/`. The phone has never drawn a workflow.

---

## Phase 1: Setup

**Purpose**: The files everything else is written into.

- [X] T001 Create `Packages/AgentsKit/Sources/AgentsKitCore/Model/WorkflowSettings.swift` containing only `import Foundation`, `public struct WorkflowSettings: Codable, Hashable, Sendable {}` and a file-level doc comment in the house voice saying: what these are (what a workflow says about how its agent should be started — permission mode, runtime, model); that the values are the runtime's own strings passed through untouched, because this app does not define a vocabulary of modes and cannot support the claim that plan mode on one runtime is the same promise as plan mode on another; that all three are optional and a workflow stating none of them starts exactly as every workflow started before this feature; and that the permission mode is the one that matters, because an agent a person starts has them sitting in front of it and a workflow's agent starts at nine in the morning whether or not anybody is at the machine
- [X] T002 [P] Create `Packages/AgentsKit/Tests/AgentsKitTests/Unit/WorkflowSettingsTests.swift` with `import Foundation`, `import Testing`, `@testable import AgentsKit`, `@testable import AgentsKitCore` and an empty `@Suite("What a workflow says about how it runs") struct WorkflowSettingsTests {}`, with a doc comment naming which test in it carries the feature — a mode the runtime does not offer must be refused and never substituted — and why: every substitution is in the permissive direction, and nobody is watching when a workflow fires
- [X] T003 [P] Create `Packages/AgentsKit/Tests/AgentsKitTests/Unit/FrontMatterEditTests.swift` with the same imports and an empty `@Suite("Changing one key in a file somebody wrote") struct FrontMatterEditTests {}`, whose doc comment says this is the only thing in the app that writes into a person's own file, that a failure here is not a failing test but the app having moved something nobody asked it to move, and that the round-trip test at the end is the one that would catch it
- [X] T004 [P] Create `Packages/AgentsKit/Tests/AgentsKitTests/Integration/WorkflowSettingsFlowTests.swift` with an empty `@Suite("A workflow that says how it runs", .timeLimit(.minutes(1))) struct WorkflowSettingsFlowTests {}`, copying the `temporary()`, `project(_:_:)`, `write(_:as:in:)` and `core(_:seeded:script:)` scaffolding from `Packages/AgentsKit/Tests/AgentsKitTests/Integration/WorkflowFiringTests.swift` verbatim, including its comment that the runtime is the fake launcher so an agent really starts and really finishes without a CLI, a credential or a network

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: The settings exist, are read off disk, and are said in the one sentence this app uses to describe a workflow. Nothing honours them yet and nothing can change them — but every later phase reads what this one builds.

**⚠️ CRITICAL**: No user story work can begin until this phase is complete.

- [X] T005 Add the three fields to `WorkflowSettings` in `Packages/AgentsKit/Sources/AgentsKitCore/Model/WorkflowSettings.swift`: `public var permissionMode: String?`, `public var runtimeID: String?`, `public var model: String?`, with a memberwise `init` defaulting all three to `nil`, plus `public var isEmpty: Bool { permissionMode == nil && runtimeID == nil && model == nil }`. Comment `isEmpty` with what it decides: an empty settings takes the start path this app has always taken, with no session made to check anything against, which is what keeps SC-006 true and keeps the common case free
- [X] T006 Add `public var summary: String?` to `WorkflowSettings` in `Packages/AgentsKit/Sources/AgentsKitCore/Model/WorkflowSettings.swift`, returning `nil` when `isEmpty`, and otherwise the clause `Workflow.summary` appends — `in plan mode`, `on Grok`, `using claude-opus-5`, joined with `", "` in that order. It must **omit the runtime when it is `RuntimeCatalog.builtIn[0].id`** (guarantee S9), commented with why: naming the default on every row is noise, and a row that says something on every workflow says nothing
- [X] T007 Add `public var settings: WorkflowSettings` to `Workflow` in `Packages/AgentsKit/Sources/AgentsKitCore/Model/Workflow.swift`, defaulting to `WorkflowSettings()` in the memberwise `init` so every existing construction site compiles untouched, with a doc comment saying this is part of the file and therefore part of the repository — unlike `isArchived` and the standing agent, which are the app's own bookkeeping and are deliberately kept out of it (quote 008's reason: it would put the app's bookkeeping into a history nobody wants to review)
- [X] T008 Extend `Workflow.summary` in `Packages/AgentsKit/Sources/AgentsKitCore/Model/Workflow.swift` to append `settings.summary` after the mode clause, **guarded on `mode != .triggering`**. The comment must carry the whole reason: a `triggering` workflow never starts an agent, so it never applies a setting, so a row saying "in plan mode" about one would be a false statement in the one place this feature exists to make true. Note in the same comment that this one renderer is read by both `WorkflowRow` and the reply an agent gets from `writeWorkflowForAgent`, which is why FR-027 and FR-029 are one line and cannot drift apart
- [X] T009 Parse the three keys in `WorkflowFile.parse` in `Packages/AgentsKit/Sources/AgentsKit/Workflows/WorkflowFile.swift`: read `mapping["permission-mode"]?.scalar`, `mapping["runtime"]?.scalar` and `mapping["model"]?.scalar` into a `WorkflowSettings`, and pass it to the `Workflow` initialiser. A key that is present but whose value is **not a scalar** — a list, or a block under it — must return `broken("...")` naming the key, because a file whose settings cannot be read is a file somebody has to fix. A `runtime:` naming an id not in `RuntimeCatalog` is **not** a parse error: comment that a runtime dropped or renamed should turn into a workflow that says why it did not run, not into a broken file, and point at [research.md](./research.md) §4
- [X] T010 Widen `known` in `WorkflowFile.parse` in `Packages/AgentsKit/Sources/AgentsKit/Workflows/WorkflowFile.swift` from `["on", "agent", "name"]` to `["on", "agent", "name", "permission-mode", "runtime", "model"]`, so the three stop landing in `unknownFields`, and leave the surrounding behaviour alone — anything else a later version writes must still be kept and must still survive being written back (FR-004)
- [X] T011 [P] Add `aFileWithNoSettingsStartsAsItAlwaysDid` and `settingsSurviveAFileThatAlsoCarriesKeysWeDoNotKnow` to `Packages/AgentsKit/Tests/AgentsKitTests/Unit/WorkflowSettingsTests.swift`: the first parses a workflow file written before this feature and expects `settings.isEmpty` and `summary == nil`; the second parses one carrying all three keys **and** a `colour: blue`, and expects the three read and `colour` still in `unknownFields`
- [X] T012 [P] Add `theSummaryLeavesOutTheDefaultRuntime` and `aTriggeringWorkflowDoesNotClaimAModeItWillNeverApply` to `Packages/AgentsKit/Tests/AgentsKitTests/Unit/WorkflowSettingsTests.swift`, the second asserting on `Workflow.summary` for a workflow with `agent: triggering` and `permission-mode: plan` — the sentence must not contain "plan"
- [X] T013 [P] Extend `Packages/AgentsKit/Tests/AgentsKitTests/Unit/WorkflowFileTests.swift` with a case for each malformed setting — `permission-mode:` with a list under it, `model:` with a block — expecting `WorkflowProblem.unreadable` naming the key, and one for `runtime: nonesuch` expecting **no problem at all**, with a comment saying the refusal for that one comes later and from somewhere else

**Checkpoint**: A workflow file can carry the three settings, the project page says so on its row, and nothing behaves differently yet. `swift test --package-path Packages/AgentsKit` must be fully green before anything below starts.

---

## Phase 3: User Story 1 - A workflow says how much it is allowed to do (Priority: P1) 🎯 MVP

**Goal**: A workflow's stated permission mode, runtime and model are honoured when it starts an agent — and when one of them cannot be honoured, no agent starts at all and the row says why.

**Independent test**: Write a workflow naming a permission mode, tap Run now, and confirm the agent it starts is in that mode and not the runtime's default. Then misspell the mode and confirm nothing starts.

- [X] T014 [US1] Add the `Resolution` enum and `resolve(_:against:)` to `Packages/AgentsKit/Sources/AgentsKitCore/Model/WorkflowSettings.swift` exactly as [contracts/workflow-settings.md](./contracts/workflow-settings.md) specifies: `case resolved(StartOptions)` and `case refused(setting: String, value: String, offered: [String])`. The mode option is found with `ModeMemory.modeOption(in:)` — reused, not reimplemented, so the workflow and the prompt bar cannot come to disagree about which advertised option is *the* mode. The model option is found by `category == "model"` first and `id == "model"` second. A named value with no matching `ConfigChoice.value` is `.refused`, with `offered` listing the choice **values** in the order the runtime sent them. Comment that there is no fallback branch and that adding one later would be adding the bug: every fallback is toward more permission, and nobody is watching
- [X] T015 [US1] Add `refusalDetail(setting:value:offered:runtime:)` to `Packages/AgentsKit/Sources/AgentsKitCore/Model/WorkflowSettings.swift`, producing the sentence a person and an agent both read — e.g. `"plan" is not a permission mode Claude offers here — it offers default, acceptEdits, bypassPermissions` — and, when `offered` is empty, `Claude does not offer a permission mode here at all`
- [X] T016 [P] [US1] Add `aNamedModeIsSentUnderTheIdTheRuntimeAdvertised` to `Packages/AgentsKit/Tests/AgentsKitTests/Unit/WorkflowSettingsTests.swift`, using a `ConfigOption` whose **id is `permission_mode`** and whose category is `mode`, so the test fails if anything hard-codes the string `"mode"` as a key (guarantee S2/S3)
- [X] T017 [P] [US1] Add `aModeTheRuntimeDoesNotOfferIsRefusedAndNotSubstituted`, `theRefusalNamesWhatWouldHaveWorked`, `aRuntimeThatOffersNoModeAtAllRefusesRatherThanIgnores` and `theModelIsFoundByCategoryNotByName` to `Packages/AgentsKit/Tests/AgentsKitTests/Unit/WorkflowSettingsTests.swift` — S5, S8, S7 and S4. Mark the first in a comment as the test that carries the feature
- [X] T018 [US1] Add `case settingRefused(setting: String, detail: String)` to `WorkflowRefusal` in `Packages/AgentsKit/Sources/AgentsKitCore/Model/WorkflowOutcome.swift`: `message` returns `detail`; `needsAPerson` returns **`true`**, in the same arm as `chainTooDeep`, `unreadable`, `folderGone` and `overLimit`, commented with why — nothing resolves this on its own, it refuses every fire until the file changes or the runtime changes back; `isSameReason(as:)` compares **`setting` only and not `detail`**, so a weekend of identical refusals collapses to one row with a count, the rule `chainTooDeep` already follows by ignoring its depth. Leave `Workflow.refusalIfBlocked` untouched and say in a comment that it stays pure and runtime-unaware, which is why this refusal is raised in the start path instead
- [X] T019 [US1] Change `freshSession(runtimeID:cwd:mcpServers:)` in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Commands.swift:~196` from `private func` to `func`, with a one-line comment saying the workflow start path needs to make a session before there is an agent, so it can refuse before one exists
- [X] T020 [US1] Rewrite `startAgent(for:run:prompt:)` in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Workflows.swift:~425` per [contracts/daemon-api.md](./contracts/daemon-api.md): resolve `runtimeID` as `workflow.settings.runtimeID ?? RuntimeCatalog.builtIn[0].id` and throw a settings refusal naming the id when `RuntimeCatalog.runtime(id:)` is nil; **when `workflow.settings.isEmpty`, take today's path unchanged and make no draft**; otherwise call `freshSession`, register the result in `drafts` as a `Draft`, read `await session.options`, call `WorkflowSettings.resolve`, and on `.refused` end the draft, remove it from `drafts` and throw — creating no agent — or on `.resolved` call `start` with that `draftID` and the resolved `StartOptions` so the same session is reused and no second process is spawned
- [X] T021 [US1] Write the comment on `startAgent(for:run:prompt:)` in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Workflows.swift` that the next reader will want: `ACPSession.apply` swallows refusals on purpose and correctly — a person is looking at the control, and an option the runtime dropped should not cost them an agent — and that this path cannot use it, because the thing being dropped is the sentence *this one may not change files* and there is nobody in the room. Say explicitly that validating against `OptionCache` instead would be validating against a remembered answer, and a stale entry claiming plan mode is available is the exact failure FR-008 exists to prevent
- [X] T022 [US1] Add a settings-refusal branch to `fire`'s existing `catch` in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Workflows.swift` (~:370): a thrown settings refusal is recorded as `.settingRefused(setting:detail:)`, everything else stays `.unreadable(message)` as today. Use a small typed error rather than string-matching the message
- [X] T023 [P] [US1] Add `theModeInTheFileReachesTheRuntime` and `aWorkflowWithNoSettingsTakesTheOldPath` to `Packages/AgentsKit/Tests/AgentsKitTests/Integration/WorkflowSettingsFlowTests.swift`, the first asserting on `FakeACPAgent`'s own recorded `setOptions` — what the runtime was actually told, never what we meant to tell it — and the second asserting no draft was made
- [X] T024 [US1] Add `aModeTheRuntimeDoesNotOfferStartsNoAgent`, `aWorkflowNamingAnUnknownRuntimeIsRefusedNotRehomed` and `fourRefusalsInARowAreOneRowWithACount` to `Packages/AgentsKit/Tests/AgentsKitTests/Integration/WorkflowSettingsFlowTests.swift`. The first must assert **the agent count is unchanged** as well as that the outcome is `.settingRefused` — a test that only checks the refusal was recorded would pass while an agent ran in the wrong mode, which is the entire failure this feature prevents

**Checkpoint**: The spec's P1 story is complete and the app is shippable here. A workflow can be made read-only by adding one line to its file, the row says so, and a mode that is not on offer starts nothing.

---

## Phase 4: User Story 2 - You can open a workflow and read it (Priority: P2)

**Goal**: Clicking any workflow on a project page opens it — trigger, agent mode, settings and the whole prompt — and back returns to the project.

**Independent test**: Click a workflow row and confirm the whole file's meaning is on screen, including the entire prompt, without opening Finder or an editor. Then do the same to an archived one and to one whose front matter is broken.

- [X] T025 [US2] Add `var openWorkflow: Workflow.ID?` to `App/Sources/AppModel.swift` beside `selection` (~:92), with a doc comment saying it is `selection`'s sibling rather than a widening of it: `selection`'s `didSet` sets `work.watching` and reloads the transcript and is threaded through the view tree in some forty places, and a second exclusive field costs one line where an enum would cost all of them
- [X] T026 [US2] Clear `openWorkflow` alongside `selection` in `selectedProject.didSet` (~:61) and in `showProject(_:)` (~:79) in `App/Sources/AppModel.swift`, extending the comment already there — picking a project shows the project, not a conversation, and now not a workflow either
- [X] T027 [US2] Add `enum Page: Hashable { case agent(UUID); case workflow(String) }` and replace the `openAgent` binding in `App/Sources/ContentView.swift:~18` with the `page` binding from [contracts/workflow-page.md](./contracts/workflow-page.md), whose setter keeps the two model fields mutually exclusive. Keep and widen the existing comment about a chat being somewhere you go from the project and come back out of: a workflow is the same kind of thing, so it is the same kind of push
- [X] T028 [US2] Change the `navigationDestination` in `App/Sources/ContentView.swift` to switch on `Page`, sending `.agent` to today's `ChatView` + sidebar arrangement untouched, and `.workflow` to the new `WorkflowPage`. The sidebar, its toolbar item and `showWhatWasAskedFor()` stay on the agent branch only — a workflow has no files pane and no agent to ask for one
- [X] T029 [US2] Create `App/Sources/Projects/WorkflowPage.swift` drawing, in the chat column `.chatColumn()` gives it (018 replaced the project page's fixed 144pt gutter with it): the name; `workflow.summary`; the next-fire and last-outcome line including a link to the agent a run started; the prompt in full in a selectable monospaced block; where the file is with *Show in Finder*; and *Run now* and *Archive*/*Restore* as words. Its doc comment must say why the prompt is the reason the page exists — an agent can write a workflow in this app without anybody's approval, and until now the prompt was the one part of it nobody could see
- [X] T030 [US2] Handle the three awkward states in `WorkflowPage.swift`: an **unreadable** workflow shows its problem *and* the file's raw text (P2), an **archived** one says it will not run and offers Restore (P7), and one whose file is **deleted while open** returns to the project page saying so (P4). Comment that every workflow opens — archived, over a ceiling, unsupported, unreadable — and that the broken one is the one most likely to need looking at, so it is the last thing that may be a dead row
- [X] T031 [US2] Make the whole card in `App/Sources/Projects/WorkflowRow.swift` open the workflow by setting `model.openWorkflow`, keeping the play button, the archive button and the *Ran →* link as their own hit areas with their own meanings. The context menu keeps what it has and gains nothing: opening is what the row now does by itself
- [X] T032 [P] [US2] Add `WorkflowPage` and any new file to `project.yml` if the target's sources are enumerated rather than globbed, then run `xcodegen generate` and confirm the app still builds
- [X] T033 [US2] Walk steps 1, 2 and 9 of [quickstart.md](./quickstart.md) §4 by hand and record what P1–P8 actually did. The app has no view tests; this is the only pass these guarantees get

**Checkpoint**: Every workflow on a project page opens, including the ones that cannot run. US1 and US2 are both complete and independent.

---

## Phase 5: User Story 3 - You can change what it is allowed to do (Priority: P3)

**Goal**: The permission mode, runtime and model are changeable from the page US2 built, and the change is written into the workflow's file leaving everything else as its author wrote it.

**Depends on**: US2. The controls live on the page, and there is nowhere else for them to go.

**Independent test**: Open a workflow, change its permission mode, and confirm the file on disk now names that mode, that nothing else in the file moved, and that the next fire uses it.

- [X] T034 [US3] Add `public enum FrontMatterEdit` with `Refusal` and `set(_:to:in:)` to `Packages/AgentsKit/Sources/AgentsKitCore/Model/FrontMatter.swift`, beside `strip`. Its doc comment must say why it is in this file and not a new one — the positional rule about `---` is stated once, and a second implementation of it is how the top of somebody's document gets eaten — and that this is the only thing in the app that writes into a file a person wrote, which is why it refuses rather than doing its best
- [X] T035 [US3] Implement E1–E8 and E12 in that function per [contracts/front-matter-edit.md](./contracts/front-matter-edit.md): only the lines between the first-line `---` and its closing fence are considered; only **column-zero** keys match, so a `model:` indented under a trigger is never touched; replacing a value preserves the line's trailing comment; a key being added goes on its own line immediately before the closing fence; `nil` removes the whole line and nothing adjacent; a value needing quoting is quoted; the document's line-ending style survives
- [X] T036 [US3] Implement the three refusals in `FrontMatterEdit.set` in `Packages/AgentsKit/Sources/AgentsKitCore/Model/FrontMatter.swift` — E9 no front matter or an unclosed block, E10 the key appearing twice at column zero, E11 the key's existing value not a scalar — each carrying a sentence a person can act on. Comment that a best effort here is worse than a refusal, because the failure mode of a best effort is a diff nobody asked for in somebody's repository
- [X] T037 [P] [US3] Add `addingAKeyPutsItJustInsideTheFence`, `changingAValueLeavesTheCommentAfterIt`, `theBodyIsReturnedByteForByte` (with a body containing its own `---` rule), `anIndentedKeyOfTheSameNameIsNotTouched` and `removingAKeyTakesOnlyItsLine` to `Packages/AgentsKit/Tests/AgentsKitTests/Unit/FrontMatterEditTests.swift`
- [X] T038 [P] [US3] Add `aDocumentWithNoFrontMatterIsRefused`, `aKeyTwiceIsRefusedRatherThanPicked`, `aKeyWithAListUnderItIsRefused`, `windowsLineEndingsSurvive` and `everyWorkflowInThisRepositoryRoundTrips` to `Packages/AgentsKit/Tests/AgentsKitTests/Unit/FrontMatterEditTests.swift` — the last setting a key and removing it again and expecting the file back byte for byte
- [ ] T039 [US3] Add `workflowsSettings = "workflows/settings"` and `optionsRemembered = "options/remembered"` to `DaemonAPI.Method`, plus `WorkflowSettingsRequest(folder:workflowID:settings:)` and `RememberedOptionsRequest(runtimeID:cwd:)`, in `Packages/AgentsKit/Sources/AgentsKitCore/Daemon/DaemonAPI.swift`. Comment `optionsRemembered` with the distinction that matters: it starts no session and spawns no process, unlike `agents/options` — reading a workflow must not start a runtime, and deciding whether one may edit your files must not trust a cache
- [ ] T040 [US3] Implement `setWorkflowSettings(_:)` in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Workflows.swift` in the order [contracts/daemon-api.md](./contracts/daemon-api.md) gives: find the workflow, read its text, apply each of the three keys through `FrontMatterEdit.set` to the text in hand, write atomically, call `rescanWorkflows(in:)` **synchronously**, and return `summary(for:)`. An editor `Refusal` becomes `DaemonAPI.Failure.workflowUnreadable` carrying the editor's own sentence **with nothing written**. Comment the synchronous rescan: the watcher is debounced 250ms and waiting that long to tell the window what it just asked for reads as the app having ignored you
- [ ] T041 [US3] Implement `rememberedOptions(_:)` in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Commands.swift`, returning `rememberedOptions(for: OptionCache.key(runtimeID:cwd:mcpServers: []))?.options ?? []` and starting nothing. A workflow attaches no MCP servers, which is why the key is built with an empty list
- [ ] T042 [US3] Route both methods in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Dispatch.swift`, `workflows/settings` beside `workflows/archive` (~:37) and `options/remembered` beside `agents/options` (~:101), following the decode-call-encode shape of the cases around them
- [ ] T043 [US3] Add `setWorkflowSettings(_:_:)` and `rememberedOptions(runtimeID:cwd:)` to the Workflows section of `App/Sources/AppModel.swift` (~:174), following `setWorkflowArchived` — except that this one must **not** swallow its error with `try?`: a refusal has to reach the person, so it goes through the existing `problem` alert (FR-025)
- [ ] T044 [US3] Add the three settings controls to `App/Sources/Projects/WorkflowPage.swift`, built from `rememberedOptions` for the workflow's runtime and this project, reusing `App/Sources/StartAgent/OptionMenu.swift` so a mode picker looks like a mode picker wherever it is. Draw all four states in the contract's table, and make the failure state carry its weight: a value the runtime does not offer is shown marked, with what it does offer, because this workflow is refusing every fire and this page is where that gets explained
- [ ] T045 [US3] Handle the two agent modes in `App/Sources/Projects/WorkflowPage.swift`: when `agent: triggering`, the three controls are **shown and disabled** under *this workflow resumes the agent that triggered it, so these do not apply* — shown rather than hidden, because a hidden control is not an explanation; when `agent: standing`, one line saying they are applied when its standing agent is started and again if it has to be replaced
- [ ] T046 [P] [US3] Add `writingASettingChangesTheFileAndNothingElse`, `theWindowHearsAboutItWithoutWaitingForTheWatcher`, `aSettingOnAReadOnlyFileIsRefusedAndNotHeld` and `rememberedOptionsStartsNothing` to `Packages/AgentsKit/Tests/AgentsKitTests/Integration/WorkflowSettingsFlowTests.swift`

**Checkpoint**: A permission mode can be set from the app, ends up in the repository, and takes effect on the next fire.

---

## Phase 6: User Story 4 - An agent asked for a workflow knows to set this (Priority: P4)

**Goal**: An agent told *don't let it change anything* writes a workflow whose file says so, and reports it in words.

**Independent test**: Ask an agent to create a workflow that must not change files, and confirm the file names a permission mode and that the reply says so.

- [ ] T047 [US4] Add the settings paragraph to `workflowTool`'s description in `Packages/AgentsKit/Sources/AgentsKit/ACP/Serve/AppService.swift:~305`, exactly as [contracts/daemon-api.md](./contracts/daemon-api.md) gives it — the three keys, what leaving them out means, when to set `permission-mode:`, and that a mode the runtime does not offer stops the workflow running rather than falling back. The schema is unchanged: `content` is already the whole file
- [ ] T048 [US4] Extend the example in `workflowTool`'s `content` property in `Packages/AgentsKit/Sources/AgentsKit/ACP/Serve/AppService.swift` to carry `permission-mode:`, so the shape an agent copies is the shape with the setting in it. Comment that `WorkflowExample.prompt` had to name the tool because two runtimes went and wrote a crontab instead — the same lesson applies to showing the key rather than describing it
- [ ] T049 [US4] Confirm no change is needed in `writeWorkflowForAgent` in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+AppTools.swift:~273`: it already interpolates `parsed.summary`, which T008 extended, so FR-029 and FR-030 are already true. If a read of it shows otherwise, fix it there rather than adding a second renderer
- [ ] T050 [P] [US4] Extend `Packages/AgentsKit/Tests/AgentsKitTests/Integration/WorkflowToolTests.swift` with a write carrying `permission-mode:` and assert the reply names the mode in words — not as a quoted line of YAML

**Checkpoint**: All four stories complete.

---

## Phase 7: Polish & Cross-Cutting

- [ ] T051 Run the whole of [quickstart.md](./quickstart.md) §4 by hand, all nine steps plus the agent-written workflow, and record what each did
- [ ] T052 [P] Add a line to `Packages/AgentsKit/Sources/AgentsKitCore/Model/WorkflowExample.swift` or its comment only if step 10 of the quickstart shows the empty-state suggestion now reads oddly beside settings — otherwise leave it alone and say so in the commit
- [ ] T053 [P] Update `specs/008-agentic-workflows/spec.md` FR-032 to point at 017's FR-021, in the manner FR-024 and FR-035 in that same file already point at what superseded them. Do not rewrite the requirement; annotate it
- [ ] T054 Run `swift test --package-path Packages/AgentsKit` and `xcodebuild -scheme Agents -destination 'platform=macOS' -skipPackagePluginValidation build`, both green
- [ ] T055 Read back every comment added in T008, T018, T021 and T036 — in `Workflow.swift`, `WorkflowOutcome.swift`, `DaemonCore+Workflows.swift` and `FrontMatter.swift` — as a stranger would. Each one exists to stop a later reader undoing a decision that looks like an oversight; if any of them reads as description rather than reason, rewrite it

---

## Dependencies & Execution Order

### Phase dependencies

- **Setup (Phase 1)**: no dependencies.
- **Foundational (Phase 2)**: needs Setup. **Blocks every user story.**
- **US1 (Phase 3)**: needs Foundational. Independent of everything after it.
- **US2 (Phase 4)**: needs Foundational. Independent of US1 — the page draws `workflow.summary`, which Phase 2 supplies.
- **US3 (Phase 5)**: needs **US2**. Its controls live on that page. The daemon half (T034–T042) is independent of US2 and can be built in parallel with it; only T044 and T045 actually need the page.
- **US4 (Phase 6)**: needs Foundational. Independent of US1, US2 and US3.
- **Polish (Phase 7)**: needs whichever stories are being shipped.

### Within Phase 2

T005 → T006 → T007 → T008 is a chain (each reads the last). T009 and T010 are one edit to one function and are sequential. T011–T013 are all `[P]`, in three different test files.

### Parallel opportunities

- T002, T003, T004 together — three new empty test files.
- T011, T012, T013 together.
- T016, T017 together, then T023, T024 together.
- T037, T038 together.
- **US1, US2 and US4 can be built by three people at once** the moment Phase 2 is green. They touch the daemon, the app and one string respectively.
- The US3 daemon work (T034–T042) runs alongside the whole of US2.

### Parallel example: after Phase 2

```text
Developer A: T014–T024   (US1 — the strict start path)
Developer B: T025–T033   (US2 — the page)
Developer C: T047–T050   (US4 — the tool's words)
Developer B or C then:  T034–T042 (US3's daemon half), before T044–T046
```

---

## Implementation Strategy

### MVP: Phases 1–3

Setup, Foundational, US1. At the end of it a workflow that must not change files can be made so by adding one line to its file, the row says so, and a mode the runtime does not offer starts nothing. That is the whole of what was asked for first, and it ships without a single change to the app's UI.

### Incremental delivery

1. Phases 1–2 → the settings exist and are read. No behaviour change. Lands alone safely.
2. Phase 3 → **MVP**. Settings are honoured, strictly.
3. Phase 4 → every workflow opens; the prompt an agent wrote is finally visible.
4. Phase 5 → the settings become changeable without an editor.
5. Phase 6 → agents write them without being told the file format.

### Where this is most likely to go wrong

- **T020/T021.** A later reader will see the workflow path duplicating what `ACPSession.apply` does and tidy it into a call to `apply`. That single change silently restores the fallback and the feature is gone with no test failing unless T024 exists. T024 asserting *no agent started* is what stands between this feature and that afternoon.
- **T035.** Column-zero matching is the whole of E3. A regex that matches any `key:` will rewrite a `model:` nested under a trigger, and the person who finds out is the person reading the diff.
- **T008.** Forgetting the `triggering` guard puts a false sentence on a row, in the one place this feature exists to make true.

---

## Notes

- `[P]` = different files, no dependencies on incomplete tasks.
- Commit after each task or logical group; every checkpoint leaves the app working.
- The comments asked for in these tasks are not garnish. Three of them (T008, T021, T036) exist specifically to stop a later reader undoing a decision that looks, from the code alone, like an oversight.

---

## US2 walked by hand (2026-09-19)

Against a second copy of the app — a throwaway root and a throwaway project in `/tmp`
with three workflow files: one ordinary, one carrying all three settings, and one whose
schedule says `:15` so it cannot be read. The real app was left alone.

| # | What it did |
| --- | --- |
| P1 | Every one opened: ordinary, settings-carrying, unreadable, and archived |
| P2 | The unreadable one showed its problem in red **and** the file's raw text, fence and all |
| P3 | Held indirectly — the page is drawn from the live list, which P4 exercises |
| P4 | Deleting the open workflow's file returned the reader to the project page within seconds |
| P5 | The prompt was shown whole, monospaced and selectable, with nothing to edit it |
| P6 | No control on the page touches a trigger or the prompt body |
| P7 | Archiving from the page left it open, saying it will not run, offering Restore |
| P8 | Back returned to the project page |

Step 1 of [quickstart.md](./quickstart.md) §4 passed as written, and it also showed the
Core half of this feature working end to end for the first time: the settings-carrying
workflow's row read *"Every day at 2am, in a new agent, in plan mode, on Grok, using
grok-4"*, which is FR-027 visible on a real row.

Two things the walk found and the code now carries:

- **A tap gesture on the card never fires.** Neither `.onTapGesture` on the card itself
  nor on a clear `Rectangle` behind it did anything, while the play and archive buttons
  on the same card worked throughout. A `Button` behind the content does work, and that
  is what the row uses: the controls in front keep their own clicks and everything else
  falls through to it. Wrapping the card in a `Button` was not an option — it would have
  taken the clicks away from the three controls that must keep them.
- **Setting `openWorkflow` redrew nothing at first.** `ContentView` read it only inside
  the getter of the binding it handed to `NavigationStack`, and observation registers
  what a body reads while it runs, not what a stored closure reads later. `selection`
  had survived the same mistake because the body reads it in three other places anyway.
  The path is now read in `body`, with a comment saying why it must be.

The settings controls are US3's and are not on the page yet. What is there now is the
sentence they will sit under, because it is true with or without them: a `triggering`
workflow never applies a mode, and the page says so.
