import AgentsKitCore
import SwiftUI

/// Every MCP server in one `mcp.json` and how each is doing (#753): under Activity, the
/// person's own `~/.agents/mcp.json` (#589); under a project, its `.agents/mcp.json`.
///
/// A hosted server (#488) says what its one copy is doing; any other, what the host found
/// when it last checked it, and Check Now checks them again. Read-only otherwise: Settings
/// is where servers are edited.
struct MCPServersView: View {
    @Environment(AppModel.self) private var model
    /// Nil for the person's own servers, on this Mac.
    var project: ProjectKey?
    @State private var checking = false

    private var host: HostID { project?.host ?? .mac }
    private var snapshot: DaemonAPI.MCPHealthSnapshot? { model.work.mcpHealthSnapshot(host) }

    private var servers: [DaemonAPI.MCPServerHealth] {
        guard let project else { return snapshot?.personal ?? [] }
        return model.work.mcpServers(in: project)
    }

    private var problem: String? { snapshot?.problem(in: project?.folder.path) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    Text(project == nil ? MCPHealthWords.personalIntro : MCPHealthWords.projectIntro)
                        .appText(.supporting)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("Check Now") {
                        checking = true
                        Task {
                            await model.checkMCPHealth(project: project)
                            checking = false
                        }
                    }
                    .disabled(checking || !servers.contains { !$0.hosted })
                    .help("Check every connector that is not hosted again now")
                }
                if let problem {
                    Text(problem)
                        .appText(.fine)
                        .foregroundStyle(StateTint.failure.style(or: .secondary))
                        .textSelection(.enabled)
                }
                if !servers.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(Array(servers.enumerated()), id: \.element.id) { index, server in
                            if index > 0 { Divider().padding(.leading, 32) }
                            MCPHealthRow(server: server)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                        }
                    }
                    .padding(.vertical, 4)
                    .paperRaised(in: RoundedRectangle(cornerRadius: 10))
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(project.flatMap { model.work.project($0)?.name }.map { "\($0) \u{2014} Connectors" }
                         ?? "Your Connectors")
        .overlay {
            if servers.isEmpty && problem == nil {
                Text(project == nil ? MCPHealthWords.personalEmpty : MCPHealthWords.projectEmpty)
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: host) {
            await model.refreshHostedMCP()
            await model.refreshMCPHealth(host)
        }
    }
}

/// The way into MCP Servers under Activity.
struct MCPServersRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        // The title alone (#587): the count is the tooltip's, and one not answering turns
        // the row's icon red (`activityIcon(_:warns:)`).
        let words = MCPHealthWords.tally(model.work.mcpHealthSnapshot()?.personal ?? [])?.words
        HStack(alignment: .firstTextBaseline) {
            Text("Your Connectors").foregroundStyle(.primary)
            Spacer()
        }
        .help(words.map { "\($0). Every connector in your own mcp.json, and how each is doing" }
              ?? "Every connector in your own mcp.json, and how each is doing")
        .accessibilityValue(words ?? "")
    }
}
