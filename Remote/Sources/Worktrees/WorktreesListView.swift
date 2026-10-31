import AgentsKitCore
import SwiftUI

/// Every folder's worktrees on the Mac and how much each holds on disk (#790), as the
/// window's Activity ▸ Worktrees: idle ones first, largest first, sizes filling in as the
/// Mac measures them. Remove Build Output and Remove… on an idle worktree the app made,
/// in its swipe and its long press; Clean Up Worktrees per folder.
struct WorktreesListView: View {
    @Environment(RemoteModel.self) private var model
    /// What the last Remove Build Output freed, said at the top until the next.
    @State private var freed: String?

    private var groups: [DaemonAPI.FolderWorktrees] { model.work.worktreesForCleanup() }

    var body: some View {
        List {
            Section {
                Text(WorktreeTally(groups).pageLine)
                if let freed {
                    Text(freed).foregroundStyle(.secondary)
                }
            } footer: {
                Text(WorktreeTally.intro)
            }
            ForEach(groups) { group in
                Section {
                    ForEach(group.worktrees) { worktree in
                        WorktreeListRow(worktree: worktree, folder: group.folder, freed: $freed)
                    }
                    .paperListRow()
                } header: {
                    HStack {
                        Text(model.work.folder(FolderKey(folder: group.folder))?.name
                             ?? group.folder.lastPathComponent)
                        Spacer()
                        Button("Clean Up") { model.offerCleanUp(in: group.folder) }
                            .appText(.fine)
                            .accessibilityLabel("Clean up worktrees")
                            .accessibilityHint("A new session here, offered the words to remove what has been merged")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Paper.ground)
        .navigationTitle("Worktrees")
        .refreshable { await model.loadWorktrees() }
        .task { await model.loadWorktrees() }
    }
}

/// One worktree: name, its branch and who is in it, and how much it holds.
private struct WorktreeListRow: View {
    @Environment(RemoteModel.self) private var model
    let worktree: DaemonAPI.WorktreeSummary
    let folder: URL
    @Binding var freed: String?

    @State private var asking: DaemonAPI.RemovalCheck?

    private var canClean: Bool { worktree.madeByApp && worktree.exists && worktree.isIdle }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(worktree.name)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .strikethrough(!worktree.exists)
                Text(worktree.exists ? ChoiceRows.worktreeDetail(worktree) : "\(worktree.branch ?? "detached") · its folder is gone")
                    .appText(.supporting)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            if worktree.exists {
                Text(worktree.size?.words ?? WorktreeTally.measuring)
                    .appText(.supporting)
                    .monospacedDigit()
                    .foregroundStyle(worktree.size == nil ? .tertiary : .secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .swipeActions(edge: .trailing) {
            if canClean {
                Button("Remove…", role: .destructive) { Task { await remove() } }
                Button("Remove Build Output") { Task { await removeBuildOutput() } }
            }
        }
        .contextMenu {
            if canClean {
                Button("Remove Build Output", systemImage: "hammer") { Task { await removeBuildOutput() } }
                Button("Remove…", systemImage: "trash", role: .destructive) { Task { await remove() } }
            }
        }
        .alert(alertTitle, isPresented: isAsking, presenting: asking) { check in
            if check.blockedBy.isEmpty {
                Button("Remove", role: .destructive) {
                    Task { await model.removeWorktree(worktree.root, in: folder, confirmed: true) }
                }
            }
            Button(check.blockedBy.isEmpty ? "Keep It" : "OK", role: .cancel) {}
        } message: { check in
            Text(message(check))
        }
    }

    private func removeBuildOutput() async {
        if let words = await model.removeBuildOutput(worktree.root, in: folder) {
            freed = "\(worktree.name): \(words)"
        }
    }

    /// Asked first, always; removed straight away only when nothing would be lost and
    /// nobody is in it, as the window does.
    private func remove() async {
        guard let check = await model.checkWorktreeRemoval(worktree.root, in: folder) else { return }
        if check.blockedBy.isEmpty && !check.losesWork {
            await model.removeWorktree(worktree.root, in: folder, confirmed: false)
        } else {
            asking = check
        }
    }

    private var isAsking: Binding<Bool> {
        Binding(get: { asking != nil }, set: { if !$0 { asking = nil } })
    }

    private var alertTitle: String {
        asking?.blockedBy.isEmpty == false ? "\(worktree.name) is in use" : "Remove \(worktree.name)?"
    }

    private func message(_ check: DaemonAPI.RemovalCheck) -> String {
        if !check.blockedBy.isEmpty {
            let names = check.blockedBy.map { model.work.agent($0)?.title ?? "An agent" }
            return "Still working here: \(names.joined(separator: ", ")). Archive them first."
        }
        return WorktreeTally.removalMessage(check, branch: worktree.branch)
    }
}

/// The way in, under Activity: the title alone, the count said to VoiceOver (#587).
struct WorktreesRow: View {
    @Environment(RemoteModel.self) private var model

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Worktrees")
            Spacer()
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(WorktreeTally(model.work.worktreesForCleanup()).rowWords ?? "")
        .accessibilityHint("Opens Worktrees")
    }
}
