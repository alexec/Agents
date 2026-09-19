# Implementation Plan: Remotes for iPhone and iPad

**Branch**: `005-mobile-remotes` | **Date**: 2026-09-18 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `specs/005-mobile-remotes/spec.md`

## Summary

A phone that buzzes when an agent is blocked, and takes the answer. An iPad that shows the same three
panes the Mac does. Both from any network.

**Two links, one remote.** On the same network the device and the Mac talk over a direct socket
found by Bonjour: milliseconds, no infrastructure, and the app feels the way it does at the desk.
Off that network they cannot, and the research is clear about why — there is no way for two of a
user's devices to reach each other across the internet on Apple's platforms, since Back to My Mac
went in 2019 with no successor and everything since is link-local or proximity-scoped. So the second
link is not a socket. It is a CloudKit private database used as an encrypted mailbox, with push
wake-ups: reachable from anywhere, no address, no port, no router, no service anyone operates, and
storage on the user's own iCloud quota.

Neither is the optimisation of the other. The direct link is why the iPad on the sofa is pleasant;
the mailbox is why the phone on the train works at all. The device picks, silently, and says which
it got only because the speeds honestly differ (`contracts/transport.md`).

Three decisions make that honest rather than merely convenient. We encrypt the payload ourselves with
CryptoKit rather than trusting `CKRecord.encryptedValues`, because that only keeps Apple out for
users who have Advanced Data Protection on and we cannot require it. Every device holds its own key
pair, so revoking a lost phone is cryptographic rather than a flag. And the notification carries three
short ciphertext fields that a Notification Service Extension decrypts on the device, so the push
service moves the words "rename-refactor needs permission to run `git push`" without ever holding
them.

The shape in the tree is smaller than that sounds. `JSONRPCConnection` already takes any
`LineTransport`, `DaemonClient` already speaks the whole method surface, and `DaemonServer` already
broadcasts to every connection. So the remote is not a protocol change: it is **a third process that
connects to `agentsd` as an ordinary client** and translates its line protocol to and from encrypted
records. `agentsd` gains no listener, no network code and no new attack surface. What it does gain is
three small things around answering — who answered, a failure code that means "somebody beat you to
it", and the same for forms.

The cost, stated up front: a mailbox round trip is seconds, not milliseconds, and after a reboot the
Mac app must be opened once before anything is reachable.

One note on order. 004 is built, and it shipped two columns and a push rather than the three columns
it specified — which is, as it happens, exactly the shape a phone wants. It also built a project lead
and then deleted it, because the layout kept moving underneath it. This plan takes that seriously:
the iOS layout is built and settled against a fake before any of the machinery above is written.

## Technical Context

**Language/Version**: Swift 6.4, Swift 6 language mode, `SWIFT_STRICT_CONCURRENCY: complete`.
Unchanged.

**Primary Dependencies**: Network (Bonjour and the direct link), CloudKit, CryptoKit,
UserNotifications, SwiftUI. All first-party, all already on both platforms. No third-party package
is added, and the research rejected the ones that tempted it (Tailscale needs a tailnet and an SSO
login; a relay we operate is a service the spec forbids).

**Storage**: One new file, `~/Library/Application Support/Agents/devices.json`, holding one record per
paired device — a handful, written whole, exactly as `projects.json` is in 004. Each device's private
key lives in that device's own keychain and never moves. The mailbox in CloudKit is transient: records
are deleted once delivered. `agent.json` and `transcript.jsonl` are untouched, and the daemon remains
the only writer of them.

**Testing**: `swift test` in `AgentsKit`. The envelope — seal, open, reject a tampered record, reject
one sealed to another device — is pure and gets unit tests, as does the bridge's filtering, which is
a function from a notification and a subscription to a decision. The bridge's translation is tested
against `PairedTransport`, the in-memory `LineTransport` that already exists, so a full round trip runs
with no CloudKit and no network. CloudKit itself is behind a protocol with a fake, because a test
suite that needs an iCloud account is a test suite that does not run. What cannot be faked — the
entitlement spike, push latency, the extension's memory ceiling — is measured on device and written
down, not asserted.

