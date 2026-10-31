import AgentsKitCore
import SwiftUI

/// A folder's Connectors page, with its set-up first (#1336), or the person's own Connectors page, with
/// their connections first. Then every MCP server in one `mcp.json` and how each is doing
/// (#753): under Activity, the person's own `~/.agents/mcp.json` (#589); under a folder, its
/// `.agents/mcp.json`.
///
/// A hosted server (#488) says what its one copy is doing; any other, what the host found
/// when it last checked it, and Check Now checks them again. Add Connector… opens the
/// catalogue, and a row's Remove… takes it out (#2154); Settings is where servers are edited.
struct MCPServersView: View {
    @Environment(AppModel.self) private var model
    /// Nil for the person's own servers, on this Mac.
    var folder: FolderKey?
    @State private var checking = false
    @State private var adding = false
    /// The connector Remove… asks about (#2154).
    @State private var removing: DaemonAPI.MCPServerHealth?
    /// Why the last Remove… did not take it out.
    @State private var removeProblem: String?

    private var host: MachineRef { folder?.host ?? .mac }
    private var snapshot: DaemonAPI.MCPHealthSnapshot? { model.work.mcpHealthSnapshot(host) }

    private var servers: [DaemonAPI.MCPServerHealth] {
        guard let folder else { return snapshot?.personal ?? [] }
        return model.work.mcpServers(in: folder)
    }

    private var problem: String? { snapshot?.problem(in: folder?.folder.path) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                // The set-up (#1336): a folder's slots, or the person's connections; on a host
                // too old to have them (#1748), the line that says so in their place (#1866).
                if let folder {
                    if model.host(host, has: Capability.connectorsSetup1) {
                        ConnectorSetupView(folder: folder, folderName: folderName ?? folder.folder.lastPathComponent,
                                           addConnector: { adding = true })
                    } else {
                        Text(UpdateWords.hostNeedsUpdate).foregroundStyle(.secondary)
                    }
                } else if model.host(host, has: Capability.connections1) {
                    YourConnectionsView()
                } else {
                    Text(UpdateWords.hostNeedsUpdate).foregroundStyle(.secondary)
                }
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(folder == nil ? "User connectors" : "Folder connectors")
                        .appText(.fine).fontWeight(.semibold).foregroundStyle(.secondary)
                        .textCase(.uppercase)
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: 16)
                    // The catalogue writes this Mac's files (#1336 keeps that): a server's
                    // folder gets its connectors from Settings on the Mac it is on.
                    if host == .mac {
                        Button("Add Connector\u{2026}") { adding = true }.buttonStyle(.paper)
                    }
                    Button("Check Now") {
                        checking = true
                        Task {
                            await model.checkMCPHealth(folder: folder)
                            checking = false
                        }
                    }
                    .buttonStyle(.paper)
                    .disabled(checking || !servers.contains { !$0.hosted })
                    .help("Check every connector that is not hosted again now")
                }
                .appText(.fine)
                .padding(.top, 6)
                if let problem {
                    Text(problem)
                        .appText(.fine)
                        .foregroundStyle(StateTint.failure.style(or: .secondary))
                        .textSelection(.enabled)
                }
                if let removeProblem {
                    Text(removeProblem)
                        .appText(.fine)
                        .foregroundStyle(StateTint.failure.style(or: .secondary))
                }
                if servers.isEmpty {
                    Text(folder == nil ? MCPHealthWords.personalEmpty : MCPHealthWords.folderEmpty)
                        .appText(.supporting).foregroundStyle(.secondary)
                        .padding(.horizontal, 14).padding(.vertical, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .paperRaised(in: RoundedRectangle(cornerRadius: 10))
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(servers.enumerated()), id: \.element.id) { index, server in
                            if index > 0 { Divider().padding(.leading, 32) }
                            MCPHealthRow(server: server)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                // Every connector (#2154), one written by hand in mcp.json too,
                                // a server folder's on its own host (#2199).
                                .contextMenu {
                                    Button("Remove\u{2026}", role: .destructive) { removing = server }
                                        // Its mcp.json is on that machine (#2266).
                                        .disabled(model.hostUnreachable(host))
                                }
                        }
                    }
                    .padding(.vertical, 4)
                    .paperRaised(in: RoundedRectangle(cornerRadius: 10))
                }
                Text(folder == nil ? MCPHealthWords.personalIntro : MCPHealthWords.folderIntro)
                    .appText(.fine)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 32).padding(.vertical, 24)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(folderName.map { "\($0) \u{2014} Connectors" } ?? "Connectors")
        .task(id: host) {
            await model.refreshHostedMCP()
            await model.refreshMCPHealth(host)
        }
        .confirmationDialog(removing.map { "Remove \($0.name)?" } ?? "",
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            presenting: removing) { server in
            Button("Remove", role: .destructive) { Task { await remove(server) } }
        } message: { server in
            Text(MCPHealthWords.removes(server.name, inFolder: folder != nil,
                                        on: host == .mac ? nil : model.hosts.label(host))
                 + (folder != nil ? " " + MCPHealthWords.removesCommitted : ""))
        }
        .sheet(isPresented: $adding) {
            AddMCPSheet(destination: folder.map { .folder(folder: $0.folder.path) } ?? .personal,
                        onAdded: { Task { await model.refreshMCPHealth(host) } })
        }
    }

    private var folderName: String? { folder.flatMap { model.work.folder($0)?.name } }

    /// Its secrets stay: Settings' Remove… is where one is forgotten too.
    private func remove(_ server: DaemonAPI.MCPServerHealth) async {
        let destination: DaemonAPI.SkillDestination = folder.map { .folder(folder: $0.folder.path) } ?? .personal
        removeProblem = await model.mcpRemove(server.name, at: destination, forgetSecret: nil, on: host)
            .map { MCPCatalogWords.notRemoved(server.name, $0) }
        await model.refreshMCPHealth(host)
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
            Text("Connectors").foregroundStyle(.primary)
            Spacer()
        }
        .help(words.map { "\($0). Every connector in your own mcp.json, and how each is doing" }
              ?? "Every connector in your own mcp.json, and how each is doing")
        .accessibilityValue(words ?? "")
    }
}
