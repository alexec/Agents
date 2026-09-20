# Implementation Plan: Notifications, Where The Person Actually Is

**Branch**: `021-notifications` | **Date**: 2026-09-19 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `/specs/021-notifications/spec.md`

## Summary

The daemon already knows, at a single point in the code, when an agent needs a person. This
feature gives that fact somewhere to go.

`DaemonCore` gains a **need** — derived from `Agent.needsAPerson`, never stored — and a
**presence** record per connected surface, fed by a new `presence/report` that every window
and every remote calls when it comes to the front, goes behind, or changes conversation. A
four-rung ladder turns the two into one answer: watching that conversation means silence; at
the Mac means the Mac's own banner; otherwise the most recently used device; otherwise the
iPhone. The answer is broadcast as one notification carrying the whole resolved fact, and
every surface applies the same idempotent rule to it, so a need that moves between devices is
one message rather than a withdrawal and a delivery that could cross.

Research found one thing that reshapes the work: **the link 005 actually shipped cannot
deliver a notification in the only case that matters** — it is a TCP connection held by a
foreground app, and the person we are trying to reach is by definition not looking. The
mailbox and the push that 005 designed and never built are not an upgrade path; they are the
feature. So this plan carries 005's unbuilt half, and orders the work so that everything
needing no new infrastructure is proven first: a Mac banner that works today, then the
iPad-versus-iPhone routing walked on real hardware over the existing LAN bridge, then the
CloudKit substrate whose first task is a spike that can fail in a way that stops the feature.

## Technical Context

**Language/Version**: Swift 6.0, strict concurrency complete

**Primary Dependencies**: UserNotifications (both platforms); CloudKit and CryptoKit (Slice C);
Network framework (already, via the bridge); no third-party additions

**Storage**: `devices.json` under the daemon's root, written whole on change, beside
`projects.json`. Needs and presence are **not** stored — both are derived or live, and neither
survives a daemon restart by design.

**Testing**: swift-testing in `Packages/AgentsKit/Tests/AgentsKitTests`, run by
`swift test --package-path Packages/AgentsKit`. The ladder, the need's identity and the
lifecycle are pure and are unit-tested against a fake surface with an injected clock. The
device slices need real hardware and are walked, not asserted.

**Target Platform**: macOS 27, iOS 27 (iPhone and iPad)

**Project Type**: Desktop app with a daemon, two mobile remotes, and two helper processes

**Performance Goals**: notification in the person's hand within 5 s of the need arising
(SC-001); the ladder itself is arithmetic over a handful of records and must cost nothing
measurable on the daemon's hot path

**Constraints**: the daemon must not gain a network client, an entitlement, or a bundle; no
login item and nothing installed; nothing stored outside the daemon's root; the two apps must
say the same words about the same agent

**Scale/Scope**: one person, at most a handful of devices, a few dozen agents. Needs
outstanding at once are in single figures.

## Constitution Check

`.specify/memory/constitution.md` **is an unfilled template** — every principle is still
`[PRINCIPLE_N_NAME]` with the example comments beside it. There is nothing there to check
against, and pretending otherwise would be the worst of both worlds.

So the gates below are the project's actual standing rules, taken from the README and from the
doc comments the code defends them with. They are cited rather than invented, and the feature
is checked against each.

| Gate | Where it is stated | This feature |
|---|---|---|
| The daemon is the only writer | README, "The daemon" | **Passes.** `devices.json` is written by the daemon alone. The bridge reads nothing from the store; it is handed what to send. |
| Nothing installed, no login item | README; 001 FR-021; 005 §7 | **Passes.** The bridge is spawned by `agentsd` as `agentsd` is spawned by the app. No `SMAppService`. The cost — nothing runs after a reboot until the app is opened once — is inherited from 005 and restated in the quickstart. |
| Nothing stored outside the root | README | **Passes.** `devices.json` is under the root. The device's own private key is in the device's keychain, which is the device's, not ours. |
| One rule, one place | `AgentGroup`, `AgentState`, `EndedReason.summary` | **Passes, and is a requirement.** FR-001 forbids a second definition of what needs a person; the plan reuses `Agent.needsAPerson` unchanged. The four thresholds live in one type for the same reason. |
| The two apps say the same words | `AgentState.startingLabel`; 018 | **Passes.** The banner's three fields are built in Core from the agent's record, once, and both platforms render the same strings. |
| No code asks which runtime it is | README, "What the app does with a runtime" | **Not engaged.** Nothing here touches a runtime. |
| A window may be gone and the work goes on | README, "The daemon" | **Passes, and is leaned on.** `isHoldingAgents` already counts a pending permission, so the daemon is alive for exactly as long as a need exists. |

