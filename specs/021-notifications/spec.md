# Feature Specification: Notifications, Where The Person Actually Is

**Feature Branch**: `021-notifications`

**Created**: 2026-09-19

**Status**: Draft — amended 2026-09-19 for three findings raised by [plan.md](./plan.md) (FR-005b/FR-007, FR-010, SC-003)

**Input**: User description: "Notifications. When something needs user attention, but the user is away from the chat, the user should get a notification. If they're away from the computer, and at their iPad, then it should go there. Otherwise, it should go to the iPhone."

## Why this feature exists

The app already knows, exactly and in one place, when an agent needs a person: a question
asked mid-turn, or a turn that ended saying it cannot get further alone. That fact reaches
the screen — a heading, a count on a project row — and stops there. It has never once
reached the person.

So the work still waits on somebody happening to look. An agent asks for permission at
11:04 and gets it at 11:40, because 11:40 is when the window came back to the front. The
remotes were built for this and cannot help: they show what is happening only while
somebody is holding them and looking at them, which is the same problem with a smaller
screen.

What is missing is the one direction nothing has ever gone: out. Not a feed to be checked,
but a thing that arrives — and arrives in the right place, because a buzz in a pocket
while the person is reading the iPad is a notification that taught them to ignore
notifications.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - The thing that is blocked reaches the person, wherever they are (Priority: P1)

An agent asks for permission to run a command. The person is not at the Mac — they are on
a train, phone in pocket, on cellular data. Within seconds the phone buzzes, naming the
project, the agent and what is being asked. They open it, read it, and allow it. The agent
carries on.

**Why this priority**: This is the feature, and it is the whole of the value. Everything
else here is about not being annoying. On its own it turns an agent that stops dead for
half an hour into one that stops for ten seconds, and it is worth shipping even if the
routing below were a coin toss.

**Independent Test**: With the phone on cellular and the Mac on a different network, and
the Mac's screen locked, provoke a permission request. Confirm the phone is notified, that
the banner names the project and the agent and what is wanted, and that answering from the
phone lets the agent proceed on the Mac.

**Acceptance Scenarios**:

1. **Given** an agent that asks the person a question mid-turn, **When** the person is away from the Mac, **Then** a notification arrives naming the project, the agent, and what is being asked.
2. **Given** an agent whose turn ends with a report saying it is stuck, partly done, or needs an answer, **When** the person is away, **Then** a notification arrives saying which of those it is.
3. **Given** the phone is on a mobile network and the Mac is on a home network, **When** the notification is opened, **Then** the remote shows that agent's conversation with the question in full and the same choices the Mac offers.
4. **Given** the question is answered from the notification, **When** the answer reaches the Mac, **Then** the agent continues and the Mac shows the question answered rather than still pending.
5. **Given** an agent finishes cleanly with nothing outstanding, **When** the person is away, **Then** no notification is sent.
6. **Given** an agent is stopped or its process dies, **When** the person is away, **Then** no notification is sent.

---

### User Story 2 - It goes to the screen the person is looking at (Priority: P2)

The person is on the sofa with the iPad. An agent needs them. The iPad shows it. The phone,
face down on the arm of the chair, stays silent. An hour later they are out of the house
with only the phone, and the next one reaches the phone.

**Why this priority**: A notification that arrives in the wrong place is worse than none at
all, because it is a buzz that has to be dismissed and it trains the person to stop
reading them. But it is second, because a notification in the wrong pocket still reaches
the person, and no notification never does.

**Independent Test**: With both devices paired and the Mac locked, use the iPad, provoke a
need, and confirm only the iPad is notified. Put the iPad down, use the phone, provoke
another, and confirm only the phone is notified.

**Acceptance Scenarios**:

1. **Given** the person is away from the Mac and the iPad is the device they most recently used, **When** an agent needs them, **Then** the iPad is notified and the iPhone is not.
2. **Given** the person is away from the Mac and the iPhone is the device they most recently used, **When** an agent needs them, **Then** the iPhone is notified and the iPad is not.
3. **Given** the person is away from the Mac and neither device has been used recently enough to say where they are, **When** an agent needs them, **Then** the iPhone is notified.
4. **Given** the person is at the Mac but the Agents window is behind another app, **When** an agent needs them, **Then** the Mac itself notifies them and neither device does.
5. **Given** only one device is paired, **When** an agent needs the person and they are away from the Mac, **Then** that device is notified whatever it is.
6. **Given** no device is paired at all, **When** an agent needs the person and they are away from the Mac, **Then** nothing is delivered anywhere and nothing is lost — the need stays outstanding, and the next surface the person opens tells them about it.

