# Implementation Plan: Enterprise T5, policy from the control plane

**Branch**: `agents/are-0-11-enterprise-3` (spec only) | **Date**: 2026-10-21 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `specs/998-org-policy/spec.md` (#998).

## Summary

The control plane keeps one signed policy document per organisation, and sends it to every machine on channel 0, as it sends user settings today. Each machine keeps the newest signed copy on disk and checks every choice against it: the policy is a ceiling over the person's and the project's own settings. A refused choice comes back as `policyRefused`, and the lists that clients draw mark refused items with `setBy`, so the Mac, the Remote and the web page all say **Set by your organisation**. Budgets reuse the person's own `CostLimits` (dollars and tokens) and the bot cap machinery (`checkCaps`, `host/user` → `capReachedUntil`). The kill switch is one rule with its own method. An admin edits the policy in Console ▸ Policy on the web page; every client shows it read only, and gives admins the kill switch. MDM and `/etc/agents/policy.json` pin a machine to one control plane.

## Technical Context

**Language/Version**: Go 1.24 (`agents-control`, `agentsd`). Swift 6 (the Mac window, Agents Host, the Remote, `Shared/UI`, `Packages/AgentsKit`). TypeScript (the web page).

**Primary Dependencies**: none new. Ed25519 signing with the control key that `agents-control` already holds (`crypto/ed25519`). Managed preferences on the Mac through `UserDefaults`, in each app's own domain, which macOS fills from a configuration profile.

**Storage**: the control plane's store: `v1/policy.json` and `v1/policy.sig`. On a machine: `<root>/policy.json` (0600). No database.

**Testing**:

- `Go/scripts/go.sh test ./internal/controlplane/... ./internal/agentsd/...`: signing, versions, push to two copies, the ceiling table test (every rule × every path of FR-009), budgets across machines, the kill switch, a forged, missing and older file, `requires`, the pin.
- `swift test` (filtered by `scripts/select-test-suites.sh`) for the AgentsKit words and `setBy` decoding, and `WireSchemaTests`.
- Vitest for the web model (`Web/test/orgPolicy.test.mjs`, `Web/test/console.test.mjs`).
- Walks: `run-app` on a scratch root with a policy, `test-servers` with the devbox for the Linux machine and `/etc/agents/policy.json`.

**Target Platform**: macOS 27, iOS and iPadOS 27, Linux (machines, control plane), current browsers.

**Project Type**: distributed app: control plane, machines, three clients.

**Performance Goals**: a policy on every online machine within 5 s (SC-002). A ceiling check adds under 1 ms per call (the policy is in memory, read again only when a new one arrives). The kill switch within 5 s (SC-004).

**Constraints**:

- No policy = no change (SC-001).
- Hosts never escalate: the policy file is the user's own file, protected by its signature, not by permissions.
- Store rule 7: no secret in the policy. It holds names and numbers only.
- v0.x takes breaking changes, but nothing here breaks: every field is new and optional.

**Scale/Scope**: one document under 64 KiB; about 20 people and 50 machines.

## Constitution Check

| Principle | How this plan meets it |
|---|---|
| I. Spec-led | Spec, decisions, plan and tasks come first. The build waits for v0.10.0 to ship. |
| II. Capability-driven runtimes | "Sandbox required" uses each runtime's advertised sandbox state (`sandboxCatalog`), not its name. A machine says `host.policy.1`, and a policy says what it `requires`. |
| III. Scoped access and user control | The policy only narrows what a person may do. Every refusal reaches the person on app-owned surfaces with a reason. Admins see no machine's inside. |
| IV. Work must be inspectable | Every policy change is an audit entry. A refused choice says why. Budgets count only what runtimes report, never an estimate shown as a fact. |
| V. Docs and quality travel with the feature | The spec's Docs section lists every page. Each slice ends with its docs, parity rows and walk. Wire files are generated from `Packages/Wire`. |

No violation. Complexity Tracking is empty.

## Project Structure

### Documentation (this feature)

```text
specs/998-org-policy/
├── spec.md
├── research.md
├── data-model.md
├── plan.md
├── contracts/policy-api.md
├── checklists/requirements.md
└── tasks.md
```

### Source Code (repository root)

```text
Packages/Wire/                          daemon.schema.json, control.openrpc.json, daemon.openrpc.json (shared, area -)
Go/internal/controlplane/
├── policy.go, policy_test.go   (new)   store, bounds, sign, policy/* methods, push      [control-plane]
├── policybudget.go             (new)   person budgets from roll-ups, raises             [control-plane]
├── bots.go                             host/user capReachedUntil for people too         [team]
├── audit/audit.go                      policy/* actions                                 [reports]
└── console.go, reports_scope.go        Machines page "follows policy", Requests kind    [reports]
Go/internal/controllink/                host/policy received, host/policyApplied          [control-plane]
Go/internal/agentsd/
├── policy.go, policy_test.go   (new)   keep, verify, ceiling checks, refusals            [hosts]
├── turns.go, helperstart.go, agents.go, sandbox.go, catalog.go, mcp*.go,
│   projects.go, runtimes.go, costlimits.go, workflows*.go, usersettings.go               [hosts]
├── reportledger.go                     limitTokens in each row                           [reports]
└── pin.go                      (new)   /etc/agents/policy.json, must join                [hosts]
Go/cmd/agentsd/                         pin at start                                      [hosts]
Host/                                   managed preferences, must join                    [hosts]
App/Sources/Control/                    pairing refused by the pin                         [control-plane]
Packages/AgentsKit/Sources/AgentsKitCore/Model/OrgPolicy*.swift (new)  words (slice 3)    [settings, added to `.agents/areas` by T029]
Shared/UI/OrgPolicyLine.swift   (new)   "Set by your organisation" + the tip             [runtimes]
Shared/UI/OrgPolicyPane.swift   (new)   the read-only Policy pane + kill switch          [settings]
App/Sources/Settings/, Remote/Sources/Settings/   the Policy pane in the Control plane group [settings]
Web/src/model/orgPolicy.ts, Web/src/views/settings/Policy.tsx (new)                       [settings]
Web/src/views/ConsoleOrgPolicy.tsx (new), Web/src/model/console.ts                        [reports]
(the client marks)  StartAgent, ModelPill, Sandbox*, Catalog, MCPServers, CostSettings, helper limits
                                        [chat, runtimes, marketplace, usage]
docs/                                   the pages of the spec's Docs section               [docs]
```

**Structure Decision**: no new binary and no new package. `policy*.go` files in the existing packages, and one shared line view per client.

## Slices for the build

Each slice is one lane, one area set, its own tests and its own walk. A slice starts only when no open PR or running lane holds its areas (#873).

| Slice | What | Areas | Needs | Walk |
|---|---|---|---|---|
| **1. Document, store, push** | wire types; `policy.json` + `policy.sig`; `policy/*` methods; push on `host/policy`; audit; person budgets on the control plane | control-plane (+ one hook in team's `bots.go`, reports' `audit.go`) | v0.10.0 shipped (area:control-plane free) | `test-servers`: two copies, three machines, a policy reaches all in 5 s |
| **2a. Machine enforcement** | keep and verify; the ceiling at every path of FR-009; `policyRefused`; `setBy` marks on lists; budgets on the machine; kill switch; `requires` | hosts (+ reports' `reportledger.go`) | slice 1 | `run-app` scratch root: each rule refused by the wire; plane off, policy kept; edited file refused |
| **2b. "Set by your organisation" on clients** | the shared line, its words, and each refused choice drawn dimmed on Mac, Remote, web | runtimes, then chat, marketplace, usage (one PR per area when they are busy) | slices 2a and 3 | `run-app` + Remote walk sim + headless Chrome: the US3 list on all three |
| **3. Admin policy page** | Console ▸ Policy on the web (edit, preview, save); the read-only Policy pane and kill switch on Mac, Remote, web; Requests kind `budget` | settings, reports | slice 1 (2a for a full walk) | headless Chrome Console walk; Mac and Remote pane walk; kill switch end to end |
| **4. MDM and `/etc` pin** | managed preferences on the Mac (Host and window), `/etc/agents/policy.json` on Linux, must join, pairing refused | hosts, control-plane (`App/Sources/Control/`) | slice 2a (hosts area) | scratch Mac account with a test profile; devbox with `/etc/agents/policy.json` |

**Order**: 1 → (2a ‖ 3) → (2b ‖ 4). 2a and 3 hold different areas; 2b and 4 do too. Slice 3 adds the shared words and decoding (`OrgPolicy.swift`, `orgPolicy.ts`) that 2b draws.

## Complexity Tracking

None.
