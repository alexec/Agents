# Implementation Plan: The iPad Remote

**Branch**: `013-ipad-app` | **Date**: 2026-09-19 | **Spec**: [spec.md](./spec.md)

**Input**: Feature specification from `specs/013-ipad-app/spec.md`

## Summary

Feature 005 designed both remotes and built a fifth of one. This plan finishes the part that
matters, on one device: an iPad that is told when an agent is blocked, that can answer from
the notification itself, and that shows everything the Mac's window shows about the work.

**Almost none of the design is new.** 005's research stands — there is no first-party way for
two of a person's devices to reach each other over the internet, so the relayed link is a
CloudKit private database used as an encrypted mailbox, woken by an alert push whose words are
assembled on the device by a Notification Service Extension. The bridge is still a third
process that connects to `agentsd` as an ordinary client. This plan inherits all of it
(`specs/005-mobile-remotes/research.md`, `contracts/transport.md`, `contracts/mailbox.md`)
rather than restating it.

Three things are genuinely new here, and they are what Phase 0 researched:

1. **Answering from the notification.** 005 stopped at "tapping it opens that agent". FR-008
   says the answer happens on the notification. That means notification *actions*, which are
   registered statically and up front, while a permission's options arrive per request and are
   named by the runtime. The resolution is to key actions on `PermissionOption.Kind` — a closed
   vocabulary of four — and have the service extension stash the decrypted option map in a
   shared app group so the action handler knows which `optionID` a tap meant. See
   `contracts/notification-actions.md`.
2. **Parity with teeth.** FR-021 makes anything the Mac shows and the iPad does not a defect
   unless the spec names it. That needs a list, and the list has to be maintainable, because the
   Mac has grown four features since 005 was written. See `contracts/parity.md`.
3. **The read-only half of the inspector.** FR-020a and FR-020b bring a touched file and a
   produced document across. `agents/showFile` and the `agent/showFile` notification already
   exist in `DaemonAPI`, so this is a screen, not a protocol.

**The order is inverted from the spec's priorities, on purpose.** The escalation is P1 in value
and last in the build, because everything underneath it — pairing, device keys, the envelope,
the mailbox, the bridge as a real process — is unbuilt. Meanwhile the parity work (US2) is
testable today over the direct link that already exists. So the two run as parallel tracks:
the screens are built and settled against a real Mac on the same network while the CloudKit
spikes and the transport are done behind them. That is the same discipline 005 applied when it
built the layout against a fake before writing any machinery, and for the same reason: 004's
project lead was deleted because the layout kept moving underneath it.

**The cost, stated up front.** This feature does not finish feature 005. The iPhone is not
judged, and 005 stays open holding what is still owed. And the iPad is the device that makes
the relayed link's seconds most obvious — a tablet on a sofa feels like a desk, and a desk that
takes three seconds to answer feels broken. `contracts/transport.md`'s rule that the person is
told which link they are on is doing more work on an iPad than it did on a phone.

## Technical Context

**Language/Version**: Swift 6.4, Swift 6 language mode, `SWIFT_STRICT_CONCURRENCY: complete`.
Unchanged.

**Primary Dependencies**: Network, CloudKit, CryptoKit, UserNotifications, SwiftUI. All
first-party and all already named by 005. This feature adds no dependency 005 did not.

**Storage**: `~/Library/Application Support/Agents/devices.json`, as 005 specified. New in this
feature: a **shared app group container** on the iPad, holding one short-lived record per
outstanding question — the option map the notification action needs — deleted on answer or
expiry. It holds no transcript and nothing that outlives the question.

**Testing**: `swift test` in `AgentsKit`. New pure things worth unit tests: the option-map
projection from `PermissionRequest` to a notification category, the category registry, and the
staleness rule for the app group store. What cannot be faked — whether a notification action
launches the app when it has been force-quit, whether a CloudKit write completes inside the
action handler's budget — is measured on device and written down.

**Target Platform**: iPadOS 27 is what is judged. iOS 27 on iPhone must keep building, installing
and launching (FR-033) and is not judged. macOS 27 on the Mac, unchanged.

**Project Type**: Desktop app, a daemon, a bridge bundle, a mobile app, and now a notification
service extension. Five shipped things.

**Performance Goals**: SC-001, a notification within 5 seconds of the request, on the relayed
link. SC-002, answered from the notification with the agent resuming within 2 seconds. SC-007,
an hour of transcript readable within 2 seconds of opening.

**Constraints**: Everything 005 constrained, unchanged — nothing readable leaves the two
devices, no account we invent, no login item, CloudKit's real budget. New: the notification
action handler runs in a background launch with a few seconds of wall clock and no user
attention, and it has to either deliver the answer or say it did not (FR-013).

**Scale/Scope**: 39 functional requirements over 4 user stories. One person, one Mac, one iPad.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

