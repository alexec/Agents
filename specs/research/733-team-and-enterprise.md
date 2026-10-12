# 733: Team and enterprise, a roadmap

2026-10-11, branch `agents/team-enterprise-plan-733` off main. This covers issue #733. It is planning only; nothing is built, and `docs/explanation/direction.md` is unchanged: the alpha comes first.

**Where it starts:** the enterprise review, `.agents/reviews/enterprise/2026-10-11.md` (#724). It found that Agents is built for one person: one grant for every client, no people, no audit trail, no admin policy. The defects it found that matter to the alpha are filed separately (#726–#729) and come before anything here.

## Decisions so far (Alex, 2026-10-11)

| Question | Answer |
|---|---|
| Tenancy | **Both, self-hosted first.** One org per control plane now, shaped so a hosted multi-org service needs no migration later. |
| Who sees and drives a host | **Its owner only, unless shared.** A shared server can be opened to the team or to named people. Admins manage people and policy; they do not drive other people's hosts. |
| Identity | **Google and Apple**, through generic OpenID Connect (OIDC), so Okta and Entra fit the same slot. |
| Admin policy | **From the control plane.** Hosts enforce it. MDM only pins which control plane a Mac must join. |

## Summary

- **Ten specs in three tiers**, after the alpha fixes:
  - **Team** (T1–T4): people and roles, sign-in with Google and Apple, who-did-what, key lifetimes.
  - **Enterprise** (T5–T9): policy, org keys and model gateways, fleet operations, data governance, SCIM.
  - **Hosted** (T10): many orgs on one service.
- **The control plane already has most of the shape.**
  - `people/<id>.json` exists, and every record carries an `owner` (FR-012). Nothing reads `owner` yet; T1 makes it real.
  - Every store key already sits under a `<prefix>/v1/` set when a copy starts (`contracts/store.md`). **One org = one prefix**, so T10 routes a request to its org's prefix and the records inside are unchanged.
- **The first slice is T1 + T2:** a second person can join a control plane by signing in with Google or Apple. They see only their own hosts and the servers shared with them.

## The tiers

### Team tier: a few people share a control plane

**T1 · People, roles and ownership** (spec)
- **People and roles.**
  - A `Person` gains a role: `admin` or `member`.
  - Today's single person becomes the first admin, by a migration that only adds fields.
- **Clients and hosts belong to a person.**
  - A client is bound to a person at pairing.
  - A host is owned by the person who enrolled it.
  - Every record's `owner` is checked on every call.
- **Sharing a host.** A host can be shared with the team or with named people. Each share carries a level:
  - **see:** its agents and transcripts, read only;
  - **drive:** start agents, answer cards, open terminals.
  - A developer's Mac is unshared by default.
- **What each role may do.**
  - **Admins:** invite, remove and change roles of people; see every host's name and status, but not its contents unless it is shared with them; set policy (T5).
  - **Members:** pair their own clients, enrol their own hosts, share them.
- **Removing a person** forgets their clients at once and takes their hosts off the control plane. Shares they were given end.
- **Retires #111's one grant for a team.** For one person nothing changes: the only person is an admin who owns everything.
- **On screen, all three clients:**
  - Settings gains People.
  - A host's menu gains Share.
  - The sidebar shows shared hosts in a group of their own, named for their owner.

**T2 · Sign in with Google and Apple** (spec)
- **Sign-in becomes the way a person joins or pairs another client.** Codes stay for a control plane with no identity provider, and for hosts.
- **The client does the OIDC sign-in itself; the control plane only checks the result.**
  - **Mac and iPhone/iPad:** `ASAuthorizationAppleIDProvider` for Apple; Google through `ASWebAuthenticationSession` with PKCE.
  - **Result:** an ID token, sent over the R6 socket.
  - **The control plane checks:**
    - the signature, against the provider's published keys (JWKS), fetched and cached;
    - `iss`, `aud` and expiry;
    - that `nonce` equals a hash of this control plane's key id and the R6 hello nonce. A token minted for one control plane cannot be replayed to another.
- **The audience is the app's own client ids** (Alex's Google OAuth client and Apple bundle and Services ids). So a self-hosted control plane needs **no registration of its own** with Google or Apple. It only needs to reach their key endpoints.
- **Who may join:**
  - **Google:** anyone whose `hd` claim is a domain the admin allowed (Workspace accounts only), or anyone invited by email.
  - **Apple:** by invite only. Apple gives no org claim, and may hide the email behind a relay address. An invite is a code the person redeems once, signed in, binding their Apple `sub`.
  - Every person is keyed by `(iss, sub)`, never by email.
- **The web page:**
  - It cannot use the app's Google or Apple redirect on an arbitrary self-hosted domain. It pairs as today, from a code shown on a signed-in client, and the code makes it that person's client.
  - An org that registers its own OIDC client (T9) gets direct web sign-in.
- **Generic OIDC from the start:** a provider is `issuer + client id`, so Okta and Entra are configuration, not code. That configuration is an enterprise-tier setting (T9).

