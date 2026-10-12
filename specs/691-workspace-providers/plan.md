# Implementation Plan: Workspace providers through MCP

**Branch**: `agents/691-start-create-remote` | **Date**: 2026-10-11 | **Spec**: [spec.md](spec.md)

**Input**: Feature specification from `specs/691-workspace-providers/spec.md` (issue #691).

Planned from source at `4d2f42d2` (origin/main, #700's server kit just landed), without building
or running anything. The decisions are in [research.md](research.md), the records in
[data-model.md](data-model.md), the interfaces in [contracts/](contracts/), the screens in
[contracts/layouts.md](contracts/layouts.md) and the walk in [quickstart.md](quickstart.md).

## Summary

Today the control plane routes bytes between clients and hosts and never acts on a host by
itself. `HostState` is `online`, `offline`, `connecting`, `needsUpdate` or `failed`, and a request
for a host with no channel is refused with "That host is offline." (`ControlRouter.toHost`).
This feature gives the control plane an MCP client of its own, for providers only. With it the
control plane can start a host's workspace, hold work until the host connects, and stop the
workspace when the host has been idle.

1. **The command provider**: a new executable `workspace-commands` in `Packages/MCPServers`, on
   `MCPServerKit` (#700). It follows the contract (`workspaces_list`, `workspace_start`,
   `workspace_stop`, and optionally create, delete and options) and runs shell commands through
   `ChildProcess`. Its configuration (workspaces or a preset) comes in one JSON environment
   variable, so it needs no file. Presets for `docker`, `doctl`, `gh codespace`, `coder` and
   `gcloud workstations` are compiled in.
2. **Providers on the control plane**: `ControlPlaneKit/Providers/`.
   - `ProviderRecord` is kept in the store at `v1/providers/<id>.json`, with no secrets in it.
   - Secrets go in a 0600 file in the control plane's own home, never the store (R3).
   - `WorkspaceProviders` (an actor) connects to each provider through AgentsKit's `MCPClient`,
     which becomes public behind a small façade. It checks the contract or the tool map, lists
     workspaces every 5 minutes and on demand, and keeps the last list in memory.
3. **Links and states**:
   - `HostRecord` gains `workspace: WorkspaceLink?`.
   - `HostState` gains `stopped(since:by:)`, `starting(phase:since:)` and `stopping`.
   - `ControlHost` (the `hosts/list` row) gains a `workspace` summary, so every client can draw
     **Start**, **Stop** and the phase.
   - Older clients read the new state strings as not online, which is what they do today.
4. **Starting**: `WorkspaceStarts` (an actor) allows one start or stop per workspace. It calls
   the provider, waits for the host's hello, and after 2 minutes starts agentsd over ssh
   (`ServerInstaller.startDaemon`, no reinstall) and opens the host's tunnel. It gives up after
   10 minutes, and each phase change is broadcast as `control/hostChanged`.
5. **New control methods**:
   - `providers/list`, `providers/add`, `providers/remove`, `providers/refresh`
   - `hosts/link`, `hosts/unlink`, `hosts/start`, `hosts/stop`
   - `hosts/start` and `hosts/stop` get web rows, so `generated.ts` gains them.
6. **Clients (US1)**: **Start** and the phase on the offline strip on all three (Mac
   `OfflineStrip`, Remote `HostOfflineStrip`, web `OfflineStrip.tsx`), and on the Mac's Hosts
   rows. **US2**: a **Providers** page in Settings ▸ Control plane (Mac only, as Hosts are), with
   Add Provider, its workspaces, **Add as Host** (into the Add a Server sheet, prefilled) and
   **Link to Workspace…** on a host row.
7. **Later stories** (their own PRs):
   - **US3 kept requests**: the router reads a request's method only when the host is
     stopped; requests kept in `v1/kept/<host>/` and replayed over a channel of the control
     plane's own once the host connects.
   - **US4 idle**: a `host/status` notification on channel 0 from `ControlUplink`.
   - **US5 create/delete**: the control plane issues a host code for `workspace_create`'s
     first-boot command.
   - **US6 agent tools**: `AppService` tools relayed through the daemon's uplink to new control
     methods.

The MVP is US1 + US2: the command provider, providers, links, Start and Stop.

## Technical Context

**Language/Version**: Swift 6.2 (ControlPlaneKit, AgentsKit, MCPServers, Mac, Remote); TypeScript (web).

**Primary Dependencies**:
- `MCPServerKit` (#700) for the command provider.
- AgentsKit's `MCPClient` (stdio and streamable http), made reachable from ControlPlaneKit.
- `ServerInstaller` / `SSHCommand` for the ssh start, and `HostTunnels` for tunnels.
- No new packages.

**Storage**:
- Store: `v1/providers/<id>.json` (provider records), `HostRecord.workspace` (links), and later
  `v1/kept/<host>/<id>.json` (US3).
- Local, never the store: `<control home>/provider-secrets.json` (0600).

**Testing**: Swift Testing.
- `Packages/MCPServers/Tests/WorkspaceCommandsTests`: the provider in process, with commands
  such as `true`, `false` and `echo stopped`, and every preset's command lines.
- `Packages/ControlPlane/Tests/ControlPlaneKitTests`: providers, maps, links, starts. These use
  a stand-in provider (`ProviderStandIn`, in-process JSON-RPC over pipes, in the style of
  `ViewsServerStandIn`) with a fake clock and a fake host hello.
- `Web` vitest for the strip.
- Walk: the `test-servers` skill's devbox container behind the command provider's `docker` preset.

**Target Platform**:
- The control plane on macOS (Agents Host) and Linux (container).
- The command provider as a static binary on both. Shipping it beside agentsd is #700's lane,
  so this feature resolves it beside `agents-control`, then on `PATH` (R5).

**Project Type**: Control plane service + MCP server + three clients.

**Performance Goals**:
- The host is online within the provider's start time + 1 minute (SC-001).
- A list costs one call per provider every 5 minutes.
- One slow provider never delays another (a task per provider).

**Constraints**:
- Timeouts: 30 s for list and options, 10 min for start, stop, create and delete (FR-005).
- Secrets are never in the store, on the wire to clients or hosts, or in the log (FR-003).
- Bound what is held: a workspace list is cut at 200 workspaces per provider, a provider's error
  text at 1 KB, and kept requests at 20 per host.
- Providers run only on a single-copy control plane, as tunnels do (R4).
- Hosts never escalate: nothing runs as root.

**Scale/Scope**: A handful of providers and up to about twenty hosts (the control plane's size).

## Constitution Check

*Gate: must pass before Phase 0 research. Rechecked after Phase 1 design.*

| Principle | How this plan meets it | Pass |
|---|---|---|
| I. Spec-led | Spec 691 has acceptance scenarios; this plan, then tasks, then the build, story by story. | ✅ |
| II. Capability-driven | A provider is recognised by the tools it lists (and `contract` in `workspaces_list`) or by a checked tool map, never by who it is. Optional tools (create, delete, options) turn their buttons on only when offered. A provider that lacks a required tool is refused, naming it. | ✅ |
| III. Scoped access and user control | Providers are added by a person on the Mac. Create and delete ask first. Agents reach workspaces only through the control plane (US6), with make and delete through the question card. No secret leaves the control plane. | ✅ |
| IV. Inspectable | Every start, stop, create and delete, who asked and the result goes in `control.log` (FR-060). Each host row and strip shows the phase and the provider's own reason. | ✅ |
| V. Docs and quality | The six docs pages in the spec are tasks. Warnings are errors. `generated.ts` is regenerated by `scripts/web.sh types`. | ✅ |
| Constraints | The daemon stays the sole writer of agent state. The control plane writes only its own store and home. Kept requests are delivered to the daemon as ordinary requests. | ✅ |

Rechecked after Phase 1: no change. Nothing in Complexity Tracking.

## Project Structure

### Documentation (this feature)

```text
specs/691-workspace-providers/
├── spec.md
├── plan.md              # this file
├── research.md          # Phase 0: decisions R1–R12
├── data-model.md        # Phase 1: records, states, transitions
├── quickstart.md        # Phase 1: the walk
├── contracts/
│   ├── provider-contract.md    # the MCP tools a provider offers (FR-001), version 1
│   ├── tool-map.md             # a map over another server's tools (FR-001a)
│   ├── command-provider.md     # workspace-commands: config, presets, states
│   ├── control-methods.md      # providers/*, hosts/link|unlink|start|stop, ControlHost.workspace
│   └── layouts.md              # the screens, for Alex before any is built
├── checklists/requirements.md
└── tasks.md             # Phase 2 (/speckit-tasks)
```

### Source Code (repository root)

```text
Packages/MCPServers/
├── Package.swift                          # + WorkspaceCommands target, workspace-commands executable, tests
├── Sources/WorkspaceCommands/
│   ├── WorkspaceCommands.swift            # MCPServer with the contract tools
│   ├── CommandConfig.swift                # config JSON, ${id}/${name} substitution
│   └── Presets.swift                      # docker, doctl, gh codespace, coder, gcloud workstations
├── Sources/workspace-commands/main.swift
└── Tests/WorkspaceCommandsTests/

Packages/AgentsKit/Sources/
├── AgentsKitCore/Control/Grant.swift              # HostRecord.workspace, HostState + stopped/starting/stopping
├── AgentsKitCore/Control/DaemonAPI+Control.swift  # methods, ControlHost.workspace, provider wire types
├── AgentsKitCore/Control/Workspaces.swift         # new: WorkspaceLink, WorkspaceInfo, ProviderSummary, ToolMap
├── AgentsKitCore/Daemon/DaemonAPI+Web.swift       # web rows for hosts/start, hosts/stop
└── AgentsKit/MCP/MCPToolClient.swift              # new: public façade over MCPClient (connect, listTools, callTool, end)

Packages/ControlPlane/Sources/ControlPlaneKit/
├── Providers/
│   ├── ProviderSecrets.swift      # 0600 file in the control home
│   ├── ProviderConnection.swift   # one provider: contract check or tool map, calls with timeouts
│   ├── ToolMapping.swift          # contract call ↔ mapped call, result paths
│   ├── WorkspaceProviders.swift   # actor: records, lists every 5 min, last known
│   └── WorkspaceStarts.swift      # actor: one start/stop per workspace, phases, ssh start, 10 min
├── ControlMethods.swift           # + own/writes/answer for the new methods, Hooks
├── ControlRouter.swift            # HostState broadcast for new states; attach ends a start
└── ControlService.swift           # wiring (single copy only), log lines

App/Sources/
├── Chat/OfflineStrip.swift                # Start, phase, failure + Start again
├── Control/ControlSettingsView.swift      # Hosts row: state, Start/Stop, Link to Workspace…; Providers page
├── Control/ControlProvidersPage.swift     # new (US2)
├── Control/ControlAddProviderSheet.swift  # new (US2)
└── Control/ControlSettingsModel.swift     # providers/*, hosts/link|start|stop
Shared/UI/OfflineWords.swift               # starting / waiting / stopped / failed wording, shared Mac + Remote
Remote/Sources/Chat/HostOfflineStrip.swift # Start, phase
Remote/Sources/RemoteModel.swift           # startHost(_:)
Web/src/views/OfflineStrip.tsx             # Start, phase
Web/src/model/store.ts                     # startHost
Web/src/protocol/generated.ts              # regenerated
```

**Structure Decision**: The command provider is a new target beside the CI watcher, on the
shared kit, and does not depend on AgentsKit. Everything that talks to providers lives in
ControlPlaneKit, which already links AgentsKit (for `HostInstall`). Wire types go in
AgentsKitCore with the other control types, so WebTypes can see them.

## Delivery

| PR | Stories | Contents |
|---|---|---|
| 1 | — | This plan and tasks. |
| 2 | US1 + US2 (P1) | Command provider; providers, links, start/stop on the control plane; Mac Hosts + Providers; Start on all three strips; docs. "Part of #691". |
| 3 | US3 (P2) | Kept requests. |
| 4 | US4 (P2) | Idle reports and stop when idle. |
| 5 | US5 (P3) | Create and delete. |
| 6 | US6 (P3) | Agent tools. "Fixes #691". |

PR 2 may be split into 2a (command provider, `Packages/MCPServers` only) and 2b (the rest) if
2a is ready first. No screen is built before Alex has seen [its layout](contracts/layouts.md).

## Complexity Tracking

None.
