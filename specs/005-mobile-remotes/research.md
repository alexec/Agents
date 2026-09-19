# Research: Remotes for iPhone and iPad

Fourteen findings. Each was checked against the tree or against Apple's current documentation for
macOS 27 and iOS 27, and each says what it decides. Where a claim could not be verified it says so,
because a plan that hides an unknown is worse than one that names it.

---

## 1. There is no first-party way for two of a user's devices to reach each other over the internet

**Decision**: stop looking for a socket. The channel is store-and-forward.

Everything Apple ships for device-to-device is link-local or proximity-scoped:

| Mechanism | Reach | Why it is out |
|---|---|---|
| `NWParameters.includePeerToPeer` | ~30 m | AWDL. Needs Bonjour, not raw addresses. |
| Wide-area Bonjour | discovery only | The registration half died with Back to My Mac; a DNS record pointing at a phone behind carrier NAT is useless anyway. |
| DeviceDiscoveryUI | local network | Mac Catalyst only. There is no AppKit version. |
| Wi-Fi Aware | local, by design | Does not exist on macOS. |
| Multipeer Connectivity | local | Deprecated wholesale in Xcode 27. |
| `ProxyConfiguration` / MASQUE relays | outbound only | Configures a client's egress. Does not make a Mac reachable. |
| Wake on LAN, Bonjour Sleep Proxy | local | Requires a router we are not allowed to touch. |

Back to My Mac was the thing that did this, and it was switched off in 2019 with no developer
successor. Handoff and Continuity need the devices near each other. iCloud Private Relay is a Safari
feature and never makes a device reachable.

Hole punching is not a way out either: local UDP port reuse across `NWConnection`s does not work
(FB13678278), which Apple's own DTS has acknowledged makes ICE impossible on Network framework
without dropping to BSD sockets or libwebrtc.

**Alternatives considered**: a relay we operate (a VPS, TLS renewal, DDoS exposure, and a feature
that is down when it is down — and FR-002 forbids a service the user or we must run); Tailscale
embedded (excellent, but needs a tailnet and an SSO login, which FR-007 forbids); WireGuard through
`NEPacketTunnelProvider` (App Store rules make it an organisation-enrolment VPN app, and Apple's own
technote says not to host a listener in one).

## 2. CloudKit's private database is the channel

**Decision**: a CloudKit private database in a container both apps name explicitly, used as an
encrypted mailbox with push wake-ups. One record per message per target device.

It is the only option that satisfies FR-001 through FR-003 together: it reaches any network, it needs
no address, no port and no router change (FR-002), it is operated by Apple rather than by us, and
storage counts against the user's iCloud quota, so there is nothing to bill and nothing to keep
running.

What it costs, and this is the honest part: **it is a mailbox, not a socket.** Round trips are
seconds, not milliseconds. See §10 for what that does to the spec's timings.

Limits that shape the design: a record is at most 1 MB; an operation carries at most 400 records;
roughly 40 requests a second per user; and throttling is real on both sides, with
`CKErrorRetryAfterKey` to be honoured everywhere. There is no public record expiry, so we delete our
own messages after delivery.

**This forbids streaming.** One record per token would exhaust the budget in seconds. Transcript
goes in coalesced chunks, and the phone asks for history rather than being sent it (§8).

## 3. `CKRecord.encryptedValues` is not enough, so we encrypt ourselves

**Decision**: our own ciphertext, in ordinary record fields, with CryptoKit. Never depend on
CloudKit's field encryption for the guarantee FR-003 makes.

`encryptedValues` is real — fields are encrypted on device with key material from the user's iCloud
Keychain — but the per-user CloudKit service keys are uploaded to Apple's HSMs unless the user has
Advanced Data Protection switched on. Turning ADP on is precisely the act that deletes them. Apple's
own summary is explicit: under standard protection third-party CloudKit data is "encrypted in transit
and on server", which means Apple holds the keys; only under ADP is it end to end.

We cannot require ADP and cannot reliably detect it. FR-003 says *nothing* in the middle may read
anything, for every user. So the guarantee has to be ours.

Two further reasons this is the right call rather than a grudging one:

- Encrypted fields cannot be indexed, cannot appear in a query predicate, and cannot be copied into a
  push payload. Our own ciphertext in a plain field can be (§5).
