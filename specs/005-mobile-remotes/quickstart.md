# Quickstart: proving the remotes work

How to tell whether this feature is real. The spike comes first because it can end the feature; after
that, each phase has a check that fails loudly when the phase is not done.

## Prerequisites

- A Mac on macOS 27 and an iPhone on iOS 27, both signed into **the same Apple Account** with
  **iCloud Drive on**. Check on the Mac in System Settings → your name, and on the phone the same.
- A second network for the phone. Turn Wi-Fi off and use cellular — a phone on the same Wi-Fi proves
  nothing this feature claims.
- Team `6T4RVD5724`, with a CloudKit container created for it.

```sh
xcodegen generate
xcodebuild -scheme Agents -destination 'platform=macOS' build
swift test --package-path Packages/AgentsKit
```

---

## Phase 0 — the spike, alongside phase 1

Three questions. It answers whether the feature can exist, so it is first in importance — but nothing
in phase 1 depends on it, so it runs beside the layout work rather than in front of it. If the first
answers no, the feature becomes "the Mac app must be running" and needs a different spec; the layout
built in phase 1 is still the right layout for that.

**Can an app-like bundle spawned by `agentsd` reach CloudKit and the keychain?**

```sh
# Build the wrapper, confirm the profile is embedded and the entitlement is on it
codesign -d --entitlements - build/.../Agents.app/Contents/Helpers/AgentsRemote.app
ls build/.../AgentsRemote.app/Contents/embedded.provisionprofile

# Spawn it the way agentsd will, and watch what it reports
build/.../Agents.app/Contents/Helpers/AgentsRemote.app/Contents/MacOS/AgentsRemote --probe
```

Expect: `CKAccountStatus.available`, a custom zone created, one record written and read back, and a
key stored in and fetched from the data protection keychain. Then do it again with the process
spawned using `POSIX_SPAWN_SETSID`, as `DaemonClient.spawnHelper()` does, because detaching the
session is exactly the sort of thing that breaks keychain access quietly.

**Does a push arrive, and how fast?** A scene-based iOS app — iOS 27 will not launch one without the
UIScene lifecycle — registers, subscribes, and logs the interval from the Mac's write to the banner.
Expect under 5 seconds on cellular. Record the actual number; SC-001 is built on it.

**Does the headline survive?** Write a record with three `desiredKeys` fields at 100 characters and
read what actually arrives in the payload. Record the real budget. Everything in `Headline` is sized
to this measurement, not to the documentation's "may be truncated".

---

## Phase 1 — the layout, on the phone, against a fake

No CloudKit, no crypto, no daemon. `PairedTransport` and canned data, on a real iPhone and a real
iPad — not only the simulator, because a layout is judged in the hand.

```sh
xcodebuild -scheme Remote -destination 'platform=iOS,name=<your iPhone>' build
```

Walk every screen in `contracts/ui.md` and check it against what 004 actually shipped, side by side
with the Mac:

1. Projects, then the project page — its name, the prompt bar with the folder fixed, the agents in
   groups as cards in the same gutter a conversation uses.
2. Tap an agent: the conversation **pushes**, with a back button. It is not a third column.
3. On a wide iPad the projects column stays visible. On a phone it collapses to a back destination.
4. The question, with its full command and the same choices the Mac offers.
5. The out-of-touch line — "Last heard from your Mac 12 minutes ago" — with everything below it
   dimmed and actions refused.

**This phase ends when the layout is settled, not when it is written.** That is the whole point of
doing it before the machinery: 004 built a project lead under a layout that then moved four times,
and the lead was deleted. Nothing below this line gets built until the screens have stopped changing.

---

## Phase 2 — answer from anywhere

This is the feature. The check is the story from the spec, done for real.

```sh
swift test --package-path Packages/AgentsKit --filter Envelope
swift test --package-path Packages/AgentsKit --filter Bridge
```

Unit tests must cover: a sealed envelope opens for its target; **does not** open for another device;
does not open when a routing field is edited; a sequence gap is reported rather than repaired; and
the bridge forwards a question to every approved device but a transcript entry only to the device
watching that agent.

Then, by hand, and this is the one that counts:

1. Start an agent on the Mac in a folder, with a prompt that will make it ask permission.
2. **Turn the phone's Wi-Fi off.** Walk away from the Mac.
3. The phone notifies within 5 seconds, and the banner names the project and the agent.
4. Open it, read the command in full, allow it.
5. The agent continues on the Mac within about 2 seconds, and the Mac's window shows the question
   answered rather than still pending.

