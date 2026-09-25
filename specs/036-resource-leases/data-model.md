# Data Model: Resource Leases

All types are in AgentsKitCore (`Model/Lease.swift`, `Model/LeaseBook.swift`,
`Model/LeaseStatus.swift`) unless marked Mac only. All are `Codable, Hashable, Sendable`.

## ResourceName

| Field | Type | Notes |
|---|---|---|
| `key` | `String` | The name trimmed of surrounding whitespace and lowercased. Two names are the same resource when their keys are equal (FR-013). Empty after trimming is refused. |

Found resources use fixed keys: `screen`, `simulator:<udid>` (lowercased) and
`browser:<bundle id>`. Aliases (UDID alone, display name) are resolved to the key by the
catalog before the book sees them (research R9).

## ResourceKind

`screen | simulator | browser | named`. `named` is anything the catalog didn't find.

## Holder

Always an agent: `holder` is the agent's `UUID`. The person never holds a lease (spec,
Clarifications). They end leases and remove waiters, and there is no way to take one.

## Lease

| Field | Type | Notes |
|---|---|---|
| `resource` | `ResourceName` | |
| `holder` | `UUID` | The agent. |
| `grantedAt` | `Date` | When this holder got it. It isn't moved by extensions, because the page shows "held since". |
| `expiresAt` | `Date` | `grantedAt`/last extension + duration, and never more than `now + LeaseLimits.maximum`. |
| `warned` | `Bool` | The five-minute warning notice has been left. Reset by an extension. |

Rules: at most one `Lease` per `resource` (FR-002). This is enforced by the book being a
`[ResourceName: Entry]` map with an optional lease per entry.

## Waiter

| Field | Type | Notes |
|---|---|---|
| `agentID` | `UUID` | |
| `askedAt` | `Date` | Order in line (FR-004, US2-AS5). |
| `minutes` | `Int?` | The duration asked for, applied when granted. |
| `waitID` | `UUID?` | Set while a tool call is open for this waiter. `nil` means "needs waking" (FR-006). Always `nil` after a restart. |

Rules: an agent appears at most once in a given line. An agent that holds a resource can't be in
its line: a re-request is an extension (US1-AS4).

## LeaseBook.Entry

| Field | Type | Notes |
|---|---|---|
| `kind` | `ResourceKind` | |
| `displayName` | `String` | As first given, or from the catalog. |
| `lease` | `Lease?` | |
| `line` | `[Waiter]` | In asking order. |

An entry with no lease and an empty line is removed. Found resources are drawn from the catalog
anyway, so they never disappear from the page.

## LeaseBook

| Field | Type | Notes |
|---|---|---|
| `entries` | `[ResourceName: Entry]` | |
| `notices` | `[UUID: [LeaseNotice]]` | Told to the agent at the head of its next lease tool reply, then cleared (FR-012, US5-AS5). |

Operations (all `mutating`, all taking `now`, all returning `[LeaseEvent]`):

| Operation | Result |
|---|---|
| `request(name, kind, display, by: agentID, minutes, wait: Bool, waitID)` | `.granted(lease)`, `.extended(lease, capped: Bool)`, `.queued(place, holder, until)`, `.refused(holder, until)` (don't wait), or `.stillWaiting(place)` when already in line (the new `waitID` replaces the old one) |
| `release(name, by: agentID)` | `.released(lease)` + `.granted(to next)`, or `.leftLine`, or `.nothingHeld` |
| `end(name, byPerson)` | `.ended(lease)` + notice to the holder + `.granted(to next)` |
| `removeFromLine(name, agentID)` | `.leftLine` |
| `drop(agentID, because: LeaseEnding)` | every lease released and every place left, each with its `.granted(to next)` |
| `waitTimedOut(waitID)` | `.stillWaiting(place)`, and sets the waiter's `waitID = nil` |
| `lapse(now)` | `.expired(lease)` + notice + `.granted(to next)` for each passed expiry. `.warned` + notice for each lease inside the warning window. |
| `closeAllWaits()` | sets every `waitID = nil` (on load) |
| `nextDeadline(openWaits:)` | the earliest expiry, warning time, or open-wait limit |

A `.granted` event carries whether the waiter's call was open (resume the continuation) or closed
(wake by prompt, research R4).

## LeaseEnding

`released | expired | endedByPerson | holderStopped | holderArchived | couldNotStart`. This is
recorded in the transcript note (FR-016) and in the event. The book doesn't keep a history
beyond the transcript.

## LeaseNotice

| Field | Type | Notes |
|---|---|---|
| `resource` | `ResourceName` | |
| `kind` | `endedByPerson | expired | endingSoon(expiresAt)` | |
| `at` | `Date` | |

## LeaseLimits

`defaultDuration = 30 min`, `maximum = 4 h`, `warning = 5 min`, `waitLimit = 45 s`. These are
static constants (spec, Assumptions: settings later).

## LeaseSnapshot (wire, DaemonAPI)

| Field | Type | Notes |
|---|---|---|
| `resources` | `[ResourceState]` | Found resources first (screen, simulators, browsers), then named ones, each group alphabetical. |
| `at` | `Date` | The daemon's clock, so a client counts time left from the daemon's time, not its own. |

`ResourceState`: `name`, `kind`, `displayName`, `isGone: Bool`, `lease: Lease?`,
`line: [Waiter]` (with `waitID` dropped), `endingSoon: Bool`.

## LeaseStatus (shared, derived)

`LeaseStatus.of(agentID, in: LeaseSnapshot, now:) -> LeaseStatus?`, which is `nil` when the agent
holds and waits for nothing (FR-010).
- `holding: [(displayName, expiresAt)]`
- `waiting: [(displayName, holderName, place)]`
- `line: String`: the full chat line, e.g. "Holding iPhone 17 Pro · iOS 26.0 (22 min left) ·
  Waiting for Screen, held by “Fix login”, 2nd in line".
- `mark: String`: the short form for rows and cards, e.g. "Holds Simulator" or "Waiting: Screen".

Holder names come from the client's own `agents` list.

## LeaseStore (Mac only)

`leases.json` under `StoreLocations.root`, next to the other stores. It holds the whole
`LeaseBook`, written atomically after every mutation, and read once at start. A missing file is
an empty book. A file that can't be decoded is moved aside as `leases.json.unreadable` and the
book starts empty, with a log line. A lock nobody can see is worse than losing leases.

## State transitions (one resource)

```text
free ──request──▶ held(A) ──release/expire/end/drop(A)──▶ held(next) or free
held(A) ──request(A)──▶ held(A, later expiry)            (extension, never a wait)
held(A) ──request(B)──▶ held(A), line [B]                (wait, or refused with don't-wait)
line [B(open)] ──45 s──▶ line [B(closed)]                (reply "still in line")
held(A), line [B(closed)] ──A ends──▶ held(B) + wake B by prompt
held(B, wake failed) ──▶ release(.couldNotStart) ──▶ held(next) or free
```
