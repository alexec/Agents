# Quickstart: proving the iPad remote works

How to tell whether this feature is real. Each track has checks that fail loudly when the
track is not done, and the two tracks can be walked independently — which is the point of
splitting them.

005's quickstart (`specs/005-mobile-remotes/quickstart.md`) still covers the CloudKit spike,
the push latency measurement and the headline budget. Do those from there. What is here is
013's own.

## Prerequisites

- A Mac on macOS 27 and **an iPad on iPadOS 27**, both signed into the same Apple Account with
  iCloud Drive on.
- Team `6T4RVD5724`, with a CloudKit container created (005 T001) — for Track A only.
- A second network for the iPad: cellular, or a hotspot the Mac is not on. **An iPad on the
  same Wi-Fi proves nothing Track A claims.**
- A real iPad. FR-034 makes the simulator insufficient for anything that ships.

```sh
xcodegen generate
xcodebuild -scheme Agents -destination 'platform=macOS' -skipPackagePluginValidation build
xcodebuild -scheme Remote -destination 'generic/platform=iOS' build
swift test --package-path Packages/AgentsKit
```

---

## Track B first, because it runs today

Track B is what the iPad shows. It needs only the direct link, which is built.

### Setting up the direct link by hand

```sh
# 1. The Mac app, so the daemon is running and has agents
open build/DD/Build/Products/Debug/Agents.app

# 2. The bridge, by hand — it is not yet spawned (005 T024h is open)
./build/DD/Build/Products/Debug/agents-bridge

# 3. The iPad on the same Wi-Fi, app installed. It finds the Mac over Bonjour.
```

> **Do not leave this running unattended.** Until 005's T024e/f/g land, the bridge serves the
> whole daemon API on the local network with no pairing and no encryption. Research §1.

For layout work with no Mac at all, the fake is still there:

```sh
# Canned projects, a question waiting, and a conversation long enough to page
xcrun simctl launch --console booted com.alexecollins.agents.remote -fake
```

### B1 — The plan appears (FR-017)

Give an agent on the Mac something that makes it plan. Open the same agent on the iPad.

**Expect**: the plan, with the same steps and the same states as the Mac's `PlanView`, updating
as the agent revises it. **Fails today**: `Agent.plans` already arrives on the iPad and nothing
draws it (research §5).

### B2 — A touched file opens, read only (FR-020a, SC-014)

Find a tool call that changed a file. Open that file from the transcript.

**Expect**: the content, and the change. **And**: no path anywhere on that screen offers to
edit, save, or share it back. Walk every menu and every long-press.

### B3 — A produced document opens, read only (FR-020b)

Have an agent produce a document. Open it on the iPad.

**Expect**: laid out for the screen as feature 007 lays it out on the Mac. Read only, same
check as B2.

### B4 — The parity walk (SC-005, FR-021)

The main event for Track B, and the slowest check here. Put the Mac and the iPad side by side
with the same agent open, and walk `contracts/parity.md` **row by row**.

**Expect**: every row marked **Yes** is present on both and says the same words. Every row
marked **No** is named in the spec's *Out of scope*. Anything on the Mac that is not a row is a
missing row — add it, then decide it.

Do this with a project that has: a workflows section, a cost total, an archived agent, an agent
that ended in an error, and an agent that is resuming.

### B5 — The iPhone still runs (FR-033, SC-013)

Install on an iPhone. Launch it. Reach every screen.

**Expect**: it launches and nothing crashes. The layout may be wrong; write the defects down
for the iPhone feature (FR-035) rather than fixing them.

---

## Track A — being asked, and answering

Track A needs 005's machinery. Do 005's spike first; if it fails, stop and re-spec.

### A0 — The new spike, and it blocks FR-008 (research §3)

Before building the notification screens, answer three questions on a real iPad on cellular:

```text
1. Tap an action while the app is merely backgrounded.  Does the handler run?
2. Tap an action after the app has been force-quit from the app switcher.  Does it run?
3. In the handler, from cold, seal and write one mailbox record.  Does it complete?
   Ten times.  Record the worst case.
```