**One gate is at risk and it is named rather than waved past.** The rule that the daemon gains
no network code and no new attack surface is what forces the bridge to be a separate process
holding CloudKit, the crypto and the mailbox. That is 005's §6 decision and this plan keeps
it. If the spike in §7 of research fails — a nested app-like bundle cannot reach the private
database — the only remaining shapes are "the Mac app must be running" or "the daemon gains
the entitlement". The first is the feature's premise gone; the second breaks this gate. There
is no third option identified, and the plan says so before the work starts rather than after.

## Project Structure

### Documentation (this feature)

```text
specs/021-notifications/
├── plan.md              # This file
├── research.md          # Phase 0 — twelve findings
├── data-model.md        # Phase 1
├── quickstart.md        # Phase 1
├── contracts/
│   ├── daemon-api.md    # presence/report, attention/*, devices/*
│   └── routing.md       # the ladder, exhaustively, as a table
├── checklists/
│   └── requirements.md  # written by /speckit-specify
└── tasks.md             # /speckit-tasks — not created here
```

### Source Code (repository root)

New files are marked **new**; everything else is an existing file that gains something.

```text
Packages/AgentsKit/Sources/AgentsKitCore/
├── Attention/
│   ├── Need.swift                 # new — what wants a person, and its identity
│   ├── Surface.swift              # new — .mac or .device(UUID)
│   ├── Presence.swift             # new — one record per surface; pure
│   ├── AttentionThresholds.swift  # new — the four numbers, in one place
│   └── Routing.swift              # new — the ladder. Pure, total, testable.
├── Remote/
│   ├── Device.swift               # new — 005's record, built here (Slice C)
│   ├── DeviceKey.swift            # new — P256, Enclave-backed (Slice C)
│   ├── Envelope.swift             # new — HPKE seal (Slice C)
│   ├── Headline.swift             # new — the three banner fields (Slice C)
│   ├── Mailbox.swift              # new — protocol + fake (Slice C)
│   ├── CloudKitMailbox.swift      # new — the real one (Slice C)
│   ├── MailboxTransport.swift     # new — third LineTransport (Slice C)
│   └── NetworkLink.swift          # exists
├── Client/AgentsModel.swift       # gains: needs it has been told about
└── Daemon/DaemonAPI.swift         # gains: methods, notification, DTOs, two failure codes

Packages/AgentsKit/Sources/AgentsKit/
├── Daemon/
│   ├── DaemonCore+Attention.swift # new — needs, presence, the ladder, broadcasting
│   ├── DaemonCore+Devices.swift   # new — devices/list|announce|approve|revoke (Slice C)
│   ├── DaemonCore.swift           # move() and the permission paths call into Attention
│   ├── DaemonCore+Commands.swift  # answering a question ends a need
│   ├── DaemonCore+Dispatch.swift  # the new methods
│   └── DaemonServer.swift         # a connection gains an identity, so presence has an owner
└── Store/
    ├── DeviceStore.swift          # new (Slice C)
    └── StoreLocations.swift       # gains `devices`

App/Sources/
├── Notifications/
│   ├── MacNotifier.swift          # new — posts and withdraws the Mac banner
│   └── PresenceReporter.swift     # new — frontmost, watching, last input
└── AppModel.swift                 # wires both to the model it already has

Remote/Sources/
├── Notifications/
│   ├── DeviceNotifier.swift       # new — the same two jobs on iOS
│   └── PresenceReporter.swift     # new — scenePhase and selection
├── Devices/PairingView.swift      # new — announce, and say what is waiting (Slice C)
└── RemoteModel.swift              # wires both

RemoteNotify/                      # new target — notification service extension (Slice C)
└── Sources/NotificationService.swift

App/Settings/DevicesPane.swift     # new — the paired devices, and whether each may notify

project.yml                        # agents-bridge becomes app-like; RemoteNotify added;
                                   # aps-environment and iCloud entitlements; NSE App Group
```

