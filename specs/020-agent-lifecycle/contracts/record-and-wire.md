# Contract: The Record and the Wire

**Feature**: 020-agent-lifecycle

What crosses the socket between `agentsd` and the two apps, and what is written to disk.
One new value, two new gates, one new tolerance.

---

## 1. `AgentState` on the wire and in the record

`AgentState` is a `String` raw-value enum. It appears as `Agent.state` in:

- the record at `<store>/agents/<uuid>/agent.json`
- `agents/list`, `agents/get` and every other method returning an `Agent`
- the `agents/changed` notification
- `TranscriptEntry.stateChanged`, in `transcript.jsonl`

**New value**: `"starting"`. It joins `"running"`, `"waitingOnUser"`, `"finished"`,
`"stopped"`, `"archived"`, which are unchanged.

### Compatibility

| Direction | Behaviour |
| --- | --- |
| This build reads an older record | Unchanged. Every earlier record is in one of the five existing states |
| This build reads a record with a state it does not know | Opens as `stopped` / `unrecognised`, and the original string is written back out (FR-021). Held in `Agent.rawState`, which is in memory only and deliberately not a `CodingKey`; cleared by `move` the moment a transition writes a state of our own, or the round trip would outlive the truth it preserved |
| An older build reads a `"starting"` record | **It drops the agent.** See below |

The last row is a real and accepted limitation. `Agent.init(from:)` in builds predating
this feature throws on an unknown state, which fails the whole record, which makes
`AgentStore.loadAll` file it under `unreadable` and carry on without it — the agent
disappears from the app with nothing a person can see.

The exposure is narrow: `starting` lasts for the seconds a session takes to be made, so a
record is only caught in it if the daemon dies mid-start *and* the next daemon is an older
build. It is the argument for adding the lenient decode now rather than the next time a
state is added — from this build onwards, it is the last time this can happen.

---

## 2. Record invariants

Four rules. Checked on every write and every read (FR-018, FR-020), where today they are
asserted only in `AgentStoreTests`.

| # | Rule |
| --- | --- |
| 1 | `archived` ⇒ has an `archivedReason` |
| 2 | `stopped` ⇒ has an `endedReason` |
| 3 | `finished` ⇒ `endedReason == endTurn` |
| 4 | `starting` ⇒ no `endedReason` and no `archivedReason` *(new)* |

### On write

`AgentStore.save` throws for a record breaking any of them, and logs the agent's id and
which rule (FR-019). Nothing partial reaches disk — the existing write is already atomic.

`DaemonCore.saveQuietly` swallows errors with `try?`, so the log line is the only evidence
a refusal happened. That is deliberate: a refused save is a bug in this app, not something
to tell the person about, and taking the daemon down over it would lose the agents that
are fine.

### On read

`AgentStore.load` mends a record breaking any of them to the nearest state the rules allow,
and reports that it did so. The daemon writes a `runtimeNote` in the agent's transcript
saying what was mended and why (FR-020).

Mending, not refusing: a person who cannot see an agent cannot do anything about it.

| Broken | Mended to |
| --- | --- |
| `archived`, no reason | `archived`, reason `byUser` |
| `stopped`, no reason | `stopped`, reason `unrecognised` |
| `finished`, reason is not `endTurn` | `stopped`, keeping the reason it had |
| `starting`, carries a reason | `starting` is only ever transient; treated as an agent found dead — `stopped` / `daemonGone` |

A record that will not *decode* at all — truncated, corrupt, not JSON — is a different
thing and keeps its existing behaviour: skipped by `loadAll`, listed in `unreadable`, and
one bad file still does not stop the daemon starting.

---

## 3. Notifications

No new method and no new notification.

`agents/changed` already carries the whole `Agent`, so `starting` reaches every window with
no protocol change. What changes is only that the app now sees `starting` where it
previously saw a momentary `stopped`.

`agents/resuming`, `agents/permission`, `agents/elicitation` and `agents/entry` are
untouched.

---

## 4. What the apps must say

`AgentState` is switched exhaustively in **11** places outside `AgentState.swift` — 5 in
`App/Sources`, 4 in `Remote/Sources`, `AgentGroup`, and the post-transition switch in
`DaemonCore.move`. Adding a case makes every one a compile error, which is the compiler
enumerating the callers.

**Two switches are exceptions and compile silently.** Both must be visited by hand:

| Where | What it would do |
| --- | --- |
| `App/Sources/AgentList/AgentRow.swift` — `tint` | `default: return .none` gives a new state whatever the default is. `.none` happens to be right for `starting`; it was checked rather than assumed |
| `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Recovery.swift` — `wordsAboutTheRestart` | `default:` tells the agent "the turn you were in the middle of was cut off… everything above is still yours", which is two false statements about an agent cut off before its first turn began |

The App count of 5 includes `Chat/PromptBar.swift`, which every survey of this feature
missed — it groups `.running, .waitingOnUser` on one line, so a grep for
`case .waitingOnUser` does not find it. It is unreachable for `starting` because of the
`hasTurnInFlight` guard above it, and it is answered anyway.

| Surface | Must say |
| --- | --- |
| Group heading | **Working** — `AgentGroup(for: .starting) == .running`. No heading is added or renamed (FR-023) |
| Row label, window and phone | "Starting" |
| Row icon | The working icon, or its own; settled in tasks |
| Accessibility label | Matches the row label |

The word is defined once, in `AgentsKitCore`, in the manner `EndedReason.summary` and
`WorkOutcome.heading` already are — "the phone and the window have to say the same words
about the same agent, and two copies of a switch are two chances to drift". The existing
duplication of the other five words across `AgentRow.swift` and `AgentCard.swift` belongs
to 018 and is not touched here.
