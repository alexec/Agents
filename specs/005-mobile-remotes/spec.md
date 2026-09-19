# Feature Specification: Remotes for iPhone and iPad

**Feature Branch**: `005-mobile-remotes`

**Created**: 2026-09-18

**Status**: Draft

**Input**: User description: "I want to have iPhone and iPad remotes. This allows me to leave the app and continue my work elsewhere. These need to build on top of the 0004 project ui uplift. They must work without being on the same WiFi."

## Why this feature exists

An agent works for minutes at a time and then stops dead, waiting for one word from the user. Today
that word can only be said at the Mac. So the user does not leave. They sit and watch a progress
meter, or they go out and come back to four agents that each stopped after ninety seconds and have
been idle since.

The work is already somewhere else: it runs on the Mac, in the daemon, whether a window is open or
not. What is missing is a way to be asked. A phone that buzzes with "the agent wants to run this
command" and lets the user say yes turns a lost afternoon into a walk. An iPad with a keyboard turns
the sofa into a second desk.

And it has to work from a train. A remote that only works on the home network solves the problem of
being in the next room, which nobody has.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Answer the thing that is waiting, from anywhere (Priority: P1)

The user leaves the house with agents running. Twenty minutes later their phone buzzes: an agent in
a project wants permission to run a command. They open the notification, read what it wants to do and
why, and allow it. The agent carries on. They put the phone away.

**Why this priority**: This is the feature. Everything else is comfort around it. On its own it turns
the Mac from something the user must sit at into something that can be checked on, and it is worth
shipping even if the remote can do nothing else.

**Independent Test**: With the phone on cellular data and the Mac on a different network, provoke a
permission request on the Mac, confirm the phone is notified, answer from the phone, and confirm the
agent proceeds on the Mac.

**Acceptance Scenarios**:

1. **Given** a paired iPhone and an agent on the Mac that asks for a permission, **When** the request
   arrives, **Then** the phone is notified, naming the project and the agent and what is being asked.
2. **Given** the phone is on a mobile network and the Mac is on a home network, **When** the user opens
   the remote, **Then** it connects and shows current state, with no shared network and no setup on the
   spot.
3. **Given** the notification is opened, **When** the remote draws, **Then** it shows the permission
   request in full, including the command or change it covers, and the same choices the Mac offers.
4. **Given** the user answers on the phone, **When** the answer reaches the Mac, **Then** the agent
   continues, and the Mac's window shows the request answered rather than still pending.
5. **Given** the remote is open, **When** an agent on the Mac changes state, **Then** the remote follows
   within a second, without the user pulling to refresh.
6. **Given** a request is answered at the Mac first, **When** the phone shows it, **Then** the phone
   updates to say it is already answered and by whom, rather than offering a second answer.
7. **Given** the user reads an agent's conversation on the phone, **When** they type a prompt and send
   it, **Then** the agent takes it, exactly as if it had been typed at the Mac.

---

### User Story 2 - Keep working from the iPad (Priority: P2)

The user takes the iPad to the sofa. It shows the same three panes the Mac does: projects, the
project's agents in their groups, and the conversation. They read what an agent did, start another
agent in the same project, and answer two permissions without getting up.

**Why this priority**: A phone is for answering; a tablet is for working. This is the difference
between checking on the work and doing it. It is second because the phone alone already stops the
user being pinned to the desk.

**Independent Test**: On an iPad away from the Mac's network, select a project, read an agent's
transcript including a diff and command output, start a new agent in that project, prompt it, and stop
it.

**Acceptance Scenarios**:

1. **Given** an iPad in landscape, **When** the remote draws, **Then** it shows projects, the selected
   project's grouped agents and the conversation together, the same shape as the Mac.
2. **Given** an iPhone, or an iPad in a narrow window, **When** the remote draws, **Then** the same
   three levels are reached one at a time, and going back returns to the level above.
3. **Given** a project is selected, **When** the agents draw, **Then** they are grouped "Needs input",
   "Working" and "Completed", in that order, with empty groups omitted, as on the Mac.
4. **Given** an agent's conversation is open, **When** it contains a diff, command output or a file a
   tool touched, **Then** the remote shows it, laid out for the screen it is on.
5. **Given** a project is selected on the iPad, **When** the user starts an agent, **Then** it starts in
   that project's folder on the Mac, with the runtimes the Mac has.
6. **Given** an agent is running, **When** the user stops it from the iPad, **Then** it stops on the
   Mac.
