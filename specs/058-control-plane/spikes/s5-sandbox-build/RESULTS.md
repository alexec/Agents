# S5: the sandboxed Mac window, what fails to build (T025)

Base: `agents/control-plane` at 53fc1e5e. Scratch worktree only; nothing committed or run.

## Setup
- `project.yml`, the Agents target: `AgentsKit` changed to `AgentsKitCore`; SwiftTerm and CodeText kept. Removed: `agentsd` and `agents-bridge` embedding (`Contents/Helpers`), `Resources/servers`, `Resources/toolsets`, and `Contents/Library/LaunchAgents`, whose plists point into Helpers.
- `App/Agents.entitlements`: `app-sandbox`, `network.client`, `files.user-selected.read-only` and `device.audio-input`.
- In all 95 app and Shared/UI files, `import AgentsKit` became `import AgentsKitCore`. Without that, the first build stops on one "Unable to resolve module" error.
- **Tooling:** by default Xcode cancels the remaining compile batches after the first failure, which hid about half the errors in passes 2–6. Pass 7 onward added `-IDEBuildingContinueBuildingAfterErrors=YES` to the given command, and `-continue-building-after-errors` to OTHER_SWIFT_FLAGS. Use both when you work through T049.

## Iteration log
| # | Change | Errors |
|---|---|---|
| 1 | as above, imports unchanged | 1 (module) |
| 2 | imports swapped | 139 (truncated) |
| 3 | pure types copied into the app; HostSet, AddServerFlow/Sheet, SignInRelays, LocalServices excluded | 60 (truncated) |
| 4–6 | `let hosts` removed from AppModel, `DaemonClient()` → Unreachable | 20–32 (truncated) |
| 7 | continue-after-errors on | 114 |
| **8** | **clean baseline, imports swapped only** | **271 in 37 files** (`pass1-baseline.errors`) |
| 9–10 | pass 3+4 changes again, plus DirectoryReader | **107 in 24 files** (`pass2-after-moves.errors`) |

**48 files fail in total**: 37 in the baseline, plus 11 hidden behind `HostSet` (they only show once `model.hosts` is gone). Every copied candidate type compiled against Core alone. There are no `Process(` calls in App/Sources.

## Classified table
a = a daemon or host RPC exists or is planned (R12); b = needs a new host method; c = type move to Core only; d = other.

