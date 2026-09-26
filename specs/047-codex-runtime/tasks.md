# Tasks: Codex as a Runtime

**Input**: `specs/047-codex-runtime/` (plan.md, spec.md, research.md R1–R11, data-model.md,
contracts/runtime-launch.md, contracts/credentials.md, quickstart.md)

**Tests**: included where the plan names them. This project proves every change with
`swift test` and a scratch-root walk (run-app skill). The catalog-totality test forces a
policy entry into the same commit as the catalog entry.

**Paths**: `Kit/` = `Packages/AgentsKit/`. Core = `Kit/Sources/AgentsKitCore/`. Daemon-side
= `Kit/Sources/AgentsKit/`. Tests = `Kit/Tests/AgentsKitTests/`.

**Shared with 046 (Gemini)**, whose tasks are on `agents/speckit-specify-support-gemini`:
Phase 3 (T009–T017), Phase 6 (T032–T036) and Phase 7 (T037–T041) are the same work as
046's T009–T017, T035–T039 and T040–T044, with the same names (`usesAppCopyOnly`,
`toolsets` map, `outdated`, per-runtime `CredentialKind`). **Before each of those phases,
check `git log main` for 046's commits. If they have landed, merge main and do only what
Codex still lacks.** Never build a second version of the same thing.

**Standing rules for every task**:
- Never write to `~/.codex` or set `CODEX_HOME`. Run probes with `HOME=/tmp/codex-home`,
  except in the one step where Alex signs in.
- Launch scratch apps with a clean environment (`env -i …`), and drive them only when
  Alex is away.
- Build the two Xcode schemes one after the other, with plugin validation skipped.
- No runtime-id `if` or `switch` outside the catalogs.

## Format: `[ID] [P?] [Story] Description`

---

## Phase 1: Setup