Then prove the privacy claim rather than asserting it:

```sh
# The plaintext fields must say nothing. No project, agent, folder, tool or command.
# In CloudKit Console, inspect a Message record while one is in flight.
```

And prove the losers are told: with the phone open on a question, answer the same question at the
Mac. The phone must replace the buttons with "Answered on this Mac", not offer a second answer.

**Fails if**: the notification says only "An agent needs you" every time (the extension is not
decrypting); any plaintext field names anything; or the phone can answer a question twice.

## Phase 3 — the rest of the remote

1. On an iPad away from the Mac's network, select a project. Two columns, the project page filling
   the detail, the groups in order with empty ones omitted.
2. Open an agent whose conversation contains a diff and command output. Both render.
3. Scroll back through an hour of transcript. It pages; it does not stall.
4. Start an agent in that project, prompt it, stop it. All three take effect on the Mac.
5. Archive the project **on the Mac** while the iPad is looking at it. The iPad follows and moves its
   selection rather than showing an empty pane.

**Fails if**: opening a long conversation takes more than 2 seconds on cellular (SC-005), or the
groups differ in any way from the Mac's.

## Phase 4 — pairing and revoking

1. On a fresh phone, first run, one button. The Mac asks "Alex's iPhone would like to connect".
2. Approve. The phone connects without anything being typed. Time it: under 60 seconds (SC-003).
3. On the Mac, the device is listed with when it was paired and when it last connected.
4. **With the phone's app open**, revoke it on the Mac. Within 10 seconds the phone loses access and
   says so (SC-008).
5. Provoke a permission request. The revoked phone is not notified and has nothing to read.

```sh
# The mailbox must be empty of anything addressed to the revoked device.
# In CloudKit Console: query Message where to == <that device id>. Expect none.
```

**Fails if**: a revoked device still receives anything, or its old records remain.

## The two links (FR-004, FR-004a, FR-004b, FR-004c)

Both links ship. Neither is optional, and the checks below are not a phase gate on each other.

**Direct, at the desk.** On the same network as the Mac, a change appears on the remote within
1 second. No badge, no banner, nothing said about the link at all — the fast case is the quiet case.

**Relayed, away.** Off the network, the same change appears within 3 seconds, and the banner reads
"Away from your Mac's network — updates take a few seconds." Once, calmly. It must read as
geography, not as a fault.

**The handover.** Turn Wi-Fi off mid-session. The remote moves to the mailbox and keeps working,
slower, with nothing for the user to do. Turn it back on: it returns to the direct link within a few
seconds, unasked. Then do it again **with an answer in flight** — the answer is either delivered
once or reported undelivered and re-sent. Never twice, and never silently swallowed (FR-036).

**The security check, on the direct link.** This is the one most likely to be waved through, because
it is on the user's own Wi-Fi and it plainly works. Capture the traffic between device and Mac with
`tcpdump -i any -A port 8790` while a conversation is in flight and confirm there is no readable
prompt, transcript, file content, command or credential in it (SC-009, FR-004c). Then, with a device
connected and its app open, revoke it at the Mac: the connection must drop within seconds, not at
the next reconnect (FR-010).

**Fails if**: anything readable crosses either link; an unpaired device on the network can connect;
a revoked device's open connection survives; or the user is asked to choose a link.

> As of 2026-09-19 the direct link fails every part of the security check by design — it has no
> pairing and no encryption yet. See tasks T024e to T024h.

---

## The whole-feature checks

| Criterion | How to prove it |
|---|---|
| SC-001 5 s to notify | Phone on cellular, Mac elsewhere. Measure ten times, take the worst. |
| SC-004 three networks | Cellular, a café, and a network that allows nothing to connect inward. |
| SC-007 never answered twice | Script both devices to answer the same question at once, 100 times. Exactly one wins each time; the other gets `alreadyAnswered`. |
| SC-009 nothing readable | Inspect records in CloudKit Console and capture traffic. No prompt, transcript, file content, command or credential anywhere. |
| FR-038 inert until asked | With no device paired: no bridge process (`pgrep -fl AgentsRemote` is empty), and the app behaves exactly as it does today. |

## Two things to confirm behave as designed, not as bugs

- **After a reboot, nothing is reachable until the Mac app is opened once.** By design (research §7).
  The phone must say when it last heard from the Mac, not spin.
- **A sleeping Mac does not answer.** By design, and unavoidable. The same line covers it.

Both belong in the release notes, in plain words, because a user who discovers them alone will file
them as faults.
