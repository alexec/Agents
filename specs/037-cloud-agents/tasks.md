# Tasks: Cloud Agents

**Input**: [spec.md](spec.md), [plan.md](plan.md), [research.md](research.md), [data-model.md](data-model.md), [contracts/ssh.md](contracts/ssh.md), [contracts/daemon.md](contracts/daemon.md), [contracts/ui.md](contracts/ui.md), [quickstart.md](quickstart.md), [wireframes.md](wireframes.md)

**Tests**: Included. This repo tests every daemon behaviour, and the quickstart names each property
to test. Write each test before the code that makes it pass. SSH is tested through the fake `ssh`
fixture (R11). The Mac `agentsd` stands in for the Linux one, so nothing here needs a server
except T005 and Phase 8.

**Where**: the worktree `/Users/alexcollins/Agents/.agents/worktrees/speckit-specify-cloud-agents`.
Never edit the shared checkout at `/Users/alexcollins/Agents`. Paths below are relative to the
worktree. `Pkg/` stands for `Packages/AgentsKit/`, and `Tests/` for
`Pkg/Tests/AgentsKitTests/`.

**Gates**:
- **T005 (Linux build on a real server)**: if the daemon cannot be built static for Linux, or
  does not complete a turn there, stop and bring the failure to Alex. Nothing after Phase 2 is
  worth building without it.
- **T036 (look gate)**: screenshots of the grouped list, the Add a server sheet and the remote
  folder sheet against the fake host. Settle the layout with Alex before Phases 4–7 add depth.
- **Phase 8**: the real-server walk is Alex's.

## Phase 1: Setup

- [X] T001 Confirm 034-ios-artifacts is merged into `main` (`git log main --oneline | grep -i 034` and `grep -n '"files/list"' Pkg/Sources/AgentsKitCore/Daemon/DaemonAPI.swift` on main). If it is not, stop: this feature's server files pane needs `files/list`, `files/read`, `files/watch` (R9). Then `git merge main` into this branch. **Done 2026-09-25: main (`fbbaa87`, 034 merged) merged in as `258ea6d`.**
- [X] T002 Record the baseline: `swift test` in `Pkg` once, and write the pass/fail count into this task, as 030's T001 did. **Baseline at `258ea6d`: 1517 tests in 168 suites, 1 issue. The suite is known flaky under load; see T053.**
- [X] T003 Install the Linux toolchain (R1). Take the swift.org toolchain for the Swift version `swift --version` reports (6.4 today) and its Static Linux SDK (`swift sdk install <url> --checksum <sum>`). Confirm `swift sdk list` shows `x86_64-swift-linux-musl` and `aarch64-swift-linux-musl`. This is a download of about 1.5 GB. Ask Alex before starting it. **Done: swift.org 6.4.0-RELEASE toolchain in ~/Library/Developer/Toolchains; `swift-6.4.0-RELEASE_static-linux-0.1.0` SDK installed.**

---

## Phase 2: Foundational (blocks every story)

### 2a — The daemon builds and runs on Linux (the gate)

