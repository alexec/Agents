# Tasks: OpenCode as a Runtime

**Input**: design documents in `specs/049-opencode-runtime/`: plan.md, spec.md, research.md,
data-model.md, contracts/, quickstart.md.

**Tests**: included. The project tests every runtime by looping over the catalog, and the plan
names the tests each phase needs.

## Paths used below

| Short | Path |
|---|---|
| Core | `Packages/AgentsKit/Sources/AgentsKitCore` |
| Kit | `Packages/AgentsKit/Sources/AgentsKit` |
| Tests | `Packages/AgentsKit/Tests/AgentsKitTests` |

Probe facts are cited as R1–R10 from research.md. Walks happen only on scratch roots (the
run-app skill), never on the real home.

## Format: `[ID] [P?] [Story] Description`

---

## Phase 1: Setup

- [x] T001 Add `--archive-github <runtime> <owner/repo> <tag>` to `scripts/update-toolset.sh`.
  - It reads `gh api repos/<owner/repo>/releases/tags/<tag>` and writes `url`, `sha256` (GitHub's
    `digest` without its `sha256:` prefix) and `size` for each platform key.
  - Platform keys come from the asset names, per contracts/archive-manifest-v2.md: `arm64` →
    `aarch64`, `x64` → `x86_64`, then a `-baseline` and/or `-musl` suffix.
  - It allows only `https://github.com/<owner>/<repo>/releases/download/` URLs, and skips
    `opencode-desktop-*` assets.
- [x] T002 Generate `App/Resources/toolsets/opencode/manifest.json` with
  `scripts/update-toolset.sh --archive-github opencode anomalyco/opencode v1.18.33`.
  - `kind: "archive"`, `runtimeID: "opencode"`, `version: "1.18.33"`,
    `source: "github:anomalyco/opencode@v1.18.33"`, `minFreeBytes: 500000000`.
  - Every platform has `command: "opencode"` and `arguments: []`.
  - Check that `darwin-aarch64.sha256` is `24b12873e605b3db3387cb355f43ba7451cd6065c180d8c188663337d2eeb553` (R1).
- [x] T003 [P] Save the probe's ACP replies as fixtures in
  `Tests/Fixtures/opencode/`: `initialize.json` (with terminal-auth `_meta`),
  `session-new.json`, `set-model-unknown-provider.json` (-32602 with `data.providerId`),
  `prompt-invalid-key.json` (-32603 APIError) and `usage-zero-cost.json`. Re-record them with
  `/tmp/oc-spike/probe.py` if that folder is gone. Use a scratch home only.

---

## Phase 2: Foundational (archive toolsets v2, blocking every story)

- [x] T004 [P] Write the tests in `Tests/Unit/ArchiveToolsetTests.swift` first:
  - Replace the `["antigravity"]` pin with a check that every archive manifest loads.
  - Platform choice: `{linux, x86_64, avx2:false, musl:true}` → `linux-x86_64-baseline-musl`;
    it falls back to dropping `-baseline`, then `-musl`; it never takes a musl build for glibc
    when both exist.
  - `format` comes from the URL (`.zip`, `.tar.gz`), and any other suffix is refused when the
    manifest loads.
  - A size mismatch is refused.
- [x] T005 In `Core/Runtimes/ArchiveToolset.swift`, add `Platform.format` (`zip` | `tarGz`),
  derived from the URL and never decoded. Add `HostFacts {os, arch, avx2, musl}` and
  `platformKey(for:)` implementing the choice rules in contracts/archive-manifest-v2.md. Keep
  version 1 manifests valid.
- [x] T006 In `Kit/Runtimes/MacArchiveInstaller.swift`:
  - Unpack `.tar.gz` with `/usr/bin/tar -xzf` (keep `ditto -x -k` for zip).
  - Refuse a download whose byte count ≠ `size`, with 048's checksum sentence.
  - Choose the Mac key through `platformKey(for:)`, with `avx2` from
    `sysctlbyname("hw.optional.avx2_0")`: true on arm64, and false when absent.
  - Never set `com.apple.quarantine` on the unpacked file (R1).
