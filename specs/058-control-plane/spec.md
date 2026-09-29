# Feature Specification: A Control Plane, and Apps That Are Only Clients

**Feature Branch**: `agents/control-plane`

**Created**: 2026-09-26. **Re-specified**: 2026-09-28.

**Status**: Draft (re-spec)

**Input**: The first spec, "Control plane, and the Mac app as one more remote", was decided with
Alex on 2026-09-26. It covered:
- a hub across machines, self-run on a machine he owns (Mac or Linux), with no service we operate;
- the hub routes every call;
- each paired client gets a grant, `operator` or `device`;
- the Mac app is purely a client and no longer starts a daemon of its own.

On 2026-09-28 Alex set two goals on top:

1. **The Mac, iPhone and iPad apps can be published in the App Store.** Everything they cannot do
   there moves out of them, into the control plane and the host.
2. **The control plane scales out.** It is a web service that runs as several copies behind a
   load balancer, keeping what it must remember on disk or in an S3-compatible bucket.

His answers to the questions that followed:
- **Hosting.** Self-hosted only: still no service we operate.
- **Mac hosts.** A Mac becomes a host through a separate download, outside the App Store.
- **The wire.** Clients and hosts speak HTTPS and WebSockets, proving their keys by signing
  instead of with pre-shared-key TLS.
- **Who it serves.** One person now; a team later, so nothing stored may assume one person
  forever.
- **Away from home.** The iCloud relay stays.
- **Phone notifications.** They stay in the person's own iCloud mailbox.
- **This spec.** It is re-specified before anything more is built.

What was built and walked under the first spec is kept where it still fits:
- the router, channels per client and host, host uplinks;
- grants, pairing by code, Settings ▸ Control plane;
- `ThisMacHost`, the `files/*` path;
- host headings on the phone;
- the move across.

The rest of this document supersedes the first spec.

## Why this feature exists

Today the Mac window is special. It starts the daemon on this Mac, and it is the only thing
allowed to do everything. It reaches each Linux server itself, over ssh. The iPhone and iPad come
in through the phone bridge, can do only what a phone may do, and see only the Mac's projects.

That shape has two costs.

**What a person can reach depends on the screen they hold.** A server added on the Mac exists
only for the Mac window. Pairing, permissions and routing live in three places.

**None of the apps can be sold in the App Store.** An App Store app runs in a sandbox. It may not:
- start helpers of its own that run outside it;
- register background jobs that run outside it;
- run ssh, git, `security` or a vendor's install script;
- read folders the person did not hand it.

The Mac window does all of these. The iPhone and iPad apps are close already, because they have
always been clients.

This feature puts one service, the **control plane**, in the middle, and leaves the apps with
nothing but a screen:
- **Hosts.** Every machine that runs agents (a Mac, a Linux server) is a host. It connects out
  to the control plane.
- **Clients.** Every screen (the Mac window, the iPhone, the iPad) is a client. It connects to
  the control plane with a grant that says what it may do.
- **Where the work goes.** What needs a real machine happens on a host, and the client asks for
  it. That covers agents, terminals, files, git, sign-ins and installs.
- **Where the control plane runs.** The person runs it themselves: on their Mac for one person
  at home, or as several copies on hosting they rent, sharing a disk or a bucket.

This reverses 037's R7 (many daemons joined in the window). It also reverses the first spec's
choices of a pre-shared-key wire and of a control plane that lives inside the phone bridge on a
Mac. The reasons are in [research.md](research.md).

## User Scenarios & Testing *(mandatory)*

### User Story 1 - The Mac window works through the control plane, sandboxed (Priority: P1)

The person pairs the Mac window with their control plane as an operator. Everything they do in
the window today works as before, through the control plane, for a project on this Mac as for
one on a server. That means starting an agent, reading it and answering it, its terminal, files
and diffs, stopping it, settings, and the shared skills and instructions pages. The window runs
in the App Store sandbox and starts nothing.

**Why this priority**: This is the shape change and the App Store goal in one. Until the window
is a sandboxed client, nothing else holds together.

**Independent Test**: Build the window with the sandbox on. On a scratch root, pair it with a
control plane and a host on this Mac. Start a real Claude turn, answer a question it asks, open
its terminal and a file, and stop it. The window must spawn no process and read no file outside
its container.

**Acceptance Scenarios**:

