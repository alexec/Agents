# Data model: The iPad Remote

What changes on top of feature 005's model (`specs/005-mobile-remotes/data-model.md`), which
stands unaltered. `Device`, `Envelope`, `Headline`, the mailbox record and the `devices.json`
file are all 005's and are not redescribed here.

Nothing in this feature adds a field to `Agent`, `Project`, `agent.json` or
`transcript.jsonl`. The daemon remains the only writer of anything durable (FR-030).

---

## New: `Escalation`

`Packages/AgentsKit/Sources/AgentsKitCore/Remote/Escalation.swift`

A question projected down to what a banner can carry and a tap can answer. Pure, both
platforms, unit-tested. Built on the Mac side by the bridge; consumed on the iPad by the
extension and the action handler.

| Field | Type | Notes |
|---|---|---|
| `permissionID` | `UUID` | What `permissions/answer` is called with. |
| `agentID` | `UUID` | Where opening the notification lands (FR-005). |
| `projectFolder` | `URL` | So the banner can name the project without a lookup. |
| `category` | `Category` | Which registered category this request maps to. |
| `options` | `[PermissionOption.Kind: String]` | kind → `optionID`. **Never contains `.unknown`.** |
| `askedAt` | `Date` | |
| `expiresAt` | `Date` | When the option map is swept regardless. |

```swift
enum Category: String {
    case allowDeny        = "perm.allowDeny"
    case allowAlwaysDeny  = "perm.allowAlwaysDeny"
    case full             = "perm.full"
    case openOnly         = "perm.openOnly"   // a form, or any .unknown option present
}
```

**Derivation rule** — this is the pure function worth the most tests:

```
Escalation(from: PermissionRequest) ->
  if any option.kind == .unknown           -> .openOnly, options = [:]
  else by the set of kinds present:
     {allowOnce, rejectOnce}                          -> .allowDeny
     {allowOnce, allowAlways, rejectOnce}             -> .allowAlwaysDeny
     {allowOnce, allowAlways, rejectOnce, rejectAlways} -> .full
     anything else                                    -> .openOnly
```

Two invariants a test should hold to:

- `options` never maps a kind to an `optionID` the request did not offer.
- A request that yields `.openOnly` yields an empty map, so no code path downstream can find an
  `optionID` to press.

An `ElicitationRequest` projects to `.openOnly` with an empty map. A form is answered in the
app (FR-011); there is no banner that can take one.

## New: `OutstandingQuestion`

`Packages/AgentsKit/Sources/AgentsKitCore/Notifications/OutstandingQuestion.swift`

What the service extension leaves in the shared app group for the action handler. It is the
`Escalation` above, plus the notification request identifier that keyed it. Shape and rules
are in `contracts/notification-actions.md`.

**Lifecycle**: written by the extension before the banner is shown; read once by the action
handler; deleted on answer, on withdrawal, on expiry, and by a sweep at every app launch and
every extension run.

**It is a cache, not a record.** It holds the ids and the three headline fields — nothing the
banner did not already show. No transcript, no diff, no file content, no command output. Stored
with the same protection as the device key: available after first unlock, this device only,
never synced, so a revoked iPad holds nothing readable (FR-031).

**Storage**: a shared app group container, because the extension and the app are separate
processes and this is the only thing they must both reach. Not the keychain — it is not a
secret, it is short-lived state, and the keychain is the wrong tool for something swept
hourly.

## New: `ActionCategory`

`Packages/AgentsKit/Sources/AgentsKitCore/Notifications/ActionCategory.swift`

The registry: the fixed set of `UNNotificationCategory` values and their actions, and the
mapping from an action identifier back to a `PermissionOption.Kind`. Pure, table-driven, and
the single place the titles and the `authenticationRequired` flags in
`contracts/notification-actions.md` are written down.

The round trip — `Kind` → action identifier → `Kind` — is total and lossless for the four real
kinds, and undefined for `.unknown`, which never reaches it.

---

## Changed: `DaemonAPI.Failure`

Two additions, renumbered from what 005 proposed because those numbers were taken by features
that landed since (research §7):

| Constant | Number | Meaning |
|---|---|---|
| `alreadyAnswered` | **`-32018`** | Somebody answered this first. Carries who. |
| `noSuchDevice` | **`-32019`** | A device id that is not paired. |

005's task list says `-32013` and `-32014`. Those are `projectHasLiveAgents` and
`noSuchWorkflow`. Any task copied from 005 must be re-read for numbers.

## Changed: `Headline`

005's `Headline` carries `h1`, `h2`, `h3` — project, agent, action — each truncated to the
measured budget and sealed separately. Unchanged in shape.

What is new is a second consumer: the service extension, having decrypted the three fields to
write the banner, also writes the `OutstandingQuestion` for the action handler. The
`Escalation` it needs travels in the **sealed body** of the mailbox record, not in the three
headline fields — those remain what they were, and their budget is not touched.

## Changed: `AnswerRequest`

005 T040 adds `answeredBy: String?`, optional on read, to `AnswerRequest`,
`AnswerElicitationRequest` and `PermissionNotification`. Unchanged and still required. The
iPad's action handler sets it to the device name so FR-012's "and by which device" has
something to say.

---

## Not changed, listed so nobody looks

- `Agent`, including `plans`. FR-017 is a view over data that already arrives on `agent/changed`
  (research §5). No new notification, no new field.
- `ToolCall`, `ToolCallContent`, `ToolCallLocation`. FR-016 and FR-020a render what is there.
- `agents/showFile` and `agent/showFile`. Already in `DaemonAPI`, already applied by
  `AgentsModel`, already unused on iOS (research §6).
- `AgentGroup`. Shared between the Mac and the iPad by design. If feature 014 changes the
  status vocabulary, both move together.
- `devices.json`, `Device`, `DeviceKey`, `Envelope`, the mailbox record. All 005's, unbuilt,
  unchanged.
