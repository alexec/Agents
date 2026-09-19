# Phase 1 Data Model: Cost Totals

Nothing here is stored. Every type below is derived on demand from `Agent.costToDate`, which
already exists, is already persisted by `AgentStore.save`, and is not modified by this
feature. There is no migration, no new file at the daemon root, and no new key on any record —
so an older build reading a record written by this one loses nothing, because this one writes
nothing new.

## Existing types this reads

### `Agent` (unchanged)

| Field | Type | Read for |
|---|---|---|
| `cwd` | `URL` | Which project the agent's spend belongs to, via `Project.standardize` |
| `costToDate` | `[String: Decimal]` | Every figure in this feature. Currency code → amount, banked per turn in `finishTurn` |
| `lastTurnUsage` | `TurnUsage?` | Telling "has not run" apart from "the runtime would not say a price" |

No field is added to `Agent`, and none is written.

### `Cost` (unchanged)

`Cost.total(of:)` formats a `[String: Decimal]` as one figure per currency in currency order,
joined with `·`, returning **nil when nothing has been spent**. That nil is how `ContextMeter`
already knows to draw no cost rather than a zero, and it is what satisfies FR-004 and FR-017
here without a new rule.

## Changed type

### `DaemonAPI.ProjectSummary`

Two additive fields. Computed fresh in `allProjects()` on every call and never stored, so
there is no persisted copy anywhere to migrate.

| Field | Type | Meaning | Rule |
|---|---|---|---|
| `costToDate` | `[String: Decimal]` | What every agent in this folder has spent, over its whole life, per currency | Sum of `costToDate` across all agents whose standardized `cwd` is this folder — **including ended and archived agents**, which is automatic because `allProjects()` groups `agents.values` and the daemon holds every agent there has ever been. Empty when nothing has been spent. |
| `unmeasuredAgents` | `Int` | How many agents here ran but were never priced | Count of agents in the folder where `isUnmeasured` is true. Zero in the ordinary case. |

Satisfies FR-001, FR-002 (whole-life, including ended and archived), FR-006, FR-013 and FR-014
— the last two because `allProjects()` already includes archived projects and already stamps
`exists` for a folder that has gone, and neither of those filters the agents.

## New types

### `Agent.isUnmeasured` — a rule, not a field

```
lastTurnUsage != nil && costToDate.isEmpty
```

A pure computed property in `Spending.swift`, following the precedent of
`Usage.isCloseToFull` and `Agent.group`: a derived fact that must not become stored state.

Three cases it separates, all of which look like "no money" from outside:

| Case | `lastTurnUsage` | `costToDate` | `isUnmeasured` |
|---|---|---|---|
| Started, never finished a turn | nil | empty | false — nothing has happened yet |
| Ran, runtime reported a price | set | non-empty | false — measured |
| Ran, runtime reported no price | set | empty | **true** — unmeasurable, not free |

Correct retroactively for every record already on disk, because `finishTurn` has always set
`lastTurnUsage` whenever the runtime reported usage and has only ever added to `costToDate`
when a price came with it.

### `Spending` — the grand total, derived from the summaries

Built from `[DaemonAPI.ProjectSummary]`, in `AgentsKitCore` so both platforms can hold it, and
pure so a unit test can exhaust it with no daemon.

| Member | Type | Meaning |
|---|---|---|
| `grandTotal` | `[String: Decimal]` | Every project's `costToDate`, added per currency. Empty when nothing has ever been spent. |
| `currencies` | `[String]` | Currency codes that have any spend, in code order. Empty, one, or rarely more. |
| `shares(in:)` | `(String) -> [Share]` | Every project with spend in that currency, largest first. |
| `unmeasuredAgents` | `Int` | Summed across every project. Non-zero means every figure here is a floor. |
| `isEmpty` | `Bool` | Nothing has ever been spent, in any currency — the page says so in a sentence. |

**`Share`**: one project's line on the page — its `folder`, its `name` and `isArchived` (both
already on `ProjectSummary`), and its `amount` in the currency of the section it is in.

Rules:

- **Per currency, never across.** `grandTotal` is a dictionary, not a number. Nothing in this
  type converts, and nothing adds two currencies. (FR-003, FR-021, SC-006)
- **One section per currency, ordered within it.** `shares(in:)` has a total order because it
  has one unit. With a single currency the page is one list; see
  [research.md §9](./research.md). (FR-009)
- **Every project with spend is listed, archived or not, folder present or not.** Nothing
  filters. (FR-013, FR-014)
- **A project that has spent nothing is not listed**, and contributes nothing to
  `grandTotal`. (FR-004)

## The invariant

> For every currency, the `shares` listed sum exactly to `grandTotal` for that currency.

This is FR-011, and it holds **by construction** rather than by care: `grandTotal` is built by
folding the same summaries `shares(in:)` filters, and `allProjects()` is the union of every
folder an agent has run in with every kept record — so no agent's spend can fall outside some
project. FR-012's "spend belonging to no project" is therefore a category that cannot be
populated, and no such row is built. See [research.md §3](./research.md).

It is nonetheless the first test written, because it is exactly the invariant a later feature
would break by filtering `allProjects()` before totalling, and it would break silently.

## What is deliberately not modelled

| Not here | Why |
|---|---|
| A stored or cached total | Derivable from records that already persist. A second copy could disagree with them, and would need invalidating on every change, archive and delete. FR-020 is satisfied by the records themselves. ([research.md §10](./research.md)) |
| A time dimension — day, month, range | All-time is what "grand total" means, and a day is *not* derivable from the records, which is why 010 needs `spend.json` and this feature needs nothing. |
| A per-agent breakdown on the page | Already on the project page and in each chat's meter. |
| Any limit, ceiling or headroom | 010's subject. This feature reports and refuses nothing. |
| A per-runtime or per-model split | Not asked for, and `costToDate` is not broken down that way on the record. |