1. **Given** a sandboxed window paired as operator, **When** the person starts an agent in a
   project on this Mac, **Then** it runs on this Mac's host and its conversation appears as today.
2. **Given** the same, **When** the person opens a file, a diff, a picture or the terminal,
   **Then** it comes from the host, as it does for a server today.
3. **Given** a project on this Mac's host, **When** the person chooses Reveal in Finder or Open
   in another app, **Then** it works, and those actions are offered for no other host.
4. **Given** the window is quit and opened again, **Then** every agent is still working, and the
   window picks up where it was without starting anything.
5. **Given** an agent needs a credential its host does not hold, **Then** the window in use is
   asked, as today, and the answer reaches only that host.

---

### User Story 2 - First run: connect to one, or set one up here (Priority: P1)

A person opening the Mac app with no control plane is asked how they want to work:
- **Connect to a control plane** they already run;
- **Set one up on this Mac**, which points them to the host download.

The host download is signed by us and installed outside the App Store. It runs a host and a
single-copy control plane on this Mac, kept running by macOS. It shows a code, and the window
pairs with it as operator.

**Why this priority**: The window no longer starts anything, so without this it opens to nothing.

**Independent Test**: On a scratch root with no control plane, install the host download's
scratch build and open the scratch window. Choose **Set one up on this Mac** and follow it to
the end. Within a minute of the install finishing, an empty window lists this Mac as a host.

**Acceptance Scenarios**:

1. **Given** no control plane configured, **When** the window opens, **Then** it shows the two
   choices and nothing else.
2. **Given** the host download is installed on this Mac, **When** the window opens, **Then** it
   finds that control plane by itself and asks only to confirm the pairing.
3. **Given** the person connects to a control plane elsewhere, **When** they scan or type its
   code, **Then** the window is paired, as operator only if the code was issued as one.
4. **Given** the host download is installed twice, **Then** nothing runs twice and nothing
   already paired is lost.

---

### User Story 3 - The control plane keeps going when one copy stops (Priority: P1)

The person runs the control plane as two or more copies behind a load balancer, sharing one
bucket or disk. Any copy can answer any client and any host. When one copy stops, the clients
and hosts that were on it reconnect to another, and no agent loses work.

**Why this priority**: This is the scaling goal. It must be designed in from the start, because
the first design keeps a client and the host it talks to in one process.

**Independent Test**: Run three copies on this Mac behind a local load balancer, sharing a
scratch bucket (a local S3-compatible server) or a shared folder. Enrol the devbox and a local
host, and pair a window and a fake device. Start turns on both hosts, then kill the copy each
connection is on. Everything must reconnect and carry on. Pair a new client using a code shown
by one copy while connected to another.

**Acceptance Scenarios**:

1. **Given** several copies sharing a store, **When** a client connects to any copy, **Then**
   it sees every host, wherever that host's connection is held.
2. **Given** a copy stops, **Then** its clients and hosts reconnect to others within 10
   seconds. A call made in that time is answered afterwards or refused with a reason, never
   lost silently.
3. **Given** a code shown by one copy, **When** it is used at another, **Then** it works, once.
4. **Given** a client is forgotten, or a host removed, on one copy, **Then** it is cut off at
   once on every copy.
5. **Given** a single copy on this Mac with a plain folder for its store (the host download's
   set-up), **Then** it behaves exactly as several copies do, minus the failover.

---

### User Story 4 - A server joins by connecting out (Priority: P2)

The person adds a Linux server. An operator client shows a host code and one command to run on
the server. The command installs the host, which enrols with the code and connects out to the
control plane over HTTPS. From then on every paired client sees the server's projects.

**Why this priority**: This is what the hub is for: add a machine once and every screen has it.

**Independent Test**: From the scratch window, add the devbox by running the shown command
there. Start a turn in a project on it, and list projects from a second client and see it.

**Acceptance Scenarios**:

1. **Given** a server that can reach the control plane's address, **When** the shown command is
   run on it, **Then** the host is installed, enrolled and listed as online.
2. **Given** a host that has joined, **When** its network drops and returns, **Then** it
   reconnects by itself, and its agents kept working the whole time.
3. **Given** a host is removed, **Then** its key stops working at once, it disappears from every
   client, and its agents are left as they are.
