# Data model: Workspace providers

The types are in `AgentsKitCore/Control/Workspaces.swift` unless another file is named. The
store keys are under the control plane's store (a folder, or S3).

## ProviderRecord (store: `v1/providers/<id>.json`)

| Field | Type | Notes |
|---|---|---|
| `id` | String | `ProviderID.make`. A slug of the name plus 4 random characters. |
| `name` | String | Shown on every row. It must be unique among providers. |
| `kind` | `commands` \| `stdio` \| `http` | `commands` is the bundled command provider (R5). |
| `command`, `args` | String, [String] | For `stdio` only. |
| `url`, `headers` | String, [String: String] | For `http` only. Header values may hold `${SECRET}`. |
| `commands` | JSON | For `commands` only: the command provider's configuration ([contract](contracts/command-provider.md)). |
| `secretNames` | [String] | The names only. Values are in `provider-secrets.json`. |
| `map` | `ToolMap?` | Nil means the server follows the contract ([contract](contracts/tool-map.md)). |
| `capabilities` | [String] | Which optional tools it has (`options`, `create`, `delete`), found when it was added. |
| `contract` | Int | The contract version its list reported. |
| `rev`, `forgotten`, `forgottenAt` | | The same as `HostRecord`, for the store's conditional writes and tombstones. |

**Validation**:
- `name` is not empty and at most 60 characters.
- For `stdio`, the command is not empty. For `http`, the URL is `http(s)://`.
- Every `${X}` in the headers or commands names an entry in `secretNames`.

## Provider secrets (local: `<control home>/provider-secrets.json`, 0600)

`{ "<provider id>": { "<NAME>": "<value>" } }`. This is never in the store, never on the wire,
and never logged (FR-003).

## WorkspaceInfo (in memory, last list per provider)

| Field | Type | Notes |
|---|---|---|
| `id` | String | The provider's own stable id. |
| `name` | String | |
| `state` | `running` \| `starting` \| `stopping` \| `stopped` \| `unknown` | Any other state is read as `unknown`. |
| `ssh` | String? | An ssh destination (`user@host`, or an ssh-config alias). |
| `tunnel` | Bool | The workspace can't reach the control plane, so a reverse tunnel is needed. |
| `cost` | String? | Shown as given. At most 120 characters. |

Held per provider as `WorkspaceList`:
- `workspaces`: at most 200
- `listedAt`
- `current`: false once a list has failed after a good one
- `problem`

## WorkspaceLink (on `HostRecord.workspace`, in `Grant.swift`)

| Field | Type | Default |
|---|---|---|
| `provider` | ProviderID | |
| `workspace` | String | The workspace's id. |
| `startWhenUsed` | Bool | true |
| `stopWhenIdleMinutes` | Int? | 30. Nil means off. |

**Rules**:
- A workspace is linked to at most one host. Linking a workspace that is already linked moves
  the link (spec edge case).
- Removing a provider leaves its hosts' links unresolved. They are cleared the next time the
  host is saved, and until then the host is drawn without Start (US2 AS5).

## HostState (in `Grant.swift`), new cases

```text
online
offline(since)
connecting
needsUpdate(from, to)
failed(reason)
stopped(since, by: StopCause?)                // new. StopCause: agentsIdle(minutes) | person | outside
starting(phase: StartPhase, since)            // new. StartPhase: provider | connecting | sshStart
stopping(since)                               // new
```

### Transitions for a linked host

```text
                 Start (any client) / kept request (US3)
 stopped ─────────────────────────────────────────► starting(provider)
    ▲                                                  │ workspace_start ok
    │ workspace_stop ok / list says stopped            ▼
 stopping ◄── Stop / idle timer ── online ◄── hello ── starting(connecting)
                                     ▲                 │ 2 min, ssh known
                                     └──── hello ───── starting(sshStart)
 any starting ── provider error / 10 min ──► stopped or offline, with workspace.problem
 offline ── list says stopped ──► stopped(by: outside)
 stopped ── list says running ──► offline (until hello) → online
```

## HostWorkspace (wire: `ControlHost.workspace`, `ControlHostChanged.workspace`)

| Field | Type |
|---|---|
| `provider`, `providerName` | ProviderID, String |
| `workspace`, `workspaceName` | String, String |
| `workspaceState` | String |
| `phase` | String? (`provider`, `connecting`, `sshStart`) |
| `problem` | String? (the provider's words, at most 1 KB) |
| `stoppedBy` | String? (`Stopped by Agents after 30 minutes idle`, already worded) |
| `canStart`, `canStop` | Bool |
| `startWhenUsed` | Bool |
| `stopWhenIdleMinutes` | Int? |
| `current` | Bool |

## ProviderSummary (wire: `providers/list`)

These fields come from `ProviderRecord`, without its commands, headers or secrets:
- `id`, `name`, `kind`
- `secretNames`, with whether each is set
- `capabilities`, `contract`, `mapped`

It adds:
- `workspaces: [WorkspaceInfo]`, each with `host: HostID?` (the host it is linked to)
- `listedAt`, `current`, `problem`

## ToolMap

See [contracts/tool-map.md](contracts/tool-map.md).

## KeptRequest (US3, store: `v1/kept/<host>/<seq>.json`)

`{ id, host, method, params (JSON), from: ClientID, at, seq }`. There are at most 20 per host.
Each is deleted once it has been delivered and answered, or dropped.
