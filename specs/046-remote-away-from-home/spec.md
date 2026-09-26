# Feature Specification: Remote Works Away From Home

**Feature Branch**: `agents/ios-works-when-not`

**Created**: 2026-09-25

**Status**: Draft

**Input**: User description: "Remote works away from home (CloudKit relayed link). The phone/iPad keeps working on any network. On the same Wi‑Fi it uses the direct link as it does today. Otherwise it switches to a relayed link through the person's iCloud private database, and switches back when the direct link returns, without the person doing anything. Pairing happens once, on the same network. Every message is sealed to its recipient, so iCloud sees only ciphertext. Degraded on purpose: a round trip takes about 1–3 s. Works away: project list, agent list, chat read and send, questions and permissions, start agent, stop/archive, events list. Not away: terminal, live page, typing into shells, large file browsing. An always-visible 'Away — slower' indicator."

## Why this feature exists

005 promised a phone that reaches the Mac from anywhere (005 FR-001), over two links: a direct one
at home and a relayed one everywhere else (005 FR-004). Only the direct one was built. Today, the
moment the phone leaves the Mac's Wi‑Fi, it says it cannot reach the Mac and shows what it last
knew, dimmed. A notification still arrives through iCloud, saying an agent needs an answer, and
the person can do nothing with it until they are home.

That is backwards. The phone matters most when the person is *not* at the desk: on the train, at
lunch, in another room on a different network. The question the agent is waiting on is a
one-word answer; the prompt they want to send is a sentence. Neither needs a fast link. Both need
*a* link.

**This feature builds the relayed link.** Away from the Mac's network, the phone and iPad carry on
through the person's own iCloud, more slowly and with less on offer, and say so plainly. At home
they use the direct link, as now. The person never chooses between them.

## Defaults taken *(Alex to confirm or overturn)*

**Look gate approved by Alex 2026-09-25** on `look/away-mock.png` (away mark, needs-the-same-network pane, never-paired projects).

Each has a default so the spec is complete; each is marked where it is used as *(default Dn)*.

- **D1. Pairing is automatic on the same network.** *(Confirmed by Alex 2026-09-25.)* The first time a device connects on the direct
  link, it and the Mac swap public keys, and from then on it may use the relayed link. There is no
  code to type and no approval step at the Mac. This keeps today's direct-link trust (anyone on the
  home network can already drive agents) and adds nothing weaker. *Alternative: the Mac shows the
  new device and the person approves it once before it may use the relay (005 FR-007).*
- **D2. Away means the everyday actions, not the rich ones.** Available away: projects, agents,
  reading and sending in a chat, answering questions and permissions, starting an agent, stopping
  and archiving, changing mode or model, the events list, and running a workflow. Not available
  away: the terminal, the live page, typing into shells, browsing files, and attaching files or
  pictures. *Alternative: small attachments (a photo) allowed away.*
- **D3. The relay carries only the person's own iCloud.** The Mac and the device must be signed in
  to the same iCloud account. Nothing passes through a server we run.
- **D4. The bridge is still started by hand.** Making the Mac start it by itself is alpha-scope work
  and separate from this feature; while the bridge is not running, neither link works.
- **D5. The direct link is unchanged.** It stays unsealed on the home network as today; sealing it
  is the security-review branch's work, not this one.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Answer an agent from anywhere (Priority: P1)

The person is out, on mobile data. An agent on the Mac asks a permission question; the phone shows
the notification. They tap it, the app opens on that agent, a small "Away — slower" mark sits at
the top, and the question card is there. They tap Allow. A second or two later the card goes, and
on the Mac the agent carries on.

**Why this priority**: It is the case that hurts today: a notification that cannot be acted on. An
agent stuck on a question for hours is the cost.

**Independent Test**: With the phone on mobile data (Wi‑Fi off) and paired, start an agent on the
Mac that asks a permission. On the phone, open it and answer. The agent on the Mac proceeds within
a few seconds, and the phone shows the answer taken.

**Acceptance Scenarios**:

1. **Given** a paired phone off the Mac's network, **When** an agent asks a permission, **Then** the
   phone shows the card within about 5 seconds of opening the app, and answering it reaches the Mac
   within about 3 seconds.
