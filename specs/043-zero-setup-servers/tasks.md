---
description: "Tasks for 043 zero-setup servers"
---

# Tasks: Zero-Setup Servers

**Input**: `specs/043-zero-setup-servers/` — plan.md, spec.md, research.md (R1–R10), data-model.md,
contracts/ (ssh.md, daemon.md, ui.md), quickstart.md. Defaults D1–D5 taken as written.

**Tests**: Included. The plan names fake-ssh and daemon suites, and every story has an
Independent Test. Tests are written with the code they prove; never prove one by mutating source.

**Order**: Setup → Foundational (incl. the Phase 0 spike, which can change R2/R5/R7/R9) → look
gate → US2 (credential) → US1 (bare server) → US3 (rebuilt) → US4 (updates) → Polish. US1 and US2
are both P1 and ship together; US2 goes first because the token is what US1's walk needs.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: different files, no dependency on an unfinished task
- Paths are from the repository root. AgentsKit = `Packages/AgentsKit`.

---

## Phase 1: Setup

- [X] T001 Merge current `main` into `043-zero-setup-servers` (037 is on main as `b36226e`; the branch is ~40 behind), resolve, and confirm both schemes build with `-skipPackagePluginValidation`, sequentially
- [ ] T002 Record the baseline: six full `swift test --package-path Packages/AgentsKit` runs on this merge, listing the failures that are main's own flakes, in `specs/043-zero-setup-servers/walk/baseline.md`
- [ ] T003 [P] Build the bare container image `agents-bare` (Debian bookworm + `openssh-server curl ca-certificates`, user `agents` with Alex's public key, no Node, no Claude) from `scripts/agents-bare/Dockerfile`, run it on `127.0.0.1:2223`, add `Host agents-bare` to `~/.ssh/config`, and check `ssh agents-bare 'command -v node npx claude; ls ~/.claude'` prints nothing
- [ ] T004 [P] Write `scripts/update-claude-toolset.sh`: given a Node version and a claude-agent-acp version, fetch `SHASUMS256.txt`, write `App/Resources/toolsets/claude/manifest.json` (fields per data-model.md § Toolset: `runtimeID`, `node.version`, `node.sha256 {x86_64, aarch64}`, `package`, `packageVersion`, `entry`, `minFreeBytes`), and generate `package.json` + `package-lock.json` with `npm install --package-lock-only` so the lock carries both `linux-x64` and `linux-arm64` SDK entries
- [ ] T005 Run T004 for Node `v24.21.0` and claude-agent-acp `0.81.2`; commit the three files under `App/Resources/toolsets/claude/`, and add that folder to the app bundle in `project.yml` (not under `servers/`, which is gitignored for 037's built binaries)

---

## Phase 2: Foundational

**⚠️ No story work before this phase is done. The spike (T006–T010) can change research decisions; update research.md before building on a changed one.**

### Spike on `agents-bare` (by hand over ssh; notes in `specs/043-zero-setup-servers/walk/spike.md`)

- [ ] T006 Run contracts/ssh.md § 2 by hand on `agents-bare` with the T005 files: download Node, check its sha256, `npm ci --ignore-scripts --omit=dev`; record whether the SDK's native binary is present and runs with scripts ignored (R2)
- [ ] T007 Start `node …/claude-agent-acp/dist/index.js` on `agents-bare` with `CLAUDE_CODE_OAUTH_TOKEN` set (Alex's token, pasted by him into a one-off env, never into a file) and drive one ACP turn through the forwarded Linux `agentsd`; record time from download to first reply (SC-001 budget)
- [ ] T008 On `agents-devbox` (which has Alex's `claude login`), start with a *different* token in the env and confirm which sign-in is used (R5: env must win)
- [ ] T009 Revoke or corrupt the token and record exactly what arrives over ACP (initialize/authenticate/prompt error shape and text) for R7's matcher
- [ ] T010 From the Mac, call `GET https://api.anthropic.com/v1/models` with an API key and with the OAuth token (Bearer + beta header) and record which answer 200/401 (R9); update research.md R2/R5/R7/R9 with the findings and commit

### Shared records and plumbing

- [ ] T011 [P] Add `Toolset` (decodes manifest.json; `id` = first 16 hex of SHA-256 over manifest + lockfile bytes) in AgentsKit `Sources/AgentsKitCore/Runtimes/Toolset.swift`, with tests in `Tests/AgentsKitTests/Runtimes/ToolsetTests.swift`
- [ ] T012 [P] Add `CredentialKind` (`oauthToken` from prefix `sk-ant-oat`, `apiKey` from `sk-ant-api`, anything else refused; env var `CLAUDE_CODE_OAUTH_TOKEN` / `ANTHROPIC_API_KEY`; mask `sk-ant-oat…<last four>`) and a non-`Codable` `Secret` wrapper whose `description`/`debugDescription` is the mask, in `Sources/AgentsKitCore/Runtimes/CredentialKind.swift`, with tests in `Tests/AgentsKitTests/Runtimes/CredentialKindTests.swift`
- [ ] T013 [P] Extend `ServerFacts` with `libc` (`glibc(version)` | `musl` | `unknown`), `downloader` (`curl` | `wget` | nil), `toolsetID: String?`, `hasNpx: Bool`, `hasOwnClaudeSignIn: Bool`; `ServerHost` with `ownSignInOnly: Bool` (default false) and `knownProjects: [String]`; `HostProblem` with `noDownloader`, `noInternet(String)`, `unsupportedLibc(String)`, `toolsetChecksum`, `toolsetInstallFailed(String)`, `diskFullForTools(needed: Int64, free: Int64)` — all decoding old `hosts.json` unchanged — in `Sources/AgentsKitCore/Hosts/Host.swift`, with round-trip tests in `Tests/AgentsKitTests/Hosts/HostRecordTests.swift`
- [ ] T014 Add `credentials/offer`, `credentials/lend` method names and the `credentialWanted`, `credentialRefused`, `notAServer`, `notOffered` failure codes (next free after main's highest) with their param/result types per contracts/daemon.md in `Sources/AgentsKitCore/Daemon/DaemonAPI.swift`
- [ ] T015 [P] Give each fake-ssh server a local mirror: fixture Node tarball (a tiny `node/bin/node` shell script that execs the Mac's node) with its sha256, and a local npm registry directory (`npm pack` of a stub `claude-agent-acp` whose `dist/index.js` speaks enough ACP for 037's test runtime), wired through `AGENTS_TOOLS_MIRROR` and `npm_config_registry` in the fake server's environment, in `Tests/Fixtures/toolsets/` and `Tests/Fixtures/ssh/`
- [ ] T016 Add the five probe lines of contracts/ssh.md § 1 to `ServerInstaller.probeScript` and parse them in `parseProbe` in `Sources/AgentsKit/Hosts/ServerInstaller.swift`; extend its parser tests with glibc, musl, no downloader, a toolset id, and signed-in/none cases in `Tests/AgentsKitTests/Hosts/ServerInstallerTests.swift`

**Checkpoint**: records build on Mac and Linux gate; probe parses; spike findings are in research.md.

---

## Phase 3: Look gate (settle the UX before depth)

- [ ] T017 Build the five screens of contracts/ui.md as views over stub state, against the fake-ssh host on a scratch root: `App/Sources/Settings/CredentialRow.swift` (§ 1), the per-server toggle and Claude line in `App/Sources/Settings/ServersSettingsView.swift` (§ 2), `App/Sources/Chat/TokenAskCard.swift` (§ 3), the Install Claude step in `App/Sources/Hosts/AddServerFlow.swift` (§ 4), `App/Sources/Hosts/RebuiltServerSheet.swift` (§ 5), and gone rows in `App/Sources/Projects/ProjectListView.swift` (§ 6)
- [ ] T018 Walk them with the run-app skill (scratch root, screenshots of each into `specs/043-zero-setup-servers/walk/look/`) and ask Alex to approve the look before Phase 4; lease the screen while driving it

---

## Phase 4: User Story 2 — Give the app a credential once (P1)

**Goal**: A Claude token pasted once in Settings is checked, kept only in the Keychain, shown masked, replaceable and removable.

**Independent Test**: paste a valid token → "Works"; a revoked one → "Claude refused this token"; remove it → servers show Claude as needing a token; the token is in none of the Mac's preferences, logs or root files.

- [ ] T019 [P] [US2] `CredentialStore` (Mac only): Keychain generic password, service `agents.runtime-credential.<root-id>`, account = runtime id; `credentials.json` in the root with `kind`, `lastFour`, `addedAt`, `lastWorked?`, `lastRefused?` and never the secret; save/replace/remove/read, in `Packages/AgentsKit/Sources/AgentsKit/Credentials/CredentialStore.swift`; exclude from the Linux build in `Packages/AgentsKit/Package.swift`
- [ ] T020 [P] [US2] Tests for T019 on a throwaway Keychain service name: save then read, replace, remove leaves neither item nor record, `credentials.json` never contains the secret, in `Packages/AgentsKit/Tests/AgentsKitTests/Credentials/CredentialStoreTests.swift`
- [ ] T021 [P] [US2] `CredentialCheck` (Mac only): `GET /v1/models` with the header T010 proved for each kind, 10 s timeout; 200 → works, 401/403 → refused, else → can't check; injectable `URLSession` for tests, in `Packages/AgentsKit/Sources/AgentsKit/Credentials/CredentialCheck.swift` with tests in `Tests/AgentsKitTests/Credentials/CredentialCheckTests.swift`
- [ ] T022 [US2] Wire `CredentialRow` to T019/T021: paste → kind check → save → spinner → Works / refused (field kept) / "Can't check right now — saved…"; masked view with added/last worked; Replace and Remove, in `App/Sources/Settings/CredentialRow.swift` and `App/Sources/Settings/ServersSettingsView.swift`
- [ ] T023 [US2] Make sure no log line, `print`, crash annotation or `DaemonClient` request log can carry a `Secret` (grep for interpolation of the store's values; route through `Secret.description`) in `App/Sources/Settings/` and `Packages/AgentsKit/Sources/AgentsKit/Credentials/`
- [ ] T024 [US2] Walk US2's Independent Test on a scratch root (run-app skill); record in `specs/043-zero-setup-servers/walk/US2.md`

**Checkpoint**: Settings holds and checks a token; nothing reaches a server yet.

---

## Phase 5: User Story 1 — A bare server runs a Claude agent (P1) 🎯 MVP

**Goal**: Add a bare server with a token in Settings; Claude is installed, signs in with the lent token, and answers — nothing done on the server by hand.

**Independent Test**: quickstart § 3 steps 2–4 on `agents-bare`: first reply ≤ 5 min from Add a server, file exists on the box, leak search finds nothing.

### Install (contracts/ssh.md §§ 2–4)

- [ ] T025 [P] [US1] `ToolsetInstaller` over `SSHCommand`: refuse before download for `unsupportedLibc` (musl or glibc < 2.28), `noDownloader`, `diskFullForTools` under `minFreeBytes`; stream `package.json` + `package-lock.json` as tar on stdin to the § 2 script; swap `current` (§ 3); remove other toolsets; report progress lines, in `Packages/AgentsKit/Sources/AgentsKit/Hosts/ToolsetInstaller.swift`
- [ ] T026 [P] [US1] Map exit codes and stderr to the `HostProblem` cases of § 4, and add the § 4 sentences (server by label) in `App/Sources/Hosts/HostProblem+Words.swift`
- [ ] T027 [US1] Fake-ssh suite under 037's `.serialized FakeSSHSuites` parent: a good install writes `tools/claude/<id>/ok` and `current`; bad checksum, no downloader, full disk, failing `npm ci` and `EINTEGRITY` each leave no `tools/claude/<id>` and no `.part-*`, and raise their case; nothing outside `~/.agents-server` changes (FR-004, compare a listing of the fake `HOME` before/after), in `Packages/AgentsKit/Tests/AgentsKitTests/Hosts/ToolsetInstallTests.swift`
- [ ] T028 [US1] In `ServerConnection.connect()`, after the daemon is up: if a Claude token is in Settings (FR-002) or Claude was just chosen on this server, and the probe's `toolsetID` ≠ the app's and `hasNpx` is false (FR-005), run T025 and publish progress in the connection state, in `Packages/AgentsKit/Sources/AgentsKit/Hosts/ServerConnection.swift`; a toolset failure leaves the server connected and usable for other runtimes
- [ ] T029 [US1] Show the step and its progress/failure/Try again in the checklist and Settings line (wire T017's stubs) in `App/Sources/Hosts/AddServerFlow.swift` and `App/Sources/Settings/ServersSettingsView.swift`; `runtimeNotFound` with `data.installable: true` from the start form triggers an install then the start

### Start from the toolset (R4)

- [ ] T030 [US1] On a `--serve` daemon, `RuntimeDiscovery` finds `claude` at `~/.agents-server/tools/claude/current/` when `ok` exists and returns a launch of `node <entry>` with `current/node/bin` prepended to that process's PATH only; else 037's `npx`; else `runtimeNotFound` with `data.installable: true`, in `Packages/AgentsKit/Sources/AgentsKit/Runtimes/RuntimeDiscovery.swift` and `Sources/AgentsKit/Daemon/DaemonCore+Commands.swift`; Mac discovery unchanged
- [ ] T031 [US1] Tests: toolset preferred over npx; missing `ok` ignored; Mac daemon never looks there, in `Packages/AgentsKit/Tests/AgentsKitTests/Runtimes/RuntimeDiscoveryTests.swift`

### Lending (contracts/daemon.md, R6)

- [ ] T032 [US1] `ProcessSessionLauncher.launch` takes `extraEnvironment`; for a lent credential set exactly its variable and remove the other one from the inherited environment; never log the dictionary, in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore.swift` and the `SessionLauncher` protocol
- [ ] T033 [US1] `DaemonCore+Credentials`: per-connection `offer` and lent map; `credentials/lend` refused with `notAServer` without `--serve` and `notOffered` against the offer; before any Claude launch (start, prompt relaunch, answers that resume, `startHelper`, resume) decide lent / own sign-in / `credentialWanted {runtime, offered}` per contracts/daemon.md, starting nothing on `credentialWanted`; sessions remember `lentFrom`; connection close drops its lends, in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Credentials.swift` and `Sources/AgentsKit/Daemon/DaemonServer.swift`
- [ ] T034 [US1] `DaemonServer`'s request logging prints only the method name for `credentials/lend` in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonServer.swift`
- [ ] T035 [US1] Daemon tests with the recording launcher: lend refused on a Mac daemon; start with nothing lent → `credentialWanted`, no session made; lend then retry with the same `sendID` → exactly one session with the variable; second connection's lend never used for the first's start; close forgets; own-sign-in-only offer → launch with no variable, lend refused; the secret appears in no file under the test root, in `Packages/AgentsKit/Tests/AgentsKitTests/Credentials/LendTests.swift`
- [ ] T036 [US1] Window side: send `credentials/offer {runtimes, ownSignInOnly}` on every server connect; on `credentialWanted` with `offered: true` lend from `CredentialStore` and repeat with the same `sendID`; with `offered: false` show `TokenAskCard` in the start form or prompt bar, save, lend, repeat; never lend to the Mac host, in `App/Sources/Hosts/HostSet.swift`, `App/Sources/AppModel.swift` and `App/Sources/Chat/TokenAskCard.swift`
- [ ] T037 [US1] Set `lastWorked` on the credential when a server session started with it completes its first turn (from the agent's first ended turn event on that host) in `App/Sources/Hosts/HostSet.swift`

### Refused token (FR-016, R7)

- [ ] T038 [US1] Classify, for sessions with `lentFrom`, the error shapes T009 recorded as `credentialRefused {runtime}` and end the agent Stopped with that reason, in `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonCore+Credentials.swift`; test with a scripted runtime that fails that way in `LendTests.swift`
- [ ] T039 [US1] Show "Claude refused the token in Settings. Replace it" with a button opening Settings ▸ Servers, and set `lastRefused`, in the chat's ending view and `App/Sources/Hosts/HostSet.swift`

### Proof

- [ ] T040 [US1] Linux build gate for both architectures (`scripts/build-linux-agentsd.sh`), and rebuild the bundled Linux binaries
- [ ] T041 [US1] Walk quickstart § 3 steps 1–4 on `agents-bare` with the test-servers skill on a scratch root: time from Add a server to first reply (SC-001 ≤ 5 min), the file on the box, and a re-connect's added time (SC-002 ≤ 5 s); notes in `specs/043-zero-setup-servers/walk/US1.md`
- [ ] T042 [US1] Walk quickstart step 6 (refused token) and step 7 (own sign-in only on `agents-devbox`, confirming no `credentials/lend` in its daemon log); add to `walk/US1.md`

**Checkpoint**: MVP — a bare server runs Claude with a token from Settings.

---

## Phase 6: User Story 3 — A server that comes back empty (P2)

**Goal**: A rebuilt server at the same name is trusted again with one confirmation and set up from scratch; its old projects show as gone.

**Independent Test**: quickstart § 3 step 5 — `docker rm -f` + run `agents-bare` again, confirm once, a new Claude agent answers, old projects say "Gone from agents-bare".

- [ ] T043 [P] [US3] `HostKeyCheck.forget(resolved:)`: `ssh-keygen -R <name>` and, if the resolved port ≠ 22, `-R '[host]:port'`, against the person's `known_hosts` (or `FAKE_SSH_KNOWN_HOSTS`), in `Packages/AgentsKit/Sources/AgentsKit/Hosts/HostKeyCheck.swift`, with a fake-ssh test that a changed key is refused, forgotten, fetched and trusted in `Tests/AgentsKitTests/Hosts/RebuiltServerTests.swift`
- [ ] T044 [US3] On `hostKeyChanged`, show `RebuiltServerSheet` with the saved `trustedFingerprint` and the new one from `HostKeyCheck.fetch`; Cancel is default; "This server was rebuilt" runs forget → trust → normal connect (which re-installs daemon and toolset), in `App/Sources/Hosts/HostSet.swift` and `App/Sources/Hosts/RebuiltServerSheet.swift`
- [ ] T045 [US3] Record each server's project paths into `ServerHost.knownProjects` in `hosts.json` whenever its project list arrives, in `App/Sources/Hosts/HostSet.swift` and `Packages/AgentsKit/Sources/AgentsKit/Hosts/HostStore.swift`
- [ ] T046 [US3] After a connect, show recorded paths the server does not list and whose folder is missing (via `files/stat`) as gone rows with Remove (drops the path and its agents' records); never the offline strip for them, in `App/Sources/Projects/ProjectListView.swift` and `App/Sources/AppModel.swift`
- [ ] T047 [US3] Fake-ssh test: wiping the fake server's `~/.agents-server` with the key unchanged re-installs daemon and toolset on connect without asking (FR-018) in `RebuiltServerTests.swift`
- [ ] T048 [US3] Walk quickstart step 5 on `agents-bare` (SC-004); notes in `specs/043-zero-setup-servers/walk/US3.md`

---

## Phase 7: User Story 4 — Keep the tools current (P3)

**Goal**: A newer toolset named by the app replaces the server's when no Claude agent there is mid-turn.

**Independent Test**: quickstart § 3 step 8 — bump the pin, connect with an agent mid-turn: waits; after the turn: swapped, next agent uses it.

- [ ] T049 [US4] Add `tools.claude {toolset, busy}` to `daemon/status` (busy = Claude agents mid-turn) in `Packages/AgentsKit/Sources/AgentsKit/Daemon/` and `Sources/AgentsKitCore/Daemon/DaemonAPI.swift`
- [ ] T050 [US4] In `ServerConnection`, when the probe's `toolsetID` ≠ the app's and a toolset exists: install beside, then swap `current` only when `busy == 0`, showing `updateWaiting` meanwhile; remove old toolsets after the next good Claude start, in `Packages/AgentsKit/Sources/AgentsKit/Hosts/ServerConnection.swift`
- [ ] T051 [US4] Fake-ssh test: a busy Claude agent holds the swap; it happens after the turn ends; agents started after use the new `current`, in `ToolsetInstallTests.swift`
- [ ] T052 [US4] Walk quickstart step 8; notes in `specs/043-zero-setup-servers/walk/US4.md`

---

## Phase 8: Polish & cross-cutting

- [ ] T053 [P] `scripts/leak-check.sh <token>`: grep the scratch root, `~/Library/Preferences/*Agents*`, the app's logs, `/usr/bin/log show --info` for the last day, and each server's home over ssh for the full token; exit non-zero on any hit
- [ ] T054 Run T053 after the walks (SC-003) and quickstart step 9 (purge leaves no `~/.agents-server`, and the person's own Node untouched on `agents-devbox`) (FR-008); notes in `specs/043-zero-setup-servers/walk/README.md`
- [ ] T055 [P] Update the test-servers skill (`.claude/skills/test-servers/`) with `agents-bare`, the token step and the rebuilt walk
- [ ] T056 [P] Update 037's `specs/037-cloud-agents/spec.md` Assumptions to point at 043 for runtimes on servers (D4)
- [ ] T057 Six full suite runs compared with T002's baseline; both schemes build; Linux gate passes
- [ ] T058 Record what is left for Alex (token paste for walks, any look notes) and SC results in `specs/043-zero-setup-servers/walk/README.md`

---

## Dependencies

- Phase 1 → Phase 2 → Phase 3 (look gate, Alex approves) → US2 → US1 → US3 → US4 → Polish.
- US2 before US1: US1's lending reads `CredentialStore` (T019) and the walk needs a saved token.
- US3 needs US1's install on connect (T028) to set a rebuilt server up again; its key work (T043–T045) can start once Phase 2 is done.
- US4 needs T025/T028.
- The spike (T006–T010) gates T021 (check header), T025 (`--ignore-scripts`), T032 (env precedence) and T038 (refusal shape).

## Parallel opportunities

- Phase 1: T003 ∥ T004.
- Phase 2: T011 ∥ T012 ∥ T013 ∥ T015 (different files), after the spike or alongside it.
- US2: T019 ∥ T021, then T020 with T019.
- US1: T025 ∥ T026 ∥ T030 ∥ T032 (installer, words, discovery, launcher are separate files); T033 after T032.
- US3: T043 ∥ T045.

## Implementation strategy

1. **MVP** = Phases 1–5: a token in Settings and a bare server that runs Claude with it. Stop and walk (T041, T042) before going on.
2. US3 next: it is the reason for the feature on ephemeral servers.
3. US4 last: only long-lived servers need it.
4. Merge only when Alex says it is this lane's turn.
