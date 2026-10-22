# Research: Enterprise T9, org identity

2026-10-21. What the code has today, what Okta, Entra and Google Workspace need, and why each decision in `spec.md` is the one it is.

## R1. Where the code is today

- **Sign-in settings**: `v1/signin.json` (`signInSettings`, `Go/internal/controlplane/signin.go:31`) holds `google {on, allowedDomains}`, `apple {on}` and `github {on, allowedOrgs}`. There is no `others` list yet; spec 736's data model names it. T9 adds the org providers as their own records (`v1/signin/providers/`), not inside `signin.json`, because each has a sealed secret and a `version`.
- **ID-token check**: `Go/internal/controlplane/signin/oidc.go`, written by hand (go-oidc is not in `go.mod`). `OIDC.Check` checks RSA JWKS, `iss`, `aud`, `exp` with `Skew`, and the nonce. `key`/`fetch` keep the JWKS for 1 hour and fetch again at most once a minute for an unknown `kid`. `GoogleOIDC` and `AppleOIDC` are fixed issuers. T9 adds an `OIDC` per org provider from its discovery document, and ES256 keys (Okta and Entra sign with RS256 by default; some tenants choose ES256).
- **Providers**: `signin/config.go` has `Providers = {Apple, Google, GitHub}`; `OIDCFor` returns nil for any other id, and `outsideProvider` (`signin.go:199`) accepts only those. T9 widens both to the org provider ids.
- **Pairing**: `signIn/pair` is answered on the `s:` sign-in connection (`pairing` :511, `pair` :575). The challenge for `signIn/addToMe` is kept in memory per copy (`challenges`, :83). T9's flow crosses a browser redirect, which can land on another copy, so its `state` and its ticket are store records.
- **People**: `records/people.go` (`SignIn` :36, `Person` :46, `IsAdmin`, `ChangePeople`). Removal: `people.go` `removePerson` :309, `removePreview` :361.
- **Key renewal (T4)**: `keylife.go` (`renewClient` :64). T9 adds the check of D9 and Q1 here.
- **Audit (T3)**: `auditing.go` (`actorFor`, `audited`) and `audit/audit.go` (`Action`, `Log.Write`). T9 adds an actor kind `scim`.
- **Sealing**: `Go/internal/controlplane/kms` (`SealFor`, `OpenFor`, bound to a store key). User secrets use it (`usersettings/usersettings.go`).
- **HTTP**: `service.go` `serveHTTP` (:884) serves `/healthz`, `/readyz`, `/v1/install.sh`, `/v1/servers/*`, `/v1/toolsets/*`, `/v1/join`, `/v1/connect`, and gives anything else to the web page (`web/public.go`, at the origin of `AGENTS_CONTROL_URL`). T9 adds `/v1/oidc/start`, `/v1/oidc/callback` and `/scim/v2/`.
- **Clients**: the Mac's `App/Sources/Control/ConnectSheet.swift`; the Remote's `Remote/Sources/Link/PairingView.swift`; `Shared/UI/SignIn/` (`SignInButtons` runs Google with PKCE in `ASWebAuthenticationSession`); the web's `Web/src/model/signIn.ts` and `Web/src/views/Pairing.tsx`. The Remote has the URL scheme `agents` (`project.yml:220`).
- **Console**: `Web/src/views/ConsoleApp.tsx` and `Web/src/model/console.ts` (sections Overview, People and Groups, Machines, Report Policy, Team Workflows, Requests, Audit). T9 adds **Sign-In** in the Organisation group.
- **Error codes**: free in `-32060`…`-32099` on 2026-10-21: `-32069`, `-32071`, `-32072`, `-32075`…`-32079`, `-32082`…`-32089`, `-32099`. T5 and T6 may take some first; the lane checks again.

## R2. Who runs the OIDC flow (D2, D3)

- **Decision**: the control plane is a confidential client with the code flow, PKCE S256, `state` and `nonce`, and a redirect URI on its own HTTPS address. The client gets a ticket bound to its connection's challenge.
- **Why**:
  - The organisation registers the client for this control plane's redirect URI. An ID token for that client is useless at any other control plane: its `aud` is this organisation's client, and no other control plane has that client's secret. So the replay that spec 736 R3 guards against for GitHub cannot happen.
  - One flow serves the Mac, the Remote and the web page. The web page has no other way to sign in directly (spec 736 FR-014).
  - The token exchange needs the secret, which stays on the control plane.
- **Rejected**:
  - **The client signs in as with Google (public client, ID token over R6).** Each native app would need its own registration at the provider, with a redirect URI to the app. Okta and Entra allow that, but it doubles the admin's work, and the web page still needs the server flow.
  - **Pass the ID token to the client.** It would let a client carry a token that names the person; nothing needs it. The ticket pairs and is gone.
  - **A cookie session for the web page.** The web page is a client with a key, as today (spec 058). A cookie would be a second kind of client.

## R3. Presets

