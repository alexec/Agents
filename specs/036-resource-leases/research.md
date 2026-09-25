# Research: Resource Leases

Each decision is written as Decision / Rationale / Alternatives. No NEEDS CLARIFICATION remained
in the Technical Context. The two open questions in the spec (turn end, phone scope) were settled
in its Clarifications.

## R1. Where the deciding lives: a pure book in Core

**Decision**: `LeaseBook` is a `Codable`, `Sendable` value type in AgentsKitCore. It has mutating
functions that take `now` and return what happened (`granted`, `queued(place)`, `extended`,
`released(passedTo:)`, and so on). `DaemonCore` holds the one instance, calls these functions,
then persists, broadcasts, resumes continuations and writes transcript notes according to the
returned events.

**Rationale**: The rules (one holder, first come first served, re-request extends, cap, expiry,
dropping an agent) can then be tested in plain unit tests without an actor or a runtime. SC-001
("never two holders") is a property of one function. The daemon's part is only I/O. The same type
is what the phone decodes, so the snapshot and the rules can't drift.

**Alternatives**: Putting the state on each `Agent` record was rejected. A resource's line spans
agents, and "who holds X" would then need a scan with no single place to lock. A separate lease
actor was also rejected: `DaemonCore` already serialises everything, and a second actor would add
an `await` between the check and the write, which is exactly the race FR-002 forbids.

## R2. Three tools, not six

**Decision**:
- `lease_resource(name, minutes?, wait?)` takes the lease, or extends it if the caller already
  holds it (US1-AS3/AS4). A second call while in line keeps waiting in the same place.
- `release_resource(name)` releases a lease, or leaves the line for it.
- `list_resources()` lists every known resource with its state. The caller's own leases and waits
  come first, with expiries.

That covers FR-001's six verbs: lease, release, extend, withdraw, list mine, list all.

**Rationale**: Every tool costs menu space in every agent's context, for every agent, whether or
not it ever leases anything. "Extend" is the same act as "lease again". Withdrawing is the same
act as releasing, seen from the line. The replies say which one happened, so nothing is lost.

**Alternatives**: Six tools, one per verb, cost three more schemas and three more names to brief,
for no difference in behaviour. One tool with an `action` field (like `manage_workflows`) was
rejected because the lease call has its own blocking behaviour. Keeping it separate makes the
description of that behaviour short and sure to be read.

## R3. How long a call waits: 45 seconds

**Decision**: A waiting `lease_resource` call is held open in the daemon as a
`CheckedContinuation` keyed by a wait id, for up to `LeaseLimits.waitLimit = 45 s`. It then
returns "still in line, place N, held by X until T". The waiter stays in the line, marked
`callOpen = false`. Calling again reopens the wait at the same place.

**Rationale**: The call has to return before any runtime gives up on it (FR-004). Known defaults:
Codex CLI's MCP `tool_timeout_sec` defaults to **60 s**. Gemini CLI's MCP timeout defaults to
**10 minutes**. Claude Code's MCP tool timeout is far longer than a minute. Grok isn't documented,
so the live pass checks it. 45 s leaves 15 s of margin under the shortest. The helper's socket
call has no read timeout (only `connect` has one), so the daemon's limit is the only one.
Progress notifications could keep some runtimes waiting longer. They aren't used, because not
every runtime honours them, and the spec wants the same behaviour everywhere.

**Alternatives**: Per-runtime limits were rejected. Each would be a guess at another program's
configuration that breaks silently when that program changes its defaults. Not blocking at all
(always return "queued") was rejected because the spec asks for the call to wait, and a free-soon
resource is the common case.

## R4. Waking an agent whose call has closed

**Decision**: When the book grants a lease to a waiter with `callOpen == false`, the daemon
records a transcript note and calls `prompt(PromptRequest(agentID:, text:, from: .app))` with the
text in contracts/lease-tools.md §Wake. The lease clock starts at the grant (spec, Edge Cases). If
`prompt` throws (runtime missing, agent gone), or the agent is held by a spending limit, the lease
is released with ending `.couldNotStart` and passed on, and the agent's transcript says why.

