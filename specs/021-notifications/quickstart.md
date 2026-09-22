# Quickstart: Notifications, Where The Person Actually Is

How to prove this works, slice by slice. Each section says what to do, what should happen, and
what it means when it does not — that last column is the point, because most of these fail in
ways that look like nothing happening.

## Prerequisites

```sh
xcodegen generate
xcodebuild -scheme Agents -destination 'platform=macOS' -skipPackagePluginValidation build
xcodebuild -scheme Remote -destination 'generic/platform=iOS' -skipPackagePluginValidation build
swift test --package-path Packages/AgentsKit
```

`-skipPackagePluginValidation` is required — SwiftTerm ships a build-tool plug-in that
`xcodebuild` cannot be asked to trust. Build the two schemes one after the other, not at once.

**Slice C only.** The CloudKit container is `iCloud.com.alexecollins.agents`, under team
`6T4RVD5724`. It exists (2026-09-21), assigned to `com.alexecollins.agents.bridge`,
`.remote` and `.remote.notify`, beside the App Group `group.com.alexecollins.agents` — all
registered by Xcode from the entitlements files with `-allowProvisioningUpdates`. A fresh
team would repeat that with a device build of `Remote` and a build of `agents-bridge`, then
open the container once in the CloudKit Console so it answers. Prove it:

```sh
xcodebuild -scheme agents-bridge -configuration Debug -skipPackagePluginValidation -allowProvisioningUpdates build
build/DD/Build/Products/Debug/agents-bridge.app/Contents/MacOS/agents-bridge --spike
```

Passing ends `spike: ok — the private database is reachable from this bundle`. A container
never opened in the Console ends `"Bad Container" (5/1014)`, which is the portal, not the code.

Run against a throwaway root so none of this touches real agents:

```sh
open -n build/DD/Build/Products/Debug/Agents.app --args --root /tmp/agents-021
```

---

## Slice A — the decision, and the Mac

No device, no account, no entitlement. Everything here works on one Mac.

### A1. The ladder, without a Mac in the room

```sh
swift test --package-path Packages/AgentsKit --filter Routing
```

**Expect**: every rung of `contracts/routing.md` covered, the pause and the re-alert interval
asserted against an injected clock, and a totality test in the shape of `AgentGroupTests`.

**Fails if**: any test sleeps. `AttentionThresholds` is injectable precisely so none of them
has to, and a suite that waits 120 s for the idle threshold is a suite nobody will run.

### A2. A banner when you are in another app

1. Start an agent and prompt it into asking for a permission.
2. Before it asks, bring another app to the front.
3. Wait.

**Expect**: within about 20 seconds — the settling pause — a Mac notification naming the
project, the agent, and what is wanted. Clicking it brings the window forward with that
conversation open and the question in front of you.

**Fails if**: it arrives instantly. The pause exists so that alt-tabbing for three seconds does
not buzz you; if it is missing, rung 2's `wait` is not being honoured.

**Fails if**: it says "An agent needs you". The headline is built in Core from the record and
should never be generic on the Mac, where there is no ciphertext budget at all.

### A3. Silence while you are looking

1. Open the agent's conversation and leave the window frontmost.
2. Provoke a permission request.

**Expect**: nothing. No banner, no sound, nothing in Notification Centre.

**Fails if**: a banner appears. Either `presence/report` is not being sent on selection
changes, or rung 1 is checking the winning surface rather than every surface.

### A4. Answered is gone

1. Provoke a request while in another app; let the banner arrive.
2. Answer at the Mac window.

**Expect**: the banner disappears by itself within a second or two.

**Fails if**: it lingers. `attention/changed` with `need: null` is not being broadcast when a
question is answered, or `MacNotifier` is not withdrawing on it.

### A5. Nothing for a clean finish

Let an agent finish a turn cleanly, with nothing outstanding, while you are in another app.

**Expect**: nothing. Then stop an agent mid-turn. **Expect**: still nothing.

**Fails if**: either produces a banner. FR-002 is explicit, and this is the test that stops the
feature becoming noise.

### A6. Walk away and it follows

1. Provoke a need while at the Mac in another app; let the banner arrive.
2. Lock the screen.