**Structure Decision**: the existing layout is kept and extended; no new package and no new
top-level directory beyond the `RemoteNotify` extension target, which has to be its own target
because that is what an extension is.

The one split worth naming: **everything that decides lives in `AgentsKitCore`, and everything
that displays lives in an app.** `Routing.swift` is a pure function from presence and a need to
a surface — no clock of its own, no I/O, no platform — which is what lets the whole of Story 2
and Story 3 be exhausted in unit tests without a phone in the room. `MacNotifier` and
`DeviceNotifier` do as they are told and decide nothing, which is FR-012 expressed as a file
boundary rather than as a comment.

## Phasing

Three slices, from research §12. Each is independently shippable and the order is chosen so
that what is gated on a developer portal and an unproven spike comes last, not first.

| Slice | What lands | Needs | Proves |
|---|---|---|---|
| **A** | Need, Presence, the ladder, `presence/report`, `attention/changed`, Mac banner | nothing new at all | US1 partly, US3 whole, US4 on the Mac. A banner when you are in another app. |
| **B** | Remote reports presence; shows and withdraws a local notification over the LAN bridge | a real iPhone and a real iPad | US2 whole — the routing walked on hardware, which is the only way to know it is right |
| **C** | 005's substrate, the app-like bridge, the mailbox, the push, the extension | CloudKit container, T002 spike, portal | US1 whole, US5 whole. Reaching a pocket on a train. |

Slice C's first task is 005's T002 and it is a gate: if a nested app-like bundle cannot reach
the private database, stop and re-plan rather than working around it.

## Amendments this plan asks the spec for

Three, each from a finding rather than from taste. None is made unilaterally; they are listed
here for `/speckit-clarify` or for a decision before `/speckit-tasks`.

1. **FR-010** — "when no device can be delivered to, deliver at the Mac" has no answer when
   there is no window either. Amend to: the need waits, and the next surface to connect is told
   through `attention/pending`. Nothing is lost because the need lives in the record, not in
   the notification. (Research §6.)
2. **SC-003** — "cleared from every device within 5 seconds" cannot hold for a backgrounded
   device off the LAN, because withdrawal needs a silent push and a silent push is throttled by
   design. Amend to: within 5 seconds on any surface in the foreground, and by the time a
   backgrounded device is next opened. (Research §8.)
3. **FR-005(b)/FR-007** — "at the Mac" should say explicitly that it requires a Mac surface to
   be connected, since an unbundled daemon cannot post a banner and a closed window cannot
   either. (Research §5, §6.)

## Complexity Tracking

| Violation | Why needed | Simpler alternative rejected because |
|---|---|---|
| A third process holding CloudKit and the crypto | A restricted entitlement needs an embedded provisioning profile, which a bare Mach-O has nowhere to put | Giving `agentsd` the entitlement means a bundle, a profile, and a network client inside the one process that spawns runtimes and reads files on their behalf. 005 §6 rejected it and the reasoning has not changed. |
| A fourth target (`RemoteNotify`) | The banner's words are assembled on the device after decryption; that is what a notification service extension is for | Sending the words in plaintext is FR-022 gone. Fetching them after the person taps means a banner that says "An agent needs you" every time, which the quickstart already names as a failure. |
| Presence as a protocol, not a sniffed idle time | The ladder asks whether the person is at *this app* and at *this conversation*, which no HID idle measure answers, and iOS has no equivalent to read at all | Reading `CGEventSource` idle time answers a different question and works on one platform of two. Research §4. |
