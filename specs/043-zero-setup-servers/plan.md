# Implementation Plan: Zero-Setup Servers

**Branch**: `043-zero-setup-servers` (branched from 037) | **Date**: 2026-09-25 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `specs/043-zero-setup-servers/spec.md`, taking defaults D1–D5 as written.

## Summary

037 already installs `agentsd` on a server by streaming it over the SSH master, checking its
checksum, and swapping a `current` link last. This feature does the same for **Claude's toolset**,
and adds a way to hand Claude a token without it ever touching the server's disk.

1. **A pinned Claude toolset.** The app carries a small manifest: a Node.js version with the
   SHA-256 of its two Linux tarballs (x64, arm64), and a `package-lock.json` for
   `@agentclientprotocol/claude-agent-acp`, whose `integrity` fields are npm's own checksums for
   every package, including the SDK's per-platform native binary (R1, R2).
2. **The server downloads it (D2).** Over the existing master, one script fetches Node with
   `curl` or `wget`, checks it against the app's checksum, unpacks it, and runs
   `npm ci --ignore-scripts` against the app's lockfile. Everything lands in
   `~/.agents-server/tools/claude/<toolset>/` and a `current` link moves last, exactly like the
   daemon. Nothing touches the person's PATH, profile or own Node (R3, FR-004).
3. **Claude is started from the toolset, not `npx`.** On a server the daemon's discovery looks
   for the app's toolset first, then 037's `npx` on PATH (FR-005). The toolset launches
   `node …/claude-agent-acp/dist/index.js` directly, so a turn never reaches for the network to
   install anything (R4).
4. **The token lives in the Mac's Keychain (D1)** and is lent, never sent ahead. When a server
   daemon has to start Claude for a request and has no token for it, it answers
   `credentialWanted`; the window calls `credentials/lend` on that connection and retries with
   037's `sendID`, so the retry is exactly-once. The daemon keeps a lent token in memory for that
   connection only, puts it in the runtime's environment (`CLAUDE_CODE_OAUTH_TOKEN` or
   `ANTHROPIC_API_KEY`), and forgets it when the connection closes (R5, R6, FR-012).
5. **The Mac's own daemon never takes a lend (D5).** `credentials/lend` is refused unless the
   daemon runs with `--serve`, which only servers do.
6. **Refusals are their own failure.** A 401 from the provider, surfaced by the ACP adapter, is
   classified as `credentialRefused` and stops the agent with "Claude refused the token in
   Settings. Replace it", not as a stopped runtime (R7, FR-016).
7. **A rebuilt server is a choice, not a wall.** 037's `hostKeyChanged` gains a sheet with the new
   fingerprint and "This server was rebuilt"; on it, the old key is removed with
   `ssh-keygen -R`, the new one trusted, and set-up runs as for a new server. The window
   remembers each server's project paths in `hosts.json`, so projects the rebuilt server no
   longer has show as gone, with Remove (R8, FR-017–019).
8. **Updates and purge come free.** A different toolset id is installed beside the old one and
   swapped when no Claude agent on that server is mid-turn, using 037's `updateWaiting` path.
   Purge already removes `~/.agents-server` whole (FR-007, FR-008).

See [research.md](research.md) for each decision, [data-model.md](data-model.md) for the new
records, and [contracts/](contracts/) for the SSH scripts, daemon methods and screens.

## Technical Context

**Language/Version**: Swift 6.x (strict concurrency), SwiftUI, as 037. The Linux `agentsd` is
still built with the Static Linux SDK.

**Primary Dependencies**:
- AgentsKit / AgentsKitCore (in-repo), 037's `SSHCommand`, `SSHMaster`, `ServerInstaller`,
  `ServerConnection`, `HostKeyCheck`.
- Security.framework (Keychain) in the Mac half of AgentsKit only; the Linux build excludes it as
  it already does for 037.
- On the server, at run time: `sh`, `tar`, `sha256sum`, and `curl` or `wget`. Nothing else, and
  no root.
- Downloaded, pinned: Node.js LTS (v24 line; glibc tarballs from nodejs.org), and
  `@agentclientprotocol/claude-agent-acp` (0.81.x today) with its lockfile.
- No new Swift packages.

