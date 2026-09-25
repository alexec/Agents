---

description: "Task list for 029, starting agents on iPhone"
---

# Tasks: Starting agents on iPhone

**Input**: Design documents from `specs/029-start-agents-on-iphone/`

**Prerequisites**: [plan.md](./plan.md), [spec.md](./spec.md), [research.md](./research.md),
[data-model.md](./data-model.md), [contracts/](./contracts/), [quickstart.md](./quickstart.md)

**Tests**: Included for every daemon and core rule, because [quickstart.md](./quickstart.md) §1
names each one. Screens are proven by screenshots and Alex's walk, not by UI tests. Never mutate
source to prove a test: assert the property directly (memory).

**Where**: All work is in the worktree `/tmp/w-029`, branch `029-start-agents-on-iphone`. Never
the shared checkout. After adding files under `Remote/Sources/`, run `xcodegen generate` (the
project is not in git). Build with plugin validation skipped, one scheme at a time (memory).

**Correction to plan.md**: `ModeStore` goes in `Packages/AgentsKit/Sources/AgentsKit/Store/`,
beside `OptionCache.swift`, not in `Daemon/`.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependency on an unfinished task)
- **[Story]**: US1 start with a prompt, US2 choose how it starts, US3 attach a picture or file

---

## Phase 1: Setup

**Purpose**: The wire additions every story leans on. All optional, so nothing existing changes.

- [ ] T001 Add `requestID: UUID?` to `DaemonAPI.StartRequest` in `Packages/AgentsKit/Sources/AgentsKitCore/Daemon/DaemonAPI.swift`: in the memberwise `init` with a `nil` default, and decoded with `decodeIfPresent` in `init(from:)`. Doc comment: "Minted once per send by the caller and reused on every retry of that send. `nil` from callers that do not retry."
- [ ] T002 [P] Add `startRequestID: UUID?` to `Agent` in `Packages/AgentsKit/Sources/AgentsKitCore/Model/Agent.swift`, beside `startedByAgent`: `decodeIfPresent`, `encodeIfPresent`, add it to `CodingKeys`, and document it as "Written on the first save, never changed."
- [ ] T003 [P] Add to `DaemonAPI` in `Packages/AgentsKit/Sources/AgentsKitCore/Daemon/DaemonAPI.swift`: `Method.agentsDiscardDraft = "agents/discardDraft"` with `DiscardDraftRequest { draftID: UUID }`; `Method.modesRemembered = "modes/remembered"`; `Method.modesImport = "modes/import"` with `ModesImportRequest { modes: [String: JSONValue] }`; `Notification.modesChanged = "modes/changed"`. The payload of the result and of the notification is `[String: JSONValue]`, keyed by runtime id ([contracts/daemon-api.md](./contracts/daemon-api.md)).
- [ ] T004 Add to `Packages/AgentsKit/Tests/AgentsKitTests/Unit/` a decode test that proves a `StartRequest` without `requestID` and an `Agent` record without `startRequestID` (a fixture written before this feature) both decode, and that both fields round-trip when present. Depends on T001, T002.

---

## Phase 2: Foundational

**Purpose**: Things both apps must agree on, moved into AgentsKitCore before either app uses them.

**⚠️ No story can start until this phase is done.**

- [ ] T005 Move `AppModel.defaultRuntimeID`'s rule into `AgentsModel.defaultRuntimeID(available: [String]) -> String?` in `Packages/AgentsKit/Sources/AgentsKitCore/Client/AgentsModel.swift`, with its rule unchanged: "the runtime of the most recently active agent that is still available, else the first available one". Make `App/Sources/AppModel.swift`'s `defaultRuntimeID` call it. Add a unit test in `Packages/AgentsKit/Tests/AgentsKitTests/Unit/DefaultRuntimeTests.swift` that gives the same answer the old property gave for three agent lists: empty, one recent unavailable runtime, and mixed.
- [ ] T006 [P] Give the Remote a `runtimes/list` and `runtimes/accounts` fetch in `Remote/Sources/RemoteModel.swift`, refreshed with everything else in `refreshEverything`, exposing `runtimes: [RuntimeStatus]` and `promptCapabilities(for runtimeID:) -> ACP.PromptCapabilities` read the same way `AppModel.promptCapabilities` reads them. Add both to `Remote/Sources/Preview/FakeDaemon.swift` and `Canned.swift` so previews have two runtimes, one of them unavailable with a reason.
- [ ] T007 [P] Add a `-start` DEBUG launch argument to `RemoteModel.openFromLaunchArguments` in `Remote/Sources/RemoteModel.swift`. After `-project <name>` it opens the start sheet on that project, so the sheet can be screenshotted without taps (memory: no Simulator GUI). Expose it as `var startingIn: URL?`, which the sheet in T010 presents from.

