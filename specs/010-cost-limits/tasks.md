---
description: "Task list for Cost Limits"
---

# Tasks: Cost Limits

**Input**: Design documents from `/specs/010-cost-limits/`

**Prerequisites**: [plan.md](./plan.md), [spec.md](./spec.md), [research.md](./research.md), [data-model.md](./data-model.md), [contracts/](./contracts/), [quickstart.md](./quickstart.md)

**Tests**: Included. Every rule in this feature works by *refusing* to act, and a refusal leaves nothing behind to click on — a cap that silently never fires looks exactly like a cap that was never reached. Money is also the one thing that cannot be validated by trying it: the fake runtime's `cost` block is how this feature is exercised without spending anything. `quickstart.md` names every case.

**Organization**: Grouped by user story, in the priority order the spec sets. Each phase is shippable without the next.

**The one rule that governs everything below**: the turn is the unit, and a limit never cuts a turn short. Any task that reaches into `turnTasks`, cancels a running turn, or acts on mid-turn `Usage` has misread the spec.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (US1–US3)

## Path Conventions

An existing Swift package plus a macOS app and an iOS remote. The line between the two source roots is the one `Package.swift` already draws:

- `Packages/AgentsKit/Sources/AgentsKitCore/` — everything both platforms can hold. No `Process`, no `posix_spawn`, no PTY, and no file system.
- `Packages/AgentsKit/Sources/AgentsKit/` — the Mac's half: the daemon, the stores, the runtimes.
- `App/Sources/` — the SwiftUI Mac app. `Remote/Sources/` — the iOS remote. Both source roots are globbed by `project.yml`, so a new folder needs `xcodegen generate`.
- `Packages/AgentsKit/Tests/AgentsKitTests/{Unit,Integration}/` — Swift Testing.

---

## Phase 1: Setup (Baseline)

**Purpose**: Establish that cost already flows end to end before anything is built on it, so a break in the existing path is visible rather than blamed on this feature.