2. **Given** the same, **When** an agent asks a question with options, **Then** the person can pick
   an option or type an answer, and the agent receives it.
3. **Given** the person answered on the Mac first, **When** the phone next hears from the Mac,
   **Then** the card goes from the phone without an error.

---

### User Story 2 - Carry on a conversation away (Priority: P1)

Away from home, the person opens a project, sees its agents, opens one and reads where it got to.
They type a prompt and send it. The prompt appears at once, marked as sending; within a few
seconds it is confirmed and the agent's reply starts to arrive, in larger steps than at home but
without gaps or repeats.

**Why this priority**: Reading and sending is what "keeps working" means for this app. Without it
the relay is a remote control for one button.

**Independent Test**: Off the home network, open a project, open an agent, send "list the files in
this folder". The reply arrives in full and matches what the Mac window shows.

**Acceptance Scenarios**:

1. **Given** a paired phone away, **When** the person opens the app, **Then** the project list and
   each project's agents appear within about 5 seconds.
2. **Given** a chat open away, **When** the agent writes, **Then** new text appears on the phone
   within about 3 seconds of appearing on the Mac, in order, with nothing twice.
3. **Given** a sent prompt, **When** it reaches the Mac, **Then** it is sent once, even if the
   phone retried.
4. **Given** the person is away, **When** they start a new agent, stop one, or archive one, **Then**
   it happens on the Mac and the phone shows the result.

---

### User Story 3 - Moving between home and away without noticing (Priority: P1)

The person walks out of the house mid-conversation. The phone loses Wi‑Fi. Within a few seconds the
"Away — slower" mark appears and the chat keeps updating. Nothing they had typed is lost. When they
come home, the mark disappears and the chat is instant again. They never pressed anything.

**Why this priority**: 005 FR-004a. A link the person has to switch by hand is a link they will
think is broken.

**Independent Test**: With a chat open on Wi‑Fi, turn Wi‑Fi off; wait; send a prompt; turn Wi‑Fi
back on. The indicator follows each change, the prompt is delivered once, and the chat has no gap.

**Acceptance Scenarios**:

1. **Given** the direct link drops, **When** the relayed link is available, **Then** the phone is
   working over the relay within about 10 seconds, without the person acting.
2. **Given** the phone is on the relay, **When** the direct link becomes available, **Then** the
   phone moves back to it within about 10 seconds, and the indicator goes.
3. **Given** a prompt or answer sent at the moment the link changed, **Then** it reaches the Mac
   exactly once.
4. **Given** both links are available, **Then** the phone uses the direct one.

---

### User Story 4 - Knowing what works away (Priority: P2)

Away, the person opens an agent and taps its terminal. Instead of a blank screen or a spinner, they
see the terminal's place with a line: "Needs the same network as your Mac." The same for the live
page, the files, and attaching a picture. Everything else in the app looks and works as at home,
only slower.

**Why this priority**: Without it the person meets features that silently fail and blames the app
for all of it.

**Independent Test**: Away, try each of terminal, live page, files and attach. Each shows the
"needs the same network" state; none spins, errors or hangs.

**Acceptance Scenarios**:

1. **Given** the phone is away, **When** the person opens something not available away *(default
   D2)*, **Then** it says it needs the same network as the Mac and offers nothing that would fail.
2. **Given** that screen is open, **When** the phone moves back to the direct link, **Then** it
   becomes the real thing without the person reopening it.
3. **Given** the phone is away, **Then** the "Away — slower" mark is visible on every screen.

---

### User Story 5 - Pairing once, at home (Priority: P2)

The person has used the phone at home before. They do nothing special: the next time the phone is
on the Mac's network, it pairs by itself *(default D1)*. From then on it works away. A phone that
has never been on the Mac's network, or that the person has revoked, cannot use the relay, and
says to open the app once on the same network as the Mac.

**Why this priority**: The relay is only safe for devices the Mac knows. It is P2 because on the
person's own phone it is invisible; it matters for the phone that is not theirs.

