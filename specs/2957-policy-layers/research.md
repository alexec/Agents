# Research: Policy layers

What exists today, and why each decision in `plan.md` was made. Paths are from `main` at f04576c9f. `<settings>` is `<root>/settings`; `<root>` is `~/Library/Application Support/Agents` on a Mac and `~/.local/share/Agents` on Linux.

## What exists

### The organisation layer (spec 998, built)

| Thing | Where | What this plan does with it |
|---|---|---|
| `OrgPolicy` | `Packages/Wire/daemon.schema.json` (`OrgPolicy`), `Go/wire/types_gen.go` `OrgPolicy`, `Web/src/protocol/generated.ts`, `Packages/AgentsKit/.../Model/OrgPolicy.swift` (by hand) | Gains the rules of FR-003. Its other fields keep their meaning. |
| `modeCeiling` | enum `ask, default, acceptEdits, auto, bypassPermissions`, ranked by `modeRanks` (`agentsd/helperstart.go:28`) | Becomes `permissionMode` in Auto's four levels (R5). |
| `sandbox` | enum `required` only | Gains `runtime` (R6). |
| Signature | `controllink/policysig.go`: ECDSA P-256, SHA-256, `CanonicalJSON` (sorted keys), `KeyID`, alg `es256` | Reused as is for your layer (R2). |
| Keep and verify | `agentsd/policy.go`: `<root>/policy.json`, `policy-seen.json`, `toldPolicy`, `trustsLocked`, last good copy, version only goes up | The same rules for `policy-yours.json`. |
| Enforcement | `agentsd/policy.go`, all reading `d.orgPolicy()`: `policyStart` :1005, `policyTurn` :1097, `optionRefusal` :1202, `runtimeRefusal` :362, `requiredSandbox` :764, `marketplaceAllowed` :779, `customServerRefusal` :800, `helperCaps` :811, `orgBudgets` :892, `passThroughAllowed` :874 | Each reads the effective policy of the agent's folder instead (R7). |
| Refusal | `PolicyRefusal{reason, rule?, words, until?}`, error `policyRefused` (-32076), "Set by your organisation." | Gains `layer` (R8). |
| Marks | `PolicySetBy{by: "organisation", rule, words}` on `ConfigChoice`, `AutoSettings`, `CostState`, `SandboxSettings`, `FolderSummary.helperLimitsSetBy` and others | `by` gains `you` and `folder`, and `layer` names it (R8). |
| Panes | Mac `App/Sources/Settings/SettingsWindow.swift` `case policy` → `Shared/UI/OrgPolicyPane.swift`; web `Web/src/views/settings/Policy.tsx`; Console `Web/src/views/ConsoleOrgPolicy.tsx`; Remote: none, only `OrgPolicyStrip` | Renamed Organisation Policy. The Console gets the new rules. |
| Capabilities | `x-capability` / `x-declared-capabilities` in `Packages/Wire/*.openrpc.json` → `Go/wire/capabilities_gen.go`; `agentsd/capabilities.go`; `host/hello` | Adds `host.policy-layers/1`. |

### The person's rules today

| Rule | Kept in | Wire | Enforced in | Edited on |
|---|---|---|---|---|
| Permission mode | No setting. A new agent gets Ask (`autopick.go` `autoLevels`); a person may choose any level. Auto's table (`automap.go` `autoPermissions`) maps levels to each runtime's modes. | `auto/*`, `agents/setLevels` | `autopick.go` `resolveLevels`, `applyLevels` | start bar, Auto ▸ Mappings |
| Permission requests | `<settings>/client-permissions.json`, a default per runtime | `clientPermissions/state|set` | `host.go` :190 | Agent Runtimes |
| Sandbox | `<settings>/sandbox.json`, a default per runtime | `sandbox/state|set` | `sandbox.go` | Agent Runtimes |
| Money and tokens | `<settings>/limits.json`, `CostLimits{perAgent, daily, perAgentTokens, dailyTokens}`; with a control plane also the user-scope part `costLimits` | `cost/state|setLimits|changed` | `costlimits.go` `startRefusal`, `holdsForLimit`; fails closed | Mac `CostSettingsView.swift` |
| Workflows turned on | `<settings>/workflow-limit.json` `{total}`, default 20, 1–100 | `workflows/limit|setLimit` | `workflows.go` `ceilingsLocked`, `workflow.refused` `over_limit` | Mac `CostSettingsView.swift` |
| Notice burst and wait | `display.json` `noticeBurst` (3, 1–20), `noticeCooldownMinutes` (10, ≤ 24 h); with a control plane also the part `notifications` and the shared bucket `notices/take` | `preferences/*`, `user/setNoticeLimits` | `notify.go`, `noticebucket` | `Shared/UI/NotificationLimitsSection.swift` (Mac, Remote), `Web/.../Notifications.tsx` |
| Archive switch | `display.json` `agentsMayArchiveMyChats` (true). Not sent to servers: a server takes it as on. | `preferences/set` | `archiverequests.go` | `Shared/UI/SidebarSettingsSection.swift`, `Web/.../FinishedChats.tsx` |
| Environment | `<settings>/runtime-environment.json` `{names, runtimes}`, by hand. Not in any user part. | `settings/passThrough` (read only) | `passthrough.go`, `runtimes.go` `launchOn` | none (shown only) |
| Helper limits | `.agents/folder.json` `helperLimits{running 3, notArchived 5, queued 5, agentsMayArchive, continueWhenBack, archiveWhenMerged, agentsMayStartOnMachines}` | `folders/setHelperLimits` | `helpers.go` `helperLimitsIn`, capped by `helperCaps` | Mac `FolderSettingsSheet.swift` General |

