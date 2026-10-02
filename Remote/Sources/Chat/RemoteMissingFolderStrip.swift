import AgentsKitCore
import SwiftUI

/// Over a chat whose folder has gone (#119): that it has, which folder, and the ways on,
/// as the Mac's strip over the chat has them.
struct RemoteMissingFolderStrip: View {
    @Environment(RemoteModel.self) private var model
    let agent: Agent

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text("\(MissingFolderWords.label) \(Text("· " + MissingFolderWords.shortPath(agent.cwd, home: "")).foregroundStyle(.secondary))")
            } icon: {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.secondary)
            }
            .appText(.fine)
            .lineLimit(1)
            .truncationMode(.middle)
            HStack(spacing: 8) {
                Button(MissingFolderWords.continueInProject) {
                    Task { await model.continueInProject(agent.id) }
                }
                if agent.mayRecreateWorktree {
                    Button(MissingFolderWords.recreateWorktree) {
                        Task { await model.recreateWorktree(agent.id) }
                    }
                }
                Button(MissingFolderWords.archive) {
                    Task { await model.archive(agent.id) }
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .appText(.fine)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}
