---
description: "Tasks for #691: workspace providers through MCP"
---

# Tasks: Workspace providers through MCP

**Input**: `specs/691-workspace-providers/`: [spec.md](spec.md), [plan.md](plan.md),
[research.md](research.md) (R1–R12), [data-model.md](data-model.md), [contracts/](contracts/),
[quickstart.md](quickstart.md).

**Tests**: these are included. Each story's Independent Test and the quickstart's tests are part
of the spec, and the constitution requires the relevant checks to pass.

**Organization**: by user story, after a shared foundation.

**Abbreviations**:

| Short | Path |
|---|---|
| `MS` | `Packages/MCPServers` |
| `CK` | `Packages/AgentsKit/Sources/AgentsKitCore/Control` |
| `AK` | `Packages/AgentsKit/Sources/AgentsKit` |
| `CP` | `Packages/ControlPlane/Sources/ControlPlaneKit` |
| `CT` | `Packages/ControlPlane/Tests/ControlPlaneKitTests` |

**Verify**: everything below runs through `scripts/build-cache.sh` under the "build" lease.
- `swift test --package-path Packages/MCPServers`
- `swift test --package-path Packages/ControlPlane --filter <suites>`
- `xcodebuild` for AgentsHost (Mac) and the Remote when they change
- `scripts/web.sh test` for the web page

**Layout gate**: no task marked 🖼 starts before Alex has chosen its layout in
[contracts/layouts.md](contracts/layouts.md) (R12).

## Format: `[ID] [P?] [Story] Description`

- **[P]**: can run in parallel (different files, no dependency on unfinished tasks).
- **[Story]**: US1–US6, as in spec.md.

---

## Phase 1: Setup

- [x] T001 [P] Add a `WorkspaceCommands` library target, a `workspace-commands` executable target and a `WorkspaceCommandsTests` test target to `MS/Package.swift`.
  - All three use `treatAllWarnings(as: .error)`, as the CI watcher's targets do.
  - Nothing in them depends on AgentsKit.
- [x] T002 [P] Add `MS/Sources/workspace-commands/main.swift`.
  - `--version` prints the version and exits.
  - It reads `WORKSPACE_COMMANDS_CONFIG`, builds `WorkspaceCommands.server(config:)` and runs `StdioTransport.serve(server, name: "workspace-commands")`.
  - A bad config is written to stderr and exits 2.
- [x] T003 [P] Put the layouts in [contracts/layouts.md](contracts/layouts.md) to Alex as a question with previews (L1 strip, L2 Hosts row, L3 Providers page, L4 Add Provider sheet, L5 Link to Workspace…). Record the answers in layouts.md before any 🖼 task starts.

---

## Phase 2: Foundational (blocks US1 and US2)

### The command provider (contracts/command-provider.md)

- [x] T004 [P] `MS/Sources/WorkspaceCommands/CommandConfig.swift`: decode the configuration's three shapes: `workspaces` (written out), `list` + `columns` (many from one entry), and `preset` + parameters.
  - `id` defaults to `name`.
  - `${name}` substitution quotes each value for `/bin/sh` (a single-quote wrap, with `'` escaped).
  - The `states` map is matched case-insensitively after trimming whitespace.
  - Any state outside "`running` | `starting` | `stopping` | `stopped` | `unknown`" is read as `unknown`.
- [x] T005 [P] `MS/Sources/WorkspaceCommands/Presets.swift`: the presets `docker`, `doctl`, `codespaces`, `coder` and `gcloud-workstations`, with the commands and state words in the contract's table. Each expands to a `CommandConfig`, and none uses `sudo`.
- [x] T006 `MS/Sources/WorkspaceCommands/WorkspaceCommands.swift`: `server(config:environment:)` returns an `MCPServer` with the contract's tools.
  - **Tools**: `workspaces_list`, `workspace_start` and `workspace_stop`, plus `workspace_create`, `workspace_delete` and `workspace_options` only when the config has them.
  - **Results**: `ToolResult.structured`; failures are `ToolResult.error`.
  - **Running commands**: each runs through `ChildProcess.run(URL(filePath: "/bin/sh"), ["-c", line], environment:)`. Timeouts are 25 s for status and list and 595 s for start, stop, create and delete.
  - **Start and stop**: they run the command, then poll `status` every 5 s until it reports the target state.
  - **Failure text**: the last 20 lines of stderr (or stdout), cut at 1 KB. Exit 127 becomes "‹cli› isn't installed where the control plane runs".
  - **List**: at most 200 workspaces, and `contract: 1`.
  - **Logging**: each command line is logged to stderr before substitution. The environment is never logged.
