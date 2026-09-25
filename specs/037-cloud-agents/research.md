# Research: Cloud Agents

Each entry: **Decision**, **Rationale**, **Alternatives considered**. Findings from reading this
repository are cited by path.

## R1 — How `agentsd` gets onto Linux

**Decision**: Cross-compile the existing `Daemon` target and `AgentsKit` from the Mac with the
**Swift Static Linux SDK** (`x86_64-swift-linux-musl`, `aarch64-swift-linux-musl`), using a
swift.org toolchain of the same Swift version as Xcode's (6.4 today). The output is two fully
static executables with no runtime dependencies. `scripts/build-linux-agentsd.sh` builds both,
stamps the version, and copies them to `App/Resources/servers/agentsd-linux-{x86_64,aarch64}`,
which `project.yml` copies into the app bundle.

**Rationale**:
- Static musl binaries run on any Linux distribution, whatever its libc, which is what "copy it
  over and run it" needs. No Swift runtime on the server; nothing to `apt install`.
- One source tree. The daemon is ~13k lines in `AgentsKit` plus 12k in `AgentsKitCore`, and it
  gains a feature every day. A second implementation would fall behind in a week.
- Swift on Linux has `Foundation` (swift-corelibs / swift-foundation), `Dispatch`, `Process`,
  `FileManager`, `Observation` and `posix_spawn`. Those are what the daemon uses.

**Found**: this Mac has **no Swift SDK installed** (`swift sdk list` is empty), no swift.org
toolchain in `~/Library/Developer/Toolchains`, and no container runtime (no `docker`, `podman`
or `container`). The toolchain and SDK are a one-time install of about 1.5 GB, and Phase 0 must do
it first. Xcode's own toolchain cannot use a swift.org SDK reliably, so the script picks the
swift.org toolchain explicitly with `--toolchain` / `TOOLCHAINS`.

**Alternatives considered**:
- *Build on the server*: needs Swift on every server and minutes of compile before first use.
  Rejected.
- *Build in a Linux container on the Mac*: no runtime here, and that is a bigger install than
  the SDK.
- *Rewrite the server side in Go or Rust*: a second daemon, which is the drift above.
- *CI builds the binaries*: fine later. It does not remove the need to build locally to test.

## R2 — What in the daemon is Darwin-only

**Decision**: guard or replace exactly these, found by grepping imports in
`Packages/AgentsKit/Sources`:

| File | Darwin use | On Linux |
|---|---|---|
| `AgentsKit/Terminal/PTY.swift`, `ShellSession.swift` | `import Darwin`, `openpty`, `ioctl` | `import Musl`/`Glibc`. `openpty` exists in musl; `TIOCSWINSZ` is the same ioctl. |
| `AgentsKit/Files/FolderWatch.swift` | FSEvents (`CoreServices`) | An `inotify` watcher with the same callback shape. Used by workflows (`DaemonCore+Workflows.swift:79`) and the 034 `files/watch`. |
| `AgentsKit/Power/PowerSource.swift`, `Wake.swift` | `IOKit.ps`, power assertions | A no-op implementation: "on mains, never asleep". 024's keep-awake is hidden for servers anyway. |
| `AgentsKitCore/Remote/CloudKitMailbox.swift`, `NetworkLink.swift`, `DeviceKey.swift`, `Envelope.swift` | CloudKit, Network, Security, CryptoKit | Excluded with `#if canImport(...)`. A server has no paired devices in v1. `DaemonCore+Devices`/attention posting become inert: no devices, so nothing to seal. |
| `AgentsKit/Client/SocketLink.swift`, `Daemon/DaemonServer.swift` | `Darwin.connect`, `sockaddr_un` layout, `SO_NOSIGPIPE` | A small `PlatformSocket` shim: `MSG_NOSIGNAL` on Linux, `sun_path` size 108. |

Everything else checked is portable: `LoginShellPath` runs `$SHELL -lc` (works with bash), `Process`
and `posix_spawn` for runtimes, `FileManager.urls(for: .applicationSupportDirectory)` (unused on
the server because the root is always given).