- [X] T001 Run `swift test --package-path Packages/AgentsKit --filter TurnUsageTests` and confirm `theTurnsOwnUsageIsRecordedOnceAndAddedUp` in `Packages/AgentsKit/Tests/AgentsKitTests/Integration/TurnUsageTests.swift` passes. This is the only existing test that asserts a cost is banked, and it is the file User Story 1 extends
- [X] T002 Read `finishTurn(agentID:result:)` and `sendNextQueued(to:)` in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Commands.swift` end to end before editing either. `finishTurn` holds the only five lines in the codebase that ever add to `costToDate`; `sendNextQueued` is the single funnel every turn begins through, and its doc comment already states the behaviour a held prompt must reuse — "a runtime that will not start leaves the words exactly where they were"
- [X] T003 Confirm the fake runtime can report money: check that `FakeACPAgent.Script.usage` in `Packages/AgentsKit/Tests/AgentsKitTests/Fake/FakeACPAgent.swift` carries a `cost` dictionary through to `TurnUsage.cost`. Every test below is vacuous without it, and a vacuous cost test passes

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: The model, the vocabulary and the two stores. Every user story needs all of it.

**⚠️ CRITICAL**: No user story work can begin until this phase is complete.

### The model — `AgentsKitCore`

- [X] T004 [P] Create `Packages/AgentsKit/Sources/AgentsKitCore/Model/CostLimits.swift` with `public struct CostLimits: Codable, Hashable, Sendable` holding `public var perAgent: Cost?` and `public var daily: Cost?`. Both reuse the existing `Cost` (amount plus currency) rather than a bare `Decimal`, because FR-005 makes the currency part of the limit. Document `nil` as "no limit, and the state before the reader has said anything" and document that a limit of **zero is a real limit that is immediately reached** and must never be collapsed into `nil`. Add `var isEmpty: Bool` (both `nil`) and `func headroom(in currency: String, against spent: [String: Decimal]) -> Decimal?` returning the limit amount less what was spent in that currency, floored at zero, and `nil` when there is no limit in that currency. Separate from `Usage.swift` deliberately: `Usage` is what a runtime reported, `CostLimits` is what the reader will allow, and only the second is ever written by a person
- [X] T005 [P] Create `Packages/AgentsKit/Tests/AgentsKitTests/Unit/CostLimitTests.swift` covering `CostLimits` alone for now: `isEmpty`, `headroom` in a currency with a limit and one without, a limit of zero returning zero headroom rather than `nil`, and spend exceeding the limit flooring at zero rather than going negative. Depends on T004
- [X] T006 Add `public var costCeiling: Cost?` to `Agent` in `Packages/AgentsKit/Sources/AgentsKitCore/Model/Agent.swift`, documented as "This agent's own ceiling, when the reader has given it one. Nil means the app-wide per-agent limit applies." Add `costCeiling` to the `CodingKeys` enum (line 158) so it is not swept into `unknownFields`, decode it with `try c.decodeIfPresent(Cost.self, forKey: .costCeiling)`, and encode it only when non-nil, following the `if !costToDate.isEmpty` precedent on line 135. Default it to `nil` in the memberwise initialiser
- [X] T007 Add four computed rules to `Agent` in `Packages/AgentsKit/Sources/AgentsKitCore/Model/Agent.swift`, all pure and all taking the limits as a parameter so nothing is stored: `func ceiling(under: CostLimits) -> Cost?` (`costCeiling` if set, else `limits.perAgent` — the only place precedence is decided); `func isAtCostLimit(under: CostLimits) -> Bool` (`costToDate[ceiling.currency] ?? 0 >= ceiling.amount`, false when there is no ceiling and false when `costIsUnmeasured`); `func costHeadroom(under: CostLimits) -> Decimal?` (nil when uncapped, which is how a view knows to show nothing); `var costIsUnmeasured: Bool` (`lastTurnUsage != nil && lastTurnUsage?.cost == nil && costToDate.isEmpty`). Add a doc comment saying these are computed and must never become stored state, in the style of the existing note on `filesToShow` that it "is not a state and must never become one" — a stored flag would be wrong between a limit being lowered and a sweep. Depends on T004, T006
- [X] T008 [P] Extend `Packages/AgentsKit/Tests/AgentsKitTests/Unit/CostLimitTests.swift` to exhaust the four rules: no ceiling set, a per-agent limit with no override, an override that raises and one that lowers, exactly at the limit (true — the spec says *reaches*, not *exceeds*), an unmeasured agent under every limit (always false, always uncapped), a limit in a currency the agent has not spent in, and lowering the limit below an existing total making the agent at-limit with no write and no sweep. Follow the exhaustive style of `Unit/AgentGroupTests.swift`. Depends on T007
- [X] T009 [P] Add a round-trip test to `Packages/AgentsKit/Tests/AgentsKitTests/Unit/AgentStoreTests.swift` asserting that an `Agent` JSON object written without a `costCeiling` key decodes as `nil`, does not gain the key in `unknownFields`, and that an unknown extra key written by a newer build survives a read-and-write by this one. Depends on T006
- [X] T010 [P] Add `case costLimit` to `EndedReason` in `Packages/AgentsKit/Sources/AgentsKitCore/Model/EndedReason.swift`, beside `processDied` and `daemonGone` as an ending the app itself knows about rather than one the protocol reports. Return `"Reached its cost limit"` from `summary`. Leave `isFinish` false (it falls out of the existing `self == .endTurn`) and leave `init?(stopReason:)` untouched — nothing on the wire ever spells this. Adding it to the one `summary` switch is what makes the phone and the window say the same words, which is why that switch is in Core
- [X] T011 [P] Add `case dayLimitReached` to `WorkflowRefusal` in `Packages/AgentsKit/Sources/AgentsKitCore/Model/WorkflowOutcome.swift` with `message` of `"the day's spending limit has been reached"`, `needsAPerson: false` (midnight resolves it with nobody doing anything, the same shape as `missedWhileClosed`), and the flat case added to `isSameReason(as:)` so twenty refusals over an exhausted evening collapse to one row with a count

### The vocabulary — `DaemonAPI`

- [X] T012 [P] Add to `Packages/AgentsKit/Sources/AgentsKitCore/Daemon/DaemonAPI.swift`: `public static let costState = "cost/state"`, `public static let costSetLimits = "cost/setLimits"` and `public static let agentsSetCeiling = "agents/setCeiling"` to `Method`; `public static let costChanged = "cost/changed"` to `Notification` (beside `projectChanged`, whose comment about carrying the whole resolved fact rather than a delta applies verbatim); and `public static let dayLimitReached = -32017` to `Failure`. None of these goes anywhere near `AppService` or the MCP surface — see T053
- [X] T013 [P] Add the request and response types to `Packages/AgentsKit/Sources/AgentsKitCore/Daemon/DaemonAPI.swift` per [contracts/daemon-api.md](./contracts/daemon-api.md): `CostState` (`limits: CostLimits`, `today: [String: Decimal]`, `day: String`), `SetLimitsRequest` (`perAgent: Cost??`, `daily: Cost??` — absent means "leave it", present-and-null means "no limit", and the double optional is what distinguishes them), and `SetCeilingRequest` (`agentID: UUID`, `ceiling: Cost?`). Document `day` as `yyyy-MM-dd` and as the only signal a window should use to notice a rollover — a window must never consult its own clock, since it may be in a different time zone from the daemon's

### The stores — `AgentsKit`

- [X] T014 [P] Add `public var limits: URL { root.appendingPathComponent("limits.json") }` and `public var spend: URL { root.appendingPathComponent("spend.json") }` to `StoreLocations` in `Packages/AgentsKit/Sources/AgentsKit/Store/StoreLocations.swift`, beside `projects`, `workflows` and `optionCache`, each with a comment in the style of those three saying what it holds and why it is one file. Note in the comment that one root is one budget, so a branch build pointed at its own root has its own limits and its own day
- [X] T015 Create `Packages/AgentsKit/Sources/AgentsKit/Store/LimitStore.swift` holding the reader's `CostLimits`, with `load()` and `save(_:)`, modelled on `ProjectStore` in the same folder. A missing or unreadable file is an empty `CostLimits` — a daemon that cannot read its limits must not refuse to work and must not invent a limit nobody set. Use `StoreCoding.encoder`/`decoder`. Depends on T004, T014
- [X] T016 Create `Packages/AgentsKit/Sources/AgentsKit/Store/SpendLedger.swift` persisting `{"days": {"yyyy-MM-dd": {"USD": 12.34}}}` per [data-model.md](./data-model.md). API: `func add(_ cost: Cost, on date: Date)` which adds into that date's local-day bucket and writes, and `func total(on date: Date) -> [String: Decimal]`. The day stamp is the machine's local calendar day from `Calendar.current`, taken at the moment of banking; the day a spend belongs to is the day its turn ended and is never re-attributed. Prune anything older than seven days on write — seven exists to make every boundary question unambiguous, **not** to offer history, and must not be surfaced anywhere. A missing or unreadable file is an empty ledger. Take the date as a parameter throughout so the rollover is testable without waiting for midnight. Depends on T014
- [X] T017 [P] Create `Packages/AgentsKit/Tests/AgentsKitTests/Unit/SpendLedgerTests.swift`: banking on one day and reading on the next returns zero; two currencies on the same day stay separate and are never summed; pruning drops the eighth day and keeps the seventh; a missing file reads as empty; an unreadable file reads as empty rather than throwing; and a day stamp taken either side of a time-zone change is still one day each. Depends on T016
- [X] T018 Add `lazy var limitStore = LimitStore(locations: locations)` and `lazy var spendLedger = SpendLedger(locations: locations)` to `DaemonCore` in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore.swift`, beside the existing `lazy var projectStore` and `lazy var workflowStore`. Depends on T015, T016

