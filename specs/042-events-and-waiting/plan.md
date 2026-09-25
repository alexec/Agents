# Implementation Plan: Events and Waiting

**Branch**: `042-events-and-waiting` | **Date**: 2026-09-25 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `specs/042-events-and-waiting/spec.md`

## Summary

The daemon keeps one **event log** for the Mac. Every event is appended through a single
function, `DaemonCore.raise(_:)`. That function does five things in order:

1. Coalesces the event with an identical one from the last 60 seconds, or gives it the next
   position.
2. Appends it to `events.jsonl` under the store root.
3. Matches it against every open wait.
4. Matches it against every workflow trigger.
5. Records what came of it, its **consequences**, and broadcasts `events/changed`.

Nothing else decides who hears about an event. Workflows and waits read the same event, and
they are tested with the same pattern-matching function, so they cannot drift apart (FR-021,
FR-024).

The **catalogue** is a static table in AgentsKitCore. Each entry has a name, a subject, a
scope, the details the event carries, one sentence of meaning, and the old trigger name it
answers to, if it has one. Four things read it:

- the wait tool's `list` answer
- the `manage_workflows` description
- the file parser
- the events page

`WorkflowTrigger` gains one case, `.event(EventPattern)`. Today's nine cases stay exactly as
they are, and each one maps to a pattern. Old files therefore parse to the same values, and
nothing is rewritten (FR-022). New names cross the wire in the `.unrecognised` shape, the way
038's pull-request triggers already do. An older device reads them as triggers it does not know
(FR-025).

A **wait** is a field on the agent's record, `eventWait`. It sits beside 039's `Block` but
separate from it, because an agent makes a wait in the middle of a turn, while a block arrives
with the report at the turn's end. `wait_for_event` holds the call open for up to 45 s in a
continuation, the way `lease_resource` does. If nothing matches in that time, it answers
"still waiting". When the event arrives after the agent's turn has ended, one write clears the
wait and queues an app prompt, following 039's `queueResume` shape. That prompt goes through
`DaemonCore.prompt`, the path leases and blocks already use. A waiting agent groups as
**Blocked**. One shared `WaitStatus` function draws both kinds of wait, a block on agents and a
wait on events, so the Mac and the phone show them the same way (FR-012).

Two more tools come with it:

- `publish_event` adds `custom.*` events, with a rate limit and one step deeper in the workflow
  chain (FR-017 to FR-020).
- `cancel_wait` ends the caller's wait.

Reading the log and the catalogue is not a fourth tool. `wait_for_event` does it, with
`action: recent` or `action: list`, so there are three tools in all (research R2).

The new event sources hook into places that already see the change:

| Events | Where they come from |
|---|---|
| Agent events | The lifecycle funnel, which today calls `workflowsRespond` |
| Workflow events | `record(_:for:)` |
| Pull request events | A diff of the old and new `PullRequestList` in 038's refresh, plus one follow-up query for a pull request that has left the open list |
| `branch.moved` | The project's existing `FolderWatch`, filtered to `.git` refs |
| Lease events | `LeaseEvent` in `settle` |
| Mac and person events | A new `MachineWatch`, using IOKit power notifications, the screen-lock distributed notification and HID idle time. It sits behind a protocol, like `PowerSource`. |
| `cost.limit_reached` | The existing checks against the limits |
| Server events | 037's connection state, where 037 has landed |

The Mac gets an **Events** row in the sidebar foot. Its page has a "Waiting now" strip,
filters, day headings, consequences and a detail pane with "Copy as trigger". The phone and
iPad get an **Events** row under the project list, with the same rows, read-only. Workflow rows
link to the event that caused them.

See [wireframes.md](wireframes.md) for the layout and [research.md](research.md) for the
decisions. [data-model.md](data-model.md) has the types and files, and [contracts/](contracts/)
has the tool and daemon shapes.

## Technical Context

**Language/Version**: Swift 6 (strict concurrency), SwiftUI

**Primary Dependencies**:
- AgentsKit and AgentsKitCore, the in-repo package
- The app's MCP server (`AppService`), relayed by `agentsd mcp`
- IOKit (`IORegisterForSystemPower`, `HIDIdleTime`) and `DistributedNotificationCenter` for the Mac events, used only on macOS behind `#if canImport(IOKit)`, because agentsd also builds for Linux (037)
- `git` and `gh`, which the app already uses