**Expect** (with Slice B or C in place): the need moves to a device. Before then, it simply
stays on the Mac, which is correct — there is nowhere else yet.

---

## Slice B — the devices, on the LAN

Needs a real iPhone and a real iPad. The simulator will not do: the whole question is which of
two physical things you are holding.

Start the bridge by hand, as it still must be:

```sh
./build/DD/Build/Products/Debug/agents-bridge
```

### B1. It goes to the one in your hand

1. Both devices on the same WiFi as the Mac, both with the app open and then backgrounded.
2. Lock the Mac.
3. Use the iPad — scroll something, anything — then put it down.
4. Provoke a need.

**Expect**: the iPad notifies. The iPhone does not.

5. Now pick up the iPhone and use it. Provoke another need.

**Expect**: the iPhone notifies. The iPad does not.

**Fails if**: both buzz. The ladder is being run on each device instead of in the daemon, which
is FR-012 broken.

**Fails if**: neither does — see B4. This is expected while the app is suspended, and it is
research §1's honest limit, not a bug.

### B2. The iPhone is the default

Leave both devices untouched for more than ten minutes. Lock the Mac. Provoke a need.

**Expect**: the iPhone. Not the iPad, not both, not nothing.

**Fails if**: the iPad wins because its `heardAt` is merely *less stale* than the iPhone's.
Past the horizon neither is evidence, and FR-009 takes over.

### B3. Watching on one silences all

Open the agent's conversation on the iPad and keep it in front of you. Provoke that agent's
need.

**Expect**: nothing, on either device — even though the phone was touched more recently.

### B4. What the LAN cannot do

Background the Remote app, wait a minute for iOS to suspend it, and provoke a need.

**Expect**: nothing arrives.

This is not a failure to fix in Slice B. It is the finding that makes Slice C the feature
rather than an enhancement: a held TCP connection cannot reach a suspended app, which is
exactly the person this feature is for.

---

## Slice C — the substrate, and real push

### C1. The gate

Before anything else in this slice, run 005's T002 spike: an app-like bundle carrying
`com.apple.developer.icloud-services`, `posix_spawn`ed **with `POSIX_SPAWN_SETSID`** as
`DaemonClient.spawnHelper()` does, reaching `CKAccountStatus.available`, creating a zone,
writing and reading one record, and storing and fetching a key from the data protection
keychain.

**If any of it fails, stop and re-plan.** Apple's DTS recommended this wrapper and had not
tested it with CloudKit. There is no identified third option.

### C2. A pocket, on a train

1. Phone on cellular. Mac on the home network, screen locked, lid open.
2. Provoke a permission request.

**Expect**: the phone notifies within 5 seconds, naming the project and the agent and what is
wanted.

**Fails if**: it says "An agent needs you" every time — the notification service extension is
not running, or it cannot read the private key. Check that the key is
`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` in the access group the extension shares,
because the extension reads it while the phone is locked.

**Fails if**: it takes minutes. The push is being sent without an alert body, which makes it a
low-priority push, which is delivered at the system's discretion.

### C3. Nothing legible in the middle

Inspect the CloudKit record in the dashboard.

**Expect**: `device`, `needToken`, `need` (an id), `alert`, `withdrawn` and `postedAt` in
plaintext, and `envelope` as ciphertext — nothing else. No project name, no agent name, no
folder, no tool, no command, anywhere. (005's field names were `to`/`from`/`kind`/`seq`;
the record that was built is keyed by need and device instead, see `CloudKitMailbox`.)

`agents-bridge --peek <device id>` prints every field of every item for one device, as
CloudKit holds it — the check without the dashboard.