- Fields cannot be converted from plain to encrypted later. Choosing at schema creation is choosing
  once.

We may still mark our ciphertext fields `encryptedValues` as a second wrapper for ADP users. We must
never rely on it.

## 4. Pairing is a public key and a tap, not a code

**Decision**: every device makes a Curve25519 key pair on first run and keeps the private half in its
own keychain, device-only. It announces its public half. The Mac asks the user to approve it. Messages
are sealed to each approved device's public key.

The obvious shortcut is wrong, and it is worth saying why because it is genuinely attractive. Both
devices are on the same Apple Account, and iCloud Keychain is end to end encrypted by default without
ADP. It syncs cryptographic keys, not merely passwords, and has since macOS 11 and iOS 14. So a
single synchronised key would arrive on the phone with no pairing UI at all, nothing to scan and
nothing to type.

It breaks FR-010. A key that syncs to every device on the account cannot be taken away from one of
them: revoking a lost phone would mean rotating a key that the lost phone receives along with
everything else. Per-device revocation and a single synced key are the same thing asked for twice in
opposite directions.

Per-device keys make revocation cryptographic rather than a flag (FR-013). A revoked device is not
merely delisted; nothing is ever sealed to it again, and the messages it already had are deleted from
the mailbox. That is what "holds nothing readable afterwards" has to mean.

There is a second, independent reason, and it is the stronger one. **CloudKit authenticates the
account, not the device.** Every device signed into the Apple Account can read and write that private
database — an old iPad in a drawer included — and this is true even with Advanced Data Protection on,
because ADP changes who holds the keys and not who is trusted. Without our own per-device sealing,
"paired" would mean nothing: every device on the account would read every transcript whether the user
had approved it or not. Sealing to an approved device's public key is what makes the approval real.

**The key is P256, not Curve25519**, for one practical reason: the Secure Enclave holds P256 and does
not hold Curve25519. An identity key the Enclave holds cannot be extracted from a phone at all, which
is most of what FR-013 is asking for. CryptoKit's HPKE has a P256 suite, so nothing else changes.

This is the design's one real fork, and it should be a conscious choice rather than a default.
Account-level trust — one key synced through iCloud Keychain — buys a feature with no pairing step at
all. Device-level trust costs one tap on the Mac and buys revocation and the drawer iPad. For a tool
that carries a transcript of everything the user's agents have read and written, the tap is worth it.

FR-008 — an observer of the pairing exchange must not be able to connect — is satisfied by there
being nothing to observe. The public key travels inside the account's own private database over TLS,
and the private half never leaves the device that made it.

CryptoKit gives us everything needed: X25519 agreement, HKDF, AES-GCM or ChaChaPoly, and HPKE since
iOS 17. Post-quantum HPKE with X-Wing exists since iOS 26 and is worth adopting for the seal, because
it costs almost nothing here and a mailbox is exactly the shape of thing that gets harvested now and
decrypted later. Apple ships no PAKE, so a short-code scheme would be hand-rolled SPAKE2; there is
no reason to, given the account boundary.

**One wording problem**: FR-007 says the exchange is "begun at the Mac". In this design the phone
announces and the Mac approves. Nothing connects without the tap on the Mac, so the intent holds, but
the spec should be amended to say *confirmed* at the Mac. Flagged in the plan, not papered over.

## 5. The notification names the agent without the push service knowing it

**Decision**: a high-priority alert push carrying three short ciphertext fields, rewritten by a
Notification Service Extension that decrypts them on the device. No network inside the extension.

This is the part that lets FR-015 and FR-019 both be true.

`CKSubscription.NotificationInfo.shouldSendMutableContent` sets `mutable-content: 1`, which hands the
push to our extension before it is shown. `desiredKeys` names record fields CloudKit copies into the
payload. So: `alertBody` is a generic placeholder, which the extension replaces with "rename-refactor
needs permission to run `git push`" after decrypting. Apple's push service carries only ciphertext,
and the words the user reads are assembled on their phone.

