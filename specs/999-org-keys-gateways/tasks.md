# Tasks: Enterprise T6, org keys and model gateways

**Input**: `spec.md`, `plan.md`, `research.md`, `data-model.md`, `contracts/org-routes-api.md`, `quickstart.md` in `specs/999-org-keys-gateways/`.

**Tests**: the spec asks for automated checks (SC-001 to SC-006), so each slice has test tasks. Write them first.

**Format**: `[ID] [P?] [Story] Description`. `[P]` means a task can run in parallel with the others of its phase (different files).

**Not before v0.10.0 ships.** Nothing here merges to `main` until then (`hold:v0.10`). Slice 1 also waits for T5 slice 1 (#998); slice 2 waits for #840 (PR #2158) and T5 slice 2a.

**Slices**: each phase below is one slice of `plan.md`, one lane, with its own areas, tests and walk. Order: 1 → (2 ‖ 4) → 3.

## Phase 1: Slice 1, routes on the control plane (area: control-plane; a hook in reports)

**Goal**: an admin keeps a route, and each allowed machine gets it sealed to its own key within 5 s. Covers US1, US2 and US4 on the control plane.

### Tests first

- [ ] T001 [US1] Test that a control plane with no route sends `host/orgRoutes {routes: []}` and nothing else changes, in `Go/internal/controlplane/orgroutes_test.go` (SC-001).
- [ ] T002 [P] [US2] Test `orgRoutes/set`: bounds, kinds against each runtime's row of the spec table, `rev` conflict, `version` + 1, a member refused, no method returns a value, the store holds no value (search its bytes, base64 and hex), no keeper → refused (FR-002, FR-003, SC-003).
- [ ] T003 [P] [US2] Test the delivery: two copies, three machines of two people, a route for a group; only allowed machines get it within 5 s; each envelope opens with that machine's key only, and not with another route id, machine id or older version in the associated data (FR-005, SC-002).
- [ ] T004 [P] [US4] Test replace and remove: a new version reaches the machines; a removed route and a person taken out of the group give an empty delivery; the audit has "key replaced" and no value (FR-004).
- [ ] T005 [P] [US7] (Q1 A) Test short-lived tokens with fake STS, OAuth and Entra servers: a machine gets only tokens, a new one about 10 minutes before the old one ends, never the long-lived fields (FR-007).

### Build

- [ ] T006 [US2] Add `OrgRoute`, `OrgRouteKind`, `OrgRouteDelivery`, `DeliveredRoute`, the new `AccountReach` cases and `AccountProfile.source` to `Packages/Wire/daemon.schema.json`; the methods and messages of the contract to `control.openrpc.json` and `daemon.openrpc.json`; `route` on `UsageRollupRow`. Run `scripts/wire.sh gen`, commit what it makes, and do what `WireSchemaTests` says.
- [ ] T007 [US2] Add `Go/internal/controlplane/orgroutes.go`: the records and envelopes (`kms.SealFor`, bound to the store key), bounds, fingerprints, `orgRoutes/*`, admin checks with `isAdmin`, the writes in `methods.go`.
- [ ] T008 [US2] Delivery: for each machine with `host.orgRoutes.1`, the routes its owner (or bot) may use by groups, each secret opened with the keeper and sealed with HPKE to `HostRecord.PublicKey` (as `apns.Seal`, info `com.alexecollins.agents.orgroute.v1`). Send on hello and on change, with a hash dedup as `toldUsers`; tell other copies through the mesh; handle `host/orgRoutesApplied` and `host/orgRoutesAgain`; tell the person and admins which routes a removed machine held.
- [ ] T009 [US7] (Q1 A) Add `Go/internal/controlplane/orgtokens.go`: STS `AssumeRole`, Google service-account OAuth, Entra client credentials; refresh per machine before expiry.
- [ ] T010 [US3] In T5's `policy.go`: the rules `runtimes.<id>.reach` and `notices.antigravityTerms`, their bounds, and `host.orgRoutes.1` in `requires` when set (FR-008).
- [ ] T011 [US4] Add the `orgRoutes/*` actions to `audit.controlActions` (`Go/internal/controlplane/audit/audit.go`), with the fields that changed and no value.
- [ ] T012 [P] Docs: `docs/explanation/org-keys-and-gateways.md` (routes, sealing, what it does not protect against); `docs/reference/integrations.md` "Model gateways" rows per kind.

**Checkpoint**: quickstart step 1.

## Phase 2: Slice 2, the machine: keep, relay, launch (area: hosts; a hook in reports)

**Goal**: a session on an org account reaches the model through the relay, and the key is nowhere a member can read it. Covers US2–US7 on the machine.

### Tests first

- [ ] T013 [US2] Write the leak test in `Go/internal/agentsd/orgroutes_test.go`: for each runtime and kind marked "Yes", start a session with the fake runtime and a fake provider; search the runtime's environment, every file under the root and `~/.agents`, `daemon.log`, `events.jsonl`, the transcript and every message to clients for the key's bytes, base64 and hex: 0 finds (SC-003).
- [ ] T014 [P] [US2] Test the relay in `modelrelay_test.go`: each kind adds its credential (research R3); a wrong stand-in gets 401 and sends nothing; streaming passes through; a body over 32 MiB is refused; the token count equals the usage fields for each answer shape (research R5, SC-006); p95 overhead under 5 ms (SC-005).
- [ ] T015 [P] [US2] Test each runtime's launch (research R2): the variables or config file set, the stand-in, the runtime's own variables from the login environment and the pass-through taken out first; the 056 relay still clears its variables for a sign-in account and is not used for an org account (FR-013, FR-014).
- [ ] T016 [P] [US3] Test `reach` over every path of T5 FR-009 (start, helper, workflow, Continue in New, Branch, `setOption`, `setDefaultAccount`): 0 ways to a sign-in account under "the org path only", 0 gateway variables from the pass-through (SC-004); no route on the machine → `orgRouteMissing`.
- [ ] T017 [P] [US4] Test replace (the next request uses the new key, no request fails) and remove (sessions stop with the line, the file is gone, the account leaves the list) (FR-018).
- [ ] T018 [P] [US7] Test offline: the route holds across a restart with the control plane down; a file that does not open is deleted and asked again; (Q1 A) an ended token gives `orgRouteExpired`.
- [ ] T019 [P] [US6] Test `notices.antigravityTerms`: `show`, `accepted` (no notice, the line), `refuse` (start and sign-in refused).

### Build

- [ ] T020 [US2] Add `Go/internal/agentsd/orgroutes.go`: receive `host/orgRoutes`, keep each envelope in `<root>/org-routes/<id>.json` (0600), open in memory with the machine's key, delete what is gone, send `host/orgRoutesApplied`, say `host.orgRoutes.1` in `host/hello`.
- [ ] T021 [US2] List each route as an `AccountProfile` for each runtime it serves (`source: organisation`, id `org:<route>`) in `runtimes/accountProfiles`, beside #840's accounts in `accounts.go`; make the account folders under `<root>/runtimes/org/` with the person's settings linked in, as #840 does.
- [ ] T022 [US2] Add `Go/internal/agentsd/modelrelay.go`: one TLS listener on loopback, its CA in `<root>/runtimes/model-relay-ca.pem`, a stand-in per session, the credentials of research R3, streaming, the token count of research R5, out on 429 by the #840 account key (FR-011, FR-012, FR-019, FR-020).
- [ ] T023 [US2] The launch per runtime and kind in `runtimes.go` `launchFor` (research R2). Rows marked "measure" are checked against the real CLI with the fake provider before they are built; a row that fails is left out and written down in `docs/reference/runtimes.md`.
- [ ] T024 [US3] `reach` and the pass-through cut in T5's `policy.go` (agentsd) at each path; `setBy` on refused accounts; `runtimes/setDefaultAccount` and the default from `defaultFor` (FR-015, FR-016).
- [ ] T025 [US6] `notices.antigravityTerms` on the sign-in methods and on start (FR-017).
- [ ] T026 [US4] Stop the sessions of a removed route with `orgRouteRemoved` (FR-018).
- [ ] T027 [US5] `route` and `relayTokens` on each turn and each roll-up row in `reportledger.go`; T5's `limitTokens` uses `relayTokens` (FR-021, FR-022).
- [ ] T028 [P] Docs: `docs/reference/runtimes.md` (org accounts, the table with the variables).

**Checkpoint**: quickstart step 2, on a `run-app` scratch root and on the devbox.

## Phase 3: Slice 4, the admin Console (areas: reports, settings)

**Goal**: an admin manages routes and the two rules on the web page; everyone reads them. Runs beside Phase 2.

- [x] T029 [US2] Add the words of the org account (**From your organisation**, **Organisation · No plan limit**, the refusals of the contract) to `Packages/AgentsKit/Sources/AgentsKitCore/Runtimes/OrgAccountWords.swift` (new) with `OrgAccountWordsTests`, and to `Web/src/model/orgAccounts.ts` (new) with `Web/test/orgAccounts.test.mjs`.
- [x] T030 [US2] Web: `Web/src/views/ConsoleModelAccess.tsx` and a `modelAccess` section in `Web/src/model/console.ts` (group "Rules", after Policy): the routes, **Add Route** per kind with write-only secret fields, model map, groups, default for, **Check**, **Replace Key**, **Remove** with a question, machines that hold each route, tokens this month. Tests in `Web/test/console.test.mjs`.
- [x] T031 [US3] Console ▸ Policy (T5): **Reaches the model by** per runtime and **Antigravity's terms**, with the preview (FR-028).
- [ ] T032 [US5] Console ▸ Reports: tokens by route, person and day (FR-021).
- [x] T033 [P] [US3] The read-only Policy pane (T5, `Shared/UI/OrgPolicyPane.swift`, `Web/src/views/settings/Policy.tsx`): the routes the person may use, and the Antigravity line (FR-029).
- [x] T034 [P] Docs: `docs/how-to/add-an-org-key-or-gateway.md`, `docs/reference/policy.md` (the two rules).

**Built in the slice-4 lane (#999, Decided):** T029, T030, T031, T033, T034. The words are in `Runtimes/OrgAccountWords.swift` and `Web/src/model/orgAccounts.ts`; the hand-written Swift types of `orgRoutes/*` are in `Runtimes/OrgAccount.swift`, for WebSignatures. **Left:** T032 (Console ▸ Reports by route) and Model Access's "tokens this month": both need `route` on each usage roll-up row, which slice 2's T027 (hosts) adds, and the control plane's sum by route; the preview's "4 people use their own Claude sign-in" needs T5 slice 1b's `policy/preview`.

**Checkpoint**: quickstart step 4.

## Phase 4: Slice 3, members on every client (areas: runtimes, then chat, then usage)

**Goal**: US2, US3 and US5 on the Mac, the Remote and the web page. One PR per area when those areas are busy.

- [x] T035 [US2] Runtimes area: `AccountProfile` decodes the new reaches and `source` (`AccountProfile.swift`, `AccountProfileTests`, `Web/src/model/runtimes.ts`); org rows on the Runtimes page (Mac `App/Sources/Runtimes/`, Remote `RuntimesView.swift`, web `Activity.tsx` rows) with **From your organisation**; **Reaches the Model By** in the runtime's sign-in sheet (Mac) and its row (Remote, web); refused choices dimmed with T5's line (FR-023, FR-024).
- [x] T036 [US2] Chat area: the account picker shows org accounts, and shows when a runtime has one (Mac `PromptBar.swift`, Remote `StartAgent/ChoiceRows.swift`, web `NewAgent.tsx`); the chat lines for `orgRouteRemoved`, `orgRouteMissing`, `orgRouteExpired` and a refused turn, with **Continue in New**.
- [x] T037 [US5] Usage area: the allowance row **Organisation · No plan limit**, today's tokens, "Out until …"; a reported cost says "list price, as <runtime> reports it" (FR-025).
- [x] T038 [US6] Runtimes area: the Antigravity sign-in sheet on all three draws no notice under `accepted` and the line in its place (FR-017).
- [x] T039 Add rows for FR-023 to FR-025 and FR-029 to `specs/071-web-remote/walks/parity/` and run `scripts/parity-counts.py`.
- [x] T040 [P] Docs: `docs/how-to/limit-spending.md` (tokens on an org account).

**Checkpoint**: quickstart step 3 on all three clients (SC-007 for the fake provider). Close each scratch app.

## Phase 5: Polish

- [ ] T041 Update `docs/reference/integrations.md` rows to their walked state per kind.
- [ ] T042 Put one item per kind (Bedrock, Vertex, Azure, base URL, org key) on Alex's 0.11 checklist (`alex-todo`): where the account is and what to check. Not a gate (#1782).
- [ ] T043 Close #999 when slices 1 to 4 have landed.

## Dependencies

- Phase 1 needs T5 slice 1 and blocks everything else.
- Phase 2 needs Phase 1, #840 and T5 slice 2a (all hosts: one after the other).
- Phase 3 (slice 4) needs Phase 1 and T5 slice 3; it runs beside Phase 2 (reports and settings against hosts).
- Phase 4 (slice 3) needs Phase 2 (the accounts on the wire) and Phase 3 (the words of T029).
- Within a phase, tests come first, then the build tasks in order; `[P]` tasks touch different files.

## Requirement coverage

| FR | Tasks |
|---|---|
| FR-001–FR-006 | T002–T004, T006–T008, T011 |
| FR-007 | T005, T009 |
| FR-008 | T010 |
| FR-009, FR-010 | T013, T018, T020, T021 |
| FR-011, FR-012 | T014, T022 |
| FR-013, FR-014 | T015, T023 |
| FR-015, FR-016 | T016, T024 |
| FR-017 | T019, T025, T038 |
| FR-018 | T017, T026 |
| FR-019–FR-022 | T014, T022, T027, T032 |
| FR-023–FR-026 | T035–T037, T013 (FR-026 by the leak search over client messages) |
| FR-027, FR-028 | T030, T031 |
| FR-029 | T033 |