**Target Platform**: macOS 27 on the Mac; iOS 27 and iPadOS 27 on the remotes, built scene-based
from the first commit because iOS 27 will not launch an app without the UIScene lifecycle. One
person's own devices, all signed into one Apple Account with iCloud Drive on.

**Project Type**: Desktop app, a helper executable, a new helper bundle, and a new mobile app with a
notification extension. Four shipped things where there were two.

**Performance Goals**: A permission request reaches the phone within 5 seconds (SC-001). An answer
reaches the Mac within 1 to 3 seconds (SC-002, see the deviation below). A conversation with an hour
of transcript opens to something readable in under 2 seconds on a mobile connection (SC-005), which
the existing `before`/`limit` paging already makes possible.

**Constraints**: Nothing readable may leave the two devices (FR-003, SC-009). No account beyond the
Apple Account they already have, no sign-up, no typed address, no router change (FR-002, FR-007). No
login item and nothing installed, which 001 promised and the README repeats. A user who never pairs a
phone must see the app exactly as it is today (FR-038). CloudKit's budget is real: 1 MB a record,
400 records an operation, about 40 requests a second, and throttling on both sides — so transcript
goes in coalesced chunks and never per token.

**Scale/Scope**: 38 functional requirements over 3 user stories. One person, one Mac, one or two
remotes, tens of projects, hundreds of agents.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

`.specify/memory/constitution.md` is still the Spec Kit template. No principles have been written for
this project, by the user's explicit decision, so there is nothing to check against and no violation
can be claimed.

The rules in force are the ones 001 recorded and 003 and 004 carried forward. This is the first
feature that strains them, so each one gets an answer rather than a tick:

| Rule in force | How this feature stands with it |
|---|---|
| One person, one Mac, no accounts | **Held, narrowed.** Still one person and still no account we invent. But it now requires the Apple Account they already have, signed in on both devices with iCloud Drive on. That is a real narrowing and it is written into the spec's assumptions, not smuggled in. |
| No remote access (001) | **Superseded, deliberately.** 001's assumption says "there is no sharing, no remote access and no multi-user behaviour *in this feature*". It was scoped to 001. 005 is the feature that changes it, and says so here rather than quietly contradicting it. Sharing and multi-user remain out. |
| The app is a window, the daemon is the owner | **Held.** The bridge owns nothing. It holds no agent state, makes no decisions, and asks the daemon like any other client. Paired devices are the daemon's records in the daemon's directory. |
| One code path for every runtime | **Held.** Nothing here knows what a runtime is. |
| Logic where `swift test` can reach it | **Held.** The envelope, the filter and the translation are in the kit with fakes. CloudKit is behind a protocol. |
| Nothing installed, no login item | **Held, at a cost.** The bridge is spawned by `agentsd` as `agentsd` is spawned by the app. No `SMAppService`, no background item in System Settings. The price is that after a reboot the Mac app must be opened once, and that goes in the spec. |
| The daemon is the only writer | **Held.** The bridge writes ciphertext to a mailbox it then empties. Every durable fact still goes through the daemon. |
| An option we do not understand is skipped, not guessed | **Held.** `Device` keeps and rewrites unknown fields, as `Agent` and `Project` do. An envelope we cannot open is dropped and logged, never guessed at. |
| The entitlements file is empty by policy | **Broken, and this is the feature that breaks it.** `App/Agents.entitlements` says "the first feature that needs a capability adds it, and says in its spec why". This is that feature. See Complexity Tracking. |

**Re-check after Phase 1**: the design adds one process, one file, three daemon methods and one
notification. It adds no second transport inside `agentsd`, no listener, no background service that
survives a logout, and no field to `agent.json`. The one rule genuinely broken is the empty
entitlements file, which was written to be broken exactly once, with a reason.

## Project Structure

### Documentation (this feature)