**Storage**:
- Mac: the token in the login Keychain (generic password, one item per runtime, scoped to the
  app's root so scratch copies do not share the real one). What is safe to show — kind, last four
  characters, added, last worked — in `credentials.json` in the root. `hosts.json` gains, per
  server, `ownSignInOnly` and the last-seen project paths.
- App bundle: `Resources/toolsets/claude/` with `manifest.json` and `package-lock.json`
  (+ `package.json`).
- Server: `~/.agents-server/tools/claude/<toolset-id>/` and `tools/claude/current`, beside 037's
  `bin/` and `root/`. The token is never on it.

**Testing**:
- `swift test`: fake-ssh suites (037's `.serialized FakeSSHSuites` parent) run the real install
  script against a local mirror of fixture tarballs, pointed at by an environment variable the
  test sets, so checksum mismatch, no downloader, full disk and a failed `npm ci` are all driven
  end to end without the network.
- A **bare** Linux container, `agents-bare`, beside 037's `agents-devbox`: Debian with
  `openssh-server`, `curl` and `ca-certificates` only — no Node, no Claude, no sign-in. It is the
  walk for SC-001, SC-003, SC-004 (rebuilt = `docker rm` + `docker run` on the same port).
- The Linux build gate for both architectures, as 037.

**Target Platform**: macOS 27 app; Linux x86-64 and ARM64 servers with glibc ≥ 2.28 for the
toolset (Node's own floor). musl servers keep 037's behaviour and are told why Claude cannot be
installed (R2).

**Project Type**: macOS app + helper daemon (existing, with its Linux build).

**Performance Goals**: first Claude reply on a bare server ≤ 5 min from Add a server (SC-001;
the download is ~50 MB Node + ~70 MB npm tree); a re-connect to a set-up server adds ≤ 5 s (SC-002:
one extra line in the existing probe, no extra round trip); a token check answers ≤ 10 s
(SC-006).

**Constraints**:
- The token never reaches a server's disk, any log, transcript, crash report, or any process but
  the Claude runtime it was lent for (FR-012). It crosses the wire only inside the SSH-forwarded
  daemon socket.
- The Mac daemon gains no token and no network code; the window does the provider check.
- 037's rule stands: nothing listens on a network port on the server.

**Scale/Scope**: one installable runtime (Claude, D3). ~8 new files, ~15 touched.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

`.specify/memory/constitution.md` is still the unfilled template, so there are no ratified gates.
The project's standing rules apply instead:

| Rule | How this plan meets it |
|---|---|
| Settle the UX before building depth | Phase 1 builds the Settings credential section, the checklist step and the rebuilt-server sheet against the fake-ssh host, and they are walked on a scratch root before the install and lending get their depth. |
| One daemon owns the work; windows only ask | Kept. The server daemon starts Claude; the window only lends. |
| The daemon gains no network code | Kept. Downloads are `curl`/`wget` run by a shell script over SSH; the token check is the window's. |
| Never mutate source to prove a test | The mirror is an environment variable the fake-ssh fixture sets, not a switch in product code. |
| Every lane in its own worktree; merge when Alex says | This worktree. 037 merges first (D4; it has, as `b36226e`), and this branch is re-based on main before building. |

**Post-design re-check**: passes. No listener, no new package, no daemon network code, the Mac
daemon's behaviour unchanged (D5).

## Project Structure

### Documentation (this feature)

```text
specs/043-zero-setup-servers/
├── spec.md
├── plan.md              # this file
├── research.md          # R1–R10
├── data-model.md        # RuntimeCredential, Toolset, InstalledTools, ServerHost additions
├── quickstart.md        # fake-ssh and the bare container
├── contracts/
│   ├── ssh.md           # probe line, install/swap/remove scripts, exit codes → sentences
│   ├── daemon.md        # credentials/lend, credentialWanted, credentialRefused, discovery order
│   └── ui.md            # Settings ▸ Servers credential section, checklist step, token ask, rebuilt sheet, gone projects
└── tasks.md             # /speckit-tasks
```

### Source Code (repository root)

```text
Packages/AgentsKit/
├── Sources/AgentsKitCore/
│   ├── Hosts/Host.swift                       # ServerHost + ownSignInOnly, knownProjects; ServerFacts + tools line;
│   │                                          # HostProblem + noDownloader, toolsetFailed, unsupportedLibc
│   ├── Runtimes/Toolset.swift                 # NEW  manifest record, toolset id
│   ├── Runtimes/CredentialKind.swift          # NEW  oauthToken / apiKey, from the prefix; env var name; mask
│   └── Daemon/DaemonAPI.swift                 # credentials/lend; credentialWanted, credentialRefused codes
├── Sources/AgentsKit/
│   ├── Hosts/ToolsetInstaller.swift           # NEW  install, swap, remove-others, over SSHCommand
│   ├── Hosts/ServerConnection.swift           # tools step after the daemon, update-when-idle for tools
│   ├── Hosts/HostKeyCheck.swift               # forget(old) for a rebuilt server
│   ├── Credentials/CredentialStore.swift      # NEW  Keychain + credentials.json (Mac only)
│   ├── Credentials/CredentialCheck.swift      # NEW  provider check over HTTPS (Mac only)
│   ├── Runtimes/RuntimeDiscovery.swift        # toolset first on a server
│   ├── Daemon/DaemonCore+Credentials.swift    # NEW  per-connection lent map, lend handler, wanted/refused
│   ├── Daemon/DaemonCore.swift                # ProcessSessionLauncher takes extra environment
│   └── Daemon/DaemonServer.swift              # connection closed → forget its lends
├── Tests/AgentsKitTests/Hosts/ToolsetInstallTests.swift      # NEW  fake-ssh
├── Tests/AgentsKitTests/Credentials/LendTests.swift          # NEW  daemon-level
└── Tests/Fixtures/toolsets/                                  # NEW  tiny fake node tarball + lock
App/Resources/toolsets/claude/          # NEW  manifest.json, package.json, package-lock.json
scripts/update-claude-toolset.sh                # NEW  regenerate the lock and checksums for a new pin
App/Sources/
├── Settings/ServersSettingsView.swift         # Claude sign-in section; per-server "own sign-in only"
├── Settings/CredentialRow.swift               # NEW
├── Hosts/AddServerFlow.swift                  # "Install Claude" checklist step
├── Hosts/HostSet.swift                        # lend on credentialWanted; remember project paths
├── Hosts/RebuiltServerSheet.swift             # NEW
├── Hosts/HostProblem+Words.swift              # the new sentences
├── Projects/ProjectListView.swift             # gone-from-server rows
└── Chat/TokenAskCard.swift                    # NEW  in-place ask before a server agent starts
```

**Structure Decision**: The toolset installer sits beside 037's `ServerInstaller` in AgentsKit's
Mac half, reusing `SSHCommand`, so fake-ssh tests reach it. Lending is daemon code, so the Linux
build gets it; the Keychain and the provider check are Mac-only files, excluded from Linux in
`Package.swift` the way 037's Security users are.

## Phases

| Phase | What | Gate |
|---|---|---|
| 0 | **Spike on `agents-bare`.** By hand over SSH: download Node, `npm ci --ignore-scripts` the lock, start `claude-agent-acp` with `CLAUDE_CODE_OAUTH_TOKEN`, one turn. Check that the env token beats a `~/.claude` login, what a revoked token looks like over ACP, and which check endpoint answers for an OAuth token. | A turn completes on the bare box with nothing but the token. If `--ignore-scripts` breaks the SDK, R2 changes before anything is built. |
| 1 | **Look.** Settings credential section (store, mask, check), checklist step, token ask card, rebuilt sheet, gone rows — against the fake-ssh host. | Look gate on a scratch root. |
| 2 | `ToolsetInstaller`, probe line, failure sentences, discovery order, fake-ssh suites. | Fake host installs, fails each way cleanly, and Claude is found from the toolset. |
| 3 | Lending: `credentials/lend`, `credentialWanted` retry, env on launch, forget on close, `credentialRefused`, own-sign-in-only. | Daemon suites green; token absent from every file under the fake server's `HOME` and the Mac root. |
| 4 | Rebuilt server and gone projects. | `docker rm`/`run` on `agents-bare`, one confirmation, a Claude agent answers. |
| 5 | Update-when-idle for toolsets, purge check, SC-003 leak search script. | Toolset swap waits for a mid-turn agent. |
| 6 | Real walk on `agents-bare`: SC-001…SC-006. | Run by me with the test-servers skill; Alex only for the token (his to paste). |

## Complexity Tracking

| Violation | Why Needed | Simpler Alternative Rejected Because |
|---|---|---|
| A lockfile and checksums the app must carry and refresh | FR-003: pinned versions checked before use | `npx -y` on the server takes whatever is latest and checks nothing the app named. |
| A per-connection lend instead of a token field on every call | FR-012: only when starting, only for that runtime, never left behind | A field on `agents/start` misses relaunches on `agents/prompt`, answers and helpers; a daemon-wide token outlives the window that gave it. |
| `hosts.json` remembers server project paths | FR-019: gone, not offline, after a wipe | The wiped server's own `projects.json` is gone with it; nothing else knows what was there. |
