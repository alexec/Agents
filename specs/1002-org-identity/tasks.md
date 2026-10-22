# Tasks: Enterprise T9, org identity

**Input**: `spec.md`, `plan.md`, `research.md`, `data-model.md`, `contracts/identity-api.md`, `quickstart.md` in `specs/1002-org-identity/`.

**Tests**: the spec asks for automated checks (SC-001 to SC-006), so each slice has test tasks. Write them first.

**Format**: `[ID] [P?] [Story] Description`. `[P]` means a task can run in parallel with the others of its phase (different files).

**Not before v0.10.0 ships.** Nothing here merges to `main` until then (`hold:v0.10`).

**Slices**: each phase below is one slice of `plan.md`, one lane, with its own areas, tests and walk. Order: 1 → (2a ‖ 3) → (2b ‖ 4).

## Phase 1: Slice 1, org providers and domains on the control plane (area: sign-in; hooks in control-plane and reports)

**Goal**: an admin saves an org provider, and a client on any copy pairs by ticket. Proved domains send people and can require the provider. Covers US1, US2, US3 on the control plane.

### Tests first

- [x] T001 [US1] Test that a control plane with no org provider lists no `orgProviders`, answers `404` on `/v1/oidc/*`, and every spec 736 sign-in test passes unchanged, in `Go/internal/controlplane/signin_org_test.go` (SC-001).
- [x] T002 [P] [US2] Extend the fake provider in `Go/internal/controlplane/signin/signintest/`: discovery, JWKS (RS256 and ES256), authorize with auto-consent, token (checks PKCE and the secret), refresh, and a switch for `invalid_grant` (research R7).
- [x] T003 [P] [US2] Test `signIn/orgProviders/set`: bounds, at most 5, `rev` conflict, `version` + 1, a member refused, no keeper or no HTTPS address refused (FR-002), no method returns the secret, the store holds no secret (bytes, base64, hex), in `signin_org_test.go` (FR-001 to FR-004, SC-005).
- [x] T004 [P] [US2] Test the flow: `signIn/orgStart` → `/v1/oidc/start` → the fake → `/v1/oidc/callback` on the other copy → `signIn/ticket` pairs the first connection. Refused: an unknown or used `state`, a bad signature, `iss`, `aud`, `exp`, `nonce`, `hd` (Google Workspace preset), `tid` (Entra preset), a ticket on another connection, a ticket after 2 minutes, the ID token on a second control plane (FR-005, FR-006, SC-004).
- [x] T005 [P] [US2] Test **Who may join**: `invite` refuses a person not known with `needsInvite`; `anyone` lets them join as a member; `addToMe` keeps one person (FR-008).
- [x] T006 [P] [US3] Test domains with a fake resolver: claim, TXT proof, one domain one provider, the daily check, 7 days of failures drop the claim with a notice, `signIn/discover`, and **Require** at join, pair and renewal with `orgSignInRequired`; the local owner never refused (FR-010 to FR-012).

### Build

- [x] T007 [US2] Add `OrgProvider`, `OrgProviderPreset`, `OrgProviderJoin`, `DomainClaim` and `SignInProviders.orgProviders` to `Packages/Wire/daemon.schema.json`; the `signIn/*` methods of the contract to `control.openrpc.json`; the failures `-32075` to `-32078` (check again that they are free). Run `scripts/wire.sh gen`, commit what it makes, and do what `WireSchemaTests` says.
- [x] T008 [US2] Add `Go/internal/controlplane/signin/discovery.go`: read and cache the discovery document (1 hour), check what FR-004 needs; ES256 in `signin/oidc.go`; an `OIDC` per org provider.
- [x] T009 [US2] Add `Go/internal/controlplane/signin_org.go`: provider records and sealed secrets (`kms.SealFor`, bound to the store key), `signIn/orgProviders/*`, `signIn/orgStart`, `signIn/ticket`, and the `orgProviders` rows in `signIn/providers`. Widen `outsideProvider` and `OIDCFor` to org provider ids.
- [x] T010 [US2] Add `Go/internal/controlplane/identity_oidc_http.go`: `/v1/oidc/start` and `/v1/oidc/callback` (state and ticket records in the store, sealed verifier and nonce, `no-store`, `no-referrer`), the redirect to `agents://oidc` or the web fragment. Route them in `service.go` `serveHTTP`.
- [x] T011 [US3] Add `Go/internal/controlplane/signin_domains.go`: claims, the TXT check behind a `Resolver`, the daily check, `signIn/discover`, `signIn/domains/*`, the preview, and the **Require** check, called from `pairing`, `redeemInvite`, `addToMe` and `keylife.go` `renewClient`.
- [x] T012 [US2] Add the org sign-in, provider and domain actions to `audit.controlActions` in `Go/internal/controlplane/audit/audit.go`, with no secret (FR-025).
- [x] T013 [P] Docs: `docs/explanation/org-identity.md` (providers, tickets, domains); `docs/reference/sign-in.md` (fields, `/v1/oidc/*`); `docs/reference/integrations.md` rows for Okta, Entra, Google Workspace and generic OIDC.

