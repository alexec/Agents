import AgentsKitCore
import SwiftUI

/// The folder's strip (#5034, second of the session's strips; #119): the session's folder has
/// gone, which folder, and the ways on. A send the host refused for it (a folder gone) is this
/// strip too, not an alert: it says that what was typed is still in the prompt, and Continue
/// in the Folder takes it along.
struct MissingFolderStrip: View {
    @Environment(AppModel.self) private var model
    let agent: Agent

    @MainActor
    static func isShown(_ agent: Agent, model: AppModel) -> Bool {
        agent.state != .archived && (agent.missingFolder != nil || model.folderGone?.agentID == agent.id)
    }

    var body: some View {
        let refused = model.folderGone.flatMap { $0.agentID == agent.id ? $0 : nil }
        let path = MissingFolderWords.shortPath(agent.cwd)
        Strip(tone: .warning, symbol: "folder.badge.questionmark", line: MissingFolderWords.label,
              detail: refused == nil ? path : path + " · " + MissingFolderWords.typedIsKept,
              primary: StripButton(title: MissingFolderWords.continueInFolder,
                                   help: "Start a new session in the folder that reads this one and carries on") {
                  model.folderGone = nil
                  Task { await model.continueInFolder(agent.id, text: refused?.text ?? "", attachments: refused?.attachments ?? []) }
              },
              second: StripButton(title: MissingFolderWords.archive, help: "Archive this session") {
                  model.folderGone = nil
                  Task { await model.archive(agent.id, andLeave: true) }
              },
              more: more)
            .help(agent.folderGoneMessage)
    }

    private var more: [StripButton] {
        var more: [StripButton] = []
        if agent.mayRecreateWorktree {
            more.append(StripButton(title: MissingFolderWords.recreateWorktree) {
                model.folderGone = nil
                Task { await model.recreateWorktree(agent.id) }
            })
        }
        return more
    }
}
