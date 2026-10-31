# Tasks: Policy layers: Organisation, You, Folder

**Input**: `spec.md`, `plan.md`, `research.md`, `data-model.md`, `contracts/policy-layers-api.md`, `quickstart.md` in `specs/2957-policy-layers/`.

**Tests**: the spec asks for automated checks (SC-001 to SC-006), so each slice has test tasks. Write them first.

**Format**: `[ID] [P?] [Story] Description`. `[P]` means a task can run in parallel with the others of its phase (different files, no dependency on an incomplete task of the same phase).

**Slices**: each phase below is one slice of `plan.md`'s "Slices for the build" table — one lane, one worktree, one pull request, its own areas, tests and walk (#873). Order: 1 → 2 → 3 → (4 ‖ the Console task of 6, once `reports` is free) → 5 → 6. Slices 2 and 3 both hold the area `machines`, so they run one after the other, never at once. Slices 4, 5 and 6 change what a client shows, so each is a UI enhancement: open with auto-merge off, the screenshots of the walk below, and the label `needs-approval`, and wait for Alex (AGENTS.md, "A UI enhancement waits for Alex").

## Phase 1: Slice 1, rules and resolver (areas: `-`, machines; needs: none; walk: none, Go tests only)

**Goal**: `PolicyRules`, `EffectivePolicy` and the one order per rule (FR-004) exist and pass the SC-003 table test, so slices 2 and 3 have one resolver to call. Foundational: no user story is independently testable from this slice alone.

### Tests first

- [ ] T001 [P] Write the SC-003 table test in `Go/internal/policylayers/resolve_test.go`: for every rule and every pair of layers (organisation, you, folder), with the tightest value set in each layer in turn, assert the resolved effective value is never looser than the tightest layer that sets it (0 escapes).
- [ ] T002 [P] Write `Go/internal/policylayers/order_test.go` against the FR-004 table: permission mode tighter is lower (Bypass Permissions → Approve for me → Ask → Plan); permission requests tighter is Ask me; sandbox tighter order Off allowed → The runtime's → On; money and tokens tighter is less; helpers, workflows, notices-in-a-burst tighter is fewer; wait-after-a-burst tighter is longer; the archive switch tighter is off; runtimes/models/marketplaces/variables tighter is fewer (a name a layer leaves out is not allowed); connectors added by hand tighter is refuse.
- [ ] T003 [P] Write `Go/internal/policylayers/validate_test.go`: `Validate` rejects a layer over 16 KiB, an unknown enum value, and a number out of its range — `budgets.perAgentTokens`/`dailyTokens` "integer ≥ 1", `helpers.mostRunning` "1–10", `helpers.mostNotArchived` "1–20", `workflows.mostOn` "1–100", `noticeLimits.burst` "1–20", `noticeLimits.waitMinutes` "1–1440" (data-model.md "PolicyRules") — and ignores-and-logs-once an unknown field.

### Build