---

### User Story 3 - Silence while the person is already looking (Priority: P2)

The person is reading the agent's conversation when it asks its question. The question
appears in front of them. Nothing buzzes, nothing lights up, and there is nothing to
dismiss afterwards.

**Why this priority**: Equal in weight to the routing, and the same argument: this is the
most common way a notification system becomes noise, because the moment an agent needs a
person is very often the moment the person is watching it. It is separated from Story 2
only because it is testable on its own and buys silence even if routing were removed.

**Independent Test**: Open an agent's conversation on the Mac and leave it frontmost.
Provoke a permission request. Confirm nothing is delivered anywhere.

**Acceptance Scenarios**:

1. **Given** the person has that agent's conversation open and in front of them, **When** that agent needs them, **Then** nothing is delivered to any device, including the one they are holding.
2. **Given** the person has a *different* agent's conversation open and in front of them, **When** an agent needs them, **Then** they are notified, on the surface they are using.
3. **Given** the person has that agent's conversation open on the iPad and in front of them, **When** that agent needs them, **Then** nothing is delivered — the rule is about the conversation being watched, not about which machine it is watched on.
4. **Given** the Mac is active with the Agents window frontmost but not showing that agent, **When** the agent needs them, **Then** a short pause is allowed for them to look before anything is delivered.
5. **Given** the Mac is locked or has been untouched past the away threshold, **When** an agent needs them, **Then** the notification is sent immediately, with no pause.

---

### User Story 4 - Answered once, gone everywhere (Priority: P3)

The person answers on the phone. The notification on the iPad disappears by itself. They
never find yesterday's notification on a device asking about a question that was settled
twenty hours ago.

**Why this priority**: Stale notifications are how the person learns that a notification is
not evidence of anything. It is third because it is only wrong after the person has already
been reached, which is the part that matters most.

**Independent Test**: Provoke a need with two devices paired and force delivery to both.
Answer on one. Confirm the other's notification is withdrawn.

**Acceptance Scenarios**:

1. **Given** a delivered notification, **When** the question is answered on any device, **Then** it is withdrawn from every device that holds it.
2. **Given** a delivered notification, **When** the question is answered at the Mac instead, **Then** it is withdrawn from every device.
3. **Given** a delivered notification for an agent that needs an answer, **When** that agent is stopped or archived, **Then** the notification is withdrawn.
4. **Given** a need that is still outstanding, **When** the person moves from the iPad to the phone, **Then** the notification is withdrawn from the iPad and delivered to the phone.
5. **Given** the person moves between devices repeatedly while the need stands, **When** each move happens, **Then** they are alerted about that same need on a new device at most once in a settled interval, rather than buzzed on every move.
6. **Given** a device was offline when a need arose and was met, **When** it comes back, **Then** it shows nothing for it.

---

### User Story 5 - A device that can be told, and taken back (Priority: P3)

The person approves their phone at the Mac once. Later they add the iPad. When the phone is
lost, they remove it at the Mac, and it is told nothing ever again.

**Why this priority**: Nothing above can be delivered to a device the Mac does not trust,
so this is built first and valued last. It is here rather than assumed because the pairing
and the sealed channel it needs were designed for the remotes and never built.

**Independent Test**: Pair a device, confirm it is notified. Revoke it at the Mac. Provoke
another need and confirm it receives nothing at all, including nothing that can be read.

**Acceptance Scenarios**:

1. **Given** an unpaired device, **When** an agent needs the person, **Then** that device is sent nothing.
2. **Given** a device that has asked to be paired and not yet been approved, **When** an agent needs the person, **Then** it is sent nothing.
3. **Given** a paired device, **When** the person revokes it at the Mac, **Then** it receives nothing from that moment, and anything already waiting for it is discarded rather than left to be read later.
4. **Given** the notification travels through a service outside the Mac, **When** it is inspected there, **Then** the project name, the agent name and what is wanted are not legible.
5. **Given** the person has not granted the device permission to show notifications, **When** an agent needs them, **Then** the Mac says so where the devices are listed, rather than appearing to work.

---

### Edge Cases

