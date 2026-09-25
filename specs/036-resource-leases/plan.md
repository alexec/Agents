# Implementation Plan: Agents Take Turns With the Mac's Shared Things

**Branch**: `036-resource-leases` | **Date**: 2026-09-24 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `specs/036-resource-leases/spec.md`

## Summary

The daemon keeps one **lease book** for the Mac: every resource that is held or has a line, who
holds it, until when, and who is waiting. It is a plain value type in AgentsKitCore that decides
everything (grant, queue, extend, release, expire, drop an agent) as pure functions of the book
and the time. `DaemonCore` owns one copy, writes it to `leases.json` under the store root after
every change, and broadcasts the whole book as `leases/changed`. The Mac, the phone and the iPad
read the same snapshot through `AgentsModel`.

Agents get three app tools on the MCP server they already have. `lease_resource` takes, extends,
or waits in line. `release_resource` gives a lease back or leaves a line. `list_resources` lists
what the Mac has and what the caller holds. A call that has to wait stays open in the daemon as a
continuation for up to **45 seconds**, which is under the shortest runtime timeout (Codex, 60 s).
It then returns "still in line" with the caller's place kept. When a lease reaches an agent whose
call is no longer open, the daemon queues an app prompt on it, which starts it again through the
same `prompt` path workflows use.

Expiry, the five-minute warning and a restart all use one timer, set for the next deadline in
the book. Stop and archive release everything the agent holds or waits for. Only agents hold
leases. The person watches them from a new **Resources** page in the Mac sidebar, and from there
can end any lease or take an agent out of a line, but never take a lease. The chat gets a
status line above the prompt bar, and the Mac row and phone card get a short mark. Both come
from one shared function, so the Mac and the phone can't disagree.

See [wireframes.md](wireframes.md) for the layout, [research.md](research.md) for the decisions, [data-model.md](data-model.md) for the types
and the file, and [contracts/](contracts/) for the tool and daemon shapes.

## Technical Context

**Language/Version**: Swift 6 (strict concurrency), SwiftUI

**Primary Dependencies**: AgentsKit / AgentsKitCore (in-repo package), the app's own MCP server (`AppService`) relayed by `agentsd mcp`, and `xcrun simctl` and LaunchServices for finding resources

**Storage**: One new JSON file, `leases.json`, under the store root, written through a `LeaseStore` like `LimitStore` and `WorkflowStore`. Agent records are unchanged.

**Testing**: swift-testing in `Packages/AgentsKit`: unit tests for the pure book and integration tests with fake runtimes for waits, wakes, stop/archive and restart. xcodebuild for both schemes. The run-app skill for the end-to-end pass.

**Target Platform**: macOS app + `agentsd`. The iOS/iPadOS Remote app only reads the status line and card.

**Project Type**: Desktop app with a daemon, plus a companion iOS app

**Performance Goals**: Grant to an open waiter within 1 s of release or expiry (SC-002). The book is tens of entries, so every operation is a linear pass. Discovery runs `simctl` at most once a minute, off the actor.

**Constraints**: At most one holder, however many calls arrive together (FR-002). The actor is the lock, so every check and write in a lease call happens before its first `await`. A waiting call must return before any runtime gives up on it (FR-004). Leases must survive a restart (FR-008). Agent records must stay readable by older phone builds, and they don't change.

**Scale/Scope**: No change to the start form or `start_agent` (FR-017). Three tools, six daemon methods (three for agents, one snapshot, and end and remove-from-line for the person), one notification, one file, one Mac page, one status line on each platform, one row/card mark on each platform, and one briefing paragraph.

## Constitution Check

The constitution (`.specify/memory/constitution.md`) is still the unfilled template, so there are
no gates to check. This plan follows the working rules the repo does have:
- **Settle the UX before depth**: the status line and the Resources page are built and seen
  first (Phase 2), against a book filled by hand over the socket. Waking and discovery come after.
- **One path, not two**: a woken agent is sent a prompt through `DaemonCore.prompt`, the path
  workflows and the outcome question already use, so limits, queueing and "after the current
  turn" come free. Stop and archive release leases inside the existing `stop`/`archive`.
- **Decide in one place**: the book is pure and shared. The daemon applies it and the views read
  it, so the phone never works out a lease for itself.
- **Prove it running**: quickstart §3 runs two agents against one resource on a scratch daemon,
  rather than leaving the walk to Alex.

Re-checked after design: still no violations.

## Project Structure

### Documentation (this feature)

```text
specs/036-resource-leases/
├── spec.md
├── plan.md              # this file
├── research.md
├── data-model.md
├── quickstart.md
├── contracts/
│   ├── lease-tools.md   # the three MCP tools, their inputs and every reply
│   └── daemon-api.md    # methods, requests, the notification, the failures
├── checklists/
│   └── requirements.md
└── tasks.md             # /speckit-tasks, not yet
```

### Source Code