**Checkpoint**: `swift test` green. Both apps build.

---

## Phase 3: User Story 1 - Start an agent in a project with a prompt (Priority: P1) 🎯 MVP

**Goal**: From a project on the phone, type a prompt, send it, and land in the new agent's conversation. The agent runs in that project's folder on the Mac. It starts once or not at all, and a typed prompt is never lost.

**Independent Test**: On the same network as a scratch daemon, open a project, start an agent with a one-line prompt and nothing chosen, and confirm it runs in that folder, shows on the Mac and the phone, and replies. The cellular version waits on 013 Track A ([quickstart.md](./quickstart.md) §4).

### Tests for User Story 1

- [ ] T008 [P] [US1] Write `Packages/AgentsKit/Tests/AgentsKitTests/Unit/StartIdempotencyTests.swift` against the fake runtime the other `DaemonCore` tests use. It covers: two `start` calls with the same `requestID` return the same id and make one agent; a second call made while the first is still in flight waits and returns the first's id; after the agent store is reloaded (a fresh `DaemonCore` on the same root), the same `requestID` returns the stored agent; a start refused for `dayLimitReached` records nothing, so a retry with the same id after raising the limit starts one agent; a start with no `requestID` behaves as today.
- [ ] T009 [P] [US1] Write `Packages/AgentsKit/Tests/AgentsKitTests/Unit/DraftLifetimeTests.swift`. It covers: `agents/discardDraft` ends the draft's session; discarding an unknown, used or already-ended draft returns success; a draft whose connection went is still usable within the grace period and is ended after it (inject the clock and the 30 s grace period rather than sleeping); workflow drafts, which have no connection, are never orphaned.

### Implementation for User Story 1

