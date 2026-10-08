# Implementation Plan: MCP integrations, a proof of concept (CI watcher)

**Branch**: `agents/spec-383-mcp-integrations` | **Date**: 2026-10-06 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `specs/383-mcp-integrations/spec.md` (issue #383).

Planned from source at `d1822ebe` (origin/main), without building or running anything. The
decisions are in [research.md](research.md), the records in [data-model.md](data-model.md), the
interfaces in [contracts/](contracts/), and the walk in [quickstart.md](quickstart.md).

## Summary

The daemon already has everything an event trigger needs at the far end. Events are raised
through one call (`DaemonCore.raise`), which writes the event to `events.jsonl` and then fires
matching workflows. Workflows already parse dotted event names with filters, and already apply
`hosts:`, off, archived, cooldown and approval. The daemon also has its own MCP client
(`MCPClient`, http and stdio) from #191.

So this feature is **one new event source** feeding that call, plus a server of our own:

1. **A trigger kind** for a server's event, named `noun.verbed` like every other event
   (`checks.failed`), with no prefix. A dotted name that isn't in the app's catalogue, and
   whose noun isn't one of the app's subjects, parses as a new
   `WorkflowTrigger.serverEvent(MCPEventTrigger)`. It hears **every** project server that
   offers the name, or only those `server:` names (one or a list), with one subscription per
   server. Its other keys are
   the *subscription's arguments*, sent to the server, not details matched locally. They are
   checked against the event's `inputSchema` once the server has been asked.
2. **An event source** `DaemonCore+MCPEvents.swift`. From the workflows' triggers, it works out
   a set of **subscriptions** (server, event, arguments) per project. For each one it holds a
   poll loop on its own MCP connection, separate from the views pool, which may be stdio. Each
   new event is raised under its own name (`checks.failed`) with `server` and `subscription`
   details, which only that subscription's triggers match.
3. **Exactly once**, by a write-ahead record in `<root>/mcp-events.json`. That record holds the
   cursor, the ids recently seen, and the ids "being delivered". `events.jsonl` is the commit
   point. See [research R4](research.md#r4-exactly-once-across-a-restart).
4. **Status** on the workflow's page. `WorkflowSummary` gains `mcpTriggers: [MCPTriggerStatus]`,
   which is drawn by `Shared/UI` (Mac and Remote) and `Web/src`.
5. **The CI watcher**: a small TypeScript MCP server in `Integrations/ci-watcher/`, run on Node
   with no build step. It serves http on `127.0.0.1:8795`, uses GitHub through `gh`, and has a
   `ui://ci/board` view. The project gets `.agents/mcp.json` and a workflow that is turned off.

## Technical Context

**Language/Version**: Swift 6 (AgentsKit, daemon, Mac, Remote); TypeScript (Web, CI watcher on Node 26, run with type stripping, no build step).

**Primary Dependencies**: The existing `MCPClient` (JSON-RPC over http + SSE, and stdio); the `gh` CLI for the CI watcher; Node's built-in `http`. There are no new packages.

**Storage**: A new `<root>/mcp-events.json` (subscriptions: cursor, seen ids, in-flight ids, status). Events go in the existing `events.jsonl`. Workflows stay in `.agents/workflows/*.md`.

**Testing**: Swift Testing in `Packages/AgentsKit/Tests`. There are unit tests for the trigger parse, the subscription set, the schema check and the record, and integration tests with an events stand-in (in the style of `ViewsServerStandIn`) and a fake clock. The CI watcher gets `node --test`, with `gh` faked.

**Target Platform**: The macOS daemon, and the Linux `agentsd` (it is the same AgentsKit code, so server hosts get it too). The CI watcher runs on macOS for this proof of concept.

**Project Type**: The daemon and three clients (Mac, Remote, web), plus one standalone MCP server.

**Performance Goals**: An event starts a run within one poll interval plus 5 s. Polling uses no CPU while idle. Each subscription costs one request per interval.

**Constraints**:
- Each subscription is asked at most every 10 s and at least every 5 min (FR-004).
- An event's details are cut at 256 KB.
- At most 8 event connections per host. One slow server never delays another (one task per subscription).
- Events are untrusted data (FR-008).
- The daemon never logs URLs, headers or secrets (as for `mcp views:` lines).

**Scale/Scope**: Tens of subscriptions per host, a handful of servers, and events per minute rather than per second.

## Constitution Check

*Gate: must pass before Phase 0 research. Rechecked after Phase 1 design.*

| Principle | How this plan meets it | Pass |
|---|---|---|
| I. Spec-led | Spec #383 has acceptance scenarios. This plan, then tasks, then the build. | ✅ |
| II. Capability-driven | Events are used only when the server declares the `events` capability and lists the event with `poll` in its `delivery`. Push and webhook-only events are refused, the refusal is logged, and the page says why (FR-013). Nothing depends on which server it is. | ✅ |
| III. Scoped access and user control | Servers come from the same approved sources as sessions (an unapproved project `mcp.json` or plugin is refused). A workflow runs under its own `permission-mode`. Event details are data, never instructions. The CI watcher's writing tools (`rerun_failed`, `comment_on_pr`) are used through the agent's normal permission flow. | ✅ |
| IV. Inspectable | Every event and every run it started is in `events.jsonl`, the Events page and `daemon.log`. Each trigger's state is on the workflow's page. Missed events are recorded, never hidden. | ✅ |
| V. Docs and quality | The three docs pages in the spec are part of the tasks. Warnings are errors as configured. `generated.ts` is regenerated from its source, not edited. | ✅ |
| Constraints | The daemon is the only writer of `mcp-events.json`. No user-home config is read beyond what sessions already read (`~/.agents/mcp.json`, `secrets.env`). | ✅ |

Rechecked after Phase 1: no change. No complexity needs justifying.

## Project Structure

### Documentation (this feature)

```text
specs/383-mcp-integrations/
├── spec.md
├── plan.md              # this file
├── research.md          # Phase 0: decisions R1–R10
├── data-model.md        # Phase 1: records and states
├── quickstart.md        # Phase 1: the walk that proves it
├── contracts/
│   ├── workflow-trigger.md     # a server's `noun.verbed` event in front matter
│   ├── mcp-events-client.md    # what the daemon sends and accepts (the draft, poll mode)
│   ├── ci-watcher-server.md    # the CI watcher's events, tools and view
│   └── wire-status.md          # MCPTriggerStatus on WorkflowSummary
├── checklists/requirements.md
└── tasks.md             # Phase 2 (/speckit-tasks)
```

### Source Code (repository root)

```text
Packages/AgentsKit/Sources/
├── AgentsKitCore/Model/
│   ├── WorkflowTrigger.swift          # + case serverEvent(MCPEventTrigger), name, matches
│   ├── MCPEventTrigger.swift          # new: event, servers?, arguments, subscriptionKey(server:)
│   ├── MCPTriggerStatus.swift         # new: wire status for the page
│   ├── Workflow.swift                 # WorkflowSummary + mcpTriggers
│   └── EventCatalogue.swift           # + reservedNouns (the app's subjects), isEventName (noun.verbed)
├── AgentsKit/Workflows/WorkflowFile.swift   # unknown noun.verbed names → serverEvent, not unrecognised
├── AgentsKit/MCP/
│   ├── MCPClient.swift                # + eventsCapability, listEvents, pollEvents
│   ├── MCPEventsWire.swift            # new: EventDefinition, PollResult, errors
│   └── JSONSchemaSubset.swift         # new: type/required/properties/enum/additionalProperties
├── AgentsKit/Store/MCPEventStore.swift      # new: <root>/mcp-events.json
└── AgentsKit/Daemon/
    ├── DaemonCore+MCPEvents.swift     # new: subscription set, poll loops, raise, status
    ├── DaemonCore+ThirdPartyViews.swift  # server resolution split out, stdio allowed for events
    └── Daemon.swift                   # start the source after the workflow ticker

Packages/AgentsKit/Tests/AgentsKitTests/
├── Support/EventsServerStandIn.swift  # new: events/list + events/poll with a scripted feed
├── Unit/MCPEventTriggerTests.swift, JSONSchemaSubsetTests.swift, MCPEventStoreTests.swift
└── Integration/MCPEventWorkflowTests.swift   # fire, dedupe, restart, start-from-now, errors

Shared/UI/WorkflowStatus.swift          # the trigger lines (Mac + Remote)
App/Sources/Projects/WorkflowPage.swift  # placement only if needed
Remote/Sources/Projects/WorkflowPage.swift
Web/src/model/workflows.ts, Web/src/views/WorkflowPage.tsx, Web/src/protocol/generated.ts (regenerated)

Integrations/ci-watcher/                # new
├── server.ts        # http JSON-RPC: initialize, tools/*, resources/*, events/list, events/poll
├── github.ts        # gh api calls, mapping runs and PRs to events
├── board.html       # ui://ci/board
├── server.test.ts   # node --test, gh faked
├── fixtures/ci.json # CI_WATCHER_FAKE: runs and PRs from a file, for walks without GitHub
├── run.sh           # start/stop as a LaunchAgent (com.agents.ci-watcher)
└── README.md

.agents/mcp.json                        # new: { "ci": { "type": "http", "url": "http://127.0.0.1:8795/mcp" } }
.agents/workflows/fix-failed-checks.md  # new, enabled: false

docs/reference/workflows.md, docs/reference/events.md,
docs/how-to/start-a-workflow-from-an-mcp-event.md (new)
specs/071-web-remote/walks/parity.md    # workflow page row: MCP trigger status
```

**Structure decision**: The daemon work stays in AgentsKit, beside the event sources it joins
(`DaemonCore+EventSources.swift`, `+Disk.swift`). The CI watcher is a separate top-level
`Integrations/` folder, because it is a third-party-shaped server and must not link
AgentsKit. That is the point of the proof of concept: no integration-specific code in the app
(SC-005).

## Phases for the build

1. **Trigger and record**: no network. `MCPEventTrigger`, its parse, `subscriptionKey(server:)`, the
   store and the schema check, with unit tests. It's useful on its own, because a file using it
   lists as "waiting for the server" rather than unrecognised.
2. **Client and source**: `listEvents` and `pollEvents` on `MCPClient`, the subscription set,
   the poll loops, raising, and exactly once. Integration tests with the stand-in: US1 and US2.
3. **Status on the page**: `MCPTriggerStatus` on the wire, then Mac and Remote (`Shared/UI`),
   then web. US5.
4. **The CI watcher**: the server, its tests, `.agents/mcp.json` and the workflow (turned
   off). US3 and US4.
5. **Docs, parity row, walk**: the quickstart on a scratch root (run-app), then the real repo
   with Alex's go-ahead.

Phases 1–3 and phase 4 touch disjoint files and can be two lanes. Phase 4 needs only the
[server contract](contracts/ci-watcher-server.md).

## Risks

- **The draft moves.** The method and field names are kept in one file
  (`MCPEventsWire.swift`) and the CI watcher. Since we are both client and server for the proof
  of concept, a change is one edit on each side.
- **Protocol version.** The draft is written against MCP 2.0. The daemon negotiates
  `2025-06-18` today. See [R2](research.md#r2-protocol-version-and-capability): accept the
  `events` capability under either version, and offer the newer one first only on event
  connections.
- **A server that doesn't start from now.** If it answers a `cursor: null` poll with a backlog,
  the first poll's events are recorded as seen and **not raised** (R5).
- **`gh` rate limits.** The CI watcher asks GitHub only when it is polled, with conditional
  requests (ETag), and keeps 2 requests per poll per repo.

## Complexity Tracking

None. The plan fits the constitution as it stands.