- [ ] T004 Add to `Packages/Wire/daemon.schema.json`: `PolicyRules` (fields `permissionMode: plan|ask|approveForMe|bypassPermissions`, `permissionRequests: default|alwaysApprove`, `sandbox: off|runtime|on`, `budgets: {perAgent, daily: Cost; perAgentTokens, dailyTokens: integer ≥ 1}`, `helpers` (existing `PolicyHelpers`), `workflows: {mostOn: 1–100}`, `noticeLimits: {burst: 1–20, waitMinutes: 1–1440}`, `archiveMyChats: boolean`, `runtimes` (existing map), `marketplaces` (existing), `environment` (existing)), `EffectivePolicy`, `EffectiveRule`, `EffectiveLayerValue`, `PolicyLayerRef` (data-model.md). Extend `PolicyRefusal` with `layer: PolicyLayerRef` and `value: string`; extend `PolicySetBy` with `by: organisation|you|folder` and `layer: PolicyLayerRef`. Run `scripts/wire.sh gen`, commit `Web/src/protocol/generated.ts` and `Go/wire/*_gen.go`, and do what `WireSchemaTests` says in Swift.
- [ ] T005 Add `Go/internal/policylayers/order.go`: one `Order` function per rule of T002's table, each returning a rank from loosest to tightest.
- [ ] T006 Add `Go/internal/policylayers/resolve.go`: `Resolve(layers []Layer) EffectivePolicy` (data-model.md "Resolve") — for each rule, take the layers that set it from the top down (organisation, the empty `groups` slot, you, folder); the effective value is the tightest by `Order`; `decides` is the highest layer with the effective value; every other layer whose value is looser is marked `kept`; a list rule (runtimes, models, marketplaces, environment) resolves to the intersection, with a trailing `*` matching a prefix, and `decides` is the highest layer whose list removes a name a lower layer allows.
- [ ] T007 Add `Go/internal/policylayers/looser.go`: `Looser(approved, next PolicyRules) bool`, true only when `next` sets any rule looser than `approved` by that rule's `Order` (used by slice 3's folder guard, research R10).
- [ ] T008 Add `Go/internal/policylayers/validate.go`: `Validate(PolicyRules) error` enforcing T003's ranges and enum values, rejecting a document of 16 KiB or more, rejecting a list entry with an empty name, and ignoring (with a once-only log) a field it does not recognise.
- [ ] T009 Add the capability `host.policy-layers/1` to `Packages/Wire/daemon.openrpc.json`'s `x-declared-capabilities` and `Go/internal/agentsd/capabilities.go`, so slice 2's new methods have a capability to require.
- [ ] T010 [P] Lease `build`, run `Go/scripts/go.sh test ./internal/policylayers/...`, fix until T001–T003 pass, then release `build`.

**Checkpoint** (quickstart.md Slice 1): the table test passes for every rule × every pair of layers × the tightest in each layer (SC-003: 0 escapes); `Looser` is true only for a looser rule; an unknown field is ignored; a 17 KiB layer is refused.

---

## Phase 2: Slice 2, your layer on the machine (areas: machines, control-plane (`controllink`); needs: Phase 1; walk: `run-app` on a scratch root)

**Goal**: a person's own layer lives on their Mac's host, signed, and every place of FR-007 reads the effective policy instead of the old files and the organisation-only ceiling. Covers US1 (a person alone sets every rule) and the single-machine part of US5 (a refusal names its layer).

### Tests first

- [ ] T011 [P] [US1] Write `Go/internal/controllink/personkey_test.go`: making the person key (ECDSA P-256) on the first save of your layer; keeping it in the Keychain (account `person-key`) on a Mac, or a 0600 file `<root>/person-key` on a scratch root or Linux; signing and verifying `YourPolicy`'s `CanonicalJSON` with `SignPolicy`/`VerifyPolicy` (alg `es256`, `KeyID`); a `PersonKeyRotation` record that checks only against the previously pinned key.
- [ ] T012 [P] [US1] Write `Go/internal/agentsd/policyyours_test.go`: the first-start move (FR-012, research R9) — `limits.json` → `budgets`; `workflow-limit.json`'s `total` → `workflows.mostOn`, only when the file exists; `display.json`'s `noticeBurst`/`noticeCooldownMinutes` → `noticeLimits`, only when set; `agentsMayArchiveMyChats: false` → `archiveMyChats: false`; `runtime-environment.json` → `environment`; each old file is renamed `<name>.moved` (or its moved keys removed from `display.json`) so nothing reads it again (SC-001). Permission mode, permission requests and sandbox are not moved (today "unset" already means no limit).
- [ ] T013 [P] [US1] Write `Go/internal/agentsd/policy_test.go` additions: `policy/setYours` refused `forbidden` from the agent socket role, an MCP tool and a workflow (FR-010, SC-004); refused `conflict` when `revision` is not the current one; refused `notKeeper` with the keeper's name on a machine that is not the keeper; refused `invalid` when `policylayers.Validate` fails.
- [ ] T014 [P] [US5] Write a refusal test per place of FR-007 (agent start, helper start, workflow run, Continue in New and Branch, mode and model changes, sandbox resolution, the permission flow, marketplace and connector adds, the turn and day budgets, the notice limit, archive requests, the runtime launch environment): when your layer is the tightest, the refusal's `layer.kind` is `you` and names the rule.

