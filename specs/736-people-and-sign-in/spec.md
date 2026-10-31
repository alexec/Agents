# Feature Specification: Team tier: people, machines and sign-in

**Feature Branch**: `agents/work-github-issue-1117`

**Created**: 2026-10-11. **Re-specified**: 2026-10-20 (#1117).

**Status**: Draft, re-specified. Nothing here is built yet.

**Milestone**: 0.8 Team. Nothing for 0.8 merges to `main` before v0.7.0 ships.

**Input**: Issue #1117, the team tier re-spec, with every answer Alex gave on it (2026-10-15 to 2026-10-18) and on #995. It covers the four team steps of `specs/research/733-team-and-enterprise.md`:

- **T1** #994: people, roles and who owns a machine;
- **T2** #995: sign-in with Google, Apple, GitHub and the local owner;
- **T3** #996: who did what;
- **T4** #997: key lifetimes.

**What changed from the 2026-10-11 draft**:

- **One user per machine.** Machines are not shared. The draft's see and drive shares, and its "Shared by" group, are gone.
- **A host and a workspace are one thing, a machine.** The screen says "machine". The code and the wire keep `host`.
- **Settings have three scopes:** this device, you, and the control plane. Projects keep their own settings.
- **A user is a person or a bot.**
  - Bots are configured by admins.
  - A bot starts work only on events.
  - A bot never asks a question.
- **Every client and every machine belongs to a person.** A person comes from a provider: Google, Apple, GitHub or the built-in local owner. Codes are the local owner's sign-in. There is no code-only path with no person.
- **A machine joins by approval on a signed-in client.** A machine that a provider starts joins with a one-time token.
- **Groups come back, for providers and bot cost only.**
- **Team workflows run on a bot's machines,** chosen by `runs-on:` labels.
- **The control plane keeps each user's secrets.** It encrypts them with a key from a key service and sends them only to that user's machines.

## Why this feature exists

**Today a control plane belongs to one person.**

- Every paired client can do everything on every host (#111, `docs/explanation/control-plane.md`, "One grant for every client").
- That is correct for one person with a Mac, a phone and a browser.
- It is wrong when a second person joins: the second person's lost phone could drive the first person's Mac.

**An MCP secret acts as the person who set it.**

- A GitHub token or a Linear key is that person's own.
- On one Unix account, nothing keeps it from the other people who use that account.
- So the only true limit is the machine. One machine has one user, and that user's secrets are on it.

**A team still wants to share some things:**

- the control plane;
- the providers that start machines, and who pays for them;
- the bots that do team work, such as reviewing every pull request;
- the channels, such as the team's Slack.

**This feature makes the control plane hold people.**

- Each person signs in.
- Each client and each machine belongs to one user.
- A user sees only their own machines.
- Admins manage people, groups, providers, bots and channels. Being an admin does not let a person into another person's machine.

**One person's control plane works the same as it does today.** That person is the local owner, the admin and the owner of everything. Nothing asks them to sign in.

## Decisions

| Question | Answer | Who, when |
|---|---|---|
| Tenancy | One organisation per control plane, self-hosted first. One organisation = one store prefix. | Alex, 2026-10-11 |
| Who uses a machine | **One user per machine.** No sharing, also not at see. | Alex, 2026-10-15; decided on #1117 |
| Settings scopes | This device / you / control plane, in one Settings window with a rail grouped by scope. Projects keep their own. | Alex, 2026-10-15; decided on #1117 |
| Identity | One model. Every client and machine belongs to a person, from Google, Apple, GitHub or the local owner provider. | Alex, 2026-10-18 (#995) |
| Bots | Distinct users, configured by admins. Started only by events. No ask tools. Cost goes to a group. | Alex, 2026-10-15 and 2026-10-16 |
| Groups | For providers and bot cost only. A group is a set of users, one user, or everyone. Admins manage groups. | Alex, 2026-10-15 |
| Started machines | Belong to the user who started them. A removed person's started machines are stopped and deleted. | Alex, 2026-10-15 |
| User secrets | Kept by the control plane, encrypted with a key outside the store, in Google Cloud KMS. A control plane on a Mac uses a 0600 file. | Alex, 2026-10-15 and 2026-10-16 |
| Channels | Run on the control plane. Each channel identity is linked by approval. Email also needs DKIM. | Decided on #1117 |
| Workflows | Personal workflows run on each user's own machines, as today. A team workflow names its bot in `runs-on:`, and runs once per trigger among that bot's machines. | Alex and decided, 2026-10-16 |
| Admins reading transcripts | Not in this cut. | Alex, 2026-10-15 |
| Agent tools | List and reach only the caller's own user's sessions. Leases are per machine. | Alex, 2026-10-16 |
| Web page | On the control plane's own HTTPS domain. Pairs by a code from a signed-in client, until the operator registers an OIDC client of their own. | Alex, 2026-10-16 |
| GitHub sign-in replay | See Clarifications, 2026-10-20. | Decided, 2026-10-20 |
| Outside sign-in on a public control plane | Not mandatory. See Clarifications. | Decided, 2026-10-20 |

## Words

- **User**: someone a machine can belong to. A user is a person or a bot.
- **Person**: a human who signs in. A person has clients.
- **Bot**: a user with no clients and no sign-in. Admins configure it.
- **Machine**: what runs agents. It is a Mac with Agents Host, a Linux server, or a workspace that a provider starts. Today the screen says "host" for some of these and "workspace" for others. The code, the wire and the store keep `host`.
- **Client**: a screen, as today: the Mac window, an iPhone, an iPad or a browser. A client always belongs to one person.
- **Provider** has two meanings, and the screen always says which one:
  - a **sign-in provider** (Google, Apple, GitHub, local owner);
  - a **workspace provider** (#691), which starts machines.
- **Group**: a set of users that a workspace provider or a bot belongs to. It can be named users, one user, or everyone.
- **Scope**: where a setting lives:
  - this device;
  - you (the user);
  - the control plane;
  - the project.

## Clarifications

### Session 2026-10-15 to 2026-10-18 (Alex, on #1117 and #995)

All of the answers in the Decisions table above.

### Session 2026-10-20 (the 0.8 re-spec lane, decide and tell; Alex can overrule)

- Q: Does a GitHub sign-in pair a client with no code, as Google and Apple do?
  → A: **No.** A GitHub token cannot carry the control plane's nonce, so a control plane that gets one could replay it to another control plane.
  - A GitHub person joins only by an invite. The invite is a code made for this control plane.
  - Each later client of that person needs an approval on one of their signed-in clients.
  - The app is a GitHub App with user tokens that expire after 8 hours.
  - The token asks for no scope, or only `read:org` when an admin allows an organisation.
  - The control plane forgets the token after one call to `GET /user`.
  - Google and Apple keep the nonce-bound sign-in with no approval.
- Q: Does a control plane reachable from the internet need an outside sign-in provider?
  → A: **No.** It is the admin's choice. Codes are bound to the control plane's key, and Alex's rule is that nobody is ever forced to have a cloud login.
- Q: When an admin turns on Google, does the local owner become a second person?
  → A: **No.** The local owner is a person. The local owner adds a Google, Apple or GitHub sign-in to themselves, and stays one person.
  - The local owner sign-in itself stays, held by whoever holds the control plane's key.
  - It is the way to recover the last admin.
- Q: Do runtime sign-ins (for example a Claude subscription) move to the user scope?
  → A: **No.** They stay on each machine, in the runtime's own files. "Use the sign-in from" (`signInFrom`) may name only machines of the same user.
- Q: Do groups have admins of their own?
  → A: **No, not in this cut.** Control-plane admins manage every group, and get the notices for bots at their caps.
- Q: Do a removed person's registered machines (not started by a provider) get deleted?
  → A: **No.** They leave the control plane, as **Remove Host** does today. Their agents keep running on that machine. Only started machines are stopped and deleted.
- Q: One spec for T1 to T4, or four specs?
  → A: **One spec**, in this folder. T1 and T2 cannot be built apart, and T3 and T4 are small and change the same records.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - One person sees no change (Priority: P1)

Alex runs a control plane alone. Agents is updated to this version. Alex is the local owner and the admin. Alex owns every client and every machine, and sees exactly what Alex saw before. Nothing asks Alex to sign in. The Settings rail is grouped by scope.

**Why this priority**: most people who use Agents use it alone. If they see a change that they must act on, the update has failed them.

**Independent Test**: update a scratch control plane that has two clients and two machines. The same lists show, every call that worked before still works, and no sheet asks for a sign-in.

**Acceptance Scenarios**:

1. **Given** a control plane with one person, **When** it starts with this version, **Then**:
   - that person becomes the local owner and the admin;
   - every client and every host record gets that person as its `owner`;
   - only fields are added, and no record moves.
2. **Given** that control plane, **When** a client pairs with a code, **Then** the client belongs to the local owner, as today.
3. **Given** any client, **When** it opens Settings, **Then** the rail shows three groups:
   - **This device**: Appearance and Sidebar;
   - **You**: Account, Agent Runtimes, Agent Configuration, Cost, Resources and Machines;
   - **Control plane**: People, Groups, Workspace Providers, Channels and Overview.
   The local owner sees every pane, because they are the admin.

---

### User Story 2 - A second person joins by signing in (Priority: P1)

Alex turns on Google sign-in and adds Alex's own Google account to Alex's person. Alex invites `sam@example.com`. Sam installs Agents, signs in with Google and accepts the invite. Sam sees no machines yet. People shows Sam as a member. Neither person sees the other's machines, agents or conversations.

**Why this priority**: this is the smallest thing a second person can use. Every other story builds on it.

**Independent Test**: on a scratch control plane with two people signed in on two clients, each person's clients list only that person's machines, agents and conversations. A request for the other person's machine is refused as "not found".

**Acceptance Scenarios**:

1. **Given** Alex is the local owner, **When** Alex signs in with Google on a client that Alex already has, **Then** that Google account becomes a second sign-in of Alex's person. No new person is made.
2. **Given** an invite to `sam@example.com`, **When** Sam signs in with a Google account for that address and accepts, **Then** Sam is a member, and Sam's client belongs to Sam.
3. **Given** Sam has joined, **When** Sam signs in with the same Google or Apple account on another Mac, iPhone or iPad, **Then** that client is paired to Sam with no code.
4. **Given** a sign-in made for one control plane, **When** it is sent again to another control plane, **Then** the second control plane refuses it.
5. **Given** a person who signs in with Apple and hides their email, **When** they redeem an invite code, **Then** they join. The control plane knows them by their Apple account, not by the relay address.
6. **Given** a person who signs in with GitHub, **When** they redeem an invite, **Then** they join, keyed by their numeric GitHub id. **When** they later sign in with GitHub on a second client, **Then** that client waits for **Approve** on their first client before it is paired.
7. **Given** an invite older than 7 days, or one that was used, **When** someone redeems it, **Then** it is refused, and the admin can send a new invite.
8. **Given** an admin who allows the Google Workspace domain `example.com`, **When** someone signs in with a Workspace account on that domain, **Then** they join as a member with no invite.
9. **Given** the control plane cannot reach a sign-in provider, **When** a person tries to sign in, **Then** they are told that sign-in is not available, and why. Clients that are already paired keep working.
10. **Given** a browser, **When** a signed-in person picks **Add a Browser**, **Then** a code shows, and the browser that uses it becomes that person's client.

---

### User Story 3 - A machine joins its user, and only its user sees it (Priority: P1)

Sam installs `agentsd` on a Linux server with the one-line command. The server prints a short code and "Waiting for approval". On Sam's Mac, a card says "**sam-build** wants to join as you", with the same code. Sam approves. The server is Sam's machine. Alex does not see it. In People, Alex sees its name and whether it is online.

**Why this priority**: machines are where agents run. Ownership means nothing until each machine has a user.

**Independent Test**: on a scratch control plane with two people, join one machine by approval, one by a machine code, and one started by a workspace provider. Each belongs to the expected user, and only that user can reach it.

**Acceptance Scenarios**:

1. **Given** a new machine that knows the control plane's address, **When** it asks to join, **Then**:
   - it shows a short code;
   - every signed-in client of the person named on the command shows **Approve** and **Deny** with that code;
   - if no person is named, every admin's clients show it.
2. **Given** that card, **When** the person approves, **Then** the machine belongs to that person and joins. **When** they deny, or 10 minutes pass, **Then** the request ends and the machine says so.
3. **Given** a machine code made on Sam's client (today's host code), **When** a machine joins with it, **Then** the machine belongs to Sam, with no approval.
4. **Given** a workspace provider in a group that Sam is in, **When** Sam starts a new workspace from it, **Then**:
   - the machine joins with a one-time join token that the control plane gave to the provider's start;
   - the machine belongs to Sam;
   - nobody approves it.
5. **Given** Sam's machine, **When** any client of Alex asks for it, or starts an agent, opens a terminal or reads a file on it, **Then** the request is refused as if the machine did not exist.
6. **Given** a Mac with Agents Host that joins a team control plane, **When** it joins, **Then** it belongs to the person who approved it. The window on that Mac reaches it directly only if the window belongs to the same person (#1118).
7. **Given** a machine's sidebar and Settings, **When** any client draws them, **Then** they say "Machine", and a workspace and a registered server show in one list.

---

### User Story 4 - Your settings follow you to your machines (Priority: P2)

Sam adds the GitHub MCP server with Sam's token under **You ▸ Agent Configuration**. A workspace that Sam starts the next day has that server and that token with no further step. Nobody else's machine gets Sam's token.

**Why this priority**: with started machines that come and go, a setting that lives on one machine is lost when the machine is deleted. That is why the user scope exists.

**Independent Test**: set an MCP server with a secret under You. Start a new machine for that user: the server is there and works. On another user's machine, the server and the secret are not there. In the store, the secret is not readable without the key.

**Acceptance Scenarios**:

1. **Given** a user setting, **When** the user changes it, **Then** the control plane keeps it and sends it to each of that user's machines that is online. A machine that is offline gets it when it joins again.
2. **Given** a user secret, **When** the control plane keeps it, **Then**:
   - it is encrypted with a data key;
   - the data key is wrapped by the control-plane key in the key service (Google Cloud KMS, or a 0600 file on a Mac);
   - the secret goes only down the links of that user's own machines, when a machine joins and when the secret changes.
3. **Given** a machine that leaves its user (removed, or deleted by its provider), **When** it is gone, **Then** it gets no more secrets. The user is told which secrets were on it.
4. **Given** a project with its own settings, **When** a user's agent runs in it, **Then** the project's settings apply over the user's settings, as project settings do today over host settings.
5. **Given** **This device** settings (Appearance, Sidebar), **When** they change, **Then** they stay on that client only, as today.

---

### User Story 5 - Admins manage people, groups and workspace providers (Priority: P2)

Alex, an admin, opens **Control plane ▸ People**. It lists each user with:

- their name;
- their sign-ins;
- their role;
- their clients;
- their machines, by name and online state.

Alex makes a group "Platform" with Sam and Kim, and gives the DigitalOcean workspace provider to that group. Sam and Kim can start machines from it. Alex removes Kim. Kim's started machines are listed with any work that is not pushed. Alex confirms, and those machines stop and are deleted.

**Why this priority**: a team needs someone to add and remove people, and to say who may spend money on machines.

**Independent Test**: as an admin on a scratch control plane, check that:

- People shows every user's machines by name and state only;
- a workspace provider is offered only to its group's members;
- removing a person cuts off their clients and deletes their started machines.

**Acceptance Scenarios**:

1. **Given** an admin, **When** they open People, **Then** they see every user, role, client and machine name with its state. They see nothing inside another user's machine.
2. **Given** an admin, **When** they remove a person, **Then** a confirmation lists that person's started machines, and for each one its branches and worktrees with work that is not pushed. **When** the admin confirms:
   - within 5 seconds the person's clients are cut off on every copy;
   - their started machines are stopped and deleted through their providers;
   - their registered machines leave the control plane;
   - their user secrets are deleted;
   - their sign-ins are refused until they are invited again.
3. **Given** one admin, **When** they try to remove themselves or give up admin, **Then** it is refused, because a control plane always has an admin.
4. **Given** a workspace provider, **When** an admin gives it to a group (named users, one user, or everyone), **Then** only that group's users can start machines from it. A machine it starts belongs to the user who started it.
5. **Given** a member, **When** they open Settings, **Then** the Control plane group shows People (themselves only) and Overview, read only. The other panes are not there.

---

### User Story 6 - A bot does the team's work on events (Priority: P2)

Alex makes a bot `review-bot` in the group "Platform", with a spend cap of $50 a day. Alex approves its machine, gives it the GitHub MCP server with an org token, and turns on a workflow from the team repo whose `runs-on:` names `review-bot`. On each `pr.opened`, one of the bot's machines runs the workflow once. Nobody can start the bot from a client. When a run cannot go on, it ends as **Needs attention**, and the admins get a notice.

**Why this priority**: team work that runs once per event, and is paid for by the team, is the second reason a team shares a control plane.

**Independent Test**: on a scratch control plane, make a bot with two machines and a workflow on `runs-on: [review-bot]`. Send one event: exactly one run happens. Check that:

- the bot is not in any client's New Agent menu;
- the bot's sessions have no ask tools;
- the bot stops at its cap.

**Acceptance Scenarios**:

1. **Given** an admin, **When** they make a bot, **Then** it has a People row, a group, its own machines, MCP servers, secrets and workflows. It has no clients and no sign-in.
2. **Given** a bot's machine that asks to join, **When** it waits for approval, **Then** admins approve it, not a person.
3. **Given** a bot, **When** any client tries to start, message or answer an agent on its machines, **Then** it is refused. **Run now** is not offered on a bot's workflows.
4. **Given** a workflow with `runs-on: [review-bot]`, **When** its trigger fires, **Then**:
   - the control plane leases the run to one online machine of that bot;
   - with none online and a workspace provider of the bot's group, it starts one;
   - it runs once per trigger.
5. **Given** a workflow with no `runs-on:`, **When** its trigger fires, **Then** it runs on the machines of each user who turned it on, as today.
6. **Given** a bot's session, **When** its agent wants to ask a question, **Then**:
   - it has no ask tools (no question cards, `ask_form` or needs-answer);
   - a tool permission is answered by the bot's policy alone, and a refused tool lets the agent carry on;
   - a run that cannot go on ends as **Needs attention**, with a notice to the admins.
7. **Given** a bot at its group's or its own spend cap, **When** it would start more work, **Then** it stops, and the admins get a notice. Its runtimes use API keys on an organisation account, not personal subscriptions.
8. **Given** a workflow on a bot's machine, **When** a schedule or a channel message ("@review-bot" in Slack from a linked identity) fires, **Then** it counts as an event and can start a run.

---

### User Story 7 - Channels know who is talking (Priority: P2)

The team's Slack is a channel on the control plane. Sam writes "@review-bot look at #412" in Slack. The first time, Sam's Mac shows "Link Slack user @sam to you?". Sam approves. From then on, Sam's Slack messages act as Sam, and events from them name Sam.

**Why this priority**: a chat or mail identity can be faked or given to someone else. A channel must not let someone act as another person.

**Independent Test**: from a scratch Slack identity that is not linked, a message starts nothing and asks for a link. After approval on a signed-in client, the same message starts the bot's workflow. An email from a linked address that fails DKIM is refused.

**Acceptance Scenarios**:

1. **Given** a channel identity that is not linked, **When** a message comes from it, **Then** nothing starts. The sender is asked to link it, and the person picks **Approve** on one of their signed-in clients.
2. **Given** a linked email address, **When** a message comes from it and its DKIM check fails, **Then** it is refused.
3. **Given** a channel, **When** an admin adds it, **Then** it runs on the control plane, not on a machine, so it works while machines are stopped.

---

### User Story 8 - Who did what (T3) (Priority: P3)

An admin opens **Activity ▸ Audit**. Each entry names an actor (a person and their client, or a bot and the event that started it), what was done, on which machine, and when. The admin can export the entries as JSON lines.

**Why this priority**: a team needs to know who did what. It is useful only after T1 and T2 make actors real.

**Independent Test**: take one action of each kind on a scratch control plane. Each is in the audit list with the correct actor. A client that names a different actor in its request is ignored: the control plane writes the actor itself.

**Acceptance Scenarios**:

1. **Given** any of these actions, **When** it is done through the control plane, **Then** it is recorded with the actor, the client and the time:
   - start, stop or delete an agent;
   - answer a card;
   - change a setting at any scope;
   - approve a machine, a channel link, a workflow, a plugin or an MCP server;
   - add or remove a person;
   - change a group or a workspace provider.
2. **Given** a bot's action, **When** it is recorded, **Then** the actor is the bot, and the entry names the event that started it.
3. **Given** default settings, **When** 90 days pass, **Then** entries older than that are deleted. An admin can set a different number of days.
4. **Given** a member, **When** they open Activity, **Then** they see their own entries only.

---

### User Story 9 - Keys expire and renew without a person seeing it (T4) (Priority: P3)

Client and machine keys expire after 90 days and renew when in use. A person whose Google Workspace account is removed has clients that stop renewing. The admin rotates the control key, and no client or machine pairs again.

**Why this priority**: a lost device or a removed account must stop working in time, but it is not needed for a team's first week.

**Independent Test**: on a scratch control plane with a short expiry, a client in use renews, and a client not in use is refused after expiry. Rotate the control key: every connected client and machine accepts the new key, and none pairs again.

**Acceptance Scenarios**:

1. **Given** a client or machine key, **When** it is used within its lifetime, **Then** it renews with no screen.
2. **Given** a client whose person signed in with Google, Apple or GitHub, **When** it renews, **Then** the person's sign-in must still be valid. A removed Workspace account stops renewing.
3. **Given** an admin, **When** they rotate the control key, **Then** clients and machines accept the new key, signed by the old key, over the next connection. Nobody pairs again.

### Edge Cases

- **Two Google accounts with the same email,** for example a personal account and a Workspace account, are two sign-ins. They are the same person only if that person added both. A person is never matched by email.
- **Invited email hidden by Apple:** an invite code can be redeemed with any Apple account. The invite keeps the email only to show who it was for. A person who redeems it with Apple sees a warning when the addresses are different. A Google invite must match its email.
- **The last admin's outside account is deleted:** the local owner sign-in recovers it. Whoever holds the control plane's key, through Agents Host or `agents-control`, can make a person admin.
- **A machine is approved by the wrong person:** that person removes it from Machines. It then joins again by a new approval. Nothing on the machine is deleted.
- **A machine moves to another control plane** (handover): it keeps its user only if that user exists there by the same sign-in. If not, it asks to join again.
- **A user's secret changes while one of their machines is offline:** the machine gets the new value when it joins again, before any workflow on it starts.
- **The key service cannot be reached:**
  - Machines that are joined keep their secrets.
  - A new join, or a change to a secret, is refused with the reason.
  - A started machine waits and tries again.
- **A started machine with work that is not pushed, and its user is removed:** the removal lists the work. It is lost only after the admin confirms.
- **A bot's workflow names a bot that is not there:** the workflow does not run. Its page says why.
- **Two machines of a bot both think they have the run:** the control plane's lease decides. The second machine is told no and does not start.
- **An agent's own tools** (`list_sessions`, `read_session`, `message_session`, `start_session`) see only sessions of the user who owns the machine. Leases such as "build" are per machine.
- **Clock skew** on the control plane's machine: sign-ins are checked with up to 5 minutes of tolerance. A refusal for time says so.
- **A sign-in provider rotates its keys:** the control plane gets the new keys and keeps working with no restart.
- **Copies of the control plane:** every copy enforces people, roles, groups and ownership the same way. A removal takes effect on every copy within 5 seconds.
- **An older client or machine** that knows nothing of people: it is read as the local owner's on a one-person control plane. On a control plane with more than one person, it is refused with "Update Agents to join this team".

## Requirements *(mandatory)*

### Functional Requirements

**People, sign-in providers and roles (T1, T2)**

- **FR-001**: The control plane MUST hold users. A user is a person or a bot. It has a name, a role (`admin` or `member`), and for a person one or more sign-ins, each `(provider, account id)`. Email is shown, but it never identifies a person.
- **FR-002**: Every control plane MUST have the local owner sign-in provider, which needs no account and no network. Codes are its sign-in. A control plane with no outside provider has one person, the local owner. The local owner's sign-in is `(local, <control-key id>)`.
- **FR-003**: On its first start with this version, a control plane MUST:
  - make its existing person the local owner and the admin;
  - make that person the `owner` of every client and host;
  - only add fields, and change no key.
- **FR-004**: An admin MUST be able to turn on Google, Apple and GitHub sign-in. None is required, also on a control plane that is reachable from the internet.
- **FR-005**: A person MUST be able to add an outside sign-in to themselves from a client they already have. It stays one person.
- **FR-006**: Admins MUST be able to:
  - invite a person by email (Google) or by an invite code to send (any provider);
  - allow Google Workspace domains;
  - allow GitHub organisations, which an invite's redeemer must be in;
  - change a role;
  - remove a person.
  A control plane MUST always keep at least one admin.
- **FR-007**: An invite MUST be for one use, and it MUST expire after 7 days. A Google invite redeemed with an account other than the one invited MUST be refused.

**Sign-in (T2)**

- **FR-008**: Google and Apple sign-in MUST be done by the client (Apple: `ASAuthorizationAppleIDProvider`; Google: `ASWebAuthenticationSession` with PKCE). The client sends the ID token over R6. The control plane checks:
  - the signature against the provider's JWKS;
  - `iss`, `aud` and the expiry;
  - a `nonce` bound to this control plane's key id and the hello nonce.
- **FR-009**: Google and Apple sign-in MUST pair a joined person's further clients with no code.
- **FR-010**: GitHub sign-in MUST use the app's GitHub App, with the device flow and user tokens that expire. The control plane:
  - calls `GET https://api.github.com/user` once;
  - keeps the numeric `id` and the `login`;
  - then forgets the token.
  A GitHub person MUST join only by an invite, and each further client MUST be approved on one of that person's signed-in clients.
- **FR-011**: A sign-in made for one control plane MUST NOT pair a client on another without that control plane's own invite or approval.
- **FR-012**: The control plane's operator MUST NOT need to register anything with Google, Apple or GitHub. The audience is the app's own client ids.
- **FR-013**: A sign-in provider MUST be described generally, as an OIDC issuer and client id, or as an OAuth provider of the GitHub kind. Another provider later (T9) MUST need configuration only, not a change to what is stored.
- **FR-014**: A browser MUST pair by a code shown on a signed-in client, and becomes that person's client. Direct sign-in in the browser needs an OIDC client that the operator registers, and is T9.
- **FR-015**: When a provider cannot be reached, the person MUST be told that sign-in is not available, and why. Paired clients MUST be unaffected.

**Machines (T1)**

- **FR-016**: Every machine MUST belong to exactly one user. The screen MUST call hosts and workspaces "machines", in one list. The code, the wire and the store keep `host`.
- **FR-017**: A machine MUST be able to join in three ways:
  - **Approval:** the machine shows a short code. The person (or, for a bot or no person named, an admin) approves it on a signed-in client within 10 minutes.
  - **Machine code:** made on a client. The machine belongs to that client's person.
  - **Join token:** for one use. The control plane gives it to a workspace provider's start. The machine belongs to the user who started it.
- **FR-018**: Every request through the control plane MUST be checked against the user who asks. A person may reach only machines they own. A request for any other machine MUST be refused as "not found".
- **FR-019**: Admins MUST see every machine's name, user and state, and nothing inside it.
- **FR-020**: The window's direct path to this Mac's machine (#1118) MUST be used only when the window and the machine belong to the same person.
- **FR-021**: `signInFrom` and `gitFrom` MUST name only machines of the same user.

**Scopes and secrets (T1)**

- **FR-022**: Settings MUST have the scopes this device, you, control plane and project. One Settings window MUST group its rail by scope, on all three clients. *Amended by #2157:* Settings MUST group its rail by subject: **This app** (the web: **This browser**), **Machines** and **Control plane** (the person's account first); project settings stay in the project's own sheet. A pane whose part can be the same on every machine MUST say at its top where an edit in it goes, with the switch, in place of a pane of its own for those switches (#2157 step 2). See [settings-by-subject.md](settings-by-subject.md).
- **FR-023**: These settings MUST be at the user scope:
  - MCP servers and their secrets;
  - agent configuration (skills, instructions, personas);
  - runtime choices and models;
  - cost limits;
  - resources.
  Runtime sign-ins MUST stay on each machine.
- **FR-024**: The control plane MUST keep user settings, and send them to each of the user's machines when it joins and when they change.
- **FR-025**: The control plane MUST keep user secrets in envelope encryption:
  - each secret is encrypted with a data key;
  - the data key is wrapped by the control-plane key in Google Cloud KMS, or in a 0600 file outside the store on a Mac;
  - the store MUST NOT hold a readable secret (store rule 7);
  - a secret MUST go only down the links of its own user's machines.
- **FR-026**: Removing a machine MUST stop secrets going to it, and tell its user which secrets it had.

**Groups and workspace providers (T1)**

- **FR-027**: Admins MUST be able to make groups. A group is named users, one user, or everyone.
- **FR-028**: Each workspace provider MUST belong to a group. Only that group's users may start machines from it. A started machine belongs to the user who started it.

**Removing a person (T1)**

- **FR-029**: Remove MUST first list the person's started machines, with the branches and worktrees on each that have work that is not pushed. After the admin confirms, within 5 seconds on every copy, the control plane MUST:
  - cut off the person's clients;
  - stop and delete their started machines through their providers;
  - take their registered machines off the control plane;
  - delete their user settings and secrets;
  - unlink their channel identities;
  - refuse their sign-ins until they are invited again.

**Bots and workflows (T1)**

- **FR-030**: Admins MUST be able to make, configure and remove bots. A bot has a group, its own machines, user settings, secrets and workflows. It has no clients and no sign-in. Admins approve its machines.
- **FR-031**: No client MUST be able to start, message, stop for work, or answer an agent on a bot's machine. **Run now** MUST NOT be offered on a bot's workflows. Admins MAY stop a bot's run.
- **FR-032**: A bot's sessions MUST have no ask tools. A tool permission MUST be answered by the bot's policy alone. A run that cannot go on MUST end as **Needs attention**, with a notice to the admins.
- **FR-033**: Spend caps MUST be settable per group and per bot. At a cap, the bot MUST stop starting work, and the admins MUST get a notice.
- **FR-034**: Workflows MUST replace `hosts:` with `runs-on:`, a list of labels. The labels are matched against machine labels: `os`, `provider`, and the user's or bot's name. A machine needs every label, except machine ids: it needs to be one of those it names (#2064).
  - A workflow with a bot's name in `runs-on:` MUST run once per trigger, leased to one of that bot's machines. If none is online and a workspace provider of the bot's group is there, the control plane MUST start a machine (#1004).
  - A workflow with no `runs-on:` MUST run on the machines of each user who turned it on, as today.
- **FR-035**: Events MUST have a scope:
  - **machine events** (`machine.disk_low`, drop box) stay on their machine;
  - **project and control-plane events** (`github`, channels, schedules on a bot's workflow) are sent once by the control plane.

**Channels (T1)**

- **FR-036**: Channels MUST run on the control plane, as MCP servers (#1223).
- **FR-037**: A channel identity MUST be linked to a user by approval on one of that person's signed-in clients before a message from it acts as that person. Email MUST also pass DKIM for the linked address. A message from an identity that is not linked MUST start nothing.

**Agent tools (T1)**

- **FR-038**: The app's agent tools MUST act as the user who owns the machine. `list_sessions`, `read_session`, `message_session` and `start_session` MUST reach only that user's sessions. Resource leases MUST be per machine.

**Who did what (T3)**

- **FR-039**: Every action through the control plane MUST carry its actor, written by the control plane, never taken from the client. The actor is:
  - a person and their client; or
  - a bot and the event that started it.
- **FR-040**: The control plane MUST keep audit entries for 90 days by default, and an admin MUST be able to change that. Machines MUST write the actor into `events.jsonl`.
- **FR-041**: Admins MUST get **Activity ▸ Audit**, read only, with a JSON-lines export. Members see only their own entries.

**Key lifetimes (T4)**

- **FR-042**: Client and machine keys MUST expire after 90 days by default, and renew when in use. A client of an outside sign-in MUST renew only while that sign-in is still valid.
- **FR-043**: An admin MUST be able to rotate the control key. Clients and machines accept the new key, signed by the old key, over R6, with no new pairing. Spec 058 FR-013 is rewritten to point here.

**Clients in step**

- **FR-044**: The Mac window, the Remote and the web page MUST all show:
  - the Settings rail by scope;
  - People, Groups, Workspace Providers, Channels and Overview for admins;
  - sign-in on the Mac and the Remote, and a code on the web;
  - the machine approval card;
  - Machines in one list;
  - bots in People;
  - **Needs attention** for a bot's run;
  - Activity ▸ Audit.
  The parity table MUST get a row for each.

**Storage**

- **FR-045**: Users, sign-ins, invites, groups, join requests, channel links, user settings, wrapped secrets and audit entries MUST be kept in the store under the prefix. Nothing outside the prefix may name an organisation. Plain files only: no database.

### Key Entities

- **User**: an id, a kind (`person` or `bot`), a name, a role (`admin` or `member`).
  - A person also has sign-ins and clients.
  - A bot also has a group and spend caps.
  - Every user has machines, user settings and secrets.
- **Sign-in**: a provider (`local`, `google`, `apple`, `github`, later others) and that provider's account id. It keeps an email for display only.
- **Sign-in provider**: an OIDC issuer and client id, or an OAuth provider of the GitHub kind, with its allowed domains or organisations. The local owner is always there.
- **Invite**: who it is for (an email, or whoever holds it), the role it gives, who sent it, when it expires, and whether it was used.
- **Client**: as today, with an owning person.
- **Machine** (`host` in code): as today, with an owning user and labels. It is linked to a workspace when a provider started it.
- **Join request**: a machine's public key and name, its short code, the person named or none, when it expires, and the result.
- **Join token**: one use. It is made for one start of one workspace provider, for one user.
- **Group**: a name, and named users, one user, or everyone. Workspace providers and bots belong to a group.
- **User setting**: a key and a value at the user scope. A secret's value is kept wrapped.
- **Channel link**: a channel, an identity on it, a user, and who approved it when.
- **Audit entry**: an actor (user, client or event), an action, a target, a machine, and a time.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A one-person control plane updated to this version shows no change in its window, phone or browser, other than the Settings rail grouped by scope, and asks nothing.
- **SC-002**: A person invited by email joins, approves their first machine, and starts an agent on it in under 5 minutes, with no code typed.
- **SC-003**: In a control plane of 10 users and 30 machines, no request from a user reaches a machine that is not theirs. An automated test checks this for every client method.
- **SC-004**: Removing a person cuts off their clients within 5 seconds on every copy.
- **SC-005**: A sign-in sent again to a second control plane pairs no client there, in 100% of attempts in tests, for Google, Apple and GitHub.
- **SC-006**: A user's MCP server and secret are working on a newly started machine of theirs within 30 seconds of it joining, with nobody online.
- **SC-007**: No readable user secret is in the store. A test reads every file under the prefix for each test secret.
- **SC-008**: One trigger of a bot's workflow gives exactly one run, also with three of the bot's machines online, in 100 tries in tests.
- **SC-009**: Someone who runs a control plane on their own machine turns on Google, Apple and GitHub sign-in without making an account or a registration with any of them.

## Docs *(mandatory)*

- `docs/explanation/control-plane.md`: change. "One grant for every client" becomes users, roles, machines and scopes. One person keeps what they have.
- `docs/explanation/people-and-machines.md`: add. One user per machine, the three scopes, bots, and why there is no sharing.
- `docs/explanation/projects-hosts-worktrees.md`: change. A host and a workspace are a machine.
- `docs/how-to/invite-someone.md`: add. Turn on a sign-in provider, invite, allow a domain or organisation, change a role, remove a person.
- `docs/how-to/add-a-machine.md`: add. It replaces `add-a-server.md`, with join by approval, by code, and by a provider.
- `docs/how-to/set-up-a-bot.md`: add. Make a bot, approve its machine, give it secrets, use `runs-on:`.
- `docs/how-to/connect-a-window-or-phone.md`: change. Sign in with Google, Apple or GitHub. A browser still pairs by code.
- `docs/how-to/start-workspaces-from-agents.md` and `docs/reference/workspace-providers.md`: change. Providers belong to groups, and a started machine belongs to who started it.
- `docs/reference/settings.md`: change. The rail by scope, and each pane's scope.
- `docs/reference/workflows.md`: change. `runs-on:` replaces `hosts:`, and events have scopes.
- `docs/reference/events.md`: change. Each event's scope, and the actor on each entry.
- `docs/reference/agent-tools.md`: change. Tools see only their user's sessions, and bots have no ask tools.
- `docs/reference/agents-folder.md`: change. User settings come from the control plane.
- `specs/058-control-plane/spec.md`: change. FR-012 (`owner`) and FR-013 (grants) point here.
- `specs/071-web-remote/walks/parity.md`: change. A row for each item in FR-044.
- `docs/reference/integrations.md`: change. The Google, Apple and GitHub sign-in rows.

## Assumptions

- **The app owns the client ids.**
  - The Google OAuth client, the Sign in with Apple Services id and the GitHub App are under Alex's developer accounts. Making them is Alex's job (#995).
  - Every self-hosted control plane trusts sign-ins made for those ids, bound to itself.
- **Google Cloud KMS** is the key service for a control plane in the cloud. It is in the Google Cloud project that #61 uses. A control plane on a Mac uses a 0600 file.
- **One organisation per control plane.** Two teams that want to be kept apart run two control planes until the hosted tier (T10).
- **Teams are small:** up to about 20 people, 10 bots and 50 machines per control plane, in line with spec 058's sizing.
- **Admins are not super-users.** An admin cannot open another user's machine. Admins reading transcripts is not in this cut.
- **v0.x takes breaking changes.** A machine's id is also one of its labels, so `hosts: [id]` becomes `runs-on: [id]`. A workflow that still says `hosts:` does not run. Its page and the release notes tell the user what to change. No migration code is written.
- **The `area:workspaces` label becomes `area:machines`** when this is built.
- **Not in this spec:** sharing machines, policy (T5), org keys and gateways (T6), and bring-your-own OIDC and SCIM (T9). Making an outside sign-in mandatory on a public control plane is also not in it. The model makes all of these possible later.
- **Linux machines' daemon socket** gets per-agent rights in #726, separately. This spec governs what reaches a machine through the control plane.
