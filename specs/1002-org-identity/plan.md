# Implementation Plan: Enterprise T9, org identity

**Branch**: `agents/are-0-11-enterprise-7` (spec only) | **Date**: 2026-10-21 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `specs/1002-org-identity/spec.md` (#1002).

## Summary

An admin adds an org provider (Okta, Entra, Google Workspace with its own client, or any OIDC provider) in Console ▸ Sign-In. The control plane runs the code flow with PKCE as a confidential client on its own HTTPS address, keeps the client secret sealed with its keeper, and gives the client a ticket for one use, bound to the connection that started the flow. That gives the web page a direct sign-in. Proved domains send people to their provider, and can require it. SCIM 2.0 at `/scim/v2/` adds, changes and suspends people, and pushes groups that can give the admin role and own shares. A suspended person's clients are cut off in 5 seconds, their keys stop renewing, and their machines stop their work; a delete waits for an admin.

## Technical Context

**Language/Version**: Go 1.24 (`Go/`: `agents-control`, `agentsd`). Swift 6 (the Mac window, the Remote, `Shared/UI`, `Packages/AgentsKit`). TypeScript (the web page, `Web/src`).

**Primary Dependencies**:

- the existing hand-written OIDC check (`signin/oidc.go`), extended for discovery and ES256;
- `golang.org/x/oauth2` for the code exchange and the refresh (already in `go.sum` through the Google libraries; the lane checks);
- the existing `kms` keeper (`SealFor`, `OpenFor`);
- `net` for the TXT lookup, behind an interface;
- AuthenticationServices (`ASWebAuthenticationSession`) on Apple platforms, as for Google today.

No SCIM library: the subset of D11 is small, and a library would bring a data model of its own. No new database.

**Storage**: the control plane's store, plain JSON under `<prefix>/v1/` (`data-model.md`).

**Testing**:

- `Go/scripts/go.sh test ./...`: the fake OIDC provider (R7), tickets and replay, domain proof with fake DNS, the SCIM fixtures of Okta and Entra (R4), suspension on two copies, the leak search (SC-005), the 5,000-user timing (SC-006).
- `swift test` for the AgentsKit models (the new words and `OrgProvider`).
- Biome and Vitest for the web.
- Walks: `test-servers` (two copies), `run-app`, the Remote walk simulator, headless Chrome for the web page and the Console.

**Target Platform**: macOS 27, iOS and iPadOS 27, Linux (machines and the control plane), current browsers.

**Project Type**: a distributed app: control plane, machines, and three clients.

**Performance Goals**: a suspension in force on every copy in 5 s; SCIM under 200 ms at p95 for 5,000 users; a sign-in adds one token call and one JWKS read (cached) on the control plane.

**Constraints**: no cloud login is ever required (the local owner stays); no readable secret, token or ID token in the store; only fields and keys are added; plain files only; hosts never escalate.

**Scale/Scope**: up to 5 org providers, 20 domains, 5,000 provisioned people and 500 groups per control plane.

## Constitution Check

| Principle | How this plan meets it |
|---|---|
| I. Spec-led | Spec, decisions, plan and tasks first. The build waits for v0.10.0. |
| II. Capability-driven runtimes | Not touched. Machines say `host.suspend.1`; one without it is refused for a suspended user. |
| III. Scoped access and user control | Only admins change providers, domains and SCIM. A provider controls only what it made (its people, its groups). The local owner is never taken away. Deleting work needs an admin. |
| IV. Work must be inspectable | Every identity change and every SCIM write is an audit entry with its actor, also when nobody clicked. |
| V. Docs and quality travel with the feature | The spec's Docs section lists every page; each slice ends with its docs, parity rows and walk; `integrations.md` rows for each provider. |

No violation. Complexity Tracking is empty.

## Project Structure

### Documentation (this feature)

```text
specs/1002-org-identity/
├── spec.md
├── research.md
├── data-model.md
├── plan.md
├── quickstart.md
├── contracts/identity-api.md
├── checklists/requirements.md
└── tasks.md
```

### Source Code (repository root)

```text
Packages/Wire/                              daemon.schema.json, control.openrpc.json (area -)
Go/internal/controlplane/
├── signin_org.go, signin_org_test.go      (new) org providers, signIn/orgStart, signIn/ticket      [sign-in]
├── signin_domains.go                      (new) claims, TXT proof, discover, require                [sign-in]
├── signin/oidc.go, signin/discovery.go          discovery, ES256, per-provider OIDC                 [sign-in]
├── signin/signintest/                           the fake provider (R7)                              [sign-in]
├── identity_oidc_http.go                  (new) /v1/oidc/start and /callback                        [sign-in]
├── service.go                                   routes /v1/oidc/* and /scim/v2/*                    [control-plane]
├── keylife.go                                   D9 and Q1 checks at renewal                         [control-plane]
├── scim/                                  (new) the SCIM server, fixtures in testdata/              [control-plane]
├── people_scim.go                         (new) provisioned people, match, suspend                  [team]
├── groups_scim.go                         (new) SCIM groups, roles                                  [team]
├── audit/audit.go                               the new actions and the scim actor                  [reports]
└── console*.go                                  Requests kind Remove                                [reports]
Go/internal/agentsd/
└── usersuspend.go                         (new) user/suspended: stop turns, pause workflows         [hosts]
Shared/UI/SignIn/                                org buttons, Use an Email, the org flow              [sign-in]
Shared/UI/People/                                Managed by / Suspended by / Set by lines            [team]
App/Sources/Control/ConnectSheet.swift           org providers first                                 [control-plane]
Remote/Sources/Link/PairingView.swift            org providers first                                 [devices]
Web/src/model/signIn.ts, views/SignIn*.tsx       direct sign-in, ticket from the fragment            [sign-in]
Web/src/views/Pairing.tsx                        org providers first                                 [devices]
Web/src/views/People.tsx                         the lines                                           [team]
Web/src/views/ConsoleSignIn.tsx            (new) Console ▸ Sign-In                                   [reports]
docs/                                            the Docs section of the spec                        [docs, sign-in, team]
```

**Structure Decision**: new files where an area is often held (`signin_org.go` beside `signin.go`; `people_scim.go` beside `people.go`), so each slice touches few shared files. `scim/` is a package of its own, with no import of `controlplane`; it calls an interface (`Directory`) that `people_scim.go` and `groups_scim.go` give it.

## Slices for the build

Each slice is one lane, one area set, its own tests and its own walk. A slice starts only when no open PR or running lane holds its areas (#873).

| Slice | What | Areas | Needs | Walk |
|---|---|---|---|---|
| **1. Org providers and domains on the control plane** | wire types; provider records and sealed secrets; discovery; `/v1/oidc/*`; tickets; `signIn/ticket`, `signIn/orgStart`, `signIn/discover`; domain claims and proof; **Require** at join, pair and renewal; audit | sign-in (+ hooks in control-plane's `service.go`, `keylife.go`, and reports' `audit.go`) | v0.10.0 shipped | `test-servers` with the fake provider: pair a client by ticket on each copy; a replayed ticket and a replayed ID token pair nothing |
| **2a. SCIM and suspension on the control plane** | `scim/` server; provisioned people and the match; groups and roles; suspension and the Remove request; Q1 refresh checks; audit | control-plane (`scim/`), team (`people_scim.go`, `groups_scim.go`) (+ reports' `audit.go`, `console*.go`) | slice 1 | the Okta and Entra fixtures on two copies; a deactivation cuts off three clients in 5 s |
| **2b. Suspension on machines** | `user/suspended`; stop turns, pause workflows, refuse the direct path; started machines stopped by their provider; `host.suspend.1` | hosts (+ workspaces for the provider stop) | slice 2a's wire types | `run-app` scratch root and the devbox: a suspended user's turn stops in 5 s; nothing is deleted |
| **3. Every client** | org buttons first, **Use an Email**, the org flow (Mac, Remote, web), the suspended and required pages, the People lines | sign-in, then devices, then team, then control-plane (`ConnectSheet`) (one PR per area when they are busy) | slice 1 (2a for the People lines) | `run-app` + Remote walk simulator + headless Chrome with the fake provider |
| **4. Admin Console** | Console ▸ Sign-In; SCIM groups and roles in People and Groups; Requests kind Remove | reports (`ConsoleSignIn.tsx`, `console.ts`), team (`People.tsx` group rows) | slice 1 (2a for SCIM parts) | headless Chrome Console walk |

**Order**: 1 → (2a ‖ 3) → (2b ‖ 4). 2a holds control-plane and team; 3 starts with sign-in and devices, and does its team part after 2a lands. 4's SCIM part waits for 2a.

## Complexity Tracking

None.