### Build

- [ ] T015 [US1] Add to `Packages/Wire/daemon.schema.json`: `YourPolicy` (`rules: PolicyRules`, `revision: integer`, `changed: WireDate`, `changedFrom: {client, kind: mac|remote|web}`, `person: string`, `keeper: string`), `SignedYourPolicy` (`policy: string` (base64 `CanonicalJSON`), `signature: PolicySignature`, `rotation?: PersonKeyRotation`), `PersonKeyRotation` (`newKey, newKeyID, signature`), `PinnedPersonKey` (`key, keyID, from: joinCode|window|controlPlane, at: WireDate`). Add `policy/effective`, `policy/yours`, `policy/setYours` to `Packages/Wire/daemon.openrpc.json`, each `x-capability: host.policy-layers/1`. Run `scripts/wire.sh gen`, commit the generated files, and do what `WireSchemaTests` says in Swift.
- [ ] T016 [US1] Add `Go/internal/controllink/personkey.go` and `personkey_darwin.go`: make the person key on first save; keep it in the Keychain (the pattern of `controllink/hostkey_darwin.go`, account `person-key`) or a 0600 file elsewhere; sign and verify with `controllink.SignPolicy`/`VerifyPolicy`; build and check a `PersonKeyRotation` record.
- [ ] T017 [US1] Add `Go/internal/agentsd/policyyours.go`: keep `<settings>/policy-yours.json`; sign on the keeper; on a non-keeper, verify a copy, refuse a lower revision or a failed signature, keep the last good copy, and log the failure once (FR-011); `policy/yours` (reports which machine is the keeper); `policy/setYours` (the refusals of T013); the first-start move of T012/research R9.
- [ ] T018 [US1] Change `Go/internal/agentsd/policy.go`: resolve the effective policy per folder with `policylayers.Resolve` — one `Effective` for "no folder", one per folder with a layer, remade whenever any layer changes — instead of reading only `d.orgPolicy()`; add `policy/effective {folder?}`, filling `EffectivePolicy.behind` with the person's machines that do not say `host.policy-layers/1` (Edge Cases, "A machine of an older version"; data-model.md `EffectivePolicy`).
- [ ] T019 [US1] Rewire `Go/internal/agentsd/costlimits.go`, `cost.go`, `workflows.go`, `notify.go`, `archiverequests.go`, `passthrough.go`, `helpers.go`, `folders.go`, `autopick.go`, `sandbox.go`, `host.go`, `turns.go`, `helperstart.go` to read T018's effective value instead of `limits.json`, `workflow-limit.json`, the notice keys of `display.json`, `agentsMayArchiveMyChats`, and `runtime-environment.json`. Those files are not read again once T017's first-start move has run (FR-012). In `costlimits.go`, keep today's rule that a runtime reporting neither a cost nor tokens is refused only when the budget rule's `EffectiveRule.decides.kind` is `organisation` (spec Decisions, "Unmeasured runtimes under your budget"): your layer's and a folder's budgets must not cap it.
- [ ] T020 [US5] Extend every refusal of T019's places to carry `layer: PolicyLayerRef` and `value` (research R8): "Acme: at most Approve for me", "Your policy: at most $40 a day", "`<folder>`: at most Ask". Extend `PolicySetBy.by` (`organisation|you|folder`) with `layer` on `runtimes/list`, the mode and model lists, `marketplaces/list`, `sandbox/state`, `cost/state`, `workflows/limit`, `FolderSummary.helperLimits`, `settings/passThrough`.
- [ ] T021 [US1] Wire `permissionMode` into `autopick.go`'s `resolveLevels`/`applyLevels` per FR-008: the effective value is both the mode Auto gives a new agent and the loosest a person, agent, helper or workflow may choose; a person may still choose a tighter mode for one session.
- [ ] T022 [P] Lease `build`, run `Go/scripts/go.sh test ./internal/agentsd/... ./internal/controllink/...`, fix until T011–T014 pass, then release `build`.

