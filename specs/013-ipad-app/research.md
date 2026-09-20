# Research: The iPad Remote

Nine findings. Feature 005's fourteen still stand and are cited by number rather than
restated — read `specs/005-mobile-remotes/research.md` alongside this. What is here is what
005 did not cover, plus what has changed in the tree since it was written.

---

## 1. What is actually built, counted rather than estimated

**Finding**: 005 is 20 of 86 tasks done, and the twenty are the kit split and the screens. The
machinery the escalation rests on is entirely absent.

Measured in the tree on 2026-09-19:

| 005 promised | In the tree |
|---|---|
| `AgentsKitCore`, both platforms | **Built.** The split landed and holds; the iOS app links Core and nothing else. |
| `Remote/Sources/` — projects, project page, agent cards, chat, permission sheet, stale banner | **Built.** Fourteen files, 2,427 lines, phone-shaped. |
| `AgentsKitCore/Remote/` — `DeviceKey`, `Device`, `Envelope`, `Headline`, `Mailbox`, `CloudKitMailbox`, `MailboxTransport`, `LinkChooser` | **One file: `NetworkLink.swift`.** Nothing else exists. |
| `Bridge/Sources/` — `main`, `BridgeCore`, `Subscription`, `Poller` | **One file: `main.swift`, 153 lines.** Started by hand. No pairing check, no sealing. |
| `DeviceStore`, `DaemonCore+Devices` | **Absent.** `Store/` has no `DeviceStore.swift`. |
| `Bridge.entitlements`, `Remote.entitlements` | **Absent.** `App/Agents.entitlements` still holds only the microphone key from dictation. |
| The CloudKit container (005 T001) and the three spikes (T002–T004) | **Not done.** No container is named anywhere in the repo. |

**Consequence for this plan**: there is no partially-working relayed link to finish. Everything
between "the iPad and the Mac are on the same Wi-Fi" and "the iPad is told on a train" is
unwritten, including the spike 005 called the one that could sink the feature. That is why the
plan runs two tracks and why the parity work does not wait behind the spike.

**Second consequence, worth saying plainly**: what exists today is an unauthenticated,
unencrypted socket on the local network, advertised over Bonjour, that serves the whole daemon
API to anyone who connects. 005 booked this as debt (T024e, T024f, T024g) and it is still open.
Nobody should pair anything until it is closed.

---

## 2. Notification actions are static; permission options are not

**Finding**: the two can be reconciled through `PermissionOption.Kind`, and only through
something like it.

`UNNotificationAction`s are registered inside `UNNotificationCategory`s, all of them handed to
`UNUserNotificationCenter.setNotificationCategories(_:)` before any notification arrives. The
push then names a `categoryIdentifier` and the system draws that category's buttons. Titles are
fixed at registration time.

A permission request does not work that way. `PermissionRequest.options` is
`[PermissionOption]`, each with an `optionID` the runtime invented, a `name` the runtime chose
to display, and a `kind`. The `optionID` is meaningless outside the request; the `name` is
arbitrary text; neither can be known at registration.

But `kind` is closed, and small:

```swift
enum Kind: String { case allowOnce, allowAlways, rejectOnce, rejectAlways, unknown }
```

Every runtime already maps into it — that is what `PermissionOption.Kind(wire:)` is for, and it
is the same closed vocabulary the Mac's own buttons are built from. So four categories cover
every request that will ever arrive, keyed on **which subset of kinds this request offers**:
allow-once and reject-once is the common pair; the four-way is the other common one.

**Decision**: register a small fixed set of categories at launch, keyed on the kind subset.
Action titles are ours — "Allow once", "Always allow", "Deny" — not the runtime's, because the
runtime's `name` cannot be on a button registered before the request exists. The runtime's own
wording is shown in the app, where the whole question is (FR-011).

**`.unknown` gets no action.** A request containing an option we cannot classify is notified
with the "there is something to look at" category (FR-010) and answered in the app. This is the
rule already in force in this codebase — an option we do not understand is skipped, not guessed
— and here it is the difference between a one-tap grant and a one-tap grant of something nobody
can name.

