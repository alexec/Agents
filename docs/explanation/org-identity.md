---
diataxis: explanation
description: How an organisation's own sign-in provider, its tickets, its claimed domains, SCIM and suspension work on the control plane, and what they do not protect against.
---

# Org identity

An organisation keeps its people in its own identity provider: Okta, Microsoft Entra ID,
Google Workspace with a client of its own, or any other OpenID Connect provider. An admin
can add it to the control plane as an **org provider**. People then sign in with it, beside
Google, Apple, GitHub and the local owner (spec 1002, #1002). This page tells how that
works, and why.

A control plane with no org provider works as before. Nothing on any screen changes.

## An org provider is one more sign-in

An org provider is an OIDC issuer, a client id, a client secret, a name to show, and the
claim that names a person. The control plane reads everything else from the issuer's
discovery document, `/.well-known/openid-configuration`, again each hour. Okta, Entra and
Google Workspace are the same kind of provider with different values. The presets only
fill in the form:

- **Okta**: the account is `sub`, the Okta user id.
- **Entra**: the issuer is `https://login.microsoftonline.com/<tenant id>/v2.0`, the account
  is `oid` (Entra's `sub` is different for each app), and an ID token must have the tenant's
  `tid`.
- **Google Workspace**: the issuer is `https://accounts.google.com`, and the ID token's `hd`
  must be one of the provider's proved domains.

A sign-in with an org provider is a sign-in such as any other: `(provider id, account)`.
The control plane never matches a person by email across providers. A person can have an
org sign-in and a Google sign-in, and the local owner's sign-in always stays.

An admin chooses **Who may join** for each provider:

- **Only by invite** (the default): a person nobody knows is told to ask an admin for an
  invite. With the invite, they pair with its code and then add the org sign-in.
- **Anyone the provider signs in**: the provider's own assignment of the app is the gate.
  A new person joins as a member.
- **Only people from SCIM**: only a person the provider added by SCIM signs in. Anybody
  else is told that the organisation has not added them yet. With SCIM off, it acts as
  **Only by invite**.

There are 5 org providers at most. A removed provider keeps its id, so that a new provider
with another issuer can never take over its sign-ins.

## Where the client secret is

The control plane keeps two objects for each provider in its store:

- `v1/signin/providers/<id>.json`: the provider, with no secret. For the secret it has only
  who set it, when, and its fingerprint, the first 8 hex digits of its SHA-256.
- `v1/signin/providers/<id>.secret.json`: the client secret, sealed with the keeper for
  secrets and bound to this store key, as [org keys](org-keys-and-gateways.md) are.

Nobody can read the secret back, also not an admin. A control plane with no keeper for
secrets refuses to save an org provider. So does a control plane with no HTTPS address,
because the provider must be able to send the browser back to it.

## The control plane signs in, and gives a ticket

The control plane is the provider's client, not the app. The flow is the authorization code
flow with PKCE (S256), `state` and `nonce`, in this order:

- A client asks `signIn/orgStart` on its connection. The control plane keeps a **state**
  in the store for 10 minutes: the provider, what it is for, and a hash of the connection.
  The PKCE verifier and the nonce in it are sealed with the keeper.
- The client opens `/v1/oidc/start` in a browser. The control plane sends the browser to the
  provider.
- The person signs in at the provider, with its multi-factor and its device checks.
- The provider sends the browser to `/v1/oidc/callback`. The control plane spends the
  state (once), exchanges the code with the client secret and the verifier, and checks the
  ID token: its signature by the provider's keys (RS256 or ES256), `iss`, `aud`, the
  expiry, the nonce, and `tid` or `hd` for the presets.
- It makes a **ticket**, which lasts 2 minutes, and sends the browser back to the client:
  to `agents://oidc` for the Mac and the Remote, or to the web page. The ticket is in the
  address's fragment, which no server sees.
- The client sends the ticket with `signIn/ticket` on the connection that started the
  flow. That pairs the connection, or adds the sign-in to the client's person.

Why it is made this way:

- **The organisation registered the client for this control plane only.** An ID token for
  that client is no good at another control plane, which has neither the client's secret
  nor the state.
- **No token leaves the control plane.** The ID token, the access token and the refresh
  token are checked and forgotten. The client gets only the ticket.
- **A ticket is good on one connection, once, for 2 minutes.** It is bound to a hash of the
  sign-in connection's challenge, or of a paired client's session and person. Shown on
  another connection, it is refused and not spent. The control plane keeps the state and the
  ticket under the SHA-256 of their values, so a listing of the store does not show them.
- **Any copy can finish the flow.** The state and the ticket are store records. The
  callback can come to another copy than the one that started it.
- **The web page signs in directly.** A browser has no other way to sign in without a
  code; with an org provider, the page needs no code and no approval.

## Claimed domains

An admin can claim an email domain for one org provider and prove it with a DNS TXT
record, `agents-domain=<token>` at `_agents.<domain>`. One domain belongs to one provider.
The control plane looks for the record when the admin selects **Check**, and once a day.
When the record is not found for 7 days in a row, the claim goes back to **Not proved** and
its switches go off.

A proved domain has two switches:

- **Send people here**: `signIn/discover` answers with the provider for an email at the
  domain, so a sign-in screen can ask for an email and start the right provider. It answers
  the same for a domain nobody claimed and a domain with the switch off.
- **Require this provider**: a Google, Apple or GitHub sign-in whose email is at the domain
  cannot join, cannot pair a client, and cannot renew a client's key. It is refused with
  `orgSignInRequired` (-32077) and the provider's name. The preview lists the people it
  changes before an admin turns it on.

Clients that are paired keep working until their keys end (90 days at most), so nobody is
cut off by surprise. A person who adds the org sign-in renews again. The local owner is
never refused: the local owner is how the key holder gets back in.

## SCIM adds, changes and suspends people

An admin turns on SCIM for a provider and makes a SCIM token. The provider (Okta, Entra)
then sends its people and groups to `https://<control plane>/scim/v2/`, with the token.

- **The token decides the provider.** The control plane keeps only the token's SHA-256,
  so a store that leaks does not leak the token. Two tokens are live at most, so an admin
  can make the next one before revoking the old one. A request with no live token is
  refused with `401`, and writes nothing.
- **A SCIM user is a person.** The person is **provisioned**: People says **Waiting for first
  sign-in**. When they first sign in with the same provider, the control plane matches them
  by the provider's match attribute, `externalId` (the default) or `userName`, equal to the
  sign-in's account claim. It never matches by email. Map `externalId` to the person's id
  at the provider: Okta's `user.id`, or Entra's `objectId`.
- **A SCIM group is a group.** Only SCIM changes its name and members, and its members are
  people of the same provider. An admin can give it what any group gets, and can mark it
  **Gives the admin role**: its members are admins while they are in it, and go back to the
  role they had before when they leave it. A SCIM change never leaves the control plane
  with no admin: the change to the group is made, the last admin stays an admin, and the
  admins get a notice.

## Suspension

`active: false` from SCIM **suspends** the person. Within 5 seconds, on every copy of the
control plane:

- each of their clients is told `control/cutOff` and closed with `4403 suspended`. The
  client keeps its key, and it is refused with `suspended` while the suspension lasts;
- their keys stop renewing, and their org sign-ins are refused with `personSuspended`;
- each of their machines is told `user/suspended`. A machine that cannot hear it
  (an older Agents) is closed, and refused at hello until it is updated.

Nothing is deleted: their machines, agents, conversations and branches stay. `active: true`
ends the suspension, and their clients connect again.

## What a machine does

A machine that hears `user/suspended` (it says `host.suspend/1` at hello):

- stops the person's running turns at once, with "Stopped. Your organisation's sign-in
  turned your access off." in each chat;
- pauses their workflows: a trigger, a schedule and a queued run are let go, not kept, and
  **Run now** is refused;
- keeps their queued prompts waiting, and refuses a new agent or prompt with
  `personSuspended`;
- cuts off the window on this Mac's direct path, and refuses it there with `suspended`;
- keeps every agent, conversation, branch and file.

It keeps the state in `<root>/suspended.json`, so a restart keeps it until the control plane
says otherwise. `user/suspended {off: true}` ends the pause, and starts nothing by itself:
a queued prompt waits until its person sends again.

The person's started machines in a machine provider are **stopped** through the provider,
never deleted, so they cost nothing. They are not started while the suspension lasts (by
hand, for a kept prompt or for a schedule), and stay stopped after it ends until the person
starts them.

## What an offline machine does

A machine that is off the network cannot hear `user/suspended`, and it runs on until it
connects: hosts never escalate, and the control plane cannot reach it. When it connects, the
control plane says the person's state before anything else, so the machine stops their work
before any workflow starts. A machine that was suspended and restarts offline stays paused,
from `<root>/suspended.json`.

## Removal

SCIM `DELETE` suspends the person too, and adds a **Remove** request for the admins
(`people/removeRequests`). Only an admin removes a person, after reading what work on their
machines is not pushed. The local owner is never cut off: only their org sign-in is refused.

## Leavers without SCIM

At an org sign-in, the control plane asks for a refresh token (`offline_access`, or
`access_type=offline` for Google Workspace) and keeps it sealed with the keeper for secrets,
at `v1/signin/refresh/<person>/<provider>.json`. It uses it when the person's key is about to
renew, at most once an hour, and once a day:

- the provider answers `invalid_grant` (the person was deactivated, disabled, or their
  sessions were revoked): the person is suspended, as above;
- the provider cannot be reached: keys still renew for 7 days after the last good check,
  then stop until a check works.

A Google Workspace sign-in gives a refresh token only the first time a person consents.
Without one, that person is checked at sign-in only.

## What this does not protect against

- **A provider's account is the provider's to guard.** When an organisation's provider signs
  someone in, the control plane trusts it, as it trusts Google for a Google sign-in.
- **A leaver is found as soon as the provider says so, not sooner.** With SCIM, that is
  when the provider sends `active: false`; without it, at the next renewal or the daily
  check. A provider that keeps a person's refresh token valid after they leave is not
  caught without SCIM.
- **An offline machine runs until it connects.** A suspended person's machine that is off
  the network does not hear `user/suspended`. It hears it before anything else when it
  connects (see [What an offline machine does](#what-an-offline-machine-does)).
- **Require reads the email the built-in provider gives.** A sign-in with no email, or with
  Apple's hidden relay address, is not at the domain, and is not refused.
- **A DNS record proves who controls the domain now.** A domain that changes hands keeps
  its claim until the daily check fails for 7 days.

## See also

- [Sign-in providers and the `/v1/oidc` routes](../reference/sign-in.md)
- [People and machines](people-and-machines.md)
- [Org keys and gateways](org-keys-and-gateways.md)
