import AgentsKitCore
import SwiftUI

/// The folder's strip (#5034, second of the session's strips; #119): that the folder has gone,
/// which folder, and the ways on, as the Mac's strip has them.
struct RemoteMissingFolderStrip: View {
    @Environment(RemoteModel.self) private var model
    let agent: Agent

    static func isShown(_ agent: Agent) -> Bool {
        agent.missingFolder != nil && agent.state != .archived
    }

    var body: some View {
        Strip(tone: .warning, symbol: "folder.badge.questionmark", line: MissingFolderWords.label,
              detail: MissingFolderWords.shortPath(agent.cwd, home: ""),
              primary: StripButton(title: MissingFolderWords.continueInFolder) {
                  Task { await model.continueInFolder(agent.id) }
              },
              second: StripButton(title: MissingFolderWords.archive) {
                  Task { await model.archive(agent.id) }
              },
              more: agent.mayRecreateWorktree
                  ? [StripButton(title: MissingFolderWords.recreateWorktree) { Task { await model.recreateWorktree(agent.id) } }]
                  : [])
    }
}
