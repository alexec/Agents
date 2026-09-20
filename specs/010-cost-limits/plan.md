# Implementation Plan: Cost Limits

**Branch**: `010-cost-limits` | **Date**: 2026-09-19 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/010-cost-limits/spec.md`

## Summary

The app already knows what everything costs and does nothing with it. `finishTurn` in
`DaemonCore+Commands.swift` is the one place a cost is ever banked — five lines that add the
runtime's figure into `agent.costToDate`, per currency, and that is the whole of the app's
relationship with money today. This feature gives that number two consequences.

The shape of the work is set by one fact about the codebase and one answer from the spec, and they
happen to agree.

The fact: **`sendNextQueued` is the single funnel every turn begins through.** A person typing, a
queued prompt draining behind a finished turn, a workflow firing, and 011's restart pick-up all
arrive there. It already has the exact behaviour a limit needs — when the runtime will not start,
"the words stay exactly where they were", on the queue, for later. One guard in that function is
the whole daily limit for every agent that already exists; `start()` gets the same guard for
agents that do not exist yet.

The answer: **the turn is the unit, and a limit never cuts a turn short.** That maps onto
`finishTurn` exactly. Nothing needs to interrupt a running turn, reach into `turnTasks`, or reason
about a half-applied edit. The limit is checked immediately after the cost is banked, because
banking is what makes the limit true.

Everything else follows from refusing to store what can be computed:

- **"At its limit" is not a state.** It is `costToDate` compared against a ceiling — a pure
  function on `Agent` in Core, exhaustible by a unit test and readable by both platforms. No
  `AgentState` case, no transition-table change. It also stays correct when the reader *lowers* the
  limit later, which a stored flag would not.
- **"The day's limit is reached" is one global fact, not a per-agent one.** Every agent is affected
  identically, so there is one number to compare and one thing to broadcast. No agent is marked.
- **"Holding" is an undrained queue.** An agent held by the day's limit is an ordinary settled agent
  whose words are still on its queue. When the day rolls over they drain. The mechanism already
  exists and is already tested.

Two things genuinely have to be stored: the reader's limits, and what has been spent today in a
form that survives a restart. Both are small JSON files at the daemon root, beside `projects.json`,
`workflows.json` and `option-cache.json`, which are exactly this pattern already.

The one piece of real new surface is a Settings window. The app has none — no `Settings` scene, no
preferences of any kind — so the feature has to build the first one.

### What this inherits

`011-restart-running-chats` already wrote down the half of the contract that meets it: picking a
chat back up *is* an ordinary prompt, so it passes through `sendNextQueued` and is gated by the
daily limit for free, and its existing failure path writes the refusal into the chat and leaves the
words queued. Nothing in this plan needs to know about recovery, and nothing in recovery needs to
know about limits.

### The seams

| Seam | What it already does | What this feature adds |
|---|---|---|
| `DaemonCore.finishTurn(agentID:result:)` | Banks the turn's cost into `costToDate`, per currency; moves the agent on `turnEnded`; drains the queue | Banks into the day's ledger too, then decides whether this turn was the one that crossed a limit |
| `DaemonCore.sendNextQueued(to:)` | The one funnel into `beginTurn`; leaves words on the queue when a turn cannot start | Refuses, leaving the words where they are, when either limit is reached |
| `DaemonCore.start(_:)` | Makes a session, then an agent | Refuses before making a session when the day's limit is reached |
| `DaemonCore.drainQueue(after:)` | Sends what is waiting once a turn ends of its own accord | Says nothing and drains nothing while a limit holds |
| `Workflow.refusalIfBlocked(…)` | A pure function taking every blocking condition as a parameter | Takes one more: the day's limit is reached |
| `DaemonCore.tickWorkflows(now:)` | The existing 15-second heartbeat that notices schedules and missed fires | Notices the day rolling over, and drains what was holding |
| `StoreLocations` | Names `projects.json`, `workflows.json`, `option-cache.json` | Names `limits.json` and `spend.json` |
| `EndedReason.summary` | One switch, in Core, so "the phone and the window have to say the same words" | One more case, and both platforms say it at once |
| `ContextMeter` + `ProjectListView` | Show an agent's total and the sitting's total | Show headroom, and today rather than the sitting |

## Technical Context

**Language/Version**: Swift 6.2, strict concurrency. `DaemonCore` is an actor and every check here
runs inside it.

**Primary Dependencies**: Foundation, SwiftUI (app and Remote). No new third-party dependency.
`Calendar`/`TimeZone` from Foundation for the day boundary.

**Storage**: Two new small JSON files at the daemon root — `limits.json` (the reader's two limits)
and `spend.json` (what was spent on each of the last few local days, per currency) — written
through stores shaped like the existing `ProjectStore` and `OptionCache`. One new optional field on
the per-agent record. `Agent` already round-trips unknown keys, so an older build reading a record
written by this one does not delete a ceiling the reader set.

**Testing**: Swift Testing (`import Testing`) in `Packages/AgentsKit/Tests/AgentsKitTests`, split
`Unit` / `Integration` / `Live` / `Fake`. Cost already arrives end to end in
`Integration/TurnUsageTests.swift` through `FakeACPAgent.Script.usage`, against a temporary root
with no CLI, credential or network — every scenario in this feature is reachable that way, and the
money in the tests is fake money. The pure rules (is this agent at its limit, which local day is
this, what is left) are unit-testable with no daemon at all.

**Target Platform**: macOS 27+ for the app and daemon. `AgentsKitCore` also builds for iOS 27+, so
the models, the rules and the API types go there and every store and gate stays in `AgentsKit`.

**Project Type**: Desktop app plus a long-lived local daemon over a unix socket, with an iOS remote
reading the same model types.

**Performance Goals**: The limit check is arithmetic on a dictionary of at most a few currencies,
run once per turn end and once per turn start — immeasurable beside starting a runtime. Held work
resumes within one tick of the day rolling over (the existing 15-second heartbeat), well inside
SC-004's "next morning".

**Constraints**: The daemon is the only participant that is always running, so every gate must live
there — a limit enforced in the app would not bind an overnight workflow with no window open. The
day's total must be written before the windows are told, so a daemon killed mid-bank comes back
having counted the money rather than having forgotten it. Nothing may cut a turn short. Nothing an
agent or a workflow can reach may raise a limit, which means no limit call goes anywhere near
`AppService` or the MCP surface.

**Scale/Scope**: Tens of agents, a handful of currencies in practice (one), a ledger of a few days.
One daemon per machine, one set of limits per daemon root — so a branch build pointed at its own
root has its own limits and its own day, which is correct and worth knowing.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

`.specify/memory/constitution.md` is still the unmodified template — every principle is an unfilled
`[PRINCIPLE_N_NAME]` placeholder. There are no project principles to check against, so the gate
passes vacuously in both directions. It is recorded here rather than silently skipped so that a
later `/speckit-constitution` knows this feature was never measured against one.

In its place, the design was held to the conventions the codebase enforces in practice:

| Convention | How this feature holds to it |
|---|---|
| The daemon owns state; windows are views of it | Every limit is decided in `DaemonCore`. The Settings window sends two numbers and renders what comes back; it never decides whether something may run. |
| The record is written before the windows are told | The day's spend is banked to `spend.json` inside `finishTurn`, before `changed(agent)` and before the broadcast. |
| A derived or transient fact must not become a state | "At its limit" and "unmeasured" are computed from `costToDate` and the limits, following `Usage.isCloseToFull`. No `AgentState` case is added and `applying(_:endedReason:)` is untouched. |
| Cost is the runtime's own number | Nothing here prices a token, converts a currency, or adds two. A limit is a figure in one currency and is compared only against spend in that currency, which is `Cost.adding`'s existing rule turned into a gate. |
| Agents are told the truth, in sentences | A refused prompt and a limit reached are written into the transcript as `runtimeNote`s in the app's own bracketed voice, so the agent reading its own history knows why it stopped. |
| `AgentsKitCore` is what both platforms can hold | `CostLimits`, the `Agent` rules, the new `EndedReason` case and the API types are in Core. `LimitStore`, `SpendLedger` and every gate are in `AgentsKit`. |
| Colour means a person is needed | Approaching a limit reuses `Usage.closeToFull` rather than introducing a second threshold. The new workflow refusal is `needsAPerson: false`, because midnight resolves it without anybody. |
| Nothing is a special kind of start | The daily gate sits in the funnel every turn already uses, so a workflow's prompt, a person's prompt and a restart pick-up are all gated by the same four lines. |

**Post-design re-check**: passes. No new package, process, transport or agent state. Two files are
added alongside three that already follow the pattern; one optional field is added to a model that
already tolerates unknown keys; three methods and one notification are added beside their exact
precedents. The one change to existing behaviour is that the sidebar's "this sitting" figure
becomes "today" — a replacement rather than an addition, justified in
[research.md §7](./research.md).

## Project Structure

### Documentation (this feature)

```text
specs/010-cost-limits/
├── plan.md              # This file
├── research.md          # Phase 0 output
├── data-model.md        # Phase 1 output
├── quickstart.md        # Phase 1 output
├── contracts/
│   └── daemon-api.md    # Phase 1 output
├── checklists/
│   └── requirements.md  # From /speckit-specify
├── spec.md
└── tasks.md             # Phase 2 output (/speckit-tasks — NOT created here)
```

### Source Code (repository root)

```text
Packages/AgentsKit/Sources/AgentsKitCore/
├── Model/
│   ├── CostLimits.swift               # NEW: the two limits, the day stamp, headroom, the rules
│   ├── Agent.swift                    # + costCeiling, its coding, and the computed limit rules
│   ├── EndedReason.swift              # + costLimit, and its one line of summary
│   └── WorkflowOutcome.swift          # + dayLimitReached, its message, needsAPerson, isSameReason
├── Daemon/
│   └── DaemonAPI.swift                # + cost/state, cost/setLimits, agents/setCeiling,
│                                      #   cost/changed, dayLimitReached failure code
└── Client/
    └── AgentsModel.swift              # + costState, fed by the notification and seeded on connect