| Preset | Issuer | Account claim | Extra check | Scopes |
|---|---|---|---|---|
| Okta | `https://<org>.okta.com` or `https://<org>.okta.com/oauth2/<server>` | `sub` (the Okta user id, `00u…`) | none | `openid email profile offline_access` (Q1 A) |
| Entra | `https://login.microsoftonline.com/<tenant id>/v2.0` | `oid` (Entra's `sub` is different for each app) | `tid` equals the tenant id | `openid email profile offline_access` |
| Google Workspace | `https://accounts.google.com` | `sub` | `hd` is a claimed domain | `openid email profile` (Google gives a refresh token with `access_type=offline` and `prompt=consent`) |
| Other OIDC | any | `sub` (the admin can change it) | none | `openid email profile` (and `offline_access` if the discovery document lists it) |

Entra's `email` claim is optional and is not checked by Entra; D9 reads it to show and to match a domain, never to identify a person. The lane that builds slice 1 measures each preset on Alex's tenants (the account steps in the report).

## R4. What Okta and Entra send by SCIM

From the vendors' SCIM docs (Okta: "SCIM 2.0 protocol reference"; Microsoft: "Develop and plan provisioning for a SCIM endpoint"). The lane records real requests on Alex's tenants and keeps them as test fixtures (`Go/internal/controlplane/scim/testdata/`).

| Request | Okta | Entra |
|---|---|---|
| Find a user | `GET /Users?filter=userName eq "x"&startIndex=1&count=100` | `GET /Users?filter=userName eq "x"`, also `externalId eq` |
| Create | `POST /Users` | `POST /Users` |
| Change | `PUT /Users/<id>` (profile) and `PATCH` (`active`) | `PATCH` with `Operations` `add`, `replace`, `remove`, paths like `name.givenName`, `emails[type eq "work"].value`, and `active` as `"False"` (a string) in some tenants |
| Leave | `PATCH active: false` (Okta never deletes by default) | `PATCH active: false`, then `DELETE` after the soft-delete time |
| Groups | `POST /Groups`, `PATCH` members `add`/`remove`, `PUT` (Okta "push groups") | `POST /Groups`, `PATCH members` `add`/`remove` with `value`, `GET /Groups?filter=displayName eq "x"&excludedAttributes=members` |
| Errors it expects | `409` on a second `userName`, `404` with the SCIM error schema | the same, and `400 invalidFilter` |

- **Decision**: the endpoints in D11. Accept `active` as a boolean or the strings `"True"`/`"False"`. Accept a `PATCH` with no `path` (a whole object in `value`). Support `excludedAttributes=members`.
- **Rejected**: `Bulk`, sort, ETags. Neither vendor needs them; `ServiceProviderConfig` says they are not supported.

## R5. Matching a SCIM user to a sign-in (D5, FR-016)

- **Decision**: the provider's match attribute: `externalId` by default, or `userName`, must equal the sign-in's `account` claim.
- **Okta**: Okta sends `externalId` only when the app's mapping sets it. The admin maps `externalId` to `user.id` (the same value as `sub`) in Okta, or picks `userName` here and sets `preferred_username` as the account claim. The how-to shows the first way.
- **Entra**: Entra maps `externalId` to `mailNickname` by default. The admin changes that mapping to `objectId`, which equals the `oid` claim. The how-to shows it.
- **Why**: an email is not stable and Entra does not check it. An id that the provider keeps for life is the only safe key, and the match is only inside one provider.
- **Rejected**: match by email. It is the attack spec 736 FR-001 shuts out: a person with an unchecked email could take another person's account.

## R6. Suspension (D13)

- **Decision**: suspend at once; delete only after an admin confirms.
- **Why**: a provider's deactivation is the organisation's IT team saying "now". A delete of started machines loses work that is not pushed (spec 736 FR-029 asks an admin to see the list first). Okta never sends `DELETE` by default, and Entra sends it 30 days after a soft delete, so the admin's step is rare.
- **What "their sessions end" means**: every client connection of the person closes with `4403 suspended` (as `control/cutOff` does today), their keys stop renewing (T4), and on their machines their running turns stop and their workflows pause (the T5 kill switch, for one user). Agents and conversations stay.
- **Rejected**: delete on `DELETE`. Rejected: suspend only the clients and leave agents running. A leaver's workflow that keeps running with the organisation's keys (T6) is the risk the security team names first.

## R7. Testing without a real tenant

- A **fake OIDC provider** on loopback in Go tests (`signin/signintest`, extended): discovery, JWKS (RS256 and ES256), authorize (auto-consent, returns a code), token (checks PKCE and the secret, returns an ID token and a refresh token), and a switch to answer `invalid_grant`.
- A **fake DNS** resolver behind an interface, for the TXT checks.
- **SCIM**: the recorded Okta and Entra requests (R4), played in order against a scratch control plane with two copies.
- Real tenants (Okta developer edition, an Entra tenant, a Google Workspace) are Alex's account test, later (#1782). It holds nothing.

## R8. Leavers without SCIM (Q1)

- **Option A (recommended)**: keep the refresh token sealed; refresh at each key renewal and daily; `invalid_grant` suspends; 7 days of grace when the provider is down.
  - Okta: a refresh token lives until the person is deactivated or the token's policy ends it. Entra: a refresh token is refused when the account is disabled or its sessions are revoked. Google: a refresh token is refused when the Workspace account is suspended.
  - Cost: one sealed record per person per provider, and one token call per person per day.
- **Option B**: no refresh token. A leaver keeps access until their keys end (up to 90 days) or an admin removes them, unless SCIM is on.
- The spec is written with A. If B is chosen, FR-024 and US6 go, and the docs say "turn on SCIM to find leavers".

## R9. Domain proof (D8)

- **Decision**: a TXT record `agents-domain=<token>` at `_agents.<domain>`, with a random token of 128 bits made for each claim. Checked at **Check** and daily; 7 days of failures drop the claim.
- **Why**: a claim changes how other people sign in (D9). DNS is the proof that Google Workspace, Okta and Slack use. A daily check finds a domain that the organisation lost.
- **Rejected**: an email to `admin@<domain>`. It needs mail on the control plane, and proves less.