**Checkpoint**: The rules are exhausted by unit tests, the files round-trip, and nothing in the daemon's behaviour has changed yet.

---

## Phase 3: User Story 1 — An agent that runs away stops itself (P1) 🎯 MVP

**Goal**: One agent, on its own, cannot spend more than the reader allowed. The turn it is in finishes first.

**Independent Test**: Set a per-agent limit low enough to reach in a few turns. Start one agent and leave it. It stops on its own, its row says the limit stopped it, and the figure beside it does not keep climbing.

### The daemon

- [X] T019 [US1] In `finishTurn(agentID:result:)` in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Commands.swift`, immediately after the existing `agent.costToDate[cost.currency] = …` line, check `agent.isAtCostLimit(under: limitStore.load())` and, when true, use `.costLimit` as the reason passed to `move(agentID, on: .turnEnded(.costLimit), endedReason: .costLimit)` in place of the turn's own reason. Banking is what makes the limit true, so the check belongs on the line after it and nowhere earlier. `AgentState.applying` already sends any `turnEnded` reason that is not `endTurn` to `.stopped`, so the transition table needs no change. Depends on T007, T010, T015
- [X] T020 [US1] In that same branch of `finishTurn` in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Commands.swift`, `await record(.runtimeNote(…), for: agentID)` a sentence in the app's own voice naming the limit and what the agent had actually spent — the real figure, which may exceed the limit, never one clamped to it (FR-011). The agent reads its own history, so this is written for a reader and an agent at once, in the style of the existing `runtimeNote` calls in this file. Depends on T019
- [X] T021 [US1] Add a guard to `sendNextQueued(to:)` in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Commands.swift` refusing to begin a turn when `agent.isAtCostLimit(under:)`. Place it beside the existing `!agent.state.hasTurnInFlight` guard and **return without removing anything from the queue**, matching the function's existing promise that words stay exactly where they were. This one guard covers a person typing, a queued prompt draining, a workflow's prompt and 011's restart pick-up, because all four arrive here. Depends on T019
- [X] T022 [US1] Make `drainQueue(after:)` in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Commands.swift` write a `runtimeNote` explaining that the agent is at its limit and the queued words are still waiting, rather than the generic "Could not send what you queued" — but only once per hold, not once per drain attempt, so an agent at its limit does not fill its own transcript. Depends on T021
- [X] T023 [US1] Implement `public func setCeiling(_ request: DaemonAPI.SetCeilingRequest) async throws -> Agent` in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Commands.swift`, beside `setOption`. Sets `agent.costCeiling`, calls `changed(agent)`, returns the updated agent. Throws `noSuchAgent` for an unknown id. It must **not** send a prompt: raising a ceiling makes an agent promptable again, and continuing is the reader's second, deliberate act (FR-018). Depends on T006, T013
- [X] T024 [US1] Route `agents/setCeiling` in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Dispatch.swift`, following the shape of the `agentsSetOption` case. Depends on T023
- [X] T025 [P] [US1] Add the client call to `AgentsModel` in `Packages/AgentsKit/Sources/AgentsKitCore/Client/AgentsModel.swift`, beside the existing per-agent calls. Depends on T013