**Checkpoint**: quickstart steps 1 and 2.

## Phase 2: Slice 2a, SCIM and suspension on the control plane (areas: control-plane, team; hooks in reports)

**Goal**: the provider adds, changes and suspends people, and its groups give roles. Covers US4, US5, US6 on the control plane.

### Tests first

- [x] T014 [US4] Record the Okta and Entra request sets (research R4) as fixtures in `Go/internal/controlplane/scim/testdata/`, and test that they play with no failed request (SC-006).
- [x] T015 [P] [US4] Test auth: no token, a wrong, revoked or ended token, a token of another provider: `401`, nothing written; two live tokens at most; `lastUse` at most once a minute (FR-014).
- [x] T016 [P] [US4] Test users: create, `409` on a second `userName`, filters, pages of 100, PUT, PATCH (with and without `path`, `active` as a string), the match at first sign-in by `externalId` and by `userName`, a rename kept in `lastNames` (FR-015, FR-016).
- [x] T017 [P] [US4] Test suspension on two copies: `active: false` closes three clients with `suspended` in 5 s, keys stop renewing, org sign-ins refused, `user/suspended` sent; `DELETE` also adds a **Remove** request; `active: true` undoes it; the local owner sign-in stays (FR-017, SC-003).
- [x] T018 [P] [US5] Test groups: create with members, PATCH add and remove, a member of another provider refused, **Gives the admin role**, `managedByProvider` on `people/setRole`, the last admin kept with a notice, a deleted group with shares kept as a tombstone (FR-019 to FR-021).
- [x] T019 [P] [US6] (Q1 A) Test refresh checks: `invalid_grant` suspends; the provider down lets keys renew for 7 days after the last good check, then stops (FR-024).
- [x] T020 [P] [US4] Test the size: 5,000 users and 500 groups, p95 under 200 ms (FR-023).

### Build

- [x] T021 [US4] Add `PersonSCIM`, `PersonSuspended`, `GroupSource`, `SCIMToken`, `SCIMTokenMade`, the `scim/*` and `groups/setRole` methods, `user/suspended` and `host.suspend.1` to `Packages/Wire`. Run `scripts/wire.sh gen`.
- [x] T022 [US4] Add `Go/internal/controlplane/scim/`: the HTTP server for D11, the filter parser (`eq`, `and`), PATCH, the error schema, `ServiceProviderConfig`, `ResourceTypes`, `Schemas`; it calls a `Directory` interface. Route `/scim/v2/` in `service.go`.
- [x] T023 [US4] Add `Go/internal/controlplane/people_scim.go`: the `Directory` for users, provisioned people, the indexes, the match at first sign-in (called from `signin_org.go`), suspend and unsuspend (cut off with `control/cutOff`, stop renewals in `keylife.go`, `user/suspended` to machines, through the mesh to the other copies).
- [x] T024 [US5] Add `Go/internal/controlplane/groups_scim.go`: the `Directory` for groups, `groups/setRole`, `roleFrom` on people, the last-admin rule, tombstones with shares.
- [x] T025 [US4] Add `scim/tokens/*` and `scim/set` in `signin_org.go`.
- [x] T026 [US6] (Q1 A) Keep the sealed refresh token at sign-in; refresh at renewal and daily in `keylife.go`.
- [x] T027 [US4] Add the Requests kind `remove` in `Go/internal/controlplane/console.go`; answering it runs `removePerson`.
- [x] T028 [US4] Add the SCIM actions and the `scim` actor to `audit/audit.go`.
- [x] T029 [P] Docs: `docs/explanation/org-identity.md` gains SCIM and suspension; `docs/reference/sign-in.md` gains `/scim/v2/*`; `docs/how-to/invite-someone.md` (**Who may join**, SCIM).

**Checkpoint**: quickstart step 3.

