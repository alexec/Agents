---
diataxis: reference
devices: [mac, iphone, ipad, web]
description: Org sign-in providers, claimed domains, their methods and the /v1/oidc routes on the control plane.
---

# Sign-in providers

The control plane signs people in with the built-in providers (Google, Apple, GitHub, and
the local owner's codes) and with up to 5 **org providers**: an organisation's own OIDC
provider (#1002). Why it works this way: [Org identity](../explanation/org-identity.md).

## An org provider's fields

| Field | What it is |
| --- | --- |
| `id` | 2 to 32 of `a-z`, `0-9` and `-`, made from the name when absent (`acme-okta`). The provider of each sign-in it makes, so it never changes, and a removed provider's id is not used again. |
| `name` | On the button: **Sign in with** *name*. 1 to 40 characters. |
| `preset` | `okta`, `entra`, `googleWorkspace` or `oidc`. Fills the form; only `googleWorkspace` adds a check (`hd`). |
| `issuer` | An `https` address. Its discovery document must name it as `issuer`. |
| `clientID` | The client the organisation registered for this control plane. |
| `accountClaim` | The claim that names a person for life: `sub` (the default), or `oid` for Entra. |
| `tenant` | Entra: the `tid` an ID token must have. Taken from an Entra issuer when absent. |
| `scopes` | `openid` always; `email` and `profile` when none is given. |
| `join` | **Who may join**: `invite` (the default), `anyone`, or `scim` (acts as `invite` until SCIM is built). |
| `on` | Off refuses its new sign-ins. Paired clients go on. |
| `order` | Its place on the sign-in screen, before the built-in providers. |
| `secret` | Who set the client secret, when, and its fingerprint (the first 8 hex of its SHA-256). Never the value. |
| `version` | One more at each change. |
| `redirectURI` | In answers only: `https://<this control plane>/v1/oidc/callback`, to register at the provider. |

The client secret is written with `signIn/orgProviders/set` and never read back. It is
sealed with the keeper for secrets at `v1/signin/providers/<id>.secret.json`.

**Saving or checking** reads the discovery document and refuses one that lacks an
authorization endpoint, a token endpoint and a JWKS address on `https`, the code flow,
PKCE with `S256`, or a client secret at the token endpoint. **Check** also reads the JWKS
and says how many keys it has (RSA and P-256).

## A claimed domain's fields

| Field | What it is |
| --- | --- |
| `domain` | The email domain, in lower case. One domain has one provider. |
| `provider` | The org provider it is claimed for. |
| `state` | `notProved` or `proved`. |
| `txtName`, `txtValue` | The record to add: `_agents.<domain>` with `agents-domain=<32 hex>`. |
| `lastGood`, `failingSince` | When the record was last found, and since when it is not found. |
| `sendHere` | **Send people here**: `signIn/discover` names the provider for an email at the domain. |
| `require` | **Require this provider**: a Google, Apple or GitHub sign-in at the domain cannot join, pair or renew a key. |

A control plane claims 20 domains at most. Both switches need a proved domain. The control
plane checks each proved domain once a day; after 7 days of failures the claim is
`notProved` and both switches are off.

## Methods

**Who may call:** *pairing* is a sign-in connection (`s:`) before it is paired; *any* is a
paired client, for itself; *admin* is an admin's client.

| Method | Who | What it does |
| --- | --- | --- |
| `signIn/providers` | pairing, any | Gains `orgProviders` (`id`, `name`, `order` of each provider that is on) and `discover` (a domain sends people). |
| `signIn/discover` | pairing, any | `{email}` → `{provider?, name?}`. |
| `signIn/orgStart` | pairing, any | `{provider, purpose: pair \| addToMe, returnTo: app \| web, loginHint?}` → `{url}`, the `/v1/oidc/start` address. It ends after 10 minutes. |
| `signIn/ticket` | pairing, any | `{ticket, name?, kind?}` → `{client}` (pair) or `{signIn}` (addToMe). On the connection that started the flow, within 2 minutes, once. To pair, `name` and `kind` (`mac`, `iPhone`, `iPad`, or `browser` for the page's flow). |
| `signIn/orgProviders/list` | admin | Every org provider, with its `rev`. |
| `signIn/orgProviders/set` | admin | `{provider, secret?, rev?}`: add (with `secret`, no `rev`) or change (with the `rev` read). |
| `signIn/orgProviders/check` | admin | `{id}` → `{ok, missing, jwksKeys, redirectURI}`. |
| `signIn/orgProviders/remove` | admin | `{id, rev?}`: the secret is deleted, the record stays as a tombstone, its domain claims go. Its people keep their sign-ins and clients. |
| `signIn/domains/list` | admin | Every claim. |
| `signIn/domains/claim` | admin | `{domain, provider}` → the claim with its TXT record. |
| `signIn/domains/check` | admin | `{domain}`: look for the record now. |
| `signIn/domains/set` | admin | `{domain, sendHere?, require?}`. |
| `signIn/domains/preview` | admin | `{domain}` → the people whose built-in sign-ins at the domain **Require** refuses. Never the local owner. |
| `signIn/domains/remove` | admin | `{domain}`. |

## Failures

| Code | Name | When |
| --- | --- | --- |
| -32077 | `orgSignInRequired` | A built-in sign-in at a domain that requires its org provider. `data` has `provider` and `name`. |
| -32082 | `orgProviderUnavailable` | No keeper for secrets, no HTTPS address, or a discovery document that lacks what the flow needs. |
| -32078 | `personSuspended` | Kept for SCIM (#1002, later). |
| -32079 | `managedByProvider` | Kept for SCIM (#1002, later). |

A person not known, with **Who may join** at `invite`, is refused with -32045 and "Ask an
admin of this control plane for an invite".

## HTTP routes

Both answer `404` on a control plane with no org provider. Every answer has
`Cache-Control: no-store` and `Referrer-Policy: no-referrer`.

| Route | What it does |
| --- | --- |
| `GET /v1/oidc/start?s=<state>` | `302` to the provider's authorization endpoint with `response_type=code`, `client_id`, `redirect_uri`, `scope`, `state`, `nonce`, `code_challenge`, `code_challenge_method=S256`, and `login_hint` when given (`hd` for Google Workspace with one domain). A state that ended answers `400`. |
| `GET /v1/oidc/callback?code&state` | Spends the state, exchanges the code (`client_secret_basic`, or `client_secret_post` when the provider lists only that), checks the ID token, and makes the ticket. Then `302` to `agents://oidc#ticket=<t>` (Mac, Remote) or to `/#oidc-ticket=<t>` (the web page). A refusal goes the same way with `error` and `message` (`oidc-error`, `oidc-message` on the page). An unknown or used state answers `400`. |

## In the store

| Key | What it holds |
| --- | --- |
| `v1/signin/providers/<id>.json` | The provider, or its tombstone (`removed`). |
| `v1/signin/providers/<id>.secret.json` | The client secret, sealed. |
| `v1/signin/domains/<domain>.json` | The claim, and when it was last checked. |
| `v1/oidc/state/<sha256>.json`, `.used` | A started flow, its verifier and nonce sealed; spent once. Swept after an hour. |
| `v1/oidc/tickets/<sha256>.json`, `.used` | A ticket; spent once. Swept after an hour. |

## The audit

Each of these is an entry, with the actor and no secret: a provider added or changed (the
fields changed, and "secret replaced" with its fingerprint), checked or removed; a domain
claimed, checked, proved, changed, lost or removed; each org sign-in (joined, paired, or
added); and each sign-in that **Require** refused.
