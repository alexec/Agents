# jscpd baseline report (2026-10-23)

jscpd 5.4.2 scans Swift, Go and TypeScript with a minimum of 10 lines and 70 tokens.
This report is informational. The linter does not fail CI for clones.

## Summary

- Clones: 144
- Duplicated lines across both copies: 2866
- Files scanned: 1277

| Language | Clones | Duplicated lines | Files |
|---|---:|---:|---:|
| go | 63 | 1610 | 408 |
| swift | 79 | 1220 | 749 |
| typescript | 2 | 36 | 120 |

## AppModel, RemoteModel and AgentsModel pairs

| Files | Clones | Duplicated lines |
|---|---:|---:|
| `App/Sources/AppModel.swift` ↔ `Remote/Sources/RemoteModel.swift` | 5 | 160 |
| `App/Sources/Sessions/PoppedChat.swift` ↔ `Remote/Sources/RemoteModel.swift` | 1 | 24 |

No clone was found in AgentsModel.swift.

## Clones by pair of files

| Files | Clones | Duplicated lines |
|---|---:|---:|
| `Go/internal/githubmcp/events.go` ↔ `Go/internal/gitlabmcp/events.go` | 12 | 472 |
| `App/Sources/Projects/WorkflowPage.swift` ↔ `Remote/Sources/Projects/WorkflowPage.swift` | 7 | 206 |
| `App/Sources/AppModel.swift` ↔ `Remote/Sources/RemoteModel.swift` | 5 | 160 |
| `App/Sources/MCPServers/ConnectGitHubSheet.swift` ↔ `App/Sources/MCPServers/ConnectGitLabSheet.swift` | 4 | 124 |
| `App/Sources/Spending/SpendingView.swift` ↔ `Remote/Sources/Projects/TotalsView.swift` | 4 | 102 |
| `Go/internal/githubmcp/events.go` ↔ `Go/internal/linearmcp/events.go` | 4 | 184 |
| `Go/internal/githubmcp/schema.go` ↔ `Go/internal/gitlabmcp/schema.go` | 4 | 288 |
| `App/Sources/AgentList/AgentRow.swift` ↔ `Remote/Sources/Sidebar/SidebarRows.swift` | 3 | 90 |
| `App/Sources/Projects/ProjectRow.swift` ↔ `Remote/Sources/Sidebar/ProjectRow.swift` | 3 | 106 |
| `App/Sources/Sidebar/ChangeFileView.swift` ↔ `Remote/Sources/Panes/RemoteChangeFileView.swift` | 3 | 128 |
| `Go/internal/controlplane/hostinstall/ssh.go` ↔ `Go/internal/controlplane/hosttunnels/ssh.go` | 3 | 92 |
| `Go/internal/githubmcp/github.go` ↔ `Go/internal/gitlabmcp/gitlab.go` | 3 | 164 |
| `Go/internal/githubmcp/schema.go` ↔ `Go/internal/linearmcp/events.go` | 3 | 96 |
| `App/Sources/Chat/PromptBar.swift` ↔ `Remote/Sources/Chat/PromptBar.swift` | 2 | 126 |
| `App/Sources/Notifications/MacNotifier.swift` ↔ `Remote/Sources/Notifications/DeviceNotifier.swift` | 2 | 50 |
| `App/Sources/Projects/ProjectListView.swift` ↔ `Remote/Sources/Sidebar/RemoteSidebar.swift` | 2 | 54 |
| `App/Sources/Projects/SidebarSmartRows.swift` ↔ `Remote/Sources/Sidebar/RemoteSidebar.swift` | 2 | 48 |
| `App/Sources/Walk/WalkCommands.swift` ↔ `Remote/Sources/Walk/WalkCommands.swift` | 2 | 46 |
| `App/Sources/Walk/WalkServer.swift` ↔ `Remote/Sources/Walk/WalkServer.swift` | 2 | 114 |
| `Go/internal/agentsd/relay.go` ↔ `Go/internal/controllink/pipe.go` | 2 | 64 |
| `Go/internal/controlplane/providers/records.go` ↔ `Go/internal/controlplane/records/coding.go` | 2 | 54 |
| `Go/internal/emailmcp/events.go` ↔ `Go/internal/githubmcp/schema.go` | 2 | 46 |
| `Go/internal/emailmcp/front.go` ↔ `Go/internal/githubmcp/front.go` | 2 | 276 |
| `Go/internal/githubmcp/coderabbit.go` ↔ `Go/internal/githubmcp/rest.go` | 2 | 58 |
| `Go/internal/githubmcp/rest.go` ↔ `Go/internal/gitlabmcp/rest.go` | 2 | 104 |
| `App/Sources/Chat/AccountMoveStrip.swift` ↔ `Remote/Sources/Chat/RemoteAccountMoveStrip.swift` | 1 | 24 |
| `App/Sources/Chat/ChatView.swift` ↔ `Remote/Sources/Chat/RemoteChatView.swift` | 1 | 22 |
| `App/Sources/Chat/ContinueWhenBackStrip.swift` ↔ `Remote/Sources/Chat/RemoteContinueWhenBackStrip.swift` | 1 | 24 |
| `App/Sources/Chat/DraftKeeper.swift` ↔ `Remote/Sources/StartAgent/StartDraftKeeper.swift` | 1 | 22 |
| `App/Sources/Chat/WakeListener.swift` ↔ `Shared/UI/Chat/Dictation.swift` | 1 | 60 |
| `App/Sources/ContentView.swift` ↔ `App/Sources/Projects/ProjectWindow.swift` | 1 | 22 |
| `App/Sources/Control/ControlProvidersPage.swift` ↔ `App/Sources/Control/ControlProvidersPage.swift` | 1 | 22 |
| `App/Sources/Elicitation/ElicitationView.swift` ↔ `Remote/Sources/Elicitation/FormPages.swift` | 1 | 24 |
| `App/Sources/Events/EventDetailView.swift` ↔ `Remote/Sources/Events/EventsListView.swift` | 1 | 30 |
| `App/Sources/Events/EventsView.swift` ↔ `Remote/Sources/Events/EventsListView.swift` | 1 | 34 |
| `App/Sources/MCPServers/AppModel+Connectors.swift` ↔ `Remote/Sources/MCPServers/RemoteModel+Connectors.swift` | 1 | 28 |
| `App/Sources/MCPServers/ConnectEmailSheet.swift` ↔ `Remote/Sources/MCPServers/RemoteConnectorSetup.swift` | 1 | 44 |
| `App/Sources/Permission/PermissionView.swift` ↔ `Remote/Sources/Permission/PermissionSheet.swift` | 1 | 30 |
| `App/Sources/Projects/PinnedPage.swift` ↔ `App/Sources/Sidebar/MacPageActions.swift` | 1 | 32 |
| `App/Sources/Projects/ProjectAgentsView.swift` ↔ `Remote/Sources/StartAgent/StartAgentView.swift` | 1 | 40 |
| `App/Sources/Projects/ProjectWorkRows.swift` ↔ `App/Sources/Projects/WorkflowRow.swift` | 1 | 22 |
| `App/Sources/Projects/ReviewDestination.swift` ↔ `Remote/Sources/Sidebar/RemoteReviewDestination.swift` | 1 | 22 |
| `App/Sources/Runtimes/RuntimeAccountsSection.swift` ↔ `App/Sources/Runtimes/RuntimesView.swift` | 1 | 24 |
| `App/Sources/Sessions/PoppedChat.swift` ↔ `Remote/Sources/RemoteModel.swift` | 1 | 24 |
| `App/Sources/Sidebar/FilesPane.swift` ↔ `Remote/Sources/Panes/FilesPane.swift` | 1 | 24 |
| `App/Sources/Sidebar/TerminalHostView.swift` ↔ `Remote/Sources/Panes/TerminalPane.swift` | 1 | 36 |
| `App/Sources/Worktrees/WorktreesView.swift` ↔ `Remote/Sources/Worktrees/WorktreesListView.swift` | 1 | 38 |
| `Go/internal/agentsd/connections.go` ↔ `Go/internal/agentsd/connections.go` | 1 | 22 |
| `Go/internal/agentsd/frontmatter.go` ↔ `Go/internal/agentsd/frontmatter.go` | 1 | 28 |
| `Go/internal/agentsd/mcpclient.go` ↔ `Go/internal/agentsd/mcpverify.go` | 1 | 26 |
| `Go/internal/agentsd/mcpevents.go` ↔ `Go/internal/agentsd/viewservers.go` | 1 | 22 |
| `Go/internal/agentsd/retention.go` ↔ `Go/internal/agentsd/retention.go` | 1 | 26 |
| `Go/internal/agentsd/runtimeauth.go` ↔ `Go/internal/agentsd/runtimeauth.go` | 1 | 22 |
| `Go/internal/agentsd/views.go` ↔ `Go/internal/controlplane/web/policy.go` | 1 | 28 |
| `Go/internal/agentsd/watch_darwin.go` ↔ `Go/internal/agentsd/watch_linux.go` | 1 | 24 |
| `Go/internal/controllink/exchange.go` ↔ `Go/internal/controlplane/records/types.go` | 1 | 30 |
| `Go/internal/controlplane/hostinstall/install.go` ↔ `Go/internal/controlplane/hosttunnels/ssh.go` | 1 | 40 |
| `Go/internal/emailmcp/events.go` ↔ `Go/internal/githubmcp/events.go` | 1 | 24 |
| `Go/internal/emailmcp/front.go` ↔ `Go/internal/gitlabmcp/front.go` | 1 | 332 |
| `Go/internal/emailmcp/front.go` ↔ `Go/internal/linearmcp/front.go` | 1 | 328 |
| `Go/internal/emailmcp/views.go` ↔ `Go/internal/linearmcp/views.go` | 1 | 32 |
| `Go/internal/githubmcp/github.go` ↔ `Go/internal/linearmcp/linear.go` | 1 | 42 |
| `Go/internal/githubmcp/pages.go` ↔ `Go/internal/gitlabmcp/pages.go` | 1 | 38 |
| `Go/internal/githubmcp/rest.go` ↔ `Go/internal/gitlabmcp/setup.go` | 1 | 28 |
| `Go/internal/githubmcp/views.go` ↔ `Go/internal/gitlabmcp/tools.go` | 1 | 26 |
| `Go/internal/githubmcp/views.go` ↔ `Go/internal/gitlabmcp/views.go` | 1 | 26 |
| `Go/internal/gitlabmcp/events.go` ↔ `Go/internal/linearmcp/events.go` | 1 | 102 |
| `Go/internal/gitlabmcp/schema.go` ↔ `Go/internal/linearmcp/events.go` | 1 | 54 |
| `Go/internal/workspacecommands/presets.go` ↔ `Go/internal/workspacecommands/presets.go` | 1 | 22 |
| `Host/PeerCheck/main.swift` ↔ `Packages/AgentsKit/Sources/AgentsKit/Daemon/CallerSignature.swift` | 1 | 22 |
| `Packages/AgentsKit/Sources/AgentsKit/Daemon/DaemonServer.swift` ↔ `Packages/AgentsKit/Sources/AgentsKitCore/Client/UnixSocket.swift` | 1 | 22 |
| `Packages/AgentsKit/Sources/AgentsKitCore/Model/Agent.swift` ↔ `Packages/AgentsKit/Sources/AgentsKitCore/Model/Project.swift` | 1 | 24 |
| `Packages/AgentsKit/Sources/AgentsKitCore/Model/ContentDigest.swift` ↔ `Packages/AgentsKit/Sources/AgentsKitCore/Remote/ControlAgreement.swift` | 1 | 22 |
| `Packages/AgentsKit/Sources/AgentsKitCore/Model/FrontMatter.swift` ↔ `Packages/AgentsKit/Sources/AgentsKitCore/Model/FrontMatter.swift` | 1 | 24 |
| `Packages/AgentsKit/Sources/AgentsKitCore/Model/TimeChart.swift` ↔ `Packages/AgentsKit/Sources/AgentsKitCore/Model/UsageChart.swift` | 1 | 30 |
| `Packages/AgentsKit/Sources/AgentsKitCore/Pins/Pins.swift` ↔ `Packages/AgentsKit/Sources/AgentsKitCore/Pins/PinsWire.swift` | 1 | 22 |
| `Packages/AgentsKit/Sources/AgentsKitCore/Sidebar/SidebarFolds.swift` ↔ `Packages/AgentsKit/Sources/AgentsKitCore/Sidebar/SidebarFolds.swift` | 1 | 24 |
| `Remote/Sources/Panes/ShellKeys.swift` ↔ `Shared/UI/Page/SourceEditor.swift` | 1 | 22 |
| `Shared/UI/ChartView.swift` ↔ `Shared/UI/MermaidView.swift` | 1 | 26 |
| `Shared/UI/Page/SourceEditor.swift` ↔ `Shared/UI/Page/SourceEditor.swift` | 1 | 24 |
| `Shared/UI/People/BotSheets.swift` ↔ `Shared/UI/People/GroupsPane.swift` | 1 | 22 |
| `Shared/UI/People/CapReachedCard.swift` ↔ `Shared/UI/People/JoinRequestCard.swift` | 1 | 22 |
| `Shared/UI/People/GroupsPane.swift` ↔ `Shared/UI/People/PeoplePane.swift` | 1 | 26 |
| `Shared/UI/People/JoinRequestCard.swift` ↔ `Shared/UI/SignIn/SignInRequestCard.swift` | 1 | 32 |
| `Shared/UI/TimeCharts.swift` ↔ `Shared/UI/UsageCharts.swift` | 1 | 74 |
| `Web/src/model/time.ts` ↔ `Web/src/model/usage.ts` | 1 | 50 |
| `Web/src/wire/keys.ts` ↔ `Web/src/wire/signIn.ts` | 1 | 22 |

