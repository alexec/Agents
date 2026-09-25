# Data Model: Cloud Agents

## Host (AgentsKitCore, `Hosts/Host.swift`)

A machine the work can happen on.

| Field | Type | Notes |
|---|---|---|
| `id` | `HostID` | `"mac"` for this Mac; otherwise 8 random `[a-z0-9]` characters, made when added. Short on purpose: it names the socket files (R3). |
| `sshName` | `String` | Exactly what the person typed: an alias or `user@host[:port]`. Passed to `ssh` unchanged, so their config decides everything else. |
| `label` | `String` | Shown in the list and headings. Defaults to the alias, or the host part of `user@host`. |
| `addedAt` | `Date` | |
| `facts` | `ServerFacts?` | From the last probe. |
| `trustedFingerprint` | `String?` | SHA256 shown and accepted at add time. Kept to show in Settings; `known_hosts` is what `ssh` actually checks. |

`HostID.mac` is never stored; it is implied.

**Validation**: `sshName` is non-empty, has no whitespace, and does not start with `-`, so it can
never be read as an `ssh` option. Two hosts may not share an `sshName`.

## ServerFacts

| Field | Type | Notes |
|---|---|---|
| `system` | `String` | `uname -s` (`Linux`) |
| `architecture` | `Architecture` | `.x86_64` / `.aarch64` / `.other(String)` |
| `home` | `String` | Absolute. Used to build the forward target. |
| `freeBytes` | `Int64` | From `df -Pk`. Install refuses under 200 MB with the disk-full message. |
| `installedVersion` | `String?` | `version` from `~/.agents-server/install.json`, or nil. |
| `streamLocalForwarding` | `Bool` | False only if `sshd_config` says `AllowStreamLocalForwarding no` or `local`. |
| `probedAt` | `Date` | |

## HostState (app, not stored)

```
             add / app launch
                   │
                   ▼
   ┌──────── connecting(step) ────────┐
   │   steps: connect → checkSystem → setUp → findRuntimes
   │                                   │
   ▼                                   ▼
failed(HostProblem)        connected(version, runtimes: [RuntimeStatus])
   ▲                           │   ▲          │
   │                 master    │   │ reconnect│ newer app installed
   │                 exits     ▼   │          ▼
   └──── (setup only) ─── offline(since, nextTry) updateWaiting(from, to)
                                                  │ turns reach 0
                                                  ▼
                                               connecting(setUp)
```

- `connecting` shows the checklist in the Add sheet, and a spinner dot in the heading.
- `offline` keeps the host's projects and agents in the model, flagged stale (FR-019).
- `failed` is only reachable while adding or re-checking. A host that worked once and then drops
  is `offline`, not `failed`, unless the probe on reconnect finds a changed key, a newer server,
  or a missing binary it cannot reinstall.

## HostProblem

One case per message in [ui.md](contracts/ui.md#words). Each carries only what its sentence
needs.

`unknownHost`, `loginRefused`, `keyLocked`, `hostKeyChanged`, `unsupportedSystem(system, arch)`,
`noStreamLocalForwarding`, `diskFull(freeBytes)`, `serverNewer(server, app)`,
`installFailed(stderrTail)`, `timedOut(step)`.

Classified from `ssh`'s exit status and stderr by `SSHCommand.classify` (see
[ssh.md](contracts/ssh.md#errors)).

## ServerInstall (on the server, `~/.agents-server/`)

```
~/.agents-server/                 0700
├── install.json                  { "version", "sha256", "installedAt", "installedBy": "<Mac name>" }
├── bin/
│   ├── agentsd-1.14+812          0700, static
│   ├── agentsd-1.13+790          kept until the next successful update, then deleted
│   └── current -> agentsd-1.14+812
└── root/                         a normal daemon root (StoreLocations)
    ├── daemon.sock, daemon.lock, daemon.log
    ├── projects.json, agents/, workflows.json, cost…
```

Removing a host with the checkbox set deletes this whole folder and nothing else.

## Tagged records (client side)

The daemon's records do not change. The window tags them as they arrive.

- `DaemonAPI.ProjectSummary` + `host: HostID` (client-assigned; default `.mac`, so a record
  decoded without it is the Mac's).
- `Agent` + `host: HostID` (same).
- `ProjectKey { host: HostID, folder: URL }`, which is `Hashable`, replaces bare `URL` wherever
  `AgentsModel` or `AppModel` identifies a project: `project(_:)`, `agents(in:group:)`,
  `counts(in:)`, `unreadCount(in:)`, `workflows(in:)`, selection, and the persisted
  `selectedProject` default. The stored value becomes `"<host>|<path>"`. Old values with no `|`
  read as `.mac`.
- `stale: Bool`, computed from the host's state, not stored on the record.

## hosts.json (Mac, `<root>/hosts.json`)

`[Host]`, written by the app only, atomically. Its sibling `<root>/hosts/` holds `<id>.ctl` and
`<id>.sock` while a master runs. Both are removed when the master stops, and stale ones are
removed at launch.

## Daemon-side additions

| Name | Where | What |
|---|---|---|
| `exitsWhenIdle` | `DaemonCore` | `false` under `--serve`. |
| `recentSends` | `DaemonCore+Sends.swift` | Ring of 512 `(UUID, JSONValue)`; lookup before acting on `agents/prompt`, `permissions/answer`, `elicitations/answer`. |