**Checkpoint** (quickstart.md Slice 2): on a scratch root with no control plane, write the old files, start the scratch app — `policy/yours` has the moved values and the old files are renamed `.moved` (SC-001); `policy/setYours` called from the agent socket role is refused `forbidden` (SC-004); set `permissionMode: ask`, ask an agent for Approve for me — refused with `layer.kind: you`, rule `permissionMode`; each rule of FR-007 stops an agent once, each refusal naming its rule and layer.

---

## Phase 3: Slice 3, folder layer and transport (areas: machines, team, control-plane; needs: Phase 2; walk: `test-servers` with the devbox)

**Goal**: a folder can set tighter rules in a committed file, and your layer reaches every machine of yours, online or not. Covers US3 (a folder tightens its own rules) and US6 (one layer on every machine), plus the organisation's new fields.

### Tests first

- [ ] T023 [P] [US3] Write `Go/internal/agentsd/policyfolder_test.go`: `.agents/policy.json` is written with only the rules the folder sets, sorted keys, two-space indents, a trailing newline (FR-014); a change from outside the app that only tightens a rule applies at once with the notice `policy.folderTightened`; a change that loosens any rule is `Pending`, the last approved copy applies, and the guarded-file actions (`Allow`, `Keep <old>`/Undo, `Show Change`) behave as `.agents/folder.json`'s guard (#502); an invalid file (not JSON, or a value out of range) is pending with the reason; an unknown rule name is ignored and logged once; a folder value looser than your effective value is kept and reported "Capped by yours" (US3 scenario 6).
- [ ] T024 [P] [US6] Write `Go/internal/controllink/personkey_test.go` additions for data-model.md's "State transitions": no pin → pinned, from a join code, the window's direct link, or the first control-plane copy (trust-on-first-use, logged); pinned → applies a copy only when the signature checks and the revision is higher; pinned → keeps its own and logs once when a copy's signature fails or its revision is not higher; a rotation record moves the pin only when it checks against the currently pinned key.
- [ ] T025 [P] [US6] Write a control-plane test (`Go/internal/controlplane/userscope_test.go` or equivalent): the user-scope part `policy` stores and forwards `SignedYourPolicy` unchanged; only the keeper's `user/setPolicy` may set it; a push reaches every machine that says `host.policy-layers/1` within 5 seconds of a change (SC-005) and on connect; a machine without that capability is skipped; an offline machine that reconnects gets the newest copy, not an older queued one.
- [ ] T026 [P] Write a test that the organisation's `modeCeiling` is read once into `permissionMode` per research R5's map (`ask`→`plan`, `default`→`ask`, `acceptEdits`→`approveForMe`, `auto`→`approveForMe`, `bypassPermissions`→`bypassPermissions`) and the result re-signed as a new version; `sandbox: required` reads as `on`.

### Build

