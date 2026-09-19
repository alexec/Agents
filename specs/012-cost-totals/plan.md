# Implementation Plan: Cost Totals

**Branch**: `012-cost-totals` | **Date**: 2026-09-19 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/012-cost-totals/spec.md`

## Summary

Both totals already exist in memory. They have simply never been added up.

`AgentStore.loadAll()` is documented as "every agent there has ever been", and the daemon
keeps all of them in `DaemonCore.agents` for the life of the process. Each carries
`costToDate: [String: Decimal]`, banked per currency in `finishTurn`. The client holds the
same complete set — which is why `ProjectAgentsView` pages its archived agents in the view
"because this window already holds every one of them". So neither total needs a store, a
migration, a background sweep, or a number written down anywhere. Both are sums.

Two facts about the existing code decide the whole shape of the work.

**The first: `allProjects()` already groups every agent by folder.** Its opening lines are
`Dictionary(grouping: agents.values) { Project.standardize($0.cwd) }`, and it already walks
each folder's agents to build `counts`. The project total is one more accumulation in that
same loop, and it lands on `ProjectSummary`, which is the type every client already has for
every project.

**The second: `changed(_:)` already broadcasts the project after the agent.** It ends with
`projectChanged(forAgentIn: agent.cwd)`, and `finishTurn` calls `changed(agent)` on the line
immediately after banking the cost. So the moment money is spent, a recomputed
`ProjectSummary` is on its way to every window. Putting the total on that type gives FR-005
and FR-016 — both totals following spend as it arrives — with **no new notification, no new
command, and no new plumbing at all.**

What follows from those two:

- **There is no grand-total command.** The grand total is a pure function over
  `[ProjectSummary]`, in `AgentsKitCore`, which the window already holds in full. It is
  exhaustible by a unit test with no daemon, and the phone could show it tomorrow without
  the daemon learning anything new.
- **There is no unassigned spend.** `allProjects()` is "the union of every folder an agent
  has run in and every folder we kept a record for" — so an agent in a folder nobody added
  *creates* a project. FR-012's category cannot be populated, which means FR-011's invariant
  (the shares add up to the grand total, exactly) holds by construction. It is still worth a
  test, because it is an invariant the next feature could quietly break. See
  [research.md §3](./research.md).
- **"Unmeasured" is a rule, not a field.** An agent that has finished a turn and has no cost
  on record is one the runtime would not price: `lastTurnUsage != nil && costToDate.isEmpty`.
  `finishTurn` sets `lastTurnUsage` whenever the runtime reports usage at all, whether or not
  a price came with it, so the two conditions together separate "would not say" from "has not
  run yet". A pure rule on `Agent`, following `Usage.isCloseToFull`.
- **Nothing is written to disk.** FR-020 — the totals survive a restart — is satisfied by the
  agent records that already persist. Every total is recomputed from them on load.

The one genuinely new surface is a Spending window. It is a separate scene rather than a page
in the detail column, so FR-018 — leaving it returns you to what you were looking at — is true
by construction rather than by a flag that has to be unwound, and so it can sit open beside the
work while the figures move. The way in is the money line already at the foot of the projects
column, which becomes a button.

### What this collides with

`010-cost-limits` is specified and unimplemented, and the two features meet in exactly one
place: the `SessionSpend` footer in `ProjectListView.swift`. 010 replaces what it *says* (the
sitting's total becomes today's, with headroom); 012 makes it *do* something (open the
Spending window). The changes are to different lines of the same twenty-line view and do not
conflict in substance. Whichever ships second inherits the other's footer.

Nothing else overlaps. 010 owns limits, ceilings, refusals and the day; this feature sets no
limit, refuses nothing, and knows nothing about days. In particular this plan adds no store,
which is where 010 does most of its work.

### The seams

| Seam | What it already does | What this feature adds |
|---|---|---|
| `DaemonCore.allProjects(includeArchived:)` | Groups every agent by standardized `cwd`; counts them per group; names, stamps and sorts | Accumulates `costToDate` per currency and counts the unmeasured, in the same pass |
| `DaemonAPI.ProjectSummary` | `project`, `name`, `exists`, `lastActivityAt`, `counts` | `costToDate`, `unmeasuredAgents` |
| `DaemonCore.changed(_:)` → `projectChanged(forAgentIn:)` | Broadcasts the recomputed summary after every agent change | Nothing. The cost rides the notification that already fires |
| `DaemonCore.finishTurn(agentID:result:)` | Banks the turn's cost into `costToDate`, then calls `changed(agent)` | Nothing |
| `AgentsModel.projects` | Every project, live and archived, upserted on `project/changed` | Nothing. The new page reads it |
| `Cost.total(of:)` | Formats `[String: Decimal]` as one figure per currency, joined not added | Nothing. Every figure on both surfaces goes through it |
| `ProjectAgentsView.heading` | The project's name, and the folder-is-gone warning | A caption under the name: what this project has cost |
| `ProjectListView` → `SessionSpend` | Shows what this sitting cost, in a `safeAreaInset` at the foot | Becomes the way into the Spending window |
| `AgentsApp` | One `WindowGroup`, one command group | A second scene, and a menu item that opens it |

## Technical Context

**Language/Version**: Swift 6.2, strict concurrency. The one daemon-side change runs inside
the `DaemonCore` actor; everything else is `@MainActor` view code or pure functions.

**Primary Dependencies**: Foundation, SwiftUI. No new third-party dependency. `Decimal`
arithmetic and `FormatStyle.currency`, both already used by `Cost`.

**Storage**: **None added.** Every figure is a sum over `Agent.costToDate`, which is already
written whole and atomically on every change by `AgentStore.save`. No new file at the daemon
root, no new key on any record, nothing to migrate, and nothing for an older build to lose.

**Testing**: Swift Testing (`import Testing`) in `Packages/AgentsKit/Tests/AgentsKitTests`,
split `Unit` / `Integration` / `Live` / `Fake`. The grand total, the ordering, the
two-currency rule and the unmeasured rule are pure and unit-testable with no daemon at all.
That a spent cost reaches `ProjectSummary` and is broadcast is an integration test against a
temporary root with `FakeACPAgent.Script.usage`, which `Integration/TurnUsageTests.swift`
already drives end to end — the money in the tests is fake money and no CLI, credential or
network is involved.

**Target Platform**: macOS 27+ for the app and daemon. The new Core types build for iOS 27+
too, so the phone can adopt them later without the daemon changing; no Remote view is written
here.

**Project Type**: Desktop app plus a long-lived local daemon over a unix socket, with an iOS
remote reading the same model types.

**Performance Goals**: The accumulation is one extra pass over agents already being iterated
in `allProjects()` — tens of agents, one or two currencies. The grand total is a fold over
tens of project summaries, recomputed by SwiftUI when `projects` changes. SC-009 ("no visible
wait, with a year's worth of agents on record") needs no cache; the cost of the whole page is
far below the cost of decoding the records the daemon already decoded at startup.

**Constraints**: Nothing may convert or add across currencies, anywhere — which makes
*ordering* the interesting problem rather than the summing, and is settled in
[research.md §9](./research.md). The daemon stays the only place agents are grouped into
projects, so the window never looks at a `cwd` itself. The page is read-only and is reachable
only from the window, so nothing in it goes near `AppService` or the MCP surface: no tool an
agent can call gains a way to read or alter the totals.

**Scale/Scope**: Tens of projects, hundreds of agents, one currency in practice. Two source
files are new, four are edited, and one of the four is a two-field struct.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

`.specify/memory/constitution.md` is still the unmodified template — every principle is an
unfilled `[PRINCIPLE_N_NAME]` placeholder. There are no project principles to check against,
so the gate passes vacuously in both directions. Recorded rather than silently skipped, so a
later `/speckit-constitution` knows this feature was never measured against one.

In its place, the design was held to the conventions the codebase enforces in practice:

| Convention | How this feature holds to it |
|---|---|
| The daemon owns state; windows are views of it | The window never groups an agent into a project. `allProjects()` does it, as it already does for the counts, and the window renders what arrives. |
| A derived fact must not become stored state | Nothing is written. The project total, the grand total and "unmeasured" are all computed from `costToDate`, following `Usage.isCloseToFull` and `AgentGroup(for:)`. A stored total would be a second copy that could disagree with the records. |
| Cost is the runtime's own number | Nothing prices a token, estimates, converts a currency, or adds two. Every figure goes through `Cost.total(of:)`, which joins per currency rather than summing across them. |
| `AgentsKitCore` is what both platforms can hold | `Spending` and the `Agent.isUnmeasured` rule go in Core, so the phone gets them free. Only the two SwiftUI surfaces are Mac-only. |
| Show nothing rather than a zero | `Cost.total(of:)` already returns nil for an empty dictionary, which is how `ContextMeter` knows to draw no cost. FR-004 and FR-017 are that existing behaviour, reused. |
| The phone and the window say the same words | No new user-facing string is invented in a view. The formatting is `Cost.total(of:)` in Core, as it is for the meter today. |
| Nothing an agent can reach may change what the app reports | The page is read-only and lives in a window scene. No new daemon method exists at all, so there is nothing for the MCP surface to expose even by accident. |

**Post-design re-check**: passes, and more cleanly than before the design. No new package,
process, transport, store, daemon method, notification, agent state or persisted field. The
only change to an existing wire type is two additive fields on `ProjectSummary`, which is
computed fresh on every call and never stored, so there is no old copy of it anywhere to
migrate. The one change to existing behaviour is that the sidebar's money line becomes
clickable — an addition, not a replacement.

## Project Structure

### Documentation (this feature)

```text
specs/012-cost-totals/
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
│   └── Spending.swift                 # NEW: the grand total over [ProjectSummary], its
│                                      #   per-currency ordering, and Agent.isUnmeasured
└── Daemon/
    └── DaemonAPI.swift                # ProjectSummary + costToDate, + unmeasuredAgents