7. **Given** a project is archived on the Mac, **When** the remote is looking at it, **Then** the remote
   follows, and the selection moves rather than leaving an empty screen.

---

### User Story 3 - Pair a device, and take it back (Priority: P3)

The user adds their phone once, at the Mac. Later they add the iPad. When the phone is lost, they
remove it from the Mac and it can no longer see anything.

**Why this priority**: Nothing works without pairing, so it is built first, but it is the least of what
the user gets. It is here rather than in P1 because the value the user feels is being asked on the
train, not the ten seconds of setup that made it possible.

**Independent Test**: Pair a device at the Mac, confirm it connects; revoke it at the Mac, and confirm
it can no longer connect or read anything, including with the app already open.

**Acceptance Scenarios**:

1. **Given** the Mac app and a fresh device, **When** the user pairs them, **Then** it takes one short
   exchange at the Mac and no account, sign-up or typed address.
2. **Given** a paired device, **When** it is opened days later on a different network, **Then** it
   connects without pairing again.
3. **Given** the Mac, **When** the user looks at paired devices, **Then** each is listed by name, when
   it was added and when it last connected.
4. **Given** a paired device, **When** the user revokes it at the Mac, **Then** it loses access within
   seconds, including if its app is open at the time, and it holds nothing readable afterwards.
5. **Given** an unpaired device with the app installed, **When** it tries to connect, **Then** it is
   refused and shown how to pair.
6. **Given** a pairing exchange is watched by someone else on the network, **When** it completes,
   **Then** what they saw does not let them connect.

---

### Edge Cases

- **The Mac is asleep, off, or has no network.** The remote says so plainly, with when it last heard
  from it, and shows the last state it knew, marked as stale and read-only. Nothing the user types is
  silently swallowed: an action that cannot be delivered is refused at the moment it is taken.
- **No window is open on the Mac.** The daemon holds the agents whether the window is there or not, so
  the remote reaches them anyway. The daemon does not exit while a remote is connected or while a
  paired device could still be asked to answer something.
- **The connection drops mid-answer.** The answer is either delivered once or not at all. When the
  remote comes back it shows what actually happened rather than assuming it worked.
- **Two remotes and the Mac all see the same request.** The first answer wins. The others are told it
  was answered, and by which device.
- **The request times out or the agent is stopped while the phone is open.** The phone replaces the
  question with what became of it.
- **A notification arrives for something already dealt with.** Opening it lands on the agent, showing
  the resolved state, not an empty question.
- **A cellular connection with an hour of transcript.** The remote fetches what is being looked at, not
  everything, and reading further asks for more.
- **The phone is lost.** Revoking at the Mac is enough. No data on the lost phone is readable without
  the device unlocked, and nothing the phone kept can be used to reconnect.
- **The Mac's folder for a project is gone.** As on the Mac: the project is marked missing, agents stay
  readable, and starting a new agent in it is refused with a sentence saying why.
- **An agent wants a file or a screenshot.** Attachments from the phone's camera roll or files are in
  scope for prompts; a runtime that cannot take them refuses before sending, as it does on the Mac.
- **The remote is open when the Mac's app quits.** The agents keep running and the remote keeps
  working, because it is talking to the daemon, not the window.
- **Both remotes open at once.** They agree. A change made on one is on the other within a second.

## Requirements *(mandatory)*

### Functional Requirements

#### Reach

- **FR-001**: The system MUST let a paired device reach the Mac's agents from any network, including
  mobile networks, networks that do not allow anything to connect inward, and networks the Mac has never seen. Being on the
  same local network MUST NOT be required.
- **FR-002**: The system MUST NOT require the user to configure a router, open a port, type an address
  or run a separate service to achieve FR-001.
- **FR-003**: The system MUST NOT expose any readable agent content, prompt, transcript, file, command
  output or credential to any intermediary that carries the connection. Anything in the middle MUST see
  only data it cannot read.
- **FR-004**: The system MUST carry the remote over two links and choose between them itself: a
  **direct link** when the device and the Mac are on the same local network, and a **relayed link**
  through an intermediary when they are not. Neither is optional. The direct link exists because
  being at the desk should feel instant; the relayed link exists because FR-001 is the point of the
  feature.
- **FR-004a**: The system MUST prefer the direct link whenever it is available, MUST move to the
  relayed link when it is not, and MUST make that change without the user doing anything and without
  losing an action in flight.
- **FR-004b**: The system MUST tell the user which link it is on, because the two have honestly
  different speeds (SC-006) and a user who sees seconds where they saw milliseconds is owed the
  reason rather than left to suspect a fault.