- [ ] T010 [US1] Make `agents/start` idempotent in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Commands.swift`: keep `startsByRequest: [UUID: Task<UUID, any Error>]` on `DaemonCore`. For a `requestID` already there, await it. Otherwise look for an agent with that `startRequestID` in the store, and failing that start and record the task. Remove the entry when the start throws, so a refused start records nothing. Set `startRequestID` on the `Agent` before its first save. Depends on T001, T002. Makes T008 pass.
- [ ] T011 [US1] Give drafts an owner in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore.swift` and `DaemonCore+Commands.swift`: add `connection: UUID?` and `orphanedAt: Date?` to `Draft`; have `options(_:)` take the calling connection from dispatch; add `discardDraft(_:)`, which removes the draft and calls `endDraft` and never throws for an unknown id; add `orphanDrafts(connection:)`, which stamps `orphanedAt` and schedules an end after the grace period (30 s, injectable) unless the draft was used or discarded first. Route `agents/discardDraft` in `DaemonCore+Dispatch.swift`, and call `orphanDrafts` from `onDisconnected` in `Packages/AgentsKit/Sources/AgentsKit/Daemon/Daemon.swift` beside `forgetPresence`. Makes T009 pass.
- [ ] T012 [US1] Discard replaced drafts on the Mac in `App/Sources/AppModel.swift`: in `loadDraftOptions`, before `draftID = nil`, send `agents/discardDraft` for the old id if there is one, without awaiting it and ignoring method-not-found. The Mac form behaves exactly as before; this only ends a process nobody will use. Depends on T011.
- [ ] T013 [US1] Add the start state to `Remote/Sources/RemoteModel.swift` as in data-model.md's "Phone start state": `project`, `runtimeID` (seeded from `work.defaultRuntimeID(available:)`), `draftID`, `options`, `chosen`, `optionsState` (`loading | ready | failed(String)`) and `pendingRequestID`. Add `openStart(in:)`, which calls `agents/options`, draws with `PromptControlsState.drawable` and seeds `chosen` from each `currentValue`. Handle `agents/draftOptions` for the current `draftID` the way `AppModel.settleDraft` does. Add `closeStart()`, which sends `agents/discardDraft` for an unused draft.
- [ ] T014 [US1] Add `startAgent(prompt:attachments:) async -> Bool` to `Remote/Sources/RemoteModel.swift`. Refuse before calling, keeping the draft, when `isStale` ("Your Mac is not answering, so nothing was started."), when `selectedSummary?.exists == false`, or when the project is archived, each in one sentence. Otherwise mint `pendingRequestID` once and send `StartRequest(runtimeID:cwd:prompt:attachments:startOptions:draftID:requestID:)`. On success set `selection` to the new id and clear the draft. On a `JSONRPCError`, set `problem` to its `message` as it is, not a fixed sentence. On a transport error, keep `pendingRequestID` and the draft and say "Checking whether it started…". Depends on T010, T013.
- [ ] T015 [US1] Reconcile an outstanding start on reconnect in `Remote/Sources/RemoteModel.swift`: after the reconnect refresh, if `pendingRequestID` is set, look in `work.agents` for an agent with that `startRequestID`. Found: clear the draft, clear `pendingRequestID` and open the agent. Not found: resend the same request once with the same `requestID`, and on failure keep the draft with the daemon's sentence. Depends on T014.
- [ ] T016 [US1] Keep the unsent prompt with `DraftStore` under `DraftKey.newAgent(folder: project)` in `Remote/Sources/StartAgent/StartDraftKeeper.swift` (new): save on every edit, debounced as the Mac's `App/Sources/Chat/DraftKeeper.swift` does; load when the sheet opens; clear only when a start has settled as started (FR-016, FR-017).
- [ ] T017 [US1] Build `Remote/Sources/StartAgent/StartAgentView.swift` (new) to [contracts/start-screen.md](./contracts/start-screen.md): a header with the project name and Cancel (Cancel keeps the draft and calls `closeStart`); the runtime shown as a read-only row for now; the choice rows placeholder filled in by T022; a multi-line prompt field that has focus on open, grows to about six lines and then scrolls; Send, disabled while the field is empty or a send is in flight; and `problem` shown above the prompt. Use `ReadableWidth` and the type scale from `Shared/UI/TypeScale.swift`. Depends on T013, T014, T016.
- [ ] T018 [US1] Add a "New agent" toolbar button to `Remote/Sources/Projects/ProjectPageView.swift`, always visible, presenting `StartAgentView` as a full-height sheet on iPhone and a form sheet on iPad, driven by `model.startingIn` so T007's `-start` flag opens it. Use the Mac's wording ("New agent", as in `App/Sources`).
- [ ] T019 [US1] Screenshot the sheet in the simulator with `-project <name> -start` against a scratch daemon's direct link, with the keyboard up and down, then settle the layout and correct [contracts/start-screen.md](./contracts/start-screen.md) to match what was settled (memory: settle the UX before building depth). Run [quickstart.md](./quickstart.md) §2 steps 1–3 over `daemon.sock` and record the results in this file under Notes.

**Checkpoint**: US1 works over the direct link. It is the MVP.

---

## Phase 4: User Story 2 - Choose how the agent starts (Priority: P2)

**Goal**: Pick the runtime and every choice it advertises. The same runtime and mode are offered first on the phone and the Mac, from one memory on the Mac.

**Independent Test**: On the phone, pick another runtime, change its model and mode, and start. On the Mac, confirm it started that way. Then open New agent on the Mac and confirm the same mode is offered first, and the other way round.

### Tests for User Story 2

- [ ] T020 [P] [US2] Write `Packages/AgentsKit/Tests/AgentsKitTests/Unit/ModeStoreTests.swift`. It covers: a start whose `startOptions` hold the runtime's mode option writes it; a `setOption` on the agent's mode option writes it, and one on a model option does not; `modes/import` fills gaps only and never overwrites an entry; "an entry that no longer decodes is treated as absent and left in the file"; each write broadcasts `modes/changed` with the whole map; the file is per root.

