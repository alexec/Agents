# Research: Notifications, Where The Person Actually Is

Twelve findings. Each was checked against this tree or against Apple's documentation, and
each says what it decides. Where a claim could not be verified it says so — 005's research
set that rule and it is worth keeping, because this feature rests on the same machinery and
inherits the same unknowns.

The headline finding is §1, and it changes the shape of the plan. Read it first.

---

## 1. The only channel that can carry a notification is the one that was never built

**Decision**: 021 carries 005's unbuilt half. It is not a dependency to be waited on; it is
most of this feature's work.

005 shipped one of its two links. `Bridge/Sources/main.swift` and
`AgentsKitCore/Remote/NetworkLink.swift` exist and work: Bonjour, an `NWListener`, lines
relayed to `agentsd` over its Unix socket. Everything else — `Device`, `DeviceKey`,
`DeviceStore`, `Envelope`, `Headline`, `Mailbox`, `CloudKitMailbox`, `MailboxTransport`, the
`devices/*` methods, the CloudKit container, the three spikes that gate them — is unbuilt.
Checked task by task: of 005's 86 tasks, T001–T005 and T024e–T043 and everything after are
all open.

That would merely be inconvenient, except for this: **the link that was built cannot deliver
a notification at all, in the only case that matters.** It is a TCP connection held open by a
running foreground app. An iOS app in the background loses it in seconds, and a suspended one
has none. So the direct link can tell a device something exactly when the person is already
looking at the device — which is the one case FR-005(a) says to stay silent in.

There is no version of this feature that works over the LAN link. The mailbox and the push
are not the ambitious option; they are the only option. The user chose "anywhere — real
push", and that choice turns out not to have been a choice.

**What follows for the plan**: the phasing in §12 puts everything that needs no new
infrastructure first, so that the routing is proven before the substrate is begun, and so
that something useful ships while the spikes are still gated on hardware and a developer
portal.

**Alternatives considered**: a background-refresh poll on the device (`BGAppRefreshTask` runs
at the system's discretion, minutes to hours apart — it cannot meet five seconds and is not
meant to); keeping a VoIP-style socket alive (PushKit is for calls, and using it for anything
else is grounds for rejection); a local notification scheduled in advance (nothing is known
in advance).

## 2. The routing decision belongs to the daemon, and nothing else may make it

**Decision**: `DaemonCore` computes the need, holds presence, runs the ladder, and broadcasts
the resolved answer. Every surface — window, phone, iPad — obeys and decides nothing.

FR-012 says this, and the code agrees it is the only workable place. The daemon already holds
every input: agent state, pending permissions, pending elicitations, and reports. It already
broadcasts `agent/permission` and `agent/changed` to every connection. And it is the only
process that outlives the window: `shouldExit` is `connectionCount == 0 && !isHoldingAgents`,
and `isHoldingAgents` counts a pending permission explicitly, so the daemon is guaranteed to
be alive for exactly as long as a need exists (`DaemonCore+Lifetime.swift:8`).

The alternative — each surface deciding whether it is the one that should alert — is how two
devices both buzz. It needs every surface to know about every other surface, which is a
presence protocol anyway, minus the single decider.

**This also settles where the bridge sits.** The bridge seals and sends. It does not choose a
recipient. That keeps it the dumb courier 005 made it, and keeps the one process that reads
files and spawns runtimes free of any new policy.

## 3. The whole resolved fact, in one notification, per need

**Decision**: one new notification, `attention/changed`, carrying `{ needID, need, to }`.
`need: nil` means it is over. `to` is the surface that should be showing it, or nil for none.

This is the idiom the codebase already uses four times and states the reason for in three
doc comments: carry the whole resolved fact rather than a delta, "so two windows cannot then
disagree, and one that missed a notification is put right by the next rather than drifting"
(`DaemonAPI.swift:113`, and again at `:124`). `project/changed` is the one the other two cite.