The placeholder is not optional. `NotificationInfo` documents that a push with no `alertBody`, sound
or badge is sent **at lower priority**. That is the throttling question answered: a silent push is a
low-priority push, delivered a couple of times an hour at best, coalesced one-deep so a newer one
discards the one still waiting, and killed outright by a force-quit. SC-001's five seconds cannot
rest on that. Our wake-up must be an alert.

The budget is tight and must be measured: `desiredKeys` takes **at most 3 keys**, and strings over
100 characters "may be truncated". Three base64 fields is roughly 225 bytes of ciphertext, about
45 to 70 bytes of plaintext each after AES-GCM overhead — enough for a project name, an agent name
and a short action, if the headline format is designed to it.

The fallback, an extension that fetches the record from CloudKit and decrypts, is where this design
is thinnest: no authoritative source says CloudKit works inside a Notification Service Extension, and
the extension has a memory ceiling of roughly 20 MB that a CloudKit link would threaten. That figure
is derived from crash reports rather than published by Apple, which is its own reason for caution.
**Unverified.** Design to the payload, prototype the fallback, and degrade to the placeholder body
rather than showing nothing.

The alert push is not merely preferable, it is the only kind that reaches an extension at all: a
service extension runs only for notifications that will display an alert *and* carry
`mutable-content: 1`. Silent, sound-only and badge-only notifications cannot be modified. Running the
extension while suppressing the banner would need
`com.apple.developer.usernotifications.filtering`, which is applied for rather than granted, and at
least one shipping app gave up after months without an answer. Do not design anything that needs it.