- [ ] T027 [US3] Add `Go/internal/agentsd/policyfolder.go`: read and write `.agents/policy.json` in the stable order of T023; guard it as `.agents/folder.json` is (`guarded.go`, `folderwatch.go`), with research R10's tighter-only fast path (`policylayers.Looser` decides apply-at-once versus pending); the events `policy.folderTightened` and `policy.yoursApplied`; `policy/folder` and `policy/setFolder` (a value looser than your effective value is kept and marked "Capped by yours").
- [ ] T028 [US3] Add `FolderPolicyState` to `<root>/guarded-files.json` (data-model.md), keyed by the file's path so each worktree of the folder has its own approved copy (Edge Cases, "A folder with several worktrees").
- [ ] T029 [US3] Move the folder helper limits (FR-015): stop reading `.agents/folder.json`'s `helperLimits.running` and `helperLimits.notArchived` in `Go/internal/agentsd/helpers.go` and `folders.go`; `folders/setHelperLimits` loses those two keys; `helpers.go`'s `helperLimitsIn` reads `helpers.mostRunning`/`helpers.mostNotArchived` from the effective policy instead. `.agents/folder.json`'s other `helperLimits` keys are unchanged.
- [ ] T030 [US6] Extend `Go/internal/controllink/membership.go`: pin the `PinnedPersonKey` at `<root>/person-key.pub.json` (0600) from a join code (path 1), the Mac window's direct link via `policy/applyYours` (path 2), or the first control-plane copy (path 3, trust-on-first-use, logged once); accept a `PersonKeyRotation` only when it checks against the key currently pinned.
- [ ] T031 [US6] Add `policy/applyYours` to `Packages/Wire/daemon.openrpc.json` (`x-capability: host.policy-layers/1`) and `Go/internal/agentsd/policyyours.go`: the Mac window's direct link to a server pins the key when none is pinned and applies the layer; refused `signature` or `older`.
- [ ] T032 [US6] Add the user-scope part `policy` in `Go/internal/controlplane/userscope.go` and `usersettings/`: store and forward `SignedYourPolicy`; drop the parts `costLimits` and `notifications`; add `user/setPolicy` (host only, only from the keeper; checks the revision goes up; does not sign or change the policy); push it in `host/userSettings` to machines that say `host.policy-layers/1`, on connect and within 5 seconds of a change.
- [ ] T033 [US6] Change `Go/internal/agentsd/usersettings.go`'s `ApplyUserSettings` to apply the part `policy` (verify the signature, keep the newest good copy per T017's rule, log a failure once).
- [ ] T034 Remove the methods `cost/setLimits`, `workflows/setLimit`, `user/setNoticeLimits`, and the `preferences/set` keys `noticeBurst`, `noticeCooldownMinutes`, `agentsMayArchiveMyChats` (contracts/policy-layers-api.md "Methods that go"). `cost/state` and `workflows/limit` stay and read the effective values, with `setBy`. The shared notice bucket (`noticebucket`) reads the burst and the wait from the stored layer and the organisation, the tighter of the two.
- [ ] T035 [US3] Change `Go/internal/controlplane/policy.go`: add `OrgPolicy`'s new optional fields `permissionMode`, `permissionRequests`, `workflows`, `noticeLimits`, `archiveMyChats`; read `modeCeiling` once into `permissionMode` per T026's map and sign a new version, then drop `modeCeiling`; `sandbox` gains the value `runtime` (`required` means `on`); set `requires: host.policy-layers/1` on the signed policy whenever any new field is set.
- [ ] T036 [P] Lease `build`, run `Go/scripts/go.sh test ./internal/agentsd/... ./internal/controlplane/... ./internal/controllink/...`, fix until T023–T026 pass, then release `build`.
- [ ] T037 [P] Lease `build`, run `scripts/go-changed.sh` before pushing, then release `build`.

**Checkpoint** (quickstart.md Slice 3): write `.agents/policy.json` by hand — tightens at once with `policy.folderTightened`; change it to loosen — pending, `Allow`/`Undo` behave; join the devbox with a join code from the scratch window, set `budgets.perAgent` $5 on the Mac — the devbox applies it within 5 seconds (SC-005); edit the devbox's `policy-yours.json` by hand — it keeps its last good copy and logs the failed check once; stop the devbox's link, change your layer, start the link — the devbox gets the newest copy; add the devbox as a server with no control plane — `policy/applyYours` pins the key and applies the layer.

---

## Phase 4: Slice 4, Agents ▸ Policy on Mac and web (areas: settings, usage, runtimes; needs: Phases 2 and 3; UI enhancement; walk: `run-app` Mac + headless Chrome)