4. **Given** an operator gives an ssh destination instead, **When** the control plane has
   installed the host there, **Then** the host enrols and connects out, and the control plane
   holds no ssh session or key for it.
5. **Given** a host older than the control plane, **Then** it is shown as needing an update,
   and calls it does not know are refused with that reason.

---

### User Story 5 - The iPhone and iPad see every host, at home and away (Priority: P2)

A paired iPhone or iPad sees the projects on every host, and can do there what its grant
allows. Away from home it reaches the control plane directly if it can, and through the iCloud
relay otherwise. When an agent needs the person, the phone is told through the person's own
iCloud mailbox.

**Why this priority**: This removes the phone limit 037 and 043 wrote down.

**Independent Test**: With the devbox enrolled, a fake device client lists projects, sees the
devbox's project, and starts an agent there. It does this once at the control plane's address
and once through the relay. The Remote is built for the generic simulator; the phone look is
Alex's.

**Acceptance Scenarios**:

1. **Given** a device-grant client, **When** it lists projects, **Then** it sees every host's
   projects, grouped by host.
2. **Given** a device-grant client, **When** it tries something only an operator may do, **Then**
   it is refused, by the control plane and again by the host.
3. **Given** the device is away and the control plane's address is not reachable, **When** it
   uses the iCloud relay, **Then** it reaches every host, with today's away limits.
4. **Given** an agent on any host needs an answer, **Then** the person's phone gets a
   notification sealed so only their devices can read it.

---

### User Story 6 - The person decides what each client may do (Priority: P2)

Settings ▸ Control plane lists every client with its grant, `operator` or `device`, and every
host with its state. The person can change a grant, forget a client and remove a host. This is
unchanged from the first spec, and it now holds across every copy.

**Why this priority**: Once screens reach the control plane over the network, what each may do
must be visible and changeable in one place.

**Independent Test**: Pair a fake client as device and change it to operator. An operator-only
call now succeeds, at whichever copy it lands. Forget the client, and its connection is cut
and its next one refused.

**Acceptance Scenarios**:

1. **Given** a client paired as device, **When** it is changed to operator, **Then** its next
   call is judged by the new grant, without pairing again.
2. **Given** a client is forgotten, **Then** its connection closes at once, directly and through
   the relay, and it can come back only by pairing again.
3. **Given** the only operator is the window in use, **When** the person tries to demote or
   forget it, **Then** the app refuses and says why.

---

### User Story 7 - Moving an existing set-up across, once (Priority: P2)

A person with today's app has a daemon on this Mac, paired devices, and servers added in the
window. They install the host download and move across once, deliberately. Their agents,
conversations and projects on this Mac become this Mac's host, and their paired iPhone and iPad
keep working without pairing again. Their servers are enrolled as hosts, or listed as needing
the shown command run on them.

**Why this priority**: Alex's live set-up is exactly this. The move is hard to undo, so it is
one clear step.

**Independent Test**: Seed a scratch root the old way, with agents, a paired fake device and
the devbox as a server. Install the host download's scratch build over it and run the move.
Every agent must be listed with its history, the fake device must still connect with its old
key, and the devbox must be a host or be listed with its command.

**Acceptance Scenarios**:

1. **Given** today's set-up, **When** the host download is installed, **Then** it takes over the
   existing agents and history in place, copying nothing.
2. **Given** the move finishes, **Then** every agent, conversation and project is present, with
   none missing history.
3. **Given** a device paired before the move, **Then** it connects afterwards without pairing
   again, with a device grant.
4. **Given** the move fails part-way, **Then** the old set-up still works and the move can be
   tried again.

---

### User Story 8 - The apps pass App Store review (Priority: P2)

The Mac, iPhone and iPad apps are built as App Store apps and pass Apple's automated
validation. A reviewer can try them against a demo control plane.

**Why this priority**: This is the first goal's finish line. Every other story makes it
possible; this one proves it.

**Independent Test**: Archive each app with App Store signing and run App Store Connect's
validation. Check that the Mac app has the sandbox on and carries no helper programs, no Linux
programs and no install scripts.

**Acceptance Scenarios**:

1. **Given** the Mac app archive, **Then** validation passes. It is sandboxed, contains no
   other executables, and asks only for network access, the microphone for dictation, and
   files the person picks.
2. **Given** the iPhone and iPad archive, **Then** validation passes with production push
   settings.
