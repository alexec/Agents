import AgentsKitCore
import SwiftUI

/// Over a chat whose folder has gone (#119): that it has, which folder, and the ways on,
/// as the Mac's strip over the chat has them: an attention banner (#4737).
struct RemoteMissingFolderStrip: View {
    @Environment(RemoteModel.self) private var model
    let agent: Agent

    var body: some View {
        let path = MissingFolderWords.shortPath(agent.cwd, home: "")
        PaneBanner(tone: .attention, symbol: "folder.badge.questionmark",
                   announcement: MissingFolderWords.label + " " + path) {
            Text("\(MissingFolderWords.label) \(Text("· " + path).foregroundStyle(Paper.secondary))")
                .lineLimit(1)
                .truncationMode(.middle)
        } actions: {
            Button(MissingFolderWords.continueInFolder) {
                Task { await model.continueInFolder(agent.id) }
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
        .paneBannerInset()
        .remoteBannerGround()
    }
}