**Goal**: a person sees and edits every rule in one pane, on the Mac and the web page. Covers US1, US2 and US4 on those two clients.

- [ ] T038 [US1] Add `Packages/AgentsKit/Sources/AgentsKitCore/Model/PolicyLayers.swift` (and a `PolicyLayersWords.swift`): decode `PolicyRules`, `EffectivePolicy`, `EffectiveRule`, `EffectiveLayerValue`, `PolicyLayerRef`; the client words of contracts/policy-layers-api.md ("`<layer>`: at most `<value>`", "Kept, not used", "Same as yours", "Capped by yours", both banner lines). Tests: `PolicyLayersWordsTests`.
- [ ] T039 [P] [US1] Add `Web/src/model/policyLayers.ts` with the same decoding and words as T038; tests in `Web/test/policyLayers.test.mjs`.
- [ ] T040 [US2] Add the scope `agents` (title **Agents**) to `Shared/UI/SettingsScope.swift`, with `policy`, `spending`, `resources` (research R14); move Spending and Resources out of the Machines group. Add the same group to `Web/src/views/settings/sections.ts`.
- [ ] T041 [US1] Add `Shared/UI/PolicyPane.swift`: the five sections of FR-002 (Permissions, Money, Work at once, Your attention, Tools); the banner of FR-021 ("`<organisation>` sets limits above yours" with a link to Organisation Policy, or "You set every limit" with the count of folders that have their own rules — frame C); when `EffectivePolicy.behind` is non-empty, a line naming which machines do not follow the new layer yet (Edge Cases, "A machine of an older version").
- [ ] T042 [US2] Add `Shared/UI/PolicyRuleRow.swift`: the row's effective value; a capped row shows 🔒 and the line naming the layer and its value (FR-019); its menu shows the values above the cap, dimmed, with the reason; your own value above a cap shows "Kept, not used".
- [ ] T043 [US4] Add `Shared/UI/PolicySourcePopover.swift`: "Where this comes from" — every layer from the top down with its value or "Not set", the deciding layer lit, a folder layer named by its file `.agents/policy.json` and marked "committed with the folder's code" (FR-020, frame B).
- [ ] T044 [US1] Change `App/Sources/Settings/SettingsWindow.swift` to add the Agents group's three panes; `App/Sources/Settings/CostSettingsView.swift` loses its limit fields (they move to Agents ▸ Policy); `App/Sources/Settings/AutoSettingsView.swift` keeps only each runtime's own name for each level.
- [ ] T045 [US1] Change `App/Sources/AppModel.swift`: drop the `cost/setLimits` and `workflows/setLimit` pushes of `refreshServer`; call `policy/applyYours` on the window's direct link to a server on connect.
- [ ] T046 [US2] Generalise `Shared/UI/OrgPolicyLine.swift` to name any layer (organisation, you or a folder), not only the organisation.
- [ ] T047 [US1] Remove the rows of `Shared/UI/NotificationLimitsSection.swift` (This app ▸ Notifications goes, FR-023); remove the archive-switch row from `Shared/UI/SidebarSettingsSection.swift`.
- [ ] T048 [US2] Change `Shared/UI/OrgPolicyPane.swift`'s title to **Organisation Policy** (FR-024); show the organisation's new rules of FR-003 and the permission mode in the four words of FR-002.
- [ ] T049 [P] [US1] Add `Web/src/views/settings/AgentsPolicy.tsx` (the same sections and banner as T041) and `Web/src/views/settings/PolicySource.tsx` (the same popover as T043); add both to `sections.ts`'s Agents group.
- [ ] T050 [P] [US1] Remove `Web/src/views/settings/Notifications.tsx`'s page (FR-023); remove the archive-switch row from `FinishedChats.tsx`.
- [ ] T051 [P] [US2] Retitle `Web/src/views/settings/Policy.tsx` **Organisation Policy**.
- [ ] T052 [US2] Remove the helper-limit fields from `App/Sources/Folders/FolderSettingsSheet.swift`'s General section (FR-015, FR-023); they move to Folder Settings ▸ Policy in slice 5.
- [ ] T053 [P] Docs: `docs/explanation/policy-layers.md` (new), `docs/reference/policy.md`, `docs/reference/settings.md`, `docs/explanation/organisation-policy.md`, `docs/how-to/set-an-organisation-policy.md`, `docs/how-to/limit-spending.md`, `docs/how-to/mute-notifications.md`, `docs/how-to/use-auto.md` — the parts of the spec's Docs section this slice ships.
- [ ] T054 Add rows for Agents ▸ Policy and Where this comes from, and remove the Notifications row, in `specs/071-web-remote/walks/parity/settings-and-project-settings.md` and `notifications-and-badges.md`; run `scripts/parity-counts.py`.
- [ ] T055 Lease `build`, run `scripts/web.sh build` to check the web change; walk frames A, B, C and F of quickstart.md with `run-app` (Mac) and headless Chrome; take the screenshots for Alex's approval (`pr-shots.sh`), release `build`.