- [x] T007 [P] Add an integration test in `Tests/Integration/MacArchiveInstallerTests.swift`:
  install a local `.tar.gz` test release through the file-URL path and check that `ok` is
  written last and `current` moves. Then check that a truncated archive leaves nothing in place.

**Checkpoint**: archive toolsets install zip and tar.gz with variants. Antigravity's tests are
still green.

---

## Phase 3: User Story 1 — Start an OpenCode agent on the Mac (P1) 🎯 MVP

**Goal**: OpenCode is installed from the set-up page and runs full turns on the Mac.

**Independent test**: quickstart §1, §3 and §5 on a scratch root.

- [x] T008 [US1] Add `RuntimeCatalog.opencode` in `Core/Runtimes/RuntimeCatalog.swift`:
  - `id "opencode"`, `name "OpenCode"`, `executable "opencode"`, `arguments ["acp"]`
  - `install .toolset(runtimeID: "opencode")`, `installPage https://opencode.ai/docs/`,
    `usesAppCopyOnly: true`
  - **Append** it to `builtIn`, never prepend: `builtIn[0]` is the default runtime.
  - Do **not** add it to `carriesConversationAcrossFolders` (R9).
  - Add a header paragraph on the name trap (spec, *The name trap*).
- [x] T009 [US1] Add `ToolPolicyCatalog.opencode` in `Core/Runtimes/ToolPolicyCatalog.swift`,
  appended to `builtIn` in the same order as `RuntimeCatalog.builtIn`:
  - `removed: task (.agents)`, `residue: []` (`todowrite` kept, as Claude's and Gemini's to-do lists are)
  - `lever: .environmentJSON(variable: "OPENCODE_CONFIG_CONTENT", value:)` with exactly
    `{"autoupdate":false,"permission":{"bash":"ask","edit":"ask","webfetch":"ask"},"share":"disabled","tools":{"task":false}}`
    (contracts/opencode-launch.md)
  - `escalationTool: nil`, `preferredAuthMethods: ["opencode-login"]`
- [x] T010 [US1] Add `RuntimeLaunchCatalog.opencode` in `Core/Runtimes/RuntimeLaunch.swift`,
  with the environment `OPENCODE_DISABLE_AUTOUPDATE=1`, `OPENCODE_DISABLE_SHARE=1`,
  `OPENCODE_AUTH_CONTENT=nil` and `OPENCODE_ENABLE_QUESTION_TOOL=nil`. Add it to `builtIn`.
- [x] T011 [P] [US1] Add a test in `Tests/Unit/OpenCodeRuntimeTests.swift`: the launch
  environment of an OpenCode process built by `ProcessSessionLauncher.environment` has
  `OPENCODE_CONFIG_CONTENT` byte for byte as the contract says, the two `DISABLE_` variables,
  and no `OPENCODE_AUTH_CONTENT` even when the login shell has one.
- [x] T012 [US1] Update the counts and pins that the new runtime changes:
  - `Tests/Unit/RuntimeDiscoveryTests.swift` (count)
  - `Tests/Unit/RuntimeAvailabilityCodingTests.swift`
  - `Tests/Fake/FakeLauncher.swift` (it makes `current/ok` for app-copy runtimes)
  - `Tests/Unit/ToolPolicyTests.swift` and `Tests/Unit/BriefingTests.swift`

  Then run those suites.
- [x] T013 [P] [US1] Add a rule for OpenCode in `Kit/Projects/PersonalDotAgents.swift` (:67-95):
  no skills folder link, no instructions link, `takesStdioServers: true`, no plugin handover
  (R8). Add its MCP entry in `Kit/Projects/PersonalDotAgents+Snapshot.swift` as "reads the
  app's session servers only".