**Alternatives rejected**: registering a category per request, which cannot be done before the
push arrives and would leak option names into a registry the push service can see; and using
`UNTextInputNotificationAction` for a free-text answer, which is right for an elicitation and
wrong for a permission whose whole point is a fixed set of choices.

---

## 3. The action handler has to reach the Mac from a background launch. **Unverified — spike.**

**Finding**: this is 013's equivalent of 005's §6, and it comes before the screens that depend
on it.

A `UNNotificationAction` without `.foreground` causes the system to launch the app **in the
background** and call the delegate's `didReceive` handler. The app then has a short, unpublished
budget to do its work and call the completion handler. In that window it must: read the option
map, seal an answer to the Mac, and write it to the mailbox — a CloudKit write, over the
network, from a cold launch.

Three things are genuinely unknown and none should be reasoned about:

1. **Does the launch happen at all after a force-quit?** Background *pushes* are documented not
   to relaunch a force-quit app. Whether a notification *action* does is a different path and
   the behaviour has changed between releases. If it does not, FR-008 has a hole that must be
   written into the spec rather than discovered by a user on a train.
2. **Does a CloudKit write complete inside the budget, on cellular, from cold?** 005 §5 already
   measured push latency in one direction; this is the other direction and it has a harder
   deadline.
3. **What happens when it does not?** FR-013 requires the answer to be delivered once or not at
   all, and the person to be told which. From a background launch there is no UI to tell them
   with. The fallback is a local notification — "That did not reach your Mac" — scheduled by
   the handler before it gives up.

**Spike, blocking**: build the action path against a fake mailbox first to prove the plumbing,
then against the real one on a device on cellular, ten times, from cold and after a force-quit.
Record the results here. If the force-quit case fails, FR-008 gains a stated limit.

**Design consequence taken now, not after the spike**: the handler does the least possible work.
It does not connect a `DaemonClient`, does not open a transcript, does not sync. It writes one
sealed envelope and stops. Everything the app would normally do on launch is skipped when the
launch came from an action.

---

## 4. The lock screen shows what FR-012 says to hide

**Finding**: 005's FR-012 — "a remote MUST require the device's own unlock before showing any
agent content" — and 013's FR-002 — a notification "MUST name the project, the agent, and what
is being asked" — are in direct conflict on a locked iPad, and the conflict is inherent, not a
bug in either.

The point of the feature is a banner that can be read and answered without unlocking. A banner
that can be read names the project and the command. That is agent content on a locked screen.

**Decision, and it is the user's to overrule**:

- We do not suppress the banner and we do not weaken FR-012 for anything else. The **headline
  is the one thing deliberately shown when locked**, and it is deliberately short: a project
  name, an agent name, and a short action. No transcript, no diff, no file content, no output.
- The system's own "Show Previews" setting governs whether even that appears when locked. We
  set `UNNotificationInterruptionLevel` appropriately and otherwise let the platform's control
  be the control, rather than inventing a second one the person has to find.
- **`authenticationRequired` is set on every action except the least dangerous.** Allowing once
  is the one tap that may happen from the lock screen. Always-allow and always-reject change
  what happens to future requests and require the device to be unlocked first — the system
  handles the unlock and then runs the action.
- Opening the notification lands in the app, which requires unlock as FR-031 says, before any
  transcript is shown.

**This should be written into the spec's assumptions** rather than left in a research file:
the person is choosing to let their iPad show, on a locked screen, that a named agent in a
named project wants to run a named command.

---

## 5. The plan is already on the agent; `agent/plan` is a dead constant

**Finding**: FR-017 costs a view and nothing else.

`Agent` has `public var plans: [Plan]`, encoded and decoded with the rest of the record. It
arrives on the iPad inside `agent/changed`, which `AgentsModel.apply` already handles and
`upsert` already stores. The iPad has the data today and does not draw it.

Separately: `DaemonAPI.Notification.agentPlan = "agent/plan"` is declared and **referenced
nowhere** — not in the daemon, not in `AppModel`, not in `AgentsModel`. 005's tasks list it as
one of the notifications `AgentsModel` must apply (T011); it does not, and nothing is broken by
that, because the plan travels on the record.

