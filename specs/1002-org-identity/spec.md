# Feature Specification: Enterprise T9: org identity (bring your own OIDC, SCIM 2.0)

**Feature Branch**: `agents/are-0-11-enterprise-7` (spec only)

**Created**: 2026-10-21

**Status**: Draft. Nothing here is built yet.

**Milestone**: 0.11 Enterprise. Nothing for 0.11 merges to `main` before v0.10.0 ships.

**Input**: Issue #1002, roadmap step T9 in `specs/research/733-team-and-enterprise.md`. It builds on:

- **T1 and T2** (spec 736, merged in code): people, roles, groups, and sign-in with Google, Apple, GitHub and the local owner. Spec 736 FR-013 says that another provider later needs configuration only, not a change to what is stored.
- **T3** (spec 736 US8): the audit trail, with the actor written by the control plane.
- **T4** (spec 736 US9): client and machine keys that expire and renew. A client of an outside sign-in renews only while that sign-in is still valid.
- **T5** (#998, PR #2164, `specs/998-org-policy/`): Console ▸ Policy on the web page, and **Set by your organisation**.
- **T6** (#999, PR #2180, `specs/999-org-keys-gateways/`): secrets kept sealed with the control plane's keeper, never shown again, and a fingerprint for admins.
- **Pair by signing in** (#2097): sign-in first on the Mac and the Remote, and a browser that pairs by approval. T9 gives a browser a direct sign-in for the people of an org provider.

## Why this feature exists

**Today a team signs in with Google, Apple or GitHub, through the app's own client ids.**

- That is correct for a small team. It is not enough for an organisation.
- An organisation keeps its people in its own identity provider: Okta, Microsoft Entra ID, or Google Workspace with a client of its own. Its IT team adds and removes people there, once, for every tool.
- Its security team wants three things:
  - people sign in through the organisation's provider, with its rules (multi-factor, device checks, conditional access);
  - a person who leaves the organisation loses access to every tool in minutes, without a second step in each tool;
  - roles come from the provider's groups, not from a list that one admin keeps by hand.

**This feature lets the organisation bring its own provider.**

- An admin adds an **org provider** in Console ▸ Sign-In on the web page: an OIDC issuer, a client id and a client secret that the organisation registered. The control plane keeps the secret sealed, as T6 keeps keys.
- People sign in with it on the Mac, the Remote and the web page. The web page signs in directly, with no code and no approval.
- The admin can claim the organisation's email domains. Then people at those domains are sent to the org provider, and can be made to use it.
- The admin can turn on **SCIM 2.0**. The provider then adds people (joiners), changes them, and takes them away (leavers). A leaver's clients are cut off in seconds, and their keys stop renewing.
- The provider's groups come in as T1 groups. An admin gives a group the admin role, workspace providers, bots and org routes (T6).

**A control plane with no org provider works as today.** One person sees no change. Google, Apple, GitHub and the local owner stay.

## Decisions

Each of these is decided and easy to undo. Alex can overrule each one.

| # | Question | Answer |
|---|---|---|
| D1 | What is an org provider? | **A generic OIDC provider**: an issuer URL, a client id, a client secret, a name to show, and the claim that identifies a person. The control plane reads the issuer's discovery document (`/.well-known/openid-configuration`). Okta, Entra and Google Workspace are each the same kind with different values. No code is special to one vendor, except presets in the Console that fill in the issuer pattern and the claim. Decided, because spec 736 FR-013 already asks for a general provider, and because one code path is one thing to test. |
| D2 | Who runs the sign-in flow? | **The control plane, as a confidential OIDC client**, with the authorization code flow, PKCE (S256), `state` and `nonce`. Its redirect URI is `https://<control plane>/v1/oidc/callback`, on the control plane's own HTTPS address (the one the web page uses). The Mac and the Remote open that flow in `ASWebAuthenticationSession`; the web page opens it in the same tab. Decided, because the organisation registered the client for this control plane only, so its tokens cannot pair a client on another control plane (the replay that spec 736 R2 and R3 guard against), and one flow serves all three clients. The built-in providers keep their client-side flow (spec 736 FR-008). |
| D3 | How does the client get the result? | **A sign-in ticket.** After the callback, the control plane checks the ID token, and makes a ticket for one use, which ends after 2 minutes. The ticket is bound to the pairing connection's challenge (the hello nonce of spec 736 R2) that started the flow. The Mac and the Remote get it on the `agents://oidc` callback; the web page gets it in the redirect's fragment. The client sends it on its connection with `signIn/ticket`. Decided, because a ticket is useless to any other connection, and no ID token or access token ever leaves the control plane. |
| D4 | Where is the client secret kept? | **On the control plane, sealed with the keeper for secrets** (Cloud KMS, Vault or the local key file), bound to its store key, at `v1/signin/providers/<id>.secret.json`, as T6 D2 keeps org keys. Never shown again, also to admins; the Console shows who set it, when, and a fingerprint (the first 8 hex of SHA-256), as T6 D14. **Replace Secret** writes a new value. A control plane with no keeper refuses to save an org provider. Decided, because it is the one secret model that already exists, and it works with copies of the control plane. |
| D5 | How is a person matched to a sign-in? | **By the provider's own id for the person, never by email across providers** (spec 736 FR-001). The sign-in is `(provider id, account)`, where `account` is the claim the admin names: `sub` by default, `oid` for Entra (Entra's `sub` is different for each app). Decided, because an id that the provider keeps for life is the only safe key. |
| D6 | How does an org provider sit beside the built-in providers and the local owner? | **As one more sign-in provider in the same list.** It has its own row in `signIn/providers`, its own button ("Sign in with Acme Okta"), and its sign-ins are `SignIn` records like the others. A person can have an org sign-in and a Google sign-in. The local owner sign-in always stays, and nothing an org provider or SCIM does can take it away: it is how the key holder recovers the last admin (spec 736 Clarifications). Decided, because spec 736 made one identity model for this. |
| D7 | How many org providers? | **Up to five on one control plane.** Each has its own domains, its own SCIM tokens and its own groups. Decided, because organisations that merge often have two providers for a time, and a list costs no more than one item. |
| D8 | Domain claims | **An admin claims a domain for one org provider, and proves it with a DNS TXT record** `agents-domain=<token>` at `_agents.<domain>`. The control plane checks it when the admin selects **Check**, and again each day. A claim has two effects, each a switch: **Send people here** (the sign-in page asks for an email first, and sends an address at a claimed domain to this provider), and **Require this provider** (described in D9). Decided, because a claim changes how other people sign in, so it needs a proof, and DNS is the proof every identity product uses. The same record works when many organisations share one service (T10). |
| D9 | "Require this provider" | **A Google, Apple or GitHub sign-in whose email is at a required domain cannot join, cannot pair a client, and cannot renew a key.** The Console's preview lists the people and the sign-ins that it changes before the admin saves. Their clients keep working until their keys end (90 days at most, T4), so that nobody is cut off by surprise; each of them sees "Your organisation asks you to sign in with Acme Okta" with the button. The local owner sign-in is never refused. Decided, because "require" must close the old door, and a preview and a slow end keep it safe. |
| D10 | Who may join through an org provider? | **A switch per provider, with three values:** **Only people from SCIM** (the default when SCIM is on), **Anyone the provider signs in** (the provider's own assignment of the app is the gate), or **Only by invite** (the default when SCIM is off). Invites (spec 736 FR-006) work with every value. A person who joins this way is a `member`, unless a group gives them `admin` (D14). Decided, because each organisation already says in its provider who may use the app, and the control plane must not add a second list by default. |
| D11 | SCIM 2.0: which endpoints | **`/scim/v2/` on the control plane's HTTPS address**: `ServiceProviderConfig`, `ResourceTypes`, `Schemas`, `Users` (list with `filter` `eq` on `userName`, `externalId` and `emails.value`; get; create; replace; patch; delete) and `Groups` (list with `filter` `eq` on `displayName` and `externalId`; get; create; replace; patch members; delete). No `Bulk`, no `/Me`, no sort, no ETags, no password change. Decided, because that is the set that Okta and Entra use (research R4), and every other part of SCIM is optional. |
| D12 | SCIM auth | **A bearer token that an admin makes in Console ▸ Sign-In, for one org provider.** It is shown once. The control plane keeps only its SHA-256. Up to two tokens are live for each provider, so an admin can rotate one without a gap. A token has no end date unless the admin sets one. The Console shows when each was last used. Decided, because Okta and Entra both send a static bearer token, and a hash cannot leak a token. |
| D13 | SCIM leavers | **`active: false` suspends the person; `DELETE` suspends the person and asks an admin to remove them.** Suspend means, within 5 seconds on every copy: every client of the person is cut off (closed with `suspended`), their keys stop renewing, their org sign-ins are refused, and each of their machines stops the person's running turns and pauses their workflows. Their machines, agents, conversations and branches are kept. Their started machines are stopped (not deleted), so they cost nothing. The full removal of spec 736 FR-029 (which deletes started machines) waits for an admin's confirmation in Console ▸ Requests, with its list of work that is not pushed. Decided, because a provider must be able to cut someone off at once, and only a person should decide to delete work. |
| D14 | SCIM groups and roles | **A SCIM group becomes a T1 group** (`source: scim`), whose members only the provider changes. An admin can give it what any group gets: workspace providers, bots, org routes (T6), and later policy layers (T5). An admin can also mark it **Gives the admin role**: its members are admins, and a person who leaves every such group becomes a member. The role of a person in such a group says **Set by Acme Okta**, and `people/setRole` refuses to change it. A change that would leave no admin is not made; the Console says why. Decided, because the issue asks that groups map to roles and shares, and T1 groups already own the shares. |
| D15 | Offline | **Sign-in needs the control plane and the provider; nothing else does.** With the provider down, new sign-ins say "Acme Okta cannot be reached" (`signInUnavailable`), paired clients keep working, and SCIM changes wait in the provider's own retry queue. A machine that is offline keeps working until it connects, then gets its user's state (suspended or not) before any workflow starts. Decided, because the local-first rule says that a paired client and a machine do not stop when a cloud service stops, and a suspension is applied as soon as anything can apply it. |
| D16 | Audit (T3) | **Every change to an org provider, a domain, a SCIM token, a group's role, and every SCIM write, is an audit entry.** A SCIM write's actor is `{scim: {provider, token}}`. Each sign-in with an org provider, each refusal by D9, and each suspension is an entry too. No secret, token or ID token is in an entry; a secret shows as "secret replaced" with its fingerprint. Decided, because an organisation's security team must see who changed identity, and the SCIM token is the actor when nobody clicked. |
| D17 | Where admins manage it | **Console ▸ Sign-In on the web page.** The Mac and the Remote show the providers read only, in Settings ▸ Control plane ▸ People, with **Edit in Console** for an admin, as T5 FR-021 and T6 FR-029 do. Decided, because Alex decided that the Console is web only (#1804, decision 1). |
| D18 | A control plane with no public HTTPS address | **Cannot turn on an org provider.** The Console says "An org provider needs this control plane's HTTPS address" and links to the how-to. Codes, the local owner and the built-in providers work as before. Decided, because the provider must be able to send the browser back to the control plane, and SCIM must be able to reach it. |

**Open question for the scrum master (Q1):** see Clarifications. The spec is written with the recommended answer.

## Words

- **Org provider**: an OIDC identity provider that an organisation runs and registers for this control plane: Okta, Entra, Google Workspace with its own client, or any other OIDC provider.
- **Built-in provider**: Google, Apple or GitHub through the app's own client ids (spec 736).
- **Sign-in ticket**: a value for one use, that the control plane gives to the client after the provider's callback. It pairs the connection that started the sign-in, and nothing else.
- **Claimed domain**: an email domain that an admin proved with DNS and gave to one org provider.
- **SCIM**: the System for Cross-domain Identity Management, version 2.0 (RFC 7643, RFC 7644). The provider uses it to add, change and take away people and groups.
- **SCIM token**: the bearer token that the provider sends with each SCIM request.
- **Provisioned person**: a person that SCIM made, who has not signed in yet.
- **Suspended**: a person whom the provider deactivated. They exist, own their machines and keep their work, but no client of theirs connects and nothing of theirs runs.
- **Set by Acme Okta**: the line on a role or a group that the provider controls (the provider's name in place of "Acme Okta").

## Clarifications

### Session 2026-10-21 (the 0.11 spec lane, decide and tell; Alex can overrule)

- Q: Does an org provider replace the built-in providers?
  → A: **No.** It sits beside them (D6). An admin can turn the built-in providers off, or require the org provider for the claimed domains (D9). The local owner stays always.
- Q: Does the web page still need a code for a person of an org provider?
  → A: **No.** It signs in directly (D2, D3): the browser goes to the provider and back, and becomes that person's client. People of the built-in providers still pair a browser by a code or by approval (#2097).
- Q: Is a SCIM user the same person as an OIDC sign-in?
  → A: **Yes, when the SCIM user's `externalId` equals the sign-in's `account` claim** (D5). The admin can pick `userName` in place of `externalId` for a provider that sends no `externalId` (research R5). The match is only inside one provider.
- Q: Can SCIM make a person whom the local owner already is?
  → A: **SCIM matches the local owner only if the local owner added that org sign-in to themself.** Suspending the local owner refuses their org sign-in and its clients; the local owner sign-in itself stays (D6).
- Q: Can SCIM make bots?
  → A: **No.** Bots are configured by admins (spec 736 FR-030). A SCIM group can hold only people.
- Q: Nested groups?
  → A: **No.** A SCIM group's members are users only. A member that is a group is refused with `400 invalidValue`. Okta and Entra push flat groups (research R4).
- Q (open, Q1 for the scrum master): **How does the control plane learn that a person left, when SCIM is off?**
  - **A (recommended, written in this spec):** **it keeps each person's refresh token, sealed, and uses it at each key renewal and once a day.** The provider's `invalid_grant` answer suspends the person (D13). With the provider down, a key still renews, but only for 7 days after the last good check; then it stops renewing until a check succeeds. The scope asks for `offline_access`.
  - **B:** it keeps no refresh token. It checks the ID token at sign-in only. Without SCIM, a leaver keeps their clients until their keys end (90 days at most) or an admin removes them.
  - Why it is not decided: A finds leavers without SCIM, but it keeps a long-lived credential of each person on the control plane. B keeps nothing, but a leaver can stay for up to 90 days. Both are reasonable; the choice changes what the control plane holds.

## What each client shows

- **Mac**: the Connect sheet and Settings ▸ You ▸ Account show **Sign in with Acme Okta** first; People shows **Managed by**, **Suspended by** and **Set by** lines, read only, with **Edit in Console** for an admin.
- **Remote (iPhone, iPad)**: the pairing screen and Account show the same button first; People shows the same lines, read only.
- **Web**: the page signs in directly with the org provider (no code, no approval); admins get Console ▸ Sign-In for providers, domains, SCIM and group roles.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - One person sees no change (Priority: P1)

Alex runs a control plane alone, with no org provider. Agents is updated to this version. Alex signs in as before. No sign-in screen shows a new button, and no person says **Set by** anything.

**Why this priority**: most people use Agents alone. The feature must cost them nothing.

**Independent Test**: update a scratch control plane with two clients and two machines, and no org provider. `signIn/providers` lists no `orgProviders`. `/scim/v2/Users` answers `401` to every request. Every sign-in that worked before still works.

**Acceptance Scenarios**:

1. **Given** no org provider, **When** any client opens its sign-in screen, **Then** it shows the same choices as before.
2. **Given** no org provider, **When** anything sends a request to `/scim/v2/` or `/v1/oidc/`, **Then** the control plane answers `404` for `/v1/oidc/` and `401` with a SCIM error for `/scim/v2/`, and writes nothing.

---

### User Story 2 - An admin adds Okta, and people sign in with it (Priority: P1)

Priya is an admin. In the Acme Okta admin console she registers a web app with the redirect URI that the Console shows. In Console ▸ Sign-In she selects **Add Provider ▸ Okta**, types the issuer `https://acme.okta.com`, the client id and the client secret, names it "Acme Okta", sets **Who may join** to **Anyone the provider signs in**, and selects **Check**. The Console says "Acme Okta answered. Sign in to try it.". Sam opens the web page of the control plane, selects **Sign in with Acme Okta**, signs in at Okta with multi-factor, and comes back signed in, with no code. Sam then signs in on the Remote with the same button. Both are Sam's clients.

**Why this priority**: this is the feature.

**Independent Test**: on a scratch control plane with a fake OIDC provider on loopback (research R7), add the provider, and sign in on each client kind by the wire. Each client is paired to one person. Send the ticket on a second connection: it is refused. Send the ID token to a second control plane: it pairs nothing. The store holds no readable client secret, and no ID token or access token.

**Acceptance Scenarios**:

1. **Given** an admin, **When** they save an org provider, **Then** the control plane reads its discovery document, checks that it offers the code flow with PKCE S256, keeps the secret sealed (D4), and the provider shows on every client's sign-in screen within 5 seconds.
2. **Given** a person on the web page, **When** they select the org provider's button, **Then** the browser goes to the provider with `state`, `nonce` and a PKCE challenge, comes back to `/v1/oidc/callback`, and the page is a client of that person with no code (D2, D3).
3. **Given** a person on the Mac or the Remote, **When** they select the button, **Then** the flow opens in `ASWebAuthenticationSession`, ends on `agents://oidc`, and the client sends the ticket with `signIn/ticket`. It is paired.
4. **Given** a callback, **When** the control plane checks it, **Then** it refuses a `state` that it did not make or that it already used, an ID token whose signature, `iss`, `aud`, `exp` or `nonce` does not match, and a ticket older than 2 minutes or bound to another challenge.
5. **Given** **Who may join** is **Only by invite**, **When** a person not known signs in, **Then** they are told "Ask an admin of this control plane for an invite" (`needsInvite`). With an invite, they join.
6. **Given** a person with a Google sign-in, **When** they add the org sign-in to themself from a client they have (`signIn/addToMe`, through the same flow), **Then** they stay one person with two sign-ins.
7. **Given** Entra, **When** the admin picks the Entra preset, **Then** the issuer is `https://login.microsoftonline.com/<tenant id>/v2.0` and the account claim is `oid` (D5).
8. **Given** Google Workspace with the organisation's own client, **When** the admin picks the Google Workspace preset, **Then** the issuer is `https://accounts.google.com`, and the provider also checks that the `hd` claim is one of the provider's claimed domains.

---

### User Story 3 - The organisation claims its domain and requires its provider (Priority: P1)

Priya claims `acme.com` for Acme Okta. The Console shows a TXT record. She adds it at her DNS host and selects **Check**: the domain says **Proved**. She turns on **Send people here** and **Require this provider**. The preview says "3 people sign in with Google at acme.com. They keep their clients until their keys end, and then must sign in with Acme Okta." She saves. Kim, who signs in with Google as `kim@acme.com`, sees "Your organisation asks you to sign in with Acme Okta" with the button. A new person who types `lee@acme.com` on the web page is sent to Okta.

**Why this priority**: an organisation that has its own provider must be able to close the other doors for its people.

**Independent Test**: with a fake DNS answer and a fake provider, claim a domain, prove it, and require it. A Google sign-in at that domain cannot join, pair or renew. A Google sign-in at another domain is not changed. The local owner signs in as before.

**Acceptance Scenarios**:

1. **Given** a domain that is not proved, **When** the admin turns on either switch, **Then** it is refused with "Prove acme.com first."
2. **Given** a proved domain, **When** the daily check does not find the record for 7 days in a row, **Then** the claim goes back to **Not proved**, its switches stop, and the admins get a notice.
3. **Given** **Require this provider**, **When** a built-in sign-in with an email at that domain tries to join, pair, or renew a key, **Then** it is refused with `orgSignInRequired` and the provider's name. Its clients that are paired keep working until their keys end.
4. **Given** **Send people here**, **When** a person types an email at that domain on any client's sign-in screen, **Then** the client starts that provider's flow, with the email as `login_hint`.
5. **Given** two providers, **When** an admin claims a domain that the other provider has, **Then** it is refused: one domain has one provider.

---

### User Story 4 - Okta adds and removes people by SCIM (Priority: P1)

Priya selects **Turn On SCIM** for Acme Okta. The Console shows the base URL and a new token, once. She pastes both in Okta and assigns the app to the group "Engineering". Okta pushes 40 people. They show in People as **Waiting for first sign-in**. Lee signs in for the first time and is matched to the person that SCIM made. Later, Okta deactivates Kim. Within 5 seconds Kim's Mac window, iPhone and browser are cut off, Kim's running agents stop, and Kim's workflows pause. People shows Kim as **Suspended by Acme Okta**. Console ▸ Requests asks an admin to remove Kim, and lists one started machine with a branch that is not pushed.

**Why this priority**: leavers are the reason a security team asks for SCIM.

**Independent Test**: drive the SCIM endpoints with the requests that Okta and Entra send (research R4), from a recorded set, on a scratch control plane with two copies. Each person and group in the provider is the same in People. A deactivation cuts off the person's clients on both copies within 5 seconds (SC-003). Nothing on the person's machines is deleted until an admin confirms.

**Acceptance Scenarios**:

1. **Given** a SCIM request with no token, a wrong token, a revoked token, or a token of another provider, **When** it arrives, **Then** it is refused with `401` and a SCIM error, and nothing is written.
2. **Given** `POST /Users`, **When** the user is new, **Then** the control plane makes a provisioned person, with the name, the emails (to show only), `userName`, `externalId` and `active`, and answers `201` with the resource. A second `POST` with the same `userName` answers `409 uniqueness`.
3. **Given** a provisioned person, **When** they sign in with the org provider and their `account` claim equals the match attribute (D5, R5), **Then** the sign-in is added to that person, and they join with no invite.
4. **Given** `PATCH` with `active: false`, or `DELETE`, **When** it arrives, **Then** the person is suspended (D13). A `DELETE` also adds a **Remove** request in Console ▸ Requests. Their clients are cut off within 5 seconds on every copy, with "Your organisation's sign-in turned your access off."
5. **Given** a suspended person, **When** `PATCH active: true` arrives, **Then** they are not suspended. Their workflows are not paused. Their clients pair again by sign-in; their stopped machines stay stopped until they start them.
6. **Given** a `PATCH` or `PUT` that changes the name or the emails, **When** it arrives, **Then** People shows the new values. The sign-in is not changed.
7. **Given** a request that the endpoint does not support (a sort, a filter other than `eq`, `Bulk`), **When** it arrives, **Then** it answers with the SCIM error that RFC 7644 gives (`400 invalidFilter`, `501`), not a 500.
8. **Given** `GET /Users` with `startIndex` and `count`, **When** it arrives, **Then** the control plane answers in pages of at most 100, with `totalResults`.

---

### User Story 5 - Provider groups give roles and shares (Priority: P2)

Okta pushes the groups "Platform" and "Agents Admins". In Console ▸ People and Groups, both show with **From Acme Okta**. Priya marks "Agents Admins" **Gives the admin role**, and gives the DigitalOcean workspace provider to "Platform". When Okta adds Raj to "Agents Admins", Raj becomes an admin, and his role says **Set by Acme Okta**. When Okta takes Raj out, he is a member again.

**Why this priority**: an organisation decides roles in its provider. A second list kept by hand drifts from it.

**Independent Test**: push groups and membership changes by SCIM. Each group is a T1 group with the same members. A person in a group with the admin role is an admin within 5 seconds; out of it, a member. A change that would leave no admin keeps the last admin and says why.

**Acceptance Scenarios**:

1. **Given** `POST /Groups` with members, **When** it arrives, **Then** a T1 group with `source: scim` is made, with those members. The Console does not let an admin change its members, and says **Set by Acme Okta**.
2. **Given** a group with **Gives the admin role**, **When** a member is added by `PATCH`, **Then** that person's role is `admin`. **When** the last group that gives them admin loses them, **Then** their role is `member`.
3. **Given** a person whose role comes from a group, **When** an admin calls `people/setRole` for them, **Then** it is refused with `managedByProvider`.
4. **Given** a SCIM change that would leave the control plane with no admin, **When** it arrives, **Then** the group changes, the role of the last admin does not, and admins get a notice "Acme Okta took the last admin out of Agents Admins. Raj stays an admin until another admin is set.". The SCIM answer is still a success, so the provider does not retry for ever.
5. **Given** a SCIM group that owns a workspace provider, a bot or an org route, **When** the provider deletes the group, **Then** the group is kept as a tombstone with its shares, and the Console asks an admin to give those shares to another group.

---

### User Story 6 - A leaver is found without SCIM (Priority: P2)

(Q1 answer A.) Acme uses Okta without SCIM. Okta deactivates Kim. The next time one of Kim's clients renews its key, and at the daily check, the control plane uses Kim's refresh token. Okta answers `invalid_grant`. Kim is suspended, as in US4.

**Why this priority**: some organisations do not turn on SCIM. A leaver must still be found.

**Independent Test**: with a fake provider, sign a person in, then make the provider refuse their refresh token. Within one daily check, or at the next renewal, the person is suspended. Stop the fake provider: renewals go on for 7 days after the last good check, then stop.

**Acceptance Scenarios**:

1. **Given** an org sign-in, **When** it is made, **Then** the control plane keeps its refresh token sealed (D4), bound to the person and the provider, and never sends it to a client or a machine.
2. **Given** `invalid_grant` on a refresh, **When** the control plane gets it, **Then** it suspends the person (D13).
3. **Given** the provider cannot be reached, **When** a key renews, **Then** it renews only if the last good check was within 7 days.

---

### User Story 7 - Each client shows the org provider (Priority: P2)

On the Mac, the Connect sheet shows **Sign in with Acme Okta** first. On the Remote, the pairing screen shows it first. On the web page, the sign-in shows it first, with **Use an email** when domains are claimed. In Settings ▸ Control plane ▸ People, each client shows **Managed by Acme Okta** under the people that SCIM made, and **Set by Acme Okta** on their roles. An admin has **Edit in Console**.

**Why this priority**: three clients draw one product (AGENTS.md).

**Independent Test**: with a fake provider, draw the sign-in screen and People on each client (`run-app`, the walk simulator, headless Chrome). Each shows the button and the lines above.

**Acceptance Scenarios**:

1. **Given** an org provider, **When** any client draws its sign-in screen, **Then** the org providers come first, in the order the admin set, then the built-in providers, then **Use a Code Instead…**.
2. **Given** a suspended person, **When** any of their clients connects, **Then** it shows "Your organisation's sign-in turned your access off." and no other page.
3. **Given** a member, **When** they open People, **Then** they see their own row, with **Managed by Acme Okta** when that is true.

---

### Edge Cases

- **The provider rotates its signing keys**: the control plane gets the new JWKS (the existing `signin/oidc.go` refetch on an unknown `kid`), and keeps working with no restart.
- **The issuer's discovery document changes its endpoints**: the control plane reads it again each hour, and at **Check**.
- **Clock skew**: ID tokens are checked with 5 minutes of tolerance, as spec 736 says.
- **Two copies of the control plane**: the flow's `state` and the ticket are records in the store (`v1/oidc/…`), so a callback can come to another copy than the one that started it.
- **A person signs in at the provider but closes the window**: the `state` ends after 10 minutes, and is swept.
- **A provider that sends no `email`**: the person shows by name. **Send people here** and **Require this provider** do not apply to sign-ins that have no email.
- **A built-in Google sign-in at a claimed domain, when the org provider is Google Workspace with its own client**: they are two providers. **Require this provider** moves those people to the org client. The built-in Google provider's allowed domains (spec 736 FR-006) that equal a claimed domain are turned off, and the Console says so.
- **Apple's hidden relay address**: it is not at the organisation's domain, so D9 does not apply. The docs say so.
- **A SCIM `userName` changes** (a person changes their name in Okta): the person is the same; the match is by `externalId` (or the old `userName` at the time it last matched, kept on the person).
- **A SCIM `POST` for a user who signed in first with the org provider** (Anyone the provider signs in): the control plane matches by the attribute, links the SCIM data to the person who is already there, and answers `201`.
- **A SCIM token is used from a new address**: nothing changes. The Console shows the address of the last use, so an admin can see a leak.
- **A suspended person is the owner of a bot's group**: bots do not belong to people. Nothing changes for bots.
- **A suspended person's machine is offline**: it keeps running until it connects (hosts never escalate; the control plane cannot reach it). When it connects, it gets the suspended state before anything else, and stops the person's turns. The docs say this plainly.
- **The Mac's own window and its machine (#1118)**: when the machine learns that its user is suspended, it refuses the window's direct path too.
- **A person of the org provider is removed by an admin in the Console, and SCIM still lists them**: the removal stands (spec 736 FR-029). A later SCIM `PATCH` for that id answers `404`, so the provider shows the error in its own logs.
- **The keeper for secrets cannot be reached**: an org provider's secret cannot be opened, so new sign-ins with it say "This control plane cannot open its secrets." Paired clients keep working.
- **The control plane's HTTPS address changes**: the redirect URI changes. The Console shows the new URI on each provider with "Update this in Acme Okta".
- **A large organisation**: SCIM pushes 5,000 users and 500 groups in its first sync. The control plane answers each request in under 200 ms at the 95th percentile, and People pages the list.

## Requirements *(mandatory)*

### Functional Requirements

**Org providers (slice 1)**

- **FR-001**: The control plane MUST keep each org provider as a plain record `v1/signin/providers/<id>.json` (no secret: name, issuer, client id, account claim, scopes, who may join, order, presets, `version`, who and when) and its secret as an envelope `v1/signin/providers/<id>.secret.json`, sealed with the keeper for secrets and bound to its store key (D4). Fields: `data-model.md`.
- **FR-002**: A control plane with no keeper for secrets, or with no HTTPS address, MUST refuse to save an org provider, with the reason (D4, D18).
- **FR-003**: Only an admin MUST be able to add, change, check, replace the secret of, reorder and remove an org provider (`signIn/orgProviders/*`). The secret MUST never be returned by any method, to anyone. `signIn/providers` MUST list each org provider's id, name and order for every client, and nothing more.
- **FR-004**: Saving or **Check** MUST read the issuer's discovery document, check that it has an authorization endpoint, a token endpoint, a JWKS URI and the code flow with PKCE S256, and say what is missing. **Check** MUST also get the JWKS, and say how many keys it has.
- **FR-005**: The control plane MUST serve `GET /v1/oidc/start` (with the provider, the purpose `pair` or `addToMe`, the client kind `app` or `web`, and the client's challenge) and `GET /v1/oidc/callback` on its HTTPS address. Start MUST keep a `state` record (10 minutes, one use) with the PKCE verifier and the nonce, and send the browser to the provider. Callback MUST exchange the code with the client secret, check the ID token (signature by JWKS, `iss`, `aud`, `exp`, `nonce`, and `hd` for the Google Workspace preset), and make a ticket (D3).
- **FR-006**: `signIn/ticket` MUST pair the connection that holds the ticket's challenge, as `signIn/pair` does today, or add the sign-in to the caller's person for `addToMe`. A ticket MUST be used once, within 2 minutes, by that connection only.
- **FR-007**: No ID token, access token or refresh token MUST leave the control plane, or be written to the store or a log in the clear. (Q1 A: the refresh token is kept sealed, FR-024.)
- **FR-008**: The org sign-in MUST be the `SignIn` `{provider: <org provider id>, account: <the account claim>, email?}` of spec 736. A person not known MUST join only by the provider's **Who may join** (D10) or an invite.
- **FR-009**: Turning an org provider off MUST refuse its new sign-ins. Removing it MUST also mark its sign-ins as gone; a person with no other sign-in keeps their clients until their keys end, and is told to ask an admin.

**Domains (slice 1)**

- **FR-010**: An admin MUST be able to claim a domain for one org provider, see its TXT record, **Check** it, and remove it. A domain MUST belong to one provider at most. The control plane MUST check each proved domain once a day, and drop a claim that fails for 7 days, with a notice to admins.
- **FR-011**: **Send people here** MUST make `signIn/discover {email}` answer with that provider for an email at the domain, on every client.
- **FR-012**: **Require this provider** MUST refuse a built-in sign-in with an email at the domain for join, pair and key renewal, with `orgSignInRequired`. It MUST never refuse the local owner sign-in. The Console MUST show a preview of the people and sign-ins it changes before it is saved.

**SCIM (slice 2)**

- **FR-013**: The control plane MUST serve SCIM 2.0 at `/scim/v2/` on its HTTPS address, with the endpoints of D11, the core User schema and the core Group schema, and keep the Enterprise User extension's fields as it gets them, without reading them.
- **FR-014**: Each request MUST carry a bearer token whose SHA-256 matches a live token of one org provider (D12). The token MUST decide the provider. Up to two tokens per provider MUST be live. An admin MUST be able to make, name, see the last use of, and revoke each token. A token value MUST be shown once only.
- **FR-015**: `Users` MUST map to people: the SCIM `id` is the person's id; `userName`, `externalId`, `name`, `displayName`, `emails` and `active` are kept on the person's `scim` part. A user that SCIM makes MUST be a provisioned person until their first sign-in.
- **FR-016**: The control plane MUST match a provisioned person to an org sign-in of the same provider by the provider's match attribute (`externalId` by default, or `userName`) equal to the sign-in's `account` claim (D5, R5), and in no other way.
- **FR-017**: `active: false` and `DELETE` MUST suspend the person (D13) within 5 seconds on every copy: cut off their clients, stop their key renewals, refuse their org sign-ins, and tell each of their machines `user/suspended`. `DELETE` MUST also add a **Remove** request in Console ▸ Requests, which runs spec 736 FR-029 only after an admin confirms.
- **FR-018**: A machine that gets `user/suspended` MUST stop the user's running turns, pause their workflows and queued prompts, refuse new work and the direct path (#1118), and keep every agent, conversation and file. Started machines MUST be stopped through their provider, not deleted. `user/suspended {off: true}` MUST undo the pause.
- **FR-019**: `Groups` MUST map to T1 groups with `source: {scim: <provider>, externalId, displayName}`. Only SCIM MUST change their members. Members MUST be users of the same provider; any other member MUST be refused with `400 invalidValue`.
- **FR-020**: An admin MUST be able to mark a SCIM group **Gives the admin role**. A person's role MUST be `admin` while they are in such a group, and `member` when they are in none, unless an admin set it by hand before SCIM managed it. `people/setRole` MUST refuse with `managedByProvider` for a person whose role a group gives.
- **FR-021**: No SCIM change MUST leave the control plane with no admin. The change to the group MUST be made; the role change that would leave no admin MUST NOT be, and admins MUST get a notice.
- **FR-022**: SCIM errors MUST use the RFC 7644 error schema and status codes, and unsupported features MUST be listed as not supported in `ServiceProviderConfig`.
- **FR-023**: The SCIM endpoints MUST answer within 200 ms at the 95th percentile for 5,000 users and 500 groups, and list in pages of at most 100.

**Leavers without SCIM (slice 2, Q1 answer A)**

- **FR-024**: With `offline_access` granted, the control plane MUST keep each org sign-in's refresh token sealed at `v1/signin/refresh/<person>/<provider>.json`, use it at each key renewal of that person's clients and once a day, suspend the person on `invalid_grant`, and let keys renew for at most 7 days after the last good check while the provider cannot be reached.

**Audit (with slices 1 and 2)**

- **FR-025**: The control plane MUST write an audit entry (T3) for: each change to an org provider (fields changed; a secret as "secret replaced" with its fingerprint), each domain claim, proof, failure and removal, each SCIM token made or revoked, each group's role mark, each SCIM write (actor `{scim: {provider, token}}`, the resource, and the fields changed), each org sign-in (join, pair, add), each refusal by FR-012, and each suspension and its end. No entry MUST hold a secret, a token or an ID token.

**Clients (slice 3)**

- **FR-026**: The Mac, the Remote and the web page MUST show each org provider on their sign-in screens first, by its name, then the built-in providers, then the code. With claimed domains that send people, they MUST offer **Use an Email** and start the provider that `signIn/discover` names.
- **FR-027**: The Mac and the Remote MUST run the org flow in `ASWebAuthenticationSession` with the `agents` callback scheme. The web page MUST run it in the same tab, and keep no token.
- **FR-028**: All three clients MUST show, in People: **Managed by <provider>** for a person from SCIM, **Waiting for first sign-in** for a provisioned person, **Suspended by <provider>** for a suspended person, **Set by <provider>** on a role or a group that the provider controls, and **Edit in Console** for an admin.
- **FR-029**: A client of a suspended person MUST show "Your organisation's sign-in turned your access off." and no other page. A client refused by FR-012 MUST show "Your organisation asks you to sign in with <provider>" with the button.

**Admin, web Console (slice 4)**

- **FR-030**: The web page MUST have Console ▸ Sign-In, for admins: the built-in providers (as `signIn/configure` today), the org providers (**Add Provider** with presets Okta, Entra, Google Workspace and Other OIDC; the redirect URI to copy; **Check**; **Replace Secret**; **Who may join**; order; **Remove**), each provider's domains (the TXT record, **Check**, the two switches, the preview of FR-012), and SCIM (**Turn On SCIM**, the base URL, tokens, last use, **Revoke**, the match attribute).
- **FR-031**: Console ▸ People and Groups MUST show SCIM groups with **From <provider>**, and the **Gives the admin role** mark. Console ▸ Requests MUST gain the kind **Remove** for a SCIM `DELETE`.

### Key Entities

- **OrgProvider**: id, name, issuer, client id, account claim (`sub`, `oid`, or another claim), scopes, preset (`okta`, `entra`, `googleWorkspace`, `oidc`), who may join (`scim`, `anyone`, `invite`), order, on, `version`, created and changed by and when, the secret's fingerprint, SCIM on and its match attribute.
- **OrgProviderSecret**: the client secret, sealed with the keeper, bound to its store key.
- **OIDCState**: a started flow: provider, purpose, challenge, PKCE verifier, nonce, `login_hint`, made, ends (10 minutes), used.
- **SignInTicket**: provider, account, email, name, challenge, purpose, made, ends (2 minutes), used.
- **DomainClaim**: domain, provider, TXT token, state (`notProved`, `proved`), last good check, the two switches.
- **SCIMToken**: id, provider, name, SHA-256 of the value, made by and when, ends (optional), last use (time and address), revoked.
- **Person** (spec 736, extended): a `scim` part (`provider`, `externalId`, `userName`, `name`, `emails`, `active`, `extra`), a `suspended` part (by, at, why), and `roleFrom` (the groups that give the role).
- **Group** (spec 736, extended): `source` (`scim`, provider, externalId, displayName) and `role` (`admin` or absent).
- **RefreshToken** (Q1 A): a person's refresh token for one provider, sealed; the last good check.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A control plane with no org provider shows no change on any client, and every sign-in path of spec 736 passes its tests unchanged.
- **SC-002**: A person signs in with an org provider on the web page in under 30 seconds of their own time, with no code and no approval, after the admin's provider is saved.
- **SC-003**: A SCIM deactivation cuts off every client of the person within 5 seconds, on every copy of the control plane, in 100% of tests with two copies and three clients.
- **SC-004**: A ticket, a `state`, an ID token or a SCIM token used where it was not made (another connection, another control plane, another provider) pairs nothing and writes nothing, in 100% of tests.
- **SC-005**: In a test that searches for the client secret's bytes (and its base64 and hex), each test token and each refresh token, after a full sign-in and SCIM run, they are found in no store file in the clear, no log, no audit entry and no client message: 0 finds.
- **SC-006**: The SCIM endpoints pass the recorded request sets of Okta and Entra (research R4) with no failed request, and answer within 200 ms at the 95th percentile for 5,000 users and 500 groups.
- **SC-007**: The Okta, Entra and Google Workspace presets each pass a walk on a real tenant in Alex's account test (not a gate, #1782).

## Docs

- `docs/explanation/org-identity.md`: add. Org providers beside the built-in ones and the local owner, tickets, domain claims, SCIM, suspension, what offline does, and what this does not protect against (an offline machine runs until it connects).
- `docs/how-to/sign-in-with-your-organisation.md`: add. Console ▸ Sign-In for each preset, with the provider's own steps (an Okta app integration, an Entra app registration and enterprise app, a Google Cloud OAuth client), the redirect URI, domains, and SCIM.
- `docs/how-to/sign-in-with-google-apple-or-github.md`: change. Org providers come first when they are there; **Require this provider**.
- `docs/how-to/use-agents-in-a-browser.md`: change. Direct sign-in with an org provider.
- `docs/how-to/invite-someone.md`: change. **Who may join**, and SCIM in place of invites.
- `docs/reference/sign-in.md`: add or change. The org provider's fields, `/v1/oidc/*`, `/scim/v2/*` and what it supports.
- `docs/reference/integrations.md`: change. Rows for Okta, Entra, Google Workspace (org client) and generic OIDC, and SCIM for Okta and Entra, with #1002.
- `specs/071-web-remote/walks/parity/`: change. Rows for FR-026 to FR-029.

## Assumptions

- **T1 to T4 are in code** (spec 736). T9 adds fields to people and groups, and does not move a record.
- **The control plane has an HTTPS address** for an org provider (D18). On a Mac with no public address, the organisation runs the control plane in the cloud (`deploy/`).
- **Sizes**: up to 5 org providers, 20 domains, 5,000 people and 500 groups per control plane for SCIM. Spec 736's sizing (about 20 active people) is for machines and sessions; a provider can provision many more people than sign in.
- **SAML is not in this spec.** Okta, Entra and Google Workspace all offer OIDC. A later spec can add SAML if an organisation asks.
- **Not in this spec**: SCIM for bots; nested groups; SCIM `Bulk`; a provider's own device-trust signals beyond what the provider enforces at sign-in; group-layer policy (T5 later); many organisations on one service (T10), for which the store shape and the DNS proof are ready.
