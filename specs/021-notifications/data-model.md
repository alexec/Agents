# Data Model: Notifications, Where The Person Actually Is

Four new things exist while the daemon runs, and one is written to disk. That ratio is the
design: what the person is doing right now is not a fact worth keeping, and what they approved
once is.

| Thing | Lives | Survives a restart |
|---|---|---|
| `Need` | derived on demand from the agent record | as the agent does — it is not stored |
| `Presence` | in `DaemonCore`, one per connection | no, deliberately |
| `Delivery` | in `DaemonCore`, one per need | no |
| `Device` | `devices.json` under the daemon's root | yes |

---

## Need

What wants a person. Derived, never stored, exactly as `AgentGroup` is — which is what makes
it impossible for a need to exist without an agent behind it, or for an agent that needs
somebody to have no need.

Lives in `AgentsKitCore/Attention/Need.swift`.

| Field | Type | Meaning |
|---|---|---|
| `id` | `NeedID` | What is being answered. See below — it is not the agent. |
| `agentID` | `UUID` | Whose it is. |
| `folder` | `URL` | The project, for the banner's first line and for grouping. |
| `kind` | `Kind` | `permission`, `elicitation`, `report`. Chooses the third line's wording. |
| `raisedAt` | `Date` | When the daemon first saw it. Drives the settling pause and the re-alert interval. |
| `headline` | `Headline` | The three short strings a banner is allowed. Built once, in Core. |

### Identity

`NeedID` is the thing being answered, not the agent, because the spec's edge case requires
that the same agent asking twice is two needs and that answering the first does not clear the
second:

```text
.permission(UUID)     PermissionRequest.id
.elicitation(UUID)    ElicitationRequest.id
.report(UUID, Date)   the agent, and the report's timestamp
```

`UUID` for the first two because that is what both request types already carry
(`PermissionRequest.swift:9`, `Elicitation.swift:9`) and what `DaemonCore.pendingPermissions`
is keyed by (`DaemonCore.swift:20`). The third is a pair because a report carries no id of its
own, and a second report on the same agent must not be mistaken for the first.

The three cases are distinct even when the UUIDs collide, because the case is part of the
identity — a permission and an elicitation could in principle be issued the same id by two
different code paths, and conflating them would clear the wrong banner.

### Where it comes from

```swift
// AgentsKitCore — the one definition, reused, never restated.
var needsAPerson: Bool {
    state == .waitingOnUser || (state == .finished && report?.outcome.needsAPerson == true)
}
```

FR-001 forbids a second definition, so `Need` is built from this and from the pending
dictionaries the daemon already keeps. No new detection anywhere.

### Lifecycle

```text
   (nothing) ── agent blocks, or reports it is stuck ──▶ outstanding
   outstanding ── answered on any surface ────────────▶ met, and gone
   outstanding ── agent stopped or archived ──────────▶ met, and gone
   outstanding ── daemon exits ───────────────────────▶ gone with it; recomputed on the next start
```

There is no "dismissed". A notification the person swipes away is a banner gone, not a need
met; the agent is still blocked and the project row still says so. Conflating the two would be
the app lying about the work, which is the one thing it must not do.

### Invariants

- A need exists **iff** its agent satisfies the rule above, or its id is in a pending
  dictionary. Never one without the other.
- `raisedAt` never moves. A need that is re-routed is the same need.
- At most one live delivery per need across every surface (FR-003), which is `Delivery`'s job
  and not this one's.

## Headline