## Phase 3: Slice 2b, suspension on machines (area: hosts; a hook in workspaces)

**Goal**: a suspended user's work stops on their machines, and nothing is deleted. Covers US4 on the machine.

- [x] T030 [US4] Test in `Go/internal/agentsd/usersuspend_test.go`: `user/suspended` stops two running turns in 5 s, pauses workflows and queued prompts, refuses new work and the direct path; `off: true` undoes the pause and starts nothing by itself; every agent and file stays (FR-018).
- [x] T031 [US4] Add `Go/internal/agentsd/usersuspend.go`: handle `user/suspended` (dispatch in `localpath.go`), reuse the T5 kill switch's stop for one user, keep the state in `<root>/suspended.json` so a restart keeps it, say `host.suspend.1` in `host/hello`.
- [x] T032 [US4] Stop (not delete) the person's started machines through their workspace provider on suspension, in the control plane's provider code.
- [x] T033 [P] Docs: `docs/explanation/org-identity.md` "What an offline machine does".

**Checkpoint**: quickstart step 4.

## Phase 4: Slice 3, every client (areas: sign-in, then devices, then team, then control-plane)

**Goal**: US7 on the Mac, the Remote and the web page. One PR per area when those areas are busy, else one PR.

- [x] T034 [US7] Add the org words to `Packages/AgentsKit/Sources/AgentsKitCore/Model/IdentityProviders.swift` (**Sign in with <name>**, **Use an Email**, **Managed by**, **Suspended by**, **Set by**, the suspended and required lines) and their tests. Web: `Web/src/model/signIn.ts`.
- [x] T035 [US7] In `Shared/UI/SignIn/SignInButtons.swift`: org buttons first; the org flow in `ASWebAuthenticationSession` with `.customScheme("agents")`, the ticket from the fragment, `signIn/ticket`; **Use an Email** with `signIn/discover`.
- [x] T036 [US7] Mac: `App/Sources/Control/ConnectSheet.swift` and Settings ▸ Account use the order of T035. Remote: `Remote/Sources/Link/PairingView.swift` the same.
- [x] T037 [US7] Web: `Web/src/views/Pairing.tsx` and `SignIn*.tsx`: org buttons first; the same-tab redirect; read `#oidc-ticket`, clear it from the address bar, send `signIn/ticket`.
- [x] T038 [US7] The suspended page and the "asks you to sign in with" line on all three (FR-029).
- [x] T039 [US7] People lines on all three: `Shared/UI/People/`, `Web/src/views/People.tsx` (FR-028).
- [x] T040 [P] Parity rows for FR-026 to FR-029 in `specs/071-web-remote/walks/parity/`; docs `sign-in-with-google-apple-or-github.md`, `use-agents-in-a-browser.md`.

**Checkpoint**: quickstart step 5.

## Phase 5: Slice 4, admin Console (areas: reports, team)

**Goal**: admins manage org providers, domains, SCIM and group roles on the web page.

- [x] T041 [US2] Add `Web/src/views/ConsoleSignIn.tsx` and the **Sign-In** section in `Web/src/model/console.ts` (Organisation group): built-in providers; org providers with presets, the redirect URI to copy, **Check**, **Replace Secret** (write only, fingerprint), **Who may join**, order, **Remove** (FR-030).
- [x] T042 [US3] Domains on the same page: the TXT record, **Check**, the two switches, the preview before **Require** is saved.
- [x] T043 [US4] SCIM on the same page: **Turn On SCIM**, the base URL, tokens shown once, last use, **Revoke**, the match attribute.
- [x] T044 [US5] Console ▸ People and Groups: SCIM groups with **From <provider>**, **Gives the admin role**; Requests kind **Remove** (FR-031).
- [x] T045 [US7] The Mac's and the Remote's Settings ▸ Control plane ▸ People show the providers read only with **Edit in Console** (D17).
- [x] T046 [P] Docs: `docs/how-to/sign-in-with-your-organisation.md` with the steps for Okta, Entra and Google Workspace (research R3, R5).

**Checkpoint**: quickstart step 6, then step 7.

## Dependencies

- Slice 1 needs v0.10.0 shipped. 2a and 3 need slice 1. 2b needs 2a's wire types (T021). 4 needs slice 1, and 2a for T043 and T044.
- T5 is not needed: D13's stop reuses the kill switch's code when T5 slice 2a has landed; before that, 2b adds the stop for one user itself.
- T6 is not needed: a SCIM group can own an org route once T6 is built.