**Rationale**: the list is short because the daemon was already split from the app (see the
comment in `Package.swift` about `AgentsKitCore` vs `AgentsKit`). Guarding in place keeps one
source of truth.

**Alternatives considered**: a separate `AgentsKitLinux` target that re-implements the core. That
is a fork.

**Risk**: something only shows up when compiling. That is why Phase 0 is a gate: build both
architectures and run one turn on a real server before any UI is written.

## R3 — The connection: one SSH master, one socket forward

**Decision**: for each connected server the app runs one long-lived process:

```
ssh -M -N -S <root>/hosts/<id>.ctl
    -o ControlPersist=no -o BatchMode=yes
    -o ServerAliveInterval=15 -o ServerAliveCountMax=3
    -o ExitOnForwardFailure=yes -o StreamLocalBindUnlink=yes
    -L <root>/hosts/<id>.sock:<remote-home>/.agents-server/root/daemon.sock
    <ssh-name>
```

Every other step runs over it with `ssh -S <ctl> -o BatchMode=yes <ssh-name> <command>`. The
remote home comes from the probe (R6), because `-L` needs an absolute path.

**Rationale**:
- It is what Alex described: copy the daemon over, forward its socket locally.
- The window's existing path to a daemon is a Unix-socket `SocketLink`, so a forwarded socket
  plugs in with no protocol work. Each `DaemonClient.connect` opens a new channel on the master.
  Opening one is a single round trip, with no new TCP connection and no new authentication.
- The person authenticates once per master: one hardware-key touch, one host-key question.
- `ServerAlive*` notices a dead link within ~45 s even with nothing being sent. The master exits,
  and `HostSet` sees the process end (R8).
- A forward to a socket that does not exist yet is fine. The local end accepts, the channel open
  fails, the client sees EOF and treats it as "nothing answering", which is exactly when
  `DaemonLink.start()` runs.

**Socket path length**: `<root>/hosts/<8 chars>.sock` under
`~/Library/Application Support/Agents/` is about 80 bytes, under the 104 `SocketLink` enforces.
A scratch root with a long path gets the same `socketPathTooLong` error it gets today.

**Alternatives considered**:
- *A stdio relay* (`ssh host agentsd attach` per connection, bytes over stdin/stdout): no
  forward and no local socket file. But it needs a new `LineTransport` over a child process, and
  one `ssh` process per connection. Kept as the fallback if a server's `sshd` has
  `AllowStreamLocalForwarding no`. The probe detects that (R6) and says so. v1 does not implement
  the fallback.
- *TCP forward to a daemon TCP port*: the daemon would gain a listener (FR-006 forbids it).
- *libssh2 or a Swift SSH library in-process*: loses the person's `~/.ssh/config`, agent,
  `ProxyJump` and FIDO keys, which FR-002 requires, and adds a dependency.
- *Mosh / Eternal Terminal*: they carry terminals, not sockets.

## R4 — Host keys without ever typing a password

**Decision**:
1. `ssh -G <name>` resolves the name through the person's config, with no network. It gives
   `hostname`, `port`, `user`, `userknownhostsfile`, `hashknownhosts` and `proxyjump`.
2. `ssh-keygen -F <host>` / `-F [host]:port` over each known-hosts file tells whether the key is
   known.
3. **Unknown host**: fetch the key with no credentials:
   `ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=<tmp>
   -o PreferredAuthentications=none -o GlobalKnownHostsFile=/dev/null <name> true`.
   This goes through `ProxyJump` like any connection, records the key in `<tmp>`, and fails
   authentication without offering a key. `ssh-keygen -lf <tmp>` gives the SHA256 fingerprint
   the sheet shows. **Trust and continue** appends `<tmp>`'s line to the first
   `userknownhostsfile`, hashed with `ssh-keygen -H` if `hashknownhosts yes`.
