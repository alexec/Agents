# Contract: a workspace provider, version 1

A workspace provider is an ordinary MCP server (stdio or streamable http) whose tools follow
these names. This page becomes `docs/reference/workspace-providers.md`.

## Results

Every tool returns its result as `structuredContent`. A server that can't do that may return
one `text` content holding the same JSON. A failure is a result with `isError: true` and one
`text` content. That text is shown to the person as it is, so it should be a sentence in the
provider's own words, cut at 1 KB.

## `workspaces_list` (required)

It takes nothing. It returns:

```json
{
  "contract": 1,
  "workspaces": [
    {
      "id": "agents-devbox",
      "name": "devbox",
      "state": "stopped",
      "ssh": "alex@127.0.0.1 -p 2222",
      "tunnel": true,
      "cost": "$0.03/hour while running"
    }
  ]
}
```

**Fields**:
- `contract` is required. A control plane refuses a major version it doesn't know.
- `state` is one of `running`, `starting`, `stopping`, `stopped` or `unknown`.
- `ssh` is optional. It is an ssh destination: either `user@host` or an alias in the ssh
  config of the machine running the control plane. It may have a `-p port` suffix.
- `tunnel` is optional (default false). True means the workspace can't reach the control
  plane, so the control plane holds a reverse tunnel over `ssh`.
- `ssh` may change between starts, as a VM's address can (#1691). The tunnel and the ssh
  start use the one listed now, and check the host key trusted at the install.
- `hostKeyRenews` is optional (default false). True means the workspace's ssh host key is
  made again at each start (#1701). After a Start that the control plane made, its ssh
  start takes the key it is offered and pins it again. At any other time, a changed key is
  refused.
- `cost` is optional, and is shown as given.

**Limits**: at most 200 workspaces are read. Ids must be stable across restarts.

## `workspace_start` (required) and `workspace_stop` (required)

They take `{ "id": "<workspace id>" }`. They return once the workspace is running (or stopped),
with that workspace as `workspaces_list` would give it:
`{ "workspace": { … } }`. A call that is still going after 10 minutes is a failure.

A start of a workspace that is already running succeeds at once, and so does a stop of one
that is already stopped.

## `workspace_options` (optional, US5)

It takes nothing. It returns `{ "schema": <JSON Schema object> }`, a flat object of string,
integer, boolean and enum properties with titles. The New Workspace form is drawn from it.
An enum property may carry `x-costs`, `{value: cost}`, for the confirmation (layouts L9).

## `workspace_create` (optional, US5)

It takes:

```json
{ "name": "devbox-2", "options": { … }, "firstBoot": "curl -fsSL … | sh -s -- agents-control:2:h:…" }
```

It returns `{ "workspace": { … }, "firstBootRuns": true }`. When `firstBootRuns` is false, the
Mac opens Add a Server with the returned `ssh` filled in, as Add as Host… does: the person
trusts the new machine's key there. `firstBoot` ends with the host's name, which is the
workspace's, as `install.sh`'s second argument; the control plane links the host that joins
under it.

## `workspace_delete` (optional, US5)

It takes `{ "id": "…" }` and returns `{}` once the workspace is gone.

## Recognition

A server is a provider when its `tools/list` holds all three required names and its
`workspaces_list` reports a `contract` the control plane knows. The optional tools are found by
name. No MCP capability or extension is needed.

## Events (optional)

A provider MAY offer the #383 events `workspace.stopped` and `workspace.started` (with
`{id}` in the details), for workflows on a host. The control plane doesn't use them. It reads
the list instead.
