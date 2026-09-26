import AgentsKit
import SwiftUI

/// Every worktree of the project's repository, and the way to be done with the app's
/// own (030).
///
/// All of them are listed, because an agent working in one made in a terminal, or by a
/// runtime, is still working on this project. Only the app's own can be removed: the
/// others are somebody else's. Hidden when there are none, because an empty heading is
/// a question nobody asked. One goes with its last agent's archive only when everything
/// in it is committed, so this is where the rest go when you are finished with them.
struct WorktreesSection: View {
    @Environment(AppModel.self) private var model
    let folder: URL?

    private var worktrees: [DaemonAPI.WorktreeSummary] {
        guard folder != nil, model.draftCwd == folder else { return [] }
        return model.draftWorktrees.worktrees.filter { !$0.isProjectFolder }
    }

    var body: some View {
        if !worktrees.isEmpty {
            SectionHeading(title: "Worktrees")
            ForEach(worktrees) { worktree in
                WorktreeRow(worktree: worktree)
            }
        }
    }
}

/// One worktree: its name, its branch, who is in it, and Remove when the app made it.
struct WorktreeRow: View {
    @Environment(AppModel.self) private var model
    let worktree: DaemonAPI.WorktreeSummary

    @State private var asking: DaemonAPI.RemovalCheck?
    @State private var isChecking = false

    var body: some View {
        // Laid out the way `AgentRow` and `WorkflowRow` are, so the page has one kind of
        // card: an icon at the reading size, a semibold name, a grey line under it.
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "arrow.triangle.branch")
                .appText(.reading)
                .foregroundStyle(.secondary)
                .padding(.top, 1)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(worktree.name)
                    .appText(.reading).fontWeight(.semibold)
                    .lineLimit(1)
                    .strikethrough(!worktree.exists)
                detail
                    .appText(.supporting)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .help(worktree.root.path(percentEncoded: false))
            Spacer(minLength: 8)
            if worktree.madeByApp {
                // Not while anyone works in it: archive them first.
                Button("Remove…") { Task { await remove() } }
                    .buttonStyle(.paper)
                    .appText(.fine)
                    .disabled(isChecking || !worktree.agents.isEmpty)
                    .help(worktree.agents.isEmpty ? "" : "Archive the agents working here to remove it.")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .paperRow()
        .alert(alertTitle, isPresented: isAsking, presenting: asking) { check in
            if check.blockedBy.isEmpty {
                Button("Remove", role: .destructive) {
                    Task { await model.removeWorktree(worktree.root, confirmed: true) }
                }
            }
            Button(check.blockedBy.isEmpty ? "Keep it" : "OK", role: .cancel) {}
        } message: { check in
            Text(message(check))
        }
    }

    /// Branch, git status, who is in it. One concatenated `Text`, so the row stays a
    /// single element to accessibility; work that would be lost is orange.
    private var detail: Text {
        let branch = worktree.branch ?? "detached"
        guard worktree.exists else { return Text("\(branch) · its folder is gone") }
        var text = Text(branch)
        if let status = worktree.status {
            let summary = Text(status.summary)
            text = text + Text(" · ") + (status.hasPendingWork ? summary.foregroundStyle(StateTint.attention.style(or: .secondary)) : summary)
        }
        switch worktree.agents.count {
        case 0: return text
        case 1: return text + Text(" · 1 agent working")
        case let count: return text + Text(" · \(count) agents working")
        }
    }

    /// Asked first, always; removed straight away only when nothing would be lost and
    /// nobody is in it.
    private func remove() async {
        isChecking = true
        defer { isChecking = false }
        guard let check = await model.checkWorktreeRemoval(worktree.root) else { return }
        if check.blockedBy.isEmpty && !check.losesWork {
            await model.removeWorktree(worktree.root, confirmed: false)
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
            let names = check.blockedBy.map { id in
                model.agents.first { $0.id == id }?.title ?? "An agent"
            }
            return "Still working here: \(names.joined(separator: ", ")). Archive them first."
        }
        var lost: [String] = []
        if check.uncommitted == 1 { lost.append("1 uncommitted change") }
        if check.uncommitted > 1 { lost.append("\(check.uncommitted) uncommitted changes") }
        if check.unmerged { lost.append("commits that are not merged") }
        return "This loses \(lost.joined(separator: " and ")), and removes its branch \(worktree.branch ?? "")."
    }
}
