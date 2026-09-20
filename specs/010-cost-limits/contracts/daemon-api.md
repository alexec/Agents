# Contract: daemon API additions

The daemon speaks JSON-RPC over a unix socket; `DaemonAPI` in `AgentsKitCore` is the whole
vocabulary, shared verbatim by the Mac app and the iOS Remote. This feature adds three methods, one
notification and one failure code, all modelled on existing pairs.

Every one of them is a **window call**. None is advertised to `AppService`, added to the MCP tool
surface, or named in any standing instruction given to an agent. That is FR-007, and it is 008's
rule about the chain-depth limit applied to money: a runaway that can raise its own limit is not
stopped.

---

## Notification — `cost/changed`

Sent whenever the reader changes a limit, whenever a turn's cost is banked, and whenever the local
day rolls over.

```swift
public struct CostState: Codable, Sendable {
    public let limits: CostLimits
    /// What this local day has cost, per currency. Empty until something is spent.
    public let today: [String: Decimal]
    /// Which local day `today` is about, `yyyy-MM-dd`.
    public let day: String
}
```

**Method name**: `DaemonAPI.Notification.costChanged = "cost/changed"`

**Precedent**: `project/changed` and `workflow/changed` — the whole resolved fact rather than a
delta, so "two windows cannot then disagree, and one that missed a notification is put right by the
next rather than drifting."

**Guarantees**:

- Sent *after* `spend.json` is written, never before. A window is never told about money the daemon
  has not yet recorded.
- Sent once per turn that reported a cost, alongside the existing `agent/changed` for that agent —
  not once per currency and not once per agent.
- `day` changing is the only signal a window needs that the day rolled over. A window must not
  consult its own clock; it may be in a different time zone from the daemon's idea of local, and the
  daemon's is the one the limit uses.
- A runtime that reported no cost produces no `cost/changed`. Silence means nothing was counted, not
  that nothing was spent — see `costIsUnmeasured`.
- Not sent for a limit *check* that refused something. The refusal is carried by the call that was
  refused, and by the transcript.

---

## Method — `cost/state`

Seeds a window on connect.

**Request**: none. **Response**: `CostState`.

**Precedent**: `projects/list` before `project/changed`; `agents/resuming` before `agent/resuming`.
Every broadcast fact in this app has a call that fetches it, so a window that connects mid-day is
not left waiting for the next turn to learn what it has already spent.

---

## Method — `cost/setLimits`

The reader setting or clearing either limit. The only way either changes.

```swift
public struct SetLimitsRequest: Codable, Sendable {
    /// Absent means "leave it as it is". Present-and-null means "no limit".
    public let perAgent: Cost??
    public let daily: Cost??
}
```

**Response**: `CostState`, so the caller sees the result rather than assuming it.

**Guarantees**:

- Raising the daily limit takes effect immediately: anything holding is drained on the same call, so
  work resumes without a restart (FR-017).
- Lowering a limit below what is already spent is allowed and is not an error. The response carries
  the new state, from which the caller can see the limit is already reached and say so at the moment
  it is set (FR-006).
- A limit of zero is a limit. Clearing one requires an explicit null, never a zero.
- The limits are written to `limits.json` before the response returns and before `cost/changed` is
  broadcast.

---

## Method — `agents/setCeiling`

Letting one agent carry on past the per-agent limit — or giving it a ceiling of its own.

```swift
public struct SetCeilingRequest: Codable, Sendable {
    public let agentID: UUID
    /// Null means "no ceiling of its own": the app-wide per-agent limit applies again.
    public let ceiling: Cost?
}
```

**Response**: the updated `Agent`, as `agents/start` and `agents/setOption` already return what they
changed.

**Guarantees**:

- Affects exactly one agent. No other agent's ceiling and neither app-wide limit is touched (FR-016).
- Does not itself send a prompt. Raising a ceiling makes the agent promptable again; it does not
  resume it. Continuing is the reader's second act, deliberately — FR-018 forbids making it the
  automatic response to a limit.
- Refused with `noSuchAgent` for an unknown id, as every other per-agent call is.

---

## Failure — `dayLimitReached`

```swift
public static let dayLimitReached = -32017
```

Raised by `agents/start` when a new agent is asked for and the day's limit is reached. Message names
the limit and what has been spent, because FR-015 forbids a silent refusal.

**Not** raised by `agents/prompt`. A prompt to an existing agent succeeds and the words stay on that
agent's queue, exactly as they do when a runtime will not start — the daemon writes a `runtimeNote`
into the transcript saying why nothing is happening, and sends it when the day rolls over or the
limit is raised. Losing what somebody typed because a budget was reached would be the worst possible
reading of "control cost".

---

## What does not change

- `agents/prompt` keeps its signature and its success. Holding is not an error.
- `agents/stop`, `agents/archive` and `agents/unqueue` are untouched: the reader must always be able
  to stop, put away and un-queue, limit or no limit.
- `agents/list` and `agent/changed` carry the new `costCeiling` field as part of `Agent`; no new
  call is needed to read it.
- `AgentState` gains nothing. A held agent is `finished` or `stopped` with an undrained queue, and
  every existing client renders it correctly today without knowing why.