**Storage**:
- `events.jsonl` (new), under the store root. One JSON event per line, appended. It is rewritten only when pruned: at start and hourly, keeping 7 days and at most 10,000 events (FR-032).
- `events-state.json` (new): the next position, the branch tips last seen and each agent's publish counts. It is small and written whole, like `leases.json`.
- The wait is on the agent record: `Agent.eventWait`, optional and decoded if present. Older phones skip the key.

**Testing**:
- swift-testing in `Packages/AgentsKit`
- Unit tests for the pure log, catalogue, patterns, alias mapping and status words
- Integration tests with fake runtimes and a fake `MachineWatch`, covering hold, wake, cancel, restart, publish, chain depth and workflows firing on new events
- xcodebuild for both schemes
- The run-app skill for the end-to-end pass on a scratch root

**Target Platform**: The macOS app and `agentsd`. The iOS/iPadOS Remote app reads the events list, the waiting capsule and the Blocked grouping.

**Project Type**: A desktop app with a daemon, and a companion iOS app

**Performance Goals**:
- A waiting agent is running again within 10 s of its event (SC-001). Matching is a linear pass over at most tens of waits and workflows, on the actor.
- An append is one `write` to an open file handle. Nothing rewrites the whole log on each event.
- `mac.wake` is raised within 10 s of waking (SC-002).
- The events page shows the newest 200 and pages older ones on demand.

**Constraints**:
- One resume per wait, even across a restart (FR-007, SC-005). Clearing the wait and queuing the prompt happen in one write, with no `await` between the check and the write.
- A held call returns before a runtime gives up on it: 45 s, the same as 036 (FR-008).
- No event carries transcript text, file contents or credentials (FR-004).
- Events are never back-filled for time the daemon was not running (FR-014).
- Older phones must keep reading agent records and workflow summaries.

**Scale/Scope**:
- 3 agent tools: `wait_for_event`, `cancel_wait` and `publish_event`
- 5 daemon methods: 3 relayed for agents, `events/list` and `events/cancelWait` for the person
- 1 notification, `events/changed`
- 2 files
- 1 Mac page, 1 phone and iPad list, 1 shared waiting capsule and hint line
- 1 link from a workflow row to its event
- 1 briefing paragraph
- 30 kinds in the catalogue, plus the `custom.*` family

## Constitution Check

The constitution (`.specify/memory/constitution.md`) is still the unfilled template, so there
are no gates to check. The plan follows the repo's own working rules:

- **Settle the UX before depth.** Phase 2 builds the events page, the waiting capsule and the
  phone list first, against events raised by hand over the socket. They are screenshotted on a
  scratch root before any real source is wired in.
- **One path, not two.** Every event goes through `raise`. Workflows stop being called directly
  from the lifecycle funnel and are matched in `raise` instead. A woken agent is prompted
  through `DaemonCore.prompt`. A wait on events shows through the same `WaitStatus` as 039's
  block.
- **Decide in one place.** The catalogue, the log and the pattern matching are pure and live in
  Core. The phone renders what the daemon sends and never matches anything itself.
- **Prove it running.** Quickstart §3 runs two real agents, one publishing and one waiting, on a
  scratch daemon, and §4 sleeps and wakes the Mac. This isn't left as a walk for Alex.
- **Never mutate source to prove a test.** Fakes are injected (`MachineWatch`, `GitHubCLI`, the
  clock) and nothing is patched.

Re-checked after design: still no violations.

## Project Structure

### Documentation (this feature)

```text
specs/042-events-and-waiting/
├── spec.md
├── wireframes.md, wireframes/
├── plan.md              # this file
├── research.md
├── data-model.md
├── quickstart.md
├── contracts/
│   ├── event-tools.md   # wait_for_event, cancel_wait, publish_event: inputs and every reply
│   ├── daemon-api.md    # methods, the notification, failures, wire shapes, trigger syntax
│   └── catalogue.md     # the 30 kinds and custom.*: details, scope, sentence, source, alias
├── checklists/
└── tasks.md             # /speckit-tasks, not yet
```

### Source Code