It also makes a move — FR-017's withdraw-here-and-deliver-there — **one** notification rather
than two that could be seen in either order or half-lost. Every surface applies the same
idempotent rule:

```
if to == me and I am not showing it  → show it
if to != me and I am showing it      → withdraw it
if need == nil and I am showing it   → withdraw it
```

A surface that reconnects after missing everything asks once and is put right, exactly as a
window is for costs and projects. That is why there is a matching `attention/pending` method
beside `permissions/pending` and `elicitations/pending`.

**Alternatives considered**: separate `attention/deliver` and `attention/withdraw` (two facts
to order and two chances to leave a notification stranded); addressing the directive only to
the chosen surface (the losers then never learn to withdraw, which is FR-016's whole job).

## 4. Presence is reported, never sniffed

**Decision**: every surface calls `presence/report { watching, active }` when it comes to the
front, goes behind, changes conversation, or sees input after a quiet spell. The daemon stamps
the time of arrival itself.

The daemon must not read the Mac's input idle time directly, though it could:
`CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: ...)` works from a
background process with no entitlement. Two reasons not to.

First, it answers the wrong question. Idle time says whether somebody is touching *the Mac*.
The ladder needs to know whether they are touching *this app*, and whether the conversation in
front of them is the one that needs them. A person editing in another app for ten minutes is
active by every HID measure and is exactly the person FR-005(b) wants to send a banner to.

Second, it is one-sided. The iPhone and iPad have no equivalent the Mac can read, so a reported
signal has to exist for them regardless; having two mechanisms where one will do is two rules
to keep in step.

**The daemon stamps the time, not the sender.** The spec's edge case asks for this — a device
with a fast clock must not win every race — and it costs nothing, because the report arrives
over a live connection.

`AgentsModel.watching` already exists in shared Core and is already set by both apps
(`AppModel.swift:144`, `RemoteModel.swift:38`). Both know what they are watching; neither has
ever told anyone. That is the whole of the client-side change for the watching half.

**This supersedes 005's T043**, which put a per-device `watching` subscription in the bridge's
memory. One place, in the daemon, serving both the routing here and the transcript filtering
005 wanted it for.

## 5. `agentsd` cannot post a notification, and must never try

**Decision**: the Mac banner is posted by the **Agents app**. The daemon decides; the window
displays.

`agentsd` is `type: tool` in `project.yml` — a bare Mach-O with no bundle. Touching
`UNUserNotificationCenter.current()` from an unbundled process throws
`NSInternalInconsistencyException: bundleProxyForCurrentProcess is nil: mainBundle.bundleURL`,
which is a crash and not a failed call. This is well documented on Apple's forums for exactly
this shape of process.

`CFUserNotificationDisplayNotice` is the old escape hatch and is the wrong thing: it puts a
modal alert on screen rather than a banner in Notification Centre, and it cannot be withdrawn.

So the Mac rung of the ladder requires a window to be connected. Which leads to §6.

## 6. The Mac rung needs a window, and when there is none the ladder moves on

**Decision**: "at the Mac" is judged as *a Mac surface is connected, frontmost, and was
interacted with within the idle threshold*. No window connected means the Mac is not a
candidate, and the device rungs take it.

This is the right behaviour on its own terms, not merely a concession to §5. A person whose
Agents window is not even running is a person who is not going to see a banner in it, and
whose phone is the honest place to reach them. The user's own sentence — "away from the chat"
— covers it: an app that is not running is as away from the chat as a train is.

**One spec amendment falls out**, and it should be made rather than papered over. FR-010 says
that when no device can be delivered to, the system delivers at the Mac "so the news is never
simply dropped". If there is also no window, there is nowhere at all. The honest amendment:

> When no surface can be delivered to, the need waits. Nothing is lost, because the need lives
> in the daemon's record and not in the notification: the next surface to appear is told about
> it on connect, through `attention/pending`.

That is true today for permissions — `permissions/pending` exists for precisely this — and it
costs nothing to make true here.

**Alternatives considered**: making the bridge post the Mac banner once it is an app-like
bundle (§7). Its bundle URL is not nil, so it would not crash — but whether a headless
app-like bundle can obtain notification authorisation at all is **unverified**, and it would
put a second notification poster in a second process. Rejected on both counts.

## 7. The bridge has to change shape before it can carry anything sealed

**Decision**: `agents-bridge` becomes an app-like bundle, and this is a gate, not a task.

`com.apple.developer.icloud-services` is a restricted entitlement that must be authorised by
an embedded provisioning profile, and a `type: tool` target is a bare Mach-O with nowhere to
embed one. 005 §6 worked this out and Apple's DTS answer is an application target with the
principal class, storyboard and delegate stripped.

005 recorded the risk plainly and it is inherited whole: **DTS recommended the wrapper but had
not tested it with CloudKit.** If a nested app-like bundle cannot reach the private database,
the architecture collapses to "the Mac app must be running", which is the premise gone. That
is 005's T002, it is still open, and it is still the first thing to do before any of Phase 3
here.

The project has a real team — `DEVELOPMENT_TEAM: 6T4RVD5724` in `project.yml` — so the portal
work is possible. The container does not exist yet (005 T001).

**Outcome, 2026-09-20 (T056).** The wrapper works. `agents-bridge` became `type: application`
with `Bridge/Info.plist` (no principal class, storyboard or delegate; `LSUIElement` and
`LSBackgroundOnly`), `Bridge/agents-bridge.entitlements` carrying `icloud-services:
[CloudKit]` and the container identifier, and `CODE_SIGN_ENTITLEMENTS` pointing at it.
`xcodebuild -scheme agents-bridge -allowProvisioningUpdates` signed it under
"Mac Team Provisioning Profile: com.alexecollins.agents.bridge" with the profile embedded
and both iCloud entitlements in the signature. `agents-bridge --spike` then reported
`accountStatus == available`, saved a zone, and the record write failed with
`CKError 5/1014 "Bad Container": Couldn't get container configuration from the server
for "iCloud.com.alexecollins.agents"` — which is the **server** saying the container is
not registered, not the entitlement being refused. The bundle reached CloudKit as itself;
what was missing was T057, the portal step.

**Passed, 2026-09-21 00:32 UTC.** The container turned out to exist already — Xcode's
`-allowProvisioningUpdates` had registered it with the bridge's App ID — and opening it once
in the CloudKit Console (`icloud.developer.apple.com`, DEVELOPMENT) was what made it
answer. The spike then wrote `spike-74F96EE7…`, read it back and deleted it:
`spike: ok — the private database is reachable from this bundle`. **The gate is open.** A
device build of `Remote` with `-allowProvisioningUpdates` then registered
`com.alexecollins.agents.remote` and `.remote.notify` and the App Group
`group.com.alexecollins.agents` by itself, and both signatures carry aps-environment,
CloudKit with the container, the App Group and the shared keychain group.

## 8. Withdrawing a notification on a device the person is not holding is best-effort

**Decision**: withdraw three ways, and amend SC-003 to say what each is worth.

`UNUserNotificationCenter.removeDeliveredNotifications(withIdentifiers:)` is the only way to
take a banner back, and only the app on that device can call it. So:

| When | How | What it is worth |
|---|---|---|
| On the surface where it was answered | in-process, immediately | Instant. |
| On another surface in the foreground | `attention/changed` over its live link | Sub-second on the LAN; seconds through the mailbox. |
| On a backgrounded or suspended device | a silent push (`shouldSendContentAvailable`) waking the app to call `removeDeliveredNotifications` | **Best effort.** |

That third row is the honest one. A silent push is low priority: delivered at the system's
discretion, coalesced one-deep so a newer one discards the one waiting, and not delivered at
all to a force-quit app. 005 §5 established this while arguing that the *alert* push must not
be silent, and the same fact bites here in the other direction.

Two things make it survivable. The banner is replaced rather than duplicated, because
`CKSubscription.NotificationInfo.collapseIDKey` sets `apns-collapse-id`, which APNs uses to
coalesce unseen notifications — so we give every need a stable id and a stale banner is
overwritten by the next one for the same need rather than stacking. And the app sweeps on
every foreground: any delivered notification whose need the daemon no longer lists is removed
on the spot, so the worst case is a stale banner until the person picks the device up, at
which point it is gone before they have read it.

**Recommended amendment to SC-003**: "A need met on one surface is cleared from every surface
in the foreground within 5 seconds, and from a backgrounded device by the time it is next
opened."

**Alternatives considered**: withdrawing from the Notification Service Extension. The
extension does run before display and can reach the notification centre — but it only runs for
a push that will show an alert, so a withdrawal would have to announce itself with a banner to
remove one. Self-defeating. The entitlement that would allow an alert push to be suppressed,
`com.apple.developer.usernotifications.filtering`, is applied for rather than granted (005 §5).

## 9. The three thresholds the spec deferred

**Decision**: the numbers below, each with the reason it is that number rather than another.
All four live in one place so they can be changed in one place, and none is read from more than
one file.

| Threshold | Value | Why |
|---|---|---|
| Mac idle before "away" (FR-007) | **120 s** | Must be longer than reading a diff and shorter than a cup of tea. Under a minute and scrolling a long transcript would route your own agent's question to your pocket; over five and a genuine departure sends nothing anywhere for five minutes. |
| Device staleness horizon (FR-008) | **10 min** | How long a device stays evidence of where you are. Long enough to survive putting the iPad down to think; short enough that yesterday's iPad does not out-rank today's phone. Beyond it the FR-009 default takes over, which is the safe direction to fail in. |
| Settling pause at the Mac (FR-014) | **20 s** | Only ever applies when the person is demonstrably at the Mac, so the cost of waiting is low and the benefit — not banner-ing somebody who is two seconds from looking — is real. Never applies when they are away (FR-013). |
| Re-alert interval (FR-018) | **5 min** | The damper on following the person between devices. Ten moves in five minutes produce one further alert, which is SC-006's "at most two" with room to spare. |

These are starting values, and the plan says so. They are measurable against real use and
expected to move once; what must not move is that there are four of them and they live
together.

## 10. What a need is, and when it is one

**Decision**: a need is derived, never stored, exactly as `AgentGroup` is. It is computed from
the same facts the screen already groups by, and there is no second definition.

FR-001 insists on this, and `Agent.needsAPerson` already exists in Core
(`AgentGroup.swift:108`):

```swift
var needsAPerson: Bool {
    state == .waitingOnUser || (state == .finished && report?.outcome.needsAPerson == true)
}
```

That is precisely the two triggers the user chose and precisely nothing else. So the need's
*existence* is free. What has to be added is its **identity**, because FR-003 counts live
notifications per need and the spec's edge cases turn on "the same agent asking twice is two
needs".

The identity is the thing being answered, not the agent:

| Trigger | Need id | Ends when |
|---|---|---|
| A permission question | the `permissionID` | answered, or withdrawn by the daemon |
| An elicitation form | the `requestID` | answered, or withdrawn |
| A report that needs a person | the agent id plus the report's timestamp | the agent leaves `finished`, or is stopped or archived |

All three already pass through `DaemonCore` at a single point each — `DaemonCore.swift:528`
and `:537` for permissions, `DaemonCore+Commands.swift:810` for elicitations, and
`DaemonCore.move` at `DaemonCore.swift:291` for every state change. Nothing new has to be detected; the needs
fall out of code that already runs.

## 11. What goes in the banner, and what must not

**Decision**: three sealed fields, as 005's `Headline` already specifies, and no fourth.

`desiredKeys` takes **at most three keys**, each of which "may be truncated" past 100
characters, which after base64 and AES-GCM overhead leaves roughly 45–70 bytes of plaintext
each (005 §5, and its T004 spike exists to measure the real figure rather than trust the
documentation). That budget is what decides the banner's shape, not the other way round:

- `h1` — the project's folder name.
- `h2` — the agent's title.
- `h3` — what is wanted, in a few words: "wants to run `git push`", "needs an answer", "stuck".

FR-004's "in enough detail to decide whether to act now" is met by those three and cannot be
met by more; anything longer is read after tapping, over the link, from the daemon.

No plaintext field may name a project, an agent, a folder, a tool or a command. That is 005's
rule for the mailbox record and it holds unchanged here — the alert body that APNs sees is a
generic placeholder, and the extension replaces it after decrypting.

**The placeholder is not optional.** A push with no alert body is sent at lower priority and
would not reach the extension at all (005 §5). SC-001's five seconds rests on the alert push.

## 12. The order to build it in

**Decision**: three slices. Everything that needs no new infrastructure goes first, and the
substrate that is gated on a portal and a spike goes last.

**Slice A — the decision, and the Mac.** `Need`, `Presence`, the ladder, `presence/report`,
`attention/changed`, `attention/pending`, and the Agents app posting and withdrawing a Mac
banner. No new target, no entitlement, no device, no account. Delivers real value on its own:
an agent that needs you reaches you while you are in another app. Every rule in the spec except
the device rungs is testable here, in unit tests, with a fake surface.

**Slice B — the devices, on the LAN.** The Remote app asks for notification permission, reports
its presence, and shows and withdraws a local notification when `attention/changed` names it.
Over the existing bridge, so the iPad-versus-iPhone routing is walked on real hardware — which
is the only way to know it is right — before a line of CloudKit is written. §1 is honest that
this does not yet work while the app is backgrounded. It is not the shipping path; it is the
gate on the routing being right.

**Slice C — the substrate, and real push.** 005's T001–T004 spikes, the container, the
app-like bridge bundle, `DeviceKey`, `Device`, `DeviceStore`, `Envelope`, `Headline`,
`Mailbox`, `CloudKitMailbox`, the notification service extension, and the silent-push
withdrawal. The largest slice by far, and the one whose first task can fail in a way that
stops the feature (§7).

This ordering is the lesson 005 learned in public and wrote down in its own §11: the direct
link went first because the machinery was blocked and the layout was not settled, and that
turned out to be the right call. It also honours the rule about settling the shape before
building depth underneath it.

---

## Sources

- [`removeDeliveredNotifications(withIdentifiers:)`](https://developer.apple.com/documentation/usernotifications/unusernotificationcenter/removedeliverednotifications(withidentifiers:))
- [Remotely dismissing notifications on iOS](https://developer.apple.com/forums/thread/774856)
- [`CKSubscription.NotificationInfo.collapseIDKey`](https://developer.apple.com/documentation/cloudkit/cksubscription/notificationinfo-swift.class/collapseidkey)
- [`shouldSendContentAvailable`](https://developer.apple.com/documentation/cloudkit/cksubscription/notificationinfo-swift.class/shouldsendcontentavailable)
- [Can UserNotifications be used in a command line program?](https://developer.apple.com/forums/thread/724249)
- [Is it possible to use UNUserNotificationCenter from a LaunchAgent?](https://developer.apple.com/forums/thread/679326)
- [`CGEventSource.secondsSinceLastEventType`](https://developer.apple.com/documentation/coregraphics/cgeventsource/secondssincelasteventtype(_:eventtype:))
- [Technical Q&A QA1917: Debugging issues with CloudKit subscriptions](https://developer.apple.com/library/archive/qa/qa1917/_index.html)