### What the reader sees

- [X] T026 [US1] Add a `Settings` scene to `AgentsApp.swift` in `App/Sources/` — the app's first; it is currently a bare `WindowGroup` with one command. This is what gives the app ⌘, and the menu item, and it is what makes User Story 1 testable by hand at all
- [X] T027 [US1] Create `App/Sources/Settings/CostSettingsView.swift` with the per-agent limit: an amount and a currency, an explicit way to clear it back to no limit, and a statement of what it is measured against ("across an agent's whole life"). Clearing must be its own action — a zero is a limit that stops everything, never a way to turn the limit off (T004). When the figure entered is already below what some agent has spent, say so at the moment it is set (FR-006). Depends on T026
- [X] T028 [US1] Run `xcodegen generate` after adding `App/Sources/Settings/`. `project.yml` globs `App/Sources`, so the folder is picked up, but the project file must be regenerated before it builds. Depends on T027
- [X] T029 [P] [US1] In `ContextMeter.swift` in `App/Sources/Chat/`, show the headroom beside the cost it already shows — `$0.42 of $2.00` — using `agent.costHeadroom(under:)`, and show nothing extra when there is no limit, matching the file's existing rule that a figure which comes and goes is one you stop trusting. Depends on T007
- [X] T030 [P] [US1] Add the ending words to `AgentRow.swift` in `App/Sources/AgentList/` and `AgentCard.swift` in `Remote/Sources/Projects/`. Both read `EndedReason.summary`, so if the switch in T010 is right this may be nothing more than confirming both already say "Reached its cost limit" without a local change. Depends on T010
- [X] T031 [US1] In `PromptBar.swift` in `App/Sources/Chat/`, when the open agent is at its limit, say so and offer exactly two things: raise the limit, or let this one agent go on. Neither may happen without the reader choosing it, and neither may be the default action (FR-018). Depends on T025, T007