Packages/AgentsKit/Sources/AgentsKit/
├── Store/
│   ├── StoreLocations.swift           # + limits.json, spend.json
│   ├── LimitStore.swift               # NEW: the reader's limits, load and save
│   └── SpendLedger.swift              # NEW: per local day, per currency, pruned
└── Daemon/
    ├── DaemonCore.swift               # + the two lazy stores
    ├── DaemonCore+Commands.swift      # bank and check in finishTurn; gate sendNextQueued and start
    ├── DaemonCore+Dispatch.swift      # + the three methods
    └── DaemonCore+Workflows.swift     # the day-limit refusal; the rollover drain on the tick

App/Sources/
├── AgentsApp.swift                    # + the app's first Settings scene
├── Settings/
│   └── CostSettingsView.swift         # NEW: the two limits, and what they have stopped
├── Chat/ContextMeter.swift            # headroom beside the cost it already shows
├── AgentList/AgentRow.swift           # "Reached its limit", and holding for the day
├── Projects/ProjectListView.swift     # today and its headroom, in place of the sitting's total
└── AppModel.swift                     # spentBeforeWeWatched retires

Remote/Sources/
├── Chat/RemoteChatView.swift          # the same words, from the same switch
└── Projects/AgentCard.swift

Packages/AgentsKit/Tests/AgentsKitTests/
├── Unit/
│   ├── CostLimitTests.swift           # NEW: the pure rules, exhausted without a daemon
│   └── SpendLedgerTests.swift         # NEW: day stamps, rollover, pruning, two currencies
├── Integration/
│   ├── TurnUsageTests.swift           # extended: the per-agent limit, end to end
│   ├── CostLimitTests.swift           # NEW: the daily gate, holding, the rollover drain
│   └── WorkflowRefusalTests.swift     # + a fire refused by the day's limit
```

**Structure Decision**: Three new source files and one new folder. Everything else lands in a file
that already owns the concern — the gates beside the queue logic they guard in
`DaemonCore+Commands.swift`, the stores beside `ProjectStore` and `OptionCache`, the refusal beside
the ten that already exist in `WorkflowOutcome.swift`, the row text beside the existing state switch
in `AgentRow.swift` and its twin in `AgentCard.swift`. `CostLimits.swift` is separate from
`Usage.swift` because they answer different questions — `Usage` is what a runtime reported,
`CostLimits` is what the reader will allow — and only the second is ever written by a person.

## Complexity Tracking

> No Constitution Check violations. Section intentionally empty.