### Implementation for User Story 2

- [ ] T021 [US2] Create `ModeStore` in `Packages/AgentsKit/Sources/AgentsKit/Store/ModeStore.swift` (new), beside `OptionCache.swift` and built the same way: `modes.json` in the root's Application Support folder, shaped `{ "<runtimeID>": { "mode": <JSONValue>, "chosenAt": <ISO-8601> } }`, with `load`, `save`, `remember(_:for:)` and `importing(_:) -> [String: JSONValue]` (gaps only). Wire it into `DaemonCore`: write on a successful `start` when `ModeMemory.modeOption(in: session options)` has a value in `startOptions.values`; write in `setOption` after the runtime accepts it when the option is the agent's mode option; route `modes/remembered` and `modes/import` in `DaemonCore+Dispatch.swift`; broadcast `modes/changed` after every write. Makes T020 pass.
- [ ] T022 [US2] Hold the remembered modes in `AgentsModel` in `Packages/AgentsKit/Sources/AgentsKitCore/Client/AgentsModel.swift`: `rememberedModes: [String: JSONValue]`, set from `modes/remembered` and replaced on `modes/changed` (add the case to the notification switch), with `rememberedMode(for runtimeID:) -> JSONValue?`. Tolerate method-not-found as `refreshCostState` does.
- [ ] T023 [US2] Move the Mac onto the daemon's memory in `App/Sources/AppModel.swift`: `rememberedMode(for:)` reads `work.rememberedMode(for:)`, and `rememberMode(_:for:)` stops writing `UserDefaults`, because the daemon now writes on start and on `setOption`. Once per connection, read every `ModeMemory.defaultsKey(runtimeID:)` key present in `UserDefaults` and send them with `modes/import`, leaving the keys in place. The Mac's form opens on the same mode as before this change (quickstart §3). Depends on T021, T022.
- [ ] T024 [US2] Fetch `modes/remembered` in `Remote/Sources/RemoteModel.swift`'s refresh, and seed the mode in `openStart` with `ModeMemory.startingValue(remembered: work.rememberedMode(for:), for:)` on the first draw only, the same rule as `AppModel.show(options:opening:)`. Depends on T022.
- [ ] T025 [US2] Build `Remote/Sources/StartAgent/ChoiceRows.swift` (new) and put it in the sheet: a runtime `Menu` listing `model.runtimes` in the Mac's order, with unavailable ones disabled and their reason shown; a `Menu` per select option showing the chosen choice's name; a `Toggle` per boolean; in `ConfigOption.categoryOrder`. While loading, draw the cached rows if there are any, else "Getting <runtime>'s choices…". On failure, show the daemon's sentence and a Retry, and still allow Send with the runtime's defaults (US2 scenarios 4 and 7). Changing the runtime calls `closeStart()` and then `openStart` for the new one, and drops choices the new runtime does not offer. Every control's accessibility label names what it chooses ("Runtime, Claude Code").
- [ ] T026 [US2] Run [quickstart.md](./quickstart.md) §2 steps 4–5 and §3 on a scratch root, record the results under Notes, and screenshot the sheet with choices at default and at the largest Dynamic Type size.

**Checkpoint**: US1 and US2 both work. The Mac's behaviour is unchanged for the person.

---

## Phase 5: User Story 3 - Attach a picture or file to the first prompt (Priority: P3)

**Goal**: A photo or a text file goes with the first prompt, by value, refused before sending when the runtime cannot take it.

**Independent Test**: Start an agent from the phone with a photo attached, and confirm the agent on the Mac received it with the prompt.

### Tests for User Story 3

- [ ] T027 [P] [US3] Write `Packages/AgentsKit/Tests/AgentsKitTests/Unit/PhoneAttachmentTests.swift` for the pure rules, placed in AgentsKitCore so they can be tested: a picture is downscaled to "2048 px, JPEG" on the long edge; "900 KB" total by value is the limit, and a set over it is refused with a sentence naming it; UTF-8 text becomes an embedded resource; anything else is refused with one sentence; `Attachment.refusal(from:)` refuses an image without the `image` capability and a resource without `embeddedContext`.

### Implementation for User Story 3

