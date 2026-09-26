# Feature Specification: A Control Plane, and the Mac Window as One More Remote

**Feature Branch**: `agents/control-plane`

**Created**: 2026-09-26

**Status**: Draft

**Input**: User description: "Control plane, and the Mac app as one more remote." Decided with
Alex in conversation before this spec: a hub across machines; self-run on a machine he owns (Mac
or Linux), with no service we operate; it routes every call; each paired client gets a grant,
`operator` or `device`; the Mac app is purely a client and no longer starts a daemon of its own.

## Why this feature exists

Today the Mac window is special. It starts the daemon on this Mac, it is the only thing allowed
to do everything, and it reaches each Linux server itself, over ssh. The iPhone and iPad come in
through the phone bridge, can do only what a phone may do, and see only the Mac's projects:
a project on a server is invisible to them.

So what a person can reach depends on which screen they are holding. A server added on the Mac
exists only for the Mac window. Pairing, permissions and routing live in three places (the
window, the bridge and each server connection), each with its own rules. And the machine the
work runs on is tied to the machine the window runs on.

This feature puts one program, the **control plane**, in the middle. It runs on a machine the
person owns. Every machine that runs agents (this Mac, another Mac, a Linux server) is a
**host** that connects to it. Every screen (the Mac window, the iPhone, the iPad) is a
**client** that connects to it, with a grant that says what it may do. A client keeps one
connection and sees every host.

This reverses a decision 037 made (R7: many daemons joined in the window, not federated). That
decision was right for one window; it is wrong once every screen should see every host. The
reasons are recorded in [research.md](research.md) R1.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - The Mac window works through the control plane (Priority: P1)

The person runs a control plane and a host on their Mac, and pairs the Mac window with the
control plane as an operator. Everything they do in the window today (start an agent, read
it, answer it, open its terminal and files, stop it, change settings) works as before, but
goes through the control plane to the host.

**Why this priority**: This is the shape change. Until the window is a client like the others,
nothing else in this feature holds together.

**Independent Test**: On a scratch root, start a control plane and a host on this Mac, pair a
scratch copy of the window as an operator, start a real Claude turn, and watch it arrive,
answer a question it asks, and stop it.

**Acceptance Scenarios**:

1. **Given** a control plane and a host running on this Mac and a window paired as operator,
   **When** the person starts an agent in a project on this Mac, **Then** it runs on the host
   and its conversation appears in the window as it does today.
2. **Given** the same, **When** the window is quit and opened again, **Then** the agent is still
   working, and the window picks up where it was, without starting anything itself.
3. **Given** the window is open and the control plane stops, **When** the control plane comes
   back, **Then** the window reconnects by itself and shows what happened while it was gone.
4. **Given** the host stops while the control plane stays up, **Then** the window shows that
   host as offline, as it shows an offline server today, and the host's projects stay listed.
5. **Given** an agent asks for a credential the host does not hold (a server login, a key the
   window lends), **Then** the window that is being used is asked, as it is today, and the
   answer reaches only the host that asked.

---

### User Story 2 - First run: connect to one, or run one here (Priority: P1)

A person opening the Mac app with no control plane set up is asked how they want to work:
**Connect to a control plane** they already run elsewhere, or **Run one on this Mac**. Running
one here sets up the control plane and a host on this Mac, both kept running by macOS, and
pairs the window as an operator, with nothing else to download.

**Why this priority**: Without it the window, which no longer starts a daemon, would open to
nothing.

**Independent Test**: With a scratch root that has no control plane, open the scratch window,
choose **Run one on this Mac**, and within a minute see an empty project list with this Mac
listed as a host; restart the scratch window and find it connects straight away.

**Acceptance Scenarios**:

1. **Given** no control plane configured, **When** the window opens, **Then** it shows the two
   choices and nothing else.
2. **Given** the person chooses **Run one on this Mac**, **When** set-up finishes, **Then** a
   control plane and a host are running on this Mac, survive a logout and login, and the window
   is paired as operator.
3. **Given** the person chooses **Connect to a control plane**, **When** they scan or type the
   pairing code shown by that control plane, **Then** the window is paired, and is an operator
   only if the code was issued as one.
4. **Given** a control plane is already running on this Mac (from an earlier set-up), **When**
   **Run one on this Mac** is chosen again, **Then** nothing is installed twice and the window
   is simply paired.

