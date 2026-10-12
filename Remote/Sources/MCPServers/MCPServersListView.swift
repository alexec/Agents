import AgentsKitCore
import SwiftUI

/// Every MCP server in one `mcp.json` and how each is doing (#753), as the window's: under
/// Activity, the person's own on the Mac (#589); under a project, its `.agents/mcp.json`.
/// Read-only but for Check Now: servers are edited in Settings.
struct MCPServersListView: View {
    @Environment(RemoteModel.self) private var model
    /// Nil for the person's own servers, on the Mac.
    var project: ProjectKey?
    @State private var checking = false

    private var snapshot: DaemonAPI.MCPHealthSnapshot? { model.work.mcpHealthSnapshot(project?.host ?? .mac) }

    private var servers: [DaemonAPI.MCPServerHealth] {
        guard let project else { return snapshot?.personal ?? [] }
        return model.work.mcpServers(in: project)
    }

    private var problem: String? { snapshot?.problem(in: project?.folder.path) }

    var body: some View {
        List {
            Section {
                if let problem {
                    Text(problem).foregroundStyle(StateTint.failure.style(or: .secondary))
                } else if servers.isEmpty {
                    Text(project == nil ? MCPHealthWords.personalEmpty : MCPHealthWords.projectEmpty)
                        .foregroundStyle(.secondary)
                }
                ForEach(servers) { MCPHealthRow(server: $0) }
                    .paperListRow()
            } footer: {
                Text(project == nil ? MCPHealthWords.personalIntro : MCPHealthWords.projectIntro)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Paper.ground)
        .navigationTitle(project.flatMap { model.work.project($0)?.name }.map { "\($0): MCP Servers" } ?? "MCP Servers")
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
            Text("MCP Servers")
            Spacer()
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(MCPHealthWords.tally(model.work.mcpHealthSnapshot()?.personal ?? [])?.words ?? "")
        .accessibilityHint("Opens MCP Servers")
    }
}
