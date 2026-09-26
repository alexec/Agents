# Tasks: Gemini CLI as a Fifth Runtime

**Input**: `specs/046-gemini-cli/` — plan.md, spec.md, research.md (R1–R12), data-model.md,
contracts/runtime-launch.md, contracts/credentials.md, quickstart.md

**Tests**: included where the plan names them. This project proves every change with
`swift test` plus a scratch-root walk (run-app skill), and the catalog-totality test makes a
policy entry mandatory in the same commit as the catalog entry.

**Paths**: `Kit/` = `Packages/AgentsKit/`. Core = `Kit/Sources/AgentsKitCore/`, Daemon-side =
`Kit/Sources/AgentsKit/`, tests = `Kit/Tests/AgentsKitTests/`.

**Standing rules for every task**: never write to `~/.gemini` or run a vendor script against the
real home (use a scratch root; `AGENTS_TEST_INSTALL_SCRIPT` for any 048 walk); launch scratch
apps with a clean environment (`env -i …`); build the two Xcode schemes one after the other
with plugin validation skipped; no runtime-id `if`/`switch` outside the catalogs.

## Format: `[ID] [P?] [Story] Description`

---

## Phase 1: Setup

- [ ] T001 Merge current `main` into this branch and confirm `swift test` in `Kit/` and both Xcode schemes build before any change; record the failing-test baseline (main's known flakes) in `specs/046-gemini-cli/walk/baseline.md`
- [X] T002 Create `scripts/update-gemini-toolset.sh` from `scripts/update-claude-toolset.sh`: package `@google/gemini-cli`, version `0.61.0`, `entry` `bundle/gemini.js`, `forwardsArguments: true`, `minFreeBytes` 419430400; writes `App/Resources/toolsets/gemini/{manifest.json,package.json,package-lock.json,mac-node.json}` with Node v24.21.0 checksums for Linux `x86_64`/`aarch64` and macOS `arm64`/`x64` (same Node pin as `App/Resources/toolsets/claude/`)
- [X] T003 Run `scripts/update-gemini-toolset.sh` and commit `App/Resources/toolsets/gemini/`; check the folder is copied into the app bundle's `toolsets/` beside `claude/` in `project.yml` (add it if the Claude folder is listed by name)
- [X] T004 [P] Add `"gemini": [<toolset shim>, "--acp"]` to `RUNTIMES` in `scripts/acp-handshake.sh` and the Gemini tool names to `scripts/runtime-tools.sh`, taking the shim path from `AGENTS_GEMINI_SHIM` (no PATH lookup)

---

## Phase 2: Spike (needs a Gemini API key from Alex) ⚠️

**Purpose**: settle research's five "to measure" items before code depends on them.

- [X] T005 Ask Alex for a Gemini API key (AskUserQuestion); keep it only in the scratch root's launch environment and in `/tmp`, never in a repo file or the real app's environment
- [X] T006 With a hand-run `npm ci` of `App/Resources/toolsets/gemini/` into `/tmp/gemini-spike/` (Node from the pinned tarball), run a real `--acp` turn with the app's MCP server in `mcpServers` and a hand-written policy file on `--policy`; record in `specs/046-gemini-cli/research.md` R2 (MCP tools reach the model), R3 (untrusted folder does not stop a turn), R5 (a `deny` rule with no `argsPattern` hides the tool or only refuses it), R9 (shape of a quota / `RESOURCE_EXHAUSTED` failure over ACP)
- [X] T007 Same setup, no key in the environment: call `authenticate` with `oauth-personal` and with `gemini-api-key`; record in research R4 what each does over ACP and whether a lent `GEMINI_API_KEY` alone is enough on a server
- [X] T008 (Mac half done, R13: `npm ci` 4 s, no compiler, `node-pty` not needed) On agents-bare (test-servers skill, 127.0.0.1:2223) and on this Mac, confirm `npm ci --ignore-scripts` of the Gemini lock succeeds without a compiler and `run_shell_command` works (`node-pty` prebuilt or skipped); record in research R10

**Result (R13)**: all measured but quota (left to the walk) and agents-bare (T008). Two decisions by Alex: `--skip-trust` (D7) and one Settings key for the Mac and servers (D3 revised) — tasks T059–T062 below.

**Checkpoint**: research has no "to measure" left; any change of decision is reflected in plan.md and contracts before Phase 3.

---

## Phase 3: Foundational (blocks every story)

- [X] T009 [P] Add `usesAppCopyOnly: Bool` (default `false`, decoded leniently, absent = false) to `Runtime` in `Core/Model/Runtime.swift`
- [X] T010 [P] Add `forwardsArguments: Bool` (default `false` when absent) to `Toolset.Manifest`, and make `Toolset.shimLines` name no runtime in its comment and end with ` "$@"` when `forwardsArguments` is true, in `Core/Runtimes/Toolset.swift`; add `shimName(for executable:)` so the shim is `bin/<runtime.executable>`
- [X] T011 [P] Unit tests in `Tests/Unit/ToolsetTests.swift`: Claude's manifest decodes with `forwardsArguments == false` and an unchanged shim; Gemini's shim forwards `"$@"`; both toolset ids are stable hashes
- [X] T012 Make `RuntimeDiscovery.locate` skip the PATH loop (and the `executable.contains("/")` branch) when `runtime.usesAppCopyOnly`, going from the server toolset straight to `appToolset(for:)`, in `Daemon-side/Runtimes/RuntimeDiscovery.swift`
- [X] T013 [P] Tests in `Tests/Unit/AppToolsetDiscoveryTests.swift`: a `gemini` on a search path is ignored for an app-copy-only runtime (row reads `.missing`); the app's whole toolset is found; a toolset without `ok` is not
- [X] T014 Replace `RuntimeInstaller.toolset: MacToolsetInstaller?` with `toolsets: [String: MacToolsetInstaller]` keyed by runtime id; `recipe(for:)` for `.toolset(runtimeID:)` looks up that id, in `Daemon-side/Runtimes/RuntimeInstaller.swift`
- [X] T015 In `Daemon-side/Daemon/Daemon.swift` load every folder under the bundle's `toolsets/` (not one `toolsetFolder`) into that map; keep the `init` parameter compatible for tests (`toolsetsFolder:`), and update the app's call site that passes the bundle folder
- [X] T016 Make `MacToolsetInstaller` runtime-neutral in `Daemon-side/Runtimes/MacToolsetInstaller.swift`: take the runtime's display name, say it in every `Failure.sentence` and progress step ("Installing Gemini", "Couldn’t reach the internet to download Gemini"), write the shim as `bin/<executable>` from T010 and return that path
- [X] T017 [P] Extend `Tests/Unit/MacToolsetInstallerTests.swift` and `Tests/Unit/RuntimeInstallerTests.swift` (with `Tests/Support/FakeMacToolset.swift`) for a second toolset: installs into `tools/gemini/`, shim `bin/gemini` executable, Claude's install and words unchanged
- [X] T018 Add `EnvironmentFile.argument: String?` beside a now-optional `variable`, exactly one set (precondition in `init`), in `Core/Runtimes/ToolPolicy.swift`; `RuntimePolicyFiles` in `Daemon-side/Runtimes/RuntimePolicyFiles.swift` writes both kinds under `<root>/runtimes/` and returns environment additions and argument additions (`[argument, path]`) separately; the launch path appends the arguments after `runtime.arguments`
- [X] T019 [P] Tests in `Tests/Unit/ToolPolicyTests.swift` and `Tests/Integration/ToolScopingTests.swift`: an argument-named file is written, rebuilt each launch, and passed as `--policy <path>` via `FakeLauncher`; Grok's variable-named file unchanged

**Checkpoint**: Claude, Grok, Copilot, Cursor behave exactly as before (full suite vs T001 baseline).

---

## Phase 4: User Story 1 — Start a Gemini agent on the Mac (P1) 🎯 MVP

**Goal**: Gemini is a row on the set-up page; **Install** puts the app's pinned copy in place; a Gemini agent then works like any runtime.

**Independent test**: scratch root with a `gemini` on PATH → sheet lists Gemini as not on this Mac → Install → tick → start an agent, create a file, run `ls`, stop, resume (quickstart §3, §3a).

- [X] T020 [US1] Add `RuntimeCatalog.gemini` in `Core/Runtimes/RuntimeCatalog.swift`: id `gemini`, name `Gemini`, executable `gemini`, arguments `["--acp"]`, `install: .toolset(runtimeID: "gemini")`, `installPage` `https://github.com/google-gemini/gemini-cli`, `usesAppCopyOnly: true`; append to `builtIn` → `[claude, grok, copilot, cursor, gemini]`; extend the file's doc comment. Same commit as T021.
- [X] T021 [US1] Add `ToolPolicyCatalog.gemini` in `Core/Runtimes/ToolPolicyCatalog.swift`: `removed` = `invoke_agent` (`.agents`) and `tracker_create_task`, `tracker_update_task`, `tracker_get_task`, `tracker_list_tasks`, `tracker_add_dependency`, `tracker_visualize` (`.standingArrangements`); lever `.words` plus one `EnvironmentFile(name: "gemini-policy.toml", argument: "--policy")` whose TOML is one `[[rule]]` per category with `decision = "deny"`, the priority settled in T006, and `denyMessage` = that category's `instead`; `escalationTool: nil` with the R6 comment; append to `builtIn`
- [X] T022 [P] [US1] Tests: catalog-totality test lists five runtimes; `Tests/Unit/ToolPolicyTests.swift` checks Gemini's TOML text byte for byte against contracts/runtime-launch.md; a test that `RuntimeCatalog.gemini`'s pinned version equals `toolsets/gemini/manifest.json` `packageVersion`
- [X] T023 [US1] Read `_meta.quota.token_count` (`input_tokens`, `output_tokens`) as the turn's usage when `result["usage"]` is absent, cost left nil, in `ACPSession.turnUsage` in `Daemon-side/ACP/ACPSession.swift`; keep `model_usage`'s single model name on `TurnResult` for the model line
- [X] T024 [P] [US1] Tests in `Tests/Integration/TurnUsageTests.swift` with `Tests/Fake/FakeACPAgent.swift` sending Gemini's exact `_meta.quota` shape (research R7): tokens shown, cost absent (not zero); a `model_usage` naming another model changes the agent's shown model
- [X] T025 [US1] Starting an agent on a runtime whose status is `.missing`, `.installing` or `.installFailed` answers with that status's sentence and the row's action instead of launching (FR-003) — check the existing start path in `Daemon-side/Daemon/DaemonCore+Commands.swift` and the start form already do this for 048's rows; fix only what does not
- [ ] T026 [US1] (Alex's, 2026-09-25: he looks at the sheet himself; install proven over the socket, walk/README.md) **Look gate**: build, launch a scratch root (run-app skill, clean env, a dummy `gemini` on the scratch PATH), screenshot the start-up sheet listing Gemini as **Not on this Mac**, press **Install** (AX by pid, only when Alex is away), screenshot progress and the tick; save under `specs/046-gemini-cli/walk/look/` and show Alex before T027
- [ ] T027 [US1] Live test `Tests/Live/LiveRuntimeTests.swift` (gated on `AGENTS_GEMINI=1`, key from the environment): a real Gemini turn through the app's toolset writes a file and ends; resume loads history
- [ ] T028 [US1] Walk on the scratch root with the spike key (quickstart §3a): start, edit, `ls` with a permission ask answered, stop mid-turn, resume, attach a picture; record in `specs/046-gemini-cli/walk/README.md` with screenshots
- [ ] T029 [US1] SC-004 check: `shasum ~/.gemini/settings.json ~/.gemini/trustedFolders.json` before and after the walk are identical; note in the walk README

**Checkpoint**: MVP — Gemini installs from the set-up page and runs agents on the Mac.

---

## Phase 5: User Story 3 — The app's own tools and scoping (P3, ships with the MVP)

**Goal**: a Gemini agent has the app's tools, not Gemini's rivals, and its questions end as **Waiting on your answer**.

**Independent test**: ask a Gemini agent to list its tools, end with a report, lease a resource and ask a question (spec US3).

- [ ] T030 [US3] Check `Daemon-side/ACP/Serve/Briefing.swift` produces Gemini's removed/residue/escalation lines from the table (no escalation tool named) and stays under the briefing ceiling; add a `Tests/Unit/BriefingTests.swift` case for Gemini
- [ ] T031 [US3] If T006 found that `deny` only refuses and does not hide, say so in `ToolPolicyCatalog.gemini`'s comment and make sure `Tests/Integration/ResidualToolTests.swift` does not count refused tools as residue
- [ ] T032 [US3] Live (`AGENTS_GEMINI=1`) in `Tests/Live/RuntimeToolScopingLiveTests.swift`: Gemini's tool list has the app's MCP tools and lacks `invoke_agent` and `tracker_*` (or they are refused with the category's sentence)
- [ ] T033 [US3] Live in `Tests/Live/FinishTurnLiveTests.swift` and `Tests/Live/OutcomeReportLiveTests.swift`: Gemini ends turns through `finish_turn` (SC-006: 9 of 10 over ten short prompts; record the count); a question mid-turn ends as needs_answer, as for Grok
- [ ] T034 [US3] Walk: Gemini agent leases and releases a resource and waits for a `custom.` event; note results in the walk README

---

## Phase 6: Pin updates and running builds (D5, FR-003a — US1 follow-through, shared with Claude)

**Goal**: a newer pin reaches the Mac through **Update**, and an install never pulls a build from under a running agent.

**Independent test**: two fake pins; install old, bundle new → row shows **Update**; start an agent on old, press Update → agent keeps running, old folder removed only after it ends.

- [X] T035 (done by 047, merged 48b2c64: RuntimeStatus.outdated, **Update** in RuntimeInstallRow, old builds kept until tidy() at the next daemon start) [US1] Add "outdated" to discovery: `appToolset(for:)` reads `current/manifest.json`, compares the toolset id with the bundle's (`RuntimeInstaller.toolsets[id].toolset.id`), and `RuntimeStatus` gains `outdated: Bool` (encoded leniently for older phones) in `Daemon-side/Runtimes/RuntimeDiscovery.swift` and `Core/Model/Runtime.swift`
- [X] T036 (done by 047, merged 48b2c64: RuntimeStatus.outdated, **Update** in RuntimeInstallRow, old builds kept until tidy() at the next daemon start) [US1] `DaemonCore.installRuntime` proceeds when the runtime is available but outdated, in `Daemon-side/Daemon/DaemonCore+Install.swift`
- [X] T037 (done by 047, merged 48b2c64: RuntimeStatus.outdated, **Update** in RuntimeInstallRow, old builds kept until tidy() at the next daemon start) [US1] Agents record the executable path they started from; `MacToolsetInstaller.removeOthers(except:keeping:)` skips toolset ids an agent still runs from; the daemon removes unused old folders at the next install and at start, in `Daemon-side/Runtimes/MacToolsetInstaller.swift` and `Daemon-side/Daemon/DaemonCore+Install.swift`
- [X] T038 (done by 047, merged 48b2c64: RuntimeStatus.outdated, **Update** in RuntimeInstallRow, old builds kept until tidy() at the next daemon start) [P] [US1] Tests in `Tests/Unit/RuntimeInstallDispatchTests.swift` and `Tests/Unit/MacToolsetInstallerTests.swift` with two fake pins covering T035–T037
- [X] T039 (done by 047, merged 48b2c64: RuntimeStatus.outdated, **Update** in RuntimeInstallRow, old builds kept until tidy() at the next daemon start) [US1] `RuntimeInstallRow` shows **Update** beside the tick when `status.outdated`, calling the same `installRuntime`, in `App/Sources/Runtimes/InstallAgentsSheet.swift`; screenshot on the scratch root (look gate, one shot)

---

## Phase 7: Generalise 043 for a second runtime (blocks US4; shared with 047)

**Before starting**: `git log main -- Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Credentials.swift` — if 047 (Codex) has already made these per-runtime, merge main and skip to Phase 8.

- [X] T040 Make `CredentialKind` carry `runtimeID`, `environmentVariable` and `clearedVariables` per kind (Claude's two unchanged), in `Core/Runtimes/CredentialKind.swift`; `LentEnvironment.applied` clears the lent kind's runtime variables only, in `Daemon-side/Daemon/DaemonCore+Credentials.swift`
- [X] T041 `DaemonCore.lendableRuntimes` = runtimes with a bundled toolset; `ServerSignIn.exists(runtimeID:)` asks a per-runtime check (Claude: `~/.claude/.credentials.json` or its variables); `lendCredential` refuses a kind whose `runtimeID` ≠ `lend.runtime`, in `Daemon-side/Daemon/DaemonCore+Credentials.swift`
- [X] T042 `ToolsetInstaller` scripts use the toolset's `runtimeID` for `serverFolder` and the shim from T010; `ServerFacts.canInstallClaude` → `canInstall(_ toolset:)`, in `Daemon-side/Hosts/ToolsetInstaller.swift` and `Core/Hosts/Host.swift`
- [X] T043 App side: `ServerCredentials.runtimes` from the bundled toolsets; `Lending`, `AppModel` (the `record("claude")` at the host check) and `ServersSettingsView` (`claudeLine`) iterate runtimes, in `App/Sources/Settings/ServerCredentials.swift`, `App/Sources/Hosts/Lending.swift`, `App/Sources/AppModel.swift`, `App/Sources/Settings/ServersSettingsView.swift`, `App/Sources/Hosts/HostSet.swift`
- [X] T044 Run `Tests/Integration/LendTests.swift`, `ServerInstallerTests.swift`, `ToolsetInstallTests.swift`, `RebuiltServerTests.swift`, `Tests/Unit/CredentialKindTests.swift` and (with `AGENTS_BARE=1`) `Tests/Live/BareServerLiveTests.swift`: Claude on servers unchanged

---

## Phase 8: User Story 4 — Gemini on servers (P4)

**Goal**: a bare Linux server installs Gemini's toolset and runs a Gemini agent with a key lent from the Mac, never written to its disk.

**Independent test**: quickstart §5 — key in scratch Settings, Gemini agent on agents-bare runs `uname -a`, `leak-check.sh` finds nothing.

- [X] T045 [US4] Add `CredentialKind.geminiAPIKey`: prefix `AIza`, runtime `gemini`, lends `GEMINI_API_KEY`, clears `GEMINI_API_KEY` and `GOOGLE_API_KEY`, display "Gemini API key"; paste refusal sentence "That isn't a Gemini API key. They start with AIza; get one at aistudio.google.com/apikey." in `Core/Runtimes/CredentialKind.swift`; tests in `Tests/Unit/CredentialKindTests.swift` (masked descriptions only)
- [X] T046 [US4] Gemini key check in `Daemon-side/Credentials/CredentialCheck.swift`: `GET https://generativelanguage.googleapis.com/v1beta/models?pageSize=1` with header `x-goog-api-key` (never in the URL); 200 → Works, 400 `API_KEY_INVALID` or 403 → refused, else could-not-check; tests in `Tests/Unit/CredentialCheckTests.swift` with a stubbed session
- [X] T047 [US4] Keychain record `gemini` beside Claude's; Settings ▸ Runtime credentials shows a Gemini row (kind, where to get one, paste field, masked `AIza…` + last 4) in `App/Sources/Settings/ServerCredentials.swift`; **look gate**: one screenshot to Alex
- [X] T048 [US4] If T007 found a key in the environment is not enough, call `authenticate` with `gemini-api-key` after lending on a server, in the server launch path in `Daemon-side/Daemon/DaemonCore+Credentials.swift`
- [X] T049 [US4] Server start offers Gemini in a server project's runtime list when installable there; the set-up checklist shows the Gemini toolset install; "own sign-in only" sends no key — verify through `App/Sources/Hosts/` and fix gaps
- [X] T050 [US4] Extend `Tests/Live/BareServerLiveTests.swift` (`AGENTS_BARE=1 AGENTS_GEMINI=1`): install Gemini's toolset on agents-bare, run a turn, then `scripts/leak-check.sh` for the key on the server's disk and the Mac's logs (SC-005, time recorded)

---

## Phase 9: User Story 2 — Sign Gemini in (P2)

**Goal**: an unsigned start says **Needs signing in** and the sheet offers Gemini's own choices.

**Independent test**: scratch root with no Gemini sign-in → start → sheet → sign in → a turn works.

- [ ] T051 [US2] Verify on the scratch root that an unsigned Gemini start surfaces `-32000` as **Needs signing in** with the sheet (existing path); add a case to `Tests/Integration/RuntimeAccountTests.swift` with `FakeACPAgent` answering Gemini's exact error
- [ ] T052 [US2] Verify the sheet lists Gemini's four methods with its descriptions and shows no sign-out button (no `logout`); screenshot into the walk README
- [ ] T053 [US2] If T007 showed `oauth-personal` cannot finish over ACP, give Gemini's sign-in the Terminal fallback (**Open Terminal** / **Copy**) with the app's own shim path `<root>/tools/gemini/current/bin/gemini`, in the runtime account sheet (`App/Sources/Runtimes/RuntimeAccountView.swift`)
- [ ] T054 [US2] Failure sentences (FR-018): a Gemini that exits before `initialize` with an unknown-argument error says "Gemini <version> did not start in a mode the app can talk to."; a quota failure (shape from T006) says "Gemini's quota ran out: …"; tests with `FakeACPAgent` in `Tests/Integration/StartResilienceTests.swift`

---

## Phase 9b: The Gemini key on the Mac too (D3 revised, D7) — added after the trial

- [X] T059 [US1] Start Gemini with `--skip-trust` (`RuntimeCatalog.gemini.arguments`), and in the check scripts and launch contract (research R13)
- [X] T060 [US2] `CredentialKind.geminiAPIKey` recognises `AIza` and `AQ.` prefixes (Alex's real key is `AQ.`, 53 characters); tests in `Tests/Unit/CredentialKindTests.swift` with made-up keys of both shapes
- [X] T061 [US2] The Mac daemon accepts a lent Gemini key from a Mac window (today `lendCredential` refuses on the Mac with `notAServer`): kept in memory for the daemon's life, not per connection, used only in the environment of Gemini processes on this Mac (`GEMINI_API_KEY` set, `GOOGLE_API_KEY` removed), never written; a key already in the person's environment is used when none is lent. In `Daemon-side/Daemon/DaemonCore+Credentials.swift` and `App/Sources/Hosts/Lending.swift` (the window lends at connect and when the key changes); tests in `Tests/Integration/LendTests.swift`
- [X] T062 [US2] (done: the refusal says "Add one in Settings ▸ Agents", where Gemini's key row now sits under its install row; the sheet's Google choice is left as Gemini offers it) A Gemini start with no key anywhere answers "Gemini needs an API key. Add one in Settings ▸ Runtime credentials." with a button to Settings, instead of the sheet's Google choice; the sheet shows Gemini's own refusal of `oauth-personal` as it words it

## Phase 10: Polish & cross-cutting

- [ ] T055 [P] Everywhere a runtime is chosen: check the phone/iPad start forms (`Remote/`), workflow steps, the runtime menu and `start_agent` all list Gemini from `RuntimeCatalog.builtIn`; fix any hard-coded list; build Remote for the generic simulator only
- [X] T056 [P] Docs: `docs/reference/runtimes.md` (five runtimes, Gemini row: install from the set-up page, app's copy only, pictures, sign-in, questions end as Waiting on your answer, tokens but no cost, quota), `docs/how-to/sign-a-runtime-in.md` (Gemini's choices), `docs/how-to/add-a-linux-server.md` (Gemini key), `docs/reference/settings.md` (Settings ▸ Agents and Runtime credentials list Gemini); `scripts/docs-check.py` passes
- [ ] T057 Full `swift test` six times on this branch and on its merge base; only main's known flakes may differ (memory: the suite is flaky under load); both Xcode schemes and the Linux agentsd gate build
- [ ] T058 Run quickstart.md end to end on a scratch root and agents-bare; tick the spec checklist; leave the real app untouched until Alex says to merge

---

## Dependencies & execution order

- **Setup (T001–T004)** → **Spike (T005–T008)**: T005 is Alex's key; T006–T008 need it. T009–T019 can start during the spike, but T021's TOML priority and T031 wait for T006.
- **Foundational (T009–T019)** blocks every story.
- **US1 (T020–T029)** and **US3 (T030–T034)** ship together (the catalog entry forces the policy). T026 look gate before T027.
- **Phase 6 (T035–T039)** after US1; independent of servers.
- **Phase 7 (T040–T044)** after Foundational; independent of US1/US3; may already be done by 047.
- **US4 (T045–T050)** after Phase 7 and T008.
- **US2 (T051–T054)** after US1 and T007.
- **Polish (T055–T058)** last.

## Parallel opportunities

- T004 beside T002–T003.
- In Foundational: T009, T010, T011 together; T013, T017, T019 (tests in different files) once their subjects exist; T014–T016 are one file chain, sequential.
- In US1: T022 and T024 beside T023/T025.
- Phase 7 (servers generalisation) can run in parallel with US1/US3 in another worktree — a candidate for one helper agent.
- T055 and T056 together.

## Implementation strategy

1. **MVP** = Setup + Spike + Foundational + US1 + US3: Gemini on the set-up page and running agents on the Mac, with the app's tools. Stop at T029/T034 and show Alex.
2. Then Phase 6 (updates), since the first pin bump after release needs it.
3. Then Phase 7 + US4 (servers), coordinating with 047 on Phase 7.
4. Then US2's remaining gaps and polish.