Sharp edge: the extension reads the key while the phone is locked, so the private key must be
`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, in a keychain access group shared by the app and
the extension. Get it wrong and every notification silently shows the placeholder forever.

## 6. The daemon cannot talk to CloudKit, and must not have to

**Decision**: a third process. `agentsd` keeps its Unix socket and gains nothing. A small helper, an
app-like bundle, connects to `agentsd` as an ordinary client and owns CloudKit, the crypto and the
mailbox.

`agentsd` is `type: tool` in `project.yml` — a bare Mach-O with no bundle and nowhere to put a
provisioning profile. `com.apple.developer.icloud-services` is a restricted entitlement and must be
authorised by an embedded profile. Apple's DTS answer to this exact question is to wrap the tool in
an app-like bundle: an application target with the principal class, storyboard and delegate stripped,
shipped as `Foo.app/Contents/MacOS/Foo` with `embedded.provisionprofile` beside it. No GUI is
involved; it is about the bundle shape carrying the profile.

Wrapping `agentsd` itself would work, and is the wrong shape. Putting a network client in the process
that spawns agents, reads files and runs commands on their behalf widens the blast radius of the one
process that must not be widened. A separate bridge means the daemon keeps exactly the attack surface
it has today, and the bridge holds no agent state of its own.

The bridge being an ordinary client is the whole trick: `JSONRPCConnection` already takes any
`LineTransport`, `DaemonClient` already speaks the full method surface, and `DaemonServer` already
broadcasts to every connection. **The remote transport is a process boundary, not a protocol
change.** No new listener, no second server, no network socket anywhere in `agentsd`.

**Risk, and it is the one that could sink the feature**: Apple's DTS recommended the app-wrapper
workaround but said they had not tested it with CloudKit specifically. If a nested app-like bundle
cannot reach the private database, the architecture collapses to "the GUI app must be running", which
is the premise gone. This is a two-day spike and it comes before everything else.

**The helper must run in the user's login context**, and two independent constraints say so. The
private database is scoped to the signed-in Apple Account, so a root daemon sees `noAccount`. And the
data protection keychain — the one that syncs and the one the Secure Enclave backs — is only
available in a user login context at all; a launchd daemon is restricted to the old file-based
keychain, which gets neither. Either constraint alone decides it.

What that does *not* decide is registration. A process spawned by the user's own app already runs in
their login context, which is how `agentsd` runs today. The claim that this forces an `SMAppService`
LaunchAgent confuses the context with the mechanism: what a LaunchAgent adds is being restarted
without the app, which is the login item §7 declines on purpose. One thing to check in the spike:
`DaemonClient.spawnHelper()` passes `POSIX_SPAWN_SETSID`, and whether detaching the session affects
keychain or CloudKit access is exactly the sort of thing that is cheaper to measure than to reason
about.

The user must also have iCloud Drive enabled, not merely be signed in, or `CKAccountStatus` reports
`noAccount`. That needs a check and a plain sentence on first run.

## 7. Nothing starts by itself after a reboot, and we should say so

**Decision**: the bridge is spawned by `agentsd`, the way `agentsd` is spawned by the app. No
`SMAppService`, no login item, nothing installed.

`SMAppService` is the modern, supported way to keep a helper running, and it registers a background
item the user sees in System Settings. That is a login item by another name, and 001's FR-021 and the
README both promise there is not one. The promise is worth more than the convenience.

The cost is real and goes in the spec: **after a reboot, the Mac app must be opened once.** Until
something opens it, no daemon and no bridge are running, and the phone sees a Mac that has not been
heard from. Nothing rescues this from the outside, either: on macOS a push does not launch an
application that is not running — icon badging is the only thing a stopped app gets — so there is no
arriving message that can start us. This is the honest version of FR-005, and the remote says when it
last heard from the Mac rather than spinning.

If that trade turns out to be the wrong one in use, the alternative is one line of policy rather than
a redesign: register the bridge with `SMAppService` and accept the background item in System
Settings. Worth revisiting after living with it, not before.

The other half of FR-005 is easy. `shouldExit` today is `connectionCount == 0 && !isHoldingAgents`
(`DaemonCore+Lifetime.swift:15`). The bridge is a connection, so while a device is paired the daemon
stays up, without touching the rule. And when no device is paired the bridge does not run at all, so
a user who never pairs a phone sees precisely the app they have today (FR-038).

## 8. The paging the phone needs already exists

**Decision**: no new transcript method. `agents/transcript` already takes `before` and `limit`.

FR-037 asks that a long conversation open quickly on a mobile connection rather than dragging the
whole history across. `DaemonAPI.TranscriptRequest` already pages, because the Mac window needed it
for scrollback. The phone asks for a page, and asks for more when the user scrolls.

What does need building is the other direction. `DaemonServer` broadcasts every notification to every
connection unconditionally — right for a window on a desk, wrong for a phone on a metered connection
that cares about three agents out of fifty. **The bridge filters.** It forwards state changes and
questions always, and transcript entries only for the agent the phone says it is watching. That
subscription lives in the bridge, so the daemon's fan-out stays as simple as it is.

## 9. Answering already works. Knowing who answered does not

**Decision**: three small daemon changes, no new mechanism.

`answerPermission` (`DaemonCore+Commands.swift:390`) removes the pending request from an actor's
dictionary and throws if it is already gone. That is first-answer-wins, atomically, today, and
FR-032 is most of the way met before we start. Every other client learns to withdraw the question
from the existing broadcast with `request: nil`.

What is missing:

1. **Who answered.** FR-032 and the spec's scenario ask the losers to be told which device won.
   `AnswerRequest` gains `answeredBy`, and the withdrawal notification carries it.
2. **A code that means what it says.** The loser gets `-32005`, which is `noSuchAgent`. A phone
   cannot tell "somebody beat you to it" from "that agent is gone", and those deserve different
   sentences. A new `alreadyAnswered` continues the block after 004's two.
3. The same for `elicitations/answer`, which has the identical shape in `DaemonCore+Serving.swift`.

## 10. The spec's timings were written for a socket

**Decision**: meet SC-001 and SC-002 as written; ask for SC-006 to be amended.

| Criterion | What it says | What a mailbox does |
|---|---|---|
| SC-001 notify in 5 s | Mac → phone, on an event | Met. Alert pushes are high priority; a shipping CloudKit app reports two seconds. |
| SC-002 resume in 2 s of the answer | phone → Mac | **Tight.** The Mac learns by polling. At a one-second poll while an agent is blocked, expect one to three seconds. |
| SC-004 / SC-006 within 1 s | both ways, live | **Not met off-LAN.** A store-and-forward round trip is seconds. |

The Mac does not get push. macOS registration for remote notifications goes through `NSApplication`,
which an app-like helper has but which requires the process to be running; whether macOS launches a
non-running third-party app to deliver a push is **unverified**, and the one forum thread asking has
no answers. So the Mac polls — but only in the window where it matters. While an agent is blocked on
a human, the bridge polls every second and holds an `NSProcessInfo.beginActivity` assertion so the
Mac does not doze mid-question. Outside that window it polls rarely and lets the Mac sleep. Thirty
requests a minute against a forty-a-second ceiling is nothing.

That is a legitimate power assertion: real work is genuinely pending. A permanent one would not be.

Its limits need stating plainly, because they are narrower than they sound. A power assertion keeps
an awake Mac awake; it cannot wake a sleeping one. `PreventUserIdleSystemSleep` has no effect in dark
wake and does not survive the lid closing, and the entitlements that would change that are private to
Apple. On battery, macOS 27 defaults "wake for network access" off, so a lid-closed laptop on battery
is simply unreachable until somebody opens it. The remote's answer to this is honesty — it says when
the Mac was last heard from — not a trick.

Polling has a third justification beyond the two above, and it is the blunt one: there is a live,
unresolved, **macOS-only CloudKit push delivery regression** reported from macOS 14 through 26.3 —
pushes arrive late or never, `killall apsd` flushes them immediately, and the identical code is fine
on iOS. Apple's DTS agreed it looked like a bug and offered no workaround. Whether it survives into
macOS 27 is unknown. Polling on the Mac was already the design; this makes it insurance.

**Recommendation**: amend SC-006 to "within 3 seconds while the remote is in front", and let the
1-second figure belong to the direct connection in §11, when it lands.

## 11. Both links are shipping, and the direct one went first

**Decision**: two links, not one with an optional extra. The direct link is built; the mailbox is
not. FR-004 is amended to require both.

This finding originally said the opposite — build the mailbox first, add a direct connection later
as its own phase, and cut FR-004 if it came to it. What happened is the reverse, and the reversal is
worth recording honestly rather than quietly rewriting history.

**What was built** (`Packages/AgentsKitCore/Remote/NetworkLink.swift`, `Bridge/Sources/main.swift`):
an `NWListener` on the Mac advertising `_agents._tcp` with `includePeerToPeer`, an `NWBrowser` on
the device, and a relay process that connects to `agentsd` over the existing Unix socket and carries
whole lines between the two. It is a third `LineTransport`, exactly as this finding predicted, and
it fitted without rework, which is the one prediction that held. A device on the same network reaches
the Mac today.

**Why it went first, in hindsight**: it needs no developer-portal container, no entitlement, no
provisioning profile and no spike. The three CloudKit spikes (T002 to T004) are gates that need
hardware, a paired device and a cellular connection; the direct link needed an afternoon. Faced
with a layout that was settled and machinery that was blocked, building the reachable half was the
right call — it turned the `Remote` app from a thing driven by canned data into a thing driven by
the real daemon, which is what the layout gate (T024) actually needs to be walked.

**What it does not do, and this is the part that matters.** From its own header:

> There is no pairing and no encryption here yet, so anything on this network that can find the
> service can drive the daemon. Until `Envelope` and the paired-device list exist, the safety is
> that this only runs while somebody has decided it should.

So the direct link as it stands **fails FR-003, FR-008 and FR-011**, and satisfies SC-009 only in
the sense that there is nothing to capture while it is not running. It is a development tool that
happens to be shaped like the shipping transport. The gap is closed by the same `Envelope`,
`DeviceKey` and `DeviceStore` the mailbox needs — which is the argument for FR-004c: one security
model, two routes, so the sealing is written once and both links get it. Nothing about the direct
link is allowed to ship on the argument that a home network is trusted.

**What this changes downstream**: the transport becomes a choice rather than a given, so there is a
selection rule to specify (`contracts/transport.md`), a link state to show the user (FR-004b), and a
handover to get right when a device walks out of the house mid-session. None of that existed when
the plan assumed one channel.

## 12. AgentsKit is macOS-only and splits cleanly

**Decision**: two targets. `AgentsKitCore` for both platforms, `AgentsKit` for the Mac.

`Package.swift` declares `platforms: [.macOS("27.0")]`, one target, and there is not a single
`#if os(` in the package. Every file imports only Foundation, so nothing has to be unpicked — the
split is by meaning, not by conditional compilation.