```text
specs/005-mobile-remotes/
├── plan.md              # This file
├── spec.md              # What it does
├── research.md          # Fourteen findings, each checked against the tree or Apple docs
├── data-model.md        # Phase 1 output
├── quickstart.md        # Phase 1 output
├── contracts/           # Phase 1 output
│   ├── daemon-api.md    # Three methods, one notification, one failure code, one field
│   ├── transport.md     # The two links, how one is chosen, and the handover between them
│   ├── mailbox.md       # The record shapes, the envelope, and what the crypto promises
│   └── ui.md            # What the phone and the iPad show, and what each promises
├── checklists/
│   └── requirements.md
└── tasks.md             # Phase 2 output (/speckit-tasks, not created here)
```

### Source Code (repository root)

```text
Packages/AgentsKit/
├── Package.swift                    # Grows: .iOS("27.0"), a second target
└── Sources/
    ├── AgentsKitCore/               # NEW target. Both platforms. Moved, not rewritten.
    │   ├── JSONRPC/                 # MOVED whole: JSONValue, JSONRPCMessage, JSONRPCError,
    │   │                            #   JSONRPCConnection, LineTransport, FDTransport, PairedTransport
    │   ├── Model/                   # MOVED whole
    │   ├── ACP/                     # MOVED: ACPTypes, ContentBlock, SessionUpdate, ToolCallContent
    │   ├── Daemon/DaemonAPI.swift   # MOVED. Method names and DTOs only.
    │   ├── Runtimes/                # MOVED: RuntimeAccount, RuntimeCatalog
    │   ├── Client/
    │   │   ├── DaemonClient.swift   # MOVED, with the transport injected (was socket-only)
    │   │   └── AgentsModel.swift    # NEW. What each notification means, lifted out of the Mac app
    │   └── Remote/                  # NEW
    │       ├── DeviceKey.swift      # P256 pair, kept in the device's own keychain
    │       ├── Envelope.swift       # Seal and open. Pure. The most tested file in the feature.
    │       ├── NetworkLink.swift    # BUILT. Bonjour browse and connect. The direct link.
    │       ├── LinkChooser.swift    # NEW. Start both, take the first, hand over. transport.md
    │       ├── Mailbox.swift        # protocol. CloudKit behind it, a fake beside it.
    │       ├── MailboxTransport.swift # LineTransport over the mailbox. The relayed link.
    │       └── Headline.swift       # The three ≤100-char fields a notification can carry
    └── AgentsKit/                   # macOS only. Depends on Core.
        ├── Daemon/
        │   ├── DaemonCore+Devices.swift  # NEW. list, approve, revoke, announce
        │   ├── DaemonCore+Commands.swift # Grows: answeredBy on the two answer paths
        │   ├── DaemonCore+Dispatch.swift # Grows: three cases
        │   └── DaemonServer.swift        # Untouched. Still AF_UNIX, still the only listener.
        ├── Store/DeviceStore.swift       # NEW. devices.json, read whole, written whole
        ├── Client/SocketTransport.swift  # The socket-and-spawn half that stayed behind
        └── (everything else unchanged)

Bridge/Sources/                      # NEW. The app-like bundle that owns CloudKit on the Mac.
├── main.swift                       # Connects to agentsd as a client. No UI, no NSApplication use.
├── BridgeCore.swift                 # Translate: notifications out, requests in, filtered
├── Subscription.swift               # What this device is watching. Keeps the phone's data small.
└── Poller.swift                     # Every second while an agent is blocked; rarely otherwise

Remote/Sources/                      # NEW. The iPhone and iPad app. Scene-based from commit one.
├── RemoteApp.swift
├── Projects/                        # 004's two columns and a push, at three sizes
├── Chat/                            # Transcript, prompt bar, attachments
├── Permission/                      # The question, and the answer
├── Pairing/                         # Announce, and wait to be approved
└── NotificationService/             # The extension. Decrypts the headline. No network.

App/Sources/
├── Devices/                         # NEW. The paired device list, approve and revoke
└── AppModel.swift                   # Shrinks: its notification handling moves to Core

App/Agents.entitlements              # No longer empty. See Complexity Tracking.
Bridge/Bridge.entitlements           # NEW. CloudKit, the container, the keychain group
Remote/Remote.entitlements           # NEW. The same, plus aps-environment
project.yml                          # Grows: three targets, an iOS destination, a nested bundle
```