---

### User Story 3 - A server joins by connecting out (Priority: P2)

The person adds a Linux server. The control plane installs the host on it over the person's own
ssh, the host connects out to the control plane with a key of its own, and from then on every
paired client (the Mac window, the iPhone, the iPad) sees the server's projects. No client
talks to the server directly.

**Why this priority**: This is what the hub is for: add a machine once and every screen has it.

**Independent Test**: Add the Linux devbox from the scratch window; start a turn in a project on
it; then list projects from a second client paired to the same control plane and see the
devbox's project there too.

**Acceptance Scenarios**:

1. **Given** a server reachable over the person's ssh, **When** they add it, **Then** the host
   is installed there, connects to the control plane, and appears under Hosts as online.
2. **Given** a host that has joined, **When** its network drops and returns, **Then** it
   reconnects by itself, and its agents kept working the whole time.
3. **Given** a host is removed in Settings, **Then** its key stops working at once, it
   disappears from every client, and its agents on the server are left as they are.
4. **Given** a server that cannot reach the control plane (no route out), **When** it is added,
   **Then** the control plane reaches it over ssh instead, and it behaves as any other host,
   marked as reached over ssh.

---

### User Story 4 - The iPhone and iPad see every host (Priority: P2)

A paired iPhone or iPad sees the projects on every host, not only on this Mac, and can do there
what its grant allows.

**Why this priority**: This is the phone limit 037 and 043 wrote down, and the reason the phone
path exists at all.

