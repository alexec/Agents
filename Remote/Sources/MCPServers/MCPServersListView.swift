import AgentsKitCore
import SwiftUI

/// A project's Connectors page, with its set-up first (#1336), or Your Connectors, with the
/// person's connections first. Then every MCP server in one `mcp.json` and how each is doing
/// (#753), as the window's: under Activity, the person's own on the Mac (#589); under a
/// project, its `.agents/mcp.json`.
/// Read-only but for Check Now: servers are edited in Settings.
struct MCPServersListView: View {
    @Environment(RemoteModel.self) private var model
    /// Nil for the person's own servers, on the Mac.
    var project: ProjectKey?
    @State private var checking = false
    @State private var setup: DaemonAPI.ConnectorSetup?

    private var snapshot: DaemonAPI.MCPHealthSnapshot? { model.work.mcpHealthSnapshot(project?.host ?? .mac) }

    private var servers: [DaemonAPI.MCPServerHealth] {
        guard let project else { return snapshot?.personal ?? [] }
        return model.work.mcpServers(in: project)
    }

    private var problem: String? { snapshot?.problem(in: project?.folder.path) }

    var body: some View {
        List {
            // The set-up first (#1336): a project's slots, or the person's connections.
            if let project {
                RemoteConnectorSetup(project: project, projectName: model.work.project(project)?.name
                                         ?? project.folder.lastPathComponent, setup: $setup)
            } else {
                RemoteConnections()
            }
            Section {
                if let problem {
                    Text(problem).foregroundStyle(StateTint.failure.style(or: .secondary))
                } else if servers.isEmpty {
                    Text(project == nil ? MCPHealthWords.personalEmpty : MCPHealthWords.projectEmpty)
                        .foregroundStyle(.secondary)
                }
                ForEach(servers) { MCPHealthRow(server: $0) }
                    .paperListRow()
            } header: {
                Text(project == nil ? "Your connectors" : "All connectors")
            } footer: {
                Text(project == nil ? MCPHealthWords.personalIntro : MCPHealthWords.projectIntro)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Paper.ground)
        .navigationTitle(project.flatMap { model.work.project($0)?.name }.map { "\($0): Connectors" } ?? "Your Connectors")
        .toolbar {
            Button("Check Now") {
                checking = true
                Task {
                    await model.checkMCPHealth(project: project)
                    checking = false
                }
            }
            .disabled(checking || !servers.contains { !$0.hosted })
        }
        // The servers are read with the leases.
        .shows([.leases])
    }
}

/// The way in, under Activity: a red icon when one of the person's servers does not answer.
struct MCPServersRow: View {
    @Environment(RemoteModel.self) private var model

    var body: some View {
        // The title alone (#587): the count is said to VoiceOver, and one not answering
        // turns the row's icon red (`activityIcon(_:warns:)`).
        HStack(alignment: .firstTextBaseline) {
            Text("Your Connectors")
            Spacer()
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(MCPHealthWords.tally(model.work.mcpHealthSnapshot()?.personal ?? [])?.words ?? "")
        .accessibilityHint("Opens Your Connectors")
    }
}