**T3 · Who did what** (spec)
- **Every host-side action carries its actor:** the person, the client and the time. That means starting, stopping or deleting an agent, answering a permission card, changing a setting, approving a workflow, plugin or MCP server, and sharing a host.
- **The actor comes down with the call.** The control plane stamps it; the host does not trust a client to name itself.
- **Where it is kept:**
  - Control-plane events are kept for a configurable time (default 90 days, up from 7).
  - Host events go into `events.jsonl` with the actor.
- **Admins get a read-only Activity ▸ Audit page and a JSON-lines export.**
- **Not this spec:** tamper-evidence (a hash chain, an external sink). It is enterprise tier (T8).

**T4 · Key lifetimes**
- **Expiry.** Client and host keys get an expiry: 90 days by default, renewed silently while in use. A client signed in by OIDC renews only while the person's sign-in still holds; a removed Workspace account stops renewing.
- **Rotation.** The control key can be rotated without re-pairing anyone. Members accept a new key signed by the old one over R6.
- **Spec 058 FR-013** (two grants) is rewritten to match T1.

### Enterprise tier: an org's IT and security teams sign off

**T5 · Policy from the control plane** (spec)
- **One policy document, set by admins and pushed to every host.** Hosts enforce it. It covers:
  - a mode ceiling (`ModeLooseness`);
  - a required sandbox;
  - allowed runtimes and models;
  - a marketplace allowlist;
  - cost and token budgets per person and per day, counting subscription runtimes by tokens;
  - helper caps;
  - an environment pass-through list (builds on #727);
  - a kill switch that pauses every workflow and stops new agents.
- **Every setting already checks a person's ceiling.** Policy becomes the ceiling above it, and a refused choice says "set by your organisation".
- **An offline host keeps the last policy it had**, and refuses to loosen without it.
- **MDM** (Mac, a configuration profile) and **`/etc/agents/policy.json`** (Linux) carry only two things: the control plane's address and pin, and "must join". A host that must join and hasn't runs nothing.

**T6 · Org keys and model gateways** (spec)
- **Each runtime gains a "how it reaches the model" setting:**
  - personal subscription (today);
  - org key;
  - gateway: Bedrock, Vertex, Azure, or a base URL.
- **Policy can require the org path.**
- **Org keys are kept by the control plane, sealed to each host's key.** They never go in the store (store rule 7) and are never shown to members.
- **The sign-in relay stops clearing** `CLAUDE_CODE_USE_BEDROCK`/`_VERTEX` and `ANTHROPIC_BASE_URL` when policy names a gateway.
- **Antigravity's terms notice** becomes a policy switch an admin can turn off.

**T7 · Fleet operations**
- **Corporate networks:** proxy support in the control dial (system, PAC, `HTTPS_PROXY`) and a custom CA in Release builds.
- **Releases:** a published control-plane container image with signatures and an SBOM.
- **Version checks:** a protocol version in every hello, refused clearly when skewed.
- **Operations:** Prometheus metrics and structured logs on `agents-control`.
- **Updates:** auto-update for Agents Host that never asks for admin rights (Alex: hosts never escalate).
- **Platform:** an n-1 macOS and iOS floor once 28 ships.

**T8 · Data governance**
- **Redaction:** known token shapes are redacted at write time in transcripts and `daemon.log`.
- **Erasure:** Delete removes the runtimes' own session files and server copies.
- **Export:** an agent or a project can be exported and imported.
- **Audit sinks:** a hash chain on events, and syslog/HTTP sinks.
- **A compliance pack in `docs/`:** a data-flow diagram, sub-processors (each runtime's vendor, iCloud, the store's host), a privacy policy and a security overview.

**T9 · Org identity**
- **Bring your own provider:** an admin configures OIDC (Okta, Entra, Google with an org's own client), which also gives direct web sign-in.
- **SCIM 2.0:** joiners and leavers come from the provider, and groups map to roles and shares.

### Hosted tier

**T10 · Many orgs on one service** (with #59–#61)
- **An org is a store prefix.**
  - A copy serves many prefixes and routes each connection by host name (`<org>.agents.…`) to its org.
  - Leases, codes and events stay per prefix.
- **Separate per org:** the control key, the policy and the providers.
- **The hosted tier adds:** billing, sign-up, per-org limits and the operations of running it.
- **T1–T9 change nothing for it:** nothing outside the prefix names an org.

## Order

1. **The alpha and its fixes** (#726–#729), as direction says.
2. **T1 + T2 together:** the smallest thing a second person can use.
3. **T3, then T4.**
4. **Enterprise:**
   - T5 first: the rest hang off policy.
   - T6 and T8 next.
   - T7 piece by piece.
   - T9 when a provider other than Google or Apple is asked for.
5. **T10,** when the hosted cloud is unparked.

## Still to decide

- **Direction.** Should the team tier become a goal in `direction.md` after the alpha? (Not changed here.)
- **Google and Apple client ids.** T2 needs a Google OAuth client and a Sign in with Apple Services id under Alex's accounts. Creating them is Alex's to do.
- **Whether admins may see shared-to-team hosts' transcripts by default.** T1 says only if shared with them.
- **Budgets for subscription runtimes.** Counting tokens rather than money (T5) needs every runtime to report tokens, and #395 found not all do.