**Independent Test**: With the devbox enrolled, open the Remote (built for the generic
simulator; the phone look is Alex's) or a fake device client over the socket, and list
projects: the devbox's project is there, and starting an agent in it works.

**Acceptance Scenarios**:

1. **Given** a device-grant client, **When** it lists projects, **Then** it sees every host's
   projects, grouped by host as in the Mac window.
2. **Given** a device-grant client, **When** it tries something only an operator may do (sign a
   runtime in, lend a credential, add a host, change a grant), **Then** it is refused, by the
   control plane and again by the host.
3. **Given** the device is away from home, **When** it uses the iCloud relay, **Then** it reaches
   every host through the control plane, with the same away limits as today.

---

### User Story 5 - The person decides what each client may do (Priority: P2)

Settings ▸ Control plane lists every client with its grant, `operator` or `device`, and every
host with its state. The person can change a client's grant, forget a client, and remove a host.

**Why this priority**: Once the window is reachable from the network, what each client may do
must be visible and changeable in one place.

**Independent Test**: Pair a fake client as device, change it to operator in Settings, and see
an operator-only call succeed; forget it and see its connection cut and its next connection
refused.

**Acceptance Scenarios**:

1. **Given** a client paired as device, **When** the person changes it to operator, **Then** its
   next call is judged by the new grant, without re-pairing.
2. **Given** a client is forgotten, **Then** its connection closes at once, at home and through
   the relay, and it can come back only by pairing again.
3. **Given** the only operator is the window being used, **When** the person tries to demote or
   forget it, **Then** the app says this would leave no operator and does not do it.

---

### User Story 6 - Moving an existing set-up across, once (Priority: P2)

A person with today's app (a daemon on this Mac, paired devices, servers added in the window)
moves to the control plane once, deliberately. Their agents, conversations and projects on this
Mac become this Mac's host. Their paired iPhone and iPad keep working without pairing again, as
device clients. Their servers are enrolled as hosts.

**Why this priority**: Alex's live set-up is exactly this. The move is hard to undo, so it must
be one clear step, not something that happens on launch.

**Independent Test**: On a scratch root seeded with agents, a paired fake device and the devbox
added as a server the old way, run the move; afterwards every agent is listed with its history,
the fake device still connects with its old key, and the devbox is a host.

**Acceptance Scenarios**:

1. **Given** today's set-up, **When** the new app first opens, **Then** it keeps working the old
   way and offers the move; nothing changes until the person chooses it.
2. **Given** the person chooses the move, **When** it finishes, **Then** every agent,
   conversation and project on this Mac is present, and none has lost history.
3. **Given** a device paired before the move, **Then** it connects afterwards without pairing
   again, with a device grant.
4. **Given** servers added before the move, **Then** each is a host afterwards, or is listed as
   needing a hand (with the reason) if it could not be enrolled.
5. **Given** the move fails part-way, **Then** the old set-up still works, and the move can be
   tried again.

---

### User Story 7 - Another Mac as a host (Priority: P3)

The person runs a host on a second Mac, and its projects appear alongside everything else.

**Why this priority**: Falls out of the design, but is not today's need.

**Independent Test**: Enrol a second host process on this Mac under another scratch root, as
if it were another Mac, and see its projects listed separately.

**Acceptance Scenarios**:

1. **Given** a second Mac with the app installed, **When** the person chooses to run only a host
   there and enters a host pairing code, **Then** it joins the control plane as a host.

---

### Edge Cases

- **The control plane is down.** No client can reach any host. Hosts keep running their agents;
  a question waits on its host until someone can answer. Clients say **Can't reach the control
  plane** with where it was expected, not an empty list.
- **The machine running the control plane sleeps.** The same as down, for the whole time. The
  person is told this when choosing where to run it.
- **The control plane restarts while a turn is streaming.** Clients and hosts reconnect; the
  client re-reads what it missed, as it does after a daemon reconnect today.
- **A call for a host that is offline.** Refused at once with "that host is offline", not left
  to time out.
- **Two clients answer the same question.** The first answer wins, as today; the other sees it
  answered.
- **A credential is asked for and the asking client disconnects.** The host is told nobody can
  lend it, as when the window closes today.
- **A host with the same name joins twice** (a reinstall). It is the same host if it holds the
  same key; otherwise it is a new host and the old one shows as offline until removed.
- **A host's version is older than the control plane's.** It is shown as needing an update and
  calls it doesn't know are refused with that reason.
- **The terminal through a router.** Every keystroke crosses an extra hop. If that is noticeably
  slower (see SC-004), the terminal needs a lane of its own, which is out of scope here.
- **Local agent calls.** An agent's own tools talk to its host on that machine, not through the
  control plane, and keep working when the control plane is down.

## Requirements *(mandatory)*

### Functional Requirements

**The control plane**

- **FR-001**: The control plane MUST be a program the person runs on a machine they own, macOS
  or Linux. Nothing MUST pass through a service run by us.
- **FR-002**: Every client and every host MUST connect to the control plane, which MUST route
  each call to the host it concerns and answer calls that concern no host itself.
- **FR-003**: The control plane MUST pass every update from every host to each connected client
  whose grant hears updates, marked with the host it came from.
- **FR-004**: A request from a host to a client (a credential it wants, a question) MUST reach
  only the client connection it belongs to, or, if none, be answered as "nobody can".
- **FR-005**: The control plane MUST keep the paired clients, their grants and the enrolled
  hosts across restarts.

**Clients and grants**

- **FR-006**: Every client MUST pair with a code, as devices do today, and MUST be given one
  grant: `operator` (everything the Mac window may do today) or `device` (what a paired phone
  may do today).
- **FR-007**: The control plane MUST refuse any call a client's grant does not allow, before it
  reaches a host, and each host MUST refuse it again on the grant the control plane passes on.
- **FR-008**: The person MUST be able to see every client, change its grant, and forget it, from
  an operator client. Forgetting MUST cut the client off at once, including through the relay.
- **FR-009**: The app MUST NOT let the last operator be demoted or forgotten.

**Hosts**

- **FR-010**: A host MUST join by connecting out to the control plane with a key issued when it
  was enrolled. The control plane MUST NOT need to reach a host, except as FR-012 says.
- **FR-011**: A host MUST reconnect by itself after the connection drops, and MUST keep its
  agents working while disconnected.
- **FR-012**: Where a host cannot connect out, the control plane MUST be able to reach it over
  the person's ssh and treat it as a host like any other.
- **FR-013**: Adding a server MUST install the host on it over ssh from the control plane's
  machine, and enroll it, in one step started from any operator client.
- **FR-014**: Removing a host MUST revoke its key at once and MUST NOT stop or delete its agents.
- **FR-015**: An agent's own tools MUST keep talking to the host on their machine directly, and
  MUST keep working while the control plane is unreachable.

**The Mac app**

- **FR-016**: The Mac app MUST NOT start a daemon itself. It MUST connect only to a control plane.
- **FR-017**: With no control plane set up, the Mac app MUST offer **Connect to a control plane**
  and **Run one on this Mac**, and nothing else.
- **FR-018**: **Run one on this Mac** MUST set up a control plane and a host on this Mac that
  macOS keeps running across logouts and restarts, from the app itself, with nothing to download,
  and MUST pair the window as operator.
- **FR-019**: Everything the window shows about a project (its files, its terminals, its diffs)
  MUST come through the control plane, for this Mac's host as for any other. Actions that only
  make sense on this Mac (Reveal in Finder, Open in another app) MUST be offered only for
  projects on this Mac's host.
- **FR-020**: Credentials the window lends today (server logins, sign-in relays) MUST be lent the
  same way through the control plane, and only by an operator client.

**Phone and iPad**

- **FR-021**: A device-grant client MUST see projects and agents on every host, and do there what
  a paired device may do today.
- **FR-022**: Away from home, a device MUST reach every host through the relay to the control
  plane, with today's away limits.

**The move**

- **FR-023**: The move from today's set-up MUST happen only when the person chooses it, and MUST
  keep every agent, conversation, project and paired device.
- **FR-024**: A device paired before the move MUST keep working without pairing again, as a
  device client.
- **FR-025**: If the move fails part-way, today's set-up MUST still work.

### Key Entities

- **Control plane**: the one program every client and host connects to. Holds the clients, their
  grants, the hosts and their keys. Has an address clients and hosts are given when they pair.
- **Host**: a machine that runs agents. Has a name, a key, a platform, a version, a state
  (online, offline, needs an update, reached over ssh) and the projects on it.
- **Client**: a paired screen (a Mac window, an iPhone, an iPad). Has a name, a key, a grant,
  and when it was last seen.
- **Grant**: what a client may do: `operator` or `device`.
- **Pairing code**: shown by the control plane, works once, for a few minutes; says whether it
  pairs a client (and with which grant) or enrols a host.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Everything that works in the Mac window today works through the control plane: the
  full test suite passes, and a scratch walk of a real turn (start, question, answer, stop,
  files, terminal) finds no difference a person would notice.
- **SC-002**: A server added once appears on every paired client within 5 seconds of joining,
  with no step on any client.
- **SC-003**: From a fresh install, **Run one on this Mac** leaves the person looking at a
  working, empty window in under one minute.
- **SC-004**: At home, a keystroke in a terminal echoes no more than 10 ms later (median) than it
  does today, and a question reaches the window no more than 50 ms later.
- **SC-005**: Every operator-only call is refused for a device client, at the control plane and
  at the host: tested for each one.
- **SC-006**: After the move, 100% of agents and conversations are present with full history,
  and no paired device needs pairing again.
- **SC-007**: With the control plane stopped for 10 minutes, every agent that was working on any
  host carries on, and every client catches up within 5 seconds of it returning.

## Docs *(mandatory)*

- `docs/explanation/control-plane.md` — add: what the control plane, hosts and clients are, where
  to run it, what happens when it is down, and why it was built this way.
- `docs/explanation/window-and-daemon.md` — change: the window no longer starts the daemon; the
  host is kept running by macOS; what "the window owns nothing" now means.
- `docs/explanation/phone-and-ipad.md` — change: devices see every host; "The connection today"
  (the bridge is no longer started by hand; grants); forgetting a device.
- `docs/explanation/projects-hosts-worktrees.md` — change: "A project lives on one host", hosts
  that connect out, hosts reached over ssh.
- `docs/how-to/` — add: run a control plane on this Mac; connect to one elsewhere; add a server;
  move an existing set-up across.
- `README.md` — change: set-up.

## Assumptions

- The person owns and runs the machine the control plane is on. Running it on a Mac that sleeps
  is allowed, with the cost made plain (see Edge Cases).
- Pairing, keys and encryption reuse what devices already use (TLS with a pre-shared key at home,
  sealed messages through the person's own iCloud away). No new kind of cryptography.
- The iCloud relay stays Apple-only: a control plane on Linux serves clients at home, or through
  a Mac that relays for it; relaying from Linux is out of scope.
- Browsing a host's folders, adding and renaming projects stay operator-only, as today.
- A direct terminal lane that skips the control plane is out of scope unless SC-004 fails.
- Cross-host daily spending caps stay per host (037's known gap); a control plane that could
  enforce them is a later feature.
- One control plane per person. Joining two control planes is out of scope.
