# Contract: daemon API additions

The daemon speaks JSON-RPC over a unix socket; `DaemonAPI` in `AgentsKitCore` is the whole
vocabulary, shared verbatim by the Mac app and the iOS Remote. This feature adds one method and one
notification, both modelled directly on existing pairs.

---

## Notification — `agent/resuming`

Sent whenever a chat joins or leaves the set being picked back up after a restart.

```swift
public struct ResumingNotification: Codable, Sendable {
    public let agentID: UUID
    /// True when the chat has joined the queue to be picked back up, false when it has
    /// left it — whether because its prompt went, because it could not be sent, or
    /// because the person stopped it first.
    public let isResuming: Bool
}
```

**Method name**: `DaemonAPI.Notification.agentResuming = "agent/resuming"`

**Precedent**: `agent/showFile` / `ShowFileNotification` — a transient per-chat fact the record
does not hold, broadcast to every window and held client-side.

**Guarantees**:

- A `true` is always eventually followed by a `false` for the same `agentID`, in the same daemon
  run. A chat is never left showing as returning.
- The `true` for every chat in a batch is sent before the first pick-up begins, so a window shows
  the whole batch at once rather than one row at a time.
- It is sent after the socket is open. `recover()` runs before the socket exists and broadcasts
  nothing; `pickUpAfterRestart` runs after it, which is why the two are separate calls in
  `Daemon.start()`.
- A `false` accompanied by no state change means the pick-up failed or was withdrawn; the reason is
  in the chat's transcript, which arrives as an ordinary `agent/entry`.

---

## Method — `agents/resuming`

Seeds a window that connects while chats are still coming back.

**Request**: no params.

**Response**:

```swift
public struct ResumingResponse: Codable, Sendable {
    public let agentIDs: [UUID]
}
```

**Method name**: `DaemonAPI.Method.agentsResuming = "agents/resuming"`

**Precedent**: `permissions/pending` and `elicitations/pending` exist for exactly this reason — a
question raised before a window connected must still be answerable by it. The same is true here: a
window opened five seconds into a ten-chat restart would otherwise miss every `true` already sent.

**Guarantees**:

- Returns the set as it stands at the moment of the call. Ordering is not meaningful.
- A chat in this list is always `.stopped` with `endedReason == .daemonGone` at the moment it is
  returned. The app must not rely on that afterwards — the pick-up may land between the response
  and the next render.

---

## Client — `AgentsModel` (AgentsKitCore/Client)

```swift
public private(set) var resuming: Set<UUID> = []
```

- Fed by `apply(_:_:)` on `agent/resuming`, alongside the existing `agentShowFile` case.
- Seeded by the connect path that already calls `agents/list`, `permissions/pending` and
  `elicitations/pending`.
- Cleared for a chat by the same `forget(_:)`-style path that clears `filesToShow`, so a deleted
  chat leaves nothing behind.

**Derived, not stored**:

```swift
public func isComingBack(_ agent: Agent) -> Bool { resuming.contains(agent.id) }
```

`AgentGroup` is **not** changed. A chat coming back stays in "Stopped" until its prompt lands and
its state becomes `.running`, at which point the existing grouping moves it to "Working" by itself.
Putting it under "Working" early would be the app claiming a turn is in flight when none is.

---

## Wording contract

The window and the phone must say the same words. Asserted by a test over both switches.

| Situation | Row line | Where |
|---|---|---|
| Chat is in `resuming` | `Coming back after a restart` | `AgentRow.description`, `AgentCard.description` |
| Chat is stopped at its pick-up limit | `Stopped with the daemon` (unchanged ending) plus the transcript line below | ending is unchanged; only the transcript explains |

Transcript lines, all `runtimeNote` entries in the app's own voice:

| Situation | Words |
|---|---|
| Found interrupted (exists today) | `This agent was working when the daemon stopped, so it stopped too.` |
| Not picked up, at its limit | `This agent was picked back up after the last restart and did not get to the end of a turn, so it has been left alone this time. Send it a message to start it again.` |
| Pick-up failed (exists today) | `Could not pick this agent back up: <why> Send it a message to pick it up yourself.` |
| Pick-up withdrawn by the person | `You stopped this agent before it was picked back up.` |

The two prompts sent to the agent itself — `wordsAboutTheRestart(_:)` for a chat that was working
and for one that was holding a question open — are unchanged, and remain bracketed so that a person
reading back can tell the app apart from themselves (FR-006).

---

## Compatibility

- An older window connected to a newer daemon receives `agent/resuming` and returns `false` from
  `apply(_:_:)`, which is the documented "a notification nobody claims is skipped, never guessed
  at" path. It shows chats as stopped until they start, exactly as today. Nothing breaks.
- A newer window against an older daemon gets a method-not-found from `agents/resuming`; the
  connect path must treat that as an empty set rather than a failed connection.
- `Agent.restartPickUps` is absent from records written by older builds and decodes as `0`.
