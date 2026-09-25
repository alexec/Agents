# Tasks: Events and Waiting

**Input**: [spec.md](spec.md), [plan.md](plan.md), [research.md](research.md),
[data-model.md](data-model.md), [contracts/event-tools.md](contracts/event-tools.md),
[contracts/daemon-api.md](contracts/daemon-api.md),
[contracts/catalogue.md](contracts/catalogue.md), [quickstart.md](quickstart.md),
[wireframes.md](wireframes.md)

**Tests**: Included. The quickstart names each property to test, and this repo tests every
daemon behaviour. Write each test before the code that makes it pass. Model the integration tests
on `Pkg/Tests/AgentsKitTests/Integration/LeaseTests.swift` and `BlockedTests.swift`, which
already drive app-tool calls through a bound token with `FakeACPAgent`, shorten the hold limit,
and restart a daemon on the same root.

**Where**: Everything runs in the worktree `.agents/worktrees/042-events-and-waiting` on branch
`042-events-and-waiting`. Never edit the shared checkout. `Pkg/` means `Packages/AgentsKit/`.

**Rules this feature must keep** (from the spec and its clarifications):
- An event is a fact with a name, a time, a scope, a sentence and details. It never carries
  transcript text, file contents or credentials (FR-004).
- Waits are one-shot. An agent has at most one wait, and a new one replaces the old one. The
  call is held for 45 s, then the agent is resumed like a lease (FR-007, FR-008).
- Agents may publish only `custom.*` events (FR-018).
- Today's nine trigger names keep working, and no workflow file is ever rewritten (FR-022,
  SC-006).
- The phone and iPad only read. No ✕, no publish, no subject filters (spec, Assumptions;
  wireframes §4).
- Nothing is tinted. Use the surface's greys, and let a waiting chat take 039's Blocked look
  (wireframes §5).
- Every event goes through `DaemonCore.raise`. No source matches waits or workflows itself
  (research R1).

**Order**: The stories are built 2 → 1 → 3 → 4 → 5. Story 2 (seeing events) comes first, fed by
a debug-only `events/raise`, so the page, capsule and phone list are on screen and settled before
waiting is built (the rule: settle the UX before building depth). There is a screenshot gate at
the end of Phase 3. Story 1 is still the MVP: it is the first story that is useful on its own.

---

## Phase 1: Setup

- [X] T001 Merge `main` into `042-events-and-waiting` in this worktree, so the branch sits on today's `main` (041, 038, 039 and 040 are all merged there). Verify with `git merge-base --is-ancestor main HEAD`, not by trusting the merge's output. Conflicts should only be in `specs/`.
- [X] T002 Record the baseline: run `swift test` in `Pkg/` once, and write down in `specs/042-events-and-waiting/walk/README.md` which tests fail before any change. The suite is flaky under load, so a later failure belongs to this lane only if it is new, and only after six runs on both commits.

---

## Phase 2: Foundational (blocks every story)

This phase adds the pure core, the catalogue, the store and the wire shapes. Nothing behaves
differently yet.

- [X] T003 [P] Create `Pkg/Sources/AgentsKitCore/Model/Event.swift`. All types are `Codable, Hashable, Sendable`.
  - `typealias EventPosition = Int64`.
  - `enum EventScope { case mac; case project(URL) }`. `project` stores `Project.standardize(folder)`.
  - `struct EventPublisher { agentID: UUID, title: String }`.
  - `enum Consequence { woke(agentID: UUID, title: String); fired(workflowID: String, folder: URL, agentID: UUID?); refused(workflowID: String, folder: URL, reason: WorkflowRefusal); couldNotWake(agentID: UUID, title: String, reason: String) }`.
  - `struct Event { position, name, at: Date, lastAt: Date?, count: Int, scope, sentence: String, details: [String: String], publisher: EventPublisher?, message: String?, chainDepth: Int, consequences: [Consequence] }`.
  - `struct EventDraft`: the same fields minus `position`, `count`, `lastAt` and `consequences`. It is what sources hand to `raise`.
  - Enforce the data-model validation verbatim: the name matches `^[a-z][a-z_]*\.[a-z][a-z0-9_]*$`; `details` has "at most 10 keys, and each value is at most 200 characters"; `message` is "at most 500 characters".
  - Add `var subject: EventSubject`, read from the name's prefix.
- [X] T004 [P] Create `Pkg/Sources/AgentsKitCore/Model/EventCatalogue.swift`.
  - `enum EventSubject: String, CaseIterable { agent, workflow, pullRequest = "pull_request", branch, lease, mac, person, cost, server, custom }`, each with its glyph (● ⟳ ⑂ ⎇ ⌘ ✦ per wireframes §5) and its filter capsule (Agents, Workflows, Pull requests, Branches, This Mac, Custom), per `contracts/catalogue.md` §Subjects.
  - `enum EventScopeKind { mac, project, either }`.
  - `struct EventKind { name, subject, scope: EventScopeKind, details: [String], meaning: String, aliases: [String] }`.
  - `static let all: [EventKind]` holds exactly the 30 rows of `contracts/catalogue.md`, with their Meaning column verbatim. `agent-stopped` is an alias on both `agent.stopped` and `agent.failed`. `workflow-completed` is the alias on `workflow.completed`.
  - `static func kind(named:) -> EventKind?`.
  - `static func isCustom(_ name: String) -> Bool`, true for `custom.<name>` where `<name>` is "lowercase letters, digits and `_`, up to 40 characters".
  - `static func describe() -> String`: the one text block that `list` and `manage_workflows` both return. It has one line per kind (name, then details, then meaning), then the `custom.<name>` family, then a line saying `subject.*` matches a whole subject.