| File(s) | Symbols | Class | Destination |
|---|---|---|---|
| Hosts/HostSet, AddServerFlow, AddServerSheet, RebuiltServerSheet | ServerConnection, HostKeyCheck, HostStore, SSHCommand, ServerInstaller, ServerReachability, ServerBinary/ServerBinaries | a | Out of the window; the control plane's `hosts/install`/`hosts/*` |
| **`model.hosts` users**: AppModel (24 sites: `hosts.client`, `isOffline`, `hosts.hosts.all` loops), ChatView, PromptBar, OfflineStrip, AgentsCommands, HostHeading, Lending, RemoteFolderSheet, ProjectAgentsView, ProjectSettingsSheet, ProjectListView, WorkflowPage, FilesPane, MacPageActions, CloneSheet, ServersSettingsView, ContentView (`$model.hosts.rebuiltAsk`), ArchiveSettingsView, CostSettingsView | HostSet | a | Route through `controlHosts` / ControlLink only; Settings ▸ Servers becomes the control plane's Hosts pane |
| Hosts/SignInRelays, Lending, ServersSettingsView, AppModel 1465/1471 | MacSignInRelay, RelayCertificates, MacSignInSource, ClaudeKeychainSignIn, CodexFileSignIn, `SignInRelays.canRelay` | a | Mac host (T091); the window asks the host whether it can relay |
| Control/LocalServices, FirstRunView, ControlSettingsModel (`restartControlPlane`), MoveAcross | LocalServices, DaemonCommandLine, ControlPlane, ControlMove, SMAppService | a | Host app (T055); the move across runs in the host |
| Control/ControlConfig | `ControlPlane.chosenRoot/clientSocket`, `connectUnixSocket`, `Daemon.platform/version`, `.local` endpoint, `runHostHere` | a | Remote endpoint only (T050); Run a Host Here moves to the host app |
| AppModel 400, ControlConfig 108 | `DaemonClient()` (SocketLink default) | a | Gone (T049/T050) |
| AppModel 1248–1251 | `DaemonLock`, `StoreLocations.lock` | a | Gone with the move across |
| Sidebar/FilesPane, ImageFile | DirectoryReader, FolderWatch, `FileProbe.read` | a | `files/list`, `files/watch`, `files/read` (these exist) |
| Projects/CloneSheet | `DaemonCore.defaultCloneParent()` (the host's home) | b | Host reports its clone parent (host info or `files/stat`) |
| Control/ThisMacHost, ControlSettingsModel, ControlSettingsView, FirstRunView | MachineID | d | `gethostuuid` may be refused in the sandbox; verify at runtime, or match via IOPlatformUUID or host-reported identity |
| Hosts/WindowFiles | StoreLocations (+ moves files out of the host root) | a/d | Container only; the migration step goes |
| Settings/ServerCredentials, CredentialRow, Pool/AddCreditSheet | CredentialStore, CredentialCheck | c | Core (the keychain is allowed) |
| Catalog/AddMCPSheet, RemoveMCPServerSheet, SetSecretSheet, Projects/ProjectMCPSection | MCPCatalogWords | c | Core |
| Sidebar/BrowserPane | BrowserPolicy | c | Core |
| Projects/WorkflowPage, WorkflowRow | `WorkflowFile.url(for:in:)` (path only) | c | Split the path helper into Core |
| Control/ConnectSheet | `ControlNet.serviceType` | c | Constant into Core |
| Chat/DraftKeeper, ThinkingDisplay, Settings/AppearanceSettingsView, AgentRuntimesSettingsView, Runtimes/InstallAgentsSheet, ProjectListView | StoreLocations (`isStandard`, `name`, `.tools`) | c + a | A small Core "window scope" (root name/isStandard); `.tools` comes from the host |

## Types to move to AgentsKitCore
- `CredentialStore`, `CredentialCheck` (AgentsKit/Credentials).
- `MCPCatalogWords` (AgentsKit/Daemon/DaemonCore+MCPCatalog.swift, to its own file).
- `BrowserPolicy` (AgentsKit/Files).
- The `FileProbe` value type, with `read` staying in AgentsKit (AgentsKit/Files).
- `WorkflowFile.url/folder/fileExtension`, split out of AgentsKit/Workflows/WorkflowFile.swift.
- `ControlNet.serviceType` (AgentsKit/Control/ControlNet.swift).
- A window-scope part of `StoreLocations`: root, name, isStandard (AgentsKit/Store/StoreLocations.swift).
- `MachineID`, only if the sandbox allows `gethostuuid`.

## What compiling does not catch (runtime sandbox failures)
These compile against Core and would fail silently:
- `FileManager` / `contentsOf` in AppModel (textFile/pathIsThere), Config/AgentsSetup.swift (reads, writes and lists AGENTS.md: **not in T047**), ProjectRow (`homeDirectoryForCurrentUser` becomes the container), ImageFile, MacPageActions, OpenElsewhere, BackgroundPane, AgentRow, ProjectSettingsSheet, AppCheckout (harmless).
- `NSWorkspace` on paths in 16 files, including **PluginsSection, SharedSettingsView, AgentsSetup and ChatView's open location, which are not in T048**.
- The PresenceReporter `dlsym`.

## Adjusting T044–T053
- **New T044a** (small, about half a day): the Core moves listed above.
- **T049 is the big one.** Split it:
  - **T049a:** AppModel routes every host through `controlHosts` (about 26 sites) and drops `DaemonClient()`/DaemonLock.
  - **T049b:** retire the ssh servers UI (ServersSettingsView, AddServer*, RebuiltServerSheet, Lending, HostHeading, RemoteFolderSheet, OfflineStrip) in favour of the control-plane Hosts pane, and fix about 12 `model.hosts` view users.
  - **T049c:** ControlConfig goes remote-only; LocalServices, MoveAcross and FirstRun "run here" go to the host app.
  - Together this is roughly 3× the current T049.
- **T047:** add AgentsSetup.swift, ProjectRow, ImageFile and MacPageActions, plus CloneSheet's clone parent (a new host field, class b). SharedSkillsPage no longer exists, and SharedInstructionsPage has no direct disk read.
- **T048:** add PluginsSection, SharedSettingsView, AgentsSetup and ChatView.
- **T044/T090:** add a grep gate for `FileManager|NSWorkspace|contentsOf` under AGENTS_STORE, because the Core-only link catches `Process` but not disk access.
- **T052:** unchanged. **T053:** add a runtime check of `MachineID` in the sandbox.
