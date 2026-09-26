# Implementation Plan: Codex as a Runtime

**Branch**: `agents/speckit-specify-support-codex` | **Date**: 2026-09-25 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `specs/047-codex-runtime/spec.md`

## Summary

Add Codex as a runtime in `RuntimeCatalog`. It is started as the app's own pinned toolset:
Node plus `@agentclientprotocol/codex-acp@1.13.1`, which pulls in `@openai/codex@0.156.1` and
that version's native binary for one platform. It is Claude's 043/048 toolset shape, installed
by 048's start-up installer on the Mac and by 043's installer on servers.

The handshake measured on 2026-09-25 (research R2) shows most of the runtime side is already
generic:
- A signed-out start is refused with ACP's `-32000`.
- Resume, list, delete, pictures and sign-out are all advertised.
- There are three sign-in methods: API key, ChatGPT, and ChatGPT by device code.

What is new:

1. **Toolset-only runtimes.** Unlike Claude, Codex is never started through the person's
   `npx`. It always runs from the app's toolset, so the pinned lock (the exact Codex binary)
   is what runs, and the 330 MB download happens at install time with progress, not
   silently inside a first turn (R1).
2. **More than one toolset.** 048 wires exactly one toolset (Claude's) into the daemon and
   the app. It becomes a map by runtime id, on the Mac and on servers. **The Mac toolset
   also learns to move to a new pin** (D5), which 048 does not do yet: an outdated toolset
   gets an **Update** button, and a folder an agent still runs from is never removed.
   That helps Claude too, and it is the same design as 046's Phase 6.
3. **A tool policy** through `CODEX_CONFIG`: a JSON object the adapter merges into Codex's
   session config. It switches off the `multi_agent`, `memories`, `apps` and `goals`
   features, and nothing in `~/.codex` changes (R5). The escalation tool is
   `request_user_input`, which the adapter raises as a form elicitation, so questions become
   cards (R6).
4. **Servers.** 043's Claude-only credential, lending and toolset code becomes per-runtime.
   Codex adds an OpenAI API key kind, lent as `CODEX_API_KEY`, with `NO_BROWSER=1` so
   ChatGPT is never offered on a server (R4, R9). **This generalisation is shared with 046
   (Gemini)**, and whichever lane lands first does it.

## Technical Context

**Language/Version**: Swift 6 (strict concurrency), as the rest of the app.

**Primary Dependencies**:
- `@agentclientprotocol/codex-acp` 1.13.1 and `@openai/codex` 0.156.1, from npm, run and not
  linked (Apache-2.0).
- Node v24.21.0, the same pin as Claude's toolset.
- 048's `RuntimeInstaller` / `MacToolsetInstaller`.
- 043's `ToolsetInstaller`, lending and `CredentialKind`.

**Storage**:
- `App/Resources/toolsets/codex/`: the manifest, package, lock and `mac-node.json`.
- The Mac's `<root>/tools/codex/<id>/`.
- A server's `~/.agents-server/tools/codex/<id>/`.
- The OpenAI key in the Mac's Keychain beside Claude's (043).

**Testing**:
- `swift test` in `Packages/AgentsKit`: unit tests, fake-runtime tests, and the
  `MacToolsetInstaller` tests against a `file://` dist.
- `scripts/acp-handshake.sh` and `scripts/runtime-tools.sh`, each gaining Codex.
- A live suite gated on `AGENTS_CODEX=1`, for a real ChatGPT turn.
- `BareServerLiveTests`, extended with Codex, on agents-bare.

**Target Platform**:
- The macOS app and agentsd (Apple silicon and Intel).
- The Linux agentsd on servers (x86-64 and ARM64; glibc for Node).
- iOS Remote only reads the runtime list.

**Project Type**: a desktop app with a daemon, a bridge and a phone client.

**Performance Goals**:
- SC-001: a first reply within 3 minutes, counting sign-in.
- SC-002: an installed start no more than Claude's plus 5 s. The adapter starts the Codex
  app server in about 1 s (R2).
- SC-005: a bare server within 5 minutes. The toolset is about 520 MB unpacked.

**Constraints**:
- Never write `~/.codex` and never set `CODEX_HOME` (FR-016). Codex's own state files there
  are Codex's (R3).
- The key is never on a server's disk (FR-019), and the ChatGPT sign-in never leaves the Mac
  (FR-020).
- No runtime-id branches outside the catalogs.

**Scale/Scope**:
- One runtime.
- About 20 files in AgentsKit, App and Daemon; half of them are the shared 043
  generalisation.
- 5 docs pages.

## Constitution Check

`.specify/memory/constitution.md` is still the unfilled template, so there are no ratified
gates. The project's working rules stand in for it:

- **Settle the UX before depth.** The new surfaces are copies of existing ones:
  - a Codex row in the start sheet and in Settings ▸ Agents (048), with install progress;
  - a Codex row in Settings ▸ Runtime credentials (043);
  - the sign-in sheet listing three methods.

  One screenshot pass early (Phase 2) is the look gate.
- **The policy is total over the catalog** (`ToolPolicyCatalog` test). Codex's policy lands
  in the same commit as its catalog entry.
- **No runtime-id branches.** The six `"claude"` literals in 043/048 code become lookups
  keyed by toolset or credential kind. Codex's differences live in the policy table, the
  credential kind, the toolset manifest and one `Runtime` field.
- **Never write the person's files.** `CODEX_CONFIG` is an environment variable, and the
  toolset lives under the daemon's root.
- **Prove it running.** Walk a scratch root with a real Codex turn (run-app skill), and walk
  agents-bare with the test-servers skill.

Re-checked after design: holds. The deviations are in Complexity Tracking.

## Project Structure

### Documentation (this feature)

```text
specs/047-codex-runtime/
├── plan.md
├── research.md        # R1–R11, measured against codex-acp 1.13.1 / codex 0.156.1
├── data-model.md
├── quickstart.md
├── contracts/
│   ├── runtime-launch.md   # command, environment, CODEX_CONFIG, modes
│   └── credentials.md      # OpenAI key kind, check, lend; NO_BROWSER on servers
└── tasks.md           # /speckit-tasks
```

### Source Code

```text
Packages/AgentsKit/Sources/AgentsKitCore/
├── Model/Runtime.swift                  # + `usesAppCopyOnly` (true for Codex; the same field as 046)
├── Runtimes/RuntimeCatalog.swift        # + codex
├── Runtimes/ToolPolicy.swift            # Lever + .environmentJSON(variable:, value:)
├── Runtimes/ToolPolicyCatalog.swift     # + codex policy
├── Runtimes/CredentialKind.swift        # + openAIAPIKey; runtime + variables per kind
├── Runtimes/Toolset.swift               # shim named for the runtime; comments not Claude-only
└── Hosts/Host.swift                     # canInstallClaude → canInstallToolset
Packages/AgentsKit/Sources/AgentsKit/
├── Runtimes/RuntimeDiscovery.swift      # skip PATH when usesAppCopyOnly; outdated check
├── Runtimes/RuntimeInstaller.swift      # toolsets: [runtimeID: MacToolsetInstaller]
├── Runtimes/MacToolsetInstaller.swift   # shim name from runtime; keep folders agents still run from
├── ACP/Serve/SessionLauncher*.swift     # apply .environmentJSON; NO_BROWSER on servers
├── Daemon/Daemon.swift                  # toolsets folder, not claude's
├── Daemon/DaemonCore+Install.swift      # install an outdated toolset on Update
├── Daemon/DaemonCore+Credentials.swift  # lendable = runtimes with a toolset; own sign-in per runtime
└── Hosts/ToolsetInstaller.swift         # folder from manifest.runtimeID
Daemon/Sources/main.swift                # Resources/toolsets, not toolsets/claude
App/
├── Resources/toolsets/codex/{manifest.json,package.json,package-lock.json,mac-node.json}
├── Sources/Hosts/{HostSet.swift,Lending.swift}   # toolsets by runtime
├── Sources/Settings/{ServerCredentials.swift,ServersSettingsView.swift,AgentsSettingsView.swift}
└── Sources/AppModel.swift
scripts/update-toolset.sh                # from update-claude-toolset.sh, runtime as argument
scripts/update-claude-toolset.sh         # becomes a one-line call of the above
scripts/runtime-tools.sh, scripts/acp-handshake.sh  # + codex
docs/reference/runtimes.md, docs/how-to/sign-a-runtime-in.md, docs/how-to/add-a-linux-server.md,
docs/reference/settings.md, docs/explanation/scoped-tools.md
```

**Structure Decision**: there are no new modules. Codex is data in three catalogs (runtime,
policy and credential kind) plus one toolset folder. The code changes are the
generalisations that let that data drive behaviour.

## Phases

**Phase 0: Spike (needs Alex's ChatGPT sign-in, once).** This runs on a scratch root with
the toolset built by hand (`scripts/update-toolset.sh codex … --install-here <root>/tools`).
Settle the items research marks **to measure**:
- **R4**: `chat-gpt` over ACP `authenticate` opens the browser from the adapter and lands in
  `~/.codex/auth.json`.
- **R5**: which of the four `features` keys `CODEX_CONFIG` honours, and whether each takes
  its tools out of the model's list.
- **R6**: `request_user_input` reaches a form card in the default mode, with
  `default_mode_request_user_input`.
- **R7**: whether `usage_update` and rate limits arrive, and in what shape a plan-limit
  refusal arrives.
- **R8**: whether calls to the app's MCP tools ask for approval in the `agent` mode.

For the server items, run an API-key turn on agents-bare with the key in the environment
only. That settles whether `CODEX_API_KEY` alone is enough, or whether `authenticate
api-key` must be called too (R9). Findings go into research.md as "Measured" lines.

**Phase 1: More than one toolset (shared groundwork, no Codex yet).**
- Replace 048's single toolset with a map by runtime id, all the way through:
  - `Daemon/Sources/main.swift` hands over `Resources/toolsets/`;
  - `Daemon` loads every subfolder;
  - `RuntimeInstaller.toolsets`;
  - `HostSet.toolsets`.
- Name the shim after `runtime.executable` rather than the fixed `npx`.
- Replace 043's Claude-only points (research R10) with lookups:
  - credential kinds carry their runtime and variables;
  - `lendableRuntimes` becomes the runtimes with a bundled toolset;
  - `ServerSignIn.exists` becomes per runtime;
  - `ToolsetInstaller` reads its folder from `manifest.runtimeID`;
  - `canInstallToolset`.
- Claude must behave exactly as before: 043's and 048's suites stay green, and so does
  `BareServerLiveTests`.
- If 046 has already landed this, merge it and keep only what it lacks (the Mac map, the
  shim name).

**Phase 2: Codex on the Mac (US1 + US3, the MVP).**
- Add `RuntimeCatalog.codex` (`usesAppCopyOnly: true`), its toolset folder and its policy
  (`.environmentJSON` lever) in one commit, with the totality test gaining Codex.
- Discovery skips the PATH for it, so a `codex-acp` of the person's is never used (FR-002).
- The start sheet and Settings ▸ Agents list Codex with 048's install button and progress.
  **Look gate**: one scratch screenshot of each, then Alex.
- A Codex agent started while the install runs, or after it failed, says so (FR-003). That
  is 048's `installing` / `installFailed` availability surfacing on the start path.
- Fake-runtime tests cover `CODEX_CONFIG` in the environment and the escalation line naming
  `request_user_input`. A live test is gated on `AGENTS_CODEX=1`.
- Walk: install, start, edit, `ls`, a permission ask, a question card, stop, resume, a
  picture, and mode and model menus.

**Phase 3: Sign-in and failures (US2, FR-011, FR-022).**
- Mostly verification. An unsigned start shows **Needs signing in**, and the sheet lists API
  key, ChatGPT and device code, with ChatGPT first (`RuntimeAccount.preferredMethod` gains
  an order from the policy or catalog, not a name check). Sign-out works, because `logout`
  is advertised.
- Plan-limit and rate-limit endings get a sentence, from what the spike shows.

**Phase 4: Moving a Mac toolset to a new pin (D5, FR-003a), the same design as 046's
Phase 6, and done once by whichever lane lands first.**
- `RuntimeDiscovery` reports a toolset whose `current` is not the bundled id as available
  and `outdated`.
- The setup row shows **Update**, which installs the new id and moves `current`.
- An agent records the executable path it started from. A folder any agent still runs from
  is kept until that agent ends, so a running Codex agent keeps its build.
- This applies to Claude's toolset as well.

**Phase 5: Codex on servers (US4).**
- The `openAIAPIKey` kind (`sk-` but not `sk-ant-`), checked with `GET
  https://api.openai.com/v1/models` (contracts/credentials.md).
- Lent as `CODEX_API_KEY`, with `OPENAI_API_KEY` cleared.
- `NO_BROWSER=1` in every server launch of Codex.
- A Settings ▸ Runtime credentials row, with the billing note.
- Live on agents-bare: a bare box, then install, turn, `leak-check.sh` for the key, and a
  check that no `auth.json` exists on the box.

**Phase 6: Everywhere a runtime is chosen, and docs.**
- Phone and iPad start forms, workflow steps and `start_agent` read the runtime list:
  verify each, and fix any hard-coded list.
- Five docs pages; `scripts/docs-check.py` passes.

## Complexity Tracking

| Deviation | Why needed | Simpler alternative rejected because |
|---|---|---|
| `Runtime.usesAppCopyOnly` (Codex never uses the person's npx or `codex-acp`) | D3/D5: the pinned lock, including the exact 238 MB Codex binary, is what runs, and it is installed with progress | `npx -y codex-acp@1.13.1` like Claude resolves `@openai/codex` by a caret range, and does its 330 MB fetch silently inside the first turn |
| `Lever.environmentJSON` | Codex's only per-process, additive lever is `CODEX_CONFIG` (R5) | `CODEX_HOME` would sign the person out (D6), and there is no deny-list flag |
| Toolset per runtime, each with its own Node (~180 MB twice) | 043's rule is that a toolset is replaced as a whole. Codex and Claude pins move independently | a shared Node would couple the two runtimes' updates, for a saving only on disk |