**Rationale**: `prompt` already queues behind a turn in flight ("after the current turn, not in
the middle"), starts a runtime that isn't running, honours both spending limits, and survives a
restart because the queue is on the agent record. This is how FR-006 and the edge cases come free.

**Alternatives**: Starting a new session directly was rejected because it bypasses the queue and
the limits. A new workflow trigger was rejected because the spec puts that out of scope.

The spending-limit case needs one extra check. `sendNextQueued` holds a prompt silently at a limit
rather than throwing. So after queueing, the daemon checks `held.contains(agentID)` or
`isAtCostLimit`, and if the agent can't run, passes the lease on.

## R5. One timer for expiry, warnings and restart

**Decision**: `LeaseBook.nextDeadline(after:)` returns the earliest of all expiries, all warning
times (expiry − 5 min, not yet warned) and all open-wait limits. `DaemonCore` keeps one
`leaseTimer: Task`, re-armed after every change, that sleeps until that deadline and then calls
`book.lapse(now:)`. The same function runs on load, before anything else touches the book.

**Rationale**: SC-003 asks for release within 5 s of expiry. One timer aimed at the next deadline
is exact, and costs nothing when there are no leases. Running `lapse` on load covers "expired
during the restart" (US5-AS4) with no special case.

**Alternatives**: Reusing the workflow ticker's fixed tick was rejected. It ties lease precision
to an unrelated interval, and wakes the daemon when there is nothing to do.

## R6. The wake prompt is an app prompt

**Decision**: `from: .app`. Checked: `.app` affects only how the entry is drawn ("Agents asked",
not the person's bubble, on both Mac `Transcript.swift:279` and phone `EntryView.swift:30`) and
the fact that `enqueue` doesn't clear `report`/`outcomeAsked`. The outcome question is tracked by
`outcomeAsked`, not by origin. So a lease prompt isn't mistaken for it.

**Rationale**: The person didn't type it, so it must not be in their bubble (the same rule as
023's FR-022).

**Alternatives**: A third origin, `.lease`, was rejected. It would add a case to both platforms'
drawing for text that already reads correctly under "Agents asked". Revisit if the label reads
wrong in the walk.

## R7. Stop, archive and the end of a turn

**Decision**: `stop` and `archive` call `dropLeases(for: agentID, ending: .holderStopped /
.holderArchived)` before their first `await`. This releases every lease (passing each on), removes
the agent from every line, and resumes any open call with "you were stopped". The end of a turn
does nothing (Clarification 1).

**Rationale**: FR-007. Doing it before the first `await` means a grant can't land on an agent
halfway through stopping.

## R8. The person ends leases but never holds one

**Decision**: Only agents hold leases. A lease's holder is an agent id, and there is no
`Holder` type. The person ends leases and removes waiters through two daemon methods called only
by the Mac page. There is no take method and no Take button (Alex, 2026-09-24). Ending an agent's lease leaves
a `LeaseNotice` for that agent, delivered at the start of the reply to its next lease tool call
(FR-012, US4-AS2). The five-minute warning (US5-AS5) and "lost to expiry" work the same way.

**Rationale**: The spec says to tell the agent on its next lease tool call and not to interrupt
it. A notice queue in the book does exactly that, and it survives a restart with the rest.

## R9. Names and known resources

**Decision**: `ResourceName` holds a key: the given text trimmed and lowercased (FR-013). Found
resources have fixed keys and a display name:
- `screen`, shown as "Screen, mouse and keyboard".
- `simulator:<UDID>`, shown as "iPhone 17 Pro · iOS 26.0". A request also matches the UDID alone,
  or the display name when that is unique.
- `browser:<bundle id>`, shown as "Safari". A request also matches the display name.

`ResourceCatalog` runs `xcrun simctl list devices available -j` and asks LaunchServices for the
apps that open `https:`. It caches the result for 60 s and runs off the actor. A resource found
earlier but missing now while leased is marked `gone` (spec, Edge Cases). A name the catalog
doesn't know is an agent-named resource and exists only while held or requested (US6-AS2).

**Rationale**: The UDID is the only stable simulator identity. Two devices can share a name and
OS. The alias matching lets an agent say "Safari" or pass the UDID it gave `xcodebuild`, and still
end up in the same line as everyone else.

## R10. Keeping the daemon alive

**Decision**: `isHoldingAgents` is also true while any line is non-empty. That includes every
open wait, since an open wait is always in a line. Held leases with empty lines don't keep the daemon up. If it exits, `lapse` on the next start
settles what expired.

**Rationale**: A waiter can only be woken by a running daemon. A lease nobody is waiting for
needs nothing to happen when it lapses, except that the page shows it right, and loading does
that.

## R11. What goes over the wire

**Decision**: `leases/changed` carries a `LeaseSnapshot`: the book plus the catalog's found
resources, flattened into `[ResourceState]` sorted for display. `leases/snapshot` answers the same
thing on connect. `AgentsModel` stores it. `LeaseStatus.of(agentID, in: snapshot, now:)` produces
the chat line and the card mark for both platforms. The phone gets it through the bridge's
existing relay of daemon notifications. This has to be checked in Phase 2, because the bridge
may forward only the methods it knows.

**Rationale**: A whole snapshot, like `workflow/changed`, means a client that missed one is put
right by the next. The snapshot is small: tens of rows.

## R12. Transcript record

**Decision**: `runtimeNote` entries, written by the daemon when the book reports granted,
released, extended, expired, ended by the person, or could-not-start (FR-016). Waiting and "still
in line" are in the tool reply already, so they aren't repeated as notes.

**Rationale**: Notes are already drawn on both platforms and already survive in the transcript
file. A new entry kind would need both views changed for no gain.