4. **Changed key**: `ssh` itself refuses with "REMOTE HOST IDENTIFICATION HAS CHANGED". The
   classifier maps that to the changed-key message. The app never offers to fix it (FR-003).
5. Every other invocation uses `BatchMode=yes` and the person's own `StrictHostKeyChecking`.

**Rationale**: `ssh-keyscan` ignores `ProxyJump` and config aliases, so it gets the wrong key
behind a bastion. Letting `ssh` fetch the key is the only way that matches what `ssh` will check
later. `BatchMode` guarantees `ssh` never waits on a hidden prompt (spec edge case: locked key).

**Locked keys and passphrases**: with `BatchMode`, a key that needs a passphrase fails like a
refused key. The classifier checks `ssh-add -l`: if the agent holds no keys, the message is the
"locked key" one; otherwise it is "refused". An `SSH_ASKPASS` helper that shows the prompt in the
app would let passphrases through without storing them. That is noted for later and is not in v1
(spec Assumption: key-based, agent-loaded).

**Alternatives considered**: `StrictHostKeyChecking=accept-new` silently (violates FR-003's
"show and ask"); showing `ssh`'s own prompt in a terminal (not a sheet, and needs a PTY).

## R5 — The server's link is a `SocketLink` plus a remote start

**Decision**: `ServerLink: DaemonLink`.
- `transport()`: the same code as `SocketLink.transport()`, at `<root>/hosts/<id>.sock`. The
  body is extracted into a function both links call.
- `start()`: `ssh -S <ctl> <name> ~/.agents-server/bin/current/agentsd --root
  ~/.agents-server/root --serve --detach`. `--detach` is a new flag. The daemon re-spawns
  itself with `POSIX_SPAWN_SETSID` exactly as `SocketLink.start()` does on the Mac, and the
  parent exits at once. That way there is no dependency on `setsid(1)` or `nohup` on the server,
  and the `ssh` channel closes cleanly.
- If the master is not running, `transport()` throws `couldNotConnect` and `start()` throws
  "offline". `HostSet` owns bringing the master back (R8); a link never starts one.

**Rationale**: `DaemonClient` is already written against `DaemonLink` precisely so the carrier can
change (see its header comment). `AppModel`'s calls do not change shape.

## R6 — Probe, install, update, remove

**Decision**: all over the master, all idempotent, all written so a failure part way leaves the
previous state.

- **Probe** (one command): `uname -sm; printf '%s\n' "$HOME"; df -Pk "$HOME" | tail -1;
  ~/.agents-server/bin/current/agentsd --version 2>/dev/null || true;
  grep -i '^ *AllowStreamLocalForwarding' /etc/ssh/sshd_config 2>/dev/null || true`.
  Parsed into `ServerFacts`. `Linux x86_64` or `Linux aarch64` passes; anything else is refused
  before anything is written (FR-004).
- **Install**: `mkdir -p -m 700 ~/.agents-server/bin ~/.agents-server/root &&
  cat > ~/.agents-server/bin/.agentsd-<v>.part && chmod 700 … && mv … agentsd-<v> &&
  ln -sfn agentsd-<v> ~/.agents-server/bin/current`. The binary goes in on stdin. About 40 MB,
  so a few seconds on a good link; the sheet's *Set up* step shows bytes sent. A checksum is
  compared with `sha256sum` (coreutils, busybox, and toybox all have it) before `mv`.
- **First-install failure** removes `~/.agents-server` only if the probe found it absent. A
  failed update removes only the `.part` file (FR-025).
- **Update** (FR-022): install `agentsd-<new>` beside the old one. Then ask the running daemon
  `daemon/status`. If `turnsInFlight == 0`, call `daemon/quit`, swap `current`, and `start()`.
  Otherwise mark the host `updateWaiting` and ask again on each `agent/changed` that ends a turn.
  Agents that were idle are picked up by the existing restart recovery (025) with nothing lost.
- **Newer server** (FR-023): the probe's version is newer than the bundled one. Refuse, with no
  install and no connection beyond the probe.