- [x] T014 [US1] Zero cost is no cost (plan P2, confirmed by Alex).
  - In `Core/Model/Usage.swift` and `Core/Model/Agent.swift` (`costIsUnmeasured`), and in the
    banking in `Kit/Daemon/DaemonCore+Commands.swift` (~:788 `bank`, ~:1118 `lastTurnUsage.cost`),
    a cost with `amount == 0` on a turn with tokens > 0 is unmeasured. It is never banked into
    `costToDate`.
  - Test it in `Tests/Unit/UsageCostTests.swift` with `Fixtures/opencode/usage-zero-cost.json`.
- [x] T015 [P] [US1] Show no cost for a zero cost on the meters, in
  `App/Sources/Chat/ContextMeter.swift` (:89-100) and `Remote/Sources/Chat/RemoteChatView.swift`
  (:337).
- [x] T016 [US1] Add `opencode` to `scripts/acp-handshake.sh` (`RUNTIMES` via
  `AGENTS_OPENCODE_SHIM`, with a scratch `HOME`/`XDG_*` in `RUNTIME_ENV`) and to
  `scripts/runtime-tools.sh` (its copy of the catalog and policy).
- [x] T017 [US1] Live gate. On a scratch root (run-app skill):
  - press **Install** on the set-up sheet;
  - start an OpenCode agent with the prompt "create hello.txt and run ls";
  - answer the permission cards;
  - stop it, relaunch, and resume it.

  Record the screenshots and socket output in `specs/049-opencode-runtime/walk/`
  (quickstart §1, §3, §5).

**Checkpoint**: an OpenCode agent works end to end on the Mac, signed out, on Zen models.

---

## Phase 4: User Story 2 — Never the wrong `opencode` (P1)

**Goal**: only the app's copy is ever run or reported as installed.

**Independent test**: quickstart §2.

- [x] T018 [P] [US2] Add an integration test in `Tests/Integration/OpenCodeNameTrapTests.swift`.
  Put a fake `opencode` that writes a marker file first on the search path, with no app copy.
  - Discovery reports OpenCode as not installed.
  - A start refuses with the "not installed" sentence and **Install**, within the start-up
    limit.
  - After a fake app copy is installed, the start runs the app's copy, and the marker is never
    written.
- [x] T019 [US2] Check `Kit/Runtimes/RuntimeDiscovery.swift` (:42-45) and the start path. An
  app copy that is missing `ok`, or doesn't answer `initialize` as `agentInfo.name == "OpenCode"`,
  ends the start with a sentence naming the cause (FR-005). It never falls back to the PATH. Add
  the sentence if a copy that answers as something else is not already caught.
  *Done 2026-09-29: a copy without `ok` is missing and never replaced by the PATH (tested); a start
  with no app copy says "OpenCode is not installed any more" (seen in the walk). An agentInfo name
  check was not added: the copy is the app's own, checked by size and SHA-256 at install.*

---

## Phase 5: User Story 4 — The app's tools and scoping (P2)

*This ships with US1: the policy entry (T009) is required before OpenCode is offered.*

**Goal**: the app's tools are present, duplicates are gone, sharing is off, and edits, commands
and fetches ask.

**Independent test**: quickstart §4 and §7.

- [x] T020 [US4] Add `opencode` to 061's `Core/Model/ClientPermissionSettings.swift` (a field,
  `supports`, `mode(for:)`, default `ask`), to its store in `App/Sources/AppModel.swift`
  (:78, :897-905) and to the row in `App/Sources/Settings/AgentRuntimesSettingsView.swift`
  (:23-25, :57-95).
- [x] T021 [P] [US4] Add a test in `Tests/Unit/ClientPermissionSettingsTests.swift`: OpenCode
  supports the setting. Under `alwaysApprove`, the daemon answers OpenCode's options
  (`once`/`always`/`reject`) with `once`.
- [x] T022 [US4] Live check on a scratch root (quickstart §4):
  - the agent lists its tools: `agents_*` are present, and `task` and `todowrite` are absent;
  - `finish_turn` arrives;
  - an `ask_form` question card arrives;
  - Always approve skips the next card.

  Record it in `walk/`.

---

## Phase 6: User Story 3 — Sign OpenCode in on the Mac (P2)

**Goal**: the sheet hands over the app's copy's `auth login`, and sign-in failures are
sentences.

