# Feature Specification: Hosted T10, many organisations on one service

**Feature Branch**: `agents/hosted-spec-1003` (spec only)

**Created**: 2026-10-22

**Status**: Draft. Nothing here is built yet, except what #1807 made.

**Milestone**: 0.12 Hosted. Nothing for 0.12 merges to `main` before v0.11.0 ships (`hold:v0.11`).

**Input**: Issue #2223, roadmap step T10 in `specs/research/733-team-and-enterprise.md` (#1003). It builds on the hosted service that #1807 (PR #1827) made: `Go/internal/hosted`, `Go/cmd/agents-hosted`, `deploy/compose.hosted.yaml`, `deploy/Caddyfile.hosted` and `docs/how-to/run-the-hosted-service.md`. The issues it covers: #2152 (sign-up protection), #2224 (plans and limits), #2225 (billing), #2226 (operations). Alex's steps are on #2227.

## Why this feature exists

**Today the hosted service is open to anyone with a GitHub account.**

- A person signs in with GitHub and gets an account and a control plane of their own (`pages.go`, `accounts.go`).
- Nothing limits how many accounts are made, how fast, or by whom.
- Each account gets its own copy of the control plane in the process, its own store prefix, and its own certificate from Let's Encrypt.
- So one script with many GitHub accounts can use all the memory, the disk and the Let's Encrypt limits. No script deploys the service yet, so nothing live is at risk.

**This feature makes the service safe to open, and worth paying for.**

- **Sign-up is by invitation at the start.** Other people go on a waitlist.
- **Rates, caps and limits** keep one account, or many, from using up the machine.
- **Each account has a plan:** Free, with small limits, or Pro, bought through Stripe Checkout.
- **An operator can run it:** a deploy script, backups, metrics, an admin command and a runbook.
- **Each client says what is wrong** when an account is on the waitlist, suspended or at a limit.

**Each account stays one organisation.** An account's control plane is the single-organisation control plane, unchanged. "Organisation" and "account" are the same thing in this spec.

## Decisions