**Decision**: draw `agent.plans` on the iPad. Do not wire `agent/plan`. Leave the constant
alone — deleting an unused wire constant is not this feature's business, but no task should be
written that implements it.

---

## 6. The read-only inspector is already in the protocol

**Finding**: FR-020a and FR-020b need no daemon work.

`agents/showFile` (a method) and `agent/showFile` (a notification) both exist in `DaemonAPI`,
and `AgentsModel.apply` already handles the notification and stores the result —
`takeFileToShow(for:)` is there and unused on iOS. The bridge forwards whatever the daemon
broadcasts without knowing what it means (005 §6), so a file an agent shows already reaches a
connected iPad.

`ToolCall.locations` carries what a tool call touched, and `ToolCallContent` carries diffs and
output, both already rendered by `Remote/Sources/Chat/BlocksView.swift`.

**Decision**: FR-020a and FR-020b are two views in `Remote/Sources/Chat/`. Read-only is
enforced structurally — the iPad calls no write method because it has no screen that does — not
by a flag. Note for `/speckit-tasks`: 011 added a `ShownFile` path that the Mac consumes; the
iPad should consume the same one rather than inventing a second.

---

## 7. The error numbers 005 chose are taken

**Finding**: 005's task T039 says "add `alreadyAnswered = -32013` and `noSuchDevice = -32014`".
Both are now in use by features that landed since:

```
-32013  projectHasLiveAgents   (004/008 era)
-32014  noSuchWorkflow         (008)
-32015  workflowUnreadable
-32016  notInWorkflowFolder
-32017  workflowLimitReached
```

**Decision**: `alreadyAnswered = -32018`, `noSuchDevice = -32019`. Any task copied from 005's
list must be re-read for numbers rather than pasted.

**Hazard found while checking**: `DaemonAPI.Failure` already contains a genuine collision —
`shellWillNotStart` and `notConfirmed` are **both `-32010`**. It predates this feature and is
out of scope to fix here, but it is the reason the next number must be picked by reading the
file rather than by adding one to the highest constant somebody remembers.

---

## 8. The Mac has grown four features since 005 described it

**Finding**: "everything the desktop app shows" is a moving target, and it has moved.

Since 005's `contracts/ui.md` was written, the Mac has gained: the workflows section on the
project page (008), cost limits (010), the resuming/restart states (011), and cost totals per
project and overall (012). A fifth, 014 — a new agent status that distinguishes "done" from
"done but still needs you" — is being specified **in another session right now** and will change
what an agent card says.

**Consequence**: FR-021's parity list cannot be a paragraph in a spec. It is
`contracts/parity.md`, a table with a disposition per surface, and it is the thing that gets
re-read when the Mac grows a screen. SC-005 is a walk down it.

**Consequence for sequencing**: 014 changes `AgentGroup` or the agent's status vocabulary, which
the iPad shares through `AgentsKitCore` — the same file, deliberately, so the two cannot
disagree. If 014 lands first the iPad inherits it for free. If 013 lands first, 014's tasks
must include the iPad's card. Whichever way, no work is duplicated; the risk is only that
somebody forgets to look.

---

## 9. What an iPad changes about 005's answers

**Finding**: two of 005's decisions were sized for a phone and want re-reading for a tablet.
Neither changes, but one of them now matters more.

**The link indicator earns its place.** 005's FR-004b says the person is told which link they
are on, justified by the honest difference between milliseconds and seconds (SC-006). On a
phone glanced at for ten seconds that is a nicety. On an iPad being worked at for twenty
minutes, three-second round trips on a sofa ten feet from the Mac would read as a broken app —
and the direct link is exactly what is available in that situation. So the iPad must actually
prefer and hold the direct link when it exists (005 FR-004a), not merely be capable of it, and
`LinkChooser` is load-bearing rather than a refinement.

**Transcript paging is more visible, not less.** 005 §8 found the daemon's `before`/`limit`
paging already sufficient. That holds. But an iPad shows two to three times as many lines per
screen as a phone, so the first page must be sized to the screen rather than to a constant, or
the person watches it fetch twice before they have read anything. This is a parameter, not a
design change.

**What does not change**: everything about the mailbox, the crypto, the bridge, the pairing
exchange and the entitlements. A tablet is not a different threat model.