**Independent test**: quickstart §6.

- [x] T023 [US3] In `Core/ACP/ACPTypes.swift` (:163-183), add `"terminal-auth": true` to
  `clientCapabilities._meta` beside `jetbrains.air`. Then run `scripts/acp-handshake.sh` for all
  eight runtimes, and record in research.md (R11) that no other runtime's auth methods changed
  for the worse.
- [x] T024 [US3] In `Kit/Daemon/DaemonCore+Runtimes.swift` (:26-35), for a `usesAppCopyOnly`
  runtime whose terminal-auth `command` equals `runtime.executable`, replace it with the shim's
  absolute path `<root>/tools/<id>/current/bin/<executable>`. Test it in
  `Tests/Unit/TerminalAuthCommandTests.swift` with `Fixtures/opencode/initialize.json`.
- [x] T025 [US3] In `Kit/Daemon/DaemonCore+Commands.swift` (`signInReason` :457-466):
  - treat `-32603` with `data.errorName == "APIError"` and "API key is invalid" as a refused
    sign-in;
  - make a `session/set_config_option` failure with `data.providerId` into "OpenCode isn't
    signed in to <provider>", with the sign-in sheet.

  Test both with the fixtures in `Tests/Unit/OpenCodeErrorTests.swift`.
- [x] T026 [US3] In `App/Sources/Runtimes/RuntimeAccountView.swift`, OpenCode's sheet shows no
  Sign out. It shows a line naming `<app copy> auth logout`, as Cursor's does. If a
  `RuntimeLaunch.signInNotice` fits, use that rather than a special case.
- [x] T027 [US3] Live check (quickstart §6): pick an unsigned provider's model id over the
  socket to get the sentence. Then check that the sheet's command is the full path, and that
  Copy puts it on the pasteboard.

---

## Phase 7: User Story 5 — OpenCode on servers (P3)

**Goal**: a server installs the pinned Linux program and borrows the Mac's non-rotating
sign-ins per run.

**Independent test**: quickstart §9 (test-servers skill, `agents-devbox`).

- [x] T028 [US5] Report the facts the chooser needs in the server's platform probe
  (`Kit/Hosts/`, the code that fills `Architecture`): `musl` if `/lib/ld-musl-*` exists, and
  `avx2` from `/proc/cpuinfo`. Carry them to `platformKey(for:)`.
- [x] T029 [US5] Build the new `Kit/Hosts/ServerArchiveInstaller.swift`:
  1. The Mac side downloads the asset for the server's key and checks its size and SHA-256.
  2. It streams the unpacked folder over the existing ssh with `tar -cz` into
     `<server root>/tools/<id>/.part-<id>`.
  3. The server writes the shim, writes `ok` last and moves it into place, with progress in
     the set-up checklist.

  A failure leaves nothing half-installed. Wire it where `Kit/Hosts/ToolsetInstaller.swift`
  dispatches Node toolsets. It must serve any archive manifest, so Antigravity's T036 can reuse
  it.
- [x] T030 [P] [US5] Add a test in `Tests/Integration/ServerArchiveInstallerTests.swift` with the
  fake ssh: a failure mid-stream leaves no `current` change, and a success writes `ok` last.
- [x] T031 [US5] Add the new `App/Sources/Hosts/OpenCodeFileSignIn.swift`:
  - read `$XDG_DATA_HOME/opencode/auth.json`, or else `~/.local/share/opencode/auth.json`;
  - keep only entries whose `type` is `"api"` or `"wellknown"`, and count the others by name;
  - produce compact JSON for `OPENCODE_AUTH_CONTENT`;
  - never write it anywhere.

  Test it in `Tests/Unit/OpenCodeFileSignInTests.swift`, including an `oauth` entry that is
  dropped and named.