- [x] T007 [P] `MS/Tests/WorkspaceCommandsTests/CommandConfigTests.swift`:
  - decoding each shape
  - quoting (`${name}` holding `'; rm -rf /`)
  - mapping states
  - every preset's exact command lines, as strings
  - no preset containing `sudo`
- [x] T008 `MS/Tests/WorkspaceCommandsTests/WorkspaceCommandsTests.swift` (with T007's tests in the same file): drive the server in process through `JSONRPC.answer`.
  - `workspaces_list` with `status: "echo stopped"`.
  - `workspace_start` with `true` / `false` / `exit 127`, and a status that flips after a file appears.
  - A timeout, using a short deadline seam.
  - `list` + `columns`.
  - A secret env var reaching a command without being logged.
  - `tools/list` shows create, delete and options only when they are configured.
- [x] T009 [P] Update `MS/README.md`: a `WorkspaceCommands` / `workspace-commands` row, and a short section with the quickstart §1 example.

### Wire types and the control plane's MCP client

- [x] T010 [P] `CK/Workspaces.swift`:
  - `ProviderID`
  - `ProviderRecord`. The validation rules are: "`name` not empty, ≤ 60 characters; `stdio` has a command; `http` URL is `http(s)://`; every `${X}` in headers or commands is in `secretNames`".
  - `WorkspaceInfo`. Its state is "`running` | `starting` | `stopping` | `stopped` | `unknown`"; `cost` is at most 120 characters.
  - `WorkspaceList`, holding at most 200 workspaces.
  - `ToolMap`, with paths parsed per [contracts/tool-map.md](contracts/tool-map.md).
  - `HostWorkspace` and `ProviderSummary`, all `Codable, Sendable, Hashable`.
- [x] T011 `CK/Grant.swift` (as built: `HostState` unchanged; the router lays the workspace over it, data-model.md):
  - `HostRecord.workspace: WorkspaceLink?` with `startWhenUsed` (default true) and `stopWhenIdleMinutes` (default 30, nil off). It must decode records that don't have it.
  - `HostState` gains `stopped(since:by:)`, `starting(phase:since:)` and `stopping(since:)`, with `StopCause` and `StartPhase`.
  - Update every exhaustive `switch` over `HostState` across the repo, including `ControlRouter.describe` and the Mac's `HostSet`.
- [x] T012 `CK/DaemonAPI+Control.swift`:
  - The method names `providers/list|add|update|remove|refresh`, `hosts/link|unlink|setWorkspaceOptions|start|stop`, and `control/providersChanged`.
  - The request structs.
  - `ControlHost.workspace` and `ControlHostChanged.workspace`.
  - The state doc comment lists the three new strings.
- [x] T013 Add `Packages/AgentsKit/Sources/AgentsKitCore/Daemon/DaemonAPI+Web.swift` rows for `hosts/start` and `hosts/stop` (`.controlRequest`). Run `scripts/web.sh types` and commit `Web/src/protocol/generated.ts`.
- [x] T014 `AK/MCP/MCPToolClient.swift`: a public façade over `MCPClient` with `init(server:cwd:log:)`, `connect()`, `listTools() -> [String]`, `callTool(_:arguments:timeout:) -> JSONValue` and `end()`.
  - In `AK/MCP/MCPClient.swift`, `request` gains an optional per-call `timeout` that overrides the client's own.
  - Tests go in `Packages/AgentsKit/Tests/AgentsKitTests/MCPToolClientTests.swift`, against the existing stdio stand-in.

### Providers on the control plane

- [x] T015 [P] `CP/Providers/ProviderSecrets.swift`: read and write `<home>/provider-secrets.json` with mode 0600, created atomically. It has `set(provider:secrets:)`, `values(provider:)` and `remove(provider:)`.
  - The values have no `description`, and no `CustomStringConvertible` that shows them.
- [x] T016 [P] `CP/Providers/ToolMapping.swift`:
  - Evaluate paths (`a.b[0]`, `items[]`) against `structuredContent`, or against the text content parsed as JSON.
  - Templates (`{path}`, `{id}`).
  - `check(map:tools:)` names the first missing tool.
  - `workspaces(from:map:)` drops items that have no id or name.
- [x] T017 `CP/Providers/ProviderConnection.swift`: one provider.
  - It builds an `MCPServer` from the record: `commands` resolves `workspace-commands` beside `agents-control`, then `AGENTS_WORKSPACE_COMMANDS`, then `PATH` (R5), and passes `WORKSPACE_COMMANDS_CONFIG` plus the secrets as environment. `stdio` gets the secrets as env. `http` substitutes `${X}` in its headers.
  - `check()` follows R2: the required tools or the map, and `contract: 1`. The refusal text names what is missing.
  - `list()` has a 30 s timeout.
  - `start(id)`, `stop(id)`, `create`, `delete` and `options` have a 10 min timeout.
  - `isError` text is cut at 1 KB.
  - It reconnects once when the connection has died.
- [x] T018 `CP/Providers/WorkspaceProviders.swift`: an actor that holds the records (store `v1/providers/<id>.json`, with conditional writes as `ControlRecords` does) and a `ProviderConnection` per provider.
  - It lists every provider when it starts, every 5 min, and on `refresh`, with one task per provider so a slow one never blocks another.
  - A failed list keeps the last one, with `current = false` and `problem` set.
  - Each change is broadcast as `control/providersChanged`.
  - It exposes `summaries()`, `add`, `update`, `remove`, `workspace(provider:id:)` and `linkedHost(provider:workspace:)`.
- [x] T019 [P] `CT/Support/ProviderStandIn.swift` (as built: `StandInProvider` in `CT/WorkspaceProvidersTests.swift`, behind the `WorkspaceProvider` protocol, plus a suite that runs the real binary when `AGENTS_WORKSPACE_COMMANDS` names it): an in-process provider for control-plane tests.
  - It is `MCPServerKit`-free JSON-RPC over a pipe pair, or the real `WorkspaceCommands.server` if CT may depend on MS. Decide in T019, and prefer the stand-in so ControlPlane doesn't depend on MCPServers.
  - It has scripted workspaces, states, failures and delays.
- [x] T020 `CT/WorkspaceProvidersTests.swift`:
  - add/check refusals: a missing tool named, a map naming a missing tool, an unknown contract version
  - list on refresh, and a list failure keeping the last list
  - secrets not in the store or in a `ProviderSummary`, and the file mode 0600
  - remove

**Checkpoint**: the command provider passes its tests, and providers can be added and listed from a test.

---

## Phase 3: User Story 2 – Add a provider and link workspaces (P1) 🎯 MVP

US2 comes before US1 because Start needs a link.

**Goal**: Settings ▸ Control plane ▸ Providers adds a provider, lists its workspaces, and links one to a host or adds it as a host.

**Independent test**: add the docker preset over the devbox container. It lists `agents-devbox`. Link it to `devbox`, or Add as Host.

- [x] T021 [US2] `CP/ControlMethods.swift`:
  - Answer `providers/list|add|update|remove|refresh` and `hosts/link|unlink|setWorkspaceOptions` through new `Hooks` (`providers`), and add them to `own` and `writes`.
  - `hosts/link` moves an existing link to the new host (one host per workspace), and saves through `ControlRecords.save`.
  - Removing a provider leaves hosts linked to a missing provider. `hostList()` drops such a link from the wire.
- [x] T022 [US2] `CP/ControlService.swift`: make `WorkspaceProviders` only when `mesh == nil`. Otherwise the methods answer `providersNeedOneCopy` (R4). Wire the hooks, start the lists, and write log lines of the form "provider: added …" (contracts/control-methods.md).
- [x] T023 [US2] `CP/ControlMethods.swift` `hostList()` and `ControlRouter.describe`: fill `ControlHost.workspace` from the link and the last list, as `HostWorkspace`, with `canStart` and `canStop` from the states. A linked offline host whose workspace is stopped reports `state: "stopped"`.
- [x] T024 [P] [US2] `CT/WorkspaceLinkTests.swift`:
  - link and unlink
  - a link moving to another host
  - a link surviving a restart (a new service on the same `MemoryStore`)
  - removing a provider leaving the host without `workspace`
  - a stopped workspace giving `state: "stopped"` in `hosts/list`
  - a mesh refusing
- [x] T025 [US2] 🖼 `App/Sources/Control/ControlSettingsModel.swift`: `providers`, `refreshProviders()`, `addProvider(...)`, `updateProvider`, `removeProvider`, `link(host:provider:workspace:)`, `unlink` and `setWorkspaceOptions`. Listen for `control/providersChanged`.
- [x] T026 [US2] 🖼 Add `ControlPage.providers` in `App/Sources/Control/ControlSettingsView.swift`, and make `App/Sources/Control/ControlProvidersPage.swift` per the chosen L3: a card per provider with its workspaces, Add as Host…, Refresh, and the `···` menu.
- [x] T027 [US2] 🖼 `App/Sources/Control/ControlAddProviderSheet.swift` per the chosen L4:
  - Kind: Commands (preset or custom), MCP server command, or MCP server URL.
  - Tool map: shipped, or edited by hand.
  - Secrets are entered once and never shown again.
  - The refusal text shows inline.
- [x] T028 [US2] 🖼 `App/Sources/Control/ControlSettingsView.swift` `ControlHostsPage`, per the chosen L2/L5:
  - **Link to Workspace…** as a sheet (`App/Sources/Control/LinkWorkspaceSheet.swift`).
  - **Unlink**.
  - **Add as Host…** opens `ControlAddServerSheet` with its destination and tunnel filled in, and with `link` set so it calls `hosts/link` once the host joins.
- [x] T029 [P] [US2] Ship the DigitalOcean tool map (FR-072) in `CK/ShippedToolMaps.swift`, once its server's tool names have been checked (`npx @digitalocean/mcp` `tools/list` without a token). If it has no power on/off, ship no map, and make `doctl` the DigitalOcean example in the docs. Test that the map passes `ToolMapping.check` against the recorded tool list.

**Checkpoint**: a provider can be added on the Mac and its workspace linked.

---

## Phase 4: User Story 1 – Start a stopped workspace (P1) 🎯 MVP

**Goal**: **Start** on a linked stopped host starts its workspace, shows the phases on every client, and the host comes online.

**Independent test**: quickstart §3 and §4.

- [x] T030 [US1] `CP/Providers/WorkspaceStarts.swift`: an actor with one task per workspace (R8). A second `start` joins the task in flight.
  - **Phases**: broadcast `.starting(.provider)`, then `workspace_start`, refresh the list, then `.starting(.connecting)` and wait for the host's attach.
  - **Tunnel**: open it at once when the host has one (`HostTunnels.add`/`reconcile`).
  - **ssh start**: if the host hasn't attached after 2 min and the workspace has `ssh`, broadcast `.starting(.sshStart)` and run `ServerInstaller.startDaemon` over `SSHCommand` with `HostInstall.options` (no reinstall, no sudo).
  - **Fail**: at 10 min, or on the provider's error, return to stopped or offline with `problem` set.
  - **Stop**: `stop` runs `.stopping`, then `workspace_stop`, then `.stopped(by: .person)`.
  - Time comes through an injected clock.
- [x] T031 [US1] `CP/ControlRouter.swift`: `attachHost` ends a start that is waiting on the host. `setState` takes the new states. `offlineUnlessBack` gives `.stopped` instead of `.offline` for a host whose linked workspace is listed stopped.
- [x] T032 [US1] `CP/ControlMethods.swift`: `hosts/start` and `hosts/stop` answer at once with the host's row. `notLinked` and `providerGone` are errors. Add them to `own` and `writes`. `CP/ControlService.swift` wires `WorkspaceStarts`, and logs per FR-060 (who asked: the client id).
- [x] T033 [P] [US1] `CT/WorkspaceStartsTests.swift`, with the stand-in and a fake clock:
  - start → connecting → attach → online
  - two starts make one provider call
  - a provider error shows its words and allows Start again
  - 2 min tries the ssh start (a fake `SSHCommand` runner)
  - 10 min fails
  - stop
  - a start for an unlinked host is refused
  - the log line has no secret
- [x] T034 [US1] 🖼 `Shared/UI/OfflineWords.swift`: the words for stopped, stopped by Agents, the three starting phases, and couldn't start, per the chosen L1.
- [x] T035 [US1] 🖼 Mac: `App/Sources/Chat/OfflineStrip.swift` and `App/Sources/Hosts/HostSet.swift`.
  - `HostSet` reads `ControlHost.workspace` and the new states from `syncControlHosts` and `control/hostChanged`.
  - The strip shows **Start**, the phase with a timer counting up, and the failure.
  - Add `AppModel.startHost(_:)` (`hosts/start`).
- [x] T036 [US1] 🖼 Mac Hosts row, per L2: the state line, then **Start** or **Stop**, then the `···` menu, in `App/Sources/Control/ControlSettingsView.swift`. Stop confirms when the host has running turns (the names come with US4; until then the refusal's list is empty).
- [x] T037 [P] [US1] 🖼 Remote: `Remote/Sources/Chat/HostOfflineStrip.swift` gets **Start** and the phase. `Remote/Sources/RemoteModel.swift` gets `startHost(_:)` and reads `workspace` from `hosts/list` and `control/hostChanged`.
- [x] T038 [P] [US1] 🖼 Web: `Web/src/views/OfflineStrip.tsx` gets **Start**, the phase and the failure (the same words as `OfflineWords`). `Web/src/model/store.ts` gets `startHost(host)` and keeps `workspace` from `takeHosts` and `control/hostChanged`. Add a test in `Web/src/views/OfflineStrip.test.tsx`.
- [x] T039 [US1] Walk quickstart §2–§5 on a scratch set-up (the `run-app` + `test-servers` skills), with a screenshot of each strip phase on the Mac and the web page. (As walked: the control plane half live, by `Walk691LiveTests` on the devbox, in `walks/us1-us2.md`; the screens are left for a scratch window, `needs-walk`.)

**Checkpoint**: the MVP. PR 2 lands with "Part of #691".

---

## Phase 5: User Story 3 – Start a workspace by using it (P2)

**Goal**: a prompt or an agent start for a stopped host is kept, starts it, and is delivered once it is up.

- [x] T040 [US3] Confirm the method names that are kept (the prompt send and the agent starts) and their idempotence keys, in `CK/DaemonAPI.swift`. Record them in research.md R9.
- [x] T041 [US3] `CP/Providers/KeptRequests.swift`: store `v1/kept/<host>/<seq>.json` ("at most 20 per host"; past that, refused with "‹host› is starting; too many prompts are waiting"), with `keep`, `drop`, `pending(host)` and `deliver`.
- [x] T042 [US3] `CP/ControlRouter.swift`: for a host that is stopped or starting, with `startWhenUsed`, peek at the method of a client line. Keep a kept method, answer `{kept}`, and start the workspace. Refuse everything else as today, with the stopped wording (FR-022). On attach, open a `.kept` channel and replay in order.
- [x] T043 [US3] `hosts/dropKept` and `control/keptChanged`. A failed start marks the kept requests as not sent, with the reason.
- [x] T044 [P] [US3] `CT/KeptRequestsTests.swift`:
  - a kept send is delivered once after attach, and survives a restart
  - × drops it
  - the limit of 20
  - a read never starts the host
  - with start when used off, a request is refused
- [x] T045 [US3] 🖼 Clients (L6): a kept prompt as a queued bubble with "Waiting for ‹host› to start" and ×, in `Shared/UI` (Mac + Remote) and `Web/src/views/Chat.tsx`. A failed send shows Try Again.

## Phase 6: User Story 4 – Stop a workspace when idle (P2)

- [x] T046 [US4] `AK/Daemon/ControlUplink.swift`: send `host/status {idle, since, running: [agent names]}` on channel 0 when the host's idleness changes. Idle uses `hasWorkInFlight`, `isHoldingAgents` and open shells.
- [x] T047 [US4] `CP/ControlMethods.swift` `hostSaid`: keep idleness per host. `CP/Providers/IdleStops.swift` keeps one timer per linked host with `stopWhenIdleMinutes`, cancelled by `idle: false`. When it fires, it calls `WorkspaceStarts.stop(by: .agentsIdle(minutes))`.
- [x] T048 [P] [US4] `CT/IdleStopsTests.swift`:
  - idle for the whole period stops the host
  - a turn in between resets the period
  - an older host that sends no status is never stopped
  - Stop with running turns needs a confirmation
- [x] T049 [US4] 🖼 The Mac Hosts row warns about scheduled workflows on a host that stops when idle. The Stop confirmation names the running agents.

## Phase 7: User Story 5 – Make a new workspace (P3)

- [x] T050 [US5] `providers/options`, `providers/create` and `hosts/deleteWorkspace`. For create, issue a host code (`ControlCodes.issue`) and pass `HostInstallScript.command(...)` as `firstBoot`. When `firstBootRuns` is false, install over ssh through `HostInstall`. Link the host once it joins.
- [x] T051 [US5] Add create, delete and options to the command provider's config and to `ToolMapping`.
- [x] T052 [P] [US5] Tests: create that runs on first boot and joins; create with an ssh install; delete removes the host; cancel makes nothing.
- [x] T053 [US5] 🖼 Mac: the New Workspace… form drawn from the schema, a confirmation naming the cost, and Delete Workspace… with its confirmation.

## Phase 8: User Story 6 – Agents use workspaces (P3)

- [x] T054 [US6] `AK/ACP/Serve/AppService.swift`: the tools `list_workspaces`, `start_workspace`, `stop_workspace`, `make_workspace` and `delete_workspace`, relayed through `AppService+Relay.swift` to the daemon, then over `ControlUplink` to the control methods. Make and delete go through `askForm` first.
- [x] T055 [P] [US6] Tests: the tools are listed; make asks before calling; secrets never appear in results.
- [x] T056 [US6] `docs/reference/agent-tools.md`: the workspace tools, and which of them ask first.

---

## Phase 9: Polish and cross-cutting

- [x] T057 [P] `docs/reference/workspace-providers.md`, from [contracts/provider-contract.md](contracts/provider-contract.md) and the first-boot install.
- [x] T058 [P] `docs/how-to/start-workspaces-from-agents.md`: add a provider, link a host, Start, Start when used, Stop when idle, with the command provider first.
- [x] T059 [P] `docs/how-to/add-a-workspace-provider.md`: a preset or your own commands, a map (the DigitalOcean example), and a server that follows the contract.
- [x] T060 [P] `docs/how-to/add-a-server.md` (adding from a provider's workspace) and `docs/explanation/control-plane.md` (providers run on the control plane; kept requests; the new host states).
- [x] T061 `specs/071-web-remote/walks/parity.md`: the rows in layouts.md L7, and row l.347 changed (the Remote and the page gain a **Start** button for a linked host).
- [ ] T062 Search for secrets across the store, logs and wire in a walk (quickstart §5, SC-005).

---

## Dependencies

- **Phase 1** → **Phase 2**. T001–T009 (the command provider) don't depend on T010–T020 (the control plane) and can run alongside them.
- **US2** needs Phase 2. **US1** needs US2's link (T021–T023).
- Every 🖼 task needs T003's answers.
- **US3** and **US4** need US1's `WorkspaceStarts`. **US5** needs US2. **US6** needs US1 and US2.
- **Docs**: T057–T060 land with the PR whose behaviour they describe. T057–T060 land in PR 2 for what US1 and US2 do, and the later PRs add their parts.

## Parallel examples

- **Phase 2**: T004, T005, T010, T015, T016 and T019 together; then T006 and T017.
- **US1**: once T030–T032 are in, T037 (Remote) and T038 (web) alongside T035 (Mac).

## Implementation strategy

1. **PR 1**: plan and tasks (this).
2. **PR 2** (MVP, "Part of #691"): Phase 1, Phase 2, US2 and US1, plus the docs for them. It may land as 2a (T001–T009, `Packages/MCPServers` only) and then 2b.
3. **PRs 3–6**: US3, US4, US5 and US6, each "Part of #691", the last "Fixes #691".