`.specify/memory/constitution.md` is still the unfilled Spec Kit template. No principles have
been written for this project, so there is nothing to check against and no violation can be
claimed. The rules actually in force are the ones 001 recorded and 003, 004 and 005 carried
forward, and 005's plan already answered each one for the remote architecture. Only what 013
changes is re-answered here.

| Rule in force | How this feature stands with it |
|---|---|
| One person, one Mac, no accounts | **Held as 005 narrowed it.** The Apple Account they already have, iCloud Drive on. Nothing further. |
| The app is a window, the daemon is the owner | **Held.** FR-030 restates it. The iPad runs nothing and writes nothing. |
| One code path for every runtime | **Held, and newly load-bearing.** The notification actions key on `PermissionOption.Kind`, which every runtime already maps into. Nothing in this feature knows a runtime's name. |
| Logic where `swift test` can reach it | **Held.** The option-map projection and the category registry are pure and live in `AgentsKitCore`. |
| Nothing installed, no login item | **Held, at 005's stated cost.** The bridge is spawned by `agentsd`. After a reboot the Mac app must be opened once. |
| The daemon is the only writer | **Held.** The new app group store on the iPad is a cache of one outstanding question, deleted on answer. It is not a record of anything. |
| An option we do not understand is skipped, not guessed | **Held, and it is why the action design works.** A `PermissionOption` whose `kind` is `.unknown` gets **no** notification action. It is shown in the app, where its real name can be read, and the notification says there is something to look at (FR-010). We never guess what an unnamed option does and then offer it as a one-tap grant. |
| The entitlements file is empty by policy | **Already broken by 005, with a reason.** This feature adds nothing to `App/Agents.entitlements` beyond what 005's plan justified. |

**New tension, recorded rather than resolved by assertion.** 005's FR-012 says a remote must
require the device's own unlock before showing any agent content. A notification banner on a
locked iPad shows the project, the agent and what is being asked. These are in genuine conflict,
and the resolution is in `research.md` §4: we do not suppress the banner and we do not weaken
FR-012 — we let the system's own "show previews" setting govern it, treat the headline as the
one thing deliberately shown when locked, and keep every option requiring
`authenticationRequired` except the least dangerous. This is a decision the user should see
rather than one this plan should make quietly.

**Re-check after Phase 1**: the design adds one extension target, one app group, one contract
and a screen. It adds no daemon method that 005 did not already specify, no field to
`agent.json`, and no second writer.

## Project Structure

### Documentation (this feature)

```text
specs/013-ipad-app/
├── plan.md                      # This file
├── spec.md                      # What it does
├── research.md                  # Phase 0. New findings only; 005's are cited, not restated
├── data-model.md                # Phase 1. What changes on top of 005's model
├── quickstart.md                # Phase 1. How to prove it works
├── contracts/
│   ├── notification-actions.md  # The answerable notification. The new one.
│   └── parity.md                # FR-021's list: what the Mac shows, and where it is on iPad
├── checklists/
│   └── requirements.md
└── tasks.md                     # Phase 2 output (/speckit-tasks, not created here)
```

Inherited and not copied: `specs/005-mobile-remotes/research.md`,
`contracts/transport.md`, `contracts/mailbox.md`, `contracts/daemon-api.md`,
`contracts/ui.md`, `data-model.md`. Where 013 changes one of them, `data-model.md` says so.

### Source Code (repository root)

```text
Packages/AgentsKit/Sources/AgentsKitCore/
├── Remote/                          # 005's, mostly unbuilt. NetworkLink.swift exists.
│   ├── DeviceKey.swift              # 005 T029
│   ├── Device.swift                 # 005 T030
│   ├── Envelope.swift               # 005 T031
│   ├── Headline.swift               # 005 T032, GROWS: carries the option map (contracts/)
│   ├── Mailbox.swift                # 005 T033
│   ├── CloudKitMailbox.swift        # 005 T034
│   ├── MailboxTransport.swift       # 005 T035
│   ├── LinkChooser.swift            # 005, direct vs relayed, unbuilt
│   └── Escalation.swift             # NEW. A question projected to what a banner can carry.
├── Notifications/                   # NEW, both platforms
│   ├── ActionCategory.swift         # Kind → action. Pure. The registry.
│   └── OutstandingQuestion.swift    # What the extension leaves for the action handler
└── Client/AgentsModel.swift         # Built. Grows nothing here.

Packages/AgentsKit/Sources/AgentsKit/   # macOS only
├── Daemon/DaemonCore+Devices.swift  # 005 T037
├── Daemon/DaemonCore+Commands.swift  # answeredBy, alreadyAnswered — renumbered, see research §7
└── Store/DeviceStore.swift          # 005 T036

Bridge/Sources/                      # Exists, started by hand, unsealed, unpaired
├── main.swift                       # GROWS: refuse unpaired (005 T024f), spawned not manual
├── BridgeCore.swift                 # 005 T044
├── Subscription.swift               # 005 T043
└── Poller.swift                     # 005 T045

Remote/Sources/                      # Exists: 14 files, phone-shaped, fake-or-local
├── Pairing/                         # NEW. Announce, wait to be approved.
├── NotificationService/             # NEW TARGET. Decrypt the headline, stash the option map.
├── Permission/PermissionSheet.swift # Exists. GROWS: answeredBy, already-answered outcome.
├── Chat/                            # Exists. GROWS: plan, file view, document view
│   ├── PlanView.swift               # NEW. FR-017
│   ├── FileView.swift               # NEW. FR-020a, read only
│   └── DocumentView.swift           # NEW. FR-020b, read only
└── Projects/                        # Exists. GROWS: workflows listed (parity.md)

App/Sources/Devices/                 # NEW. Approve and revoke, on the Mac.

Remote/Remote.entitlements           # NEW. iCloud, container, keychain group, aps-environment
Bridge/Bridge.entitlements           # NEW. iCloud, container, keychain group
project.yml                          # GROWS: the extension target, app group, entitlements
```