- **Several agents need the person at once.** Each is its own notification, so answering one
  does not clear the others. If more arrive than a screen can carry, the person still learns
  how many are outstanding.
- **The same agent needs the person twice in a row** — a question, answered, then another
  question. The second is a new notification, not a revival of the first.
- **The person is at the Mac, and the Mac is asleep.** Asleep is away: the notification is
  routed to a device, and the Mac shows it too when it wakes if the need still stands.
- **Two devices were touched within a second of each other.** One wins by being later; a tie
  goes to the iPhone, which is the default the person asked for.
- **A device's clock is wrong.** Presence is judged by when the Mac heard, not by what the
  device claims the time was, so a device with a fast clock cannot win every race.
- **The device is paired but has not been reachable for days.** It is not a candidate for
  "where the person is"; the iPhone default applies.
- **The need is met before the notification is delivered.** Nothing arrives, rather than
  arriving and being withdrawn a second later.
- **The daemon is not running when a need would have arisen.** There is no need, because
  there is no agent; nothing has to be caught up on restart.
- **The agent's project or agent name is empty or enormous.** The banner still identifies
  which agent it is, truncated rather than blank.

## Requirements *(mandatory)*

### Functional Requirements

**What is worth telling somebody about**

- **FR-001**: The system MUST treat an agent as needing the person when, and only when, it is blocked on them mid-turn — a permission question or a form — or its turn ended with a report saying it is stuck, partly done, or needs an answer. This is the same rule the screen already uses to group an agent under "Needs attention"; there MUST NOT be a second definition.
- **FR-002**: The system MUST NOT notify for an agent that finished cleanly with nothing outstanding, was stopped, died, or was archived.
- **FR-003**: Each outstanding need MUST produce at most one live notification across all of the person's surfaces at any moment.
- **FR-004**: A notification MUST name the project, the agent, and what is wanted, in enough detail to decide whether to act now.

**Where it goes**

- **FR-005**: The system MUST decide where to deliver by the following ladder, in order, taking the first that applies: (a) the person is watching that agent's conversation — deliver nothing; (b) the person is at the Mac *and a Mac surface is connected to say so* — the Mac notifies; (c) the most recently used paired device — that device notifies; (d) otherwise — the iPhone notifies.
- **FR-006**: The system MUST judge "watching that agent's conversation" as: a surface is showing that conversation, is in front of the person, and has been interacted with recently.
- **FR-007**: The system MUST judge "at the Mac" as: a Mac surface is connected and reporting itself in front of the person, having been heard from within a short threshold. A Mac with no window connected is not "at the Mac", however awake the machine is — nothing else on the Mac can post a banner, so the ladder MUST move on rather than deliver to a surface that cannot show anything.
- **FR-008**: The system MUST judge "most recently used device" from when each device last reported the person interacting with it, disregarding any device that has not been heard from within a staleness horizon.
- **FR-009**: When no paired device is recent enough to say where the person is, the system MUST deliver to the iPhone, and when several iPhones are paired, to the most recently used one.
- **FR-010**: When no surface can be delivered to at all — no Mac window connected, and no device paired, reachable or permitted to show notifications — the need MUST wait rather than be dropped: it stays outstanding in the daemon's record, and the next surface to connect MUST be told about it on connecting. The news is never lost, because a need lives in the record and not in the notification.
- **FR-011**: Every surface — the Mac window and each remote — MUST report to the daemon when the person interacts with it, when it comes to the front or goes behind, and which conversation it is showing, so that the ladder above has facts to run on.
- **FR-012**: The daemon MUST be the one place that decides where a notification goes. No surface may decide for itself whether it is the right one to alert.

**When it goes**

- **FR-013**: When the person is plainly away — the Mac locked, asleep, or untouched past the threshold — the system MUST deliver immediately, without waiting to see whether they come back.
- **FR-014**: When the person is at the Mac but not watching that conversation, the system MUST allow a brief settling pause before delivering, and MUST NOT deliver if the need is met or they begin watching within it.
- **FR-015**: The system MUST NOT deliver a notification for a need that has already been met.

**What happens afterwards**

- **FR-016**: When a need is met — answered anywhere, or the agent stopped or archived — the system MUST withdraw its notification from every surface holding it.
- **FR-017**: When a need is still outstanding and the person moves to a different surface, the system MUST withdraw the notification from where it was and deliver it where they now are.
- **FR-018**: The system MUST NOT re-alert the same person about the same need more than once within a settled interval, however many times they change surfaces.
- **FR-019**: Opening a notification MUST take the person to that agent's conversation, with what is wanted in front of them and answerable there.

