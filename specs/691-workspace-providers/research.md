# Research: Workspace providers through MCP

Decisions for [plan.md](plan.md), from source at `4d2f42d2`. Each gives the decision, why, and
what else was looked at.

## R1. The control plane's MCP client

**Decision**: Add a public façade, `MCPToolClient`, in `AgentsKit/MCP/`, over the existing
internal `MCPClient`. It offers `connect`, `listTools`, `callTool(_:arguments:timeout:)` and `end`,
and takes a `log` closure, which ControlPlaneKit sets to `ControlLog`. `MCPClient.request` gains
an optional per-call timeout, so one connection can have 30 s lists and 10 minute starts
(FR-005).

**Rationale**:
- ControlPlaneKit already links AgentsKit (for `HostInstall`).
- `MCPClient` already does stdio and streamable http, and it has the hardening of #191 and #383:
  page limits, the 401 failure, and `MCPStdioProcess`.
- The spec's assumption ("the control plane gets an MCP client of its own, separate from the
  daemon's") is met by a separate *instance* in a separate process. A second implementation is
  not needed.

**Alternatives**:
- Make `MCPClient` itself public. That exposes events, resources and the pool's internals.
  The façade keeps the surface to what providers need.
- Write a client in ControlPlaneKit. That duplicates about 400 lines of tested code.
- Move the client into a new shared package. That is too big a move for this feature.

## R2. Recognising a provider

**Decision**: When it is added and on every reconnect, `tools/list` is checked:

- **Contract**: `workspaces_list`, `workspace_start` and `workspace_stop` must all be present.
  Any missing ones are named in the refusal (US2 AS2). `workspace_options`,
  `workspace_create` and `workspace_delete` are noted as capabilities.
- **Version**: the first `workspaces_list` must carry `contract: 1`. A higher major version is
  refused, saying which version it offers.
- **Tool map**: the same check is made against the map's tool names (US2 AS6). The refusal
  names the server's missing tool, not the contract's.
- **Results**: they are read from `structuredContent`. If there is none, the first text
  content is parsed as JSON. A `tools/call` result with `isError: true` is a failure, and its
  text, cut at 1 KB, is the reason ("in the provider's words", US1 AS3).

**Rationale**: The spec's assumption is that tool names plus the version are enough, with no
MCP extension. `structuredContent` is what `MCPServerKit` returns (`ToolResult.structured`).

## R3. Where secrets live

**Decision**:
- A provider's secrets (name → value) are kept in `<control home>/provider-secrets.json`,
  mode 0600, keyed by provider id. They are written only by `providers/add` and removed by
  `providers/remove`.
- They are given to a stdio provider as environment variables, and to an http provider as
  header values, through `${NAME}` substitution in its configured headers.
- `ProviderRecord` in the store keeps only the secret *names*.
- The wire to clients carries names and "set", never values. Log lines name the provider,
  never its environment or headers.

**Rationale**:
- The store may be an S3 bucket, and FR-003 forbids secrets there.
- The control plane's own key comes in as a file descriptor from Agents Host's Keychain. That
  fits a fixed key read once at launch, not secrets added while it runs.
- A 0600 file in the control home is how scratch set-ups already keep their keys
  (`HostSecrets`, scratch). On Linux the home is the container's volume.
- Hosts never escalate: the file belongs to the control plane's own user.

**Alternatives**:
- The Keychain, by Agents Host. Agents Host would have to relay each secret to the running
  `agents-control`, a new channel. The memory "seeded Keychain items prompt the app" warns
  against items made outside the app.
- The store, encrypted with the control key. That is better for a mesh, but a mesh doesn't
  run providers (R4). Left for #61.

## R4. Which copy runs providers

**Decision**: Providers, starts and idle timers run only on a control plane with no mesh, the
same rule `HostTunnels` follows today (`ControlService.swift:276`, `mesh == nil`).

- On a mesh, the provider methods answer "Workspace providers need a single control plane for
  now", and links are kept but **Start** is not offered.
- The spec's edge case ("one copy at a time runs each provider") becomes a lease, as
  `Leases.swift` does for hosts, when #61 brings the control plane to the cloud.

**Rationale**:
- `direction.md`: "The control plane stays on the Mac for now."
- Tunnels, which a start needs, are already single-copy.

## R5. Finding the command provider's binary

**Decision**: A provider of kind `commands` is run as `workspace-commands`, found in this order:

1. beside the running `agents-control` (`Bundle.main.executableURL` / `CommandLine.arguments[0]`)
2. `AGENTS_WORKSPACE_COMMANDS` (tests and walks)
3. `PATH`

When none is found, adding it fails with "workspace-commands isn't installed beside the
control plane".

**Rationale**: Another lane of #700 is shipping the MCP server binaries beside agentsd, and
this lane must not change that packaging. Looking beside `agents-control` works once it lands,
and the variable lets walks use `swift build`'s output now.

## R6. The command provider's configuration

**Decision**:
- The whole configuration is one JSON value in `WORKSPACE_COMMANDS_CONFIG`
  ([contract](contracts/command-provider.md)), so the binary needs no file.
- There are two shapes:
  - **Workspaces**: a list, each with a name and its `start`, `stop`, optional `status` and
    `ssh` commands.
  - **Preset**: a preset name, plus its parameters (such as a tag for `doctl`).
- Commands run through `/bin/sh -c`, with `${id}` and `${name}` substituted after shell
  quoting.
- Timeouts: `status` and `list` 30 s; `start` and `stop` 10 minutes, less 5 s so the
  provider's own failure arrives before the control plane's timeout.
- A `status` command's output is matched case-insensitively against the five states, plus the
  preset's own words: `exited` maps to stopped for docker, `off` to stopped for doctl,
  `Shutdown` to stopped for codespaces.