**Structure Decision**: unchanged from 005. The split into `AgentsKitCore` (both platforms) and
`AgentsKit` (macOS) is built and works; the iOS app links Core and nothing else, which is the
rule that keeps a `Process` or a PTY from ever reaching it. This feature adds one target — the
notification service extension — and fills in the directories 005 named and did not write.

## Key design decisions

### 1. The notification carries the question; the app group carries the answer's meaning

A `UNNotificationAction` is registered at launch, with a fixed title, inside a fixed category. A
`PermissionOption` arrives per request with a runtime-chosen `name` and an `optionID` that means
nothing outside that request. Those two facts do not fit together, and the naive fixes are both
wrong: registering a category per request is not possible before the push arrives, and putting
the option map in the push payload does not fit — `desiredKeys` takes three fields of about a
hundred characters and they are already spent on the headline.

The resolution: actions are keyed on `PermissionOption.Kind`, which is a closed set of four that
every runtime already maps into, so four categories cover every request. The service extension,
which already runs before the banner is shown and already holds the device key, writes the
decrypted `{kind → optionID}` map into a shared app group container. When a tap arrives, the
action handler reads the map and sends the right `optionID`. See
`contracts/notification-actions.md`.

An option whose `kind` is `.unknown` gets no action. That follows the rule already in force — an
option we do not understand is skipped, not guessed — and it is the difference between a
one-tap grant and a one-tap grant of something nobody can name.

### 2. Two tracks, because one of them can start today

Track A is 005's unbuilt machinery: the spikes, device keys, the envelope, the mailbox, the
bridge as a spawned and sealed process, pairing. Track B is what the iPad shows: the plan, the
file, the document, the workflows list, the parity sweep, on the direct link that already works
on the same network.

They meet at the escalation, which needs both. Track B is not blocked on the CloudKit spike
that could sink Track A, which matters, because 005's research is explicit that the spike could
collapse the architecture and nobody should find that out having built nothing else.

### 3. Parity is a list, not an intention

FR-021 promises everything about the work and names the exceptions. An intention cannot be
tested and rots the first time the Mac grows a screen — and the Mac has grown four features
since 005 was written, one of which (014) is being specified in another session right now.
`contracts/parity.md` is the list: every surface the Mac shows about a project or an agent, its
iPad disposition, and the requirement or the out-of-scope line that justifies it. SC-005 is a
walk down that table.

### 4. The read-only half of the inspector is a screen, not a protocol

`agents/showFile` and the `agent/showFile` notification already exist and the bridge forwards
whatever the daemon says. So FR-020a and FR-020b cost two views on the iPad and nothing on the
Mac. The read-only rule is enforced by there being no path that offers to write: the iPad never
calls a write method, because the iPad has no such screen, not because a flag says no.

## Complexity Tracking

| Violation | Why Needed | Simpler Alternative Rejected Because |
|---|---|---|
| A fifth shipped thing: the notification service extension | FR-008 requires an answerable notification, and the words on the banner must be assembled on the device (005 FR-019 / 013 FR-006). Only an extension can rewrite a push before it is shown. | Showing the generic placeholder always. Rejected: FR-002 requires the notification to name the project, the agent and what is asked, and a banner saying "an agent needs you" cannot be answered from the lock screen with any confidence. |
| A shared app group container on the iPad | The action handler needs the option map and cannot decrypt it in time from the payload. | Putting the map in the push payload. Rejected: `desiredKeys` is three fields of ~100 characters, already spent on the headline (005 research §5). |
| 013 leaves 005 open rather than superseding it | The user's decision, recorded in the spec: 013 is the iPad slice, a later feature is the iPhone slice. | Closing 005 as done. Rejected: it would silently discharge requirements the iPhone still owes. |

## Phase status

- [x] Phase 0: research complete — `research.md`
- [x] Phase 1: design complete — `data-model.md`, `contracts/`, `quickstart.md`
- [ ] Phase 2: tasks — run `/speckit-tasks`
