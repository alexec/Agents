# Implementation Plan: Policy layers: Organisation, You, Folder

**Branch**: `agents/2957-govern-what-agents-may-do-2` (plan only) | **Date**: 2026-10-30 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `specs/2957-policy-layers/spec.md` (#2957), and the mock-up `specs/research/2957-policy-layers/index.html`.

## Summary

One shape of rules, `PolicyRules`, is used by all three layers. The organisation layer is today's `OrgPolicy` (spec 998) with the new rules added. Your layer is a `PolicyRules` document that the Mac's host keeps and signs with a new **person key** (ECDSA P-256, as the organisation policy is signed). It goes to your other machines in the user scope of the control plane, or from the Mac window over its direct link when there is no control plane. A folder's layer is `.agents/policy.json`, guarded as `.agents/folder.json` is (#502): a tighter change applies at once, a looser one waits.

Each machine resolves the three layers with one pure Go package, `policylayers`. It gets the effective value of each rule, the layer that decides, and each layer's value. Every place that applies a rule today (spec 998's ceiling checks, and the person's own limits in `limits.json`, `workflow-limit.json`, `display.json` and `runtime-environment.json`) reads the effective value. A refusal and a `setBy` mark carry the layer, so every client draws the same lock line and the same **Stopped by a policy** card. The clients draw what the machine resolved; no client resolves rules.

Settings gets the group **Agents** (Policy, Spending, Resources) on the Mac and the web page. The Remote gets Agents ▸ Policy, read only except for the notice limits and the archive switch. Control plane ▸ Policy becomes **Organisation Policy**.

## Technical Context

**Language/Version**: Go 1.24 (`agentsd`, `agents-control`). Swift 6 (the Mac window, Agents Host, the Remote, `Shared/UI`, `Packages/AgentsKit`). TypeScript (the web page and the Console).

**Primary Dependencies**: none new. Signing uses Go's `crypto/ecdsa` with P-256 and SHA-256, through the existing `controllink.SignPolicy`, `VerifyPolicy`, `CanonicalJSON` and `KeyID` (`Go/internal/controllink/policysig.go`). The key is kept in the Keychain on a Mac, as `controllink/hostkey_darwin.go` keeps the machine key, and in a 0600 file elsewhere. See research R1 and R2.

**Storage**: plain files, no database.

- On the Mac's host: `<settings>/policy-yours.json` (the signed layer) and the person key (Keychain account `person-key`, or `<root>/person-key` on a scratch root or Linux).
- On every machine: `<settings>/policy-yours.json` (the newest good signed copy) and the pinned person public key in `<root>/person-key.pub.json`.
- In each folder: `.agents/policy.json`, committed. Its last approved copy is in `<root>/guarded-files.json`, as for `.agents/folder.json`.
- On the control plane: the user-scope part `policy` in `v1/users/<user>/settings.json`. It replaces the parts `costLimits` and `notifications`.

**Testing**:

- `Go/scripts/go.sh test ./internal/policylayers/...`: the order of every rule (FR-004), the resolver, `Looser`, kept values, and the table test of SC-003 (every rule × every pair of layers).
- `Go/scripts/go.sh test ./internal/agentsd/... ./internal/controlplane/... ./internal/controllink/...`: the person key, signing, pinning and rotation; the first-start move (FR-012, SC-001); the guarded `.agents/policy.json`; every place of FR-007 with each layer deciding; refusals from an agent tool or a folder file (SC-004); the user-scope part.
- `scripts/go-changed.sh` before each push that changes `Go/`.
- `swift test`, filtered by `scripts/select-test-suites.sh`, for the AgentsKit words and decoding, and `WireSchemaTests`.
- Vitest: `Web/test/policyLayers.test.mjs`, and `Web/test/orgPolicy.test.mjs` and `Web/test/console.test.mjs` for the new organisation rules.
- Walks (quickstart.md): `run-app` on a scratch root (Mac and web), the walk simulator for the Remote, `test-servers` with the devbox for US6.

**Target Platform**: macOS 27, iOS and iPadOS 27, Linux (machines and control plane), current browsers.

**Project Type**: distributed app: control plane, machines, three clients.

**Performance Goals**: your layer on every online machine within 5 s (SC-005). The effective policy of a folder is resolved when a layer changes and kept in memory, so a check adds under 1 ms. A layer is under 16 KiB.

**Constraints**:

- A person alone with no layer set gets today's behaviour, rule by rule (Edge Cases, "No layer sets a rule").
- Hosts never escalate. The layer files are the user's own files. Signatures, not file modes, protect your layer; the guard protects a folder's layer. Neither is a boundary against the machine's own user (spec, Clarifications).
- No secret in any layer: names and numbers only.
- v0.x takes breaking changes, with the two moves of the spec's Decisions: your old values are read once (FR-012); the folder helper limits are not moved (FR-015).

**Scale/Scope**: under 10 machines and under 200 folders with a layer per person (spec, Assumptions). About 20 people for an organisation, as for spec 998.

## Constitution Check

*Before Phase 0, and again after Phase 1.*

| Principle | How this plan meets it |
|---|---|
| I. Spec-led | Spec 2957 (merged, #2978), this plan, then tasks. The build starts only after `/speckit-tasks`. |
| II. Capability-driven runtimes | A machine says `host.policy-layers/1`. The control plane sends your layer only to a machine that says it, and a client says which machines do not (Edge Cases). The sandbox rule uses each runtime's advertised sandbox state, as spec 998 does. Each runtime's own name for a level stays in Auto's table. |
| III. Scoped access and user control | Layers only make rules tighter. No agent can write your layer (FR-010): the method is refused for the agent socket role, MCP tools and workflows. A folder file that loosens a rule waits for the person's OK on an app-owned card. |
| IV. Work must be inspectable | Every rule shows its effective value and the layer that decides. Where this comes from shows every layer. Every refusal names the rule, the layer and the value. A tighter folder change gives a notice. |
| V. Docs and quality travel with the feature | The spec's Docs section lists every page; each slice updates its own pages and its parity rows. Wire types come from `Packages/Wire` through `scripts/wire.sh gen`. |

No violation. Complexity Tracking is empty. After Phase 1: still no violation. The new person key is the one new moving part. Research R1 says why the existing keys cannot do this job.

## Project Structure

### Documentation (this feature)

```text
specs/2957-policy-layers/
├── spec.md
├── plan.md                    this file
├── research.md                Phase 0
├── data-model.md              Phase 1
├── contracts/policy-layers-api.md   Phase 1
├── quickstart.md              Phase 1
├── checklists/requirements.md
└── tasks.md                   /speckit-tasks (not made by this plan)
specs/research/2957-policy-layers/index.html   the mock-up (frames A to G)
```

### Source Code (repository root)

Areas from `.agents/areas` are in brackets.

```text
Packages/Wire/                    daemon.schema.json, daemon.openrpc.json, control.openrpc.json   [-]
Go/internal/policylayers/  (new)  rules, orders, Resolve, Looser, Effective; pure, no I/O          [machines, added by T001]
Go/internal/controllink/
├── policysig.go                  reused as is for the person key's signatures                     [control-plane]
├── personkey.go, personkey_darwin.go (new)  make, keep, load, rotate the person key               [control-plane]
└── membership.go                 the pinned person key beside the control key                     [control-plane]
Go/internal/controlplane/
├── policy.go                     new organisation rules; modeCeiling read once as permissionMode  [control-plane]
├── userscope.go, usersettings/   the part `policy` (store and forward); parts costLimits and
│                                 notifications go; the notice bucket reads the layer              [team]
└── console*                      Organisation Policy words                                        [reports]
Go/internal/agentsd/
├── policy.go                     effective policy instead of org-only ceilings; refusals with layer [machines]
├── policyyours.go (new)          your layer: keep, sign (on the keeper), verify, pin, apply,
│                                 the first-start move (FR-012)                                    [machines]
├── policyfolder.go (new)         .agents/policy.json: read, write in stable order, guard rule     [machines]
├── guarded.go, folderwatch.go    .agents/policy.json is guarded; tighter applies at once          [machines]
├── costlimits.go, cost.go, workflows.go, notify.go, archiverequests.go, passthrough.go,
│   helpers.go, folders.go, autopick.go, sandbox.go, host.go, turns.go, helperstart.go
│                                 read the effective value; the old files are not read             [machines]
├── usersettings.go               apply the part `policy`                                          [team]
└── capabilities.go               host.policy-layers/1 (declared)                                  [machines]
Packages/AgentsKit/Sources/AgentsKitCore/Model/PolicyLayers*.swift (new)  decode, words           [settings]
Shared/UI/
├── PolicyPane.swift (new)        Agents ▸ Policy and a folder's layer: sections, rows, banner     [settings]
├── PolicyRuleRow.swift (new)     effective value, 🔒 line, dimmed menu values, Kept, not used     [settings]
├── PolicySourcePopover.swift (new)  Where this comes from                                         [settings]
├── Chat/PolicyStopCard.swift (new)  Stopped by a policy                                           [chat]
├── OrgPolicyLine.swift           generalised: the line names any layer                            [runtimes]
├── OrgPolicyPane.swift           title Organisation Policy                                         [settings]
├── NotificationLimitsSection.swift, SidebarSettingsSection.swift   rules leave                    [settings]
└── SettingsScope.swift           the group Agents                                                  [settings]
App/Sources/Settings/             SettingsWindow (group, panes), CostSettingsView (limits leave),
                                  AutoSettingsView                                                  [settings, usage, runtimes]
App/Sources/Folders/FolderSettingsSheet.swift   pane Policy; General loses helper limits          [folders]
App/Sources/AppModel.swift        no cost/setLimits, workflows/setLimit pushes; policy/applyYours  [-]
Remote/Sources/Settings/          Agents ▸ Policy (read only, two rules editable)                  [settings]
Remote/Sources/Chat/              the stop card                                                    [chat]
Web/src/model/policyLayers.ts (new), Web/src/views/settings/AgentsPolicy.tsx (new),
Web/src/views/settings/PolicySource.tsx (new), sections.ts, Notifications.tsx (goes),
FinishedChats.tsx, Policy.tsx (renamed title)                                                      [settings]
Web/src/views/chat/PolicyStopCard.tsx (new)                                                         [chat]
Web/src/views/ConsoleOrgPolicy.tsx, Web/src/model/orgPolicy.ts   new rules, four levels            [reports, settings]
docs/                             the pages of the spec's Docs section                              [docs, settings]
specs/071-web-remote/walks/parity/  rows of the spec's Docs section                                 [docs]
```

**Structure Decision**: no new binary. One new pure Go package, `Go/internal/policylayers`, so the resolver has one home and one table test, used by `agentsd` and the control plane. Each client gets one shared pane in its own idiom (`Shared/UI` for the Mac and the Remote, `Web/src/views/settings` for the web page) that draws the machine's `EffectivePolicy`.

## Slices for the build

Each slice is one lane, one area set, its own tests and its own walk, as for spec 998. A slice starts only when no open PR or running lane holds its areas (#873). Slices 4, 5 and 6 change what clients show, so each is a UI enhancement and waits for Alex's approval of its screenshots (#2811).

| Slice | What | Areas | Needs | Walk |
|---|---|---|---|---|
| **1. Rules and resolver** | `PolicyRules`, `EffectivePolicy`, `PolicyLayerRef` and the extended `PolicyRefusal` and `PolicySetBy` in the wire; `Go/internal/policylayers` with the SC-003 table test; `host.policy-layers/1` | `-`, machines | none | none: Go tests only |
| **2. Your layer on the machine** | person key; `policy-yours.json`; sign on the keeper, verify and pin elsewhere; the first-start move; every place of FR-007 reads the effective value; refusals with the layer; `policy/*` daemon methods | machines, control-plane (`controllink`) | slice 1 | `run-app` scratch root: old values moved; an agent tool refused; each rule stops an agent with layer You |
| **3. Folder layer and transport** | `.agents/policy.json` guarded (tighter at once, looser waits); helper limits leave `.agents/folder.json`; user-scope part `policy`; `host/userSettings` carries it; `policy/applyYours` from the window; organisation rules of FR-003 and `modeCeiling` → `permissionMode` | machines, team, control-plane | slice 2 | `test-servers`: devbox gets your layer in 5 s; forged copy refused; offline then online |
| **4. Agents ▸ Policy on Mac and web** | group Agents (Policy, Spending, Resources); the pane, rows, banner, Where this comes from; the rules leave their old panes; Organisation Policy rename | settings, usage, runtimes | slices 2 and 3 | `run-app` Mac + headless Chrome: frames A, B, C, F |
| **5. Folder layer and the stop card on clients** | Folder Settings ▸ Policy (Mac); the folder list in Agents ▸ Policy (web); the guarded card's words for a policy change; Stopped by a policy in chat | folders, chat, settings | slice 4 | `run-app` Mac + headless Chrome: frames D, E |
| **6. Remote and Console** | Agents ▸ Policy on the Remote (two rules editable); the stop card on the Remote; the Console's new rules and four permission levels | settings, chat, reports | slices 4 and 5 | walk simulator for the Remote; headless Chrome for the Console |

**Order**: 1 → 2 → 3 → (4 ‖ Console part of 6 when `reports` is free) → 5 → 6. Slices 2 and 3 hold `machines`, so they go one after the other. The parity table rows go with slices 4, 5 and 6; the docs pages go with the slice that ships what they describe.

**Parity lines**: slice 4 `remote: #<the Remote slice>`; slice 5 `remote: same` for the stop card, `web: same`; slice 6 `mac: same, web: same`. The parity issue for editing every rule on the Remote is filed by slice 6 (FR-027).

## Complexity Tracking

None.