**Rationale**:
- Configuration in the environment is what every MCP host passes to a stdio server.
- The control plane already keeps the provider's record, so a file would be a second copy.
- `sh -c` lets a person paste the command they already use (`cws start devstack-1`).

## R7. Links, states and the wire

**Decision**:
- `HostRecord.workspace: WorkspaceLink?` holds the provider id, workspace id, `startWhenUsed`
  (default true) and `stopWhenIdleMinutes` (default 30; nil means off).
- `HostState` gains:
  - `.stopped(since:, by:)`, where `by` is `.agents(idleMinutes)`, `.outside` or nil
  - `.starting(phase:, since:)`, where the phase is `.provider`, `.connecting` or `.sshStart`
  - `.stopping`
- The state of a linked offline host comes from its workspace's last listed state: stopped
  gives `.stopped`, starting gives `.starting(.provider)`. An unlinked offline host stays
  `.offline`.
- `ControlHost.state` gains the strings `stopped`, `starting` and `stopping`, and
  `ControlHost.workspace: HostWorkspace?` adds:
  - provider name, workspace name and workspace state
  - the phase, and the last problem
  - `canStart`, `canStop`, `startWhenUsed`, `stopWhenIdleMinutes`
  - whether the list is current
- `ControlHostChanged` carries the same, so clients redraw without a list.

**Rationale**:
- `HostState` is the one place the router keeps per-host state, and it is already broadcast.
- The Mac reads `state == "online"`, the Remote reads `state == "online"` and the web reads
  `hostIsOnline`. A new string therefore reads as "not online" on older clients, the same as
  today.

**As built**: `HostState` gained no cases. The router keeps the `HostWorkspace` per host
and lays its `hostState` over the state it describes (data-model.md), so no exhaustive switch
across the clients had to change.

## R8. Starting

**Decision**: The `WorkspaceStarts` actor keeps a task per workspace (US1 AS4: a second
**Start** joins the one in flight, and answers at once with its phase). The order:

1. Broadcast `.starting(.provider)`.
2. Call `workspace_start` (10 minutes).
3. On success, refresh the list, broadcast `.starting(.connecting)` and wait for `attachHost`.
4. After 2 minutes, if the list has an ssh destination, run `ServerInstaller(…).startDaemon`
   over `SSHCommand` with `HostInstall.options`, and broadcast `.starting(.sshStart)`. Agents
   never reinstalls (FR-013) and never runs sudo. If the host has a tunnel record,
   `HostTunnels.add`/`reconcile` opens the tunnel at once, before the wait.
5. If the host has not attached after 10 minutes in all, fail with "devbox didn't connect in 10
   minutes". Without an ssh destination, the reason is "agentsd didn't start; make it start on
   boot (loginctl enable-linger)".
6. A failure broadcasts `.offline` or `.stopped` again, with `workspace.problem` set, and
   **Start** is offered once more.

**Rationale**: This follows the spec. `ServerInstaller.startDaemon` is what an install already
runs.

**Note**: `ServerInstaller` has no stop. **Stop** is the provider's `workspace_stop`. The host
drops, and is shown `.stopping` and then `.stopped(by: nil)` when the next list says so. The
control plane does not send `daemon/quit` first, because the provider owns the machine.

## R9. Kept requests (US3, a later PR)

**Decision**:
- The router does not parse requests today. For a host whose state is stopped or starting
  (and only then), `ControlRouter.clientLine` peeks at the JSON-RPC `method`. If it is a prompt
  send (`agents/send`) or an agent start (`agents/start`, `agents/new`; the exact names are
  checked in the US3 PR), and the link says start when used, the request is written to
  `v1/kept/<host>/<seq>.json` and answered at once with `kept: {host, id}`.
- When the host attaches, the router opens a channel of its own (a new `ChannelTarget.kept`)
  and replays the requests in order, deleting each one once the host answers.
- At most 20 kept requests per host.
- Cancelling is `hosts/dropKept`.

**Rationale**: The request has to outlive the client (US3 AS2), so it must live in the store.
Every other request keeps today's refusal (FR-022).

**Risk**: A send's id and its idempotence. The Mac's `sendToServer` already retries with the
same `sendID`, and the daemon dedupes by it, so replaying is safe. This is checked in the US3 PR.

## R10. Idle (US4, a later PR)

**Decision**:
- `ControlUplink` sends `host/status {idle, since}` on channel 0 whenever the host's idleness
  changes, using `hasWorkInFlight`, `isHoldingAgents` and `ShellSession.isIdle`. The control
  plane keeps `idleSince` per host and sets one timer per linked host.
- A new turn makes the host send `idle: false`, which cancels the timer (US4 AS2).
- An older host that never sends status is never stopped as idle, and its row says so.

**Alternatives**: The control plane opens a channel and polls `daemon/status` every minute. That
costs more, and `DaemonStatus` doesn't cover terminals or questions.

## R11. Agent tools (US6, a later PR)

**Decision**: There are four new `AppService` tools: `list_workspaces`, `start_workspace`,
`stop_workspace` and `make_workspace`, plus `delete_workspace`. Each is relayed by the daemon as
a channel-0 request to the control plane (`ControlUplink`), which runs it as a client would.
Make and delete first call the daemon's `askForm` path, so the question card shows on every
client.

## R12. The layout gate

**Decision**:
- [contracts/layouts.md](contracts/layouts.md) draws, in text, every screen this feature adds
  or changes:
  - the strip in each phase
  - the Hosts row
  - the Providers page
  - the Add Provider sheet
  - Link to Workspace…
- It is put to Alex as previews in a question before any client code is written (direction.md:
  no machinery under an unsettled layout).
- Control-plane work (R1–R8) doesn't depend on the layout and can go ahead meanwhile.