- **Remove**: `daemon/quit` (the dialog has already confirmed stopping running agents; `quit`
  stops them the way Stop does), wait for the socket to go, stop the master, delete the host
  record. With the checkbox, also `rm -rf ~/.agents-server`. Project folders are never inside it.

**Version comparison**: the app's marketing version plus build number, stamped into both
binaries by the build script and returned by `--version` and `daemon/status`. Equal means
compatible. There is no protocol-range negotiation in v1: the app ships its daemon, and both
are the same build.

## R7 — Many daemons in one window: client-side, not federated

**Decision**: the window holds a `HostSet`: `.mac` plus each server, each with its own
`DaemonClient`, link and `HostState`. There is still **one** `AgentsModel`.
- Every `ProjectSummary` and `Agent` that arrives from a host is tagged with that `HostID` before
  it is applied. `apply(_:from:)` wraps today's `apply`.
- `replaceAgents`/`replaceProjects` replace only that host's subset, so a server re-listing after
  a reconnect does not drop the Mac's projects.
- Project identity becomes `ProjectKey(host, folder)`. Two servers may both have
  `/home/alex/src/api`. Selection, `project(_:)`, `agents(in:)`, `counts(in:)`, workflows by
  folder, and the persisted `selectedProject` key take the key instead of the bare URL.
- Agent IDs are UUIDs made by each daemon, so collisions are not a practical concern. Routing a
  call about an agent uses `agent.host`.
- `AppModel`'s ~70 `client.call` sites become `client(for: host)`. Methods that are about the
  whole app — `cost/state`, `attention/pending`, `runtimes/list` for the start form — are asked
  of every connected host and combined, or of the project's host, whichever the call is about.

**Rationale**: the wireframes put every host in one list, so the model is the natural place to
combine them. The daemon stays single-host and knows nothing about SSH.

**Alternatives considered**:
- *Federation in the Mac daemon*: the Mac `agentsd` connects to servers and proxies. The window
  and phone would be unchanged, and the phone would see server projects for free. But every one
  of ~90 methods and ~30 notifications needs routing. The Mac daemon would have to stay alive,
  and its lifetime would decide the servers' reachability. And a bug there would take down local
  work too. **This is the natural route for the phone follow-up**: a later feature can let the
  Mac daemon carry server notifications to the mailbox without changing this plan's shape.
- *One `AgentsModel` per host*: the grouped list and spending totals would then combine at every
  view. One model with tagged records is less code.

**Costs** (FR-014): `cost/state` is per daemon. The spending row sums the connected hosts' `today`
and shows the servers' share. **Limits**: `cost/setLimits` is sent to every host whenever it
changes and on connect, so each daemon enforces the same per-agent ceiling. The **daily** limit
is then enforced per host, not across all of them. That is a known v1 gap, written into the
Settings help text. A true cross-host daily cap needs a coordinator, which the Mac cannot be
while it is asleep.

## R8 — Staying up, noticing loss, reconnecting fast

**Decision**:
- `agentsd --serve` sets `DaemonCore.exitsWhenIdle = false`. `runUntilIdle` keeps reaping
  shells but never returns. A server daemon then keeps scheduled workflows firing with no Mac
  connected (spec edge case: days with no Mac).
- `HostSet` watches the master process. When it exits: state → `.offline(since:)`, and every
  call for that host fails fast with an `offline` error, which the UI already disables for.
  Reconnect with backoff 1, 2, 4 … 30 s. It retries **immediately** on
  `NSWorkspace.didWakeNotification` and on an `NWPathMonitor` path change to satisfied. That is
  what makes SC-003's 10 s possible after a lid opens.
- Catch-up is what the Mac app already does on reconnect: `agents/list`, `projects/list`,
  `permissions/pending`, `elicitations/pending`, then the open chat's `agents/transcript`. The
  transcript is stored by the daemon, so nothing that happened while away is missing (FR-018).
  Nothing is replayed from the client, so nothing is shown twice.
