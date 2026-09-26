# Implementation Plan: Gemini CLI as a Fifth Runtime

**Branch**: `agents/speckit-specify-support-gemini` | **Date**: 2026-09-25 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `specs/046-gemini-cli/spec.md`

## Summary

Add Gemini as a fifth entry in `RuntimeCatalog`: `gemini --acp`, where `gemini` is the shim
of the app's own pinned toolset (`@google/gemini-cli@0.61.0` + Node v24.21.0), installed from
048's set-up page with the same `.toolset` recipe as Claude, and never a `gemini` on the PATH
(D1, Alex 2026-09-25). The page, its offered-once rule, progress and failure words are 048's
and need nothing from this lane beyond the catalog entry (R12). The handshake measured on 2026-09-25 (research R2–R8)
shows most of the work is already generic: sign-in refusal is ACP's `-32000`, resume,
pictures, modes and models all come from the handshake, and there is no sign-out. What is
new:

1. **A tool policy** that removes `invoke_agent` and the six `tracker_*` tools with a
   `--policy` TOML file the app writes per launch (R5). No escalation tool: Gemini drops
   `ask_user` in ACP mode, so questions become **Waiting on your answer**, as for Grok (R6).
2. **Usage from `_meta.quota`** on the prompt result, since Gemini sends no `usage_update`
   (R7).
3. **A second Mac toolset**: 048's installer made per-toolset (a map, a shim named for the
   runtime that forwards its arguments, the runtime's name in its sentences), discovery that
   skips the PATH for app-copy-only runtimes, **Update** on a row whose toolset is older than
   the app's pin, and old builds kept while an agent runs on them (R12).
4. **Servers**: 043's Claude-only credential, lending and toolset code made per-runtime, then
   a Gemini API key kind (R10).

Pinned, the same version on the Mac and servers (D5), moved by one script.

## Technical Context

**Language/Version**: Swift 6 (strict concurrency), as the rest of the app.

**Primary Dependencies**: Gemini CLI 0.61.0 from npm (run, not linked) and a pinned Node ≥ 20,
installed by 048's `MacToolsetInstaller` on the Mac and 043's `ToolsetInstaller` on servers.

**Storage**: `<root>/runtimes/gemini-policy.toml` (rebuilt each launch); `<root>/tools/gemini/`
(048); the Gemini API key in the Mac's Keychain beside Claude's (043);
`App/Resources/toolsets/gemini/` with `mac-node.json`.

**Testing**: `swift test` in `Packages/AgentsKit` (unit + fake-runtime tests);
`scripts/acp-handshake.sh` and `scripts/runtime-tools.sh` for the live check; a live suite
gated on `AGENTS_GEMINI=1` for the real turn; `BareServerLiveTests` extended for Gemini on
agents-bare.

**Target Platform**: macOS app + agentsd; Linux agentsd on servers (x86-64, ARM64); iOS
Remote only reads the runtime list.

**Project Type**: desktop app with daemon, bridge and phone client.

**Performance Goals**: SC-001 (Install to first reply ≤ 3 min),
SC-002 (cached start ≤ Claude + 5 s), SC-005 (bare server ≤ 5 min).

