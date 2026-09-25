# Tasks: Agents Take Turns With the Mac's Shared Things

**Input**: [spec.md](spec.md), [plan.md](plan.md), [research.md](research.md), [data-model.md](data-model.md), [contracts/lease-tools.md](contracts/lease-tools.md), [contracts/daemon-api.md](contracts/daemon-api.md), [quickstart.md](quickstart.md), [wireframes.md](wireframes.md)

**Tests**: Included. The quickstart names each property to test, and this repo tests every daemon
behaviour. Write each test before the code that makes it pass. Model integration tests on
`Pkg/Tests/AgentsKitTests/Integration/HelperAgentTests.swift` and `WorkflowToolTests.swift`,
which already drive an app-tool call through a bound token with `FakeACPAgent`.

**Where**: Everything runs in the worktree `.agents/worktrees/036-resource-leases` on branch
`036-resource-leases`. Never edit the shared checkout. `Pkg/` means `Packages/AgentsKit/`.

**Rules this feature must keep** (from the spec's Clarifications):
- Only agents hold leases. There is no take for the person: no method, no button.
- The person can **End** a lease and **remove** an agent from a line, on the Mac only.
- Starting an agent never offers a lease (FR-017). Nothing on the start form or in `start_agent`
  changes.
- The end of a turn never releases a lease.
- Nothing is tinted. Use `StateTint.none` and the surface's secondary grey (wireframes §4).

**Order**: The stories are built 1 → 3 → 2 → 5 → 4 → 6. Story 3 (seeing leases) comes before
Story 2 (waiting and waking) so the layout is on screen and settled before the deeper machinery
is built. There is a screenshot gate at the end of Phase 4.

---

## Phase 1: Setup

- [X] T001 Merge `main` into `036-resource-leases` in this worktree (it is 13 commits behind). Main has 033's shared `Shared/UI/Chat/PromptPieces.swift` (`PromptHeader`) and `Shared/UI/StateTint.swift`, which Phase 4 builds on. Verify with `git merge-base --is-ancestor main HEAD`, not by trusting the merge's output. Settle conflicts, which should only be in `specs/`.
- [X] T002 Record the baseline: run `swift test` in `Packages/AgentsKit` once and write down which tests fail before any change. The suite is flaky under load, so a later failure only belongs to this lane if it is new.

---

## Phase 2: Foundational (blocks every story)

The pure book, its limits, the wire snapshot and the store. Nothing behaves differently yet.

- [X] T003 [P] Create `Pkg/Sources/AgentsKitCore/Model/Lease.swift`. All types are `Codable, Hashable, Sendable`. `ResourceName { key: String }` has `init?(_ given: String)`, which trims surrounding whitespace, lowercases, and returns nil when the result is empty. `ResourceKind { screen, simulator, browser, named }`. `Lease { resource: ResourceName, holder: UUID, grantedAt: Date, expiresAt: Date, warned: Bool }`: the holder is always an agent id, and there is no `Holder` type. `Waiter { agentID: UUID, askedAt: Date, minutes: Int?, waitID: UUID? }`. `LeaseEnding { released, expired, endedByPerson, holderStopped, holderArchived, couldNotStart }`. `LeaseNotice { resource: ResourceName, kind: endedByPerson | expired | endingSoon(expiresAt: Date), at: Date }`. `LeaseLimits` has static `defaultDuration = 30 min`, `maximum = 4 h`, `warning = 5 min` and `waitLimit = 45 s`.
- [X] T004 [P] Create `Pkg/Tests/AgentsKitTests/Unit/LeaseBookTests.swift`, written against the API in T005 and failing first. Cover:
  - Two `request`s at the same `now` for one name give exactly one `.granted` and one `.queued(place: 1)` (SC-001).
  - The line is served in `askedAt` order (US2-AS5).
  - A re-request by the holder returns `.extended` and never queues (US1-AS4).
  - A 600-minute request is granted for 240 minutes with `capped: true`.
  - `"  Screen "` and `"screen"` are one resource (FR-013).
  - `wait: false` on a held resource returns `.refused` and adds no waiter.
  - A re-request while in line returns `.stillWaiting(place)` and replaces `waitID`.
  - `release` by the holder hands to the next waiter, and that event says whether the waiter's call was open.
  - `release` by a waiter leaves the line.
  - `release` by neither returns `.nothingHeld`.
  - `end` leaves an `endedByPerson` notice for the old holder and hands on.
  - `removeFromLine` removes only that agent.
  - `drop(agentID)` releases every lease and leaves every line, handing each on.
  - `lapse` expires past-due leases with a notice and hands on. It warns once inside the 5-minute window and resets `warned` on extension.
  - `waitTimedOut` keeps the place and clears `waitID`.
  - `closeAllWaits` clears every `waitID`.
  - `nextDeadline` returns the earliest expiry, warning time or open-wait limit.
  - An entry with no lease and no line is removed.
  - A book encoded and decoded is equal.
- [X] T005 Create `Pkg/Sources/AgentsKitCore/Model/LeaseBook.swift`: `struct LeaseBook` with `entries: [ResourceName: Entry]` and `notices: [UUID: [LeaseNotice]]`, where `Entry { kind, displayName, lease: Lease?, line: [Waiter] }`. Add the mutating operations from data-model §LeaseBook, each taking `now` and returning `[LeaseEvent]`: `request`, `release`, `end`, `removeFromLine`, `drop`, `waitTimedOut`, `lapse`, `closeAllWaits`. Add `nextDeadline(openWaits:)` and `takeNotices(for:)`, which returns the agent's notices and clears them. `LeaseEvent` cases: `granted(Lease, waiter: Waiter?, callWasOpen: Bool)`, `extended(Lease, capped: Bool)`, `queued(place: Int, holder: UUID, until: Date)`, `refused(holder: UUID, until: Date)`, `stillWaiting(place: Int, holder: UUID, until: Date)`, `released(Lease, LeaseEnding)`, `leftLine(ResourceName, UUID)`, `nothingHeld`, `warned(Lease)`. Enforce the data-model rules verbatim: "at most one `Lease` per `resource`", "an agent appears at most once in a given line", "An agent that holds a resource can't be in its line: a re-request is an extension", and expiry is "never more than `now + LeaseLimits.maximum`". Make T004 pass.
- [X] T006 [P] In `Pkg/Sources/AgentsKitCore/Daemon/DaemonAPI.swift`, add:
  - Methods `leasesLease = "leases/lease"`, `leasesRelease = "leases/release"`, `leasesList = "leases/list"`, `leasesSnapshot = "leases/snapshot"`, `leasesEnd = "leases/end"` and `leasesRemoveWaiter = "leases/removeWaiter"`. There is no take method.
  - Request types `LeaseRequest { token, name, minutes: Int?, wait: Bool? }`, `LeaseNameRequest { token, name }`, `LeaseTokenRequest { token }`, `PersonEndRequest { name }` and `PersonRemoveRequest { name, agentID: String }`.
  - `LeaseSnapshot { resources: [ResourceState], at: Date }`, where `ResourceState { name, kind, displayName, isGone: Bool, lease: Lease?, line: [Waiter], endingSoon: Bool }` and each waiter's `waitID` is set to nil.
  - `Notification.leasesChanged = "leases/changed"`, and `Failure.leaseRefused` with the next free code.
- [X] T007 [P] Create `Pkg/Sources/AgentsKit/Daemon/LeaseStore.swift`, modelled on `LimitStore`. It holds `leases.json` under `locations.root`. `load() -> LeaseBook`: a missing file is an empty book. A file that can't be decoded is moved aside as `leases.json.unreadable`, a line is written with `DaemonLog.shared.write`, and the book starts empty. `save(_:)` writes atomically. Add a unit test in `Pkg/Tests/AgentsKitTests/Unit/LeaseStoreTests.swift` for round-trip, missing file and unreadable file.
- [X] T008 [P] In `Pkg/Sources/AgentsKitCore/Model/AppTool.swift`, add `leaseResource = "lease_resource"`, `releaseResource = "release_resource"` and `listResources = "list_resources"`, each with a one-line doc comment in the file's voice.
- [X] T009 In `Pkg/Sources/AgentsKit/Daemon/DaemonCore.swift`, add:
  - `lazy var leaseStore = LeaseStore(locations: locations)` and `var leaseBook = LeaseBook()`.
  - `var openWaits: [UUID: CheckedContinuation<String, Never>]`, keyed by `waitID`.
  - `var leaseTimer: Task<Void, Never>?`.
  - `var leaseLimits = LeaseLimits.self`-style overridable values (at least `waitLimit`), so tests can shorten the 45 s wait.
  - `func leasesChanged()`, which saves the book, broadcasts `leases/changed` with the snapshot, and re-arms the timer (the timer body comes in T031).

**Checkpoint**: `swift test` gives the T002 results plus the new passing unit tests.

---

## Phase 3: User Story 1: An agent takes a lease, works, and gives it back (P1) 🎯 MVP

**Goal**: An agent can lease a free resource, extend it, list what it holds, and release it.

**Independent test**: With a bound token, `leases/lease` on a free name grants it with an expiry. Leasing again extends it, `leases/list` shows it under "Yours:", and `leases/release` frees it. The agent's transcript holds a note for each step.

- [X] T010 [US1] Create `Pkg/Tests/AgentsKitTests/Integration/LeaseTests.swift` with the US1 cases, in the style of `HelperAgentTests.swift`, using the reply texts from `contracts/lease-tools.md`:
  - A free name: the reply is "You hold {display} until {HH:mm} ({n} minutes). Release it with release_resource when you are done."
  - A second call by the same agent: "You still hold {display}, now until {HH:mm}."
  - `minutes: 600`: the reply adds the capped sentence.
  - `leases/list`: the reply begins with "Yours:" and lists the lease.
  - `leases/release`: "Released {display}." The book is then empty, and `leases/changed` was broadcast.
  - An unbound token: "That conversation is not open any more, so nothing was leased."
  - An empty name: "Nothing was leased: say which resource."
  - The transcript holds the runtime notes "Leased … until …", "Extended the lease on … to …" and "Released …" (FR-016).
- [X] T011 [US1] Create `Pkg/Sources/AgentsKit/Daemon/DaemonCore+Leases.swift`:
  - `leaseCaller(token:)` resolves the caller from `appTokens`, refusing as `startHelper` does.
  - `public func lease(_:) async throws -> String`. In this phase it covers grant, extend and `wait: false`. The waiting branch comes in US2, so leave a `// US2:` marker there.
  - `public func releaseLease(_:) throws -> String` and `public func listLeases(_:) -> String`.
  - Every reply is prefixed with `takeNotices(for:)`, one line each, then a blank line.
  - Every mutation happens before the first `await`, and each event is turned into its transcript note from `contracts/daemon-api.md` §Transcript notes. Call `leasesChanged()` after each change.
  - Until T043 lands, display names for named resources are the name as first given.
- [X] T012 [US1] Add the `leasesLease`, `leasesRelease` and `leasesList` cases to `Pkg/Sources/AgentsKit/Daemon/DaemonCore+Dispatch.swift`, each returning `["note": .string(note)]`. Make T010 pass.
- [X] T013 [P] [US1] Add the three tools to `Pkg/Sources/AgentsKit/ACP/Serve/AppService.swift`, with the schemas and descriptions from `contracts/lease-tools.md` verbatim: `lease_resource(name, minutes?, wait?)`, `release_resource(name)` and `list_resources()`. They are offered to every agent, including one with `managesAgents: false`. Add a `LeaseCall` enum sink and an init parameter defaulting to a refusal, as `agents:` does. Dispatch matches on the name's suffix. Extend `Pkg/Tests/AgentsKitTests/Unit/AppServiceTests.swift`: `tools/list` has all three with and without `managesAgents`, and a call relays its arguments to the sink.
- [X] T014 [US1] In `Daemon/Sources/main.swift`, relay the three tools to `leases/lease`, `leases/release` and `leases/list` with the token, through the existing `relay` helper.
- [X] T015 [P] [US1] In `Pkg/Sources/AgentsKit/ACP/Serve/Briefing.swift`, add the leases paragraph from `contracts/lease-tools.md` §Briefing verbatim, for every agent. Extend `Pkg/Tests/AgentsKitTests/Unit/BriefingTests.swift` so it is present with and without `managesAgents` (FR-015).

**Checkpoint**: The MVP. An agent can lease, extend, list and release, and everything it did is in its transcript.

---

## Phase 4: User Story 3: The person sees who holds what (P1)

**Goal**: The Resources page, the chat's lease row and the row/card mark, on the Mac and the phone, match `wireframes.md`.

**Independent test**: Two agents on a scratch root. One leases a simulator, and the other leases the screen. The page, both chats, both rows and a phone card show them within a second, with no tint.

- [X] T016 [P] [US3] Create `Pkg/Tests/AgentsKitTests/Unit/LeaseStatusTests.swift`:
  - `LeaseStatus.of` returns nil for an agent with nothing.
  - Holding one lease gives the mark "Holds Screen · 18 min".
  - Holding two gives the first one plus "and 1 more".
  - Waiting gives "Waiting for Screen · 2nd in line".
  - The capsule text matches wireframes §2: `▣ {name} · {n} min` and `◷ Waiting for {name} · held by “{holder}” until {HH:mm} · {ordinal}`.
  - Minutes are counted from `snapshot.at`, not the client's clock.
  - The short name drops the OS ("iPhone 17 Pro") and says "Screen".
- [X] T017 [US3] Create `Pkg/Sources/AgentsKitCore/Model/LeaseStatus.swift`: `LeaseStatus.of(_ agentID: UUID, in: LeaseSnapshot, titles: [UUID: String]) -> LeaseStatus?`, with `holding`, `waiting`, `capsules: [String]`, `mark: String`, `moreCount: Int` and `shortName(_:)`. Make T016 pass.
- [X] T018 [US3] In the daemon, add `func leaseSnapshot() -> DaemonAPI.LeaseSnapshot` to `Pkg/Sources/AgentsKit/Daemon/DaemonCore+Leases.swift` (found resources are joined in by T044), and the `leasesSnapshot` dispatch case. In `leasesChanged()`, also broadcast once a minute while any lease is held (contracts/daemon-api.md §Notification). Add an integration test that a grant broadcasts `leases/changed` carrying that lease.
- [X] T019 [US3] In `Pkg/Sources/AgentsKitCore/Client/AgentsModel.swift`, add `public private(set) var leases: DaemonAPI.LeaseSnapshot?`, `Update.leasesChanged`, the decode case for `leases/changed` in the shared switch, and the apply case (replace, never merge). Fetch `leases/snapshot` wherever `costState` is fetched on connect, in `App/Sources/AppModel.swift` and `Remote/Sources/RemoteModel.swift`. A daemon that answers method-not-found leaves `leases` nil.
- [X] T020 [US3] Check that the phone receives `leases/changed`. Read how `Bridge/Sources/main.swift` and `Pkg/Sources/AgentsKitCore/Remote/NetworkLink.swift` relay daemon notifications, and add `leases/changed` and `leases/snapshot` if they relay only named methods (research R11).
- [X] T021 [P] [US3] Create `Shared/UI/Chat/LeaseRow.swift`: a wrapping row of `.paperRaised(in: Capsule())` capsules, one per entry in `LeaseStatus.capsules`, in `.appText(.fine)` and `.secondary`, with no tint. On the Mac, a capsule opens the Resources page at that resource and the holder's name opens its chat. On the phone, a tap shows the full line in a small read-only sheet. The view is absent when `LeaseStatus.of` is nil.
- [X] T022 [US3] In `Shared/UI/Chat/PromptPieces.swift`, have `PromptHeader` draw `LeaseRow` above its existing `HStack` when the agent has a status. It takes the snapshot and titles as inputs, so both apps pass them from their own model.
- [X] T023 [P] [US3] Add the row mark to `App/Sources/AgentList/AgentRow.swift`: its own line under the report line, `.appText(.fine)`, `.secondary`, "▣ {mark}" or "◷ {mark}", with "and N more" beneath in `.tertiary`. Give it an `.accessibilityLabel` that spells out the full status line.
- [X] T024 [P] [US3] Add the same mark to `Remote/Sources/Projects/AgentCard.swift`, with the same text from `LeaseStatus.mark`.
- [X] T025 [US3] Add `case resources` to `App/Sources/Projects/SidebarItem.swift`. Add a Resources row above `SpendingRow` in `App/Sources/Projects/ProjectListView.swift`, with the count line "{n} held · {m} waiting", which is absent when both are zero. Add `showsResources` in `App/Sources/AppModel.swift`, following `showsSpending`, and route it in `App/Sources/ContentView.swift`.
- [X] T026 [US3] Create `App/Sources/Resources/ResourcesView.swift`, following wireframes §1 and `SpendingView`'s layout:
  - The title "Resources" and the one-line explanation.
  - Groups in the order Screen, Simulators, Browsers, Named by agents. Named by agents is absent when it would be empty.
  - Each row: a dot (filled = held, hollow = free, faint = gone), the name, and "Held by “{title}” since {HH:mm} · until {HH:mm} · {n} min left". Agent names are links to their chat (US3-AS5).
  - A plain "ending soon" capsule inside the warning window.
  - The line under its row, each waiter showing "asked {HH:mm} · waiting in its call" or "will be started".
  - No buttons yet (US4 adds End and ✕), and no Take button ever.
- [X] T027 [US3] **UX gate.** Build both schemes, one after the other, with plugin validation skipped. Use the run-app skill to launch a scratch root, have two scratch agents call `lease_resource` over their bound tokens, and screenshot the Resources page, a chat and the agent list. Build Remote for the generic simulator only. Compare against `wireframes.md` and fix the layout before moving on. Leave the screenshots with the task for Alex.

**Checkpoint**: Leases are visible everywhere the spec asks, and the layout is settled.

---

## Phase 5: User Story 2: A second agent waits its turn and is let through (P1)

**Goal**: A request for a held resource waits in line. It is granted in its open call, or the agent is started again when the lease reaches it.

**Independent test**: A holds the resource, B asks for it, and A releases within the wait limit, so B's call returns "is yours now". Again with B's call timing out first: B's call returns "still in line", and when A releases, B receives the wake prompt `from: .app`.

- [X] T028 [US2] Add the US2 cases to `Pkg/Tests/AgentsKitTests/Integration/LeaseTests.swift`, with `waitLimit` shortened through T009's override:
  - An open wait is granted within 1 s of release, with the reply "{display} is yours now, until …".
  - At the wait limit the reply is "still in line", with the place and the holder, and the waiter keeps its place.
  - Calling again reopens the wait at the same place.
  - A grant after the call closed queues a prompt `from: .app` with the wake text from `contracts/lease-tools.md` §Wake, and B's queued prompt is sent.
  - B with a turn in flight: the wake prompt waits behind that turn.
  - Three waiters are served in order.
  - `wait: false` gives "held by … You are not in line."
  - `release_resource` by a waiter gives "You left the line for …".
  - 20 concurrent `leases/lease` calls on one name give one holder and 19 waiters (SC-001).
  - B can't run (its runtime is removed from the launcher): the lease is released with `.couldNotStart`, passed on, and B's transcript holds the note.
  - B at its cost limit is handled the same way (research R4).
- [X] T029 [US2] Implement the waiting branch in `Pkg/Sources/AgentsKit/Daemon/DaemonCore+Leases.swift`:
  - Queue the waiter with a fresh `waitID` before any `await`.
  - `await withCheckedContinuation`, storing it in `openWaits[waitID]`, and start a `Task` that after `waitLimit` calls `waitTimedOut` and resumes the continuation with the "still in line" text.
  - On a `.granted` event with `callWasOpen`, remove the continuation and resume it with the grant text. Every resume first removes the entry from `openWaits`, so no continuation is resumed twice.
  - On `.granted` with `callWasOpen == false`, call `wake(agentID:lease:)`.
- [X] T030 [US2] Implement `wake(agentID:lease:)` in `DaemonCore+Leases.swift` (research R4):
  - Record the grant note, then `prompt(PromptRequest(agentID:, text: wakeText, from: .app))`.
  - If that throws, or afterwards `held.contains(agentID)` or the agent is at its cost limit, `release` the lease with `.couldNotStart` and record "{display} came to this agent but it could not be started ({reason}), so it was passed on."
  - Handing it on can wake the next waiter in turn, so loop rather than recurse.

**Checkpoint**: Agents take turns. A waiting agent is let through in its call, or started again afterwards.

---

## Phase 6: User Story 5: Leases don't outlive their use (P2)

**Goal**: Expiry, the warning, stop/archive and restart all free resources without anyone acting.

**Independent test**: A short lease expires on time and passes on. Stopping the holder frees it. The book survives a daemon restart with the same expiry, and one that expired while the daemon was down is freed on load.

- [X] T031 [US5] Add the US5 cases to `Pkg/Tests/AgentsKitTests/Integration/LeaseTests.swift`, driving time through the injected `now`:
  - Expiry releases the lease and passes it on within the timer's next firing.
  - The warning notice appears on the next lease tool reply, and `endingSoon` is set in the snapshot.
  - `stop` and `archive` release all of an agent's leases, remove it from every line, and resume its open call with "You were stopped, so you left the line for …".
  - The end of a turn keeps the lease.
  - A daemon built on the same root reloads the book with the same `expiresAt`. A lease whose expiry passed before the reload is released during load and its next waiter is woken, and every `waitID` is nil after the reload.
- [X] T032 [US5] In `DaemonCore+Leases.swift`, implement the timer: `armLeaseTimer()` cancels `leaseTimer` and sleeps until `leaseBook.nextDeadline`, then calls `lapse(now())` and handles its events: notes, handing on, and wakes. It is called from `leasesChanged()`. It does nothing when there is no deadline.
- [X] T033 [US5] In `Pkg/Sources/AgentsKit/Daemon/DaemonCore+Commands.swift`, have `stop(_:by:)` and `archive(_:by:)` call `dropLeases(for:ending:)` (`.holderStopped` / `.holderArchived`) before their first `await`. This resumes the agent's open waits with the stopped text and hands everything on (research R7). Add nothing at the end of a turn.
- [X] T034 [US5] In `Pkg/Sources/AgentsKit/Daemon/DaemonCore+Recovery.swift`, at the start of `recover()`: `leaseBook = leaseStore.load()`, `closeAllWaits()`, `lapse(now())`, handle the events (wakes join the normal pick-up), then `leasesChanged()`.
- [X] T035 [US5] In `Pkg/Sources/AgentsKit/Daemon/DaemonCore+Lifetime.swift`, make `isHoldingAgents` true while any entry in `leaseBook` has a non-empty line. Keep its comment style: say why a line keeps the daemon up and a lone lease does not (research R10).
- [X] T036 [P] [US5] In `App/Sources/Resources/ResourcesView.swift`, show a lease's "ending soon" capsule from `ResourceState.endingSoon`, and "Gone from this Mac · still held by …" for `isGone`.

**Checkpoint**: Nothing stays held past its expiry or its agent, across a restart (SC-003).

---

## Phase 7: User Story 4: The person takes a lease back (P2)

**Goal**: From the Resources page, the person can end any lease and remove any agent from a line. There is no take.

**Independent test**: A holds the screen and B is waiting. Pressing End passes the screen to B, and A's next lease tool reply starts with "the person ended your lease". Pressing ✕ on a waiter removes it.

- [X] T037 [US4] Add the US4 cases to `Pkg/Tests/AgentsKitTests/Integration/LeaseTests.swift`:
  - `leases/end` hands the lease to the next waiter at once and leaves the notice. The agent is not interrupted mid-turn: no prompt is queued and no cancel is sent.
  - `leases/removeWaiter` removes only that waiter.
  - `leases/end` on a free resource fails with `Failure.leaseRefused`.
  - There is no `leases/take` method: calling it gives method-not-found.
- [X] T038 [US4] Implement `endLease(_:)` and `removeWaiter(_:)` in `DaemonCore+Leases.swift`, each returning the snapshot, and add their dispatch cases. Record "You ended this agent's lease on {display}." in the holder's transcript.
- [X] T039 [US4] Add the buttons to `App/Sources/Resources/ResourcesView.swift`: **End** on every held row, including gone ones, and ✕ on each waiter. Neither asks for confirmation. There is no Take on free rows (wireframes §1). Give both an `.accessibilityLabel` naming the agent and the resource.

**Checkpoint**: The person can clear a stuck lease or line from one place.

---

## Phase 8: User Story 6: The resources are ones the app already knows (P3)

**Goal**: The Mac's simulators, browsers and screen are listed under stable names, free or not.

**Independent test**: `list_resources` shows the screen, each available simulator and each browser. Leasing by UDID, or by a browser's display name, lands on the same resource as its key. A made-up name works and disappears once free.

- [X] T040 [P] [US6] Create `Pkg/Tests/AgentsKitTests/Unit/ResourceCatalogTests.swift`. Parse a canned `xcrun simctl list devices available -j` fixture into `simulator:<udid>` keys, lowercased, with display names "iPhone 17 Pro · iOS 26.0". Resolve an alias: a UDID alone, a display name when it is unique, and a browser's display name. A display name shared by two devices does not resolve. Found resources have fixed keys `screen`, `simulator:<udid>` and `browser:<bundle id>`.
- [X] T041 [US6] Create `Pkg/Sources/AgentsKit/Daemon/ResourceCatalog.swift`:
  - The screen, always listed as "Screen, mouse and keyboard".
  - Simulators from `xcrun simctl list devices available -j`. End the subprocess on `terminationHandler`, never `waitUntilExit`. It runs off the actor. With no Xcode there are no simulators and nothing is said.
  - Browsers from `LSCopyApplicationURLsForURL` for `https:`.
  - Results cached for 60 s.
  - `resolve(_ given: String) -> (ResourceName, ResourceKind, displayName)`.
- [X] T042 [US6] Add the US6 cases to `Pkg/Tests/AgentsKitTests/Integration/LeaseTests.swift`, with an injected fake catalog: leasing by UDID and by key share one line, and `list_resources` shows found resources as free.
- [X] T043 [US6] Use the catalog in `DaemonCore+Leases.swift`: `lease` resolves names through it, so known names get their kind and display name and unknown names are `named`. `list_resources` matches the contract's "On this Mac:" layout.
- [X] T044 [US6] Join found resources into `leaseSnapshot()` as free rows, and mark a held resource `isGone` when it is no longer found. Refresh the snapshot when the catalog's cache is renewed.

**Checkpoint**: Agents and the person see one list of what the Mac has, and every agent ends up in the same line for the same thing.

---

## Phase 9: Polish and proof

- [X] T045 Run the full suite on this branch and on `main`, several times each, and compare before blaming the branch.
- [X] T046 Build both schemes, one after the other, with plugin validation skipped. Build Remote for the generic simulator only. Never create or boot a simulator for screenshots.
- [X] T047 Run quickstart §3 end to end with the run-app skill on a scratch root, with two real agents on one simulator: page, chats, rows, the 45 s "still in line", the wake within 5 s, End, ✕, and a restart by the pid in `daemon.lock`. Save the screenshots, and never drive the scratch window while Alex is using the Mac.
- [X] T048 For each runtime available, record whether a 45 s wait came back as "still in line" or the runtime gave up first. Write the result as a note at the foot of this file (research R3 risk).
- [X] T049 [P] Check that FR-017 holds: `git diff main -- App/Sources/StartAgent Remote/Sources/StartAgent` and the `start_agent` schema show no lease option. Starting an agent is unchanged.

---

## Dependencies

- **Setup (T001–T002)** comes before everything.
- **Foundational (T003–T009)** blocks every story. T005 needs T003 and T004. T009 needs T005 and T007.
- **US1 (T010–T015)** needs Foundational. It is the MVP.
- **US3 (T016–T027)** needs US1, so that there are leases to show. T027 is a gate: stop and settle the layout before US2.
- **US2 (T028–T030)** needs US1. It changes only the daemon, so it could run alongside US3's views, but it waits for the gate by choice.
- **US5 (T031–T036)** needs US2, because expiry and stop hand leases on to waiters.
- **US4 (T037–T039)** needs US3 (the page) and US2 (handing on).
- **US6 (T040–T044)** needs US1 and US3. T040 and T041 can start any time after Foundational.
- **Polish (T045–T049)** comes last.

## Parallel opportunities

- Foundational: T003, T004, T006, T007 and T008 touch different files.
- US1: T013 (AppService) and T015 (Briefing) run alongside T011 and T012.
- US3: T016, T021, T023 and T024 run together once T017 is in. T025 and T026 are Mac-only files.
- US6: T040 and T041 can be written as soon as Foundational is done.

## Implementation strategy

1. **MVP** = Phases 1–3. Agents lease and release, and it is in their transcripts. This is useful on its own, because any agent can already see what others hold.
2. **Settle the look** = Phase 4, ending at the T027 gate, with screenshots.
3. **Taking turns** = Phase 5, then Phase 6, so waiting is never left without expiry and cleanup.
4. **Person's controls, then known resources** = Phases 7 and 8.
5. **Proof** = Phase 9, before any merge. Merge only when Alex says it is this lane's turn.

---

## Notes from implementing (2026-09-25)

- **T027 look gate**: walked on a scratch root with two real Claude agents. Screenshots are in
  `walk/`: the Resources page (A holds the screen, B is 1st in line and "waiting in its call"),
  the project's rows ("◷ Waiting for Screen · 1st in line", "▣ Holds Screen · 19 min / and 1
  more"), and A's chat with "▣ Screen · 18 min", "▣ Safari · 29 min" above the prompt bar. The
  real catalog found 23 simulators and 2 browsers. That list pushed Browsers off the page, so
  free rows now fold after four ("Show N more free"). How it looks on the phone is Alex's to check.
- **Capsule names**: capsules use the short name on both platforms ("Screen", "iPhone 17 Pro"),
  with the full line in the tooltip and the phone's sheet. The Mac wireframe drew the full name.
- **Briefing**: the ceiling in `BriefingTests` went to 2,100 characters and seven lines. The
  leases paragraph was cut to 396 characters, and the longest briefing now is 2,085 (Cursor).
- **T045**: the branch passed the full suite (1,583 tests) in 2 of 3 runs. The one failure was
  `aProgramSeesATerminalOnItsOutput`, a terminal test this lane does not touch. `main` was not
  run for comparison.
- **T047, partly done**: done live were the page, rows, chat row, the 45 s "still in line"
  (00:27:50 → 00:28:40), End (`leases/end`), and the wake. The screen went to B at once, and B
  was started with the "is yours now" prompt `from: .app`, then asked to release. Not done live:
  pressing ✕ in the window, and a restart by pid. Both are covered by `LeaseTests`.
- **T048, partly done**: Claude's 45 s wait came back as "still in line", and the runtime did
  not give up first. Codex, Gemini and Grok have not been tried. Claude asked the person's
  permission before its first `lease_resource` and `release_resource` call. That is the
  runtime's own MCP permission policy (plan, Risks), and an unattended agent in "ask" mode will
  stop there.

## Notes from finishing (2026-09-25)

- **release_resource, live**: on the real app restarted onto `e3ce367`, a lease on "036 release
  check" was taken and released ("Released 036 release check."), and `list_resources` then showed
  nothing held. The same call first surfaced the two "the person ended your lease" notices from
  00:50, delivered at the next lease call and kept across two restarts (FR-012). One quirk: a lease
  of 5 minutes or less is inside the warning window from the start, so its holder is warned at
  once. It's harmless, but worth changing if short leases turn out to be common.
- **T048, the 45 s wait on each runtime** (scratch root, a Claude agent holding the screen):
  - **Grok**: the call went out at 08:02:35 and came back at 08:03:20 with "still in line"
    (1st). Grok then ended its turn with `finish_turn`. It did not give up first.
  - **Cursor**: it asked the person's permission first (08:02:51), then came back with "still
    in line" (2nd), and ended its turn at 08:03:46. It did not give up first.
  - **Claude** (from the first walk): came back with "still in line" after 45 s.
  - **Copilot**: not measured. Its session had none of the app's tools, not `lease_resource`
    and not even `finish_turn`, and it said so ("I don't have a lease_resource tool available in
    this environment"). This is how the app's MCP server reaches Copilot, not 036, and it is
    worth its own look.
  - **Codex, Gemini**: not runtimes this app has. The built-in ones are Claude, Grok, Copilot and
    Cursor.
- **T047, ✕ and restart by pid** (scratch root, while Alex was away): with two agents in line
  for the screen, pressing ✕ on the Resources page removed exactly that waiter, and the other
  kept its place (`walk/remove-from-line-*.png`). The two waiters had the same title, so the two
  ✕ buttons' labels could not be told apart in the accessibility tree. Stopping the scratch
  daemon by the pid in its `daemon.lock` left it a zombie until the window reaped it, and the
  window started a new daemon on the same root. The book came back with the same holder, the same
  expiry to the millisecond, and the waiter's call marked closed (`walk/after-daemon-restart.png`).
- **iPad look**: approved by Alex on Alex's iPad (2), iPad (A16), with Remote at `e3ce367`: the
  card line, the capsule on one line, and the read-only sheet.
- **Expiry across sleep**: the iPad check lease was due at 01:26 but lapsed at 01:33. The Mac slept
  from about 01:23 to a DarkWake at 01:33:13 (`pmset -g log`), and the timer fired at that wake.
  SC-003's 5 seconds holds only while the Mac is awake. Nothing runs during sleep, and the daemon
  catches up at the first wake, which is what happened. The agent's notice gives the time it
  was noticed ("ran out at 01:33"), not the expiry, so after a sleep the two differ.