**Independent Test**: Install the app fresh on a second device and take it off the home network
first: it says to connect once at home. Bring it home, open it, take it away: it works. Revoke it on
the Mac: within a minute it stops working away and says why.

**Acceptance Scenarios**:

1. **Given** a device never paired, **When** it is away, **Then** it shows "Open once on the same
   network as your Mac to use it away" and sends nothing through the relay.
2. **Given** a device connects on the direct link, **Then** it and the Mac learn each other's keys
   with no action from the person, and the Mac lists it among paired devices.
3. **Given** a paired device is revoked at the Mac, **Then** the Mac ignores anything it sends
   through the relay from then on, and the device says it is no longer paired.

---

### Edge Cases

- **The Mac is asleep or the bridge is not running.** Away, the phone waits, then shows "Can't
  reach your Mac" with when it last heard, as today; it does not claim to be connected.
- **iCloud is signed out or full on either side.** The phone says the relay needs iCloud on both
  devices, rather than hanging.
- **iCloud slows the app down (throttling).** Both sides wait as long as iCloud asks before trying
  again; the phone shows "Slower than usual" rather than failing.
- **A push from iCloud never arrives at the Mac.** The Mac still checks on its own every few seconds,
  so a message is picked up regardless.
- **A reply is too large for one message** (a long agent list or a long chat). It is compressed, and
  carried as a file attachment when still too large; the phone receives it whole.
- **Messages arrive out of order or twice.** Each side puts them in order and drops repeats.
- **Old messages left behind.** Each side deletes what it has read; anything older than a day is
  removed, so iCloud does not fill with ciphertext.
- **Two devices away at once** (phone and iPad). Each has its own relayed session; they agree as at
  home.
- **The person's Wi‑Fi is a different network with the same name.** The direct link is used only if
  the Mac is actually found and answers; otherwise the relay.
- **A permission card open while the link changes.** It stays, and answering it goes on whichever
  link is current.

## Requirements *(mandatory)*

### Functional Requirements

#### Reach and choice of link

- **FR-001**: A paired device MUST reach the Mac's agents from any network that reaches iCloud,
  including mobile networks, with the Mac on a different network (005 FR-001).
- **FR-002**: The device MUST try both links at once and use the direct link whenever it works,
  the relayed link otherwise, and move between them without the person acting (005 FR-004a).
- **FR-003**: A request or answer sent while the link changes MUST reach the Mac exactly once;
  the Mac MUST drop a repeat of a request it has already carried out.
- **FR-004**: The relayed link MUST need nothing from the person beyond having been on the Mac's
  network once and being signed in to the same iCloud account on both *(default D3)*. No port, no
  address, no account of ours (005 FR-002).

#### Privacy and trust

- **FR-005**: Everything sent over the relayed link MUST be sealed so that only its one recipient
  (the Mac, or that one device) can read it. iCloud MUST see only data it cannot read (005 FR-003).
- **FR-006**: The Mac MUST have a lasting key pair of its own, kept in its secure store, and MUST
  give its public key to a device when the device pairs.
- **FR-007**: Pairing MUST happen when a device connects on the direct link, with no action from the
  person *(default D1)*, and MUST record the device among the Mac's paired devices.
- **FR-008**: The Mac MUST ignore anything arriving through the relay that is not sealed by a
  currently paired device, and a revoked device MUST be refused within a minute.
- **FR-009**: A device that is not paired MUST NOT send anything through the relay, and MUST tell the
  person to open the app once on the Mac's network.

#### What works away

- **FR-010**: Over the relayed link the device MUST offer: the project list; each project's agents;
  reading a chat and following it as it grows; sending a prompt; answering permissions and
  questions; starting an agent; stopping and archiving an agent; changing an agent's mode or model;
  the events list; and running a workflow *(default D2)*.
- **FR-011**: Over the relayed link the terminal, the live page, typing into a shell, browsing files
  and attaching files MUST show that they need the same network as the Mac, and MUST NOT spin, hang
  or error *(default D2)*.
- **FR-012**: When the device moves back to the direct link, a screen from FR-011 that is open MUST
  become the working screen without being reopened.

#### Telling the person