Packages/AgentsKit/Sources/AgentsKit/
└── Daemon/
    └── DaemonCore+Projects.swift      # fill the two new fields in allProjects()'s existing pass

App/Sources/
├── AgentsApp.swift                    # + the Spending window scene and the menu item
├── Spending/
│   └── SpendingView.swift             # NEW: the grand total, and every project's share
├── Projects/
│   ├── ProjectAgentsView.swift        # the project's total, under its name
│   └── ProjectListView.swift          # the money line becomes the way in

Packages/AgentsKit/Tests/AgentsKitTests/
├── Unit/
│   └── SpendingTests.swift            # NEW: the grand total, the shares-add-up invariant,
│                                      #   ordering, two currencies, unmeasured, nothing spent
└── Integration/
    └── ProjectsTests.swift            # extended: a turn's cost reaches the summary and is
                                       #   broadcast; archiving an agent or a project does not
                                       #   move it
```

**Structure Decision**: Two new source files and one new folder. `Spending.swift` is separate
from `Usage.swift` because they answer different questions — `Usage` and `Cost` are what a
runtime reported about one agent, `Spending` is what a reader is owed about all of them — and
because every rule in it is pure, which is what makes `Unit/SpendingTests.swift` able to
exhaust the feature without a daemon. Everything else lands in the file that already owns the
concern: the accumulation inside the loop in `DaemonCore+Projects.swift` that already counts
agents per folder, the caption beside the folder-is-gone warning in `ProjectAgentsView`, the
button on the money line that is already in `ProjectListView`. No test file is created for the
daemon side because `Integration/ProjectsTests.swift` already exercises `allProjects()`.

## Complexity Tracking

> No Constitution Check violations. Section intentionally empty.