**Expect**: 1 yes. 3 comfortably inside the budget. **2 is the unknown** — if it is no, FR-008
gains a stated limit and the spec must say that force-quitting the app costs you the one-tap
answer. Record all three here in `research.md` §3 before writing the screens.

### A1 — The notification arrives and names things (SC-001, FR-002)

iPad locked, app not running, on cellular, Mac on an unrelated network. Provoke a permission
request.

**Expect**: within 5 seconds, a banner naming the project, the agent, and what is wanted. Not
"An agent needs you" — that is the fallback, and seeing it here means the extension failed to
decrypt. Check the keychain accessibility first (005 §5: `AfterFirstUnlock…ThisDeviceOnly`, in
the shared access group).

### A2 — It is answered from the banner (SC-002, FR-008)

Press **Allow once** on the locked iPad.

**Expect**: the app never opens. The agent resumes on the Mac within 2 seconds. The Mac's
window shows the question answered, and by which device.

Then press **Always allow** on a locked iPad.

**Expect**: the system asks for the device to be unlocked before it runs
(`authenticationRequired`, `contracts/notification-actions.md`).

### A3 — An option nobody can name gets no button (FR-010, the rule that matters)

Provoke a permission request carrying an option whose `kind` does not map — easiest with a
runtime that sends something unexpected, or by hand in a test.

**Expect**: a banner with **no answer buttons**, saying there is something to look at. Opening
it shows the full question with the runtime's own wording. **A one-tap grant here is a
failure**, not a convenience.

### A4 — Nothing is answered twice (SC-004, FR-012)

Provoke a request. Answer it on the Mac. Look at the iPad.

**Expect**: the banner is gone from the lock screen, not sitting there inviting an answer. If
the app is open on that question, the buttons are replaced by what became of it and who
answered.

Then the race: answer from the banner and the Mac at the same instant, 100 times.

**Expect**: exactly one answer applied every time. The loser gets `alreadyAnswered`
(**`-32018`**, not 005's `-32013` — research §7) and says so, never `noSuchAgent`.

### A5 — An answer that cannot be delivered says so (FR-013)

Answer from the banner with the Mac asleep or off the network.

**Expect**: a local notification saying it did not reach the Mac, naming the agent. **Not**
silence, and **not** a cheerful nothing. Then wake the Mac: the question is still pending and
still answerable, because the answer was never delivered rather than half-delivered.

### A6 — Pairing, and taking it back (SC-008, SC-010)

Pair the iPad from the Mac. Time it.

**Expect**: under 60 seconds, no account made, nothing typed. Then revoke it at the Mac with
the iPad's app open.

**Expect**: access gone within 10 seconds, with the app open at the time. Nothing readable
afterwards. Provoke a request: no notification arrives.

### A7 — Nothing readable in the middle (SC-011)

Capture traffic between the iPad and the Mac on both links, and inspect the CloudKit records
and the push payload.

**Expect**: no readable prompt, transcript, file content, command, or credential anywhere,
**including on the direct link** (005 FR-004c: a home network is not a trusted network). Until
T024e lands, this check fails on the direct link by design — that is the debt, and it blocks
ship.

---

## The gate

**FR-034**: every screen walked on real iPad hardware, beside the Mac, and iterated until it
has stopped changing. This is 005's T024 gate, narrowed to one device and actually enforced
this time. Nothing after it begins until it stops moving.

## What "done" looks like

- Track B: `contracts/parity.md` walked with no unexplained gaps, and its two unsettled rows
  (dictation, sessions) decided.
- Track A: A0 through A7 pass, with A0's force-quit answer recorded whichever way it went.
- `swift test --package-path Packages/AgentsKit` green, including the new pure tests on the
  `Escalation` derivation and the category round trip.
- The iPhone launches and is reachable, with its layout defects written down and not fixed.
- Feature 005 still open, holding what the iPhone is owed.
