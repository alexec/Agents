# Tasks: Enterprise T5, policy from the control plane

**Input**: `spec.md`, `plan.md`, `research.md`, `data-model.md`, `contracts/policy-api.md` in `specs/998-org-policy/`.

**Tests**: the spec asks for automated checks (SC-001 to SC-006), so each slice has test tasks. Write them first.

**Format**: `[ID] [P?] [Story] Description`. `[P]` means a task can run in parallel with the others of its phase (different files).

**Not before v0.10.0 ships.** Nothing here merges to `main` until then (#998 holds `hold:v0.10`).

**Slices**: each phase below is one slice of `plan.md`, one lane, with its own areas, tests and walk. Order: 1 → (2a ‖ 3) → (2b ‖ 4). 2b also waits for 3, which adds the shared words (T029).

## Phase 1: Slice 1, the document, its store and the push (areas: control-plane; a hook in team and reports)

**Goal**: an admin can save a signed policy, and every machine that says `host.policy.1` gets it within 5 s. Covers US1, the store side of US2, US4 and US5.

### Tests first

- [x] T001 [US1] Test that a control plane with no policy sends `host/policy {none: true}` and nothing else changes, in `Go/internal/controlplane/policy_test.go` (SC-001).
- [x] T002 [P] [US2] Test `policy/set`: bounds, `rev` conflict between two admins, `version` + 1, a member refused, the signature checks with the control key and fails after one changed byte, in `policy_test.go`.
- [x] T003 [P] [US2] Test the push: two copies over one store, three machines, a save reaches all three in 5 s; a machine without `host.policy.1` gets nothing; a machine that connects later gets the newest, in `policy_test.go` (SC-002).
- [ ] T004 [P] [US4] Test person budgets: two machines' roll-ups add up by UTC day in dollars and `limitTokens`; at a budget, `host/user` carries `capReachedUntil` for a person; a raise lifts it for that day only, in `Go/internal/controlplane/policybudget_test.go`.
- [x] T005 [P] [US5] Test `policy/stopAll`: on and off are audited, pushed, and `control/stopAll` reaches every person's clients, in `policy_test.go`.

### Build

- [ ] T006 [US2] Add `OrgPolicy`, `SignedPolicy`, `PolicySignature`, `PolicyView`, `PolicyPreview`, `PolicyRefusal`, `PolicySetBy`, `BudgetRaise` to `Packages/Wire/daemon.schema.json`; the methods and notifications of `contracts/policy-api.md` to `control.openrpc.json`; `limitTokens` on `UsageRollupRow`. Run `scripts/wire.sh gen`, commit the generated files, and do what `WireSchemaTests` says in Swift.
- [ ] T007 [US2] Add `Go/internal/controlplane/policy.go`: read and keep `v1/policy.json` and `v1/policy.sig` (conditional on `rev`), bounds, canonical JSON, Ed25519 signing with the control key, `policy/mine`, `policy/get`, `policy/set`, `policy/preview`, `policy/stopAll`, `policy/raise`, `policy/askForMore`. Admin checks with `isAdmin`. Add `policy/set`, `policy/stopAll`, `policy/raise` to `writes` in `methods.go`.
- [x] T008 [US2] Push `host/policy` on `host/hello` and on each change, with the hash dedup of `userscope.go`; tell the other copies through the mesh, as `userChanged` does. Handle `host/policyApplied` and keep each machine's applied version for the Console. With `requireFollowing`, the router refuses agent starts on a machine whose applied version is not the current one (edge case "a machine of an older version").
- [x] T009 [US2] Add the `policy/*` actions to `audit.controlActions` in `Go/internal/controlplane/audit/audit.go`, with before and after.
- [ ] T010 [US4] Add `Go/internal/controlplane/policybudget.go`: `checkBudgets(user)` from the roll-ups (as `spentToday`, plus tokens), raises, and the sweep of old raises. Call it where `checkCaps` is called. In `bots.go`, `sendHostUser` sends `capReachedUntil` for a person at a budget too.
- [ ] T011 [US4] Add the Requests kind `budget` in `Go/internal/controlplane/console.go`; answering it calls `policy/raise`.
- [x] T012 [US2] Rotation (T4): sign the policy again with the new key at rotation, in `rotate.go`.
- [x] T013 [P] Docs: `docs/explanation/control-plane.md` gains "Policy" and the store keys; `docs/reference/policy.md` (fields).

**Built in the first slice-1 lane (#998, Decided):** T001–T003, T005, T008, T009, T012, T013, and of T006 and T007 all but `PolicyPreview`, `policy/preview`, `policy/askForMore` and `limitTokens`. The signature is ECDSA P-256 (`es256`) with the control key, not Ed25519, because the control key is a P-256 key that machines already trust. **Left for a slice 1b lane** (areas team and reports): T004, T010, T011, `limitTokens` on `UsageRollupRow`, `policy/askForMore` (a Requests kind), and `policy/preview` (with slice 3, which draws it).

**Checkpoint**: `test-servers` walk: two copies, three machines, a policy reaches all three in 5 s, the kill switch flag reaches them, and the audit shows both.

## Phase 2: Slice 2a, enforcement on machines (areas: hosts; a hook in reports' `reportledger.go`)

**Goal**: every machine enforces the policy at every path, offline too. Covers US2, US4, US5, US6 on the machine.

### Tests first

- [x] T014 [US2] Write the ceiling table test in `Go/internal/agentsd/policy_test.go`: every rule × every path of FR-009 (start, helper, workflow, Continue in New, Branch, `setOption` mode and model, workflow and helper `model:`, sandbox set and failure card, marketplace add and enable, `skills/add`, `mcp/add`, `mcp/add-by-hand`, project helper limits, launch environment, `ApplyUserSettings`). 0 escapes (SC-003). A new path with no row fails the test. A looser policy gives back each choice the person had set, unchanged (FR-011).
- [x] T015 [P] [US6] Test the file: a forged, missing, older and newer policy; a rotated key within and after 30 days (SC-005).
- [x] T016 [P] [US5] Test the kill switch: two running turns stop within 5 s, a workflow trigger does not run, a queued prompt stays, turning it off starts nothing (SC-004).
- [x] T017 [P] [US4] Test machine budgets: the machine refuses at its own count; `capReachedUntil` from the control plane wins; an unmetered runtime is refused unless allowed; tokens count for a cost-less runtime (SC-006).
- [x] T018 [P] [US2] Test `requires`: a capability the machine lacks refuses every start with `reason: update`.

### Build

- [x] T019 [US6] Add `Go/internal/agentsd/policy.go`: receive `host/policy` (dispatch in `localpath.go`), verify, keep `<root>/policy.json` 0600, refuse a lower version, send `host/policyApplied`, say `host.policy.1` in `host/hello` (`Go/internal/controllink/uplink.go`). Joined with no trusted policy → `noPolicy`.
- [x] T020 [US2] Add the ceiling checks at each path of T014, with `policyRefused` errors (`PolicyRefusal`). Mode by `modeRanks`; an unknown mode counts as rank 4.
- [x] T021 [US2] Mark refused items with `setBy` in `runtimes/list`, the options lists (`agents/options`, `draftOptions`), `marketplaces/list`, `sandbox/state`, the project's helper limits, `cost/state`, and the pass-through list.
- [x] T022 [US2] Read `<settings>/runtime-environment.json` in `runtimes.go` `environment()`, then cut it to `environment.passThrough` (FR-011a).
- [x] T023 [US2] A running agent meets a new policy at its next turn: lower the mode, or refuse the turn, with a line in the chat (FR-012).
- [x] T024 [US4] Budgets: the policy's `budgets` as a ceiling over `CostLimits` in `costlimits.go`; honour `capReachedUntil` for a person; refuse unmetered runtimes under a budget.
- [x] T025 [US4] Add `limitTokens` to each row in `reportledger.go`.
- [x] T026 [US5] The kill switch: reuse `stopAll` in `turns.go` for running turns, refuse new work, pause workflows and their queues in `workflows.go`.
- [x] T027 [US2] `daemon/policyState` and its notification, so a client on the direct path (#1118) gets the same state.
- [x] T028 [P] Docs: `docs/explanation/organisation-policy.md` (with what it does not protect against), `docs/how-to/limit-spending.md`.

**Checkpoint**: `run-app` on a scratch root joined to a scratch control plane: each rule refused by the wire; control plane stopped and the policy still holds; an edited file refuses work.

## Phase 3: Slice 2b, "Set by your organisation" on every client (areas: runtimes, then chat, marketplace, usage)

**Goal**: US3 on all three clients. One PR per area when those areas are busy, else one PR.

- [x] T030 [US3] Add `Shared/UI/OrgPolicyLine.swift`: a dimmed choice with **Set by your organisation** and the rule in a help tip (Mac) or a detail line (Remote). Web: `Web/src/views/OrgPolicyLine.tsx`.
- [x] T031 [P] [US3] Runtimes area: the runtime list, the model menu (`ModelPill`), the mode menu, the sandbox capsule and failure card, on Mac, Remote and web.
- [x] T032 [P] [US3] Chat area: the new-agent form (`StartAgent`, `NewAgent.tsx`), and the chat line for a refused turn, a lowered mode, the budget line with **Ask for More**, and the kill-switch strip with the composer's reason.
- [x] T033 [P] [US3] Marketplace area: marketplaces not allowed are not listed; **Add by Hand** refused with the line.
- [x] T034 [P] [US3] Usage area: Cost shows the policy's budgets beside the person's, with the line; the helper limits rows in the project pane.
- [x] T035 [US3] Add a row per item of FR-020 to `specs/071-web-remote/walks/parity/`, and run `scripts/parity-counts.py`.

**Checkpoint**: walk the US3 list with `run-app`, the Remote walk simulator and headless Chrome (SC-007). Close each scratch app.

**Built in the slice-2b lane (#998, Decided):** T030–T035 in one PR, because no other open PR held runtimes, chat, marketplace or usage when it opened. `OrgPolicyLine` also has `OrgPolicyMenuItem` (a native menu's dimmed item with the line as its second line), `OrgPolicyStrip`, `OrgBudgetRows` and `PassThroughRows`. The pass-through names are drawn read only where each client lists its runtimes, because no client writes `runtime-environment.json` yet. `daemon/policyState`, `daemon/policyStateChanged` and `settings/passThrough` are tagged `web`. **Left:** **Ask for More** on the budget line waits for slice 1b's `policy/askForMore`; the Remote was built and not walked (#2272).

## Phase 4: Slice 3, the admin policy page (areas: settings, reports)

**Goal**: an admin edits the policy on the web Console; everyone reads it on all three clients; admins have the kill switch everywhere.

- [x] T029 [US3] (moved here from slice 2b, because the pane needs the words first) Add the words and the decoding of `setBy` and `PolicyRefusal` in `Packages/AgentsKit/Sources/AgentsKitCore/Model/OrgPolicy.swift`, with tests (`OrgPolicyWordsTests`); the same in `Web/src/model/orgPolicy.ts` with `Web/test/orgPolicy.test.mjs`. Map the new `OrgPolicy*` files to `settings` in `.agents/areas`, and `OrgPolicyLine*` to `runtimes`.
- [x] T036 [US2] Web: `Web/src/views/ConsoleOrgPolicy.tsx` and a `policy` section in `Web/src/model/console.ts` (group "Rules", before Report Policy): a control per rule, the preview from `policy/preview` ("3 people use Gemini; their agents will be refused"), a warning when no runtime is left, Save with `rev`. Tests in `Web/test/console.test.mjs`.
- [x] T037 [US2] The Console's Machines page shows "Follows policy vN" or **Does not follow policy** (FR-024).
- [ ] T038 [US4] Requests shows `budget` requests with **Raise for Today**.
- [x] T039 [P] [US3] Mac: Settings ▸ Control plane ▸ Policy (`App/Sources/Settings/SettingsWindow.swift`, a new `SettingsPane.policy`), drawing `Shared/UI/OrgPolicyPane.swift`: the rules in words, the last change and its actor, **Edit in Console** for an admin.
- [x] T040 [P] [US3] Remote: the same pane in `Remote/Sources/Settings/` from `Shared/UI/OrgPolicyPane.swift`.
- [x] T041 [P] [US3] Web: `Web/src/views/settings/Policy.tsx` in `sections.ts` (Control plane group).
- [x] T042 [US5] The kill switch on all three panes for admins: **Stop All Agent Work**, a confirmation that names how many agents are running, and **Resume Agent Work**. The red strip on every screen for every person while it is on.
- [x] T043 [P] Docs: `docs/how-to/set-an-organisation-policy.md`; `docs/reference/settings.md`; parity rows for FR-021 and FR-022.

**Built in the slice-3 lane (#998, Decided):** T029, T036, T037, T039–T043. **Left:** T038 (Requests shows `budget` requests with **Raise for Today**) waits for slice 1b's Requests kind `budget` and `policy/askForMore` on the control plane; the preview of T036 says what each rule change refuses from what the Console already reads (the runtimes left, the sandbox and budget rules, machines that do not follow) and not yet who it refuses, which needs slice 1b's `policy/preview`. The red strip on every screen of T042 is slice 2b's (T032, chat area): the store keeps `orgPolicy` from `control/policyChanged` and `control/stopAll` for it, and the Policy pane draws the strip.

**Checkpoint**: headless Chrome walk of Console ▸ Policy end to end; Mac and Remote pane walk; kill switch from the phone stops a turn on a scratch machine.

## Phase 5: Slice 4, MDM and `/etc` pin (areas: hosts, control-plane)

**Goal**: US7.

- [x] T044 [US7] Tests first, in `Go/internal/agentsd/pin_test.go`: `/etc/agents/policy.json` read only when root owns it and nobody else can write it; must join refuses agents, shells and workflows; a code or join for another control plane is refused; another key is ignored and logged once. The path is a parameter, so the test needs no root.
- [x] T045 [US7] Add `Go/internal/agentsd/pin.go` and read it in `Go/cmd/agentsd/`. Refuse `--join` and codes for another control plane, and leaving.
- [x] T046 [US7] Agents Host: read the managed preferences (`ControlPlaneAddress`, `ControlPlaneKey`, `MustJoin`) in `Host/`, pass them to `agentsd`, and show "Your organisation requires this Mac to join <address>." until it has joined. Tests over a `UserDefaults` suite.
- [x] T047 [US7] The window: read the same keys from its own domain; the connect sheet and **Forget** refuse another control plane with **Set by your organisation** (`App/Sources/Control/`).
- [x] T048 [P] Docs: `docs/how-to/pin-machines-with-mdm.md` with a sample `.mobileconfig` that sets both domains, and `/etc/agents/policy.json`.

**Checkpoint**: a scratch Mac account with a test profile (or the managed-preferences test suite when installing a profile needs Alex's hands), and the devbox with `/etc/agents/policy.json`.

## Phase 6: Polish

- [ ] T049 Update `docs/reference/integrations.md` only if a slice changes an integration (none expected).
- [ ] T050 Comment on #999 (T6) with the `runtimes.<id>.reach` rule, on #1001 (T8) with the fields it adds, and on #840 that it needs nothing from T5.
- [ ] T051 Close #998 when slices 1 to 4 have landed.

## Dependencies

- Phase 1 blocks everything.
- Phase 2 (2a) and Phase 4 (3) can run at once: hosts versus settings and reports.
- Phase 3 (2b) needs 2a (the `setBy` marks) and Phase 4 (the words of T029). Phase 5 (4) needs 2a, because both are in hosts. 2b and 4 can run at once.
- Within a phase, tests come first, then the build tasks in order; `[P]` tasks touch different files.
