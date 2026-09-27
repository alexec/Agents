import AgentsKit
import AppKit
import SwiftUI

/// A project's MCP servers, on its page after Skills and before Plugins (060, frame D).
///
/// They live in `.agents/mcp.json`, which is committed, so the line under the heading
/// says the file names secrets and each person sets their own. One that arrived with a
/// pull waits until it is approved. Not drawn for a project on a server (R6).
struct ProjectMCPSection: View {
    @Environment(AppModel.self) private var model
    let folder: URL?

    @State private var servers: [DaemonAPI.ProjectMCPServer] = []
    @State private var problem: String?
    @State private var adding = false
    @State private var failure: String?

    private var onMac: Bool { model.selectedProjectKey?.host == .mac }

    var body: some View {
        if let folder, onMac {
            heading(folder)
            Text("In .agents/mcp.json, committed with the project. Secrets aren't: it names them, and each person sets their own.")
                .appText(.fine).foregroundStyle(.secondary)
                .padding(.leading, 2)
                .padding(.bottom, 4)
            if let problem {
                Text(problem)
                    .appText(.supporting).foregroundStyle(SharedInk.attention)
                    .padding(.horizontal, 16).padding(.vertical, 13)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .paperRow()
            } else if servers.isEmpty {
                Text("No MCP servers in this project yet.")
                    .appText(.supporting).foregroundStyle(.secondary)
                    .padding(.horizontal, 16).padding(.vertical, 13)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .paperRow()
            } else {
                if let failure {
                    Text(failure).appText(.fine).foregroundStyle(SharedInk.attention)
                }
                ForEach(servers) { server in
                    ProjectMCPRow(server: server, servers: servers, folder: folder,
                                  changed: { Task { await load(folder) } },
                                  failed: { failure = $0 })
                }
            }
            Color.clear.frame(height: 0)
                .task(id: folder) { await load(folder) }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    Task { await load(folder) }
                }
                .sheet(isPresented: $adding) {
                    AddMCPSheet(destination: .project(folder: folder.path), onAdded: { Task { await load(folder) } })
                }
        }
    }

    private func heading(_ folder: URL) -> some View {
        HStack(spacing: 8) {
            SectionHeading(title: "MCP servers")
                .fixedSize()
            if !servers.isEmpty {
                SharedChip(text: "\(servers.count)").padding(.top, 20)
            }
            Spacer()
            Group {
                Button("Reveal mcp.json") {
                    let file = folder.appending(path: ".agents/mcp.json")
                    SharedFiles.reveal(FileManager.default.fileExists(atPath: file.path) ? file.path : folder.path)
                }
                .buttonStyle(.paper)
                Button("Add server…") { adding = true }.buttonStyle(.paperProminent)
            }
            .padding(.top, 20)
        }
    }

    private func load(_ folder: URL) async {
        guard let fresh = await model.projectMCPServers(folder) else { return }
        servers = fresh.servers
        problem = fresh.problem
    }
}

/// One of a project's servers. Waiting ones are already first. A missing secret is named,
/// never shown. Set…, Replace… and Remove… ask before they write (frame E).
private struct ProjectMCPRow: View {
    @Environment(AppModel.self) private var model
    let server: DaemonAPI.ProjectMCPServer
    let servers: [DaemonAPI.ProjectMCPServer]
    let folder: URL
    var changed: () -> Void = {}
    var failed: (String?) -> Void = { _ in }

    @State private var setting: [String] = []
    @State private var replacing = false
    @State private var removing = false

    private var setSecrets: [String] {
        server.secretNames.filter { !server.missingSecrets.contains($0) }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .appText(.reading)
                .foregroundStyle((isWaiting || !server.missingSecrets.isEmpty ? StateTint.attention : StateTint.none).style(or: .secondary))
                .accessibilityLabel(isWaiting ? "Waiting for your OK" : "Server")
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(server.name).appText(.reading).fontWeight(.semibold).lineLimit(1)
                    if server.managed != nil { SharedChip(text: "registry", tone: .source) }
                    if isWaiting { SharedChip(text: "waiting for your OK", tone: .attention) }
                    ForEach(server.missingSecrets, id: \.self) { name in
                        SharedChip(text: "\(name) not set", tone: .attention)
                    }
                }
                Text(detail).appText(.supporting).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                if let note {
                    Text(note).appText(.supporting).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 8)

            HStack(spacing: 6) {
                Button("Show entry") {
                    SharedFiles.open(folder.appending(path: ".agents/mcp.json").path)
                }
                .buttonStyle(.paper)
                .appText(.fine)
                if !server.missingSecrets.isEmpty {
                    Button("Set…") {
                        replacing = false
                        setting = server.missingSecrets
                    }
                    .buttonStyle(.paper)
                    .appText(.fine)
                }
                if !setSecrets.isEmpty {
                    Button("Replace…") {
                        replacing = true
                        setting = setSecrets
                    }
                    .buttonStyle(.paper)
                    .appText(.fine)
                }
                if case .waiting(let digest, _) = server.approval {
                    Button("Approve") {
                        Task {
                            if let error = await model.approveProjectMCP(server.name, digest: digest, in: folder) {
                                failed(MCPCatalogWords.sentence(error))
                            } else {
                                failed(nil)
                                changed()
                            }
                        }
                    }
                    .buttonStyle(.paper)
                    .appText(.fine)
                }
                if server.managed != nil {
                    Button("Remove…") { removing = true }
                        .buttonStyle(.paper)
                        .appText(.fine)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .paperRow()
        .accessibilityElement(children: .contain)
        .sheet(isPresented: Binding(get: { !setting.isEmpty }, set: { if !$0 { setting = [] } })) {
            SetSecretSheet(serverName: server.name, names: setting, replacing: replacing, onSaved: changed)
        }
        .sheet(isPresented: $removing) {
            RemoveMCPServerSheet(server: server, destination: .project(folder: folder.path),
                                 forgettable: RemoveMCPServerSheet.forgettable(server, among: servers),
                                 keptSecret: RemoveMCPServerSheet.keptBecauseShared(server, among: servers),
                                 onRemoved: changed)
        }
    }

    private var isWaiting: Bool {
        if case .waiting = server.approval { true } else { false }
    }

    private var icon: String {
        if isWaiting { return "hand.raised" }
        if !server.missingSecrets.isEmpty { return "exclamationmark.triangle" }
        return "point.3.connected.trianglepath.dotted"
    }

    private var detail: String {
        if let managed = server.managed, server.summary.contains("://") {
            return "\(server.summary) · \(managed.version)"
        }
        return server.summary
    }

    private var note: String? {
        if case .waiting(_, let isNew) = server.approval {
            return (isNew ? "New with the last pull. " : "Changed since you approved it. ")
                + "No agent is given it until you approve it."
        }
        if let name = server.missingSecrets.first {
            let extra = server.missingSecrets.count > 1 ? " (and \(server.missingSecrets.dropFirst().joined(separator: ", ")))" : ""
            return "Agents here start without it until you set \(name)\(extra)."
        }
        return nil
    }
}