**Shared** (`AgentsKitCore`): all of `JSONRPC/` — `JSONValue`, `JSONRPCMessage`, `JSONRPCError`,
`JSONRPCConnection`, `LineTransport` with both implementations; all of `Model/`; `DaemonAPI.swift`,
which is method names and DTOs with no daemon dependency; the ACP type files `ACPTypes`,
`ContentBlock`, `SessionUpdate`, `ToolCallContent`; and `RuntimeAccount`, `RuntimeCatalog`.

**Mac only** (`AgentsKit`, depending on Core): `Daemon/`, `Store/`, the ACP session and serving code,
runtime discovery, and `Client/DaemonClient.swift`. The blockers are concrete: `Process` in
`RuntimeProcess`, `TerminalService` and `LoginShellPath`; `posix_spawn` and the `Bundle.main` helper
lookup in `DaemonClient`; `flock` in `DaemonLock`; the `AF_UNIX` listener in `DaemonServer`.

`DaemonClient` is worth a second look: everything in it except opening the socket and spawning the
helper is platform-free, and the phone wants exactly that part. It moves to Core with its transport
injected, and the socket-and-spawn half stays on the Mac. That is one small refactor that saves
writing a second client.

One thing to notice while splitting: what each notification *means* currently lives in
`AppModel.received(_:_:)` in the Mac app, not in the kit. The phone needs the same logic. It moves to
Core with the client.