## Ten largest clones

| Files and lines | Lines per copy | Lines across both copies |
|---|---:|---:|
| `Go/internal/emailmcp/front.go:32` ↔ `Go/internal/gitlabmcp/front.go:41` | 166 | 332 |
| `Go/internal/emailmcp/front.go:34` ↔ `Go/internal/linearmcp/front.go:30` | 164 | 328 |
| `Go/internal/emailmcp/front.go:56` ↔ `Go/internal/githubmcp/front.go:50` | 123 | 246 |
| `Go/internal/githubmcp/schema.go:71` ↔ `Go/internal/gitlabmcp/schema.go:71` | 61 | 122 |
| `Go/internal/gitlabmcp/events.go:173` ↔ `Go/internal/linearmcp/events.go:223` | 51 | 102 |
| `App/Sources/Chat/PromptBar.swift:529` ↔ `Remote/Sources/Chat/PromptBar.swift:215` | 46 | 92 |
| `Go/internal/githubmcp/events.go:192` ↔ `Go/internal/gitlabmcp/events.go:192` | 44 | 88 |
| `App/Sources/Walk/WalkServer.swift:29` ↔ `Remote/Sources/Walk/WalkServer.swift:38` | 43 | 86 |
| `Go/internal/githubmcp/events.go:151` ↔ `Go/internal/gitlabmcp/events.go:151` | 40 | 80 |
| `Go/internal/githubmcp/schema.go:3` ↔ `Go/internal/gitlabmcp/schema.go:3` | 37 | 74 |

## Notes

- `Packages/CodeText/Grammars`, `.specify`, `Web/dist`, `.build`, generated Go files, Go tests and `generated.ts` are excluded.
- A clone can be correct for platform-specific clients. Review each pair before changing it.