| Question | Answer | Who, when |
|---|---|---|
| Who can sign up | **Invite only at the start**, with a waitlist and an allowlist. Open sign-up is a setting for later. | Decided on #2223, 2026-10-22 |
| Plans and billing | **One Free plan with limits, one paid plan (Pro) through Stripe Checkout.** Billing is off when no Stripe key is set, and every account is then on Free. | Decided on #2223, 2026-10-22 |
| How an invitation works | **Two ways:** an operator allows a GitHub login (the allowlist), or makes a one-use invite link. Both are admin commands. | Decided 2026-10-22, see Clarifications |
| Minimum GitHub account age | **30 days**, also for an invited person. An invite link does not skip it; an allowlist entry does. | Decided 2026-10-22 |
| A CAPTCHA (Turnstile) | **Not in 0.12.** Sign-up is invite only, so the rates, the age rule and the cap are enough. The open sign-up setting adds Turnstile when it is built. | Decided 2026-10-22 |
| Where limits are enforced | **In `agents-hosted`**, around each account's control plane: in its store, in the proxy, and in a sweep. The control plane is not changed in 0.12, because 0.11 holds its area. | Decided 2026-10-22 |
| Agents running at the same time | **Recorded in the plan, not enforced in 0.12.** Only the control plane knows which agents run. A later slice adds the hook, after v0.11.0 ships. | Decided 2026-10-22 |
| Workspace providers on a hosted account | **Off.** A provider runs commands and holds cloud keys on the service's machine. Machines join by code or join command. | Decided 2026-10-22 |
| At a limit | **Refuse the new thing, keep everything there.** Nothing is deleted at a limit or at a downgrade, except events older than the plan keeps. | Decided 2026-10-22 |
| Many certificates | **A cap below Let's Encrypt's limits**, and a wildcard certificate later (Alex's DNS token, #2227) when the cap is too small. | Decided 2026-10-22 |
| The admin tool | **A command, `agents-hosted admin …`, on the service's machine**, against the same store. No admin web page in 0.12. | Decided 2026-10-22 |

## Words

- **Account**: one sign-up. It has an id (ten letters and digits), a GitHub user, a plan and a state. It is one organisation.
- **Operator**: whoever runs the service. Alex, at the start.
- **Allowlist**: the GitHub logins that may sign up now.
- **Invite link**: `https://<domain>/?invite=<code>`. One person signs up with it, once, within 14 days.
- **Waitlist**: the GitHub users who signed in and could not sign up yet, in the order they came.
- **Admit**: move a person from the waitlist to the allowlist.
- **Suspended**: an account whose control plane is stopped and answers nothing but a refusal. Its records are kept.
- **Blocked**: a GitHub user id that may not sign up or join the waitlist.
- **Plan**: Free or Pro. A plan is a set of limits.
- **Limit**: a number in a plan: machines, clients, connections, storage, events kept, agents running.
- **Copy**: an account's control plane, running in `agents-hosted`. It stops after 15 minutes with no request (`copies.go`).

## Clarifications

### Session 2026-10-22 (the 0.12 spec lane, decide and tell; Alex can overrule)

- Q: Allowlist or invite links?
  → A: **Both.** An allowlist entry is for a person the operator knows by GitHub login. An invite link is for a person whose login the operator does not know. Each is one admin command. The allowlist is checked by login at sign-in, and the account then keeps the numeric GitHub id, which never changes.
- Q: What does a person on the waitlist see?
  → A: A page that says they are on the waitlist, their place in it, and that an email is not sent: they come back and sign in again. Agents keeps no email address.
- Q: What does the cap on accounts do with the allowlist?
  → A: The cap holds for everyone. A person on the allowlist, when the cap is full, goes on the waitlist at the front. The operator raises the cap with a setting.
- Q: What are the rates?
  → A: **3 sign-ups an hour from one address, and 30 an hour in total.** A sign-up here is a new account or a new waitlist entry. A sign-in to an account that is there is never limited. Over a rate, the page says "Too many sign-ups just now. Try again in an hour." The rates are kept in memory: the service is one process.
- Q: How many copies may run at once?
  → A: **50 by default** (a setting). At the limit, the service stops the copy that has been idle longest. When no copy is idle, the request gets "The service is full just now. Try again in a few minutes." Each account's own store is limited by its plan.
- Q: How many new certificates?
  → A: **10 an hour and 40 a week** (settings), below Let's Encrypt's 50 certificates a week for one registered domain. A certificate is new the first time its name is asked for. The account keeps the time its certificate was first allowed, so a restart does not count it again, and a renewal is not new. At the cap, `/v1/tls-allowed` says no, and the account page says "Your control plane's address is not ready yet. Try again in an hour."
- Q: What does a suspended account see?
  → A: The account page says "This account is suspended" and the reason the operator gave. Sign-in still works, so the person can read it and delete the account. The control plane's address answers `403` with the header `Agents-Refusal: suspended` and the line "This hosted account is suspended. See https://<domain>/account." The copy is stopped within a minute of the admin command.
- Q: What do the Mac and the Remote show?
  → A: **Suspended:** the error line the address answers, as they show any refusal when they connect. **Waitlist:** nothing: a person on the waitlist has no control plane, so the Mac and the Remote never meet one (by design). **At a limit:** the refusal's words, as an error line.
- Q: What are the plans?
  → A: See the table under FR-020. Free is enough for one person with two machines. Pro is for a small team.
- Q: How is a plan bought and ended?
  → A: **Upgrade** on the account page opens Stripe Checkout for Pro. **Manage Billing** opens Stripe's customer portal, where the person changes the card or ends the plan. A signed webhook sets the account's plan. When a payment fails past Stripe's retries, or the plan ends, the account goes back to Free. Nothing is deleted.
- Q: An account over a limit after a downgrade?
  → A: It keeps everything. New machines, clients and records over the limit are refused until it is under. Events older than Free keeps are deleted by the sweep, as on any Free account.
- Q: What stays apart for each account?
  → A: The control key (done, #1807), the policy (T5, #998: `v1/policy.json` is in the account's own prefix), every record, and the secrets (sealed with the keeper in the account's own prefix). Workspace providers are off. A test shows two accounts' policies and records apart.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - An invited person signs up (Priority: P1)

Sam gets an invite link from Alex. Sam opens it, selects **Sign Up with GitHub**, and is back on Sam's own control plane in the browser, paired, as today.

**Why this priority**: invitations are how the beta starts.

**Independent Test**: on a test service with a fake GitHub, make an invite with the admin command, sign up with it, and see the account made and the browser sent to its control plane.

**Acceptance Scenarios**:

1. **Given** an invite link, **When** a GitHub user older than 30 days signs up with it, **Then** the account is made and the invite is used.
2. **Given** a used or expired invite, **When** someone opens it, **Then** the page says the invite is used or expired, and they can join the waitlist.
3. **Given** a GitHub login on the allowlist, **When** that user signs in, **Then** the account is made, whatever the account's age.

---

### User Story 2 - A stranger goes on the waitlist (Priority: P1)

Priya hears about Agents and signs in with GitHub without an invite. The page says she is on the waitlist, number 12. Later, Alex admits her. She signs in again and gets her account.

**Independent Test**: sign in without an invite: a waitlist entry, no account. Admit the login: the next sign-in makes the account.

**Acceptance Scenarios**:

1. **Given** no invite and no allowlist entry, **When** a person signs in, **Then** they go on the waitlist once, and the page shows their place.
2. **Given** the cap on accounts is full, **When** an invited or allowed person signs in, **Then** they go on the waitlist, and the invite is not used.
3. **Given** a GitHub account younger than 30 days, **When** it signs in with an invite, **Then** it goes on the waitlist, and the page says why.
4. **Given** a blocked GitHub id, **When** it signs in, **Then** the page says sign-up is not open to it, and nothing is kept.

---

### User Story 3 - A script cannot use up the service (Priority: P1)

A script signs in with 200 GitHub accounts from 20 addresses in an hour.

**Independent Test**: make sign-ups from one address and from many, with a fake clock, and count what is made.

**Acceptance Scenarios**:

1. **Given** 3 sign-ups from one address in an hour, **When** a 4th comes, **Then** it is refused with "Too many sign-ups just now."
2. **Given** 30 sign-ups in total in an hour, **When** a 31st comes from a new address, **Then** it is refused.
3. **Given** 50 copies running, **When** a 51st account is asked for, **Then** the idle copy that waited longest is stopped, or the request is refused when none is idle.
4. **Given** 10 new certificates this hour, **When** an 11th name is asked for, **Then** `/v1/tls-allowed` says no.

---

### User Story 4 - The operator suspends an account (Priority: P1)

Alex sees that one account sends spam through its agents. Alex runs `agents-hosted admin suspend k3v9x0qa7b "Spam"` and `agents-hosted admin block 123456`.

**Independent Test**: suspend an account with the command while its copy runs; within a minute the copy stops, the address answers `403 suspended`, and the account page says so. Block the GitHub id: a new sign-in with it is refused.

**Acceptance Scenarios**:

1. **Given** a running account, **When** the operator suspends it, **Then** its copy stops within one minute, and every request to its address gets `403` with `Agents-Refusal: suspended`.
2. **Given** a suspended account, **When** its person signs in, **Then** the account page says it is suspended and why, and offers only **Delete Account** and **Sign Out**.
3. **Given** a suspended account, **When** the operator runs `unsuspend`, **Then** the next request starts its copy as before.
4. **Given** a blocked id, **When** it signs in, **Then** no account and no waitlist entry is made.

---

### User Story 5 - A plan's limits hold, with words that say so (Priority: P1)

Sam is on Free, which allows 2 machines. Sam joins a third. The join is refused, and the Mac says "Your Free plan allows 2 machines. Remove one, or upgrade at https://agentloops.dev/account."

**Independent Test**: an account on Free; join machines and clients, write records, open sockets up to each limit and one over. Each one over is refused with words that name the limit and the plan. Nothing is deleted.

**Acceptance Scenarios**:

1. **Given** an account at its machines limit, **When** a new machine joins, **Then** the join is refused with the words.
2. **Given** an account at its clients limit, **When** a new client pairs, **Then** pairing is refused with the words.
3. **Given** an account at its storage limit, **When** its control plane writes more, **Then** the write is refused with the words. A write that makes nothing larger (a rewrite of the same size or smaller, a delete) is never refused.
4. **Given** an account at its connections limit, **When** another socket opens, **Then** it gets `429` with the words.
5. **Given** events older than the plan keeps, **When** the sweep runs (each hour), **Then** they are deleted.
6. **Given** two accounts, **When** each sets a policy and joins machines, **Then** neither can read or change the other's.

---

### User Story 6 - Sam buys Pro (Priority: P2)

Sam selects **Upgrade** on the account page, pays in Stripe Checkout, and is back on the account page, on Pro, with the Pro limits.

**Independent Test**: with a fake Stripe, select Upgrade, follow the fake checkout, send a signed `checkout.session.completed` webhook: the plan is Pro. Send `customer.subscription.deleted`: the plan is Free, and nothing is deleted. Without a Stripe key, the page shows no **Upgrade**.

**Acceptance Scenarios**:

1. **Given** no Stripe key, **When** any account opens the account page, **Then** it shows the Free plan and its use, and no **Upgrade** or **Manage Billing**.
2. **Given** a Stripe key, **When** Sam selects **Upgrade**, **Then** the service makes a Checkout session for Pro with the account's id, and sends the browser to it.
3. **Given** a webhook with a bad signature, **When** it comes, **Then** it is refused and nothing changes.
4. **Given** the subscription ends or its payment fails for good, **When** the webhook comes, **Then** the account is on Free, and nothing is deleted.
5. **Given** Pro, **When** Sam selects **Manage Billing**, **Then** the browser goes to Stripe's customer portal for Sam's customer.

---

### User Story 7 - Alex deploys and runs it (Priority: P2)

Alex runs `deploy/gcp/hosted-up.sh` with a project, a zone, the names and the secrets, and the service is up. Each night the disk is backed up. When something breaks, the runbook says what to do.

**Independent Test**: `hosted-up.sh` with nothing set says each missing name and exits with no change. With a fake `gcloud` on the path, it runs the expected commands. `agents-hosted admin restore` puts one account back from a backup on a scratch store.

**Acceptance Scenarios**:

1. **Given** a missing name or secret, **When** `hosted-up.sh` runs, **Then** it says which, and makes nothing.
2. **Given** a running service, **When** Prometheus reads `/metrics` from inside the machine, **Then** it gets accounts, waitlist, copies running, sign-ups, refusals by kind, and certificates allowed.
3. **Given** a backup, **When** the operator restores one account, **Then** only that account's prefix changes.

---

### Edge Cases

- **The same GitHub user on two tabs signs up at once:** one account (the link is written only if absent, as today); one waitlist entry.
- **An invite used by two people at once:** the invite is spent with a conditional write; the second goes on the waitlist.
- **A GitHub login renamed:** the allowlist is by login at the time of sign-in. The account keeps the numeric id, so a rename later does not matter.
- **The operator lowers the cap below the number of accounts:** no account is touched; new sign-ups go on the waitlist.
- **A suspended account's certificate:** `/v1/tls-allowed` still says yes, so the refusal is served over TLS.
- **A copy that writes over the storage limit mid-handover:** the write is refused; the copy keeps running and reports the store error, as for any store error.
- **A Stripe event for an account that is deleted:** ignored, and logged.
- **The service restarts:** rates in memory start again. The cap, the waitlist, suspensions, certificates and plans are in the store.

## Requirements *(mandatory)*

### Functional Requirements: sign-up (#2152)

- **FR-001**: `AGENTS_HOSTED_SIGNUP` says who may sign up: `invite` (the default), `open` or `closed`. `closed` makes no account and no waitlist entry. `open` lets any GitHub user who passes FR-004 and FR-005 sign up; it is for later and the docs say so.
- **FR-002**: With `invite`, a person may make an account when their login is on the allowlist, or they came with an unused invite that is not expired. Everyone else goes on the waitlist.
- **FR-003**: The cap on accounts, `AGENTS_HOSTED_MAX_ACCOUNTS` (default 100), holds for every mode. At the cap, a person who may sign up goes on the waitlist, at the front.
- **FR-004**: A GitHub user whose account is younger than `AGENTS_HOSTED_MIN_GITHUB_AGE` (default 30 days, from `created_at` on `/user`) goes on the waitlist, unless their login is on the allowlist.
- **FR-005**: A blocked GitHub id makes no account and no waitlist entry.
- **FR-006**: New accounts and waitlist entries are limited to 3 an hour from one address and 30 an hour in total (`AGENTS_HOSTED_SIGNUPS_PER_ADDRESS`, `AGENTS_HOSTED_SIGNUPS_PER_HOUR`). A sign-in to an existing account or waitlist entry is not counted.
- **FR-007**: At most `AGENTS_HOSTED_MAX_COPIES` (default 50) copies run at once. At the limit, the copy idle longest stops; with none idle, the request gets `503` and "The service is full just now. Try again in a few minutes."
- **FR-008**: `/v1/tls-allowed` allows at most `AGENTS_HOSTED_CERTS_PER_HOUR` (10) and `AGENTS_HOSTED_CERTS_PER_WEEK` (40) new names. A name is new until its account records `certificate`, the time it was first allowed.
- **FR-009**: An account's state is `active` or `suspended` (with a reason and a time). A suspended account's copy stops within one minute, and its address answers `403`, `Agents-Refusal: suspended`, and "This hosted account is suspended. See https://<domain>/account."
- **FR-010**: The admin command, `agents-hosted admin`, reads the same store as the service:
  - `invite [--days 14]`: prints a new invite link.
  - `allow <login>` / `disallow <login>`.
  - `waitlist`: lists it in order, with each place, login, id and time.
  - `admit <login>`: allows the login (the waitlist entry stays until the account is made).
  - `suspend <account> <reason>` / `unsuspend <account>`.
  - `block <github id or login> [reason]` / `unblock <github id>`: a block also suspends the id's account.
  - `accounts`: lists each account's id, login, plan, state and created time.
  - `plan <account> free|pro`: sets the plan by hand (FR-021).
- **FR-011**: The pages show each state in words: "You are on the waitlist, number N." with why (no invite, the cap, the account's age); "Too many sign-ups just now. Try again in an hour."; "This invite is used or expired."; "Sign-up is not open to this GitHub account."; "This account is suspended: <reason>."
- **FR-012**: The service keeps no email address and sends no email.

### Functional Requirements: plans and limits (#2224)

- **FR-020**: Each account has a plan, `free` (the default) or `pro`, in its account record. A plan's limits:

  | Limit | Free | Pro |
  |---|---|---|
  | Machines joined | 2 | 20 |
  | Clients paired | 5 | 50 |
  | Connections open at once | 20 | 200 |
  | Storage | 1 GB | 20 GB |
  | Events kept | 7 days | 90 days |
  | Agents running at once | 3 | 30 |

  The numbers are in one table in `Go/internal/hosted/plans.go`; changing them is a one-line change.
- **FR-021**: `agents-hosted` holds each account's control plane to its plan:
  - **Machines and clients:** a new record under `v1/machines/` or `v1/clients/` over the limit is refused by the account's store.
  - **Storage:** a write that makes the account's store larger than the limit is refused. A write that does not make it larger is never refused.
  - **Connections:** the proxy counts each account's open WebSockets. One over the limit gets `429` and the words.
  - **Events:** a sweep each hour deletes the account's events older than the plan keeps.
  - **Agents running at once** (#2243): the control plane's router refuses `agents/start` and the other ways to begin another running agent, at the plan's limit, through a hook (`Config.AgentsRunningGate`) `agents-hosted` sets per account.
- **FR-022**: A refusal names the limit and the plan: "Your Free plan allows 2 machines. Remove one, or upgrade at https://<domain>/account." The words reach the client that asked, as the control plane passes a store error on. Where the control plane does not pass it on, the words go in the service's log and the gap goes on the 0.12 follow-up list for the control-plane hook.
- **FR-023**: A refusal at a limit deletes nothing. A downgrade deletes nothing, except events past the plan's days.
- **FR-024**: The account page shows the plan and the use of each limit ("Machines: 1 of 2", "Storage: 120 MB of 1 GB").
- **FR-025**: Workspace providers are off on every hosted account (no `ProviderHome`).
- **FR-026**: A test shows two accounts' policies, records and secrets apart: neither copy can read or change the other's keys.

### Functional Requirements: billing (#2225)

- **FR-030**: `Go/internal/hosted/billing/` talks to Stripe through an interface: make a Checkout session, make a portal session, and check a webhook's signature. The tests use a fake.
- **FR-031**: With no `AGENTS_HOSTED_STRIPE_KEY`, billing is off: no **Upgrade**, no **Manage Billing**, no webhook route, and every account is on Free unless the operator sets a plan.
- **FR-032**: **Upgrade** makes a Checkout session for `AGENTS_HOSTED_STRIPE_PRICE` with the account's id as `client_reference_id`, and sends the browser to it. Success and cancel come back to `/account`.
- **FR-033**: `/billing/webhook` checks the `Stripe-Signature` with `AGENTS_HOSTED_STRIPE_WEBHOOK_SECRET`, refuses a bad or old one (5 minutes), and acts on `checkout.session.completed` (Pro, keep the customer id), `customer.subscription.updated` (Pro while `active` or `trialing`, else Free) and `customer.subscription.deleted` (Free). Each event id is acted on once.
- **FR-034**: **Manage Billing** makes a customer portal session for the account's customer and sends the browser to it.
- **FR-035**: Billing keeps no card data. The account record keeps the Stripe customer id and subscription id only.

### Functional Requirements: operations (#2226)

- **FR-040**: `deploy/gcp/hosted-up.sh` deploys `compose.hosted.yaml` to a GCP VM, as `deploy/gcp/up.sh` does for the control plane. It does nothing without the names and secrets it needs, and says which are missing.
- **FR-041**: The VM's disk has a daily snapshot, kept 7 days, as #2136 does for the control plane. `agents-hosted admin backup <dir>` and `admin restore <dir> <account>` copy one account's prefix out of and into the store.
- **FR-042**: `/metrics` (Prometheus text) answers only from loopback and the trusted proxies' network, never through Caddy. It has: accounts by plan and state, waitlist length, copies running, sign-ups and refusals by kind, certificates allowed, and requests by status. It uses the same names as #2176 where they overlap.
- **FR-043**: The log is one line per event, as today, and never holds a code, a key, a token or an email.
- **FR-044**: The runbook in `docs/how-to/run-the-hosted-service.md`: deploy, update, back up, restore, suspend, block, delete an account, raise the cap, admit from the waitlist, turn billing on.

### Clients

- **CL-001 web (the service's own pages):** the waitlist, rate, invite, blocked and suspended states (FR-011); the plan and use (FR-024); **Upgrade** and **Manage Billing** (FR-031).
- **CL-002 web (the control plane's page, `Web/src`):** a refusal at a limit is an error line with the refusal's words, as any error is today. A suspended address answers before the page loads; the browser shows the refusal's text.
- **CL-003 Mac and Remote:** a suspended account's control plane refuses the connection; they show the line it answers as their connection error. A refusal at a limit shows its words as an error line. The waitlist: by design, nothing (no control plane to meet). Billing: by design, nothing (billing is on the web).

### Key Entities

- **Account** (`hosted/v1/accounts/<id>.json`): id, GitHub id and login, created, plan, state (`suspended` with reason and time), certificate time, Stripe customer and subscription ids.
- **Allowlist entry** (`hosted/v1/allow/<login>.json`): login, who added it, when.
- **Invite** (`hosted/v1/invites/<code>.json`): expiry, used (by GitHub id, when).
- **Waitlist entry** (`hosted/v1/waitlist/<github id>.json`): login, when, why.
- **Block** (`hosted/v1/blocked/<github id>.json`): reason, when.
- **Stripe event** (`hosted/v1/stripe/<event id>.json`): seen, so it is acted on once; swept after 30 days.

## Success Criteria *(mandatory)*

- **SC-001**: With `invite`, no GitHub user makes an account without an invite or an allowlist entry (test).
- **SC-002**: 200 sign-ins from 20 addresses in an hour make at most 30 accounts and waitlist entries (test, fake clock).
- **SC-003**: A suspended account's address answers `403 suspended` within 60 seconds of the command (test).
- **SC-004**: Each limit of FR-020 that is enforced refuses the first one over, with words that name it and the plan, and deletes nothing (test).
- **SC-005**: Two accounts' records, policies and secrets stay apart (test).
- **SC-006**: Without a Stripe key, no billing route answers, and the account page shows no **Upgrade** (test).
- **SC-007**: A webhook with a bad signature changes nothing; a good one sets the plan once, however many times it comes (test).
- **SC-008**: `hosted-up.sh` with nothing set exits non-zero and names each missing input (test with no `gcloud` calls).

## Not in this spec

- Open sign-up with Turnstile (FR-001 `open` is the setting; the CAPTCHA comes with it).
- Several people in one hosted account beyond what the team tier (T1–T4) gives every control plane.
- An admin web page, invoices in Agents, taxes, more than one paid plan, yearly prices.
- Many service processes over one store (the rates, the copies and the certificate count are per process).

## Docs

- `docs/how-to/run-the-hosted-service.md`: the settings, the admin command and the runbook (FR-044).
- `docs/reference/integrations.md`: a Stripe row (#2225), untested until Alex's account (#2227).
- `docs/explanation/direction.md`: one line that sign-up is by invitation in the beta.