**Structure Decision**: the two thin shells around one library become four shells around two
libraries. The split is by platform and it is a move, not a rewrite: every file going into
`AgentsKitCore` imports only Foundation today, and there is not one `#if os(` in the package to
unpick. Everything that decides anything — what an envelope means, what a device may read, what the
phone is watching, what each notification does to the model — is in the kit where `swift test`
reaches it. The bridge and the two apps draw and carry.

## Key design decisions

### 1. Two links, chosen by the device, above one `LineTransport`

`JSONRPCConnection` takes any `LineTransport`, so a second link costs a file, not a design. The
direct one is `NetworkLink`: Bonjour `_agents._tcp`, `NWListener` on the Mac, `NWBrowser` on the
device, `includePeerToPeer` so an iPad finds it with nothing configured. The relayed one is
`MailboxTransport` over CloudKit. Everything above them — `DaemonClient`, `AgentsModel`, every
screen — cannot tell which it is on.

The device starts both at once rather than trying direct and falling back, because a Bonjour browse
on a network with no Mac on it does not fail, it stays quiet, and a user on a train would watch a
spinner for as long as we were willing to wait. The selection rule, the handover and what the user
is told are in `contracts/transport.md`.

**The mailbox, taken seriously.** CloudKit's private database, one record per message per target
device, deleted once delivered. Not a socket dressed up as one. Everything downstream follows:
transcript in coalesced chunks rather than per token, the phone asking for history rather than being
sent it, and timings quoted in seconds.

The alternative that keeps coming back is a relay we run. It is faster and it is worse: a service that
is down when it is down, a bill, a TLS certificate to renew, and an address in the middle that we
would then have to prove we cannot read. CloudKit is operated by Apple, costs nothing, and bills the
user's own quota.

**One security model across both.** This is the decision that keeps two links from becoming two
designs. The same pairing, the same per-device keys, the same `Envelope` sealing, the same
revocation, on the Wi-Fi at home exactly as on the train. A home network is not a trusted network,
and the direct link gets no discount for being on one — see FR-004c, and the warning in
`research.md` §11 about what the direct link does today.

### 2. The remote is a client, not a protocol

The bridge connects to `agentsd` over the Unix socket that exists, using `DaemonClient`, and gets the
entire method surface for nothing. No second listener, no network code in the process that spawns
agents and runs commands on their behalf, no new attack surface on the thing that must not grow one.

This is the decision the rest of the feature rests on. It is why 004's project methods, 003's ACP
coverage and anything 006 adds arrive on the phone without being ported: they are already in
`DaemonAPI`, and the bridge does not know what they mean.

### 3. We encrypt it ourselves

`CKRecord.encryptedValues` keeps Apple out only for users who have Advanced Data Protection switched
on, which we cannot require and cannot detect. FR-003 promises every user that nothing in the middle
can read anything. So the promise has to be ours: CryptoKit, sealed to the target device's public
key, in ordinary record fields.

Two things fall out of it that we would have wanted anyway. Our ciphertext can ride a push payload,
which Apple's encrypted fields cannot, because the server has to be able to copy them. And the
guarantee no longer varies between users.

### 4. Every device holds its own key, so revocation is cryptographic

The tempting shortcut is one symmetric key synced through iCloud Keychain — end-to-end encrypted by
default, no pairing UI at all. It cannot be taken back from one device, so it fails FR-010 the moment
a phone is lost.

Per-device key pairs make revoking real: nothing is sealed to that device again, and the mailbox it
could still read is emptied. "Holds nothing readable afterwards" is a statement about keys, not about
a flag in a list.

The sharper reason is that **CloudKit authenticates the account, not the device**, with or without
Advanced Data Protection. Every device signed into the Apple Account can read that private database —
the old iPad in a drawer included. Without per-device sealing, approving a device would mean nothing,
because nothing would have been withheld from the ones that were never approved.

The key is P256 rather than Curve25519 so the Secure Enclave can hold it, which means it cannot be
extracted from a lost phone at all. CryptoKit's HPKE has a P256 suite; nothing else changes.

### 5. The notification is written on the phone

Three short ciphertext fields ride the push payload through `desiredKeys`; the Notification Service
Extension decrypts them and rewrites the body. Apple's push service carries "an agent needs you" and
the user reads the project and the agent by name.

