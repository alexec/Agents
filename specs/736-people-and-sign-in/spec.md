# Feature Specification: People, roles and sign-in

**Feature Branch**: `agents/team-spec-736`

**Created**: 2026-10-11

**Status**: Draft

**Milestone**: Beta (Alex, 2026-10-11: team and enterprise are beta features). Nothing here is built during the alpha.

**Input**: Issue #736. This is the team tier's first slice, T1 and T2 of `specs/research/733-team-and-enterprise.md`, following the enterprise review (`.agents/reviews/enterprise/2026-10-11.md`).

## Why this feature exists

**Today a control plane belongs to one person.**
- Every paired client may do everything on every host: run commands, pair more clients, forget others, add hosts (#111, `docs/explanation/control-plane.md` "One grant for every client").
- That is right for one person with a Mac, a phone and a browser. It is wrong as soon as a second person joins: their lost phone could drive the first person's Mac.

**Teams want to share some things and not others.** Two developers who share a build server want to see each other's agents there. They do not want to see each other's laptops. Their lead wants to add and remove people without being able to drive anyone's machine.

**This feature makes the control plane hold people.**
- Each person signs in with Google or Apple.
- Each client and each host belongs to one person.
- A host is seen only by its owner, unless the owner shares it.
- Admins manage people. They do not get into other people's hosts by being admins.

**One person's control plane works exactly as it does today.**

### Decisions already taken (Alex, 2026-10-11)

- **Tenancy:** one organisation per control plane, self-hosted first. What is stored must not change when a hosted, many-organisation service is added later.
- **Hosts:** a host is visible to its owner only, unless shared.
- **Identity:** Google and Apple, through standard OpenID Connect, so other providers fit the same slot later.
- **Admin policy:** it will come from the control plane (a later spec, T5). This spec only gives admins the role that policy will hang on.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - A second person joins and sees only their own things (Priority: P1)

Alex runs a control plane. Alex invites Sam, by email or by a code to send. Sam installs Agents on their Mac, signs in with Google and accepts the invite. Sam enrols the Mac as a host. Sam sees Sam's Mac. Alex sees Alex's hosts and, in People, that Sam has joined. Neither sees the other's hosts or agents.

**Why this priority**: this is the smallest thing a second person can use, and every other story builds on it. Without it, adding Sam means giving Sam everything.

**Independent Test**: on a scratch control plane with two people signed in on two clients, each person's clients list only that person's hosts, agents and conversations. Any request for the other's host is refused.

**Acceptance Scenarios**:

1. **Given** a control plane with one person, Alex, **When** Agents is updated to this version, **Then** Alex is its admin, owns every existing client and host, and sees exactly what Alex saw before. Nothing asks Alex to sign in.
2. **Given** Alex invites `sam@example.com`, **When** Sam signs in with a Google account for that address and accepts, **Then** Sam is a member, and Sam's client belongs to Sam.
3. **Given** Sam enrols a Mac or a Linux server, **When** Sam opens Agents, **Then** that host appears for Sam, and does not appear for Alex.
4. **Given** Sam's client, **When** it asks for, starts an agent on, opens a terminal on, or reads files from one of Alex's hosts, **Then** it is refused as if the host did not exist.
5. **Given** an invite, **When** someone signs in with a different Google or Apple account than the one invited, **Then** they are told the invite is for someone else, and nothing is created.
6. **Given** an invite older than 7 days, or already used, **When** it is redeemed, **Then** it is refused, and the admin can send a new one.

---

### User Story 2 - Sign in with Google or Apple on every client (Priority: P1)

A person signs in to a control plane with their Google or Apple account. That works on the Mac window, on iPhone and iPad, and in a browser (through a client already signed in). Signing in is how a person pairs a new client of their own. The person needs no code, and the control plane's operator needs no Google or Apple set-up of their own.

**Why this priority**: identity is what makes ownership mean something. Codes alone cannot tell Sam's phone from Alex's.

**Independent Test**: on a scratch control plane, sign in on a Mac window and an iPhone with the same Google account. Both are that person's clients, and People shows one person with two clients.

**Acceptance Scenarios**:

1. **Given** a person who has joined, **When** they sign in with the same Google or Apple account on another Mac, iPhone or iPad, **Then** that client is paired to them with no code.
2. **Given** a browser, **When** the person picks Add a Browser on a signed-in client, **Then** a code is shown as today, and the browser that uses it becomes that person's client.
3. **Given** a control plane run on someone's own machine with no Google or Apple configuration, **When** a person signs in, **Then** it works: the operator registered nothing with either provider.
4. **Given** a sign-in made for one control plane, **When** it is replayed to another control plane, **Then** the second refuses it.
5. **Given** a person who signs in with Apple and hides their email, **When** they redeem an invite, **Then** they join. They are known by their Apple account, not by the relay address.
6. **Given** a control plane that cannot reach Google or Apple to check a sign-in, **When** a person tries to sign in, **Then** they are told sign-in is unavailable and why. Clients already paired keep working.

---

### User Story 3 - Share a server with the team (Priority: P2)

Sam enrols a shared build server and shares it with the team at "drive". Everyone in the team now sees the server, its agents and their conversations. They can start agents there, answer cards and open terminals. Sam shares a second server with Alex alone, at "see". Alex can read that server's agents and conversations, but cannot start, stop or answer anything there.

**Why this priority**: sharing is why a team shares a control plane at all, but owner-only (US1) is safe and useful without it.

**Independent Test**: with three people on a scratch control plane, share one host with the team at drive and another with one person at see. Check each person's list and each refused action.

**Acceptance Scenarios**:

1. **Given** Sam's host, **When** Sam shares it with the team at drive, **Then** every person in the team sees it. It is grouped under "Shared by Sam", and each person can start agents, answer cards, stop agents and open terminals there.
2. **Given** a host shared with Alex at see, **When** Alex opens it, **Then** Alex reads its agents, conversations and files. Starting, stopping, answering, typing into a terminal or writing a file is refused, and the controls for them are not shown.
3. **Given** a shared host, **When** Sam stops sharing it, **Then** within 5 seconds it disappears for the people it was shared with, and any terminal or open conversation of theirs on it closes with "No longer shared with you".
4. **Given** an agent started on Sam's host by Alex, **When** anyone looks at it, **Then** it says Alex started it. Sam, as the owner, can always see and stop it.
5. **Given** a host shared with the team, **When** a new person joins later, **Then** they see it too.
6. **Given** sharing at see, **When** Sam shares, **Then** Sam is told that people it is shared with can read everything its agents read and print, including any secret an agent printed.

---

### User Story 4 - Admins manage people without driving their hosts (Priority: P2)

Alex, an admin, opens Settings ▸ People. It lists everyone: each person's name, their sign-in (Google or Apple, with an email where there is one), their role, their clients and their hosts by name and status. Alex can invite people, make Sam an admin, and remove someone. Alex cannot open a host that is not Alex's own unless it is shared with Alex.

**Why this priority**: a team needs someone to add and remove people. Keeping admin separate from access means making someone admin does not hand them everyone's laptop.

**Independent Test**: as an admin on a scratch control plane, check that People shows every person's hosts by name and status only. Removing a person ends their clients' connections and takes their hosts off.

**Acceptance Scenarios**:

1. **Given** an admin, **When** they open People, **Then** they see every person, role, client and host name with its online state. They see no host's agents, conversations or files unless that host is theirs or shared with them.
2. **Given** an admin, **When** they remove Sam, **Then**:
   - within 5 seconds Sam's clients are cut off;
   - Sam's hosts leave the control plane, and their agents stop being reachable through it;
   - shares Sam gave or was given end;
   - Sam can no longer sign in to this control plane until invited again.
3. **Given** two admins, **When** one removes the other or makes them a member, **Then** it is allowed. **Given** one admin, **When** they try to remove themselves or give up admin, **Then** it is refused: a control plane always has an admin.
4. **Given** a member, **When** they open Settings, **Then** People shows only the people they share hosts with. They cannot invite, remove or change roles.
5. **Given** a member, **When** they open Settings ▸ Clients, **Then** they see and can forget only their own clients. That replaces today's "any client may forget any client".
6. **Given** an admin and Google sign-in, **When** they allow the domain `example.com`, **Then** anyone signing in with a Google Workspace account on that domain joins as a member without an invite. Accounts that are not Workspace accounts, and Apple accounts, still need an invite.

---

### User Story 5 - A control plane with no sign-in provider keeps working (Priority: P3)

Someone runs a control plane that cannot or should not reach Google or Apple: an offline lab, or a person who prefers codes. With no provider turned on, everything works as today. One person pairs every client with codes, and there is one grant for every client.

**Why this priority**: it keeps today's behaviour for anyone who does not need a team, and keeps air-gapped use possible.

**Independent Test**: on a scratch control plane with sign-in turned off, pairing by code works as today, and People offers no invite.

**Acceptance Scenarios**:

1. **Given** sign-in turned off, **When** a client pairs by code, **Then** it belongs to the one person, as today.
2. **Given** sign-in turned off, **When** the admin opens People, **Then** Invite explains that inviting needs Google or Apple sign-in turned on, and offers to turn it on.
3. **Given** a host on any control plane, **When** it enrols, **Then** it uses a host code as today. Hosts never sign in with Google or Apple. The host belongs to the person whose client made the code.

### Edge Cases

- **Two Google accounts with the same email,** for example a personal account and a Workspace account: they are two different people. A person is their provider and account, never their email.
- **An invited email Apple hides behind a relay:** an invite can be redeemed with any Apple account. The invite carries the email only to show who it was meant for, and a person who redeems it with Apple is warned when the addresses differ. Google invites must match the email.
- **The last admin's account is deleted at Google or Apple:** the control plane cannot lose its only admin. Recovery is by the control plane's key, as today's handover: whoever holds the key on the machine can make a person admin from Agents Host or `agents-control`.
- **A host's owner is removed while their host runs agents:** the host leaves the control plane. Its agents keep running on that machine, as with today's Remove Host, and the owner can enrol it again on another control plane.
- **A person shares a host, then the host is moved to another control plane** (handover): shares do not travel. The host arrives unshared.
- **Clock skew** on the control plane's machine: sign-ins are checked with up to 5 minutes' tolerance, and a refusal for time says so.
- **A provider rotates its signing keys:** the control plane fetches the new keys and keeps working without a restart.
- **The web page served on a domain of the organisation's own:** it pairs by code from a signed-in client, as today (US2-2). Direct sign-in in the browser is a later spec (T9).
- **An agent on a shared host calls the app's own tools** (start a helper, message an agent): it acts with the rights of the person who started it, never the host owner's. On a host shared at see, nobody but the owner can start agents.
- **Copies of the control plane:** every copy enforces people, roles and shares the same way. Removing a person or a share takes effect on every copy within 5 seconds, as forgetting a client does today (FR-009 of spec 058).

## Requirements *(mandatory)*

### Functional Requirements

**People and roles**

- **FR-001**: The control plane MUST hold people. Each person has a name, a role (`admin` or `member`), and the sign-ins they use: a provider and that provider's account id. Email is shown but never identifies a person.
- **FR-002**: On first start with this version, an existing control plane MUST make its existing person the admin and owner of every existing client and host. It MUST NOT ask that person to sign in, and MUST NOT change any record a later hosted service would need to move.
- **FR-003**: Admins MUST be able to invite a person by email (Google) or by an invite code to send (Google or Apple). They MUST be able to change a person's role and remove a person. A control plane MUST always keep at least one admin.
- **FR-004**: An admin MUST be able to allow one or more Google Workspace domains. A Google sign-in carrying one of those domains joins as a member without an invite.
- **FR-005**: An invite MUST be one-time and expire after 7 days. Redeeming it with an account other than the one invited (for Google) MUST be refused.
- **FR-006**: Removing a person MUST, within 5 seconds on every copy:
  - cut off their clients;
  - take their hosts off the control plane;
  - end every share they gave or were given;
  - refuse their sign-ins until they are invited again.

**Ownership and sharing**

- **FR-007**: Every client and every host MUST belong to exactly one person. A client belongs to the person who signed it in, or who made the code it paired with. A host belongs to the person whose client made its host code.
- **FR-008**: Every request through the control plane MUST be checked against who is asking. A person may reach only hosts they own or that are shared with them. Everything else is refused as "not found", so a host's existence is not disclosed.
- **FR-009**: An owner MUST be able to share a host with the whole team or with named people, at **see** or **drive**:
  - **see:** read agents, conversations, files and terminals' output;
  - **drive:** everything see allows, plus start, stop and answer agents, type into terminals and write files.
  - Only the owner may share, change or end a share.
- **FR-010**: Ending a share MUST take effect within 5 seconds, closing the people's open terminals and conversations on that host with a message saying it is no longer shared.
- **FR-011**: Admins MUST see every person's hosts by name and online state, and nothing inside them, unless the host is theirs or shared with them.
- **FR-012**: Everything done on a host through the control plane MUST record the person who did it. That covers starting an agent, answering a card, stopping, and writing a file. An agent started by one person on another's host MUST say who started it.
- **FR-013**: The app's own tools used by an agent MUST act with the rights of the person who started that agent.
- **FR-014**: Settings ▸ Clients MUST list and forget only the person's own clients. Admins may additionally forget any person's client from People.

**Sign-in**

- **FR-015**: People MUST be able to sign in with Google or Apple on the Mac window, iPhone and iPad. Signing in pairs that client to the person with no code.
- **FR-016**: A browser MUST pair by a code shown on a client already signed in, and become that person's client.
- **FR-017**: A sign-in MUST be usable only with the control plane it was made for, and only once. A sign-in captured on the way to one control plane MUST be refused by any other.
- **FR-018**: A control plane MUST check sign-ins without its operator registering anything with Google or Apple. It needs only to reach the providers' published signing keys, which it keeps and refreshes.
- **FR-019**: The way a provider is described MUST be general: an issuer and a client id, with Google and Apple as the two built in. Adding another standard provider later (T9) must need configuration, not a change to what is stored.
- **FR-020**: Sign-in MUST be something an admin can turn off. With it off, the control plane behaves exactly as today (US5).
- **FR-021**: Hosts MUST keep enrolling by host code. Codes MUST keep working for browsers, and for clients when sign-in is off.
- **FR-022**: When a provider cannot be reached to check a sign-in, the person MUST be told sign-in is unavailable and why. Clients already paired MUST be unaffected.

**Clients in step**

- **FR-023**: The Mac window, the Remote and the web page MUST all show:
  - People;
  - Share on a host's menu;
  - a "Shared by <name>" group for shared hosts;
  - who started an agent, when it was not you;
  - see-only hosts without the controls a viewer cannot use.
  - The parity table gains a row for each.

**Storage**

- **FR-024**: People, invites, roles and shares MUST be kept in the control plane's store with the rest of its records. Nothing outside the store's prefix may name an organisation, so a later hosted service can hold one organisation per prefix unchanged. No secret may be stored (store rule 7).

### Key Entities

- **Person**:
  - who someone is on this control plane: a name, a role, and one or more sign-ins;
  - owns clients and hosts.
- **Sign-in**:
  - a provider (Google, Apple, or later another) and that provider's account id;
  - the email the provider gave, kept only for display.
- **Invite**:
  - who it is for (an email, or anyone holding it);
  - the role they get, who sent it, and its expiry;
  - one use.
- **Allowed domain**: a Google Workspace domain whose accounts join as members without an invite.
- **Client**: as today, now with an owning person.
- **Host**: as today, now with an owning person and its shares.
- **Share**:
  - a host;
  - who it is for (the team, or a named person);
  - a level (see or drive).

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A person invited by email joins and sees their first enrolled host in under 3 minutes, with no code typed.
- **SC-002**: In a control plane of 10 people and 30 hosts, no request from a person reaches a host that is neither theirs nor shared with them. This is checked for every client method in an automated test.
- **SC-003**: Removing a person or ending a share cuts off the affected clients within 5 seconds, on every copy.
- **SC-004**: A one-person control plane updated to this version shows no change in its window, phone or browser, and asks nothing.
- **SC-005**: Someone running a control plane on their own machine turns on Google and Apple sign-in without creating any account or registration with either provider.
- **SC-006**: A sign-in replayed to a second control plane is refused in 100% of attempts in tests.

## Docs *(mandatory)*

- `docs/explanation/control-plane.md` — change: "One grant for every client" becomes people, roles and ownership; one grant is what a single person still has.
- `docs/how-to/invite-someone.md` — add: invite a person, allow a domain, change a role, remove a person.
- `docs/how-to/share-a-host.md` — add: share a host with the team or a person, at see or drive, and stop sharing.
- `docs/how-to/connect-a-window-or-phone.md` — change: sign in with Google or Apple; a browser still pairs by code.
- `docs/reference/settings.md` — change: People and Clients entries, sign-in switch, allowed domains.
- `specs/058-control-plane/spec.md` — change: FR-012 (`owner`) and FR-013 (grants) to point at this spec.
- `specs/071-web-remote/walks/parity.md` — change: rows for People, Share, Shared by and who started an agent.

## Assumptions

- **Google and Apple client ids belong to the app.** They are registered under Alex's developer accounts, and creating them is Alex's to do. Every self-hosted control plane trusts sign-ins made for those ids, bound to itself.
- **One organisation per control plane.** Two teams wanting isolation run two control planes until the hosted tier (T10).
- **Teams are small:** up to about 20 people and 50 hosts per control plane, in line with spec 058's sizing.
- **Admins are not super-users.** An admin who needs into a host asks its owner to share it. Recovery when every admin is lost is by the control plane's key, as handover is today.
- **Retention of who-did-what** stays as today (events 7 days on the control plane, the host's `events.jsonl`). Longer retention, an audit page and export are T3.
- **Key expiry and rotation** are T4. Org-wide policy (mode ceiling, sandbox, runtimes) is T5. Single sign-on through an organisation's own provider, and SCIM, are T9.
- **The direct browser sign-in** needs a provider registration for the browser's domain, so it waits for T9. Browsers pair by code meanwhile.
- **Linux hosts' daemon socket** gets per-agent rights in #726, independently. This spec governs what reaches a host through the control plane, not processes on the host itself.