- **FR-013**: While on the relayed link, the device MUST show an "Away — slower" mark on every
  screen (005 FR-004b), and MUST remove it within seconds of moving back to the direct link.
- **FR-014**: The device MUST say, in words, when the Mac cannot be reached over either link, when
  iCloud is unavailable on the device, and when iCloud is asking it to slow down.

#### Carrying messages

- **FR-015**: The Mac MUST notice a new message from a device within a few seconds, whether or not
  iCloud tells it one has arrived.
- **FR-016**: Replies and updates too large for one relayed message MUST be compressed and, if still
  too large, carried whole in a larger attachment; the device MUST receive them complete.
- **FR-017**: Each side MUST delete relayed messages once it has read them, and MUST remove any left
  unread after a day.
- **FR-018**: Both sides MUST honour iCloud's requests to wait before trying again.
- **FR-019**: Updates the device follows at home (agent list changes, chat growth, questions
  appearing and going) MUST also reach it over the relay, batched, within about 3 seconds.

### Key Entities

- **Mac key**: The Mac's lasting key pair. Its public half is given to each device at pairing; its
  private half never leaves the Mac's secure store.
- **Device key**: Each device's own key pair (exists). Its public half is given to the Mac at
  pairing and is how the Mac knows the device.
- **Paired device**: A device the Mac knows by its key, with its name, when it was paired and when
  it last connected; can be revoked.
- **Relayed session**: One device's conversation with the Mac over the relay: its requests, the
  Mac's replies and updates, in order, each delivered once.
- **Relayed message**: One sealed piece of a session in the person's iCloud, readable only by its
  recipient, deleted once read.
- **Link**: Which way the device is reaching the Mac right now: direct, relayed, or none.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Away, answering a permission reaches the Mac within 3 seconds in 9 of 10 tries on a
  normal mobile connection.
- **SC-002**: Away, opening the app shows the project list and agents within 5 seconds.
- **SC-003**: Away, a sent prompt is confirmed within 3 seconds, and the agent's reply text reaches
  the phone within 3 seconds of reaching the Mac window.
- **SC-004**: Leaving and rejoining the Mac's network changes link within 10 seconds each way, with
  no prompt or answer lost or sent twice across 10 changes.
- **SC-005**: Nothing readable (prompt, reply, file name, command) can be found in the person's
  iCloud data for the app; only sealed data.
- **SC-006**: Every feature not available away shows "needs the same network" rather than failing;
  none spins for more than a second.
- **SC-007**: A device that has never been on the Mac's network, or has been revoked, cannot drive
  an agent through the relay.

## Docs *(mandatory)*

- `docs/explanation/phone-and-ipad.md` — change: "Two ways to reach you" and "The connection today"
  describe the relayed link, pairing on the home network, what works away and why it is slower.
- `docs/tutorials/follow-from-iphone.md` — change: a closing step showing the "Away — slower" mark
  and answering from mobile data.
- `docs/reference/statuses.md` — change: add the phone's link states (direct, away, can't reach,
  needs the same network).

## Open risks

- **iCloud throttling.** iCloud may slow the app down if it writes and reads too often; a busy chat
  away is the likely trigger. Both sides back off as asked (FR-018); batching updates (FR-019) keeps
  the rate down. Measured in the live walk.
- **Pushes to the Mac.** Whether iCloud's notice of a new record reaches the Mac's bridge (a command
  line helper, not an app) is unproven. The Mac polls every few seconds regardless (FR-015), so the
  cost of no push is latency and requests, not correctness.
- **The bridge is started by hand** *(default D4)*. Away, the person cannot start it; if it stopped,
  the phone can only say it cannot reach the Mac.

## Assumptions

- The phone and the Mac are signed in to the same iCloud account, and the iCloud container 005 set
  up is already enabled for both (spike passed in 021).
- The Mac is awake with the bridge running when the person is away; keeping it awake is not this
  feature.
- A round trip of 1–3 seconds is acceptable for everything offered away; the person was told it is
  slower.
- The direct link keeps its present behaviour and security *(default D5)*.
- Notifications through iCloud (existing) are unchanged; tapping one away now opens a working screen.
