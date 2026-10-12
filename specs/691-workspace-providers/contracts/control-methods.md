# Contract: control plane methods

These are new methods in `DaemonAPI+Control.swift`, answered by `ControlMethods.answer`. They
are added to `own`, and every one but the lists is added to `writes`. On a control plane with a
mesh, every method answers `providersNeedOneCopy` (R4).

## Providers (Mac only, US2)

| Method | Params | Result |
|---|---|---|
| `providers/list` | `{}` | `{ providers: [ProviderSummary] }`, as last listed. A page that opens also sends `providers/refresh` (FR-004). |
| `providers/add` | `{ name, kind, command?, args?, url?, headers?, commands?, map?, secrets: {NAME: value} }` | `ProviderSummary`, once the server has been connected and checked and has listed. Refusals name what is missing ("It has no workspace_stop tool"). |
| `providers/update` | `{ id, …same fields, secrets? }` | `ProviderSummary`. Secrets that are left out are kept. |
| `providers/remove` | `{ id }` | `{}`. Its hosts stay, unlinked (US2 AS5). |
| `providers/refresh` | `{ id? }` | `{}`. The results come as `control/providersChanged`. |

`control/providersChanged` is a notification to clients, carrying `{ providers: [ProviderSummary] }`.

## Links and actions (all clients for start/stop)

| Method | Params | Result |
|---|---|---|
| `hosts/link` | `{ host, provider, workspace, startWhenUsed?, stopWhenIdleMinutes? }` | `ControlHost`. A workspace that is already linked moves to this host. |
| `hosts/unlink` | `{ host }` | `ControlHost` |
| `hosts/setWorkspaceOptions` | `{ host, startWhenUsed?, stopWhenIdleMinutes? }` | `ControlHost` (US3/US4) |
| `hosts/start` | `{ host }` | `ControlHost` with `state: "starting"`, right away. Progress comes as `control/hostChanged`. A second call while one is in flight returns the same. |
| `hosts/stop` | `{ host, confirmRunning?: Bool }` | `ControlHost` with `state: "stopping"`. While turns are running and `confirmRunning` isn't true, it is refused with `running: [agent names]` (US4 AS4; the names come from the host's last `host/status`, and are empty before US4). |

`hosts/start` and `hosts/stop` get `Row(…, kind: .controlRequest)` in
`DaemonAPI.WebSignatures.rows`, so the web page and `generated.ts` have them. The provider
methods don't, because Providers is Mac only.

**Errors**:
- `notLinked`: "devbox isn't linked to a workspace"
- `providerGone`
- `providerFailed(reason)`: the provider's words
- `providersNeedOneCopy`

## ControlHost and ControlHostChanged

- `state` gains `stopped`, `starting` and `stopping`.
- Both types gain `workspace: HostWorkspace?` ([data model](../data-model.md#hostworkspace-wire-controlhostworkspace-controlhostchangedworkspace)).
- `ControlRouter.describe` writes the same `workspace` object into `control/hostChanged`.

## Log lines (FR-060), in `control.log`

```text
workspace: start devbox (do-1/agents-devbox) by client mac-…: ok in 41s
workspace: start devbox by client web-…: failed: "Error: droplet is locked"
workspace: ssh start devbox (alex@…): ok
workspace: stop devbox by idle (30 min): ok
provider: added do-1 (commands, preset doctl), 2 workspaces
```

These lines never include environment values, headers, secret values or commands with
secrets substituted in.