```text
Packages/AgentsKit/Sources/AgentsKitCore/
├── Model/AppTool.swift              # waitForEvent, cancelWait, publishEvent
├── Model/Event.swift                # NEW: Event, EventScope, EventPosition, Consequence, EventPublisher
├── Model/EventCatalogue.swift       # NEW: EventKind table, subjects, sentences, aliases, `describe`
├── Model/EventPattern.swift         # NEW: name or subject.*, detail filters, matches(_:), parse from YAML/JSON
├── Model/EventLog.swift             # NEW: pure log: append/coalesce, prune, query(after:scope:subjects:limit)
├── Model/EventWait.swift            # NEW: EventWait, WaitEnding for events (matched/timedOut/cancelled)
├── Model/WaitStatus.swift           # NEW: one line + mark for Block.waits or eventWait (FR-012)
├── Model/EventWords.swift           # NEW: the tool replies, the wake prompt, the hint line
├── Model/Agent.swift                # eventWait: EventWait?
├── Model/AgentGroup.swift           # open eventWait while not running → .blocked
├── Model/WorkflowTrigger.swift      # .event(EventPattern); old cases ↔ patterns; wire as .unrecognised
├── Model/WorkflowOutcome.swift      # .ran/.refused carry causingEvent: EventPosition?
├── Daemon/DaemonAPI.swift           # methods, EventsPage, events/changed, Failure.eventRefused…
└── Client/AgentsModel.swift         # recent events + Update.eventsChanged

Packages/AgentsKit/Sources/AgentsKit/
├── ACP/Serve/AppService.swift       # 3 tool schemas + dispatch; manage_workflows lists the catalogue
├── ACP/Serve/Briefing.swift         # the events paragraph
├── Workflows/WorkflowFile.swift     # dotted names + detail filters parse to .event
├── Store/EventStore.swift           # NEW: events.jsonl append/load/prune, events-state.json
├── Power/MachineWatch.swift         # NEW: protocol + IOKit/lock/idle implementation (macOS only)
└── Daemon/
    ├── DaemonCore+Events.swift      # NEW: raise, match waits and workflows, consequences, broadcast, page
    ├── DaemonCore+EventWaits.swift  # NEW: the tools, hold, wake, deadline timer, cancel paths, restart
    ├── DaemonCore+EventSources.swift# NEW: branch watch, machine watch, cost limit, lease + server adapters
    ├── DaemonCore+PullRequests.swift# diff old/new list → pull_request.*; follow-up for merged/closed
    ├── DaemonCore+Workflows.swift   # workflowsRespond becomes a caller of raise; fire(on event)
    ├── DaemonCore+Commands.swift    # person's prompt / stop / archive cancel the wait
    ├── DaemonCore+Blocks.swift      # agent.blocked raised; nothing else changes
    ├── DaemonCore+Leases.swift      # lease.granted / lease.released raised from settle
    ├── DaemonCore+Recovery.swift    # load log + state, re-arm deadlines, resume cleared-but-unsent
    └── DaemonCore+Dispatch.swift    # 5 cases

Daemon/Sources/main.swift            # relay the 3 tools

App/Sources/Projects/SidebarItem.swift        # .events
App/Sources/Projects/ProjectListView.swift    # Events row above Resources and Spending
App/Sources/Events/EventsView.swift           # NEW: page, filters, Waiting now, day headings, "1 new"
App/Sources/Events/EventDetailView.swift      # NEW: details, publisher, position, Copy as trigger
App/Sources/Projects/WorkflowRow.swift        # "Ran 06:55 on pull_request.merged #41 ›"
Shared/UI/Events/EventRow.swift               # NEW: one row + consequences, both platforms
Shared/UI/Chat/WaitCapsule.swift              # NEW: ◷ capsule in PromptHeader's lease row; ✕ on Mac only
Shared/UI/Chat/PromptPieces.swift             # capsule + "Sending will cancel the wait…" hint
App/Sources/AgentList/AgentRow.swift          # WaitStatus.mark
Remote/Sources/Projects/AgentCard.swift       # WaitStatus.mark
Remote/Sources/Projects/ProjectListView.swift # Events row next to Spending
Remote/Sources/Events/EventsListView.swift    # NEW: read-only list, project menu, detail sheet

Packages/AgentsKit/Tests/AgentsKitTests/
├── Unit/EventLogTests.swift              # positions, coalesce 60 s, prune 7 d / 10k, query filters
├── Unit/EventPatternTests.swift          # full, wildcard, filters, custom.<name>, refusals
├── Unit/EventCatalogueTests.swift        # every alias maps; manage_workflows text == list text
├── Unit/WorkflowTriggerEventTests.swift  # old files parse identically; wire shape; old decoder reads new
├── Unit/WaitStatusTests.swift            # block on agents and wait on agent.finished read the same
├── Unit/EventStoreTests.swift            # append, torn last line, prune rewrite
└── Integration/EventWaitTests.swift      # hold+match, still waiting, wake, deadline, cancel ×4, restart ×20,
                                          # from-position, several matches, cannot wake, publish limit,
                                          # chain depth, workflows on mac.wake/custom.*, older phone decode
```

