# Feature Specification: Enterprise T6: org keys and model gateways

**Feature Branch**: `agents/are-0-11-enterprise-5` (spec only)

**Created**: 2026-10-21

**Status**: Draft. Nothing here is built yet.

**Milestone**: 0.11 Enterprise. Nothing for 0.11 merges to `main` before v0.10.0 ships.

**Input**: Issue #999, roadmap step T6 in `specs/research/733-team-and-enterprise.md`. It builds on:

- **T5, policy** (#998, PR #2164, `specs/998-org-policy/`): one signed policy document, pushed to every machine, enforced as a ceiling. T6 adds two rules to it.
- **Several accounts per runtime** (#840, PR #2158): `AccountProfile` with `reach`, the account picker, an allowance per account. T6 adds two kinds of `reach`. It makes no second model.
- **User secrets** (#1760, spec 736 US4): secrets sealed with the control plane's keeper and sent only to the person's own machines.
- **The sign-in relay** (056): a loopback gate that the runtime is pointed at, with a stand-in token.

## Why this feature exists

**Today each person brings their own way to the model.**

- A person signs a runtime in with their own subscription (Claude Max, ChatGPT, Google, GitHub), or passes their own key through (`ANTHROPIC_*`, `OPENAI_*`, #727).
- An organisation cannot give its people one key or one gateway, cannot keep the key from them, and cannot make sure that work goes through the gateway that its contracts, its logging and its data-residency rules need (Amazon Bedrock, Google Vertex AI, Microsoft Azure, or its own LLM gateway).

**This feature gives the organisation its own way to the model.**

- An admin adds an **org route** in Console ▸ Model Access on the web page: an org key, or a gateway (Bedrock, Vertex, Azure, a base URL), for one or more runtimes.
- The control plane keeps the secret sealed. It sends it to each machine that may use it, sealed to that machine's own key. No member ever sees it.
- On the machine, the runtime never gets the secret. It gets a stand-in and the address of a relay on loopback. The relay adds the real credential and sends the request on.
- The route is one more account of the runtime (#840). A member picks it in the same account picker. Each runtime's **Reaches the Model By** setting is its default account.
- The policy (T5) can require the org path for a runtime. Then the person's own sign-in is a refused choice, with **Set by your organisation**.
- Antigravity's terms notice becomes a policy switch.

**A control plane with no org route works as today.** One person sees no change.

## Decisions

Each of these is decided and easy to undo. Alex can overrule each one.

| # | Question | Answer |
|---|---|---|
| D1 | What is "how it reaches the model"? | **An account of the runtime (#840).** `AccountReach` gains two cases: `orgKey` and `gateway`. An org route shows on each member's machines as an account, with `source: organisation`. **Reaches the Model By** is the runtime's default account for new sessions. The picker of #840 stays, per session. Decided, because #840 already has the picker, the allowance per account and the session's `accountID`; a second model would split them. |
| D2 | Where is an org key kept? | **On the control plane, as #1760 keeps user secrets:** an envelope sealed with the control plane's keeper (Cloud KMS, Vault or the local key file), bound to its store key, at `v1/org/routes/<id>.secret.json`. Only ciphertext is in the store. Decided, because it works with two copies of the control plane, and it is the one secret model that already exists. The issue's "never in the store" is read as "never in the clear in the store" (store rule 7). |
| D3 | How does it reach a machine? | **Sealed to that machine's own key.** The control plane opens the envelope, and seals the value with HPKE to the machine's P-256 key (`HostRecord.PublicKey`), bound to the route, the machine and the route's version. It sends it on channel 0 as `host/orgRoutes`. Only machines whose person may use the route get it. Decided, because a relay, a log or another copy that sees the message cannot open it. |
| D4 | How does it reach the runtime? | **Never.** The machine keeps the sealed value on disk and opens it in memory. A **model relay** on loopback (TLS, the 056 pattern) takes the runtime's requests, checks a stand-in token, puts in the real credential and sends the request to the provider. The runtime's environment has the relay's address and the stand-in only. Decided, because an agent can run `env` and print what it has: a key in the runtime's environment is a key shown to the member. |
| D5 | A runtime whose model traffic the relay cannot carry | **Gets no org key and no gateway in this spec** (Cursor, Copilot, Antigravity, and Grok until its base URL is measured). Decided, because of D4. A later spec can allow a key in the environment with an admin's explicit "members can read this key". |
| D6 | Which person may use a route? | **Everyone, or the groups the admin names** (T1 groups), as for workspace providers. Decided, because groups already own providers and bot cost. |
| D7 | Policy: "require the org path" | **T5's `runtimes.<id>.reach`** (`signIn`, `orgKey`, `gateway`), per runtime. Absent = every way. `["orgKey", "gateway"]` is "the org path only". Decided in T5 FR-030; T6 builds it. |
| D8 | The relay that clears `CLAUDE_CODE_USE_BEDROCK`, `_VERTEX` and `ANTHROPIC_BASE_URL` | **It stays as it is for a sign-in account.** For an org account, the machine sets these variables itself, to the model relay, after it takes out everything that the person's own environment brought for that runtime. The 056 sign-in relay is not used for an org account. Decided, because the two never mix in one process. |
| D9 | The person's own Bedrock or base URL (pass-through, #727) | **Stays for a sign-in account.** Under a policy whose `reach` refuses `signIn` for that runtime, the runtime's own variables (`ANTHROPIC_*`, `AWS_*`, `CLAUDE_CODE_USE_*`, …) are taken out of the person's pass-through for it, so a member cannot point it somewhere else. Decided, because "require the org path" must not have a way round it. |
| D10 | Antigravity's terms notice | **A policy rule, `notices.antigravityTerms`:** `show` (absent, as today), `accepted` (the organisation has reviewed Google's terms: members do not see the notice, and the Policy pane says so), or `refuse` (Antigravity is refused, with the terms as the reason). Decided, because the notice is a legal question for the organisation, not for each member. |
| D11 | Offline | **A machine keeps the sealed routes it has, and uses them offline**, until a newer delivery takes one away. Revoking a key at once is done at the provider, then with the kill switch (T5). Decided, because the policy (T5) works the same way, and the provider is the only place that can stop a leaked key. |
| D12 | Usage and allowance | **The relay counts tokens from each response** (the provider's own `usage` field), per turn, per route, per person. An org account has no plan reading. It is "out" only on the provider's rate-limit or quota answer, for that account only. Cost is shown as the runtime reports it, with "list price, as <runtime> reports it". Decided, because a token count from the provider's answer is a fact; a price is not (constitution IV, T5 budgets). |
| D13 | Where an admin manages routes | **Console ▸ Model Access on the web page**, beside Console ▸ Policy. The Mac and the Remote show the routes read only. Decided, because Alex decided that the Console is web only (#1804, decision 1), and T5 follows it. |
| D14 | A value after it is saved | **Never shown again, also to admins.** The Console shows who set it, when, and a short fingerprint (the first 8 hex of SHA-256), so two admins can compare. **Replace Key** writes a new value. Decided, because a secret that can be read back can be copied. |

**Open question for the scrum master (Q1):** see Clarifications. The spec is written with the recommended answer.

## Words

- **Org route**: an organisation's way to the model for one or more runtimes: an org key, or a gateway. It has a name ("Acme Bedrock"), a kind, settings that are not secret, and one or more secret values.
- **Org key**: an API key of the runtime's own vendor (Anthropic, OpenAI, Google AI Studio, xAI) that the organisation pays for.
- **Gateway**: a way to the model through another service: **Amazon Bedrock**, **Google Vertex AI**, **Microsoft Azure** (Azure OpenAI, or Claude in Microsoft Foundry), or a **base URL** (the organisation's own LLM gateway, such as LiteLLM or Portkey).
- **Org account**: an org route as one machine shows it: an `AccountProfile` (#840) with `reach: orgKey` or `reach: gateway` and `source: organisation`.
- **Reaches the Model By**: a runtime's setting on each person's machines: which account a new session uses. Its choices are **Your Own Sign-In** (the Default account of #840), the person's added accounts (#840), and the org accounts.
- **Model relay**: a server on loopback on each machine. The runtime sends its model requests to it. It puts in the real credential and sends them on.
- **Stand-in**: a random token the machine gives the runtime in place of the key. It works only on that machine's model relay.
- **From your organisation**: the line under an org account, on every client.

## Clarifications

### Session 2026-10-21 (the 0.11 spec lane, decide and tell; Alex can overrule)

- Q: Is "how it reaches the model" a new setting beside the accounts of #840?
  → A: **No. It is the runtime's default account** (D1). An org route is an account with another `reach`. The account picker stays per session.
- Q: Can a member see the key?
  → A: **No client shows it, no file in the clear holds it, and the runtime's process never has it** (D3, D4, D14). The docs say plainly what this does not stop: `agentsd` runs as the member (hosts never escalate), so a member who reads the machine's memory with a debugger can find a key that is open there. The model relay keeps the key open only while it sends a request. The organisation's real protection is the provider's own limits on the key, and the kill switch.
- Q: Which runtimes can use which gateway?
  → A: The table in "What each runtime can use" below. A runtime gets a kind only when its model traffic can go through the relay (D5).
- Q: What does a member see?
  → A: One line each, on the Mac, the Remote and the web: the org account in the account picker and on the Runtimes page, named as the admin named it, with **From your organisation** under it. No key, no fingerprint, no URL.
- Q: How do usage and allowance read?
  → A: D12. Tokens from the relay's count. The Runtimes page has no plan bar for an org account; it says **Organisation · No plan limit** and "Out until 14:05" after a rate-limit answer.
- Q (open, Q1 for the scrum master): **Where is a cloud credential (an AWS role, a Google service account, an Azure Entra app) turned into a short-lived token?**
  - **A (recommended, written in this spec):** **on the control plane.** It keeps the long-lived credential sealed, and sends each machine a token that ends within an hour (AWS STS, Google OAuth, Entra), sealed to the machine, about 10 minutes before the last one ends. A machine never holds a credential that lasts. An offline machine loses that gateway within an hour. Plain API keys (Anthropic, OpenAI, a Bedrock API key, an Azure key, a gateway's key) are sent as they are, and work offline (D11).
  - **B:** on the machine. The machine keeps the long-lived credential sealed, and its relay makes the tokens. It works offline, and every machine holds a credential that lasts.
  - Why it is not decided: A is safer and B works offline. Both are reasonable for an enterprise, and the choice changes what the control plane needs (three cloud SDKs).

## What each runtime can use

"Yes" means: the relay can carry it, and this spec builds it. The exact variables are in `research.md` R2; those marked "measure" there are checked by the build lane before it builds that row.

| Runtime | Org key | Bedrock | Vertex | Azure | Base URL | How the relay is reached |
|---|---|---|---|---|---|---|
| **Claude** | Yes (Anthropic key) | Yes | Yes | Yes (Claude in Microsoft Foundry) | Yes | Variables: `ANTHROPIC_BASE_URL` or `CLAUDE_CODE_USE_BEDROCK`/`_VERTEX`/`_FOUNDRY` with that gateway's base URL and its "skip auth" switch, and a stand-in |
| **Codex** | Yes (OpenAI key) | No | No | Yes (Azure OpenAI) | Yes (OpenAI-compatible) | A `config.toml` in the account's own `CODEX_HOME` (#840) with a model provider whose `base_url` is the relay |
| **Gemini** | Yes (Gemini API key) | No | Yes | No | Yes (measure) | Variables: the Gemini key and Vertex switches, with the base URL variable for each (measure) |
| **OpenCode** | Yes (Anthropic or OpenAI key) | Yes | Yes | Yes | Yes | A config file of the account's own (`OPENCODE_CONFIG`) with one provider whose `baseURL` is the relay |
| **Grok** | Measure first (xAI key) | No | No | No | Measure first | Only when its CLI takes a base URL. Until then, sign-in only |
| **Copilot** | No | No | No | No | No | Sign-in only. The org path for Copilot is the person's own GitHub sign-in with the organisation's Copilot seat; the admin allows `signIn` for Copilot in the policy |
| **Cursor** | No | No | No | No | No | Sign-in only. Cursor has no base URL; its key would be in the agent's environment (D5) |
| **Antigravity** | No | No | No | No | No | Google sign-in only. Its terms notice is a policy switch (D10) |

## User Scenarios & Testing *(mandatory)*

### User Story 1 - One person sees no change (Priority: P1)

Alex runs a control plane alone, with no org route and no `reach` rule. Every runtime signs in and starts as before. No account says **From your organisation**.

**Why this priority**: most people use Agents alone. The feature must cost them nothing.

**Independent Test**: update a scratch control plane and a machine with no route. Start each runtime. `runtimes/accountProfiles` lists no org account. Each runtime's environment is the same as before, byte for byte, apart from order.

**Acceptance Scenarios**:

1. **Given** no org route, **When** a machine joins, **Then** it gets `host/orgRoutes {routes: []}`, starts no model relay, and launches every runtime as today.
2. **Given** no org route, **When** any client opens a runtime's **Reaches the Model By**, **Then** it lists the person's own sign-in and their #840 accounts only.

---

### User Story 2 - An admin adds a gateway and members use it (Priority: P1)

Priya is an admin. In Console ▸ Model Access she adds **Acme Bedrock**: kind Bedrock, region `us-east-1`, a Bedrock API key, for Claude and OpenCode, for everyone, and sets it as the default for Claude. Within seconds Sam's Mac and Sam's Linux server have it. Sam starts a Claude session: the account capsule says **Acme Bedrock**, and under it **From your organisation**. The session runs. Sam's own Claude Max sign-in is still there, in the picker.

**Why this priority**: this is the feature.

**Independent Test**: on a scratch control plane with two people and three machines, add a base-URL route that points at a fake provider on loopback, with a fake key. Start the fake runtime and Claude on each machine. The fake provider sees the real key on every request. The runtime's process environment, the transcript, `daemon.log`, `events.jsonl` and every file under the root hold neither the key nor any part of it.

**Acceptance Scenarios**:

1. **Given** a saved route, **When** the control plane keeps it, **Then** each online machine whose person may use it has it within 5 seconds, and an offline one when it connects.
2. **Given** a route for the group Platform, **When** a machine of a person outside Platform connects, **Then** it gets nothing of that route: no name, no value.
3. **Given** a machine with the route, **When** a session starts on the org account, **Then** the runtime gets the relay's address and a stand-in, never the key, and the relay sends each request on with the real credential.
4. **Given** a route that is the default for Claude, **When** a person has not chosen another default, **Then** a new Claude session uses the route. A person's own choice of default wins, unless the policy refuses it (US3).
5. **Given** a request with a wrong stand-in, or from another user on a shared Linux machine, **When** the relay gets it, **Then** it refuses it with 401 and sends nothing on.
6. **Given** a branch, **Continue in New** or a helper of an org-account session, **When** it starts, **Then** it keeps the same account (#840).

---

### User Story 3 - The policy requires the org path (Priority: P1)

Priya sets Claude's reach to **Org key or gateway** in Console ▸ Policy. On Sam's Mac, the **Your Own Sign-In** row and Sam's added Claude accounts are dimmed, with **Set by your organisation**. A session that ran on Sam's own sign-in meets the policy at its next turn: the turn is refused, and the chat says "Your organisation requires Claude to use Acme Bedrock. Continue in New to move this session." with **Continue in New**.

**Why this priority**: an organisation that pays for a gateway must know that work goes through it.

**Independent Test**: with the route of US2 and the policy above, try to start Claude on a sign-in account by the wire, from every path of T5 FR-009 (start, helper, workflow, Continue in New, Branch, `setOption`). Each is refused with `policyRefused`, rule `runtimes.claude.reach`. Set `ANTHROPIC_BASE_URL` and `CLAUDE_CODE_USE_BEDROCK` in the person's pass-through: the runtime's environment does not have them.

**Acceptance Scenarios**:

1. **Given** `reach: ["orgKey", "gateway"]` for a runtime, **When** a session, helper or workflow asks for a sign-in account, **Then** the machine refuses it with **Set by your organisation**. A workflow or helper with no account named takes the runtime's org default, and says so in the run.
2. **Given** that rule and no org route for that runtime on this machine, **When** a person starts it, **Then** it is refused with "Your organisation's way to this model has not reached this machine. Connect to the network." (D11).
3. **Given** that rule, **When** the machine builds the runtime's environment, **Then** the runtime's own variables from the person's pass-through are taken out (D9).
4. **Given** a looser policy later, **When** machines get it, **Then** the person's own sign-in and accounts come back as they were.

---

### User Story 4 - An admin rotates and removes a key (Priority: P2)

A key may have leaked. Priya opens **Acme Bedrock** and selects **Replace Key**. She pastes the new key and saves. Every machine gets the new value within 5 seconds; running sessions use it from their next request. She revokes the old key at AWS. Later she removes the route: each machine takes the org account away, stops the sessions that use it, and deletes the sealed value.

**Why this priority**: a key that cannot be changed is a risk the security team will not sign.

**Independent Test**: on a scratch set-up, replace a route's key while a fake runtime sends a request each second. The fake provider sees only the new key within 5 seconds, and no request fails. Remove the route: the machine has no file for it, and the sessions on it stop with a line in the chat.

**Acceptance Scenarios**:

1. **Given** a replaced key, **When** machines get the new delivery, **Then** the relay uses the new value from its next request, and the old sealed file is deleted.
2. **Given** a removed route, **When** a machine gets the delivery without it, **Then** it stops each session on that account, with "Your organisation removed Acme Bedrock.", deletes the sealed file, and the account leaves the picker. The sessions are kept; **Continue in New** moves one to another account.
3. **Given** a person removed from the group the route is for, **When** their machines get the next delivery, **Then** the same happens on their machines.
4. **Given** any change to a route, **When** it is saved, **Then** the audit trail (T3) has who, when, and what changed, with no value and no fingerprint of a value other than the D14 fingerprint.

---

### User Story 5 - A member reads usage on an org account (Priority: P2)

Sam opens the Runtimes page. The row **Claude · Acme Bedrock** says **Organisation · No plan limit**, and today's tokens. After Bedrock answers "too many requests", the row says "Out until 14:05", and only that account is out; Sam's own Claude Max sign-in is not. Priya, in Console ▸ Reports, sees tokens per route, per person, per day.

**Why this priority**: people need to see what they used, and an admin needs to see what the route costs.

**Independent Test**: a fake provider answers with known `usage` numbers and then a 429 with `retry-after`. The turn's tokens on the machine equal the sum of the answers. The account goes out until the stated time, and the Default account stays in. The control plane's roll-up for the route and the person equals the machine's.

**Acceptance Scenarios**:

1. **Given** a turn on an org account, **When** it ends, **Then** its tokens are the relay's count from the provider's answers (input, output, cache read, cache write), kept beside what the runtime reported.
2. **Given** the provider's rate-limit or quota answer, **When** the relay sees it, **Then** that account's credential (`<runtime>:account:<id>`, #840) is out until the time the answer gives, or for 5 minutes when it gives none.
3. **Given** a cost that the runtime reports, **When** a client shows it for an org account, **Then** it says "list price, as Claude reports it". T5's budgets count the tokens and the reported cost.
4. **Given** usage roll-ups, **When** the control plane adds them, **Then** each row carries the route, so Console ▸ Reports splits by route.

---

### User Story 6 - Antigravity's terms become a policy switch (Priority: P3)

Priya's legal team has read Google's terms. In Console ▸ Policy, under **Antigravity's terms**, she chooses **Reviewed by your organisation**. Members no longer see the notice when they sign Antigravity in; the Policy pane says "Your organisation has reviewed Antigravity's terms." Another organisation chooses **Do not allow**: Antigravity is refused, and the reason links to the terms.

**Why this priority**: it matters to some organisations only.

**Independent Test**: set each of the three values by the wire. The sign-in sheet shows the notice only for `show`. With `refuse`, every start of Antigravity is refused with `policyRefused`, rule `notices.antigravityTerms`.

**Acceptance Scenarios**:

1. **Given** no rule, **When** a member signs Antigravity in, **Then** the notice shows, as today.
2. **Given** `accepted`, **When** a member signs it in, **Then** the notice does not show, and the line "Your organisation has reviewed these terms." shows in its place.
3. **Given** `refuse`, **When** a member starts it or signs it in, **Then** it is refused with **Set by your organisation** and "Your organisation does not allow Antigravity, because of Google's terms on third-party tools.", with the link.

---

### User Story 7 - A machine keeps working offline (Priority: P3)

Sam's server loses its link to the control plane for a day. Its sessions on **Acme Bedrock** go on: Bedrock is still reachable, and the server has the sealed key. When the link comes back, it gets the newest delivery.

**Why this priority**: the control plane is not in the path of each request.

**Independent Test**: with a key route, stop the control plane. Turns on the org account go on. Restart the machine's `agentsd`: the route is still there, from the sealed file. Start the control plane with the route removed: the machine takes it away within 5 seconds of connecting.

**Acceptance Scenarios**:

1. **Given** an offline machine with a key route, **When** a turn starts, **Then** it uses the kept route.
2. **Given** Q1 answer A and a cloud-credential route, **When** the token ends while offline, **Then** the next request fails with "Your organisation's Bedrock access ended while this machine is offline. Connect to the network.", and the account is out until a new token arrives.
3. **Given** a sealed file that does not open with the machine's key (copied from another machine, or edited), **When** the machine reads it, **Then** it deletes it, and asks the control plane for the delivery again.

---

### Edge Cases

- **Two admins save one route at once**: the conditional write lets one through (store rule 3); the other is told to load it again.
- **A route for a runtime that the policy does not allow** (T5 `runtimes`): the Console warns before it saves. Members do not see it.
- **A machine of an older version**: it does not say `host.orgRoutes.1`. It gets no route. The Console's Machines page shows **Cannot use org routes**. With a `reach` rule that refuses `signIn`, its sessions of that runtime are refused by the router (as T5 `requireFollowing`).
- **A Mac's own window and a Mac host**: the Mac host is a machine like any other and gets its own sealed copy. The window never gets a value.
- **A server that lends its sign-in to another (056)**: an org account is never lent. Each machine has its own delivery.
- **The person's own key in the login environment** (`ANTHROPIC_API_KEY` in `.zshrc`): for an org account it is taken out, so it cannot answer first (#840 does the same for its accounts).
- **The model in a gateway**: a gateway's model ids differ (`us.anthropic.claude-sonnet-…` on Bedrock). The route keeps a model map (the runtime's model names to the gateway's). The model menu shows the runtime's names. A model the route does not map is not offered for that account.
- **Streaming and large requests**: the relay streams both ways, and adds no buffering. It refuses a request body over 32 MiB.
- **The relay's port is taken**: it picks another free port at each start; the stand-in and the address go to the runtime at launch.
- **A provider that is down**: the relay passes the provider's answer through. It does not try another route by itself (Alex's rule for accounts: nothing switches account by itself, #840).
- **A route's settings are wrong** (a bad region): the Console's **Check** sends one small request from the control plane where it can (keys and base URLs), and says the answer. A machine's first failed request says the provider's words in the chat.
- **Bots** (T1): a bot's machines get the routes for the bot's groups, as a person's do.
- **Control key rotation (T4)**: sealing uses each machine's key, not the control key. Nothing changes.
- **A machine removed**: its person is told which routes were on it (as `SecretsLeft`, #1760). The admin is told too, in Console ▸ Model Access.

## Requirements *(mandatory)*

### Functional Requirements

**Routes on the control plane (slice 1)**

- **FR-001**: The control plane MUST keep each org route as a plain record `v1/org/routes/<id>.json` (no secret: name, kind, runtimes, settings, model map, groups, default-for, `version`, who and when) and its secrets as an envelope `v1/org/routes/<id>.secret.json`, sealed with the keeper for secrets (#1760) and bound to its key. Fields: `data-model.md`.
- **FR-002**: A control plane with no keeper for secrets MUST refuse to save a route that has a secret, with "This control plane has no key to seal secrets with." (as `ErrNoSealing`). A base-URL route with no key MAY be saved.
- **FR-003**: Only an admin MUST be able to add, change, check, replace a key of, and remove a route (`orgRoutes/*`). A value MUST never be returned by any method, to anyone (D14). A member MUST be able to read the names and kinds of the routes they may use (`orgRoutes/mine`).
- **FR-004**: Each change MUST raise the route's `version` by one and be an audit entry (T3) with the actor and the fields that changed. A value is shown in the audit only as "key replaced".
- **FR-005**: The control plane MUST send each machine that says `host.orgRoutes.1` the routes its person (or bot) may use, on channel 0, as `host/orgRoutes`: each route's record and each secret sealed with HPKE (P-256, HKDF-SHA256, AES-256-GCM) to the machine's key, with info `com.alexecollins.agents.orgroute.v2` and the route id, the machine id, the route `version` and a SHA-256 of the whole delivered route without its sealed values (its kind, vendor, runtimes, settings such as `address` and `header`, models and expiry) as associated data, so a kept route whose settings differ from what was delivered does not open. It MUST send it on connect and within 5 seconds of each change, on every copy, and send nothing to a machine of a person who may not use the route.
- **FR-006**: The route and its delivery MUST be in `Packages/Wire/daemon.schema.json` (`OrgRoute`, `OrgRouteKind`, `OrgRouteDelivery`, `SealedEnvelope` reused) and the methods in `control.openrpc.json`, generated by `scripts/wire.sh gen` (#1135).
- **FR-007**: (Q1 answer A.) For a cloud-credential route, the control plane MUST make a token that ends within one hour and send it, sealed, in place of the credential, about 10 minutes before the last one ends. It MUST never send the long-lived credential to a machine.
- **FR-008**: The T5 policy MUST gain `runtimes.<id>.reach` (built here; named in T5 FR-030) and `notices.antigravityTerms` (`show`, `accepted`, `refuse`), each with its capability in `requires` (`host.orgRoutes.1`).

**On the machine (slice 2)**

- **FR-009**: A machine MUST keep each delivered secret as its sealed envelope in `<root>/org-routes/<id>.json` (0600), never in the clear on disk, open it in memory only when the relay needs it, and delete a file that the newest delivery no longer has, or that does not open.
- **FR-010**: A machine MUST list each delivered route as an `AccountProfile` (#840) for each of its runtimes that the table above allows, with `reach: {orgKey: {route}}` or `reach: {gateway: {route, kind}}` and `source: organisation`, and keep it out of `runtime-accounts.json` (the person cannot remove it).
- **FR-011**: A machine MUST run one model relay on loopback when it has at least one route: TLS with a certificate from a CA of its own (the runtime trusts it by `NODE_EXTRA_CA_CERTS`, `CODEX_CA_CERTIFICATE` or the runtime's own setting), a stand-in token per session, and a refusal (401) for any other token.
- **FR-012**: The relay MUST add the credential that the route's kind needs (an API key header, a Bedrock bearer key or SigV4 with a short-lived AWS credential, a Google OAuth token, an Azure key or Entra token), send the request to the route's address, stream the answer back, and keep no request or answer body.
- **FR-013**: For a session on an org account, the machine MUST build the runtime's launch as in "What each runtime can use" and `research.md` R2: first take out every variable that the runtime's own pass-through and the login environment bring for that runtime (#840 does this for its accounts), then set the relay's address, the stand-in, the gateway's switches and non-secret settings. The runtime's environment and files MUST never hold a secret value.
- **FR-014**: The 056 sign-in relay MUST go on clearing `CLAUDE_CODE_USE_BEDROCK`, `CLAUDE_CODE_USE_VERTEX` and `ANTHROPIC_BASE_URL` for a sign-in account, and MUST NOT be used for an org account (D8).
- **FR-015**: The machine MUST enforce `runtimes.<id>.reach` at every path of T5 FR-009, with `policyRefused` and the rule's name, and mark refused accounts with `setBy` in `runtimes/accountProfiles` and the Runtimes rows. With `signIn` refused, the runtime's own variables MUST be taken out of the person's pass-through (D9).
- **FR-016**: Each runtime MUST have a default account (**Reaches the Model By**), kept per person in the runtimes user setting (so the control plane carries it, #1760). A route that is `defaultFor` a runtime is the default when the person has set none, or when the policy refuses theirs.
- **FR-017**: The machine MUST enforce `notices.antigravityTerms`: `refuse` refuses every start and sign-in of Antigravity; `accepted` sends `signInNotice` as absent and the line of US6 in its place.
- **FR-018**: A removed route, or a person no longer allowed, MUST stop the sessions on it within 5 seconds of the delivery, with a line in the chat, and keep the sessions.

**Usage and allowance (slice 2, with slice 4)**

- **FR-019**: The relay MUST count each answer's tokens from the provider's own usage fields (Anthropic, OpenAI, Gemini and Bedrock shapes, `research.md` R5), add them to the turn, and keep them beside what the runtime reports, as `relayTokens`.
- **FR-020**: A rate-limit or quota answer MUST put that account's credential out (#840 key `<runtime>:account:<id>`) until its `retry-after` or reset header, or 5 minutes, and nothing else.
- **FR-021**: The usage roll-up row MUST carry `route` (the route id) for a turn on an org account. The control plane MUST add tokens per route, person and UTC day for Console ▸ Reports.
- **FR-022**: T5 budgets MUST count an org-account turn's `relayTokens` as its tokens. A runtime that is unmetered on its own (T5 `unpricedTurns`) is metered on an org account.

**Clients (slice 3)**

- **FR-023**: The Mac, the Remote and the web page MUST show an org account in the account picker (#840) and on the Runtimes page, by its route's name, with **From your organisation**, and MUST show the picker when a runtime has an org account (even with no #840 account).
- **FR-024**: All three clients MUST show each runtime's **Reaches the Model By** in its runtime settings (Mac: the runtime's sign-in sheet; Remote and web: the runtime's row on the Runtimes page), and refused choices dimmed with **Set by your organisation** (T5 FR-020).
- **FR-025**: All three clients MUST show an org account's allowance as **Organisation · No plan limit**, today's tokens, and "Out until …" when it is out (D12).
- **FR-026**: No client MUST ever receive or show a value, a fingerprint, a region, a project or an address of a route. A member sees the name, the kind ("Bedrock") and **From your organisation** only.

**Admin, web Console (slice 4)**

- **FR-027**: The web page MUST have Console ▸ Model Access, for admins: the routes, **Add Route** (kind, runtimes, settings, the secret fields, write only, model map, who: everyone or groups, default for), **Check**, **Replace Key**, **Remove**, and for each route the machines that hold it and its tokens this month.
- **FR-028**: Console ▸ Policy (T5) MUST gain, for each runtime, **Reaches the model by**: any way / org key or gateway only / own sign-in only; and **Antigravity's terms**: show / reviewed by your organisation / do not allow. The preview says who it changes ("4 people use their own Claude sign-in; their next turn will be refused").
- **FR-029**: The Mac and the Remote MUST show, read only, the routes a person may use in Settings ▸ Control plane ▸ Policy, with **Edit in Console** for an admin (as T5 FR-021).

### Key Entities

- **OrgRoute**: id, name, kind (`key`, `bedrock`, `vertex`, `azure`, `baseURL`), vendor (for `key`: `anthropic`, `openai`, `gemini`, `xai`), runtimes, settings (region, project, location, resource, address, API shape), model map, groups (empty = everyone), `defaultFor` (runtime ids), `version`, created and changed by and when.
- **OrgRouteSecret**: the route's secret fields, sealed with the keeper, bound to its store key. Never on the wire unsealed.
- **OrgRouteDelivery**: what a machine gets: the routes its person may use, each with its secrets sealed to the machine.
- **AccountReach** (#840, extended): `signIn {folder}` | `orgKey {route}` | `gateway {route, kind}`.
- **Policy rules** (T5, extended): `runtimes.<id>.reach`, `notices.antigravityTerms`.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A control plane with no route shows no change on any client, and each runtime's launch environment is the same as before (test over all eight runtimes).
- **SC-002**: A saved or replaced route is on every allowed online machine within 5 seconds, also with two copies of the control plane; a machine not allowed gets nothing.
- **SC-003**: In a test that searches for the key's bytes (and its base64 and its hex) after a session of each supported runtime, the key is found in no runtime process environment, no file under the root or `~/.agents`, no log, no transcript, no event and no client message: 0 finds.
- **SC-004**: With "the org path only" for a runtime, every path of T5 FR-009 gives 0 ways to start that runtime on a sign-in account, and 0 ways to give it a gateway variable from the person's pass-through.
- **SC-005**: The relay adds under 5 ms to the time to the first byte of a model answer, at the 95th percentile, on the Mac and the devbox.
- **SC-006**: The relay's token count for a turn equals the sum of the provider's usage fields in 100% of the fake-provider tests, for each answer shape.
- **SC-007**: Each runtime row of the table marked "Yes" passes a walk on a fake provider, and on the real gateway in Alex's account test (not a gate, #1782).

## Docs

- `docs/explanation/org-keys-and-gateways.md`: add. Routes, the relay, what the member cannot see, and what this does not protect against.
- `docs/how-to/add-an-org-key-or-gateway.md`: add. Console ▸ Model Access for each kind, with the provider's own steps (a Bedrock API key, a Vertex service account, a Foundry resource, a gateway).
- `docs/reference/runtimes.md`: change. "More than one account" gains org accounts; a table "Org keys and gateways" (the table above, with the variables).
- `docs/reference/policy.md` (T5): change. `runtimes.<id>.reach`, `notices.antigravityTerms`.
- `docs/reference/integrations.md`: change. The "Model gateways" rows: one row per kind (Bedrock, Vertex, Azure, base URL, org key), state and #999.
- `docs/how-to/limit-spending.md`: change. Tokens on an org account.
- `specs/071-web-remote/walks/parity/`: change. Rows for FR-023 to FR-025 and FR-029.

## Assumptions

- **T5 lands first** (its slice 1 at least): T6 adds two rules to its document, and uses `policyRefused` and `setBy`.
- **#840 lands first**: `AccountProfile`, the picker and the account allowance key are its.
- **Sizes**: up to 50 routes and 10 secret values per route, each under 16 KiB (the #1760 bound); about 50 machines.
- **Clouds**: Bedrock, Vertex and Azure are reached over their public HTTPS endpoints. Private endpoints (PrivateLink) work when the machine can resolve them; nothing here sets them up.
- **Not in this spec**: a key in the runtime's environment (D5); Cursor, Copilot and Antigravity org paths; Grok until measured; choosing among routes by cost or failing over between them; per-project routes; showing a provider's bill.

## Limits

- **Where the machine's key is kept.** Every route is sealed to the machine's key, so the key opens every route the machine holds. On a Mac, agentsd keeps the key in a login Keychain item that it makes itself (Security.framework, through purego), service `agents.machine-key.<root hash>`. The item trusts only agentsd's code signature: another program of the same person, an agent's shell or `/usr/bin/security` included, cannot read it without the person's password. A root that kept `control-host-key` before moves the key into the item on its first start and removes the file.
- **On Linux the key is a file.** A Linux machine has no store that keeps a secret from other processes of the same user. The key is `<root>/control-host-key` (0600), and any process of that user, an agent's shell included, can read it and open the routes in `<root>/org-routes/`. A runtime's sandbox limits writes, not reads of the root. On a Linux machine shared with agents that must not see an org key, run agentsd as a user of its own, or do not deliver org routes to it.
- **A changed route file does not open.** Each secret's associated data holds the whole delivered route (FR-005). A process that can write the root can delete a route file, but it cannot change where the relay sends a key.