- **FR-004c**: Both links MUST meet FR-003 and FR-008 in full. The direct link being on the user's
  own network MUST NOT be treated as a reason to send anything in the clear or to accept an unpaired
  device: a home network is not a trusted network, and the same pairing and the same sealing apply
  to both.
- **FR-005**: The daemon MUST accept a connection from a paired device while no Mac window is open, and
  MUST NOT exit while a remote is connected.
- **FR-006**: The system MUST show the user, on the remote, whether it is connected, and when it last
  heard from the Mac.

#### Pairing and trust

- **FR-007**: Users MUST be able to pair a device by an exchange begun at the Mac, with no account,
  sign-up, or typed address or code longer than a short one shown on screen.
- **FR-008**: The system MUST make an observer of the pairing exchange unable to connect afterwards.
- **FR-009**: The system MUST list paired devices on the Mac, each with its name, when it was paired and
  when it last connected.
- **FR-010**: Users MUST be able to revoke a device at the Mac, and revocation MUST take effect within
  seconds even for a device that is connected at the time.
- **FR-011**: The system MUST refuse any device that is not paired, and MUST say how to pair rather than
  failing silently.
- **FR-012**: A remote MUST require the device's own unlock before showing any agent content.
- **FR-013**: The system MUST NOT put agent content, transcripts or secrets anywhere a revoked or lost
  device can still read them.

#### Being told

- **FR-014**: The system MUST notify a paired device when an agent needs the user: a permission request
  or a form awaiting an answer.
- **FR-015**: A notification MUST name the project, the agent and what is being asked, enough to decide
  whether it is worth opening.
- **FR-016**: The system MUST notify when an agent finishes and when an agent stops on an error, and
  users MUST be able to turn each kind of notification off independently, per device.
- **FR-017**: Opening a notification MUST land on the agent it names, showing whatever that agent's
  state is by then.
- **FR-018**: The system MUST NOT notify a device about something that has already been answered.
- **FR-019**: Notification content MUST NOT be readable by any service that carries it.

#### What the remote shows

- **FR-020**: The remote MUST use the same shape as feature 004: projects, then that project's agents
  grouped "Needs input", "Working" and "Completed" in that order with empty groups omitted, then the
  conversation.
- **FR-021**: The remote MUST show which projects have an agent needing the user, on the project row, as
  the Mac does.
- **FR-022**: The remote MUST show a conversation's transcript, including diffs, command output and
  files a tool call touched, laid out for the screen it is on.
- **FR-023**: The remote MUST show an agent's cost and context usage, as reported, not estimated.
- **FR-024**: The remote MUST show archived agents for a project on request, newest first, in batches,
  as the Mac does.
- **FR-025**: The remote MUST reflect a change made on the Mac, or on another remote, within one second
  while it is open and connected.
- **FR-026**: On a wide iPad the remote MUST show projects, agents and conversation together; on a phone
  or a narrow window it MUST show one at a time with a way back.

#### What the remote can do

- **FR-027**: Users MUST be able to answer a permission request from a remote, with the same choices the
  Mac offers.
- **FR-028**: Users MUST be able to answer a form request from a remote.
- **FR-029**: Users MUST be able to send a prompt to an existing agent from a remote, including
  attachments chosen from the device, subject to the same refusal when a runtime cannot take them.
- **FR-030**: Users MUST be able to start an agent in an existing project from a remote, choosing from
  the runtimes the Mac has.
- **FR-031**: Users MUST be able to stop a running agent, and to archive and unarchive an agent, from a
  remote.
- **FR-032**: The system MUST resolve each request exactly once no matter how many devices answer, MUST
  tell the losers it was already answered and by which device, and MUST NOT apply a second answer.
- **FR-033**: The system MUST refuse an action it cannot deliver, at the moment it is taken, rather than
  appearing to accept it.
- **FR-034**: An action taken on a remote MUST have the same effect as the same action on the Mac, and
  MUST be recorded the same way.

#### Staying honest

- **FR-035**: The remote MUST mark state as stale when it has lost touch with the Mac, and MUST NOT
  offer actions against stale state.
- **FR-036**: The system MUST NOT lose or duplicate an answer when the connection drops mid-flight.
- **FR-037**: The system MUST fetch transcript on demand rather than the whole history at once, so that
  a long conversation opens quickly on a mobile connection.
- **FR-038**: The Mac MUST remain fully usable when no device is paired, and MUST NOT require any of
  this to be set up.

### Key Entities