**Checkpoint** (quickstart.md "Slices 4 to 6" table, frames A/B/C/F rows): the banner, the capped row with 🔒 and the line, "Kept, not used", Where this comes from, and the old panes' removal, on both Mac and web; `swift test` (filtered by `scripts/select-test-suites.sh`), `WireSchemaTests`, and `Web/test/policyLayers.test.mjs` green under the `build` lease.

---

## Phase 5: Slice 5, folder layer and the stop card on clients (areas: folders, chat, settings; needs: Phase 4; UI enhancement; walk: `run-app` Mac + headless Chrome, frames D and E)

**Goal**: a person sets a folder's rules in Folder Settings ▸ Policy, and a chat card names the rule and layer that stopped an agent. Covers US3 and US5 on the Mac and web.

- [ ] T056 [US3] Add a **Policy** pane to `App/Sources/Folders/FolderSettingsSheet.swift`: every row starts "Same as yours" with the person's value (FR-022); its menu dims the values looser than the person's effective value, with "Your policy allows at most …".
- [ ] T057 [P] [US3] Web: add the folder list inside `Web/src/views/settings/AgentsPolicy.tsx` — the banner's "`<n>` folders have their own rules" opens a list, and each folder opens its layer in the same pane (research R13).
- [ ] T058 [US3] Extend the guarded-change card for a policy change: `Shared/UI/Chat/GuardedChangeCard.swift` and `Web/src/views/GuardedChange.tsx` draw `GuardedChange.policy: {looser: [PolicyRuleName], words}` (contracts/policy-layers-api.md) as frame D's **Allow**, **Keep `<old value>`**, **Show Change**.
- [ ] T059 [US5] Add `Shared/UI/Chat/PolicyStopCard.swift`: "Stopped by a policy" with the rule, the layer and the value (FR-025); **Change** opens that layer's pane at the rule, offered only for a layer the person can edit (You or a folder); **Ask for More** for an organisation budget; **See Organisation Policy** for any other organisation rule.
- [ ] T060 [P] [US5] Add `Web/src/views/chat/PolicyStopCard.tsx` with the same behaviour as T059.
- [ ] T061 Add the Stopped-by-a-policy row to `specs/071-web-remote/walks/parity/chat-turns-and-turn-detail.md`, and the Folder Settings ▸ Policy rows to `settings-and-project-settings.md`; run `scripts/parity-counts.py`.
- [ ] T062 [P] Docs: `docs/how-to/set-rules-for-a-folder.md` (new), `docs/reference/agents-folder.md`.
- [ ] T063 Lease `build`, walk frames D and E of quickstart.md with `run-app` (Mac) and headless Chrome, take the screenshots for Alex's approval (`pr-shots.sh`), release `build`.