### Tests

- [X] T032 [P] [US1] Extend `Packages/AgentsKit/Tests/AgentsKitTests/Integration/TurnUsageTests.swift`: with a per-agent limit set and a scripted cost that crosses it, assert the crossing turn is **recorded in full** before the agent stops, the ending is `.costLimit`, the state is `.stopped`, and `costToDate` holds the real figure rather than one clamped to the limit. Depends on T019, T020
- [X] T033 [P] [US1] Create `Packages/AgentsKit/Tests/AgentsKitTests/Integration/CostLimitTests.swift` with the per-agent cases: a prompt to an at-limit agent leaves the words on the queue and sends nothing; a ceiling set on one agent changes no other agent and neither app-wide limit; raising that agent's ceiling makes it promptable again but does **not** resume it by itself. Depends on T021, T023

**Checkpoint**: A runaway agent stops itself, and nothing else in the app has changed. Shippable.

---

## Phase 4: User Story 2 — A day cannot cost more than you said (P2)

**Goal**: A ceiling on the whole day that binds automation as much as a person, and that holds overnight with no window open.

**Independent Test**: Set a daily limit low enough to reach within a sitting. Run agents until it is reached. Nothing further starts — including a workflow firing on a schedule — every attempt says why, and after the day rolls over work starts again with no action from the reader.

### Counting the day

- [X] T034 [US2] In `finishTurn(agentID:result:)` in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Commands.swift`, bank the same cost into `spendLedger.add(cost, on: Date())` **before** `changed(agent)` and before any broadcast, following the codebase's rule that the record is written before the windows are told — a daemon killed mid-bank must come back having counted the money. Depends on T016, T018
- [X] T035 [US2] Broadcast `cost/changed` carrying the whole `CostState` from `finishTurn` in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Commands.swift`, after the ledger write and beside the existing `changed(agent)`. Once per turn that reported a cost — not once per currency and not once per agent. A runtime that reported no cost broadcasts nothing. Depends on T013, T034
- [X] T036 [US2] Implement `cost/state` and `cost/setLimits` in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Commands.swift` per [contracts/daemon-api.md](./contracts/daemon-api.md). `setLimits` writes `limits.json` before returning and before broadcasting, returns the resulting `CostState` so the caller sees the result rather than assuming it, accepts a limit lower than what is already spent without erroring, and — when the daily limit is raised — drains anything holding on the same call so work resumes with no restart (FR-017). Depends on T015, T018
- [X] T037 [US2] Route `cost/state` and `cost/setLimits` in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Dispatch.swift`. Depends on T036
- [X] T038 [P] [US2] Add `costState` to `AgentsModel` in `Packages/AgentsKit/Sources/AgentsKitCore/Client/AgentsModel.swift`, fed by the `cost/changed` notification and seeded by `cost/state` on connect, following how projects are seeded by `projects/list` and kept current by `project/changed`. Derive `dayLimitReached`, `dayHeadroom` and `dayIsCloseToFull` client-side; they are never sent. Depends on T013