- [X] T001 Merge current `main` into this branch, and confirm that `swift test` in `Kit/` passes and both Xcode schemes build before any change. Record the failing-test baseline (main's known flakes) in `specs/047-codex-runtime/walk/baseline.md`.
- [X] T002 Make `scripts/update-toolset.sh <runtime> <node-version> <package> <version> [--min-free-bytes N] [--platform-package-pattern P]` from `scripts/update-claude-toolset.sh`. It writes `App/Resources/toolsets/<runtime>/{manifest.json,package.json,package-lock.json,mac-node.json}` in exactly the formats Claude's use today, and fails unless the lock holds a package matching the pattern for `linux-x64`, `linux-arm64`, `darwin-x64` and `darwin-arm64`. Reduce `scripts/update-claude-toolset.sh` to one call of it (pattern `claude-agent-sdk-`). Re-run it for Claude, and check `App/Resources/toolsets/claude/` is byte-identical. If 046 has already added `scripts/update-gemini-toolset.sh`, fold it into the same generic script.
- [X] T003 Run `scripts/update-toolset.sh codex v24.21.0 @agentclientprotocol/codex-acp 1.13.1 --min-free-bytes 1073741824 --platform-package-pattern 'codex-'`. Commit `App/Resources/toolsets/codex/`. Check that `project.yml` copies the whole `toolsets/` folder into the app bundle, and add `codex/` if Claude's folder is listed by name.
- [X] T004 [P] Add `"codex": [<toolset shim>]` to `RUNTIMES` in `scripts/acp-handshake.sh`, taking the shim path from `AGENTS_CODEX_SHIM` (no PATH lookup), and Codex's tool names to `scripts/runtime-tools.sh`.

---

## Phase 2: Spike (needs Alex's ChatGPT sign-in, and an OpenAI API key for the server half) ⚠️

**Purpose**: settle research's "to measure" items before code depends on them. Use the
toolset already `npm ci`'d in `/tmp/codex-lock` with Node from the pinned tarball, or
rebuild it from T003.

- [X] T005 Ask Alex (AskUserQuestion) for a moment when he can sign Codex in with ChatGPT in the browser, and for an OpenAI API key for the server half. The key goes only in `/tmp` and the scratch root's launch environment, never in a repo file.
- [X] T006 In the real home, with Alex present: run the adapter, call `authenticate {methodId:"chat-gpt"}`, and let Alex finish in the browser. Record in research R4 whether it completed over ACP and wrote `~/.codex/auth.json`, and whether the toolset's own `codex login status` agrees. If it did not complete, repeat with `chat-gpt-device-code` and record that. Take `shasum ~/.codex/config.toml` before and after (the file may be absent).
- [X] T007 Signed in, run a real turn with the app's MCP server in `mcpServers` and `CODEX_CONFIG` from contracts/runtime-launch.md. Record in research:
  - R2: the app's MCP tools reach the model.
  - R5: each of `multi_agent`, `memories`, `apps` and `goals` is accepted, and its tools are absent from Codex's tool list, or listed but refused.
  - R6: `request_user_input` arrives as `elicitation/create` in the `agent` mode.
  - R7: whether token counts arrive, and in what shape a limit refusal arrives.
  - R8: whether a call to an app tool (`finish_turn`) raises `session/request_permission` in `agent` mode, and, if it does, whether an `mcp_servers` approval key in `CODEX_CONFIG` stops it.
- [ ] T008 On agents-bare (test-servers skill, 127.0.0.1:2223): install the toolset with `npm ci` from the lock, set `CODEX_API_KEY` and `NO_BROWSER=1`, and record in research R9:
  - whether `session/new` succeeds without `authenticate`, and if not, whether `DEFAULT_AUTH_REQUEST={"methodId":"api-key"}` fixes it;
  - the auth methods offered, which must not include `chat-gpt`;
  - the error shape for a deliberately wrong key.

  Afterwards, remove the toolset and the key from the box.

**Checkpoint**: research has no "to measure" left. Any change of decision is reflected in plan.md, data-model.md and the contracts before Phase 3 depends on it.

---

## Phase 3: Foundational (blocks every story; shared with 046's T009–T017)

- [X] T009 [P] Add `usesAppCopyOnly: Bool` to `Runtime` in `Core/Model/Runtime.swift`: default `false`, decoded leniently, absent reads as `false`.
- [X] T010 [P] In `Core/Runtimes/Toolset.swift`, make `shimLines` name no runtime in its comment, and add `shimName(for executable:)` so the shim is `bin/<runtime.executable>`. (046's `forwardsArguments` is not needed by Codex, but must not break it.)
- [X] T011 [P] Tests in `Tests/Unit/ToolsetTests.swift`:
  - Claude's manifest and shim are unchanged byte for byte;
  - Codex's manifest decodes, with `entry` `dist/index.js` and `minFreeBytes` 1073741824;
  - both toolset ids are stable.
- [X] T012 In `Daemon-side/Runtimes/RuntimeDiscovery.swift`, make `RuntimeDiscovery.locate` skip the PATH loop and the `executable.contains("/")` branch when `runtime.usesAppCopyOnly`, going from the server toolset straight to `appToolset(for:)`.
- [X] T013 [P] Tests in `Tests/Unit/AppToolsetDiscoveryTests.swift`:
  - a `codex-acp` (and an `npx`) on a search path is ignored for an app-copy-only runtime, and the row reads `.missing`;
  - the app's whole toolset is found;
  - a toolset without `ok` is not.
- [X] T014 In `Daemon-side/Runtimes/RuntimeInstaller.swift`, replace `RuntimeInstaller.toolset: MacToolsetInstaller?` with `toolsets: [String: MacToolsetInstaller]`, keyed by runtime id. `recipe(for:)` for `.toolset(runtimeID:)` looks up that id.
- [X] T015 In `Daemon-side/Daemon/Daemon.swift`, load every folder under the bundle's `toolsets/` that has a `manifest.json` into that map (the `toolsetsFolder:` parameter). In `Daemon/Sources/main.swift`, pass `Resources/toolsets`, not `Resources/toolsets/claude`. Update tests that pass one folder.
- [X] T016 Make `MacToolsetInstaller` runtime-neutral, in `Daemon-side/Runtimes/MacToolsetInstaller.swift`:
  - take the runtime's display name, and use it in every `Failure.sentence` and progress step ("Installing Codex", "Couldn’t reach the internet to download Codex");
  - write the shim as `bin/<executable>` (T010) and return that path;
  - its `npm ci` must install only the host's `@openai/codex-darwin-*` package (verify with the test below).
- [X] T017 [P] Extend `Tests/Unit/MacToolsetInstallerTests.swift` and `Tests/Unit/RuntimeInstallerTests.swift` for a second toolset, with a `file://` Node dist and a tiny fake package:
  - it installs into `tools/codex/`, and the shim `bin/codex-acp` is executable;
  - Claude's install and wording are unchanged.

**Checkpoint**: Claude, Grok, Copilot and Cursor behave exactly as before (the full suite against the T001 baseline).

---

## Phase 4: User Story 1, start a Codex agent on the Mac (P1) 🎯 MVP

**Goal**: Codex is a row on 048's set-up page, **Install** puts the app's pinned copy in
place, and a Codex agent then works like any runtime.

**Independent test**: a scratch root with an `npx` and a `codex-acp` on its PATH: the sheet lists Codex as not on this Mac. Press **Install** and wait for the tick. Then start an agent, create a file, run `ls`, stop, resume, and attach a picture (quickstart §2–§3).

- [X] T018 [US1] Add `RuntimeCatalog.codex` in `Core/Runtimes/RuntimeCatalog.swift`: id `codex`, name `Codex`, executable `codex-acp`, arguments `[]`, `install: .toolset(runtimeID: "codex")`, `installPage` `https://github.com/agentclientprotocol/codex-acp`, `usesAppCopyOnly: true`. Append it to `builtIn`, and extend the file's doc comment (why Codex is never the person's npx: R1). Same commit as T019.
- [X] T019 [US1] Add `ToolPolicyCatalog.codex` in `Core/Runtimes/ToolPolicyCatalog.swift`, and append it to `builtIn`:
  - `removed`: `spawn_agent`, `send_input`, `wait` and `close_agent` (`.agents`); `memories` (`.artefacts`); `apps` (`.artefacts`); `goals` (`.standingArrangements`). Adjust the names to the list T007 recorded.
  - `kept`: `request_user_input`, with the because-sentence in data-model.md.
  - `residue`: whatever T007 found still listed.
  - `escalationTool`: `"request_user_input"`.
  - `lever`: `.environmentJSON(variable: "CODEX_CONFIG", value:)`, with the value in contracts/runtime-launch.md.
- [X] T020 [US1] Add `Lever.environmentJSON(variable: String, value: JSONValue)` in `Core/Runtimes/ToolPolicy.swift`, with `ToolPolicy.launchEnvironment: [String: String]`: the value serialised with sorted keys, and empty for every other lever. `sessionMeta` returns `nil` for it, and `launchArguments` returns `[]`. Merge `policy.launchEnvironment` into the environment in `ProcessSessionLauncher.launch` in `Daemon-side/Daemon/DaemonCore.swift`, after `LentEnvironment.applied` and `RuntimePolicyFiles`.
- [X] T021 [P] [US1] Tests:
  - the catalog-totality test in `Tests/Unit/ToolPolicyTests.swift` lists Codex;
  - `CODEX_CONFIG`'s text equals contracts/runtime-launch.md's JSON;
  - `Tests/Integration/ToolScopingTests.swift` sees `CODEX_CONFIG` in a `FakeLauncher` launch of Codex and not in Claude's;
  - a new test checks that every `.toolset` runtime has `App/Resources/toolsets/<id>/manifest.json` with a matching `runtimeID` and `packageVersion`.
- [X] T022 [US1] Starting an agent on a runtime whose status is `.missing`, `.installing` or `.installFailed` must answer with that status's sentence and the row's action instead of launching (FR-003). Check the existing start path in `Daemon-side/Daemon/DaemonCore+Commands.swift` and the start form already do this for 048's rows, and fix only what does not. Add a `Tests/Integration/StartResilienceTests.swift` case for an installing Codex.
- [X] T023 [US1] **Look gate**:
  - build, and launch a scratch root (run-app skill, clean env, dummy `npx` and `codex-acp` on the scratch PATH);
  - screenshot the set-up sheet listing Codex as **Not on this Mac**;
  - press **Install** (AX by pid, only when Alex is away) and screenshot the progress and the tick;
  - save the shots under `specs/047-codex-runtime/walk/look/`, and show Alex before T024.
- [ ] T024 [US1] Live test in `Tests/Live/LiveRuntimeTests.swift`, gated on `AGENTS_CODEX=1`, with Codex signed in (T006): a real Codex turn through the app's toolset writes a file and ends, and a resume loads the history.
- [ ] T025 [US1] Walk on the scratch root, signed in (quickstart §3 steps 3 and 7): start, edit, `ls` with a permission ask answered on the Mac, stop mid-turn, resume, attach a picture. Also check the modes menu shows `read-only`/`agent`/`agent-full-access`, and that a picked mode is remembered for the next Codex agent. Record it in `specs/047-codex-runtime/walk/README.md` with screenshots.
- [ ] T026 [US1] SC-004: compare `shasum ~/.codex/config.toml` and the account in `~/.codex/auth.json` before and after the walk; they must be identical. Note it in the walk README.

**Checkpoint**: the MVP. Codex installs from the set-up page and runs agents on the Mac.

---

## Phase 5: User Story 3, the app's own tools and scoping (P2, ships with the MVP)

**Goal**: a Codex agent has the app's tools, not Codex's rivals, and its questions arrive as cards.

**Independent test**: ask a Codex agent to list its tools, end with a report, lease a resource and ask a question (spec US3).

- [ ] T027 [US3] Check that `Daemon-side/ACP/Serve/Briefing.swift` builds Codex's removed, residue and escalation lines from the table (naming `request_user_input`) and stays under the briefing ceiling. Add a Codex case to `Tests/Unit/BriefingTests.swift`.
- [ ] T028 [US3] If T007 found that the app's tools ask for approval in `agent` mode and a `CODEX_CONFIG` key stops it, add that key to the lever's value (and to contracts/runtime-launch.md). If nothing stops it, add a sentence to the policy's comment, and check that the briefing does not claim the tools run without asking (FR-015).
- [ ] T029 [US3] Live tests (`AGENTS_CODEX=1`):
  - in `Tests/Live/RuntimeToolScopingLiveTests.swift`, Codex's tool list has the app's MCP tools and lacks the removed ones (or they are refused, with the category's sentence);
  - in `Tests/Live/FinishTurnLiveTests.swift` and `Tests/Live/OutcomeReportLiveTests.swift`, Codex ends turns through `finish_turn`: SC-006 needs 9 of 10 over ten short prompts, so record the count.
- [ ] T030 [US3] Walk (quickstart §3 steps 4–6): a question card appears on the Mac and on the phone, and the answer reaches Codex; the agent leases and releases `screen`, and waits for a `custom.` event. Note the results in the walk README.

---

## Phase 6: User Story 2, sign Codex in with ChatGPT (P1)

**Goal**: an unsigned start says **Needs signing in**, and the sheet offers ChatGPT first.

**Independent test**: a scratch root with `HOME` pointing at an empty folder for the runtime: start, open the sheet, sign in, and a turn works.

- [ ] T031 [US2] Add `ToolPolicy.preferredAuthMethods: [String]` (default empty) in `Core/Runtimes/ToolPolicy.swift`. For Codex it is `["chat-gpt", "chat-gpt-device-code", "api-key"]`. `RuntimeAccount.preferredMethod` and the sheet's order in `Core/Runtimes/RuntimeAccount.swift` follow it, with unlisted methods after it in their own order. Empty keeps today's rule. Test in `Tests/Integration/RuntimeAccountTests.swift` with `FakeACPAgent` answering Codex's exact `authMethods` (research R2).
- [ ] T032 [US2] Add a `Tests/Integration/RuntimeAccountTests.swift` case for Codex's `-32000` "Authentication required" leading to `needsSignIn`. On the scratch root, verify the sheet lists the three methods in order with a sign-out button (`auth.logout`), and that sign-out makes the next start say **Needs signing in**. Put screenshots in the walk README.
- [ ] T033 [US2] If T006 showed `chat-gpt` cannot finish over ACP, make the sheet lead with `chat-gpt-device-code` (URL elicitation: a link and a code) by reordering `preferredAuthMethods`, in `Core/Runtimes/ToolPolicyCatalog.swift`. Otherwise, nothing to do.
- [ ] T034 [US2] Failure sentences (FR-011, FR-022), with `FakeACPAgent` tests in `Tests/Integration/StartResilienceTests.swift`:
  - a plan-limit or rate-limit refusal (shape from T007) says "Codex's usage limit is reached" plus the reset time if one is given;
  - an expired sign-in mid-session says Codex needs signing in again;
  - an adapter that rejects `CODEX_CONFIG` says "Codex did not start: <its message>".

---

## Phase 7: A new pin reaches the Mac (D5, FR-003a; shared with 046's T035–T039 and with Claude)

**Goal**: a newer pin arrives through **Update**, and never pulls a build from under a running agent.

**Independent test**: with two fake pins, install the old one and bundle the new one; the row shows **Update**. Start an agent on the old one and press Update: the agent keeps running, and the old folder is removed only after it ends (quickstart §4).

- [X] T035 [US1] Add "outdated" to discovery. `appToolset(for:)` resolves `current` and compares its id with the bundled toolset's id, and `RuntimeStatus` gains `outdated: Bool`, encoded leniently for older phones. In `Daemon-side/Runtimes/RuntimeDiscovery.swift` and `Core/Model/Runtime.swift`.
- [X] T036 [US1] In `Daemon-side/Daemon/DaemonCore+Install.swift`, `DaemonCore.installRuntime` proceeds when the runtime is available but outdated.
- [X] T037 [US1] Agents record the executable path they started from, and `ProcessSessionLauncher` launches through the resolved `<id>` path, never `current`. `MacToolsetInstaller.removeOthers(except:keeping:)` skips toolset ids an agent still runs from, and the daemon removes unused old folders at the next install and at start. In `Daemon-side/Runtimes/MacToolsetInstaller.swift`, `Daemon-side/Daemon/DaemonCore+Install.swift` and `Daemon-side/Daemon/DaemonCore.swift`.
- [X] T038 [P] [US1] Tests in `Tests/Unit/RuntimeInstallDispatchTests.swift` and `Tests/Unit/MacToolsetInstallerTests.swift`, with two fake pins, covering T035–T037 for Codex and Claude.
- [ ] T039 [US1] `RuntimeInstallRow` in `App/Sources/Runtimes/InstallAgentsSheet.swift` shows **Update** beside the tick when `status.outdated`, calling the same `installRuntime`. Take one screenshot on the scratch root (look gate).

---

## Phase 8: Generalise 043 for a second runtime (blocks US4; shared with 046's T040–T044)

**Before starting**: run `git log main -- Kit/Sources/AgentsKit/Daemon/DaemonCore+Credentials.swift`. If 046 has already made these per-runtime, merge main and skip to Phase 9.

- [ ] T040 Make `CredentialKind` carry `runtimeID`, `environmentVariable` and `clearedVariables` per kind (Claude's two unchanged), in `Core/Runtimes/CredentialKind.swift`. `LentEnvironment.applied` must clear only the lent kind's runtime variables, in `Daemon-side/Daemon/DaemonCore+Credentials.swift`.
- [ ] T041 In `Daemon-side/Daemon/DaemonCore+Credentials.swift`:
  - `DaemonCore.lendableRuntimes` becomes the runtimes with a bundled toolset;
  - `ServerSignIn.exists(runtimeID:)` asks a per-runtime check (Claude: `~/.claude/.credentials.json` or its variables);
  - `lendCredential` refuses a kind whose `runtimeID` ≠ `lend.runtime`;
  - `isAuthenticationFailure` gains a per-runtime shape (Claude's `errorKind` stays).
- [ ] T042 Make `ToolsetInstaller`'s scripts, and `isInstalled`/`swap`/`removeOthers`, use `toolset.manifest.runtimeID` for `serverFolder` and the shim from T010. Rename `ServerFacts.canInstallClaude` to `canInstall(_ toolset:)`, and make `ServerConnection`'s Claude state, `wantsClaude` and `installClaude` step per toolset. In `Daemon-side/Hosts/ToolsetInstaller.swift`, `Core/Hosts/Host.swift` and `Daemon-side/Hosts/ServerConnection.swift`.
- [ ] T043 App side:
  - `ServerCredentials.runtimes` comes from the bundled toolsets;
  - `HostSet.claudeToolset` becomes `toolsets`;
  - `Lending`, `AppModel` (the `record("claude")` at the host check) and `ServersSettingsView` (`claudeLine`) iterate runtimes;
  - `AgentsSettingsView`'s Claude-only footer names each toolset runtime.

  Files: `App/Sources/Settings/ServerCredentials.swift`, `App/Sources/Hosts/HostSet.swift`, `App/Sources/Hosts/Lending.swift`, `App/Sources/AppModel.swift`, `App/Sources/Settings/ServersSettingsView.swift` and `App/Sources/Settings/AgentsSettingsView.swift`.
- [ ] T044 Run `Tests/Integration/LendTests.swift`, `ServerInstallerTests.swift`, `ToolsetInstallTests.swift`, `RebuiltServerTests.swift`, `ServerConnectionTests.swift`, `Tests/Unit/CredentialKindTests.swift` and, with `AGENTS_BARE=1`, `Tests/Live/BareServerLiveTests.swift`. Claude on servers must be unchanged.

---

## Phase 9: User Story 4, Codex on servers (P3)

**Goal**: a bare Linux server installs Codex's toolset and runs a Codex agent with an OpenAI key lent from the Mac. The key is never written to the server's disk, and ChatGPT never leaves the Mac.

**Independent test**: quickstart §5. Put the key in scratch Settings; a Codex agent on agents-bare runs `uname -a`; `leak-check.sh` finds nothing, and there is no `auth.json` on the box.

- [ ] T045 [US4] Add `CredentialKind.openAIAPIKey` in `Core/Runtimes/CredentialKind.swift`:
  - recognised by prefix `sk-` and not `sk-ant-`, with `init?(secret:)` checking `sk-ant-` first;
  - runtime `codex`; lends `CODEX_API_KEY`; clears `CODEX_API_KEY` and `OPENAI_API_KEY`;
  - display "OpenAI API key";
  - paste refusal: "That isn't an OpenAI API key. They start with sk-; get one at platform.openai.com/api-keys."

  Tests in `Tests/Unit/CredentialKindTests.swift` (masked descriptions only; `sk-ant-oat…` is still Claude's).
- [ ] T046 [US4] Add the OpenAI key check to `Daemon-side/Credentials/CredentialCheck.swift`: `GET https://api.openai.com/v1/models` with `Authorization: Bearer`. 200 is Works, 401 is refused, anything else is could-not-check. Tests in `Tests/Unit/CredentialCheckTests.swift`, with a stubbed session.
- [ ] T047 [US4] Keep a Keychain record `codex` beside Claude's. Settings ▸ Runtime credentials shows a Codex row, with the kind, where to get one, the billing note from contracts/credentials.md, a paste field, and the key masked as `sk-…` plus its last 4 characters. In `App/Sources/Settings/ServerCredentials.swift`. **Look gate**: one screenshot to Alex.
- [ ] T048 [US4] Server launch environment for Codex: set `NO_BROWSER=1` whenever the daemon runs with `--serve`, and set `DEFAULT_AUTH_REQUEST={"methodId":"api-key"}` with a lent key only if T008 showed it is needed. Put these in the policy or launch path in `Daemon-side/Daemon/DaemonCore.swift`, without a runtime-id branch: a `serverEnvironment` field on the Codex policy. Test with `FakeLauncher` in `Tests/Integration/LendTests.swift`: the Mac launch has no `NO_BROWSER`, and the server launch does.
- [ ] T049 [US4] Offer Codex in a server project's runtime list when it is installable there. The set-up checklist must show the Codex toolset install, and a server marked "own sign-in only" must be sent no key (`ServerSignIn.exists("codex")`: `~/.codex/auth.json`, or `CODEX_API_KEY`/`OPENAI_API_KEY` in the login environment). Verify through `App/Sources/Hosts/` and fix any gaps.
- [ ] T050 [US4] Extend `Tests/Live/BareServerLiveTests.swift` (`AGENTS_BARE=1 AGENTS_CODEX_KEY=…`):
  - install Codex's toolset on agents-bare and run a turn;
  - run `scripts/leak-check.sh` for the key on the server's disk and in the Mac's logs, and check `~/.codex/auth.json` is absent on the box (SC-005; record the time);
  - check the Mac's own Codex is still signed in with ChatGPT.

---

## Phase 10: Polish & cross-cutting

- [ ] T051 [P] Everywhere a runtime is chosen: check the phone and iPad start forms (`Remote/`), workflow steps, the runtime menu and `start_agent` all list Codex from `RuntimeCatalog.builtIn`, and fix any hard-coded list. Build Remote for the generic simulator only.
- [ ] T052 [P] Docs. `scripts/docs-check.py` must pass.
  - `docs/reference/runtimes.md`: the count, and a Codex row: installed from the set-up page, the app's copy only, pictures, ChatGPT or API-key sign-in, questions as cards, the three modes, context use but no cost, plan limits, residue.
  - `docs/how-to/sign-a-runtime-in.md`: signing in with ChatGPT, device code or API key.
  - `docs/how-to/add-a-linux-server.md`: Codex takes an OpenAI key, and why ChatGPT stays on the Mac.
  - `docs/reference/settings.md`: Agents and Runtime credentials list Codex.
  - `docs/explanation/scoped-tools.md`: Codex's switched-off features and residue.
- [ ] T053 Run the full `swift test` six times on this branch and on its merge base; only main's known flakes may differ. Both Xcode schemes and the Linux agentsd gate must build.
- [ ] T054 Run quickstart.md end to end on a scratch root and agents-bare, and tick the spec checklist. Leave the real app untouched until Alex says to merge. Update the spec-queue memory.

---

## Dependencies & execution order

- **Setup (T001–T004)** comes before the **Spike (T005–T008)**. T005 is Alex's. T006 needs him at the browser, T007 needs T006, and T008 needs the key.
- **Foundational (T009–T017)** can start during the spike and blocks every story. It is shared with 046: check main first.
- **US1 (T018–T026)** and **US3 (T027–T030)** ship together, because the catalog entry forces the policy. The T023 look gate comes before T024. T019's names wait for T007.
- **US2 (T031–T034)** comes after T018 and T006. T031–T032 can run beside US3.
- **Phase 7 (T035–T039)** comes after US1 and is independent of servers. It is shared with 046.
- **Phase 8 (T040–T044)** comes after Foundational and is independent of US1–US3. It is shared with 046.
- **US4 (T045–T050)** comes after Phase 8 and T008.
- **Polish (T051–T054)** comes last.

## Parallel opportunities

- T004 beside T002–T003.
- In Foundational, T009, T010 and T011 together. T013, T017 (tests in different files) once their subjects exist. T014–T016 are one chain of edits and go in sequence.
- In US1, T021 beside T020 and T022.
- Phase 8 (the servers generalisation) can run beside US1, US2 and US3 in another worktree, and is a candidate for one helper agent. Coordinate with 046 first, because only one lane should build it.
- T051 and T052 together.

## Implementation strategy

1. **MVP** = Setup + Spike + Foundational + US1 + US3 + US2's ordering (T031): Codex on the set-up page, signed in with ChatGPT, running agents on the Mac with the app's tools. Stop at T030 and show Alex.
2. Then Phase 7 (updates), because the first pin bump after release needs it.
3. Then Phase 8 and US4 (servers), coordinating with 046 on Phase 8.
4. Then US2's remaining failure sentences, and polish.

## Per-story independent tests

- **US1**: install from the set-up page, then start, edit, `ls`, stop, resume, picture (quickstart §2–§3).
- **US2**: signed out: **Needs signing in**, the sheet with ChatGPT first, sign in, then a turn (quickstart §3 steps 1–2).
- **US3**: the tool list, `finish_turn`, a lease, and a question card (quickstart §3 steps 4–6).
- **US4**: bare box, key lent, `uname -a`, no leak, no `auth.json` (quickstart §5).