**Checkpoint**: quickstart.md frames D and E on Mac and web — a tighter folder change applies with a notice; a looser one waits with Allow/Keep/Show Change; a stop names the rule and the layer, with Change only for an editable layer.

---

## Phase 6: Slice 6, Remote and Console (areas: settings, chat, reports; needs: Phases 4 and 5; UI enhancement; walk: the walk simulator for the Remote, headless Chrome for the Console)

**Goal**: the Remote reads every rule and keeps the edit of the two it edits today; the Console shows the organisation's new rules in the four permission words. Covers US6's client parity, and completes US2/US3/US5 on the Remote.

- [ ] T064 [US1] Add Agents ▸ Policy to `Remote/Sources/Settings/`: read only, except the notice burst/wait and the archive switch stay editable (FR-027, spec Decisions "Tier").
- [ ] T065 [US4] Add the "Where this comes from" popover to `Remote/Sources/Settings/`, read only.
- [ ] T066 [US5] Add the Stopped-by-a-policy card to `Remote/Sources/Chat/` (FR-027).
- [ ] T067 [US3] Add the guarded-change card's policy words to `Remote/Sources/Chat/`, read only (the Remote has no Folder Settings).
- [ ] T068 [US2] Change `Web/src/views/ConsoleOrgPolicy.tsx` and `Web/src/model/orgPolicy.ts`: the organisation's new rules of FR-003, and the permission mode shown in the four words of FR-002 (Clarifications: "Auto's levels, on every layer and every client"). Tests in `Web/test/console.test.mjs` and `Web/test/orgPolicy.test.mjs`.
- [ ] T069 File the parity issue for editing every other rule on the Remote (FR-027, "the rest is read only on the Remote at first, with a parity issue for the rest").
- [ ] T070 Add the Remote's rows to `specs/071-web-remote/walks/parity/settings-and-project-settings.md`, `notifications-and-badges.md` and `chat-turns-and-turn-detail.md`; run `scripts/parity-counts.py`.
- [ ] T071 Lease `build`, walk the Remote's "Remote edits" row of quickstart.md's table with the walk simulator, and the Console with headless Chrome, take the screenshots for Alex's approval (`pr-shots.sh`), release `build`.

**Checkpoint**: quickstart.md's full table, across Mac, web and Remote (SC-006: every capped row and every Stopped-by-a-policy card names the layer, on all three clients).

---

## Phase 7: Polish

- [ ] T072 [P] Update `docs/reference/integrations.md` only if a slice above changed an integration (none expected per the spec's Assumptions).
- [ ] T073 Run the full SC-003 table test and the FR-007 place-by-place refusal tests once more on the merged tip of all six slices, as the merge wave does, before closing the issue.
- [ ] T074 Close #2957 once Phases 1–6 have landed (handled by whichever lane lands last, per AGENTS.md's "Landing a change"; not a PR of its own).

## Dependencies

- **Phase 1** blocks every other phase.
- **Phase 2** needs Phase 1. **Phase 3** needs Phase 2. Phases 2 and 3 both hold the area `machines` (#873), so they run one after another, never at once.
- **Phase 4** needs Phases 2 and 3. T068 (the Console's part of Phase 6) may run alongside Phase 4 once the area `reports` is free, since it touches neither `settings` nor `machines`.
- **Phase 5** needs Phase 4.
- **Phase 6** (besides T068) needs Phases 4 and 5.
- **Phase 7** needs Phases 1–6.
- Within a phase: tests before build tasks; build tasks in the order listed unless marked `[P]`; `[P]` tasks touch different files and may run together.
- Phases 4, 5 and 6 are UI enhancements (`App/Sources`, `Remote/Sources`, `Shared/UI`, `Web/src`): each phase's PR opens with auto-merge off, its walk's screenshots under `## Screenshots`, and the label `needs-approval`, and waits for Alex's comment before it lands (AGENTS.md, "A UI enhancement waits for Alex", #2811).
