import AgentsKitCore
import SwiftUI

/// Every worktree of the project's repository, and the way to be done with the Mac's
/// own (030), as the Mac's project page has them.
///
/// All of them are listed, but only the app's own can be removed: one made in a
/// terminal, or by a runtime, is somebody else's. Hidden when there are none. Archiving
/// an agent never removes its worktree — the work in it may not be merged — so this is
/// where they go when you are finished.
struct WorktreesSection: View {
    @Environment(RemoteModel.self) private var model
    let folder: URL

    private var worktrees: [DaemonAPI.WorktreeSummary] {
        model.projectWorktrees.worktrees.filter { !$0.isProjectFolder }
    }

    var body: some View {
        if !worktrees.isEmpty {
            SectionHeading(title: "Worktrees")
            ForEach(worktrees) { worktree in
                WorktreeRow(worktree: worktree, folder: folder)
            }
        }
    }
}

/// One worktree: its name, its branch and who is in it, and Remove when the Mac made it.
private struct WorktreeRow: View {
    @Environment(RemoteModel.self) private var model
    let worktree: DaemonAPI.WorktreeSummary
    let folder: URL

    @State private var asking: DaemonAPI.RemovalCheck?
    @State private var isChecking = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "arrow.triangle.branch")
                .appText(.fine)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(worktree.name)
                    .appText(.reading).fontWeight(.semibold)
                    .lineLimit(1)
                    .strikethrough(!worktree.exists)
                Text(ChoiceRows.worktreeDetail(worktree))
                    .appText(.supporting)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if worktree.madeByApp {
                Button("Remove…") { Task { await remove() } }
                    .buttonStyle(.paper)
                    .appText(.supporting)
                    .disabled(isChecking)
                    .accessibilityLabel("Remove \(worktree.name)")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .paperRow()
        .alert(alertTitle, isPresented: isAsking, presenting: asking) { check in
            if check.blockedBy.isEmpty {
                Button("Remove", role: .destructive) {
                    Task { await model.removeWorktree(worktree.root, in: folder, confirmed: true) }
                }
            }
            Button(check.blockedBy.isEmpty ? "Keep it" : "OK", role: .cancel) {}
        } message: { check in
            Text(message(check))
        }
    }

    /// Asked first, always; removed straight away only when nothing would be lost and
    /// nobody is in it.
    private func remove() async {
        isChecking = true
        defer { isChecking = false }
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
            let names = check.blockedBy.map { id in model.work.agent(id)?.title ?? "An agent" }
            return "Still working here: \(names.joined(separator: ", ")). Archive them first."
        }
        var lost: [String] = []
        if check.uncommitted == 1 { lost.append("1 uncommitted change") }
        if check.uncommitted > 1 { lost.append("\(check.uncommitted) uncommitted changes") }
        if check.unmerged { lost.append("commits that are not merged") }
        return "This loses \(lost.joined(separator: " and ")), and removes its branch \(worktree.branch ?? "")."
    }
}