- **Server reboot** (FR-021): the master reconnects, the forward finds no socket, and
  `ServerLink.start()` runs. The daemon's existing `recover()` + `pickUpAfterRestart` handle the
  agents.

**Rationale**: the reconnect loop in `AppModel.reconnect()` already has this shape for the Mac
daemon. It moves into `HostSet` and runs per host.

## R9 — What the Mac window reads from its own disk

**Found**: the Mac files pane, image preview, workflow page and prompt attachments read the local
disk directly (`App/Sources/Sidebar/FilesPane.swift`, `ImageFile.swift`,
`Projects/WorkflowPage.swift`, `Chat/PromptBar.swift`), through `DirectoryReader` / `FolderWatch`
in `AgentsKit`. On `main` the daemon has **no** file-listing methods. **034-ios-artifacts** (built,
not merged) adds `files/list`, `files/read`, `files/watch`, `files/unwatch`, `files/changed` for
the phone.

**Decision**: 037 builds on 034. For a server project, the files pane, image preview and workflow
page use the `files/*` methods through the host's client. Local projects keep reading the disk,
because it is faster and already walked. A thin `ProjectFiles` protocol in the app chooses
between the two. Live pages use a `WKURLSchemeHandler` for `agents-file://<host>/<path>` that
answers from `files/read`, so relative links and images in a page resolve on the server.
Attachments: a new `files/write` into `<project>/.agents/attachments/`, whose path is then
referenced in the prompt the way a local path is today. Show in Finder, Open in…, Reveal and
Keep awake are hidden when `project.host != .mac` (FR-016).

**Alternatives considered**: `sshfs`/`macFUSE` mounts (a kernel extension on macOS, and slow);
`sftp` from the app (a second channel type and a second set of error cases, for what `files/*`
already does).

## R10 — Exactly-once prompt and answer

**Decision**: `agents/prompt`, `permissions/answer` and `elicitations/answer` gain an optional
`sendID: UUID`. The daemon keeps the last 512 `(sendID → result)` pairs in memory. A repeat
returns the stored result without acting again. The client makes the ID once per send and retries
with the same ID after a reconnect if the first attempt's reply never came. If the retry cannot be
made within 30 s, the prompt bar shows the text as *not sent* and puts it back in the field
(FR-020).

**Rationale**: a dropped channel after the daemon acted but before the reply arrived is the one
case where retrying sends twice. The memory lives only as long as the daemon, and so does the
retry window. A daemon restart between the two loses the memory, and the retry then goes through
once, which is the rare right answer anyway since the first was lost with the restart's runtime.

**Alternatives considered**: never retry (FR-020 says report *not sent*, which is right only if
we know it was not). Persist the IDs (overkill for a 30 s window).

## R11 — Testing without a server

**Decision**:
- **Fake `ssh`**: `Tests/AgentsKitTests/Hosts/Fixtures/ssh` is a shell script. It parses the
  options the app passes, runs the remote command with `HOME=<tmp>/server-home` via `/bin/sh -c`,
  and implements `-M -N -L local:remote` by running `socat` if present, or a 40-line Swift relay
  the test target builds. `SSHCommand` takes the `ssh` executable URL as a parameter, so tests
  point it at the fixture. Nothing in product code knows it is a test.
- With it, the Mac `agentsd` stands in for the Linux one. The whole of install → start → forward
  → `agents/list` → update → remove runs in `swift test`, as does the offline path (kill the
  fake master).
- **Error classifier** tests use `ssh`'s real stderr strings, captured once from OpenSSH 10.3, as
  fixtures.
- **Linux compile** is a build step (`scripts/build-linux-agentsd.sh --check`) run before merge.
  Linux runtime behaviour — inotify, the PTY, `--detach` — is proved in Phase 0 and Phase 6 on a
  real server. That is Alex's hardware, or a VM he gives an address for.

**Found**: `ssh localhost` is not usable here (Remote Login off), and there is no container
runtime, so a real Linux daemon can only be exercised on a real server.