3. **Given** a reviewer with no control plane, **When** they follow the review notes, **Then**
   they reach a demo control plane with a demo host and can start an agent.

---

### User Story 9 - Another Mac as a host (Priority: P3)

The person installs the host download on a second Mac, gives it a host code, and its projects
appear alongside everything else.

**Why this priority**: It falls out of US2 and US4, but it is not today's need.

**Independent Test**: Enrol a second host under another scratch root, as if it were another
Mac, and see its projects under their own heading.

**Acceptance Scenarios**:

1. **Given** a second Mac with the host download, **When** it is given a host code, **Then** it
   joins as a host and runs no control plane of its own.

---

### Edge Cases

- **The control plane is down** (every copy). No client reaches any host. Hosts keep their
  agents working, and a question waits on its host. Clients say **Can't reach the control
  plane** and give the expected address, rather than showing an empty list.
- **The store is unreachable while copies are up.** Live connections keep working. Anything
  that must be remembered (pairing, a grant change, enrolling, removing) is refused with that
  reason, and none of it is half-done.
- **Two copies change the same record at once.** Neither change is lost silently. Examples:
  two operators change one grant, or a host is removed while it is enrolling. One wins, and the
  other is told to try again.
- **The copy holding a host's connection stops mid-turn.** The host reconnects to another copy.
  Clients see it offline for no more than the reconnect, and re-read what they missed.
- **A single copy on a Mac that sleeps.** The same as down, for the whole time. The person is
  told this when they choose it.
- **A call for a host that is offline.** It is refused at once with "that host is offline",
  not left to time out.
- **Two clients answer the same question.** The first answer wins; the other sees it answered.
- **The client that was asked for a credential disconnects.** The host is told nobody can lend
  it.
- **A host reinstalled with the same name.** It is the same host if it holds the same key.
  Otherwise it is a new host, and the old one shows offline until removed.
- **A sandboxed window is handed a folder.** A folder picked or dropped for a project on this
  Mac is passed to the host by path. The window never keeps access to it itself.
- **The terminal through a load balancer.** Every keystroke crosses more hops. If that is
  noticeably slower (SC-004), the terminal needs a lane of its own, which is out of scope.
- **An agent's own tools.** They talk to the host on their own machine, never through the
  control plane, and keep working while it is down.

## Requirements *(mandatory)*

### Functional Requirements

**The control plane**

- **FR-001**: The control plane MUST be a service the person runs themselves. It runs either on
  their Mac (as part of the host download) or on Linux (as a container). Nothing MUST pass
  through a service we run.
- **FR-002**: Every client and every host MUST connect to the control plane. It MUST route each
  call to the host it concerns, and answer calls that concern no host itself.
- **FR-003**: The control plane MUST pass every update from every host to each connected client
  whose grant hears updates, marked with the host it came from.
- **FR-004**: A request from a host to a client (a credential, a question) MUST reach only the
  client connection it belongs to. If there is none, it MUST be answered "nobody can".
- **FR-005**: The control plane MUST keep the paired clients, their grants, the enrolled hosts
  and the pairing codes it has issued across restarts.

**Scaling out**

- **FR-006**: The control plane MUST be able to run as any number of copies sharing one store.
  Any copy MUST accept any client or host, and MUST route to a host whose connection another
  copy holds.
- **FR-007**: The store MUST be either a folder on disk or an S3-compatible bucket. Nothing else
  (no database) is needed to run it.
- **FR-008**: Every change to a stored record MUST be safe against a concurrent change from
  another copy. It either applies to the version it read, or is refused.
- **FR-009**: Forgetting a client, changing a grant or removing a host MUST take effect on every
  copy within 2 seconds.
- **FR-010**: The control plane's private key MUST NOT be kept in the store in the clear. It is
  given to each copy as a secret by whatever runs the copies.
- **FR-011**: Clients and hosts MUST reach the control plane over standard HTTPS, so any
  ordinary load balancer or TLS terminator can sit in front of it. Each MUST prove it holds its
  key when it connects.
- **FR-012**: Every stored record of a client, host or grant MUST name the person it belongs to,
  so that more than one person can be added later without moving what is stored. Only one
  person is supported now.

**Clients and grants**

- **FR-013**: Every client MUST pair with a code and be given one grant: `operator` (everything
  the Mac window may do today) or `device` (what a paired phone may do today).