**Walked 2026-09-21 20:00 (Alex's iPhone, `F79AD0F1…`)**: three live items — an
elicitation (`alert = 1`) and two reports (`alert = 0`, moved silently inside the
re-alert interval) — each `envelope` a JSON of base64 `ciphertext` + `encapsulated`, the
other fields as listed. **Pass.** Also seen: a need that moved back to the Mac left a
`withdrawn = 1` record with an empty envelope under the same name, replacing the item.

### C4. Answered on one, gone on the other

Force both devices to hold the notification. Answer on one.

**Expect**: the other clears — immediately if it is in the foreground, and by the time you next
open it if it is not.

**That second half is the amended SC-003** and it is the honest figure: withdrawal on a
backgrounded device needs a silent push, and a silent push is throttled by design. If it clears
instantly every time on a backgrounded device, you have been lucky, not correct.

**Walked 2026-09-21 (Alex's iPhone + the Mac). Pass**, after four fixes it found (`a0ce24b`):
the Mac idle past `macIdle` moved the needs to the phone (LAN banner and a CloudKit push for
each); an elicitation answered on the Mac was withdrawn on the phone over the LAN
(`over=true`) and by push; tapping a banner opened the conversation itself ("that worked").
Found and fixed on the way: the tap crashed the Remote (async delegate callback finishing
off the main thread); the tap stopped at the project (path set in the same turn as the
column); a need in an **archived** project flapped between the phone and nowhere; a silent
push re-showed a dismissed banner. Also: 15 stale Agents.app build products were registered
with LaunchServices, so a click on a Mac notification could launch an old copy — unregistered.

### C5. Revoked is deaf — **struck 2026-09-21**

There is no revoking and no approving (Alex, 2026-09-21): a device that opens Agents on the
person's own network is paired, and the mailbox is their own iCloud account. A device that
is gone stops being heard from and the staleness rung stops choosing it; its records stay
sealed to a key nobody holds. The Devices pane lists devices and says which cannot notify
(C6); it has no buttons.

### C6. Permission refused, and said so

Deny notification permission on a device. Look at the devices list on the Mac.

**Expect**: that device is shown as unable to notify, and the ladder skips it — the need goes
to the next rung rather than to a device that will silently drop it.

---

## Measuring the success criteria

| Criterion | How |
|---|---|
| SC-001 5 s to notify | Phone on cellular, Mac locked elsewhere. Ten trials, take the worst. |
| SC-002 right surface | The four rungs, three trials each. Any wrong surface is a failure, not a flake. |
| SC-003 cleared (amended) | Foreground: stopwatch. Background: confirm it is gone on first open. |
| SC-004 zero while watching | A2–A3 and B3, ten trials, any banner is a failure. |
| SC-005 never a placeholder | Read every banner in C2 across ten trials. |
| SC-006 at most two alerts | Move between devices ten times inside five minutes with one need standing. |
| SC-007 revoked receives nothing | C5, plus the CloudKit dashboard. |
| SC-008 median answer time | Two days of ordinary use with notifications off, two with them on. |
| SC-009 no stale notifications | A week's log: every banner read against whether the need still stood. |

## The thing to remember after a reboot

Nothing starts by itself. No daemon, no bridge, no notifications until the Mac app has been
opened once. That is 005 §7's decision — no login item, nothing installed — and it is a cost,
not an oversight. The remote says when it last heard from the Mac rather than spinning.

---

## Walk log — Slice A, 2026-09-20

Driven from the daemon's socket with Alex at the screen, on `796f4b8`. Times are the
daemon's, read through `attention/pending` every five seconds.

| Check | Daemon side | Seen |
|---|---|---|
| A2 | Permission held 16:23:50; delivered `→ mac` at **16:24:10**, twenty seconds later and not before | banner seen, three lines read right, click opened the conversation ("They look fine") |
| A3 | A question held 16:30:30 and **not delivered for eight minutes** while its conversation was watched; delivered `→ mac` at 16:38:32 when Alex moved away | silence while watching, confirmed |
| A4 | Answered `allow-once` at 16:24:40; withdrawn at **16:24:41** | banner gone, confirmed |
| A5 | The A2 agent finished cleanly (`done`), no need. An essay agent stopped mid-turn (`cancelled`), no need | nothing appeared, confirmed |
| A6 | Not yet: no device slice in place, so the need stays on the Mac, which is correct | — |

Found on the way, and fixed before the walk: the window reported `active` as "Agents is
frontmost", so switching to another app moved the need to nowhere — the opposite of A2.
At the Mac now means the session is in use (unlocked, input in any app inside `macIdle`),
and watching stays the narrow fact (`796f4b8`).

Also seen on live traffic during the walk: a form answered fifteen seconds after it was asked was never delivered (FR-015), and a banner withdrew the moment its conversation was opened from it.