The extension does no network I/O at all, which is what keeps it inside a memory ceiling of roughly
20 MB. The budget is three keys of about 100 characters, so the headline format is designed to the
budget rather than the budget discovered afterwards. Anything that fails falls back to the generic
body rather than showing nothing.

### 6. The Mac polls, and only while it matters

macOS will not launch a stopped application to deliver a push, so an arriving answer cannot start us
and push on the Mac is not in the critical path. While an agent is blocked on a human the bridge
polls every second and holds a power assertion so an awake Mac does not doze mid-question. Outside
that window it polls rarely and lets the Mac sleep.

It cannot wake a sleeping Mac, and no supported mechanism can. The remote's answer is to say when it
last heard from the Mac.

### 7. Filtering belongs to the bridge

`DaemonServer` broadcasts everything to every connection, which is right for a window on a desk and
wrong for a phone on a metered connection. The bridge holds what each device is watching and forwards
state changes and questions always, transcript only for the agent in front of the user. The daemon's
fan-out stays as simple as it is, and the phone's data bill stays small.

### 8. Three small things change in the daemon

Answering is already first-answer-wins: `answerPermission` removes the pending request from an
actor's dictionary and throws if it has gone. What is missing is who won — so `AnswerRequest` gains
`answeredBy` and the withdrawal notification carries it — and a failure code that says "somebody beat
you to it" instead of reusing `noSuchAgent`, which a phone cannot tell apart from a deleted agent.
The same two changes apply to `elicitations/answer`.

### 9. A user who never pairs a phone sees no change

No device paired means no bridge process, no CloudKit, no entitlement in play, and `shouldExit`
behaving exactly as it does today. The feature is inert until it is asked for. That is the strongest
thing this design has going for it, and it is worth protecting in review.

## Deviations from the spec

Three, all raised rather than absorbed. Each is a spec amendment to make before `/speckit-tasks`, or
a decision to overrule me.

| Spec text | What the research found | Proposal |
|---|---|---|
| **FR-007**: pairing is "an exchange begun at the Mac" | The phone announces itself and the Mac approves. Nothing connects without the tap on the Mac, but the Mac is not where it starts. | Amend to "confirmed at the Mac". The guarantee is unchanged. |
| **SC-006**: a change is on the remote "within 1 second, and the reverse" | A store-and-forward round trip is seconds. 1 second is a socket's number. | **Amended.** SC-006 now carries both figures: 1 second direct, 3 seconds relayed. |
| **FR-004**: prefer a direct connection when one is possible | It is a whole second transport: a listener, a Bonjour service, and a security model that has to match the mailbox's rather than lean on the network. | **Amended, and the direction reversed.** FR-004 now requires both links, with FR-004a to FR-004c covering selection, telling the user, and the one security model. It is built first, not cut last. See `research.md` §11. |

One more thing to note rather than amend: **SC-002's two seconds is tight.** A one-second poll plus a
round trip lands between one and three. It is close enough to build against and measure, and if it
misses, the honest fix is the number, not a faster poll.

## Phasing

**The layout lands first, and gets settled, before the machinery under it is built.** That is not a
general preference, it is the lesson 004 just paid for: its project lead was specified, planned,
built with MCP tools, four safety guards and a held permission flow, and then deleted, because the
layout moved four times underneath it and made it mean something slightly different each time. A
remote is a layout with a great deal of machinery under it, and the machinery here is worse than
004's — an entitlement, a container, a crypto envelope and a push extension are not things to rework
because a screen changed.

So the order is: something to hold, then something to trust.

0. **The spike, two days, in parallel with phase 1 and not in front of it.** Three questions. Can an
   app-like bundle spawned by `agentsd` reach the CloudKit private database and the data protection
   keychain? Apple's guidance is that the app wrapper is how a tool carries a restricted entitlement,
   but their DTS answer says they had not tested it with CloudKit — and check `POSIX_SPAWN_SETSID`
   while there, since detaching the session is the sort of thing that quietly breaks keychain access.
   Does a scene-based iOS app get an APNs token and a subscription push end to end, and how fast?
   Does a three-field `desiredKeys` payload survive without truncation?

   It is first in importance and not first in time: it answers whether the feature can exist, and
   nothing in phase 1 depends on the answer. If it fails, the feature becomes "the Mac app must be
   running", which is a different feature and needs a different spec — and the layout built in
   phase 1 is still the right layout for it.

