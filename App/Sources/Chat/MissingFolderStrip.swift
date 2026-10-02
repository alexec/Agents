import AgentsKitCore
import SwiftUI

/// Over a chat whose folder has gone (#119): that it has, which folder, and the ways on.
/// Where the park line and Carry on are, so it is read before anything is typed.
struct MissingFolderStrip: View {
    @Environment(AppModel.self) private var model
    let agent: Agent

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text("\(MissingFolderWords.label) \(Text("· " + MissingFolderWords.shortPath(agent.cwd)).foregroundStyle(.secondary))")
            } icon: {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            }
            .appText(.fine)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(agent.folderGoneMessage)
            HStack(spacing: 8) {
                Button {
                    Task { await model.continueInProject(agent.id) }
                } label: {
                    Label(MissingFolderWords.continueInProject, systemImage: "arrow.turn.down.right")
                }
                .help("Start a new session in the project folder that reads this one and carries on")
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
                Spacer(minLength: 0)
            }
            .buttonStyle(.paper)
            .appText(.fine)
            .fixedSize(horizontal: false, vertical: true)
        }
        .chatColumn()
        .padding(.vertical, 8)
    }
}
