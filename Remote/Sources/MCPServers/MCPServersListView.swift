import AgentsKitCore
import SwiftUI

/// A project's Connectors page, with its set-up first (#1336), or Your Connectors, with the
/// person's connections first. Then every MCP server in one `mcp.json` and how each is doing
/// (#753), as the window's: under Activity, the person's own on the Mac (#589); under a
/// project, its `.agents/mcp.json`.
/// Read-only but for Check Now: servers are edited in Settings.
struct MCPServersListView: View {
    @Environment(RemoteModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    /// Nil for the person's own servers, on the Mac.
    var project: ProjectKey?
    @State private var checking = false
    @State private var setup: DaemonAPI.ConnectorSetup?
    @State private var connections: [DaemonAPI.Connection]?
    /// Why the set-up or the connections did not read.
    @State private var setupProblem: String?

    private var snapshot: DaemonAPI.MCPHealthSnapshot? { model.work.mcpHealthSnapshot(project?.host ?? .mac) }

    private var servers: [DaemonAPI.MCPServerHealth] {
        guard let project else { return snapshot?.personal ?? [] }
        return model.work.mcpServers(in: project)
    }

    private var problem: String? { snapshot?.problem(in: project?.folder.path) }

    var body: some View {
        List {
            // The set-up first (#1336): a project's slots, or the person's connections; neither
            // on a host too old to have them (#1748).
            if let project, model.host(project.host, has: Capability.connectorsSetup1) {
                RemoteConnectorSetup(project: project, projectName: model.work.project(project)?.name
                                         ?? project.folder.lastPathComponent, setup: $setup,
                                     problem: setupProblem, reload: readSetUp)
            } else if project == nil, model.host(.mac, has: Capability.connections1) {
                RemoteConnections(connections: connections, problem: $setupProblem, reload: { await readSetUp(.cached) })
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
        .task(id: project) { await readSetUp(.cached) }
        // Back from github.com (an install, a grant): read again, as the window does (#1684).
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await readSetUp(.cached) } }
        }
        // A pull reads each slot again from the provider, as Try Again does.
        .refreshable { await readSetUp(.fresh) }
    }

    /// A project's set-up, or the person's connections.
    private func readSetUp(_ how: DaemonAPI.ConnectorSetupReading) async {
        if let project {
            guard model.host(project.host, has: Capability.connectorsSetup1) else { return }
            switch await model.connectorSetup(project, reading: how) {
            case .success(let fresh): setup = fresh; setupProblem = nil
            case .failure(let failure): setupProblem = failure.words
            }
        } else {
            guard model.host(.mac, has: Capability.connections1) else { return }
            switch await model.connections(on: .mac) {
            case .success(let list): connections = list; setupProblem = nil
            case .failure(let failure): connections = connections ?? []; setupProblem = failure.words
            }
        }
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
