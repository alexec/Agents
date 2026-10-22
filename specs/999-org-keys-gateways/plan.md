# Implementation Plan: Enterprise T6, org keys and model gateways

**Branch**: `agents/are-0-11-enterprise-5` (spec only) | **Date**: 2026-10-21 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `specs/999-org-keys-gateways/spec.md` (#999).

## Summary

An admin adds org routes (an org key, or a Bedrock, Vertex, Azure or base-URL gateway) in Console ▸ Model Access. The control plane keeps each route's secrets in a keeper-sealed envelope, as #1760 keeps user secrets, and sends each allowed machine its routes on channel 0, each secret sealed with HPKE to that machine's key. The machine keeps the envelopes, lists each route as an account of the runtimes it serves (#840 `AccountProfile`, `reach: orgKey | gateway`), and runs one model relay on loopback. A session on an org account gets the relay's address and a stand-in; the relay adds the real credential, streams the answer, and counts the provider's tokens. T5's policy gains `runtimes.<id>.reach` ("the org path only") and `notices.antigravityTerms`.

## Technical Context

**Language/Version**: Go 1.24 (`agents-control`, `agentsd`). Swift 6 (Mac window, Agents Host, Remote, `Shared/UI`, `Packages/AgentsKit`). TypeScript (web page).

**Primary Dependencies**: none new for keys and base URLs: `crypto/hpke` and `crypto/ecdh` (as `apns.Seal`), `net/http/httputil` for the relay, `gocloud.dev/secrets` (the keeper, as #1760). Under Q1 answer A: small clients for AWS STS `AssumeRole`, Google OAuth (service account JWT) and Entra client credentials in `agents-control`; SigV4 signing in `agentsd` for a Bedrock role (or the AWS SDK's signer only).

**Storage**: store: `v1/org/routes/<id>.json`, `v1/org/routes/<id>.secret.json`. Machine: `<root>/org-routes/<id>.json` (sealed), account folders under `<root>/runtimes/org/`. No database.

**Testing**:

- `Go/scripts/go.sh test ./internal/controlplane/... ./internal/agentsd/...`: seal and open, delivery by group, two copies, replace and remove, the relay with a fake provider for each kind and answer shape, the stand-in refusal, the launch environment of each runtime, the reach table test over T5 FR-009, the leak search (SC-003).
- `swift test` filtered by `scripts/select-test-suites.sh`: `AccountProfile` decoding of the new reaches, the words; `WireSchemaTests`.
- Vitest: `Web/test/runtimes.test.mjs`, `Web/test/console.test.mjs`.
- Walks: `test-servers` (devbox) for delivery and the relay on Linux; `run-app` for the Mac host and the window; the Remote walk simulator; headless Chrome for the Console.

**Target Platform**: macOS 27, iOS and iPadOS 27, Linux (machines, control plane), current browsers.

**Project Type**: distributed app: control plane, machines, three clients.

**Performance Goals**: delivery within 5 s (SC-002); the relay under 5 ms at p95 to the first byte (SC-005).

**Constraints**:

- No route = no change (SC-001).
- No secret value in the clear in the store, on disk, in a runtime's environment, in a log, an event, a transcript or a client message (SC-003).
- Hosts never escalate: protection is by sealing and by keeping keys out of the runtime, not by file owners.
- Nothing switches account by itself (#840).

**Scale/Scope**: up to 50 routes, about 20 people and 50 machines.

## Constitution Check

| Principle | How this plan meets it |
|---|---|
| I. Spec-led | Spec, decisions, plan and tasks first. The build waits for v0.10.0, T5 slice 1 and #840. |
| II. Capability-driven runtimes | Which kind a runtime can use is a table per runtime from what its CLI takes (research R2), not its name in code paths. Machines say `host.orgRoutes.1`. |
| III. Scoped access and user control | A route reaches only the machines of the people it is for. A member keeps their own sign-in unless the policy says otherwise, and sees why. |
| IV. Work must be inspectable | Every route change is an audit entry. Tokens are the provider's count; a cost is labelled as the runtime's list price. |
| V. Docs and quality travel with the feature | The spec's Docs section lists every page; each slice ends with its docs, parity rows and walk; `integrations.md` rows for each kind. |

No violation. Complexity Tracking is empty.

## Project Structure

### Documentation (this feature)

```text
specs/999-org-keys-gateways/
├── spec.md
├── research.md
├── data-model.md
├── plan.md
├── quickstart.md
├── contracts/org-routes-api.md
├── checklists/requirements.md
└── tasks.md
```

### Source Code (repository root)

```text
Packages/Wire/                          daemon.schema.json, control.openrpc.json, daemon.openrpc.json (area -)
Go/internal/controlplane/
├── orgroutes.go, orgroutes_test.go   (new)  records, envelope, orgRoutes/*, delivery, seal to machine   [control-plane]
├── orgtokens.go                      (new)  short-lived tokens (Q1 A)                                  [control-plane]
├── policy.go (T5)                           reach and antigravityTerms rules                           [control-plane]
├── audit/audit.go                           orgRoutes/* actions                                        [reports]
└── reports*.go, console*                    tokens by route; Machines "holds routes"                   [reports]
Go/internal/agentsd/
├── orgroutes.go, orgroutes_test.go   (new)  keep, open, list as accounts, remove                        [hosts]
├── modelrelay.go, modelrelay_test.go (new)  the relay, credentials, token count                         [hosts]
├── runtimes.go, accounts.go (#840)          the launch per runtime and kind                             [hosts]
├── policy.go (T5)                           reach, antigravityTerms                                     [hosts]
└── reportledger.go                          route, relayTokens                                          [reports]
Packages/AgentsKit/Sources/AgentsKitCore/Runtimes/AccountProfile.swift   new reaches, source, words     [runtimes]
App/Sources/Runtimes/, Remote/Sources/Projects/RuntimesView.swift, Web/src/model/runtimes.ts             [runtimes]
App/Sources/Chat/PromptBar.swift, Remote/Sources/StartAgent/, Web/src/views/NewAgent.tsx (the picker)   [chat]
Packages/AgentsKit/Sources/AgentsKitCore/Runtimes/Allowance/, Web/src/views/Activity.tsx rows            [usage]
Web/src/views/ConsoleModelAccess.tsx (new), Web/src/model/console.ts                                     [reports]
Shared/UI/OrgPolicyPane.swift (T5), Web/src/views/settings/Policy.tsx (T5)                               [settings]
docs/                                                                                                     [docs, runtimes, usage]
```

**Structure Decision**: no new binary and no new package. New files in existing packages, beside T5's and #840's.

## Slices for the build

Each slice is one lane, one area set, its own tests and its own walk. A slice starts only when no open PR or running lane holds its areas (#873).

| Slice | What | Areas | Needs | Walk |
|---|---|---|---|---|
| **1. Routes on the control plane** | wire types; route records and envelopes; `orgRoutes/*`; delivery sealed to each machine; audit; T5's two new rules; Q1 tokens | control-plane (+ a hook in reports' `audit.go`) | v0.10.0 shipped; T5 slice 1 | `test-servers`: two copies, three machines, a route reaches the allowed machines only, in 5 s |
| **2. The machine: keep, relay, launch** | sealed files; org accounts; the model relay; each runtime's launch (R2); `reach` and `antigravityTerms` enforcement; token count; out on 429; remove | hosts (+ reports' `reportledger.go`) | slice 1; #840 landed; T5 slice 2a landed (both are hosts) | `run-app` scratch root and devbox: a fake provider sees the key, the leak search finds 0, the reach table test |
| **3. Members on every client** | the org account in the picker and on Runtimes, **From your organisation**, **Reaches the Model By**, refused choices, the allowance row | runtimes, then chat (the picker), then usage (one PR per area when they are busy) | slices 2 and 4 (the words) | `run-app` + Remote walk simulator + headless Chrome |
| **4. Admin Console** | Console ▸ Model Access; Policy's reach and Antigravity controls; Reports by route; the routes in the read-only Policy pane | reports, settings | slice 1 (2 for a full walk); T5 slice 3 | headless Chrome Console walk; Mac and Remote pane walk |

**Order**: 1 → (2 ‖ 4) → 3. 2 holds hosts, 4 holds reports and settings. Slice 4 adds the shared words (`AccountProfile` org words in AgentsKit, `runtimes.ts`) that 3 draws, so it lands first in the runtimes file it touches; when runtimes is held, slice 4 puts the words in its own new file.

## Complexity Tracking

None.