- [ ] T028 [US3] Put the rules from T027 in `Packages/AgentsKit/Sources/AgentsKitCore/Model/PhoneAttachment.swift` (new): `downscaled(_ data: Data, maxEdge: 2048) -> Data?` with ImageIO, `fromFile(_ url: URL) -> Result<Attachment, Refusal>`, and `totalRefusal(_ attachments: [Attachment], limit: 900_000) -> String?`. Makes T027 pass.
- [ ] T029 [US3] Build `Remote/Sources/StartAgent/PhoneAttachments.swift` (new): an attach button offering a `PhotosPicker` (photo library) and a `fileImporter` (Files), each producing an `Attachment` through T028, plus a strip of what is attached, each item removable and showing `refusal(from: model.promptCapabilities(for: runtimeID))` under it. Put it in `StartAgentView`, and make `startAgent` refuse before sending when any attachment is refused or the total is over the limit, keeping everything (US3 scenario 2).
- [ ] T030 [US3] Keep attachments in the draft through T016's keeper. When `DraftStore` drops inline data for size, the sheet says which attachments need attaching again rather than dropping them silently.

**Checkpoint**: All three stories work.

---

## Phase 6: Polish, iPad and the gate

- [ ] T031 [P] Check the sheet as a form sheet on iPad in the simulator (screenshot), then mark 013's T072 in `specs/013-ipad-app/tasks.md` as carried by this feature, and update the start row of `specs/013-ipad-app/contracts/parity.md` to say what the remote offers and that folders, MCP servers and extra arguments stay on the Mac by decision (spec, Assumptions).
- [ ] T032 [P] Accessibility pass over `Remote/Sources/StartAgent/`: every control has a label, rows wrap rather than truncate at the largest Dynamic Type size, and the prompt keeps at least two lines visible with the keyboard up (FR-020).
- [ ] T033 Run the full `swift test` six times on this branch and six on `main`, and compare before blaming any failure on the branch (memory: the suite is broadly flaky). Build both schemes, one after the other.
- [ ] T034 **Gate, SC-006.** Hand Alex [quickstart.md](./quickstart.md) §4's real-iPhone walk, steps 1–6, and nothing an agent could have run. Record the date and anything found under Notes. The cellular test and SC-002's mobile timing are recorded as waiting on 013 Track A, not as passed.

---

## Dependencies & Execution Order

- **Phase 1** first. T001–T003 are independent; T004 needs T001 and T002.
- **Phase 2** needs Phase 1. T005, T006 and T007 are independent of each other.
- **US1** needs Phase 2. Inside it: T008 and T009 first (they fail); T010 and T011 are daemon work in the same file, so do them one after the other; T012 after T011; T013 → T014 → T015 on the phone; T016 is independent; T017 needs T013, T014 and T016; T018 after T017; T019 last.
- **US2** needs Phase 2 and, for the sheet, T017. T020 first; T021 → T022 → T023 and T024; T025 needs T024 and T017; T026 last.
- **US3** needs T017 and T006. T027 → T028 → T029 → T030.
- **Phase 6** after the stories it checks.

US2 and US3 do not depend on each other and can proceed side by side once US1's sheet exists.

## Parallel Opportunities

- Phase 1: T002 and T003 alongside T001.
- Phase 2: T005, T006 and T007 together.
- US1: T008 and T009 together. T016 alongside the daemon work (T010–T012).
- US2 and US3: T020 and T027 together. The daemon side of US2 (T021–T023) alongside the phone side of US3 (T028–T030).
- Phase 6: T031 and T032 together.

## Implementation Strategy

**MVP is US1 alone** (T001–T019). It gives a phone that starts an agent with the usual choices, once and never twice, without losing what was typed, and it stops leaking a runtime process on the Mac. Stop at the T019 checkpoint and show it before going further: the layout is settled by running it, and the sheet's shape is what US2 and US3 hang controls on.

Then US2, whose daemon half can land without the sheet. Then US3. Then the gate, which is Alex's.

## Notes

- Nothing in the notification extension or the bridge changes.
- `defaultsKey(runtimeID:)` stays in `ModeMemory`: the Mac reads it once per connection to import.
- Record the scratch-root results of T019 and T026, and the walk in T034, here.
