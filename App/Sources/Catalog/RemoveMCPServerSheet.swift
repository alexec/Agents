import AgentsKitCore
import SwiftUI

/// Remove a server, one the app added or one written by hand (#2154). The secret stays
/// unless nothing else names it and the person asks to forget it (060, frame E).
struct RemoveMCPServerSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let server: DaemonAPI.FolderMCPServer
    let destination: DaemonAPI.SkillDestination
    /// Offered only when this server's one secret is not named by another server here.
    var forgettable: String?
    /// Named when the secret stays because another server still uses it.
    var keptSecret: String?
    var onRemoved: () -> Void = {}

    @State private var alsoForget = false
    @State private var removing = false
    @State private var failure: String?

    /// The one secret this server names, when no other row in `servers` names it.
    static func forgettable(_ server: DaemonAPI.FolderMCPServer,
                            among servers: [DaemonAPI.FolderMCPServer]) -> String? {
        guard server.secretNames.count == 1, let name = server.secretNames.first else { return nil }
        let usedElsewhere = servers.contains { $0.name != server.name && $0.secretNames.contains(name) }
        return usedElsewhere ? nil : name
    }

    static func keptBecauseShared(_ server: DaemonAPI.FolderMCPServer,
                                  among servers: [DaemonAPI.FolderMCPServer]) -> String? {
        guard server.secretNames.count == 1, let name = server.secretNames.first else { return nil }
        let usedElsewhere = servers.contains { $0.name != server.name && $0.secretNames.contains(name) }
        return usedElsewhere ? name : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Remove \(server.name)?").appText(.title)
            Text(MCPHealthWords.removes(server.name, inFolder: inFolder))
                .appText(.fine)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if inFolder {
                Text(MCPHealthWords.removesCommitted)
                    .appText(.fine)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let forgettable {
                Toggle("Also forget \(forgettable)", isOn: $alsoForget)
                    .appText(.fine)
                Text("Nothing else names it.").appText(.fine).foregroundStyle(.secondary)
            } else if let keptSecret {
                Text("\(keptSecret) stays, because another connector still names it.")
                    .appText(.fine).foregroundStyle(.secondary)
            } else if !server.secretNames.isEmpty {
                Text("Its secrets stay in secrets.env.").appText(.fine).foregroundStyle(.secondary)
            }
            if let failure {
                Text(failure).appText(.fine).foregroundStyle(SharedInk.attention)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(.paper)
                Button("Remove") { Task { await remove() } }
                    .buttonStyle(.paperProminent)
                    .disabled(removing)
            }
        }
        .padding(20)
        .frame(width: 420)
        .paperSheet()
    }

    private var inFolder: Bool {
        if case .folder = destination { return true }
        return false
    }

    private func remove() async {
        removing = true
        defer { removing = false }
        let forget = alsoForget ? forgettable : nil
        if let error = await model.mcpRemove(server.name, at: destination, forgetSecret: forget) {
            failure = MCPCatalogWords.notRemoved(server.name, error)
        } else {
            onRemoved()
            dismiss()
        }
    }
}