```text
Packages/AgentsKit/Sources/AgentsKitCore/
├── Model/AppTool.swift              # leaseResource, releaseResource, listResources
├── Model/Lease.swift                # NEW: ResourceName, Resource, Holder, Lease, Waiter, LeaseEnding
├── Model/LeaseBook.swift            # NEW: the pure book: request/release/expire/drop/warn + LeaseLimits
├── Model/LeaseStatus.swift          # NEW: status(for agentID) → the chat line and card mark, shared
├── Daemon/DaemonAPI.swift           # 6 methods (no take), requests, LeaseSnapshot, leases/changed, Failure.leaseRefused
└── Client/AgentsModel.swift         # `leases` snapshot + Update.leasesChanged

Packages/AgentsKit/Sources/AgentsKit/
├── ACP/Serve/AppService.swift       # 3 tool schemas + dispatch
├── ACP/Serve/Briefing.swift         # the leases paragraph (FR-015)
└── Daemon/
    ├── LeaseStore.swift             # NEW: leases.json read/write
    ├── ResourceCatalog.swift        # NEW: simulators (simctl), browsers (LaunchServices), the screen
    ├── DaemonCore+Leases.swift      # NEW: tool entry points, open waits, wake, timer, person methods
    ├── DaemonCore.swift             # book, openWaits, leaseTimer, catalog
    ├── DaemonCore+Commands.swift    # stop/archive call dropLeases(for:)
    ├── DaemonCore+Lifetime.swift    # isHoldingAgents: a waiter to wake or an open wait
    ├── DaemonCore+Recovery.swift    # load the book, expire what lapsed, close stale waits
    └── DaemonCore+Dispatch.swift    # 6 cases

Daemon/Sources/main.swift            # relay the 3 tools

App/Sources/Projects/SidebarItem.swift        # .resources
App/Sources/Projects/ProjectListView.swift    # Resources row above Spending
App/Sources/Resources/ResourcesView.swift     # NEW: the page: watch, end, remove from line (no take)
Shared/UI/Chat/LeaseRow.swift                 # NEW: the capsule row, drawn by PromptHeader on both platforms (033's shared UI; on main, not yet on this branch)
Shared/UI/Chat/PromptPieces.swift             # PromptHeader shows LeaseRow above its row
App/Sources/AgentList/AgentRow.swift          # short mark
Remote/Sources/Projects/AgentCard.swift       # short mark, same LeaseStatus.mark

Packages/AgentsKit/Tests/AgentsKitTests/
├── Unit/LeaseBookTests.swift                 # NEW: one holder, order, extend-not-queue, cap, expiry, drop, names
├── Unit/LeaseStatusTests.swift               # NEW: line and mark text
├── Unit/AppServiceTests.swift                # tools/list includes the three
├── Unit/BriefingTests.swift                  # paragraph present
└── Integration/LeaseTests.swift              # NEW: wait+grant, limit, wake, stop/archive, restart, concurrency
```

**Structure Decision**: The existing layout. New files: `DaemonCore+Leases.swift`, following the
`DaemonCore+Area` split. `Lease`, `LeaseBook` and `LeaseStatus` go in Core because both platforms
read them. `LeaseStore` and `ResourceCatalog` are Mac only. There's one new Mac folder for the
page, next to `Spending/`.

## Phases (for /speckit-tasks)

1. **The book (US1, US2, US5, pure)**: `Lease.swift`, `LeaseBook.swift` and their unit tests: one holder, first come first served, re-request extends, the 4-hour cap, expiry and warning deadlines, dropping an agent, and name normalising. No daemon yet.
2. **Seen first (US3)**: `LeaseSnapshot`, `leases/changed`, `AgentsModel.leases`, `LeaseStatus`, the Mac status line, row mark and Resources page (read-only), and the phone line and card, all fed by leases taken by hand over the socket. Screenshot on a scratch root before going further (settle the UX).
3. **Agents take and wait (US1, US2, P1)**: `LeaseStore`, `DaemonCore+Leases` with open waits and the 45 s limit, the three tools, the relays, the briefing paragraph, transcript notes, and the wait/grant/concurrency integration tests.
4. **Leases end (US5)**: the timer, expiry and warning, stop/archive release, restart recovery, `isHoldingAgents`, the wake prompt and its failure path, and their integration tests.
5. **The person takes one back (US4)**: the end and remove-from-line methods and their buttons on the page, and the "ended by the person" notice on the agent's next lease call. There is no take.
6. **Known resources (US6)**: `ResourceCatalog` and listing, and found resources appear on the page when free.
7. **Proof**: both builds, full suite, and the quickstart run-app pass with two real agents and screenshots.

## Risks

- **Runtime timeouts are not ours.** 45 s is chosen against Codex's 60 s default MCP tool
  timeout. A runtime with a shorter one would see the call fail. The agent keeps its place in
  line anyway, because nothing in the book depends on the call. The live pass records what each
  runtime does (quickstart §3).
- **A woken agent's prompt is an app prompt.** `PromptOrigin.app` today means only "the one
  question after a silent ending". Every place that branches on `.app` has to be checked so a
  lease prompt doesn't count as that question (research R6).
- **Agreement, not a lock.** An agent that ignores its briefing still collides. The feature is
  only as good as the briefing paragraph and the tool descriptions, so both are written to be
  quoted back to the person.
- **Discovery costs a subprocess.** `xcrun simctl list` takes about a second when cold. It is
  cached for a minute and never run on the actor. Without Xcode the list has no simulators and
  says nothing about it.
- **A deadlock between two agents lasts until a lease expires.** This is accepted (spec, Edge
  Cases). The page shows both waits so the person can break it.

## Complexity Tracking

None. There are no constitution gates. The only thing beyond the spec's words is the choice of
three tools rather than six (research R2), which is less, not more.