**Constraints**: never write to `~/.gemini` (FR-013); key never on server disk (FR-016); no
runtime-id branches outside the catalogs (the `Lever` comment's rule).

**Scale/Scope**: one runtime; ~ 15 files touched in AgentsKit and App; 4 docs pages.

## Constitution Check

`.specify/memory/constitution.md` is still the unfilled template, so there are no ratified
gates. The project's working rules stand in for it and this plan keeps them:

- **Settle the UX before depth**: almost no new UI. Gemini's set-up row is 048's row; the new
  surfaces are **Update** on an outdated row and a Gemini row in Settings ▸ Runtime credentials.
  The look gate is one screenshot pass of the set-up sheet listing Gemini (with one row
  outdated), early in Phase 1, before the policy and usage work.
- **The policy is total over the catalog** (`ToolPolicyCatalog` test): Gemini's policy lands
  in the same commit as its catalog entry.
- **No runtime-id branches**: new behaviour goes into the policy table, the credential kind
  and the toolset manifest; the three existing `"claude"` literals in 043 code become lookups.
- **Never write the person's files**: the policy file lives under `<root>/runtimes/`.

Re-checked after design: holds. One deviation, justified in Complexity Tracking.

## Project Structure

### Documentation (this feature)

```text
specs/046-gemini-cli/
├── plan.md
├── research.md        # R1–R11, measured against 0.61.0
├── data-model.md
├── quickstart.md
├── contracts/
│   ├── runtime-launch.md   # the command, policy file, environment
│   └── credentials.md      # Gemini key kind, check, lend
└── tasks.md           # /speckit-tasks
```

### Source Code

```text
Packages/AgentsKit/Sources/AgentsKitCore/
├── Runtimes/RuntimeCatalog.swift        # + gemini
├── Runtimes/ToolPolicyCatalog.swift     # + gemini policy, policy TOML text
├── Runtimes/ToolPolicy.swift            # EnvironmentFile: argument OR variable
├── Model/Runtime.swift                  # usesAppCopyOnly
├── Runtimes/CredentialKind.swift        # + geminiAPIKey; variables per runtime
├── Runtimes/Toolset.swift               # shim named for the runtime; forwardsArguments; outdated check
├── ACP/ACPTypes.swift                   # PromptResult reads _meta.quota
└── Hosts/Host.swift                     # ServerFacts.canInstall(runtime)
Packages/AgentsKit/Sources/AgentsKit/
├── Runtimes/RuntimePolicyFiles.swift    # write files named by argument too
├── Runtimes/RuntimeDiscovery.swift      # skip PATH for app-copy-only; report outdated
├── Runtimes/RuntimeInstaller.swift      # toolsets by runtime id
├── Runtimes/MacToolsetInstaller.swift   # runtime's name in words; keep folders in use
├── Daemon/DaemonCore+Install.swift      # install when outdated; pass folders in use
├── ACP/Serve/SessionLauncher* / ACPSession.swift   # append policy args; turn usage from quota
├── Daemon/DaemonCore+Credentials.swift  # lendable set + own sign-in per runtime
└── Hosts/ToolsetInstaller.swift         # serverFolder(runtimeID:) from the toolset
App/
├── Resources/toolsets/gemini/{manifest.json,mac-node.json,package.json,package-lock.json}
├── Sources/Runtimes/InstallAgentsSheet.swift # RuntimeInstallRow: Update when outdated
├── Sources/Settings/ServerCredentials.swift  # runtimes from CredentialKind
├── Sources/Settings/ServersSettingsView.swift
├── Sources/Hosts/{HostSet.swift,Lending.swift}
└── Sources/AppModel.swift
scripts/update-gemini-toolset.sh         # from update-claude-toolset.sh
scripts/runtime-tools.sh, scripts/acp-handshake.sh  # + gemini
docs/reference/runtimes.md, docs/how-to/sign-a-runtime-in.md,
docs/how-to/add-a-linux-server.md, docs/reference/settings.md
```

**Structure Decision**: no new modules. Gemini is data in three catalogs (runtime, policy,
credential kind) plus one toolset folder; the code changes are the generalisations that let
that data drive behaviour.

## Phases

**Phase 0: Spike (needs a Gemini API key from Alex).** On a scratch root, with the key in that
root's launch environment only. Run a real turn over `--acp` with the app's MCP server and the
policy file, and settle the five "to measure" items: MCP reaches the model (R2), untrusted
folder doesn't stop a turn (R3), `oauth-personal` and `gemini-api-key` over `authenticate`
(R4), deny also hides the tool (R5), quota error shape (R9). Then `npm ci` of the lock on the
Mac and on agents-bare, without a compiler (`node-pty`, R10). Findings go into research.md.

**Phase 1: Gemini on the set-up page (US1 install half).** Toolset folder +
`scripts/update-gemini-toolset.sh` (from Claude's; also writes `mac-node.json`); catalog entry
with `.toolset` and `usesAppCopyOnly`; `RuntimeInstaller` holds every bundled toolset;
shim `bin/gemini` forwarding `"$@"`; the runtime's name in the installer's words. Unit tests:
discovery ignores a `gemini` on the PATH, finds the app's; a fake `nodeDist` install of the
Gemini toolset (as `MacToolsetInstallerTests` does for Claude). **Look gate**: scratch app
(048's `AGENTS_TEST_INSTALL_SCRIPT` rule; this recipe runs no vendor script) — the sheet lists
Gemini as not on this Mac, **Install** runs, row ticks; screenshot to Alex.

**Phase 2: Gemini agents on the Mac (US1 + US3, the MVP).** Policy + `--policy` file
(`EnvironmentFile` argument form), `escalationTool: nil`, `PromptResult` reads `_meta.quota`,
the catalog-totality test gains Gemini, `acp-handshake.sh` / `runtime-tools.sh` gain it. Live
test on `AGENTS_GEMINI=1`. Walk: start, edit, `ls`, permission, stop, resume, picture, a
question ending as **Waiting on your answer**; starting while not installed says so (FR-003).

**Phase 3: Updates and running builds (D5, FR-003a; shared with Claude).** Outdated =
`current`'s toolset id ≠ the bundle's; the row shows **Update**; `installRuntime` proceeds when
outdated; `removeOthers` skips folders an agent is running from, and the daemon clears them at
the next install or start. Tests with two fake pins.

**Phase 4: Generalise 043 (shared with 047).** Replace every Claude-only point in R10's list
with a lookup: credential kinds by runtime, lendable runtimes = runtimes with a bundled
toolset, own-sign-in check per runtime, server installer folders and shim from the manifest.
Claude's behaviour must not change: 043's suites (incl. `BareServerLiveTests`) stay green. If
047 has landed this already, merge it instead.

**Phase 5: Gemini on servers (US4).** `geminiAPIKey` kind (`AIza`), check against
`generativelanguage.googleapis.com` (contracts/credentials.md), lend as `GEMINI_API_KEY` with
`GOOGLE_API_KEY` cleared; Settings ▸ Runtime credentials row (look gate, one screenshot). Live
on agents-bare with the spike's key: install, turn, then `leak-check.sh` for the key.

**Phase 6: Sign-in (US2) and failures (FR-018).** Mostly verification: unsigned start shows
**Needs signing in**; sheet lists four methods; no sign-out button. Add only what the spike
shows is missing (e.g. the Terminal fallback for `oauth-personal`, which hands over the app's
own `…/tools/gemini/current/bin/gemini`). Failure sentences for a changed flag (version named)
and quota.

**Phase 7: Everywhere a runtime is chosen, docs.** Phone/iPad start forms, workflow steps and
`start_agent` read `RuntimeCatalog.builtIn`; verify each. Docs: runtimes, sign-in, servers,
settings (Settings ▸ Agents lists Gemini). `scripts/docs-check.py` passes.

## Complexity Tracking

| Deviation | Why needed | Simpler alternative rejected because |
|---|---|---|
| `EnvironmentFile` gains an argument form | Gemini's only additive, per-process lever is `--policy <path>` | `GEMINI_CLI_SYSTEM_SETTINGS_PATH` would override the person's own settings key by key (R5) |
| `Runtime.usesAppCopyOnly` skips the PATH | Alex: agents run only the pinned copy; Gemini's ACP surface moves between releases | PATH-first (048's rule for Claude) would run whatever `gemini` the person has |
| **Update** and kept folders in 048's installer | D5 and FR-003a: a pin bump must reach the Mac, and a lazily-loading bundle can't lose its folder mid-turn | leaving 048 as is means a pin bump never installs, and the next install breaks running agents |