- [X] T005 [P] Create `Pkg/Sources/AgentsKitCore/Model/EventPattern.swift`: `struct EventPattern: Codable, Hashable, Sendable { name: String, filters: [String: String] }`.
  - `static func parse(_ name: String, filters: [String: String]) -> Result<EventPattern, EventPatternProblem>` accepts a catalogue name, `subject.*` for a subject in `EventSubject`, or `custom.<name>`. `EventPatternProblem.message` is the sentence the agent reads:
    - an unknown name gives "`\"x\" is not an event. Did you mean y? Events you can wait on: …`";
    - an unknown subject in `x.*` is refused the same way;
    - a filter key the kind does not carry gives "`pull_request.merged carries number; \"branch\" is not one of its details.`".
    - For `x.*`, a filter key must be carried by at least one kind in the subject. Filters on `custom.*` are free-form.
  - `func matches(_ event: Event) -> Bool`: the name is equal, or the prefix matches for `subject.*`, and every filter equals `event.details[key]`, compared as strings (a number filter `41` matches `"41"`).
  - `var summary: String`: the kind's meaning narrowed by the filters, e.g. "When pull request #41 is merged".
- [X] T006 [P] Create `Pkg/Tests/AgentsKitTests/Unit/EventCatalogueTests.swift` and `EventPatternTests.swift`, failing first. Cover:
  - the 30 names are unique and all valid;
  - every one of today's nine trigger names except `schedule` is an alias of at least one kind, and `agent-stopped` is an alias of exactly `agent.stopped` and `agent.failed`;
  - `describe()` names every kind;
  - `pull_request.*` matches all ten pull-request kinds and nothing else;
  - `{number: 41}` matches 41 and not 42;
  - `custom.build_green` matches only itself;
  - the refusals list the valid choices (quickstart §1).
- [X] T007 Create `Pkg/Sources/AgentsKitCore/Model/EventLog.swift`: `struct EventLog` with the events in position order, plus `head: EventPosition`.
  - `mutating func append(_ draft: EventDraft, position: EventPosition, now: Date) -> Appended`, where `Appended` is `.new(Event)` or `.repeated(Event)`. It folds the draft into the last event when that event has the same name, the same scope and equal details, and `now - (lastAt ?? at) < 60 s`. Folding sets `count += 1` and `lastAt = now` and keeps the first position (FR-031, R14).
  - `mutating func addConsequence(_:to:)`.
  - `mutating func prune(now:)` keeps events newer than 7 days, then at most 10,000, dropping the oldest first (FR-032).
  - `func query(before: EventPosition?, limit: Int, scopes: Set<EventScope>?, subjects: Set<EventSubject>?) -> (events: [Event], hasMore: Bool)`, newest first, with `limit ≤ 200`.
  - `func matches(after: EventPosition, _ patterns: [EventPattern], scopes: Set<EventScope>) -> [Event]`, oldest first, used for "wait from" (R6).
- [X] T008 [P] Create `Pkg/Tests/AgentsKitTests/Unit/EventLogTests.swift`, failing first. Cover:
  - positions only go up;
  - folding within 60 s gives `count` 2, and 61 s later gives a new row;
  - details that differ do not fold;
  - pruning at 7 days, and at 10,001 events;
  - query paging with `before`;
  - scope and subject filters;
  - `matches(after:)` excludes the event at the `from` position itself;
  - a log encoded and decoded is equal.
  Make it pass with T007.
- [X] T009 [P] Create `Pkg/Sources/AgentsKitCore/Model/EventWait.swift`.
  - `struct EventWait { id: UUID, patterns: [EventPattern], from: EventPosition, deadline: Date?, since: Date, ending: EventWaitEnding?, resumePromptID: UUID? }`.
  - `enum EventWaitEnding { matched(position: EventPosition, extraMatches: Int); timedOut; cancelled(by: Canceller); couldNotWake(reason: String) }`, where `Canceller` is `agent, person, prompt, stopped, archived`.
  - `var isOpen: Bool { ending == nil }`.
  - The deadline range is 1–1440 minutes.
- [X] T010 In `Pkg/Sources/AgentsKitCore/Model/Agent.swift`, add `public var eventWait: EventWait?`. Encode it with `encodeIfPresent`, decode it with `decodeIfPresent`, add it to `CodingKeys`, and add it to the memberwise init with a default of `nil`. An older phone ignores the unknown key. Add a round-trip case to the existing agent coding test (`Pkg/Tests/AgentsKitTests/Unit/AgentCodingTests.swift`, or whichever file tests `Agent` coding today).
- [X] T011 [P] Create `Pkg/Sources/AgentsKitCore/Model/EventWords.swift`, holding every sentence from `contracts/event-tools.md`, so tests can pin them:
  - `matched(event, waited: Int?)`, `stillWaiting(patterns, filters, since, until)`, `replaced(previous)`, `timedOut(patterns, at)`;
  - `wake(event, extraMatches)`, which is the prompt block in the contract;
  - `cancelledByPrompt(patterns)`, the line put before the person's text;
  - `stoppedWaiting(patterns)`, `notWaiting`;
  - `published(event, consequences)`, `publishOutsideCustom(name)`, `publishLimit(until)`, `otherProject`;
  - `hint(patterns)`, which is "Sending will cancel the wait on pull_request.merged.";
  - `recentLine(event)` and `recentFooter(head)`.
  Times are `HH:mm` in the Mac's time zone, as `LeaseWords` formats them.
- [X] T012 [P] In `Pkg/Sources/AgentsKitCore/Daemon/DaemonAPI.swift`, add:
  - Methods `eventsWait = "events/wait"`, `eventsCancel = "events/cancel"`, `eventsPublish = "events/publish"`, `eventsList = "events/list"`, `eventsCancelWait = "events/cancelWait"` and `eventsRaise = "events/raise"`.
  - Requests `EventWaitRequest { token, action: String?, events: [String]?, where: [String: String]?, from: Int64?, untilMinutes: Int?, limit: Int? }`, `EventTokenRequest { token }`, `EventPublishRequest { token, name, message: String?, details: [String: String]? }`, `EventsListRequest { before: Int64?, limit: Int, scope: EventScope?, subjects: [EventSubject]? }` and `CancelWaitRequest { agentID: UUID }`.
  - `EventsPage { events: [Event], waiting: [WaitingAgent], hasMore: Bool }`, `WaitingAgent { agentID, title, folder, status: WaitStatus, cancellable: Bool }` and `EventsChange { event: Event?, waiting: [WaitingAgent] }`.
  - `Notification.eventsChanged = "events/changed"`.
  - `Failure.eventRefused = -32050` and `Failure.noWait = -32051`, each with a doc comment in the file's voice (R16).