- **FR-014**: The control plane MUST refuse any call a client's grant does not allow before it
  reaches a host. Each host MUST refuse it again, on the grant the control plane passes on.
- **FR-015**: From an operator client, the person MUST be able to see every client, change its
  grant and forget it. Forgetting MUST cut the client off at once, including through the relay.
- **FR-016**: The app MUST NOT let the last operator be demoted or forgotten.

**Hosts**

- **FR-017**: A host MUST join by connecting out to the control plane with a key of its own,
  enrolled with a host code. The control plane MUST NOT need to reach a host.
- **FR-018**: Adding a server MUST mean running one command on it, shown with a host code by an
  operator client. The command installs the host and enrols it.
- **FR-018a**: An operator MAY instead have the control plane install the host over ssh. The
  person gives the destination, and a key the control plane may use for that install only. The
  control plane MUST keep neither the key nor the session afterwards. The host MUST then enrol
  and connect out like any other.
- **FR-019**: A host MUST reconnect by itself after the connection drops, to any copy, and MUST
  keep its agents working while disconnected.
- **FR-020**: Removing a host MUST revoke its key at once and MUST NOT stop or delete its agents.
- **FR-021**: An agent's own tools MUST keep talking to the host on their machine directly.
- **FR-022**: Whatever needs a real machine MUST happen on a host, asked for by a client. This
  covers:
  - agents and terminals;
  - reading, writing and browsing files;
  - git;
  - installing runtimes and toolsets;
  - signing runtimes in, including reading this Mac's own Claude sign-in;
  - the shared skills and instructions in the person's home folder.

**The host download**

- **FR-023**: A Mac MUST become a host by installing a download signed by us, outside the App
  Store. It MUST be kept running by macOS across logouts and restarts.
- **FR-024**: The host download MUST be able to run a single-copy control plane on the same Mac,
  with a folder for its store. It is offered as **Set one up on this Mac**.
- **FR-025**: On a Mac with today's set-up, the host download MUST take over the existing agents,
  history and projects in place.
- **FR-026**: A Mac host MUST be able to act as the iCloud relay and notification mailbox for the
  control plane, so devices can reach it away from home and be told when they are needed.

**The Mac app**

- **FR-027**: The Mac app MUST run in the App Store sandbox. It MUST NOT start any process,
  register any background job, or read any file outside its container except what the person
  picks.
- **FR-028**: The Mac app MUST connect only to a control plane.
- **FR-029**: With no control plane set up, the Mac app MUST offer **Connect to a control plane**
  and **Set one up on this Mac**, and nothing else.
- **FR-030**: Everything the window shows about a project MUST come through the control plane,
  for this Mac's host as for any other. Reveal in Finder and Open in another app MUST be offered
  only for projects on this Mac's host.
- **FR-031**: Credentials the window lends today MUST be lent through the control plane, by an
  operator client only.

**Phone and iPad**

- **FR-032**: A device-grant client MUST see projects and agents on every host, and do there what
  a paired device may do today.
- **FR-033**: Away from home, a device MUST reach the control plane at its address when it can,
  and through the iCloud relay otherwise, with today's away limits.
- **FR-034**: Notifications MUST reach the person's devices through their own iCloud mailbox,
  sealed so only their devices can read them.

**The App Store**

- **FR-035**: The Mac, iPhone and iPad apps MUST pass App Store Connect validation. They MUST
  contain no helper programs, no programs for other platforms and no install scripts.
- **FR-036**: A demo control plane with a demo host MUST be available to App Review, with notes
  on how to reach it.

**The move**

- **FR-037**: The move from today's set-up MUST happen only when the person chooses it, and MUST
  keep every agent, conversation, project and paired device.
- **FR-038**: A device paired before the move MUST keep working without pairing again.
- **FR-039**: If the move fails part-way, today's set-up MUST still work.

### Key Entities

- **Control plane**: the service every client and host connects to. It runs as one copy or
  many, with an address clients and hosts are given when they pair.
- **Copy**: one running instance of the control plane. It holds live connections and nothing
  that only it knows.
- **Store**: where the control plane remembers things: a folder, or an S3-compatible bucket. It
  holds clients, grants, hosts, codes and which copy holds which host's connection.
