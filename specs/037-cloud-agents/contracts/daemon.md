# Contract: Daemon changes

The daemon stays single-host and knows nothing about SSH. These are the only changes.

## Command line (`Daemon/Sources/main.swift`)

| Flag | Meaning |
|---|---|
| `--serve` | Never exit for being idle. `runUntilIdle` keeps reaping shells, but `shouldExit` is always false. |
| `--detach` | Spawn this same executable with the same arguments minus `--detach`, with `POSIX_SPAWN_SETSID`, stdin `/dev/null`, stdout+stderr appended to `<root>/daemon.log`. Then exit 0. If the lock is already held, exit 0 without spawning. |
| `--root <path>` | Unchanged. |

## New methods

### Where the version lives (changed during implementation, 2026-09-25)

A Swift `-D` flag carries no value, so the binary cannot stamp its own version without
generating source. The installer writes the version instead:
`~/.agents-server/install.json` holds `{"version": "<CFBundleShortVersionString>+<CFBundleVersion>",
"sha256": …, "installedAt": …, "installedBy": …}`. The probe reads that file in place of
`agentsd --version`. The daemon knows nothing of its version, and there is no `--version` flag.

### `daemon/status` → `{ turnsInFlight: Int, agentsLive: Int }`

`turnsInFlight` counts agents starting, running or waiting on the person — where the update must wait. `agentsLive` counts agents
holding a runtime, used by the remove dialog's number.

### `daemon/quit` `{ stopAgents: Bool }` → `{}`

- `stopAgents: false`: refuse with `busy` if `turnsInFlight > 0`. Otherwise shut down as the idle
  path does. Idle agents are resumed by the next daemon through the existing restart recovery
  (025).
- `stopAgents: true`: stop every live agent the way `agents/stop` does, then shut down. Used by
  Remove.

Replies before exiting. The socket going away is the signal that it has finished.

## Changed methods

`agents/prompt`, `permissions/answer`, `elicitations/answer` gain an optional
`requestID: UUID`. If present and seen in the last 512, the daemon returns the stored result and
does nothing. Absent means today's behaviour, which is what the phone and every older client send.

## Linux build

- `Package.swift`: no new targets. Files that import CloudKit, Network, Security or CryptoKit are
  wrapped in `#if canImport(...)`. Types other code names (e.g. `Envelope`, `Device`) keep a stub
  on Linux, so the daemon's call sites need no guards. On a server `devices` is always empty and
  `mailbox/post` is never broadcast.
- `FolderWatch` gets an `#if os(Linux)` inotify body with the same initializer and callback.
- `PTY`/`ShellSession`/`DaemonServer`/`SocketLink` socket and ioctl calls go through a
  `Platform` shim (`Darwin` / `Musl`).
- `Power`: `PowerSource.current` returns `.mains`; wake assertions are no-ops.
- `scripts/build-linux-agentsd.sh [--check]`:
  `swift build -c release --swift-sdk {x86_64,aarch64}-swift-linux-musl --product agentsd
  -Xswiftc -DAGENTS_BUILD_VERSION=…`. Writes both binaries and their SHA256 to
  `App/Resources/servers/`. `--check` builds without copying, and is the pre-merge gate.