- [X] T013 [P] Create `Pkg/Sources/AgentsKit/Store/EventStore.swift`.
  - `events.jsonl` under `locations.root` holds the three line shapes from data-model §Files: `{"event":…}`, `{"consequence":…,"position":N}` and `{"repeat":N,"at":…}`.
  - `load() -> EventLog` folds lines in order and drops a torn last line.
  - `append(_ line:)` writes through a `FileHandle` kept open, one `write` per line.
  - `rewrite(_ log:)` writes to a temporary file and renames it over the old one.
  - Beside it, `events-state.json` (`EventState { nextPosition, branchTips, pullRequestsSeen, publishes, costCrossings }`) is written whole and atomically, like `LeaseStore`.
  - A file that cannot be read is moved aside as `.unreadable`, a line goes to `DaemonLog`, and the log starts empty.
- [X] T014 [P] Create `Pkg/Tests/AgentsKitTests/Unit/EventStoreTests.swift`. Cover:
  - round trip;
  - a torn last line;
  - consequences and repeats folding into their event;
  - a rewrite through rename;
  - an unreadable file moved aside;
  - `nextPosition` surviving a reload.
- [X] T015 In `Pkg/Sources/AgentsKit/Daemon/DaemonCore.swift`, add:
  - `lazy var eventStore`, `var eventLog = EventLog()` and `var eventState = EventState()`;
  - `var openEventWaits: [UUID: CheckedContinuation<Result<String, JSONRPCError>, Never>]`, keyed by agent id;
  - `var eventWaitTimer: Task<Void, Never>?`;
  - `var eventHoldLimit: Duration = .seconds(45)`, the same value as `leaseWaitLimit` (R5);
  - `var machineWatch: (any MachineWatch)?`.
  Load the log and state in `DaemonCore+Recovery.swift` beside the lease book, and prune on load.

**Checkpoint**: `swift test` gives the T002 results plus the new unit tests, all passing.

---

## Phase 3: User Story 2: The person sees what happened and what came of it (P2), built first

**Goal**: The Mac has an Events page, and the phone and iPad have an Events list. Both update
live, show consequences, and are fed at first by `events/raise`.

**Independent Test**: Raise three events over `daemon.sock` with `events/raise` on a scratch
root, one of them carrying a `fired` consequence and one a `woke` consequence. The Mac page and
the phone list both show all three, newest first, with times, sentences, names and scopes. The
consequences link to their agents.

- [X] T016 [US2] Create `Pkg/Sources/AgentsKit/Daemon/DaemonCore+Events.swift` with `@discardableResult func raise(_ draft: EventDraft) -> Event`. It:
  1. takes `eventState.nextPosition`, bumps it and saves the state;
  2. appends the event through `eventLog.append`, then `eventStore.append`;
  3. broadcasts `events/changed`.
  There is no `await` anywhere in `raise` (R1). Leave two marked hooks, `matchWaits(event)` and `fireWorkflows(for: event)`, as empty functions to be filled in Phases 4 and 5. Also add:
  - `func addConsequence(_:to:)`, which appends a consequence line and broadcasts;
  - `func eventsPage(_ request: EventsListRequest) -> EventsPage`;
  - an hourly prune task.