- **Person**: whom clients and hosts belong to. There is one per control plane for now.
- **Host**: a machine that runs agents. It has a name, a key, a platform, a version, a state
  (online, offline, needs an update) and the projects on it.
- **Client**: a paired screen. It has a name, a key, a grant, and when it was last seen.
- **Grant**: what a client may do: `operator` or `device`.
- **Code**: shown by the control plane. It works once, for a few minutes, at any copy. It says
  whether it pairs a client (and with which grant) or enrols a host.
- **Host download**: the signed Mac package that runs a host, and optionally a single-copy
  control plane, outside the App Store.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Everything that works in the Mac window today works in the sandboxed window
  through the control plane. The full test suite passes, and a scratch walk of a real turn
  finds no difference a person would notice. The walk covers start, question, answer, stop,
  files, terminal, and the shared skills page.
- **SC-002**: All three apps pass App Store Connect validation, and the Mac app starts no
  process in a whole walk.
- **SC-003**: With three copies running, stopping any one of them leaves every client and host
  connected again within 10 seconds. No agent on any host loses work.
- **SC-004**: At home, through a single copy, a keystroke in a terminal echoes no more than 10 ms
  later (median) than it does today, and a question reaches the window no more than 50 ms later.
- **SC-005**: A server added once appears on every paired client within 5 seconds of joining,
  with no step on any client.
- **SC-006**: Once the host download is installed, **Set one up on this Mac** leaves the person
  looking at a working window in under one minute.
- **SC-007**: Every operator-only call is refused for a device client, at the control plane and
  at the host. Each one is tested.
- **SC-008**: After the move, 100% of agents and conversations are present with full history,
  and no paired device needs pairing again.
- **SC-009**: With every copy stopped for 10 minutes, every agent that was working on any host
  carries on. Every client catches up within 5 seconds of a copy returning.

## Docs *(mandatory)*

- `docs/explanation/control-plane.md` — add:
  - what the control plane, copies, the store, hosts and clients are;
  - where to run it: on this Mac, or several copies with a bucket;
  - what happens when it or its store is down;
  - why it was built this way.
- `docs/explanation/window-and-daemon.md` — change:
  - the window is sandboxed and starts nothing;
  - the host download runs the host;
  - what "the window owns nothing" now means.
- `docs/explanation/phone-and-ipad.md` — change:
  - devices see every host;
  - they reach it directly or through the relay;
  - grants, and forgetting a device.
- `docs/explanation/projects-hosts-worktrees.md` — change:
  - a project lives on one host;
  - hosts join by connecting out.
- `docs/how-to/` — add:
  - set one up on this Mac;
  - run the control plane as several copies with a bucket;
  - connect a window or phone to it;
  - add a server;
  - move an existing set-up across.
- `README.md` — change:
  - set-up now means the App Store app plus the host download;
  - building from source.

## Assumptions

- **Running it.** The person runs the control plane and owns what it runs on. Running it on a
  Mac that sleeps is allowed, with the cost made plain.
- **Keys.** Clients and hosts keep the P-256 keys they have today. What changes is how they
  prove them: by signing when they connect, over ordinary HTTPS, not by pre-shared-key TLS.
  There is no new kind of cryptography.
- **Addresses.** The control plane has one stable address (a name, not a list of IP addresses).
  Codes, clients and hosts carry that address.
- **Servers over ssh.** ssh is used only to install a host (FR-018a), then let go. A server that
  cannot reach the control plane over HTTPS is out of scope: hosts reached over ssh were in the
  first spec and are dropped. A control plane running as several copies in rented hosting holds
  no live ssh sessions.
- **Relay and notifications.** These stay Apple-only (iCloud) and need a Mac host. A set-up with
  no Mac host has neither: its devices reach the control plane only at its address and get no
  pushes.
- **What devices may do.** Browsing a host's folders, and adding and renaming projects, stay
  operator-only.
- **Scale.** The target is one person: a handful of clients and up to about twenty hosts. Several
  copies are for staying up, not for load. Teams are a later feature, which FR-012 keeps open.
- **Spending caps.** Caps across hosts stay per host (037's known gap).
- **The terminal.** A direct terminal lane that skips the control plane is out of scope unless
  SC-004 fails.
- **The first build.** The first spec's pre-shared-key listener, its dialers, and the control
  plane inside the phone bridge are replaced. They stay in the code only until their
  replacements are walked.
