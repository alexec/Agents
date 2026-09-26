# Implementation Plan: Gemini CLI as a Fifth Runtime

**Branch**: `agents/speckit-specify-support-gemini` | **Date**: 2026-09-25 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `specs/046-gemini-cli/spec.md`

## Summary

Add Gemini as a fifth entry in `RuntimeCatalog`, started as `npx -y
@google/gemini-cli@0.61.0 --acp` (D1). The handshake measured on 2026-09-25 (research R2–R8)
shows most of the work is already generic: sign-in refusal is ACP's `-32000`, resume,
pictures, modes and models all come from the handshake, and there is no sign-out. What is
new:

1. **A tool policy** that removes `invoke_agent` and the six `tracker_*` tools with a
   `--policy` TOML file the app writes per launch (R5). No escalation tool: Gemini drops
   `ask_user` in ACP mode, so questions become **Waiting on your answer**, as for Grok (R6).
2. **Usage from `_meta.quota`** on the prompt result, since Gemini sends no `usage_update`
   (R7).
3. **Servers**: 043's Claude-only credential, lending and toolset code made per-runtime, then
   a Gemini toolset and a Gemini API key kind (R10).

Pinned on the Mac as well as servers (R1 adjusts D5): one version, moved by one script.

## Technical Context

**Language/Version**: Swift 6 (strict concurrency), as the rest of the app.

**Primary Dependencies**: Gemini CLI 0.61.0 from npm (run, not linked); Node ≥ 20 on the Mac
(already required by Claude); 043's server toolset machinery.

**Storage**: `<root>/runtimes/gemini-policy.toml` (rebuilt each launch); the Gemini API key
in the Mac's Keychain beside Claude's (043); `App/Resources/toolsets/gemini/`.

**Testing**: `swift test` in `Packages/AgentsKit` (unit + fake-runtime tests);
`scripts/acp-handshake.sh` and `scripts/runtime-tools.sh` for the live check; a live suite
gated on `AGENTS_GEMINI=1` for the real turn; `BareServerLiveTests` extended for Gemini on
agents-bare.

**Target Platform**: macOS app + agentsd; Linux agentsd on servers (x86-64, ARM64); iOS
Remote only reads the runtime list.

**Project Type**: desktop app with daemon, bridge and phone client.

**Performance Goals**: SC-001 (first reply ≤ 2 min incl. fetch; measured fetch 5.7 s),
SC-002 (cached start ≤ Claude + 5 s), SC-005 (bare server ≤ 5 min).

**Constraints**: never write to `~/.gemini` (FR-013); key never on server disk (FR-016); no
runtime-id branches outside the catalogs (the `Lever` comment's rule).

**Scale/Scope**: one runtime; ~ 15 files touched in AgentsKit and App; 4 docs pages.

## Constitution Check

`.specify/memory/constitution.md` is still the unfilled template, so there are no ratified
gates. The project's working rules stand in for it and this plan keeps them:

- **Settle the UX before depth**: there is almost no new UI. The only new surfaces are a
  Gemini row in Settings ▸ Runtime credentials and the "fetching Gemini" line. Both are
  copies of existing ones, so the look gate is one screenshot pass, early (Phase 3).
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
├── Runtimes/CredentialKind.swift        # + geminiAPIKey; variables per runtime
├── Runtimes/Toolset.swift               # runtime-agnostic comments; nothing Claude-only
├── ACP/ACPTypes.swift                   # PromptResult reads _meta.quota
└── Hosts/Host.swift                     # ServerFacts.canInstall(runtime)
Packages/AgentsKit/Sources/AgentsKit/
├── Runtimes/RuntimePolicyFiles.swift    # write files named by argument too
├── ACP/Serve/SessionLauncher* / ACPSession.swift   # append policy args; turn usage from quota
├── Daemon/DaemonCore+Credentials.swift  # lendable set + own sign-in per runtime
└── Hosts/ToolsetInstaller.swift         # serverFolder(runtimeID:) from the toolset
App/
├── Resources/toolsets/gemini/{manifest.json,package.json,package-lock.json}
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

**Phase 0: Spike (needs a Gemini API key from Alex).** Put it in the scratch root's login
environment only. Run a real turn over `--acp` with the app's MCP server and the policy file,
and settle the five "to measure" items in research: MCP reaches the model (R2), untrusted
folder doesn't stop a turn (R3), `oauth-personal` and `gemini-api-key` over `authenticate`
(R4), deny also hides the tool (R5), quota error shape (R9). Then `node-pty` on agents-bare
(R10). Findings go into research.md as R-numbers' "Measured" lines.

**Phase 1: Mac runtime (US1 + US3 together, the MVP).** Catalog entry, policy + policy file,
`PromptResult` quota, briefing's residue/escalation lines follow from the table. Fake-runtime
tests for the argument-named file and for quota usage; the catalog-totality test gains
Gemini. A live test gated on `AGENTS_GEMINI=1`. Walk on a scratch root: start, edit, `ls`,
permission, stop, resume, picture.

**Phase 2: Generalise 043 (shared with 047).** Replace every Claude-only point in R10's list
with a lookup: credential kinds by runtime, lendable runtimes = runtimes with a bundled
toolset, own-sign-in check per runtime, installer folders from the manifest. Claude's
behaviour must not change: 043's suites (incl. `BareServerLiveTests`) stay green. If 047 has
landed this already, merge it instead and skip to Phase 3.

**Phase 3: Gemini on servers (US4).** Toolset folder + update script; `geminiAPIKey` kind with
`AIza` prefix, check against `generativelanguage.googleapis.com` (contracts/credentials.md),
lend as `GEMINI_API_KEY` with `GOOGLE_API_KEY` cleared. Settings ▸ Runtime credentials gets
its Gemini row: **look gate** (one screenshot of the row, then Alex). Live on agents-bare with
the spike's key: install, turn, then `leak-check.sh` for the key.

**Phase 4: Sign-in (US2) and failures (FR-018).** Mostly verification: unsigned start shows
**Needs signing in**; sheet lists four methods; no sign-out button. Add only what the spike
shows is missing (e.g. the Terminal fallback for `oauth-personal`). Failure sentences for no
Node (shared with Claude's), fetch offline, bad flag (version named), quota.

**Phase 5: Everywhere a runtime is chosen, docs.** Phone/iPad start forms, workflow steps and
`start_agent` read `RuntimeCatalog.builtIn`, so they should need nothing; verify each and fix
any hard-coded list found. Four docs pages; `scripts/docs-check.py` passes.

## Complexity Tracking

| Deviation | Why needed | Simpler alternative rejected because |
|---|---|---|
| `EnvironmentFile` gains an argument form | Gemini's only additive, per-process lever is `--policy <path>` | `GEMINI_CLI_SYSTEM_SETTINGS_PATH` would override the person's own settings key by key (R5) |
| Pinned on the Mac, not `@latest` (D5 adjusted) | the ACP surface moves between releases (`--experimental-acp` deprecated) | `@latest` makes every Gemini release an untested change to the app |