### Refusing on the day

- [X] T039 [US2] Add the daily guard to `sendNextQueued(to:)` in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Commands.swift`, beside the per-agent guard from T021 and with the same behaviour: return, leave the words on the queue, send nothing. Depends on T021, T034
- [X] T040 [US2] Guard `start(_:)` in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Commands.swift` with `dayLimitReached`, whose message names the limit and what has been spent (FR-015 forbids a silent refusal). Place it **before** the session is made — refusing after spawning a runtime costs a process for a turn that was never going to run. A new agent has no queue to wait on, which is why this is a refusal where a prompt is a hold. Depends on T012, T034
- [X] T041 [US2] Add a `dayLimitReached` parameter to `Workflow.refusalIfBlocked(…)` in `Packages/AgentsKit/Sources/AgentsKitCore/Model/Workflow.swift`, keeping the function pure, and pass it from `fire(_:on:…)` in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Workflows.swift`. Order it after `archived` and `paused` — a workflow the person put away or paused is refused for that reason, not for the budget. The refusal must not pause the workflow or alter its schedule (FR-014). Depends on T011, T034
- [X] T042 [US2] Notice the rollover in `tickWorkflows(now:)` in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Workflows.swift`: when the local day stamp differs from the last one seen, broadcast the new `CostState` and drain every agent with queued prompts. Reuse the existing 15-second heartbeat rather than adding a timer, and take `now` from the parameter it already accepts so this is testable without waiting for midnight. A held agent must become promptable **where it stands**, with its conversation intact (FR-012). Depends on T035, T039
- [X] T043 [US2] Add the daily limit to `App/Sources/Settings/CostSettingsView.swift`: the amount, the currency, an explicit clear, what today has cost so far, and what is left. Depends on T027, T038

### Tests

- [X] T044 [P] [US2] Extend `Packages/AgentsKit/Tests/AgentsKitTests/Integration/CostLimitTests.swift`: `agents/start` refused with `dayLimitReached` while `agents/prompt` succeeds and leaves words queued; a turn in flight when the limit is reached completes and then nothing drains; the ledger is written before `cost/changed` is broadcast; a daemon restarted mid-day resumes the day's true total rather than zero; raising the daily limit drains what was holding on the same call; the rollover drains without the reader acting and without the agent being restarted. Depends on T034, T039, T040, T042
- [X] T045 [P] [US2] Extend `Packages/AgentsKit/Tests/AgentsKitTests/Integration/WorkflowRefusalTests.swift` with a fire refused by the day's limit: assert the recorded outcome is `dayLimitReached`, that `needsAPerson` is false, that the workflow is neither paused nor rescheduled, and that twenty consecutive refusals collapse to one entry with a count. Assert on the recorded outcome, never on the absence of an agent. Depends on T041

**Checkpoint**: The bill is bounded overnight, unattended, with no window open. Shippable.

---

## Phase 5: User Story 3 — You can see what you are spending and how much is left (P3)

**Goal**: What this agent cost, what today cost, and what is left — in one look, from a surface the reader is already on.

**Independent Test**: With both limits set, run an agent part-way to each. Without opening anything, read off all three figures.