- **Remote**: An iPhone or iPad running the app in remote form. Sees the Mac's projects and agents; owns
  none of them. Holds no agent record of its own beyond what it is currently showing.
- **Paired device**: The Mac's record of a remote it trusts. Has a name, when it was paired, when it
  last connected, which notifications it wants, and the means to verify it. Revocable.
- **Project, Agent, Agent group**: Unchanged from feature 004. The remote is another view of them, not a
  copy.
- **Notification**: A message to a device that an agent wants something or has finished. Names the
  project and agent. Carries no readable content outside the device.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: With the phone on a mobile network and the Mac on an unrelated network, a permission
  request on the Mac reaches the phone as a notification within 5 seconds.
- **SC-002**: From the notification, the user can read the request and answer it in under 15 seconds,
  and the agent resumes on the Mac within 2 seconds of the answer.
- **SC-003**: Setting up a new device takes under 60 seconds, with no account, no typed address and no
  router change.
- **SC-004**: The remote works on the first try from at least three networks the Mac has never been on,
  including a mobile network and one that allows nothing to connect inward.
- **SC-005**: A conversation with an hour of transcript opens to something readable in under 2 seconds
  on a mobile connection.
- **SC-006**: A change on the Mac is on an open remote within 1 second on the direct link, and
  within 3 seconds on the relayed link, and the reverse. The two figures are separate on purpose: a
  store-and-forward round trip is seconds, and quoting a socket's number for it would be a promise
  the relayed link cannot keep.
- **SC-007**: No permission request is ever answered twice, across 100 attempts to answer the same
  request from two devices at once.
- **SC-008**: A revoked device loses access within 10 seconds and can read nothing afterwards.
- **SC-009**: Traffic captured anywhere between the device and the Mac contains no readable prompt,
  transcript, file content, command, or credential.
- **SC-010**: An agent that stops for input while the user is away is answered in minutes rather than
  discovered on return: the median time from request to answer, away from the Mac, is under 5 minutes.
- **SC-011**: Reaching any agent from the remote takes at most two selections, the project then the
  agent, as on the Mac.
- **SC-012**: Every action the remote offers has the same outcome as the Mac's equivalent, verified
  action by action.

## Assumptions

Decisions taken where the description did not say. Each is a candidate for `/speckit-clarify`.

- **The Mac is the only place work happens.** The remote is a view and a controller, never a second
  brain. No agent runs on the phone, nothing is stored on the phone to work from offline, and the
  daemon stays the only writer, as it is today.
- **A rendezvous in the middle is acceptable; a reader in the middle is not.** Reaching the Mac from
  a train needs something both ends can find each other through. That is allowed, on the condition in
  FR-003: it carries bytes it cannot read.
- **Two links, one remote.** The user never chooses a link and never configures one. They are told
  which they are on (FR-004b) and nothing else about it. The same pairing, the same keys and the
  same sealing serve both, which is what makes switching between them a routing decision rather than
  a second security model to get right twice.
- **Notifications go through the platform's push service**, because a phone cannot be woken any other
  way. Their content is not readable by that service, which means the notification carries enough to
  identify the agent and the rest is fetched by the device.
- **The Mac must be awake and on a network to be reached.** Waking a sleeping Mac is out of scope for
  this feature; the remote says the Mac is unreachable and when it last was. This is the one thing the
  user may have to arrange themselves, and the remote says so rather than failing mysteriously.
- **One person's devices, not a team.** Pairing is a user adding their own device. Sharing a project
  with somebody else, roles and permissions are out of scope.
- **New projects are made at the Mac.** A remote starts agents in projects that already exist, because
  making a project means choosing a folder, and browsing the Mac's file system from a phone is a
  feature of its own. Adding a project from the remote is out of scope.
- **Archiving a project is done at the Mac**, for the same reason: it is tidying, and tidying is a
  desk activity. Archiving an agent is on the remote, because it is part of finishing a piece of work.
- **The remote is the same app, not a different one.** Same projects, same groups, same transcript,
  same vocabulary, laid out for the screen. Anything feature 004 decided about the Mac's layout holds
  on the remote unless the screen makes it impossible.
- **The right-hand inspector from feature 002 is out of scope on the phone** and shown on a wide iPad
  only. A phone has room for one thing at a time.
- **Serving the agent stays on the Mac.** File reads and writes and command runs the app does on an
  agent's behalf happen on the Mac against the Mac's folders. The phone answers the questions about
  them; it never becomes a second file system.
- **Nothing new is asked of the user's Mac setup**: no login item, no installer, no port, no account,
  matching what the app does today.