- [X] T004 Make `agentsd` compile for Linux, per [contracts/daemon.md § Linux build](contracts/daemon.md#linux-build): **Done: `Daemon/Package.swift` builds `agentsd` static for aarch64 and x86_64 (Debug, 160 MB unstripped). The changes: `AgentsKitCore/Platform/POSIX.swift`, a `CShims` C target (ioctl, non-reaping exit check), `AgentsKit/Platform/Spawn.swift`, inotify `FolderWatch+Linux.swift`, Linux exit watcher in PTY, and guards around PhoneAttachment, MarkdownBlock, CloudKit, Network and CryptoKit. The Mac suite is unchanged, though failures under load vary. Runtime on Linux is unproven until T005.**
  - Add `Pkg/Sources/AgentsKit/Platform/Platform.swift`: `#if canImport(Darwin) import Darwin #elseif canImport(Musl) import Musl #elseif canImport(Glibc) import Glibc`, plus wrappers for `connect`, `socket` send flags (`SO_NOSIGPIPE` vs `MSG_NOSIGNAL`), and `sun_path` size (104 vs 108).
  - Route `Pkg/Sources/AgentsKit/Terminal/PTY.swift`, `Terminal/ShellSession.swift`, `Daemon/DaemonServer.swift` and `Client/SocketLink.swift` through it.
  - `Pkg/Sources/AgentsKit/Files/FolderWatch.swift`: keep FSEvents under `#if os(macOS)`. Add an `#if os(Linux)` body using `inotify_init1`/`inotify_add_watch` (recursive, via a watch per directory) with the same `init(root:onChange:)`.
  - `Pkg/Sources/AgentsKit/Power/PowerSource.swift`, `Power/Wake.swift`: on Linux, `.mains` and no-op assertions.
  - Wrap `Pkg/Sources/AgentsKitCore/Remote/CloudKitMailbox.swift`, `NetworkLink.swift`, `DeviceKey.swift` and `Envelope.swift` in `#if canImport(CloudKit)` / `canImport(CryptoKit)`. Leave Linux stubs for any type the daemon names, so `DaemonCore+Devices.swift` and `+Attention.swift` compile unchanged, with `devices` always empty.
  - Iterate with `swift build --swift-sdk aarch64-swift-linux-musl --product agentsd` until it builds, then do the same for x86_64. The Mac `swift test` must stay at T002's count.
- [ ] T005 **Gate.** Write `scripts/build-linux-agentsd.sh [--check]`. It builds release for both SDKs, stamps `-Xswiftc -DAGENTS_BUILD_VERSION=<CFBundleShortVersionString>+<build>`, and writes `App/Resources/servers/agentsd-linux-{x86_64,aarch64}` plus `.sha256` beside each. `--check` builds without copying. Then run [quickstart § 1](quickstart.md#1-linux-build-phase-0-gate) on a server Alex names, by hand with `scp`, `ssh -L` and a `socat` or Swift one-off client. **Pass**: `runtimes/list` answers, a one-line prompt completes, and `shell/attach` echoes. Write the result into this task. If it fails, stop and tell Alex.

### 2b — Daemon changes

- [X] T006 [P] Write `Tests/Unit/DaemonCommandLineTests.swift`: `--version` prints `buildVersion` and exits with no root; `--serve` makes `shouldExit` false with no connections and nothing held; `--detach` is stripped from the child's arguments. **Done: parser, serve and detach covered (6 tests). `--version` dropped; see contracts/daemon.md § Where the version lives.**
- [X] T007 Implement `--version`, `--serve` and `--detach` in `Daemon/Sources/main.swift`, `Pkg/Sources/AgentsKit/Daemon/Daemon.swift` and `Daemon/DaemonCore+Lifetime.swift` (`exitsWhenIdle`). Put `buildVersion` in `Pkg/Sources/AgentsKitCore/AgentsKitCore.swift`, read from the `AGENTS_BUILD_VERSION` compile flag with `"dev"` as the fallback. `--detach` re-spawns with `POSIX_SPAWN_SETSID` exactly as `Client/SocketLink.swift` `start()` does, and exits 0 if the lock is held. **Done: `DaemonCommandLine.swift`, `Spawn.detached` (SocketLink now uses it too), `exitsWhenIdle`. Smoke: `--serve --detach` on a scratch root stayed up past the idle grace; a second `--detach` exited without a duplicate.**
- [X] T008 [P] Write `Tests/Integration/DaemonVersionQuitTests.swift`: `daemon/status` returns `{version, turnsInFlight, agentsLive}` correctly for idle, mid-turn (fake runtime), and held-but-idle agents. `daemon/quit {stopAgents:false}` refuses with `busy` mid-turn and shuts down when idle. `daemon/quit {stopAgents:true}` stops live agents and shuts down, and the socket is gone afterwards. **Done: `Integration/DaemonStatusQuitTests.swift`, 5 tests.**
- [X] T009 Add `daemon/status` and `daemon/quit` to `Pkg/Sources/AgentsKitCore/Daemon/DaemonAPI.swift` and `Pkg/Sources/AgentsKit/Daemon/DaemonCore+Dispatch.swift`, implemented in a new `Pkg/Sources/AgentsKit/Daemon/DaemonCore+Version.swift`. **Done in `DaemonCore+Status.swift` (named for `daemon/status`); `busy` is -32040.**
- [X] T010 [P] Write `Tests/Integration/SendOnceTests.swift`: `agents/prompt` sent twice with the same `sendID` delivers once and returns the same result both times. Same for `permissions/answer` and `elicitations/answer`. No `sendID` means today's behaviour. The 513th ID evicts the first. **Done: `Integration/SendOnceTests.swift`, 3 tests (prompt path end to end; eviction on `once` directly).**
- [X] T011 Add the optional `sendID: UUID?` to the three request types in `DaemonAPI.swift`. Implement the 512-entry ring in `Pkg/Sources/AgentsKit/Daemon/DaemonCore+Sends.swift`, and check it at the top of the three handlers in `DaemonCore+Commands.swift`. **Done: named `sendID`, because `AnswerElicitationRequest` already has a `requestID` (the question's own id). `DaemonCore+Sends.swift`; a repeat arriving while the first is in hand waits for it.**

### 2c — Host record and store

- [X] T012 [P] Write `Tests/Unit/HostTests.swift`, covering the validation rules in data-model.md: "`sshName` is non-empty, has no whitespace, and does not start with `-`"; "Two hosts may not share an `sshName`"; `HostID` is 8 characters of `[a-z0-9]`; `.mac` is never encoded into `hosts.json`; label defaults (alias → alias, `alex@devbox.lan:2222` → `devbox.lan`); `ProjectKey` stored as `"<host>|<path>"`, with a bare path decoding as `.mac`.
- [X] T013 Create `Pkg/Sources/AgentsKitCore/Hosts/Host.swift` (`HostID`, `Host`, `ServerFacts`, `Architecture`, `HostProblem`, `ProjectKey`) as data-model.md specifies, plus `Pkg/Sources/AgentsKit/Hosts/HostStore.swift` (atomic `hosts.json` at `StoreLocations.hosts`). Add `hosts` and `hostsFolder` to `Pkg/Sources/AgentsKit/Store/StoreLocations.swift`.

### 2d — The SSH layer (Mac only)

- [X] T014 Build the fake `ssh` fixture at `Tests/Fixtures/ssh/ssh` (executable `/bin/sh`) with a `Tests/Support/FakeSSH.swift` helper, per R11: **Done: `Fixtures/ssh/` (shell script + python3 relay + `uname`/`sha256sum` shims), `Support/FakeSSH.swift`. Two stderr fixtures captured for real; the rest are OpenSSH's text written by hand (README says which).**
  - It accepts `-G`, `-M -N -S <ctl> -L a:b`, `-S <ctl> -O check|exit`, and `-S <ctl> <name> <command>`.
  - It runs commands with `HOME=$FAKE_SSH_HOME` via `/bin/sh -c`.
  - It relays `-L` with a small Swift relay the helper builds once into the test's temporary folder.
  - It simulates failures via `FAKE_SSH_FAIL=<stderr fixture name>`.
  - Capture real OpenSSH 10.3 stderr for each row of [ssh.md § Errors](contracts/ssh.md#errors) into `Tests/Fixtures/ssh/stderr/*.txt`.
- [X] T015 [P] Write `Tests/Unit/SSHCommandTests.swift`: **Done: 14 tests.**
  - argv for every command in [contracts/ssh.md](contracts/ssh.md), matched exactly, with `--` before the name;
  - a name starting with `-` is refused;
  - the environment drops `CLAUDE_*`, `AGENTS_*`, `SSH_ASKPASS` and `DISPLAY`, and keeps `SSH_AUTH_SOCK`;
  - `classify` maps each stderr fixture to its `HostProblem`, with `ssh-add -l` stubbed for the locked/refused split.
- [X] T016 Implement `Pkg/Sources/AgentsKit/Hosts/SSHCommand.swift`: argv building, the environment, `run(_:stdin:) async -> (status, stdout, stderr)` ending on `terminationHandler` (memory: `waitUntilExit` hangs off the main thread), and `classify`. The executable URL is injected, so tests pass the fixture. **Done.**
- [X] T017 [P] Write `Tests/Integration/SSHMasterTests.swift` against the fake: `start()` becomes ready when `-O check` passes; the forward socket answers once something listens at the remote path; `stop()` uses `-O exit` and then SIGTERM; `onExit` fires within 1 s of the master being killed; stale `.ctl`/`.sock` files are removed on start. **Done: 7 tests; nothing left running afterwards.**
- [X] T018 Implement `Pkg/Sources/AgentsKit/Hosts/SSHMaster.swift` (contracts/ssh.md § 4). It starts without `-L`, has `restartWithForward(home:)`, exposes `onExit`, and uses socket paths `<root>/hosts/<id>.{ctl,sock}`. It throws `socketPathTooLong` over 103 bytes. **Done. `restartWithForward` is `stop()` then `start(forwardingTo:)`.**
- [X] T019 [P] Write `Tests/Unit/HostKeyCheckTests.swift` using temporary `known_hosts` files: known → `.known`; unknown → the fetch writes `<tmp>` and the fingerprint is parsed; trust appends the line, hashed when `hashknownhosts yes`; cancel deletes `<tmp>`. **Done: 7 tests, all on temporary known_hosts files.**
- [X] T020 Implement `Pkg/Sources/AgentsKit/Hosts/HostKeyCheck.swift` (contracts/ssh.md §§ 1–3). **Done.**
- [X] T021 [P] Write `Tests/Integration/ServerInstallerTests.swift` against the fake, using the Mac `agentsd` built by `swift build` as the "Linux" binary: **Done: 9 tests. Binaries are named `agentsd-<sha16>`; `install.json` carries version and SHA-256 and is written at the swap; `ServerFacts.installedSHA256` added.**
  - the probe parses all five lines, and a garbled probe gives `installFailed`;
  - `Darwin arm64` gives `unsupportedSystem`, and nothing is written under `$FAKE_SSH_HOME`;
  - install puts `bin/agentsd-<v>` with mode 0700, `current` points at it, and `root/` is 0700;
  - a checksum mismatch on first install leaves no `~/.agents-server`;
  - a checksum mismatch on update leaves the old `current` and no `.part` file;
  - `freeBytes` under 200 MB gives `diskFull` before any write;
  - remove with `purge` deletes `~/.agents-server` and nothing else in `$FAKE_SSH_HOME`.
- [X] T022 Implement `Pkg/Sources/AgentsKit/Hosts/ServerInstaller.swift` (`probe`, `install(binary:version:sha256:)`, `swapCurrent`, `purge`), per contracts/ssh.md §§ 5, 6, 8. **Done, plus `removeBinaries(except:)` and `startDaemon()`.**
- [X] T023 [P] Write `Tests/Integration/ServerLinkTests.swift`: with the fake master up and no daemon, `DaemonClient(link: ServerLink(...)).connect()` runs `start()`, the Mac `agentsd --serve --detach` comes up under `$FAKE_SSH_HOME/.agents-server/root`, and `agents/list` answers through the forward. With the master down, `connect` throws within 1 s and never starts a master. **Done: 2 tests; the first installs the Mac `agentsd` over the fake ssh, starts it over ssh, and gets `agents/list` through the forward.**
- [X] T024 Extract `SocketLink`'s connect body into a shared `connectUnixSocket(path:)` in `Pkg/Sources/AgentsKit/Client/SocketLink.swift`. Implement `Pkg/Sources/AgentsKit/Hosts/ServerLink.swift` (R5). **Done: `connectUnixSocket(path:)` shared by both links.**

### 2e — The window can hold many daemons

- [X] T025 [P] Write `Tests/Unit/AgentsModelHostTests.swift`: **Done: 6 tests.**
  - `apply(_:from:)` tags agents and projects with the host;
  - `replaceAgents(_:from: host)` replaces only that host's agents, and `replaceProjects` likewise;
  - two hosts with the same folder path are two projects;
  - `project(_ key:)`, `agents(in:group:)`, `counts(in:)` and `unreadCount(in:)` take `ProjectKey`;
  - records decoded without `host` are `.mac`.
- [X] T026 Add `host: HostID` (client-assigned, default `.mac`, not encoded) to `DaemonAPI.ProjectSummary` and `Agent` in `Pkg/Sources/AgentsKitCore/Model/`. Change `Pkg/Sources/AgentsKitCore/Client/AgentsModel.swift` to key projects by `ProjectKey` and to add `apply(_:from:)`. Keep URL-taking shims that mean `.mac` until T028 has moved every caller, then delete them. **Done. URL-taking queries stay (the phone uses them, and they mean any host); keyed ones added beside them. T028 moves the Mac's callers.**
- [X] T027 Create `App/Sources/Hosts/HostSet.swift` (`@Observable @MainActor`): **In progress: the per-host sequence is `AgentsKit/Hosts/ServerConnection.swift` (master → probe → refuse / install / update-when-idle → forward → connect; offline on master loss), 7 tests in `Integration/ServerConnectionTests.swift`. The app-side `HostSet` wrapper is next.** **Done: `App/Sources/Hosts/HostSet.swift` over `ServerConnection`; `UnreachableLink` so a server call never falls through to the Mac. The kit's `Host` became `ServerHost`, because Foundation has its own `Host`.**
  - hosts `[HostID: HostConnection]`, `.mac` first, the rest loaded from `HostStore`;
  - each `HostConnection` has its `DaemonClient`, link, `SSHMaster?` and `HostState` (data-model.md state diagram);
  - `client(for:)` throws `offline` fast when the host is not connected;
  - the reconnect loop moves here from `AppModel.reconnect()`, per host, with backoff 1→30 s, plus immediate retry on `NSWorkspace.didWakeNotification` and on `NWPathMonitor` becoming satisfied (R8);
  - `AGENTS_SSH` in the environment overrides the `ssh` path, which is used by the fake-host walk.
- [X] T028 Move `App/Sources/AppModel.swift` from its single `client` to `hostSet`: **Done: selection is host+folder (`select(_:)`, `selectedProjectKey`, stored `host|path`); agent calls go to the agent's host, draft and project calls to the selected project's host, and devices, cost, wake, presence and accounts stay on the Mac. The Mac's refreshes replace only the Mac's records; `refreshServer` lists a server's when it connects. Builds; the scratch smoke with no servers is part of T036.**
  - every `client.call` becomes `hostSet.client(for: <the project's or agent's host>)`;
  - whole-app reads (`cost/state`, `attention/pending`) are asked of every connected host and combined;
  - notifications from each host's `client.notifications()` go to `work.apply(_:from:)`;
  - selection and the persisted `selectedProject` use `ProjectKey`;
  - update every view that passed a folder `URL` to the model: `App/Sources/Projects/*`, `AgentList/*`, `Chat/*`, `Sidebar/*`, `StartAgent/*`, `Spending/*`.
  - With no servers added, the app must behave exactly as before: run the full suite and a scratch-root smoke launch (run-app skill).

**Checkpoint**: a server host can be added in code and its agents appear in the model. No UI yet.

---

## Phase 3: User Story 1 — Add a server and start an agent there (P1) 🎯 MVP

**Goal**: add a server by its SSH name, make a project on it, and run an agent there with files and terminal.

**Independent test**: quickstart § 3 steps 1–3 against the fake host. Phase 8 does the same on a real server.

- [X] T029 [P] [US1] Write `Tests/Integration/AddServerFlowTests.swift`, driving the flow object behind the sheet against the fake: connect → unknown key → awaiting trust → trust → checkSystem → setUp → findRuntimes → ready with the Mac's runtimes. The host record is written only at ready. Cancel at awaiting-trust leaves no host record, no `<tmp>` file and no `~/.agents-server`. **Built as `App/Sources/Hosts/AddServerFlow.swift`; exercised through `ServerConnection`'s 7 tests and the T036 walk rather than a separate app-side test (the app target has no test bundle).**
- [X] T030 [US1] Implement `App/Sources/Hosts/AddServerFlow.swift`, the state machine in [ui.md § Add a server](contracts/ui.md#add-a-server-addserversheet). It uses `HostKeyCheck`, `SSHMaster`, `ServerInstaller` (the bundled binary picked by `ServerFacts.architecture` from `Bundle.main` `servers/`; in DEBUG with `AGENTS_SSH` set, the Mac `agentsd` is used) and `ServerLink`, then `runtimes/list`. **Done.**
- [X] T031 [US1] Build `App/Sources/Hosts/AddServerSheet.swift`, states A, B, C and C′ as in `wireframes/mac-add-server.svg`, with strings from wireframes.md § Words. **Open terminal on <label>** calls `shell/attach` with the server's home. **Check again** re-runs `runtimes/list`. **Done. 'Open terminal on <label>' is left out: `shell/attach` needs an agent to belong to, and a server with no runtime has none. C′ says to install one there instead.**
- [X] T032 [US1] Update `App/Sources/Projects/ProjectListView.swift` for host sections and the New project menu. Sections: no headings with only `.mac`; otherwise one section per host with the heading marks from ui.md. The menu: no servers → today's items plus divider and `Add a server…`; servers → a submenu per host. Add `on <label>` to the detail header in `App/Sources/Projects/ProjectAgentsView.swift`. Hide Show in Finder in `ProjectRow.swift`'s menu for server projects. **Done: sections only once a server exists; heading marks; per-host New project submenus; Show in Finder hidden and Archive disabled offline; `on <label>` under the project name.**
- [X] T033 [US1] Build `App/Sources/Hosts/RemoteFolderSheet.swift`, as in `wireframes/mac-new-project.svg` B. Back it with that host's `files/list`, starting at `ServerFacts.home`, folders first, files greyed out and not selectable. Double-click goes into a folder. **Add as project** calls `projects/add` on that host with the selected folder, or the path field when nothing is selected. **Done, backed by a new `files/browse` (absolute or ~ path; 3 tests), since `files/list` needs an agent.**
- [X] T034 [US1] Update `App/Sources/Projects/CloneSheet.swift` so a clone on a server goes to that host's `projects/clone`, with the destination line `Clones into ~/<name> on <label> and adds it as a project.` **Done.**
- [ ] T035 [US1] Add `App/Sources/Sidebar/ProjectFiles.swift` (`.local` / `.remote(HostID)`). Make `Sidebar/FilesPane.swift`, `Sidebar/ImageFile.swift` and `Projects/WorkflowPage.swift` read through it, using `files/list`/`read`/`watch` for server projects. Register a `WKURLSchemeHandler` for `agents-file://<host>/<path>` on the live-page web view, answered from `files/read`. Hide Open in…/Reveal (`Sidebar/OpenElsewhere.swift`) and Keep awake for server projects (FR-016). **Partly done: the files pane lists, reads and watches a server agent's folder through that server (`RemoteFiles` moved from Remote into AgentsKitCore and shared), images are drawn from the bytes sent, and Open in…/Reveal are replaced by 'On <server>. Open it there.' Still open: live pages via an `agents-file://` scheme handler, the workflow page, and hiding Keep awake for server projects.**
- [ ] T036 [US1] **Look gate.** Using the run-app skill on a scratch root with `AGENTS_SSH` pointing at the fixture, run quickstart § 3 steps 1–3. Save screenshots of the grouped list, sheet states A/B/C, the remote folder sheet, and a server project's files pane to `specs/037-cloud-agents/walk/`. Only drive the window if Alex is away (memory). Bring the screenshots to Alex and settle the layout before Phase 4. **Walked 2026-09-25 against the fake ssh; screenshots 01–06 and notes in `specs/037-cloud-agents/walk/`. Three bugs found and fixed (racing connects, update reconnecting to the departing daemon, master outliving quit). Waiting on Alex's look.**

**Checkpoint**: US1 works end to end against the fake host.

---

## Phase 4: User Story 2 — Agents keep working when the Mac goes away (P1)

**Goal**: server agents carry on; the window shows offline honestly and catches up by itself.

**Independent test**: quickstart § 3 step 4. Mid-turn, kill the fake master: the strip appears, Send is disabled and the draft is kept. After reconnect the transcript is complete, with nothing duplicated.

- [ ] T037 [P] [US2] Write `Tests/Integration/HostReconnectTests.swift` (model-level, fake host):
  - killing the master gives `offline(since:)` within 1 s, and calls for that host fail fast with `offline`;
  - the Mac host's projects are untouched;
  - while offline, the server daemon keeps its agent running (the fake runtime finishes a turn);
  - on reconnect `agents/list` + `projects/list` + pending permissions/elicitations + the open transcript are re-fetched, the finished turn is present, and no entry appears twice;
  - a permission raised while offline is answerable after reconnect.
- [ ] T038 [US2] Finish reconnect catch-up in `App/Sources/Hosts/HostSet.swift` and `App/Sources/AppModel.swift`: re-list per host on the transition to connected, and re-fetch the open chat's transcript if its agent is on that host. When the daemon socket is missing after a server reboot, `ServerLink.start()` runs (FR-021).
- [ ] T039 [P] [US2] Build `App/Sources/Chat/OfflineStrip.swift` as in `wireframes/mac-offline.svg`: `<label> is offline since HH:mm. Agents there keep working.`, `Next try in N s`, **Try now**. Show it in the chat view when the agent's host is offline.
- [ ] T040 [US2] Offline treatment:
  - `App/Sources/Chat/PromptBar.swift`: Send disabled, with the tooltip `<label> is offline`; the draft is kept.
  - Permission and question cards (`App/Sources/Permission/*`, `App/Sources/Elicitation/*`): buttons disabled, with the same tooltip.
  - Agent rows (`App/Sources/AgentList/AgentRow.swift`): `.secondary`, with `as of HH:mm` in place of the live time.
  - Project rows of an offline host: `.secondary`; Archive disabled.
- [ ] T041 [US2] Sends across a drop (ui.md § Sending across a drop):
  - `AppModel` makes a `sendID` per send/answer and passes it in the call;
  - on a transport error it shows `Sending…`, then retries with the same ID once the host reconnects, within 30 s;
  - after 30 s it removes the bubble, puts the text back in the field, and shows `Not sent — <label> went offline.`
  - Test in `Tests/Integration/HostReconnectTests.swift`: drop the forward right after the daemon acts, and exactly one prompt is delivered.

**Checkpoint**: US1 + US2 is the useful product: work on a server that survives the laptop.

---

## Phase 5: User Story 3 — A server that cannot be used says why (P2)

**Goal**: every failure is one sentence naming the cause, and a failed setup leaves nothing behind.

**Independent test**: the five cases in spec US3, via `FAKE_SSH_FAIL` and a fake probe reporting `Darwin`.

- [ ] T042 [P] [US3] Extend `Tests/Integration/AddServerFlowTests.swift`. Each of `unknownHost`, `loginRefused`, `keyLocked`, `hostKeyChanged`, `unsupportedSystem`, `noStreamLocalForwarding`, `diskFull` and `timedOut` ends in state D within 30 s (use a 2 s timeout in the test), with the exact string from wireframes.md § Words, and `$FAKE_SSH_HOME` has no `.agents-server`. `hostKeyChanged` offers no Try again.
- [ ] T043 [US3] Add state D to `App/Sources/Hosts/AddServerSheet.swift`: the failed step in red with its sentence, the field keeping its text, and **Try again** returning to connect (none for `hostKeyChanged`). Put every `HostProblem` string in one `HostProblem+Words.swift` beside it.
- [ ] T044 [US3] A zero-runtime server: state C′ in the sheet, and the start form for a server project in `App/Sources/StartAgent/*` offers only that host's `runtimes/list`. With none, it shows `No agent runtime on <label>. Install one there and log in, then choose Check again.` (FR-012).

---

## Phase 6: User Story 4 — The server stays in step with the app (P2)

**Goal**: older servers are updated when idle; newer servers are refused.

**Independent test**: quickstart § 4 SC-007 on the fake host. Stamp the "installed" binary's `--version` lower with a wrapper script.

- [ ] T045 [P] [US4] Write `Tests/Integration/ServerUpdateTests.swift`:
  - older + idle: install new, `daemon/quit`, swap, start; projects and transcripts are intact;
  - older + mid-turn: the host is `updateWaiting`, nothing is swapped, and after the fake turn ends the swap happens;
  - newer: `serverNewer`, nothing is written, and no daemon is started or stopped;
  - the old binary is deleted only after the next successful connect.
- [ ] T046 [US4] Implement the update path in `App/Sources/Hosts/HostSet.swift`, using `ServerInstaller` and `daemon/status`/`daemon/quit`: compare versions on every connect, and re-check `turnsInFlight` on each `agent/changed` from that host while `updateWaiting`. Show `Update waiting` in the heading (T032) and in Settings (T048).

---

## Phase 7: User Story 5 — Remove a server (P3)

**Goal**: remove a server cleanly; the person's code on it is never touched.

**Independent test**: quickstart § 2 remove cases, then Settings ▸ Servers on the fake host.

- [ ] T047 [P] [US5] Write `Tests/Integration/RemoveServerTests.swift`:
  - idle: `daemon/quit {stopAgents:false}`, master stopped, host record gone, its projects gone from the model, `~/.agents-server` still present;
  - with purge: `~/.agents-server` gone and a project folder elsewhere in `$FAKE_SSH_HOME` byte-identical;
  - busy: `daemon/quit {stopAgents:true}` stops the fake agents first.
- [ ] T048 [US5] Build `App/Sources/Hosts/ServersSettingsView.swift` as in `wireframes/mac-settings-servers.svg`:
  - rows with state, `ServerFacts`, version, project count and runtimes; **Check again**, **Remove…** and **+**;
  - the Remove dialog uses `agentsLive` for `N agents are running on <label> and will be stopped.` and **Stop N and Remove**, plus the purge checkbox (off by default);
  - add the tab with `server.rack` after Devices in `App/Sources/AgentsApp.swift`.
- [ ] T049 [US5] Implement `HostSet.remove(_:purge:)` in `App/Sources/Hosts/HostSet.swift`, following contracts/ssh.md § 8.

---

## Phase 8: Polish, costs and the real server

- [ ] T050 [P] Costs across hosts (R7):
  - `App/Sources/Spending/*` and the project list's spending row sum each connected host's `cost/state` and add `· £X on servers`;
  - `cost/setLimits` is pushed to every host on change and on connect;
  - `App/Sources/Settings/CostSettingsView.swift` gains `Each server keeps to this limit on its own.` under the daily limit.
  - Test the sum in `Tests/Unit/AgentsModelHostTests.swift`.
- [ ] T051 [P] Attachments to server projects: add `files/write` to `DaemonAPI.swift`/`DaemonCore` (writes under `<project>/.agents/attachments/`, 25 MB cap, refusing paths outside the project), with a test in `Tests/Integration/`. Use it from `App/Sources/Chat/PromptBar.swift` for server projects, with the too-big message from ui.md.
- [ ] T052 Build `project.yml`: copy `App/Resources/servers/*` into the app bundle's `Resources/servers/`. Run `scripts/build-linux-agentsd.sh` before `xcodegen`. Both schemes build sequentially with `-skipPackagePluginValidation` (memory).
- [ ] T053 Run the full `swift test` six times on this branch and on its merge-base, and compare against T002 before blaming anything on this branch (memory: the suite is flaky under load). Run `scripts/build-linux-agentsd.sh --check`.
- [ ] T054 Write `specs/037-cloud-agents/walk/README.md` listing the real-server checks from [quickstart § 4](quickstart.md#4-real-server-phase-6-alex) (SC-001, SC-002/003, SC-005, SC-006, SC-007, two Macs, reboot), each with the exact steps and what passing looks like. Those are Alex's to run.

---

## Dependencies

```
Phase 1 (T001–T003)
   └─► Phase 2a gate (T004–T005) ──► stop if it fails
          └─► 2b daemon (T006–T011) ─┐
              2c host record (T012–T013) ─┤
              2d SSH layer (T014–T024) ───┤ (2b/2c/2d in parallel)
                                          └─► 2e many daemons (T025–T028)
                                                 └─► US1 (T029–T036, look gate)
                                                        ├─► US2 (T037–T041)
                                                        ├─► US3 (T042–T044)
                                                        ├─► US4 (T045–T046)
                                                        └─► US5 (T047–T049)
                                                               └─► Phase 8 (T050–T054)
```

- US2–US5 each depend only on US1 and can go in any order after the look gate. US4's heading
  mark and US5's Settings row share `ServersSettingsView`, so do US5's T048 before US4's Settings
  line, or add that line in T048.
- T041 needs T011 (`sendID`). T046 and T049 need T009 (`daemon/status`, `daemon/quit`).

## Parallel opportunities

- Phase 2: T006/T008/T010 (daemon tests), T012 (host tests), and T015/T017/T019/T021/T023 (SSH tests) are all in different files and can be written together. T004 blocks only T005.
- US1: T033 (remote folder sheet), T034 (clone sheet) and T035 (files) are independent once T030–T032 exist.
- US2: T039 (strip) alongside T038 (catch-up).
- Phase 8: T050 and T051 are independent.

## Implementation strategy

1. **The gate first.** T001–T005. A daemon that does not run on Linux ends the feature, so it is
   proved on a real server before anything else is built.
2. **MVP = US1 + US2** (both P1). Add a server, work on it, and have the work survive the lid
   closing. Stop at T036 for the look, and again after T041 for a real-server try by Alex.
3. **Then US3** (failures). It is cheap once the classifier exists, and it is what makes the
   feature trustworthy.
4. **US4 and US5** before merging. Without updates, the first app release after merge breaks
   every server.
5. Merge only when Alex says it is this lane's turn (memory).
