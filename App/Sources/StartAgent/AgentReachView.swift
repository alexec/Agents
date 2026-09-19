import AgentsKit
import SwiftUI

/// Everywhere an agent may work, and what else it can reach.
///
/// Work that spans two repositories is the ordinary case rather than the odd one, and
/// an MCP server is how an agent reaches something that is not a file at all.
struct AgentReachView: View {
    @Environment(\.dismiss) private var dismiss
    let cwd: URL?
    @Binding var folders: [URL]
    @Binding var servers: [MCPServer]

    @State private var serverName = ""
    @State private var serverCommand = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Folders").font(.headline)
                if let cwd {
                    Label(cwd.lastPathComponent, systemImage: "folder")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .help(cwd.path(percentEncoded: false))
                }
                ForEach(folders, id: \.self) { folder in
                    HStack {
                        Label(folder.lastPathComponent, systemImage: "folder")
                            .font(.callout)
                            .help(folder.path(percentEncoded: false))
                        Spacer()
                        Button {
                            folders.removeAll { $0 == folder }
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                }
                Button("Add a folder", action: addFolder)
                    .buttonStyle(.glass)
                    .font(.footnote)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("MCP servers").font(.headline)
                ForEach(servers) { server in
                    HStack {
                        Text(server.name).font(.callout)
                        Spacer()
                        Button {
                            servers.removeAll { $0.id == server.id }
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 8) {
                    TextField("Name", text: $serverName)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 120)
                    TextField("Command, as you would type it", text: $serverCommand)
                        .textFieldStyle(.roundedBorder)
                    Button("Add", action: addServer)
                        .buttonStyle(.glass)
                        .disabled(serverName.isEmpty || serverCommand.isEmpty)
                }
                Text("A server that will not start is reported against the agent and does not stop it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.glass)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Add"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard url != cwd, !folders.contains(url) else { return }
        folders.append(url)
    }

    private func addServer() {
        let parts = serverCommand.split(separator: " ").map(String.init)
        guard let command = parts.first else { return }
        servers.append(MCPServer(name: serverName,
                                 transport: .stdio(command: command,
                                                   args: Array(parts.dropFirst()),
                                                   env: [:])))
        serverName = ""
        serverCommand = ""
    }
}