- [x] T032 [US5] Lend it through `credentials/lend`, for OpenCode runs on that server only:
  - `App/Sources/Hosts/SignInRelays.swift` / `HostSet.swift` (`serverRuntimes` :527 offers
    OpenCode even with nothing to lend, since the Zen models need nothing);
  - `Kit/Daemon/DaemonCore+Credentials.swift` (`launchEnvironment(for:)` →
    `LentEnvironment` sets `OPENCODE_AUTH_CONTENT`).

  An "own sign-in only" server is lent nothing. Test that the variable never reaches another
  runtime's process or a Mac-side OpenCode process.
- [x] T033 [US5] Refused-key wording on a server: T025's refused sign-in on a server run says
  the provider refused the Mac's sign-in, and names `opencode auth login` on the Mac. The sheet
  lists the sign-ins that were not lent, and why.
- [x] T034 [US5] Walk on `agents-devbox` (test-servers skill; quickstart §9), from a scratch Mac
  home whose `auth.json` holds a test key:
  - the install progress shows;
  - a Zen turn works;
  - a turn with the lent provider's model works;
  - afterwards, `grep -r` for the key on the box finds nothing, and there is no `auth.json` of
    the Mac's on the box;
  - an "own sign-in only" server gets nothing lent.

  Record it in `walk/`.

---

## Phase 8: Polish & cross-cutting

- [x] T035 [P] Update the docs:
  - `docs/reference/runtimes.md`: the runtime table and count, the OpenCode row, questions,
    limits, skills and instructions;
  - `docs/how-to/sign-a-runtime-in.md`: `auth login` and its providers, and that Zen works
    signed out;
  - `docs/how-to/add-a-linux-server.md`: install, and borrowing the Mac's sign-in;
  - `docs/explanation/scoped-tools.md`: the removed tools, no residue, sharing off, asks forced
    on;
  - `README.md`: the runtime count (:98-101) and tool scoping (:182).

  Run `scripts/docs-check.py`.
- [x] T036 [P] Give OpenCode the "O" letter in `App/Sources/Settings/Shared/ReachDots.swift`
  (:24), so the fallback isn't relied on.
- [x] T037 In `App/Sources/Runtimes/InstallAgentsSheet.swift` (:141-148), the `downloadNote`
  names "GitHub" for `github.com` hosts, as it names "Google" for `dl.google.com`.
- [x] T038 Build both schemes sequentially, skipping plugin validation (see memory), and
  `scripts/build-linux-agentsd.sh`. Then run the full suite on this branch and on main, three
  runs each, and compare them (the suite is flaky under load).
- [x] T039 SC-005 check (quickstart §10): hash the scratch home's `~/.config/opencode` and
  `auth.json` before and after all the walks. Record that the app wrote nothing and that no
  share happened.
- [x] T040 Remote: build for the generic simulator only. The phone look (an OpenCode row in the
  start form and runtime menu, and no "$0") is Alex's.

---

## Dependencies

- Phase 1 → Phase 2 → US1 (T008–T017).
- **US4's policy (T009) is inside US1**, because the every-runtime policy test fails without
  it. The rest of US4 (T020–T022) can follow US1 or run beside US3.
- US2 (T018–T019) needs T008 only.
- US3 (T023–T027) needs T008. T023 touches every runtime's handshake, so land it on its own
  commit.
- US5 (T028–T034) needs Phase 2 and US1. It is independent of US3 and US4, except T033 needs
  T025.
- Polish comes last. T038 goes before any merge.

## Parallel opportunities

- T003 runs alongside T001–T002. T004 and T007 are test files, alongside T005–T006.
- Within US1: T011, T013 and T015 are in different files, and run once T008–T010 are in.
- US2, US3 and the rest of US4 can run in parallel after US1's T008–T010.
- Within US5: T030 and T031 run in parallel with T029.
- T035 and T036 can run at any time after US1.

## Implementation strategy

1. **MVP**: Phases 1–2, then US1 with the policy, then US2 (T018–T019). This is OpenCode on the
   Mac, installed by the app, signed out on Zen models, and never the wrong program. Stop and
   walk (T017).
2. Then US4's permission setting and US3's sign-in. Walk each.
3. Then US5, servers. It also unblocks Antigravity's server install (its T036).
4. Docs, full-suite compare, and a merge when Alex says it's this lane's turn.