Three short strings, and there is no fourth, because `desiredKeys` carries at most three keys
of about 100 characters each (research §11, and 005's T004 measures the real figure).

| Field | Holds | Example |
|---|---|---|
| `h1` | the project's folder name | `Agents` |
| `h2` | the agent's title | `rename-refactor` |
| `h3` | what is wanted, in a few words | ``wants to run `git push` `` |

Built in Core, once, so the Mac banner and the phone banner say the same words about the same
agent — the rule `AgentState.startingLabel` exists to defend. Each field is truncated to the
measured budget **before** sealing; a headline that will not fit degrades to the generic
placeholder rather than being cut mid-ciphertext.

## Presence

What the daemon believes about where the person is. One record per connected surface, held in
memory and never written down.

Lives in `AgentsKitCore/Attention/Presence.swift`; `DaemonCore` holds the dictionary.

| Field | Type | Meaning |
|---|---|---|
| `surface` | `Surface` | `.mac` or `.device(UUID)`. Identity, taken from the connection. |
| `watching` | `UUID?` | The conversation on screen, if any. |
| `active` | `Bool` | In front of the person: frontmost on the Mac, foreground and unlocked on a device. |
| `heardAt` | `Date` | When the daemon received this. **Stamped by the daemon, never by the sender.** |

`heardAt` is the daemon's own clock by requirement, not by convenience: the spec's edge case
says a device with a fast clock must not win every race, and a report arriving over a live
connection needs no timestamp from the far end.

### Derived, never stored

| Property | Rule |
|---|---|
| `isRecent` | `now - heardAt < deviceStaleness`. A surface not heard from is not evidence of anything. |
| `isHere` | `active && now - heardAt < macIdle`. Used for the Mac rung. |
| `isWatching(_:)` | `active && watching == agentID`. Used for the silence rung. |

### Invariants

- One record per surface. A reconnecting surface replaces its own record; it does not add one.
- A disconnected surface's record is deleted, not aged out. Gone is more truthful than stale,
  and it is the difference between the Mac rung failing fast and the person waiting 120 s for
  a banner nobody can show.
- Presence is never consulted for anything except routing. It decides nothing about the work.

## Surface

```text
.mac                 a connected Agents window
.device(UUID)        a paired device, by its Device id
```

Two cases and no third. It is `Codable` as a tagged object rather than a bare string, so
adding a third later — a watch, if it ever happens — is additive rather than a re-parse.

## Delivery

The record of a need having been put in front of the person somewhere. This is what makes
FR-003 ("at most one live notification per need") checkable and FR-018's interval measurable.

| Field | Type | Meaning |
|---|---|---|
| `needID` | `NeedID` | Which need. |
| `to` | `Surface?` | Where it should be showing. `nil` means nowhere can be reached. |
| `alertedAt` | `Date` | When the person was last actually buzzed about this need. |
| `alertCount` | `Int` | How many times. Read by SC-006's assertion, and by nothing else. |

### Invariants

- One `Delivery` per outstanding `Need`, created when the ladder first answers for it.
- Changing `to` is a **move**, and moves do not touch `alertedAt` unless the re-alert interval
  has passed — that is the whole of FR-018, in one place.
- A `Delivery` is destroyed when its need is met. Nothing outlives the need it belongs to.

## Device

005's record, unchanged, built here because 005 never built it. Lives in
`AgentsKitCore/Remote/Device.swift`; stored by the daemon at `devices.json`.

| Field | Type | Meaning |
|---|---|---|
| `id` | `UUID` | Made by the device on first run. Identity. |
| `publicKey` | `Data` | P256. Everything sealed to this device is sealed to it. |
| `name` | `String` | "Alex's iPhone". Shown on the Mac and in "answered by". |
| `kind` | `Kind` | `iPhone`, `iPad`, `unknown`. **Drives the FR-009 default, and an icon.** |
| `announcedAt` | `Date` | When it first asked. |
| `approvedAt` | `Date?` | `nil` means waiting. |
| `lastSeenAt` | `Date?` | When it last connected. |
| `mayNotify` | `Bool?` | Whether the person granted it notification permission. `nil` means it has not said. FR-023. |
| `unknownFields` | `[String: JSONValue]` | Kept and written back, as `Agent` and `Project` do. |

Two differences from 005's data model, both deliberate:

- **`wants` is not built.** 005 gave each device three flags for which kinds it accepted. This
  feature's Out of Scope says every approved device is eligible for everything, so the field is
  left out rather than added and ignored. `unknownFields` means a record written by a future
  build that has it is not damaged by this one.
- **`mayNotify` is added**, because FR-023 requires the Mac to show which devices are able to
  show notifications and which have been refused. It is the device's report of its own
  authorisation status, refreshed whenever it connects — not a setting anybody here edits.

`kind` stops being decorative in this feature. FR-009 makes the iPhone the default when nothing
says where the person is, so `kind` is now load-bearing and a device that reports `unknown`
cannot be the default. That is worth knowing before somebody simplifies it away.

### Invariants

- One record per `id`. A reinstalled device is a new id, a new key, and a new approval.
- Sealed to only while `approvedAt != nil`. Revoking **deletes** the record, which is what makes
  the device unable to read anything — not a flag somebody must remember to check.
- The public key is never rewritten. A device that wants a new key is a new device.

## Thresholds

Not an entity, but the one place four numbers live, so they move together or not at all.
`AgentsKitCore/Attention/AttentionThresholds.swift`.

| Name | Value | Requirement |
|---|---|---|
| `macIdle` | 120 s | FR-007 |
| `deviceStaleness` | 10 min | FR-008 |
| `settlingPause` | 20 s | FR-014 |
| `reAlertInterval` | 5 min | FR-018 |

Injectable, with these as the defaults, so every test names its own and none of them sleeps.
Research §9 gives the reason for each figure.
