# Data model: Enterprise T9, org identity

All keys are under `<prefix>/v1/`, as in `specs/058-control-plane/contracts/store.md`. Every record keeps `rev` and the tombstone fields (rules 10 and 11), and keeps the fields it does not know (`Extra`). Plain JSON files only. No record of spec 736 moves; T9 only adds fields and keys.

## Org provider (`signin/providers/<id>.json`)

| Field | Type | Notes |
|---|---|---|
| `id` | string | lower-case, `[a-z0-9-]{2,32}`, chosen from the name (`acme-okta`). It is the `provider` of each `SignIn` it makes, so it never changes |
| `name` | string | shown on buttons ("Acme Okta"), 1 to 40 characters |
| `preset` | `"okta"` \| `"entra"` \| `"googleWorkspace"` \| `"oidc"` | fills the defaults in the Console only |
| `issuer` | string | an `https` URL. Its discovery document must have `issuer` equal to it |
| `clientID` | string | |
| `accountClaim` | string | `sub` (default), `oid` (Entra), or another claim |
| `tenant` | string? | Entra: the `tid` to require |
| `scopes` | `[string]` | `openid` is always in it |
| `join` | `"scim"` \| `"anyone"` \| `"invite"` | D10 |
| `on` | bool | |
| `order` | int | on the sign-in screen |
| `secret` | `{fingerprint, setBy, setAt}` | the value is in the `.secret.json`; the fingerprint is the first 8 hex of SHA-256 |
| `scim` | `{on, match: "externalId" \| "userName"}` | |
| `discovery` | `{authorizationEndpoint, tokenEndpoint, jwksURI, readAt}` | the cache of the discovery document, read again each hour |
| `version` | int | + 1 on each change |
| `created`, `changed` | Stamp + user | |

**States**: `off ⇄ on`; `→ removed` (tombstone). At most 5 that are not removed.

## Org provider secret (`signin/providers/<id>.secret.json`)

`{sealed: {keeper, wrappedKey, nonce, ciphertext, sealed}}` from `kms.SealFor`, bound to this record's store key. Never readable without the keeper.

## OIDC state (`oidc/state/<id>.json`)

`{id, provider, purpose: "pair" | "addToMe", returnTo: "app" | "web", challenge, verifier, nonce, loginHint?, person? (addToMe), made, ends (10 min)}`. The `id` is the `state` parameter (128 random bits, base64url). It is spent by a create-only `oidc/state/<id>.used`. Swept after 1 hour.

The PKCE verifier and the nonce are secrets for 10 minutes. They are sealed with the keeper as for the provider secret, so that the store has no value that can finish a flow.

## Sign-in ticket (`oidc/tickets/<id>.json`)

`{id, provider, account, email?, name?, challenge, purpose, returnTo, person? (addToMe), made, ends (2 min)}`. The `id` is the ticket (128 random bits). It is spent by a create-only `oidc/tickets/<id>.used`. Swept after 1 hour.

## Domain claim (`signin/domains/<domain>.json`)

`{domain, provider, token, state: "notProved" | "proved", lastGood?, failingSince?, sendHere: bool, require: bool, by, at}`. The key is the domain in lower case, so one domain has one provider (written with `absent`).

## SCIM token (`scim/tokens/<id>.json`)

`{id, provider, name, sha256, made: {by, at}, ends?, lastUse?: {at, address}, revoked?: {by, at}}`. The value is `agscim_` and 32 random bytes in base64url. It is shown once and not kept. `lastUse` is written at most once a minute.

## Person (`people/<id>.json`, extended)

| Field | Type | Notes |
|---|---|---|
| `scim` | `{provider, externalId?, userName, name?: {givenName?, familyName?, formatted?}, displayName?, emails?: [{value, type?, primary?}], active, extra?}` | absent for a person SCIM did not make. `extra` keeps the Enterprise User extension as it came |
| `provisioned` | bool | true until the first sign-in links a `SignIn` |
| `suspended` | `{by: "scim" \| "refresh" \| <user>, provider, at, why}`? | D13 |
| `roleFrom` | `[group id]` | the groups that give the role. Absent = the role was set by hand |
| `lastNames` | `[{userName, until}]` | the match values before a rename, for 90 days |

**Index**: `scim/<provider>/users/<sha256(match value)>.json` → `{user}`, written with `absent`, so one value has one person. `scim/<provider>/names/<sha256(userName)>.json` → `{user}`, for the `409` on a second `userName`.

**States**: `provisioned → active` (first sign-in); `active ⇄ suspended`; `→ removed` (spec 736).

## Group (`groups/<id>.json`, extended)

- `source`: `{scim: <provider>, externalId?, displayName}`. Absent for a group an admin made.
- `role`: `"admin"` or absent (**Gives the admin role**).
- `members`: as spec 736. For a SCIM group, only SCIM writes it.

**Index**: `scim/<provider>/groups/<sha256(displayName)>.json` → `{group}`.

## Refresh token (`signin/refresh/<person>/<provider>.json`, Q1 answer A)

`{sealed, lastGood, failingSince?}`. Sealed as the provider secret, bound to its store key. Deleted when the sign-in is removed or the person is removed.

## Audit entry (`events/<day>/<ulid>.json`, extended)

- `actor` gains `{scim: {provider, token}}` for a SCIM write, and `{refresh: {provider}}` for a suspension by Q1.
- New actions: `signIn.orgProvider.set`, `.remove`, `.secretReplaced`, `signIn.domain.claim`, `.proved`, `.failed`, `.remove`, `scim.token.make`, `.revoke`, `scim.user.create`, `.change`, `.suspend`, `.unsuspend`, `.delete`, `scim.group.create`, `.change`, `.delete`, `group.role.set`, `signIn.org.join`, `.pair`, `.add`, `signIn.refusedByRequire`, `person.suspended`, `person.unsuspended`.

## Wire types (`Packages/Wire/daemon.schema.json`)

`OrgProvider`, `OrgProviderPreset`, `OrgProviderJoin`, `DomainClaim`, `SCIMToken` (no value), `SCIMTokenMade` (with the value, once), `PersonSCIM`, `PersonSuspended`, `GroupSource`, and `SignInProviders.orgProviders: [{id, name, order}]`. `Person` and `Group` gain the fields above.