- [X] T046 [US3] Replace the sitting's total with today's in `ProjectListView.swift` in `App/Sources/Projects/` (line 170), reading `model.costState` instead of `model.sessionCost`, and show the day's headroom beside it. Argued in [research.md §7](./research.md): today's figure is what the limit is measured against, survives closing the window, and needs no baseline subtraction — and two similar money figures in one sidebar is how a reader learns to trust neither. Depends on T038
- [X] T047 [US3] Retire `sessionCost`, `spentBeforeWeWatched` and `noteWhatWasAlreadySpent()` from `AppModel.swift` in `App/Sources/`, and `Cost.spent(by:since:)` from `Packages/AgentsKit/Sources/AgentsKitCore/Model/Usage.swift` if nothing else calls it. Grep before deleting. Depends on T046
- [X] T048 [P] [US3] Apply the app's existing "needs a person" colour to a limit that is close to being reached, in `ContextMeter.swift` and in the sidebar figure, reusing `Usage.closeToFull` rather than introducing a second threshold for readers to learn (FR-025). Depends on T029, T046
- [X] T049 [P] [US3] Show the agent's headroom on the phone in `RemoteChatView.swift` in `Remote/Sources/Chat/` (line 164), matching `ContextMeter`. The phone shows limits and never sets them. Depends on T029, T038
- [X] T050 [P] [US3] In `App/Sources/Settings/CostSettingsView.swift`, show what the limits have actually stopped — so the answer to "why did that not run" sits in the same place as the number that caused it. Depends on T043
- [X] T051 [P] [US3] Add a client test to `Packages/AgentsKit/Tests/AgentsKitTests/Unit/AgentsModelTests.swift` asserting that `costState` is seeded on connect, updated by `cost/changed`, and that a changed `day` resets the client's idea of today without the client consulting its own clock. Depends on T038

**Checkpoint**: All three stories are independently functional.

---

## Phase 6: The cases that are easy to get wrong

**Purpose**: Four rules that are invisible when correct and silently harmful when not. None of them is polish.

### An agent whose runtime reports no cost

> The worst failure available to this feature: a reader sets a limit, sees no warning, and believes they are covered when nothing is capped.

- [X] T052 Label an unmeasured agent wherever its cost would otherwise be — `ContextMeter.swift`, `AgentRow.swift`, `RemoteChatView.swift`, `AgentCard.swift` — as unable to be measured. It must **never** be shown as within a limit, at any headroom, on any surface (FR-013). Depends on T007, T029
- [X] T053 Say in `App/Sources/Settings/CostSettingsView.swift` that a runtime reporting no cost cannot be capped, and that the day's total is therefore a floor rather than a fact while such an agent is running. The spec requires this be stated rather than rounded away. Depends on T043
- [X] T054 [P] Add integration coverage to `Packages/AgentsKit/Tests/AgentsKitTests/Integration/CostLimitTests.swift` with a fake runtime scripted to report **no** `cost`: the agent runs past both limits without stopping, contributes nothing to the day's total, and `costIsUnmeasured` is true. Depends on T007, T034

### The rest

- [X] T055 [P] Add two-currency coverage to `Packages/AgentsKit/Tests/AgentsKitTests/Integration/CostLimitTests.swift`: a limit in USD does not cap spend in GBP, GBP spend is counted in the ledger under its own key, and nothing anywhere adds or converts the two. The display already refuses to sum them; a limit cannot be more permissive about arithmetic than the display is
- [X] T056 [P] Assert in `Packages/AgentsKit/Tests/AgentsKitTests/Unit/CostLimitTests.swift` that a limit of zero stops everything and is never treated as no limit, and that clearing a limit requires an explicit null. Depends on T005
- [X] T057 Confirm nothing an agent or a workflow can reach raises or removes a limit (FR-007, SC-009): grep `Packages/AgentsKit/Sources/AgentsKit/ACP/Serve/AppService.swift`, `DaemonCore+AppTools.swift` and the MCP tool surface for `costSetLimits`, `agentsSetCeiling` and `cost/` and find nothing. Add a test asserting the served tool list does not contain them. This is 008's rule about the chain-depth limit applied to money: a runaway that can raise its own limit is not stopped. Depends on T012, T023, T036
- [X] T058 Confirm no path cuts a turn short: grep the diff for `turnTasks` and for any use of mid-turn `Usage.cost` in a gate. A transcript ending mid-tool-call is a bug in this feature, not an acceptable cost of enforcement

---

## Phase 7: Polish & Cross-Cutting