1. **The layout, on the phone, against a fake.** The iOS app with 004's shape — projects, the project
   page, the push to a conversation — driven by `PairedTransport` and canned data, running on a real
   iPhone and a real iPad. No CloudKit, no crypto, no daemon. The point is to hold it, use it, and
   change it until it is right. Every screen in `contracts/ui.md` exists here, including the question
   and the out-of-touch line, because those are the two that are hardest to judge from a description.

   This is where the feature is decided. It ends when the layout is settled, not when it is written.

2. **The direct link. Built (`b3cf6e8` and after), and not finished.** `NetworkLink` and the
   `agents-bridge` relay: a device on the same network drives the real daemon, which is what turned
   the layout from something driven by canned data into something worth walking the T024 gate with.
   It went before the mailbox because it needs no container, no entitlement and no spike, and the
   spikes were the blocked thing. **It has no pairing and no encryption**, by its own header, so it
   is a development tool until phase 4 reaches it. Nothing ships with it in this state.

3. **P1 — answer from anywhere.** Now the machinery, under a layout that has stopped moving: the
   package split, `Envelope`, `Mailbox`, `MailboxTransport`, `devices.json`, the three daemon changes
   and the notification extension, with a hard-coded approval so pairing does not block it. At the
   end of this a phone buzzes on a train and the agent carries on.

4. **P3 — pairing and revoking, properly, on both links.** The Mac's device list, approve and
   revoke, key rotation, emptying a revoked device's mailbox — **and retrofitting all of it onto the
   direct link**, which is the debt phase 2 took on deliberately. `Envelope` over `NetworkLink`,
   unpaired devices refused at accept, and a revoked device's open connection dropped. FR-004c is
   met here or not at all.

5. **Selection and handover.** Both links exist, so now they have to be chosen between: start both,
   take the first, keep browsing on the relayed one, move across without losing an action in flight,
   and say which link the user is on. `contracts/transport.md`.

6. **P2 — the rest of the remote.** Transcript paging, starting an agent from the project page's
   prompt bar, stopping one, attachments, the archived disclosure. Mostly filling in screens that
   already exist against data that is now real. Last because it is the least blocked: every screen
   is already drawn, and none of it changes what the feature promises.

004 is **built** (`9087a1a`), so nothing here waits on it. What it built is not what its contract
described — two columns and a push, not three columns — and phase 1 copies what shipped. Its project
lead was removed (`c13eb9b`) and does not appear in this feature.

## Complexity Tracking

| Violation | Why needed | Simpler alternative rejected because |
|---|---|---|
| **The entitlements file stops being empty** — CloudKit, an iCloud container, a keychain access group, and `aps-environment` on iOS | The file's own comment says the first feature that needs a capability adds it and says why in its spec. Reaching another device over the internet cannot be done without a channel, and every channel Apple offers is entitled. | There is no unentitled option. The unentitled alternatives are all local-network only (§1 of the research), which is the one thing the user ruled out. |
| **A third process** (the bridge) | `agentsd` is a bare Mach-O with nowhere to embed a provisioning profile, so it cannot hold a restricted entitlement as built. | Wrapping `agentsd` itself would work and would put a network client in the process that spawns agents, reads files and runs commands for them. That is the one process whose blast radius must not grow. |
| **A second library target** | The phone needs the model, the protocol and the client; it cannot have `Process`, `posix_spawn` or `flock`. | `#if os(macOS)` sprinkled through twenty files, in a package that has not one conditional in it today. The split is a move; the alternative is a permanent tax on every file. |
| **`ITSAppUsesNonExemptEncryption: false` is no longer true** | The app ships encryption now. | Nothing to reject — this is a declaration to get right before submission, not a design choice. It needs answering deliberately rather than left at a default that has quietly become wrong. |
