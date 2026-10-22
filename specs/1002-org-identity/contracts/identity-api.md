# Contract: org identity methods, HTTP routes and SCIM

These change `Packages/Wire/control.openrpc.json` and `daemon.schema.json` first, then `scripts/wire.sh gen` (#1135).

**Who may call** (as spec 736): **any** (a signed-in client, for itself), **admin**, **pairing** (the `s:` sign-in connection, no key yet).

## Control-plane methods

| Method | Who | Shape |
|---|---|---|
| `signIn/providers` | pairing, any | gains `orgProviders: [{id, name, order}]` and `discover: bool` (a domain sends people) |
| `signIn/discover` | pairing, any | `{email}` → `{provider?}`: the org provider of a claimed domain with **Send people here** (FR-011). It answers the same for an unknown domain and a domain with no switch |
| `signIn/orgStart` | pairing, any | `{provider, purpose: "pair" \| "addToMe", returnTo: "app" \| "web", loginHint?}` → `{url}`: the `/v1/oidc/start` URL for this connection's challenge |
| `signIn/ticket` | pairing, any | `{ticket, name?, kind?}` → `{client}` (pair) or `{signIn}` (addToMe). Refused with `needsInvite`, `orgSignInRequired`, `personSuspended`. The web page's ticket (`returnTo: web`) is bound to the `s:` id and key it proved, which it proves again on a new connection when it comes back (the same tab closes the first); the app's is bound to its connection. The page on the control plane's own domain takes `s:` on its socket for this |
| `signIn/orgProviders/list` | admin | → `[OrgProvider]` (no secret) |
| `signIn/orgProviders/set` | admin | `{provider: OrgProvider, secret?, rev?}` → `{provider}`. `secret` is write only. Refused with `changedElsewhere` on a stale `rev`, and with the reason of FR-002 |
| `signIn/orgProviders/check` | admin | `{id}` → `{discovery: ok \| missing [..], jwksKeys: n, redirectURI}` |
| `signIn/orgProviders/remove` | admin | `{id}` → `{}` (FR-009) |
| `signIn/domains/list` | admin | → `[DomainClaim]` |
| `signIn/domains/claim` | admin | `{domain, provider}` → `{claim, txtName, txtValue}` |
| `signIn/domains/check` | admin | `{domain}` → `{claim}` |
| `signIn/domains/set` | admin | `{domain, sendHere?, require?}` → `{claim}`. `require` needs a proved domain |
| `signIn/domains/preview` | admin | `{domain, require: true}` → `{people: [{user, name, signIns: [{provider, email}]}]}` (FR-012) |
| `signIn/domains/remove` | admin | `{domain}` → `{}` |
| `scim/tokens/list` | admin | `{provider}` → `[SCIMToken]` |
| `scim/tokens/make` | admin | `{provider, name, ends?}` → `SCIMTokenMade` (the value, once). Refused when two are live |
| `scim/tokens/revoke` | admin | `{id}` → `{}` |
| `scim/set` | admin | `{provider, on, match}` → `{provider}` |
| `groups/setRole` | admin | `{group, role: "admin" \| null}` → `{group}` (FR-020, FR-021) |
| `people/list` | any | each person gains `scim?`, `provisioned`, `suspended?`, `roleFrom?` |
| `people/setRole` | admin | refused with `managedByProvider` for a person with `roleFrom` |

## Notifications

| Notification | To | Shape |
|---|---|---|
| `control/cutOff` | every client of a suspended person | `{why: "suspended", provider}`, then close `4403 suspended` |
| `control/peopleChanged` | admins, and the person changed | as today; also on SCIM writes |
| `control/notice` | admins | `{kind: "lastAdminKept" \| "domainLost" \| "groupSharesOrphaned" \| "removeRequested", …}` |

## Channel 0, machine ↔ control plane

| Message | Direction | Shape |
|---|---|---|
| `user/suspended` | → machine | `{user, off?: true, provider, at}`. Sent on hello before user settings, and within 5 s of a change, on every copy (FR-018) |
| `host/hello` | machine → | gains capability `host.suspend.1`. A machine without it, whose user is suspended, is refused at hello with `personSuspended` |

## HTTP routes (on the HTTPS address)

| Route | Shape |
|---|---|
| `GET /v1/oidc/start?s=<state id>` | made by `signIn/orgStart`. `302` to the provider's authorization endpoint with `response_type=code`, `client_id`, `redirect_uri`, `scope`, `state`, `nonce`, `code_challenge`, `code_challenge_method=S256`, `login_hint?` |
| `GET /v1/oidc/callback?code&state` | checks the state, exchanges the code (`client_secret_basic`, or `client_secret_post` if the discovery document lists only it), checks the ID token, makes the ticket. Then `302` to `agents://oidc#ticket=<t>` (Mac, Remote) or to `/#oidc-ticket=<t>` (web). On a provider error, the same with `error=<code>`. Headers: `Cache-Control: no-store`, `Referrer-Policy: no-referrer` |

## SCIM 2.0 (`/scim/v2/`)

`Content-Type: application/scim+json`. Auth: `Authorization: Bearer agscim_…` (D12). The token decides the provider; a resource of another provider answers `404`.

| Route | Methods | Notes |
|---|---|---|
| `/ServiceProviderConfig` | GET | `patch: true`, `bulk: false`, `filter: {supported: true, maxResults: 100}`, `changePassword: false`, `sort: false`, `etag: false`, `authenticationSchemes: [oauthbearertoken]` |
| `/ResourceTypes`, `/Schemas` | GET | User (with the Enterprise extension), Group |
| `/Users` | GET, POST | GET: `filter` with `eq` on `userName`, `externalId`, `emails.value`; `startIndex`, `count` (at most 100); `attributes`, `excludedAttributes` |
| `/Users/<id>` | GET, PUT, PATCH, DELETE | PATCH `add`, `replace`, `remove`; `active` as a boolean or `"True"`/`"False"`. DELETE suspends and asks an admin (D13); answers `204` |
| `/Groups` | GET, POST | GET: `filter` with `eq` on `displayName`, `externalId`; `excludedAttributes=members` |
| `/Groups/<id>` | GET, PUT, PATCH, DELETE | PATCH `members` `add` / `remove` (by `value`, or a filter `members[value eq "x"]`), `replace` `displayName` |

**Errors** (RFC 7644 §3.12): `400 invalidFilter`, `400 invalidValue`, `400 invalidSyntax`, `401`, `404`, `409 uniqueness`, `413` (a body over 1 MiB), `429` (more than 50 requests a second for one token, with `Retry-After`), `501` (Bulk, sort, `/Me`).

## Failures (JSON-RPC)

| Code | Name | Meaning |
|---|---|---|
| `-32077` | `orgSignInRequired` | a built-in sign-in at a required domain (FR-012), with `{provider, name}` |
| `-32078` | `personSuspended` | the person is suspended (D13), with `{provider}` |
| `-32079` | `managedByProvider` | a role or a group member that a provider controls, with `{provider}` |
| `-32082` | `orgProviderUnavailable` | no keeper, no HTTPS address, or a discovery document that does not do what is needed, with `{reason}` |

`signInUnavailable`, `needsInvite` and `changedElsewhere` are reused. The numbers are the ones `Packages/Wire` gives: slice 1 moved them past the ones T5 and T6 took.