## 13. 004 shipped, in a different shape, and it is the shape a phone wants

**Decision**: the remote copies what 004 actually built — two columns and a push — rather than the
three columns its contract described.

004 is **built** (`9087a1a`), and it did not land as planned. The three columns became two: projects
on the left, and the project itself filling the detail pane — its name, the real prompt bar with the
folder already set, and the agents in their groups as cards in a 144pt gutter. **The conversation is
not a third column.** It is a push inside a `NavigationStack`, with a back button, because "a chat is
somewhere you go from the project and come back out of". 002's inspector rides beside `ChatView`
inside that pushed destination, and only when the window is wide enough for it.

This is good news twice over. The Mac has already adopted the navigation model a phone needs, so the
iPhone layout is not a translation of the Mac's — it is the same idea at a smaller size, and the iPad
differs only in keeping the projects column visible. And it removes the piece of this plan that was
about reconciling two different shapes.

**The project lead is gone.** It was specified, planned, built with MCP tools, four guards and a held
permission flow, and then taken back out (`c13eb9b`) after the layout moved under it four times. An
earlier draft of this finding leaned on the lead as the best argument for remotes. It is not
available and that argument is withdrawn.

The reason it was removed is the useful part, and it applies directly here: the layout was not
settled, so everything built underneath it meant something slightly different each time the layout
moved, and all of it was deleted. A remote is a layout with a great deal of machinery under it. See
the phasing, which is ordered accordingly.

## 14. Small things on iOS 27 and macOS 27 that each cost a debugging session

Collected rather than discovered, and each one is cheaper to read now than to hit later.

- **iOS 27 requires the UIScene lifecycle.** An app built against the latest SDK without it "won't
  launch". Ours is new, so this is a matter of starting scene-based rather than migrating — but note
  that nothing at all can be tested until it launches, including the APNs token the whole push path
  depends on. It belongs in the spike, before any push work.
- **`BGTaskScheduler.submit(_:)` is deprecated** in favour of `submitTaskRequest`, which surfaces
  errors the old call swallowed. Limits are now documented: one refresh task and ten processing tasks
  pending. We want very little background work, but if any appears, use the new call.
- **Secure Enclave holds P256, MLKEM and MLDSA — not Curve25519 and not X-Wing.** This is what
  decides the identity key in §4.
- **`kIOPMAssertNetworkClientActive` is honoured on AC power only.** On battery it prevents idle
  sleep at best. Another reason §10's assertion is scoped to the blocked window and not leaned on.
- **macOS 27 launchd refuses plists carrying the quarantine attribute.** Only bites if §7's decision
  is ever reversed toward `SMAppService` — and if it is, expect the "Background item added"
  notification and a permanent row in Login Items & Extensions, neither of which can be suppressed.
  That row is itself an argument for the current choice.
- **A new entitlement gates Neural Engine access while backgrounded** on iOS 27. Nothing here uses
  it; worth knowing before anything on-device starts doing ML.