**How settings reach other machines today.** With a control plane: user-scope parts `mcpServers, agentConfig, runtimes, costLimits, notifications` in `v1/users/<user>/settings.json`, pushed as `host/userSettings` to machines that say `host.user-settings/1`, written to files by `agentsd/usersettings.go` `ApplyUserSettings`. Without one: the Mac window pushes `cost/setLimits`, `workflows/setLimit`, `auto/set`, `sandbox/set`, `clientPermissions/set` and others to each server on connect (`AppModel.refreshServer`, `AppModel.swift:3646`). Notice limits, the archive switch and `runtime-environment.json` reach no other machine.

**The guarded folder files (#502, #531).** `agentsd/guarded.go` guards `.agents/folder.json` and `.agents/pins.json`. A change from outside the app becomes `Pending`, and the last approved copy (in `<root>/guarded-files.json`) applies. Wire: `folders/readGuardedChange`, `folders/keepGuardedChange`, `folders/undoGuardedChange`, `approvals/*` kind `file`. Card: `Shared/UI/Chat/GuardedChangeCard.swift` (Review…, Undo, Keep), `Web/src/views/GuardedChange.tsx`.

**Keys.** Every key today is a P-256 **key-agreement** key: the control key (Agents Host, Keychain `control-key`), the machine key (`controllink/hostkey*.go`), the paired-client key (`ControlClientKey.swift`), the Remote's device key, the browser key (WebCrypto ECDH). Authentication is ECDH with HKDF and HMAC. The only signature is the organisation policy's, by the control key. A machine learns the client keys from the control plane (`host/clients`). There is no key of the person.

## Decisions

### R1. A person key of its own

- **Decision**: a new key, the **person key**, ECDSA P-256. The Mac's host makes it the first time your layer is saved, and keeps it in the Keychain (account `person-key`, this device only), or in a 0600 file `<root>/person-key` on a scratch root or Linux. The host that holds it is the **keeper**. Only the keeper signs your layer.
- **Why**: the spec says the control plane must not be able to change your layer (FR-013, US6-4). A paired-client key cannot do it: it is a key-agreement key, each client has its own, and machines learn them from the control plane, so the control plane could swap one. The control key belongs to the organisation, not the person.
- **Not chosen**: a key on each client (a web page has a non-extractable ECDH key and no signing key; every client would have to be trusted by every machine); signing on the control plane (it could then change the layer); no signature, trust in the link (the spec's Decisions say signed).

### R2. Sign with the existing ES256 code, Go standard library

- **Decision**: `controllink.SignPolicy` and `VerifyPolicy` sign `CanonicalJSON` of the layer document, alg `es256`, `KeyID` of the public key. The Keychain part reuses the pattern of `controllink/hostkey_darwin.go`.
- **Libraries before our own code**: the platform library fits. Go's `crypto/ecdsa`, `crypto/elliptic` and `crypto/sha256` (BSD-3-Clause, part of Go 1.24, pinned by `go.mod`, no added size). No new library. `CanonicalJSON` is already in the repo; a JCS library (RFC 8785, such as `github.com/gowebpki/jcs`) was not taken, because the existing function already signs and checks the organisation policy and both must canonicalise the same way.
- **Not chosen**: Ed25519 (`crypto/ed25519` also fits, but a second algorithm doubles the verify paths for no gain; spec 998 chose P-256 for the same reason).

### R3. How a machine learns the person key

- **Decision**: a machine pins the person public key (`<root>/person-key.pub.json`: key, `KeyID`, where it came from, when) from the first of:
  1. a join code that your Mac window makes (Settings ▸ Machines ▸ Add a Machine): the code carries the person key beside the control key;
  2. the Mac window's direct link to a server (`policy/applyYours`), which is the path of `AppModel.refreshServer` today;
  3. for a machine that joined before this version, the first signed layer that the control plane sends. This one is trust on first use, and the machine logs it.
  After the pin, a new key is taken only in a **rotation record**: the new public key, signed by the pinned key.
- **Why**: paths 1 and 2 do not go through the control plane, so it cannot put in a key of its own. Path 3 is needed once, for machines that are joined today; the window's Settings ▸ Machines shows each machine's pinned `KeyID`, so a wrong pin can be seen.
- **Not chosen**: learning the key from `host/clients` (the control plane writes that list); asking the person to copy a fingerprint to each machine (too much work for a person alone).
- **Known limit**: a control plane that is changed by an attacker before the first send of path 3 could pin a key of its own on a machine joined before this version. The same control plane can already stop that machine's work. The spec does not make a layer a boundary against the machine's own user or its control plane admin.

### R4. Where a client edits your layer

- **Decision**: a client calls `policy/setYours` on the keeper. The Mac window calls its own host on the local socket. The web page and the Remote reach the keeper as they reach any machine (through the control plane, or the direct path of #1118). `policy/yours` says which machine is the keeper. A machine that is not the keeper refuses `policy/setYours` with the keeper's name. The keeper refuses the method from the agent socket role, from MCP tools and from workflows (FR-010).
- **Why**: Alex settled "kept on the Mac's host" (spec, Decisions). The role check already exists for the agent socket role.
- **A person with no Mac**: the first machine that a client of theirs asks to save a layer becomes the keeper. Decided: so a person on Linux and the web page only is not left out; it changes nothing for a person with a Mac. Alex can overrule.

### R5. Permission mode in Auto's four levels

- **Decision**: `permissionMode` is `plan | ask | approveForMe | bypassPermissions` on every layer (spec, Clarifications). The control plane reads an existing `modeCeiling` once into `permissionMode`, signs a new version, and drops `modeCeiling`: `ask` → `plan`, `default` → `ask`, `acceptEdits` → `approveForMe`, `auto` → `approveForMe`, `bypassPermissions` → `bypassPermissions`. A runtime's own mode is placed on the four levels by Auto's table (`automap.go` `autoPermissions`), and a mode that the table does not name by `permissionAliases` (`autopick.go`) and then `modeRanks` (rank 3 or 4 → `bypassPermissions`).
- **Why**: the same map is already in `permissionAliases` (#2873: Claude's `auto` counts as Approve for me). Each value maps to the same or a tighter level, so no organisation loosens. The control plane reads it once for the same reason as FR-012: a limit that goes away without a word makes the rules looser.
- **Unset rule**: a new agent gets Ask, and a person may choose any level, as today. A set rule is both what a new agent gets and the loosest a session may choose (FR-008).

### R6. The order of each rule, as code

- **Decision**: `policylayers` has one `Order` per rule, the table of FR-004, and every comparison goes through it. Sandbox: `off` (rank 2) → `runtime` (1) → `on` (0), the ranks of `automap.go` `levelRank`. The organisation's `sandbox: required` is read as `on`; a new value `runtime` refuses only `off`. Permission requests: `alwaysApprove` → `default` (Ask me). Lists (runtimes, models, marketplaces, environment): the effective list is the intersection of the layers that set it; a trailing `*` in a model or variable name matches a prefix, as today.
- **Why**: one order per rule in one place makes the table test of SC-003 exact, and each order is the one its refusal uses today.

### R7. One resolver, used at every place

- **Decision**: `policylayers.Resolve(layers []Layer) Effective`. The machine keeps one `Effective` for "no folder" and one per folder that has a layer, made again when any layer changes. `agentsd` asks `d.effective(folder)` at each place of FR-007. The person's old files (`limits.json`, `workflow-limit.json`, the notice keys of `display.json`, `agentsMayArchiveMyChats`, `runtime-environment.json`) are not read after the first-start move.
- **Why**: today's two systems (org ceilings and personal settings) become one call. The clients draw the machine's result, so the Mac, the Remote and the web page cannot differ.
- **Per-runtime defaults stay setup**: `sandbox.json` and `client-permissions.json` keep each runtime's default, edited in Agent Runtimes ("Policy allows; Agent Runtimes sets up"). The rule caps them. They are not moved into your layer, because a rule is one value, and rules that differ by runtime are out of scope (spec, Assumptions).

### R8. Refusals and marks carry the layer

- **Decision**: `PolicyRefusal` gains `layer: PolicyLayerRef` (`organisation | you | folder`, a name, and for a folder its id) and `value` (words). `PolicySetBy.by` gains `you` and `folder`, plus `layer`. The words change from "Set by your organisation." to the layer's name: "Acme: at most Approve for me", "Your policy: at most $40 a day", "payments-api: at most Ask". The machine writes the words, so clients draw them as they are.
- **Why**: FR-026. Every client, an older one too, can show the words.

### R9. The first-start move (FR-012)

- **Decision**: on the keeper, when `policy-yours.json` does not exist, the host makes your layer once from: `limits.json` → `budgets`; `workflow-limit.json` → `workflows.mostOn` (only when the file exists); `display.json` `noticeBurst` and `noticeCooldownMinutes` → `notices` (only when set); `agentsMayArchiveMyChats: false` → `archiveMyChats: false`; `runtime-environment.json` → `environment`. It signs it, writes it, and renames each old file it read to `<name>.moved` (or removes the moved keys from `display.json`), so nothing reads them again and the person can find them. Permission mode, permission requests and sandbox are not moved: today they are no limit (R5, R7), so "unset" is the same rule.
- **Why**: the spec's Decisions (your values are read once). A server is not moved from its own files: it gets the keeper's layer.

### R10. A folder's layer is a guarded file with a tighter-only fast path

- **Decision**: `guarded.go` adds `.agents/policy.json`. When the file changes from outside the app, `policylayers.Looser(approved, new)` decides: no rule looser → the new copy is approved at once, with the notice "payments-api's policy is tighter: …"; any rule looser → `Pending`, the last approved copy applies, and the card shows. The card for this file uses the words of frame D: **Allow** (= keep the change), **Keep `<old value>`** (= undo), **Show Change** (= review). An invalid file (not JSON, a value out of range) is pending with the reason; an unknown rule name is ignored and logged once. Each worktree has its own approved copy, keyed by path as today.
- **Why**: the spec's Decisions and FR-016. The card and its methods exist; only the words and the fast path are new.
- **`.agents/folder.json`**: `helperLimits.running` and `helperLimits.notArchived` are no longer read (FR-015). Its other `helperLimits` keys stay: they are folder settings, not rules.

### R11. Transport with a control plane

- **Decision**: the user-scope part `policy` holds `SignedYourPolicy`. Only the keeper may set it (new host method `user/setPolicy`); a client cannot. The control plane stores it without a change and pushes it in `host/userSettings` to machines that say `host.policy-layers/1`. The parts `costLimits` and `notifications` go (FR-013): `user/setNoticeLimits` goes too, and the shared notice bucket reads the burst and the wait from the stored layer and the organisation, the tighter of the two.
- **Why**: the user scope is the existing path to every machine of a person, within 5 s, with dedup by hash. The control plane can read the layer (no secret in it) but cannot sign one.

### R12. Clients draw, the machine decides

- **Decision**: `policy/effective {folder?}` returns, for each rule, the effective value, the layer that decides, each layer's value or "Not set", "Kept, not used", and the cap a menu must dim at. `policy/effectiveChanged` tells clients. Clients never resolve.
- **Why**: one resolver (R7). Swift and TypeScript only decode and draw, so no third copy of the orders.

### R13. The Remote and the web page for a folder's layer

- **Decision**: the web page has no Folder Settings today. It edits a folder's layer from Agents ▸ Policy: the banner's "folders with their own rules" opens a list, and each folder opens its layer in the same pane. The Mac has Folder Settings ▸ Policy and the same list. The Remote shows the list read only.
- **Why**: the web page is a full client (AGENTS.md); a whole web Folder Settings is not this spec's work. Decided, Alex can overrule.

### R14. The Settings group Agents

- **Decision**: `Shared/UI/SettingsScope.swift` and `Web/src/views/settings/sections.ts` gain the scope `agents` (title **Agents**), with `policy`, `spending` and `resources`. Spending and Resources leave Machines. This app ▸ Notifications goes. On the Remote, Settings gains Agents with Policy only (the Remote has no Spending or Resources today).
- **Why**: FR-018, FR-023 and frame A.