- [X] T017 [US2] In `Pkg/Sources/AgentsKit/Daemon/DaemonCore+Dispatch.swift`, add the `events/list` case, and `events/raise` under `#if DEBUG`. The raise method is refused unless the store root is not the real one (compare with `StoreLocations.default`), and it can attach a consequence given in the request for the look gate. Allow `events/list` over the bridge the way `leases/snapshot` is allowed (find the phone's allowed-method list by grepping for `leasesSnapshot` in `Bridge/` and `Pkg/Sources/AgentsKit/Daemon/DaemonServer.swift`).
- [X] T018 [P] [US2] Create `Pkg/Sources/AgentsKitCore/Model/WaitStatus.swift`: `struct WaitStatus: Codable, Hashable, Sendable { line: String, mark: String, cancellable: Bool }` and `static func status(for agent: Agent, names: (UUID) -> String) -> WaitStatus?`.
  - An open `eventWait` gives `◷ Waiting for {pattern} · #44 · since HH:mm · until HH:mm` and the mark `◷ Waiting for pull_request.merged #44`, with `cancellable: true`.
  - An open 039 `Block` with agent waits gives `◷ Waiting for "Fix login" to finish` in both the line and the mark, with `cancellable: false`.
  - An `agent.finished` wait filtered to those same agents gives identical text (FR-012, R4).
  - Otherwise it returns `nil`.
- [X] T019 [P] [US2] Create `Pkg/Tests/AgentsKitTests/Unit/WaitStatusTests.swift`. Cover:
  - the line and the mark for an event wait with and without a deadline;
  - a block on one agent and on two agents;
  - the block-versus-`agent.finished` equality;
  - `nil` for a plain agent.
- [X] T020 [US2] In `Pkg/Sources/AgentsKitCore/Client/AgentsModel.swift`, add `Update.eventsChanged(EventsChange)` and decode it for `DaemonAPI.Notification.eventsChanged`. Keep `recentEvents: [Event]`, the newest 200 inserted or replaced by `position`, plus `waiting: [WaitingAgent]` and a `loadEvents(before:)` that calls `events/list`. The Remote model reads the same fields (`Remote/Sources/RemoteModel.swift`, beside its `leasesSnapshot` call).
- [X] T021 [P] [US2] Create `Shared/UI/Events/EventRow.swift`, the one row both platforms draw:
  - the time; the sentence in `reading` size; the name in `fine` monospace with its scope ("This Mac" or the project name); the subject glyph; `×N` when `count > 1`.
  - Consequences are indented under the event, each starting with ↳: *Woke*, *Fired*, *Refused by* with the reason, and *Could not wake* with the reason.
  - Agent names are links through a closure the platform supplies. Workflow names are links on the Mac and plain text on the phone.
  - There is no tint. The whole row is one accessibility element with one label (see memory: stacked accessibility labels crash AppKit).
- [X] T022 [US2] Add the Mac page: `App/Sources/Projects/SidebarItem.swift` gains `.events`, and `App/Sources/Projects/ProjectListView.swift` gets an Events row in the sidebar foot above Resources and Spending, with the same shape. Its line says "Last HH:mm", with no count.
- [X] T023 [US2] Create `App/Sources/Events/EventsView.swift`, the page in wireframes §1:
  - a project menu (All, This Mac, then each project) and the six subject capsules, which combine;
  - day headings (Today, Yesterday, then dates);
  - live insertion at the top that does not move what the person is reading, and a "1 new" capsule when scrolled down;
  - paging older events with `loadEvents(before:)`;
  - a "Waiting now" strip at the top listing every `WaitingAgent` with its line and ✕ (✕ calls `events/cancelWait`, wired in T041). The strip is absent when nobody is waiting.
- [X] T024 [P] [US2] Create `App/Sources/Events/EventDetailView.swift`, the right-hand detail for a clicked row: every detail, the publisher and message for `custom.*`, and the position. A **Copy as trigger** button puts `on:\n  - pull_request.merged:\n      number: 41` on the pasteboard, using the event's filterable details.
- [X] T025 [P] [US2] Phone and iPad:
  - In `Remote/Sources/Projects/ProjectListView.swift`, add an Events row next to `SpendingRow`, with the same shape.
  - Create `Remote/Sources/Events/EventsListView.swift`: the same `EventRow`s, a single project menu at the top, a read-only detail sheet with no Copy as trigger, and consequences that link to the chat. On iPad the list goes in the detail column.
  - There is no ✕, no subject filter and no Waiting now strip (wireframes §4).
- [X] T026 [US2] Build both schemes one after the other with plugin validation skipped (see memory). With the run-app skill, launch on `/tmp/run-042` and raise the wireframe's night of events with `events/raise`: a Mac sleep and wake, #41's checks failing with a `fired` consequence, `custom.build_green` with a `woke` consequence, and #41 merged. Screenshot the page, a detail, and the filter capsules into `specs/042-events-and-waiting/walk/`.
- [X] T027 [US2] **Look gate.** Show Alex the screenshots, and ask about the page layout and the sidebar row with `AskUserQuestion`. Do not start Phase 4 until he has answered. The phone look is his to do on a device when he chooses.

**Checkpoint**: The events page and list render live events on both platforms, and the look is
approved.

---

## Phase 4: User Story 1: An agent waits for something to happen, then carries on (P1) 🎯 MVP

**Goal**: `wait_for_event` and `cancel_wait` work. The call is held for 45 s and then answers
"still waiting". A match wakes the agent with a prompt. The deadline, the cancel paths and
restarts all behave. A waiting agent is Blocked everywhere.

**Independent Test**: Agent A waits on `agent.finished` for agent B. A's call answers "still
waiting" and A shows under Blocked with the capsule. When B finishes, A is running again within
seconds with the event in its prompt.

### Tests for User Story 1

- [X] T028 [P] [US1] Create `Pkg/Tests/AgentsKitTests/Integration/EventWaitTests.swift`, failing first, with `eventHoldLimit` shortened and events raised with `raise` directly. Cover:
  - A match inside the hold answers the open call with `EventWords.matched` (US1-AS2).
  - Reaching the hold limit answers "Still waiting", keeps the wait, and leaves A grouped as `.blocked` once its turn ends (US1-AS3, FR-012).
  - A match after the call closed wakes A with a `.app` prompt containing `EventWords.wake`, within 5 s (US1-AS4, SC-001).
  - A deadline with no match wakes A with "timed out" (US1-AS5).
  - `from`: an event after `from` answers at once, and the event at `from` does not (US1-AS8, R6).
  - Three matches while closed give one wake that says "2 more matches".
  - A second `wait_for_event` replaces the first, and its reply begins "Replaced your earlier wait".
  - Waiting on another project's scope never matches, and a `mac.*` wait does.
  - An unknown name, a bad filter and `until_minutes` 0 or 1441 are refused with `-32050` and the contract's words.
  - `action: recent` returns newest-first lines and a head. `action: list` returns `EventCatalogue.describe()`.
- [X] T029 [P] [US1] In the same file, add the cancel and restart cases:
  - `cancel_wait`, `events/cancelWait`, the person's prompt, stop and archive each end the wait with no later wake. The person's prompt carries `EventWords.cancelledByPrompt` before their text in the agent's input, and not in their bubble (US1-AS7, FR-013).
  - `cancel_wait` with nothing open gives `-32051`.
  - Restart 20 times with a wait open: it is there each time (SC-005).
  - A wait that was cleared, with its prompt queued, before a restart is resumed exactly once.
  - No event is raised for the time the daemon was down (FR-014).
  - When the runtime cannot be started: the consequence is `couldNotWake`, the wait is dropped, and A's transcript gets a runtime note naming the missed event.

### Implementation for User Story 1

- [X] T030 [P] [US1] In `Pkg/Sources/AgentsKitCore/Model/AppTool.swift`, add `waitForEvent = "wait_for_event"`, `cancelWait = "cancel_wait"` and `publishEvent = "publish_event"`, with the file's comment voice and a note that these three are offered to every agent, including helpers. None of the three is a suffix of another tool's name (compare 036's `release_resource` bug), and the tests in T036 assert that.
- [X] T031 [US1] Create `Pkg/Sources/AgentsKit/Daemon/DaemonCore+EventWaits.swift`, with `public func waitForEvent(_ request: EventWaitRequest) async throws -> String`:
  - Resolve the caller by token, as `leaseCaller` does.
  - For `recent` and `list`, answer straight away.
  - For `wait`: parse every name with `EventPattern.parse`, applying `where` to each. A `where.agent` given as a title resolves to an id with 039's `waitTarget(named:for:)` rules.
  - Take `from` or `eventLog.head`. Check `eventLog.matches(after:)` in the caller's scopes (its project plus `.mac`) and, if one is found, answer at once.
  - Otherwise, with no `await` in between, write `agent.eventWait` (replacing any open one and noting it for the reply), call `changed(agent)`, raise `agent.blocked` with `waiting_on`, and park a continuation in `openEventWaits[agentID]` with a hold timer set to `eventHoldLimit`.
  - When the hold limit is reached, answer `stillWaiting`.
  - Re-arm the deadline timer.
- [X] T032 [US1] In `DaemonCore+Events.swift`, fill in `matchWaits(event)`. For each agent with an open `eventWait` whose patterns match and whose scope is allowed:
  - If `openEventWaits[agentID]` exists, answer it with `matched`, clear the wait, and add a `woke` consequence.
  - Otherwise, in one write with no `await`, set `ending = .matched(position, extraMatches: 0)` and a new `resumePromptID`, queue the `.app` prompt with `EventWords.wake`, add the `woke` consequence, then send it on a detached task as 039's `sendResume` does.
  - A match on a wait that is ended but not yet sent increments `extraMatches`, so the prompt says how many more arrived.
  - When the send fails, drop the wait, add a `couldNotWake` consequence and write a runtime note (mirror `wake(_:askedAt:)` in `DaemonCore+Leases.swift`).
- [X] T033 [US1] Deadlines: in `DaemonCore+EventWaits.swift`, arm one timer for the earliest open deadline across agents. On firing, set `ending = .timedOut` and queue the `timedOut` prompt in the same write. Re-arm the timer on every wait change and at start.
- [X] T034 [US1] Cancel paths:
  - `cancelWait(token)` and `cancelWaitByPerson(agentID)` (`events/cancelWait`) clear the wait, answer any open call with `stoppedWaiting`, and broadcast.
  - In `Pkg/Sources/AgentsKit/Daemon/DaemonCore+Commands.swift`, the person's prompt (`prompt` with `from: .person`) clears an open wait and prepends `EventWords.cancelledByPrompt` to the text the runtime receives, not the transcript's bubble text. Stop and archive clear it with `.stopped` or `.archived`.
  - Every clear broadcasts `events/changed` with the new `waiting`.
- [X] T035 [US1] Grouping and restart:
  - In `Pkg/Sources/AgentsKitCore/Model/AgentGroup.swift`, an open `eventWait` while the state is not `starting`, `running` or `waitingOnUser` gives `.blocked`. Wanting a person still outranks it. Extend the existing `AgentGroup` tests.
  - In `DaemonCore+Recovery.swift`, re-arm deadlines, send any queued-but-unsent `resumePromptID` once, and close every open call (there are none after a restart).
  - `DaemonCore+Lifetime.swift`'s `isHoldingAgents` counts an agent with an open wait, as it counts lease waiters.
- [X] T036 [US1] Tools:
  - In `Pkg/Sources/AgentsKit/ACP/Serve/AppService.swift`, add the `wait_for_event` and `cancel_wait` schemas with the descriptions and inputs from `contracts/event-tools.md` verbatim, an `eventCall(named:_:)` parser beside `leaseCall`, and dispatch.
  - In `Daemon/Sources/main.swift`, relay them to `events/wait` and `events/cancel`, as the lease tools are relayed at `main.swift:110`.
  - Add `events/wait` and `events/cancel` to `DaemonCore+Dispatch.swift`.
  - Extend `Pkg/Tests/AgentsKitTests/Unit/AppServiceTests.swift`: `tools/list` includes all three new tools, and no tool name is a suffix of another's.
- [X] T037 [US1] Briefing: in `Pkg/Sources/AgentsKit/ACP/Serve/Briefing.swift`, add the events paragraph described in `contracts/event-tools.md` §Briefing. Extend `BriefingTests`.
- [X] T038 [US1] Agent events through `raise`. In `Pkg/Sources/AgentsKit/Daemon/DaemonCore.swift`, at the three `workflowsRespond` call sites (lines ~637, ~819 and ~855), raise the matching events:
  - `agent.finished` with `outcome`;
  - `agent.stopped` with `by`, or `agent.failed` with `reason`, according to the `EndedReason` (a person, an agent or the app gives stopped; a process death or an error gives failed);
  - `agent.asked_form` and `agent.asked_permission`.
  Also raise `agent.started` where a new agent's first turn begins. Each carries `agent`, `agent_title` and `chainDepth` from `workflowChainDepth(causedBy:)`, and `sentence` in plain words ("“Fix login” finished: done"). Leave the `workflowsRespond` calls in place for now: Phase 5 moves them.
- [X] T039 [US1] A 039 `blocked` report raises `agent.blocked` with `waiting_on` set to the waited agents' titles, in `DaemonCore+Blocks.swift` where the block is written.
- [X] T040 [P] [US1] Create `Shared/UI/Chat/WaitCapsule.swift`: the ◷ capsule drawn in `PromptHeader`'s lease row (`Shared/UI/Chat/LeaseRow.swift` / `PromptPieces.swift`), with the text of `WaitStatus.line`. On the Mac, clicking it opens the Events page with Waiting now in view, and ✕ calls `events/cancelWait`. The phone has no ✕. Above the prompt bar, while a wait is open, add the one-line hint from `EventWords.hint`, on both platforms.
- [X] T041 [US1] Row and card marks: `App/Sources/AgentList/AgentRow.swift` and `Remote/Sources/Projects/AgentCard.swift` show `WaitStatus.mark` on the same line 036 uses for `LeaseMark`. Wire the Events page's Waiting now ✕ (T023) to `events/cancelWait`.
- [X] T042 [US1] Run `swift test --filter 'EventWaitTests|WaitStatusTests|AppServiceTests|BriefingTests|AgentGroup'` until green, then the existing `Blocked|Lease|Workflow` suites, which must pass without edits.

**Checkpoint**: The MVP. An agent can wait on any agent event or a raised event, costs nothing
while it waits, and is woken, timed out or cancelled correctly.

---

## Phase 5: User Story 3: Workflows and waits use the same events (P3)

**Goal**: Every catalogue event can trigger a workflow, with the same names and filters as a
wait. The nine old names behave exactly as before. Workflow rows lead to their causing event.
Pull-request and branch events are raised.

**Independent Test**: An existing workflow file with `agent-finished` fires exactly as before.
A workflow on `mac.wake` and one on `custom.ping` both fire when those events are raised, and
each fire shows as a consequence on its event.

### Tests for User Story 3

- [ ] T043 [P] [US3] Create `Pkg/Tests/AgentsKitTests/Unit/WorkflowTriggerEventTests.swift`. Cover:
  - Every `.md` under `.agents/workflows/` in this repository, and every `WorkflowExample`, parses to the same `[WorkflowTrigger]` as before. Compare with a fixture captured from `main` in this task, before any parser change.
  - `mac.wake`, `custom.build_green`, `pull_request.*` and `pull_request.merged: {number: 41}` parse to `.event`.
  - `pull_request.merged: {branch: x}` is a file error that names `number`.
  - An unknown dotted name stays `.unrecognised`.
  - `.event` encodes as `.unrecognised(name, keys)`, and a copy of `main`'s `Stored` decoder reads it as a trigger it does not know (FR-025).
  - `summary` for `agent-finished` equals the summary for `agent.finished` (FR-022).
- [ ] T044 [P] [US3] Create `Pkg/Tests/AgentsKitTests/Integration/EventWorkflowTests.swift`. Cover:
  - A workflow on `mac.wake` fires once per raised `mac.wake`, and its fire is a `fired` consequence.
  - One on `custom.ping` with `agent: triggering` fires in the publisher. On `mac.wake` it is refused with `noTriggeringAgent`, and that refusal is a `refused` consequence (FR-023).
  - An `agent-finished` workflow fires exactly once per finish, both before and after the switch in T047 (it must never fire twice).
  - `workflow-completed` fires from `workflow.completed` at `run.depth + 1`.
  - `workflow.ran`, `workflow.completed` and `workflow.refused` appear in the log.
  - `WorkflowOutcome.ran` carries `causingEvent`.

### Implementation for User Story 3

- [ ] T045 [US3] In `Pkg/Sources/AgentsKitCore/Model/WorkflowTrigger.swift`:
  - Add `case event(EventPattern)` and `var patterns: [EventPattern]`, which maps today's cases (`agentStopped` gives `[agent.stopped, agent.failed]`, and `schedule` and `unrecognised` give `[]`).
  - Give `.event` its `summary` from `EventPattern.summary`, and `isSupported` is true for it.
  - In the hand-written `Codable`, encode `.event(p)` as `Stored.unrecognised(name: p.name, keys: p.filters.mapValues(JSONValue.string))`. When decoding `.unrecognised`, try `EventPattern.parse` before falling back, keeping 038's pull-request mapping first.
  - Add `func matches(_ event: Event) -> Bool` over `patterns`.
- [ ] T046 [US3] In `Pkg/Sources/AgentsKit/Workflows/WorkflowFile.swift`, `trigger(named:keys:)`: after the nine old names, try `EventPattern.parse(name, filters: keys as strings)`. A parse failure for a known subject or kind is a `YAMLNode.Failure` with the pattern's message. An unknown name stays `.unrecognised`. The file is never written back.
- [ ] T047 [US3] Move the agent-event firing behind `raise` (R7). Fill in `fireWorkflows(for: event)` in `DaemonCore+Events.swift`:
  - For each workflow in the event's project (or in every project for a `.mac` event) that is not archived and has a trigger where `trigger.matches(event)` holds, fire it on a detached task, as `workflowsRespond` does, with `depth: event.chainDepth` and `triggeringAgentID` from `details["agent"]`.
  - Keep `deferredLifecycleEvents` holding the workflow matching (not the logging) until `workflowsAreStarted`.
  - Delete the direct `workflowsRespond` calls from T038's sites, so there is exactly one route.
  - `workflowRunFinished` raises `workflow.completed` and stops firing `respondsToCompletion` directly.
  - Pull-request triggers written with the old names stay in 038's `firePullRequestTriggers` (R8). Exclude them here with `trigger.isPullRequest`.
- [ ] T048 [US3] Consequences and causing events:
  - `fire(_:on:…)` takes `causingEvent: EventPosition?`, and records a `fired` or `refused` consequence against it.
  - `record(_:for:)` raises `workflow.ran` or `workflow.refused`.
  - In `Pkg/Sources/AgentsKitCore/Model/WorkflowOutcome.swift`, `.ran` and `.refused` gain `causingEvent: EventPosition?`, encoded only when present.
  - 038's `firePullRequestTriggers` passes the position of the matching `pull_request.*` event raised in T050, so 038 fires still show on the log.
- [ ] T049 [US3] `manage_workflows`: in `AppService.swift`, append `EventCatalogue.describe()` to its description, under "Triggers you can use", so it is the same text as `wait_for_event`'s `list` (FR-024). Extend the `AppServiceTests` assertion to compare the two strings.
- [ ] T050 [US3] Pull-request events, in `Pkg/Sources/AgentsKit/Daemon/DaemonCore+PullRequests.swift`, after each refresh (R8):
  - Diff the new `PullRequestList` against `eventState.pullRequestsSeen[folder]` and raise `opened`, `checks_failed`, `checks_passed`, `approved`, `changes_requested`, `conflicts` and `review_comments`, each followed by `pull_request.changed` with `what`.
  - For a number that has left the open list, make one `gh api graphql` call through the injected `GitHubCLI` for `pullRequest(number:){ state }`, which gives `merged` or `closed`. If that fails, raise nothing and try again at the next refresh.
  - The first refresh after start only seeds the list, except for a merged or closed pull request that was in the stored list.
  - Save `pullRequestsSeen`.
  - Add tests with the fake `GitHubCLI` in `Pkg/Tests/AgentsKitTests/Integration/PullRequestEventTests.swift`: every transition, merged versus closed, a failed follow-up, and 038's babysitter still firing exactly once.
- [ ] T051 [US3] `branch.moved`, in a new `Pkg/Sources/AgentsKit/Daemon/DaemonCore+EventSources.swift` (R9):
  - Start the project's `FolderWatch` for every project, not only ones with workflows, and add a callback for paths under `.git/refs/`, `.git/packed-refs`, `.git/HEAD` and `.git/worktrees/*/HEAD`, debounced by 1 s.
  - Run `git rev-parse` for the default branch and the branch of each live agent's worktree, off the actor. Compare with `eventState.branchTips` and raise one event per change, with `branch`, `from` and `to`.
  - At start, store the tips and raise nothing, apart from a tip that moved while the daemon was down, which carries the time it was noticed.
  - Add tests with a temporary git repository in `Pkg/Tests/AgentsKitTests/Integration/BranchEventTests.swift`.
- [ ] T052 [US3] Workflow row link: in `App/Sources/Projects/WorkflowRow.swift`, the latest-outcome line reads "Ran 06:55 on pull_request.merged #41 ›" when `causingEvent` is set. The event part links to that row on the Events page, and the run link still goes to the agent (FR-030, wireframes §3).
- [ ] T053 [US3] Run `swift test --filter 'Workflow|PullRequest|EventWorkflow|BranchEvent|WorkflowTriggerEvent'`. Every existing workflow and 038 suite must pass without edits (SC-006).

**Checkpoint**: Workflows and waits read one catalogue through one route. Old files are
unchanged, and pull requests and branches raise events.

---

## Phase 6: User Story 4: Agents signal each other with events they publish (P4)

**Goal**: `publish_event` records `custom.*` events attributed to the agent, with a rate limit
and a chain-depth step.

**Independent Test**: A waits on `custom.ping`. B publishes `custom.ping` with a message. A wakes
with B's message, and the log shows the publish, attributed to B, with A woken as its
consequence.

- [X] T054 [P] [US4] Add to `EventWaitTests.swift`, failing first:
  - Publishing wakes a waiter and fires a `custom.ping` workflow. Its reply lists both consequences.
  - The event has `publisher` and `message`.
  - `mac.wake` and `agent.finished` are refused with `publishOutsideCustom`.
  - A message over 500 characters, 11 details, or a detail over 200 characters is refused.
  - The 31st publish within an hour is refused with `publishLimit`, naming when the next is allowed (FR-019).
  - A publish by a workflow's agent fires the next workflow at `depth + 1`, and a loop stops at the depth limit (FR-020).
- [X] T055 [US4] Implement `publishEvent(_ request: EventPublishRequest)` in `DaemonCore+EventWaits.swift`:
  - Resolve the caller.
  - Check `EventCatalogue.isCustom`, the size limits, and `eventState.publishes[agentID]` over the last hour, pruning older entries.
  - Raise it with `scope: .project(caller.projectFolder)`, `publisher`, `message`, `details` and `chainDepth: workflowChainDepth(causedBy: caller.id)`.
  - Reply with `EventWords.published(event, consequences)`, using the consequences known when `raise` returns.
- [X] T056 [US4] Add the `publish_event` schema and dispatch to `AppService.swift`, the relay in `Daemon/Sources/main.swift`, and the `events/publish` case in `DaemonCore+Dispatch.swift`. In `EventDetailView` (T024), show the publisher and the message.
- [X] T057 [US4] Run `swift test --filter EventWaitTests` until green.

**Checkpoint**: Agents coordinate by what happened. Publishing is limited and chain-safe.

---

## Phase 7: User Story 5: The machine and the person are events too (P5)

**Goal**: The app raises `mac.sleep`, `mac.wake`, `person.away`, `person.back`,
`cost.limit_reached`, `lease.*` and `server.*`.

**Independent Test**: Sleep and wake the Mac, lock and unlock it, and reach a cost limit on a
scratch root. Each appears in the log labelled "This Mac", and a waiting agent and a workflow
each respond to one of them.

- [ ] T058 [US5] **Spike, ten minutes, first.** In a scratch Swift file under `/tmp/042-spike`, not in the repository, check that `DistributedNotificationCenter` delivers `com.apple.screenIsLocked` and `com.apple.screenIsUnlocked` to a process that runs `dispatchMain()` under launchd, as agentsd does. Write the result in `research.md` R10. If it fails, T059 takes lock and unlock from the app's `presence/report` instead.
- [ ] T059 [US5] Create `Pkg/Sources/AgentsKit/Power/MachineWatch.swift`.
  - `protocol MachineWatch: AnyObject, Sendable { func start(_ report: @escaping @Sendable (MachineChange) -> Void); func stop() }`, where `MachineChange` is `sleep, wake, away(why: String), back(why: String)`.
  - The IOKit implementation, behind `#if canImport(IOKit)`, uses `IORegisterForSystemPower` for will-sleep (call `IOAllowPowerChange` after reporting) and has-powered-on, the lock notifications (or presence, per T058), and a 30 s `HIDIdleTime` poll with a 300 s threshold. It raises no idle "away" while locked.
  - Add `FakeMachineWatch` in `Pkg/Tests/AgentsKitTests/Support/`.
  - On Linux there is no watch at all.
- [ ] T060 [US5] In `DaemonCore+EventSources.swift`, start the watch when the daemon starts and stop it when it goes. Map each `MachineChange` to `raise` of `mac.sleep`, `mac.wake`, `person.away` or `person.back`, with Mac scope and a plain sentence ("This Mac woke up"). Inject it through `useForEvents(machineWatch:)` in tests.
- [ ] T061 [US5] `cost.limit_reached` (R11): where `isDayLimitReached` and `agent.isAtCostLimit` refuse in `DaemonCore+Commands.swift`, raise it once per crossing. Use `limit: day` with Mac scope, or `limit: agent` with project scope and `agent`, remembered in `eventState.costCrossings` by day.
- [ ] T062 [US5] Lease events: in `DaemonCore+Leases.swift`, `settle`, raise `lease.granted` (with `resource` and `agent`) for `.granted`, and `lease.released` (with `resource` and `how`: released, ended or expired) for `.released`, both with Mac scope.
- [ ] T063 [US5] Server events: if 037 (servers) is on `main` by now, raise `server.offline` and `server.online` from its connection-state change, with `server`. If it isn't, leave the two kinds in the catalogue with no source, and note that in `walk/README.md`.
- [ ] T064 [P] [US5] Create `Pkg/Tests/AgentsKitTests/Integration/MachineEventTests.swift` with `FakeMachineWatch`. Cover:
  - sleep then wake gives both events in order;
  - a wait on `mac.wake` from project P wakes, and a workflow on `mac.wake` in project Q fires (US5-AS3);
  - lock and unlock give away and back with `why: locked`;
  - a cost crossing is raised once;
  - lease granted and released appear with Mac scope.

**Checkpoint**: Every row of the catalogue has a source, apart from the server events if 037 has
not landed.

---

## Phase 8: Polish and proof

- [ ] T065 Build both schemes one after the other with plugin validation skipped, then run the full `swift test` six times. Compare the failures with T002's baseline on `main`, and treat only new ones as this lane's.
- [ ] T066 Run quickstart §3 with the run-app skill on `/tmp/run-042`: "Waiter" and "Pinger" with Claude, then Grok and Cursor as Waiter. Record what each runtime did with the 45 s hold. Screenshot the Events page, the waiting chat (capsule and hint line) and the workflow row link into `specs/042-events-and-waiting/walk/`.
- [ ] T067 Run quickstart §4 (sleep and wake, lock and unlock) only when Alex is away, after checking idle and lock state first (see memory). Otherwise list it for him in `walk/README.md`.
- [ ] T068 Quickstart §5: commit on a scratch project's default branch and see `branch.moved`. For the pull-request events on `alexec/agents-babysit-sandbox`, ask Alex with `AskUserQuestion` before pushing to or merging his sandbox pull request.
- [ ] T069 [P] Write `specs/042-events-and-waiting/walk/README.md`: what was walked, the screenshots, what each runtime did, what is left for Alex (the phone and iPad look, and the Mac sleep if it was not run), and any known gaps.
- [ ] T070 Merge `main` into the branch again, check `git merge-base --is-ancestor main HEAD`, rebuild both schemes and run the event suites. Then report to Alex that the branch is ready, and do not merge it into `main` until he says it is this lane's turn.

---

## Dependencies

- **Setup (T001–T002)** comes first.
- **Foundational (T003–T015)** blocks every story. T007 needs T003. T010 needs T009. T013 needs T003 and T007. T015 needs T013.
- **US2 (Phase 3)** needs the foundational phase. T016 comes before T017 and T020, and T020 before T022–T025. **T027's look gate blocks Phase 4.**
- **US1 (Phase 4)** needs US2's `raise` and `WaitStatus`. T031 comes before T032–T034, and T036 needs T031.
- **US3 (Phase 5)** needs US1's T038, the agent events through `raise`. T045 comes before T046 and T047, and T047 before T048. T050 and T051 are independent of each other.
- **US4 (Phase 6)** needs US1 (waits) and US3 (firing workflows from `raise`).
- **US5 (Phase 7)** needs only `raise` from US2 to raise its events. Its waiting and workflow proof needs US1 and US3. T058 comes before T059.
- **Polish (Phase 8)** needs everything else.

## Parallel opportunities

- Foundational: T003, T004, T005, T009, T011 and T012 are separate files. T006 and T008 are written alongside their subjects.
- US2: T018 and T019 (WaitStatus), T021 (EventRow), T024 (detail) and T025 (phone) run alongside T022 and T023 once T020 is done.
- US1: T028 and T029 (tests), T030 (tool names) and T040 (capsule) run alongside T031.
- US3: T043 and T044 (tests) run together. T050 (pull requests) and T051 (branches) run together after T047.
- US5: T059–T063 touch different sources. T064 runs alongside them.

Example, the US2 fan-out after T020:

```text
T021 Shared/UI/Events/EventRow.swift
T024 App/Sources/Events/EventDetailView.swift
T025 Remote/Sources/Events/EventsListView.swift
```

## Implementation strategy

1. **The MVP is Phases 1–4.** The events page (settled first) plus waiting on agent events and
   raised events. That alone answers "stop polling". Stop at the Phase 4 checkpoint and prove it
   with two real agents before going further.
2. **Then build incrementally.** US3 (workflows on events, pull requests, branches), then US4
   (publish), then US5 (machine and person). Each ends at its checkpoint with its suites green
   and the existing suites unchanged.
3. **Gates that belong to Alex**: the Phase 3 look gate, the phone and iPad look, the Mac sleep
   walk if he is at the Mac, and anything that touches his sandbox repository.