- [X] T059 Run every scenario in [quickstart.md](./quickstart.md) by hand against a throwaway root (`open Agents.app --args --root /tmp/agents-cost-test`), including the unmeasured case, which is the easy one to skip
- [X] T060 [P] Confirm SC-010 by clearing both limits: nothing is stopped, nothing is refused, nothing new is shown, and the app behaves exactly as it did before this feature. The feature must be invisible when off
- [X] T061 [P] Confirm `agents/stop`, `agents/archive` and `agents/unqueue` all still work while both limits are reached. The reader must always be able to stop and tidy up, budget or no budget
- [X] T062 Run `swift test --package-path Packages/AgentsKit` and `xcodebuild -scheme Agents -destination 'platform=macOS' -skipPackagePluginValidation build`, and build the Remote target — `AgentsKitCore` must stay free of anything iOS cannot hold

---

## Not in this feature

Named so they are not drifted into:

- Weekly, monthly, per-project or per-runtime limits. The daily limit is the one that bounds an unattended overnight run.
- Spending history — charts, a ledger view, spend by project over time. The seven-day pruning window exists for boundary correctness and must not be surfaced.
- Estimating cost for runtimes that report none. It is the estimate the app refuses to make everywhere else, and a limit enforced on a guess is worse than no limit because it looks like one.
- Currency conversion, or any figure that is not the runtime's own.
- Deciding what else belongs in the new Settings window.
- Setting limits from the phone. The Remote shows them.

---

## Dependencies

### Phase order

- **Phase 1 (Setup)**: no dependencies
- **Phase 2 (Foundational)**: blocks every user story
- **Phase 3 (US1)**: after Phase 2
- **Phase 4 (US2)**: after Phase 2. Independent of US1 in behaviour, but both edit `finishTurn` and `sendNextQueued` — US1 adds the ceiling check, US2 adds the ledger bank and the daily guard. Different lines, same two functions, so sequence them rather than running them in parallel
- **Phase 5 (US3)**: needs T038 from Phase 4 for the day's figure, and T029 from Phase 3 for the agent's
- **Phase 6**: after the story it checks; T057 and T058 after everything
- **Phase 7**: last

### The one cross-story coupling

US3's sidebar work (T046) reads `costState`, which US2 builds (T038). US3 is otherwise independent: the per-agent headroom in T029 belongs to US1 and ships with it.

---

## Parallel execution examples

**Phase 2, after T004 and T006:**

```text
T005  CostLimits unit tests
T009  Agent round-trip test
T010  EndedReason.costLimit
T011  WorkflowRefusal.dayLimitReached
T012  DaemonAPI names and failure code
T013  DaemonAPI request/response types
T014  StoreLocations paths
```

**Phase 3, after the daemon work (T019–T025):**

```text
T029  ContextMeter headroom
T030  AgentRow and AgentCard wording
T032  TurnUsageTests extension
T033  Integration/CostLimitTests
```

**Phase 6, all four checks:**

```text
T054  Unmeasured runtime
T055  Two currencies
T056  A limit of zero
T057  Out of agents' reach
```

---

## Implementation strategy

### MVP (User Story 1 only)

1. Phase 1 → Phase 2 → Phase 3.
2. **Stop and validate**: set a per-agent limit, let an agent run into it, confirm the turn finished whole and the agent stopped.
3. This alone turns a number you watch into a number that holds — which is the thing the app could not do at all.

### Incremental

1. Setup + Foundational → the rules are exhausted by unit tests and nothing has changed yet.
2. US1 → a runaway agent stops itself. Ship.
3. US2 → the day is bounded, including overnight and including automation. Ship.
4. US3 → the limits stop being a surprise. Ship.
5. Phase 6 before calling any of it done.

### Notes

- Commit after each task or logical group.
- Every gate belongs in the daemon. A limit enforced in the app would not bind a workflow firing at 3am with no window open — that is the whole reason for the shape of this plan.
- Avoid: storing "at its limit" as state; cutting a turn short; throwing away words a person typed; adding a second "nearly full" threshold; letting any of this reach an agent.
