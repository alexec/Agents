import AgentsKitCore
import SwiftUI

/// Over a chat whose folder has gone (#119): that it has, which folder, and the ways on. An
/// attention banner (#4737): the person chooses the folder again, or archives. Where the
/// Archiving needs approval line and Carry on are, so it is read before anything is typed.
struct MissingFolderStrip: View {
    @Environment(AppModel.self) private var model
    let agent: Agent

    var body: some View {
        PaneBanner(tone: .attention, symbol: "folder.badge.questionmark",
                   announcement: MissingFolderWords.label + " " + MissingFolderWords.shortPath(agent.cwd)) {
            Text("\(MissingFolderWords.label) \(Text("· " + MissingFolderWords.shortPath(agent.cwd)).foregroundStyle(.secondary))")
                .lineLimit(1)
                .truncationMode(.middle)
                .help(agent.folderGoneMessage)
        } actions: {
            Button {
                Task { await model.continueInFolder(agent.id) }
            } label: {
                Label(MissingFolderWords.continueInFolder, systemImage: "arrow.turn.down.right")
            }
            .help("Start a new session in the folder that reads this one and carries on")
            if agent.mayRecreateWorktree {
                Button {
                    Task { await model.recreateWorktree(agent.id) }
                } label: {
                    Label(MissingFolderWords.recreateWorktree, systemImage: "arrow.triangle.branch")
                }
                .help("Make the worktree again from its branch\(agent.worktree?.branch.map { ", \($0)" } ?? "")")
            }
            Button {
                Task { await model.archive(agent.id, andLeave: true) }
            } label: {
                Label(MissingFolderWords.archive, systemImage: "archivebox")
            }
            .help("Archive this session")
        }
        .chatColumn()
        .padding(.top, 8)
    }
}