**Being allowed to**

- **FR-020**: The system MUST deliver only to devices the person has approved at the Mac.
- **FR-021**: Revoking a device MUST stop delivery to it immediately and discard anything already waiting for it unread.
- **FR-022**: What a notification says MUST NOT be legible to any service it passes through outside the person's own devices.
- **FR-023**: The system MUST show the person, where their devices are listed, which of them are able to show notifications and which have not been permitted to, rather than silently failing to reach one.
- **FR-024**: A device MUST be asked for permission to show notifications at a point where the person can see why it is being asked, not on first launch with no context.

### Key Entities *(include if data involved)*

- **Need**: One outstanding call on the person's attention, belonging to one agent. Comes into being when the agent becomes blocked or reports it cannot finish alone; ends when it is answered, or the agent is stopped or archived. Identity matters: the same agent asking twice is two needs.
- **Presence**: What the daemon believes about where the person is. One record per surface — the Mac window and each paired device — holding when it was last interacted with, whether it is in front of the person, and which conversation it is showing. Derived from what surfaces report; never guessed and never stored beyond the session.
- **Device**: A remote the person has approved, with a name, a kind (iPhone or iPad), and whatever is needed to reach it and to seal what is sent. Approved or absent; there is no third state.
- **Delivery**: The record of a given need having been put in front of the person on a given surface, so that it can be withdrawn again and so that FR-018's interval has something to measure.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: With the person away from the Mac and on a mobile network, a blocked agent reaches them within 5 seconds, in at least 9 of 10 trials.
- **SC-002**: Across the four cases of the routing ladder, the notification arrives on the intended surface and no other, in 100% of trials.
- **SC-003**: A need met on one surface is cleared from every other surface that is in the foreground within 5 seconds, in 100% of trials; from a backgrounded device, by the time that device is next opened. Waking a backgrounded device to withdraw a banner is throttled by the operating system and cannot be promised to a deadline.
- **SC-004**: While the person is watching an agent's conversation, that agent produces zero notifications on any surface.
- **SC-005**: Every delivered notification names the project, the agent and what is wanted; none shows a placeholder.
- **SC-006**: Moving between devices ten times while one need stands produces at most two alerts about it.
- **SC-007**: A revoked device receives nothing, and nothing already sent to it can be read, in 100% of trials.
- **SC-008**: The median time from an agent becoming blocked to the person answering falls by at least 75% against the same work done with no notifications.
- **SC-009**: In a week of ordinary use, every notification the person receives corresponds to an agent that was still waiting on them when they read it.

## Assumptions

- The pairing between the Mac and each device, the sealed channel that carries a message to a device that is not on the same network, and the record of an approved device were all designed for the remotes and never built. They are prerequisites, and this feature carries them.
- The existing rule for when an agent needs a person is correct and is reused unchanged; this feature adds no new reason for an agent to want attention.
- "Away from the computer" is judged by the Mac being locked, asleep, or idle past a threshold, rather than by anything about the person's location.
- Presence is a live fact, not a history. It is not written to disk, and after a restart the person's whereabouts are unknown until a surface says otherwise — at which point the iPhone default (FR-009) carries the load.
- The person has at most a handful of devices, all their own. There is no notion of several people, and no notification is ever routed to somebody else.
- The Mac can show a notification locally without any of the pairing machinery, but only while an Agents window is connected: the daemon is not an app and cannot post a banner on its own. That is why FR-010's last resort is waiting rather than falling back to the Mac.
- One iPhone and one iPad is the ordinary case; the requirements say what happens with more, but that case is not designed for.

## Out of Scope

- Choosing which kinds of notification each device receives. Every approved device is eligible for everything this feature sends; per-device preferences are a later feature if the person wants one.
- Notifying about agents that finished cleanly or stopped unexpectedly. Both were considered and deliberately left out: neither is waiting on an answer.
- Quiet hours, do-not-disturb rules and scheduled silence. The system's own rules for silence are FR-005(a) and FR-014; the operating system's are the person's to set.
- A watch, a widget, an email or any surface other than the Mac and the two remotes.
- Acting on a notification without opening the app. The person opens it and answers in the conversation.
- Any notification sent by an agent of its own accord. What reaches the person is decided by the rules here, not by an agent asking.
