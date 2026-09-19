# Contract: daemon API additions

The daemon speaks JSON-RPC over a unix socket; `DaemonAPI` in `AgentsKitCore` is the whole
vocabulary, shared verbatim by the Mac app and the iOS Remote.

**This feature adds no method, no notification and no failure code.** It adds two fields to
one existing response type. That is the whole wire change, and it is the strongest evidence
that the design is in the grain of the codebase rather than laid across it.

There is consequently nothing here for `AppService` or the MCP tool surface to expose, by
design or by accident: no agent gains a way to read the totals, and none could alter them,
because there is nothing to call. (FR-019, SC-010)

---

## Changed type — `DaemonAPI.ProjectSummary`

Carried by `projects/list` (as an array) and by the `project/changed` notification (as one).
Both are existing; neither changes shape otherwise.

```swift
public struct ProjectSummary: Codable, Hashable, Sendable, Identifiable {
    public var project: Project
    public var name: String
    public var exists: Bool
    public var lastActivityAt: Date
    public var counts: [AgentGroup: Int]

    /// What every agent in this folder has spent over its whole life, per currency.
    /// Empty when nothing has been spent, which is how a view knows to show no figure
    /// rather than a zero.
    public var costToDate: [String: Decimal]          // NEW

    /// How many agents here finished a turn the runtime would not price. Zero in the
    /// ordinary case; non-zero means `costToDate` is a floor rather than the whole.
    public var unmeasuredAgents: Int                  // NEW
}
```

**Precedent**: `counts`. It is computed in the same loop, over the same grouping, from agents
the daemon holds in full, and it is likewise never stored — a summary is rebuilt from
`agents.values` on every call, so there is no persisted copy of the old shape anywhere to
migrate.

**Guarantees**:

- **Whole-life, and nothing is excluded.** The sum runs over every agent whose standardized
  `cwd` is this folder, whatever its state — running, finished, stopped, or archived. The
  daemon holds every agent there has ever been (`AgentStore.loadAll`), so archiving an agent
  changes no total. (FR-002, SC-005)
- **Per currency, never across.** A dictionary keyed by currency code, exactly as
  `Agent.costToDate` is. Nothing here converts or adds two currencies. (FR-003, FR-021)
- **Empty means nothing spent.** Not a zero, and not absent-therefore-unknown.
  `Cost.total(of:)` returns nil for it, which is the existing signal to draw nothing.
  (FR-004)
- **Archived projects and missing folders carry their spend.** `allProjects(includeArchived:)`
  already includes archived projects, and `exists` already reports a folder that has gone;
  neither filters the agents, so neither loses the money. (FR-013, FR-014)
- **Every agent's spend is inside exactly one summary.** The project list is the union of
  every folder an agent has run in with every kept record, so no agent's folder is outside it
  and no two summaries can claim the same agent. This is what makes the grand total's shares
  add up. (FR-011, FR-012)

## Timing: when a window learns

No new event. The existing chain already fires at the right moment:

```
finishTurn(agentID:result:)
    agent.costToDate[currency] += cost.amount     // the money is banked
    changed(agent)
        agents[agent.id] = agent                  // in memory
        saveQuietly(agent)                        // to the record
        broadcast(agent/changed, agent)           // the agent's own figure
        projectChanged(forAgentIn: agent.cwd)
            broadcast(project/changed, summary)   // ← the project's total, recomputed
```

**Guarantees this inherits**:

- The record is written before the windows are told, so a daemon killed mid-broadcast comes
  back having counted the money.
- The project is broadcast *after* the agent, which is the existing ordering rule — a window
  that renders both sees the agent's own figure and its project's total agree.
- One `project/changed` per agent change, not one per currency. A turn that spends in two
  currencies is still one notification carrying both.
- A turn the runtime did not price still produces `agent/changed` and `project/changed` (the
  agent's `lastTurnUsage` changed), which is precisely what makes `unmeasuredAgents` go up
  live rather than at the next reconnect.

## Client-side: no new call

`AgentsModel` already seeds `projects` from `projects/list` on connect and maintains it
through `upsert(_:)` on `project/changed`. The Spending window is a pure function of
`AgentsModel.projects` — see `Spending` in [data-model.md](../data-model.md) — so it needs no
fetch of its own, cannot be stale relative to the sidebar, and cannot show a grand total that
disagrees with the shares beneath it: both are folded from the same array in the same render.

## Compatibility

| Direction | Effect |
|---|---|
| New app, new daemon | The intended case. They ship in one bundle. |
| New app, old daemon | `costToDate` and `unmeasuredAgents` decode as absent. Both fields default (empty, zero), so the project page shows no figure and the Spending window says nothing has been spent. Degrades to silence, never to a wrong number. |
| Old app, new daemon | Extra JSON keys, ignored by the decoder. Unchanged behaviour. |
| Records on disk | Untouched. This feature writes nothing and reads only fields that already exist. |