**Structure Decision**: This uses the existing layout: the `DaemonCore+Area` split for the
daemon, models in Core because both platforms read them, and stores and machine watching on the
Mac only. There is one new Mac folder, `Events/`, next to `Resources/`, and one on the phone.
The shared row and capsule go in `Shared/UI`, so the two platforms draw them identically.

## Phases (for /speckit-tasks)

1. **The pure core (US1, US3).** `Event`, `EventCatalogue`, `EventPattern`, `EventLog`,
   `EventWait` and `WaitStatus`, with their unit tests. Add `WorkflowTrigger.event` with the
   alias and wire tests. No daemon work yet.
2. **Seen first (US2).** `EventStore`, `raise` (log and broadcast only), `events/list`,
   `events/changed`, `AgentsModel`, the Mac page, the phone list, the waiting capsule and the
   hint line. Feed them from a debug `events/raise` method that exists only in test builds.
   Screenshot on a scratch root and show Alex before going on, to settle the UX.
3. **Agents wait (US1, P1).** `wait_for_event` and `cancel_wait`, the 45 s hold, the wake
   prompt, deadlines, the cancel paths, restart recovery, Blocked grouping, the relays and the
   briefing. Agent and workflow events are raised from the funnel, and `workflowsRespond`
   becomes a subscriber.
4. **Workflows on events (US3).** `raise` fires matching workflows through `fire` with a
   `causingEvent`. Record consequences, including refusals. Add the workflow-row link. The
   parser accepts dotted names and filters. `manage_workflows` gains the catalogue text.
   Prove every existing file is unchanged (SC-006).
5. **Publish (US4).** `publish_event`, the `custom.` namespace, the 30-an-hour limit and chain
   depth plus one.
6. **More sources (US5, rest of US1).** Pull-request diffing and the merged/closed follow-up,
   `branch.moved`, `MachineWatch` (sleep, wake, lock and idle), `cost.limit_reached`, the two
   lease events, and the server events if 037 is on main by then.
7. **Proof.** Both builds, the full suite, and the quickstart run-app pass with two real agents,
   a Mac sleep and wake, and screenshots. The phone look is Alex's.

## Risks

- **Moving workflow firing behind `raise`.** Today the lifecycle funnel calls
  `workflowsRespond` directly, with careful handling of the deferred events that arrive before
  workflows are loaded (`deferredLifecycleEvents`). The move keeps that deferral: `raise`
  records the event at once, and holds only the workflow matching until workflows start. The
  existing workflow suites must pass unchanged before anything new is built on this (research
  R7).
- **Double firing during the switch-over.** A pull-request change must fire its 038 workflow
  exactly once. 038's own `PullRequestChanges.unfired` bookkeeping stays the thing that decides
  whether a pull-request workflow fires. Only triggers written in the new dotted form go
  through event matching (research R8).
- **Screen-lock notifications in a daemon.** `DistributedNotificationCenter` needs a running
  main queue, which agentsd has (`dispatchMain`), but this is unproven here. Phase 6 starts
  with a ten-minute spike. If it fails, the app reports lock and unlock over `presence/report`,
  which it already sends (research R10).
- **Holding the call.** The same risk as 036: 45 s is under every runtime's timeout that has
  been measured. Copilot sessions get none of the app's tools, so they cannot wait.
- **Log size.** 10,000 lines at about 400 B each is about 4 MB. Loading it at start takes
  milliseconds. The page is sent 200 events at a time, never the whole log.
- **Wake storms.** A `pull_request.changed` wait and a workflow on it both respond to every
  pull-request event. Coalescing (FR-031), one wait per agent and one run at a time per workflow
  keep this bounded.

## Complexity Tracking

None. There are no constitution gates. The design adds one extension point, `raise`, and routes
the existing workflow triggers through it rather than beside it.
