import AgentsKit
import SwiftUI

/// The worktrees this app made for the project, and the way to be done with one (030).
///
/// Only the app's own: one made in a terminal, or by a runtime, is somebody else's to
/// remove. Hidden when there are none, because an empty heading is a question nobody
/// asked. Archiving an agent never removes its worktree — the work in it may not be
/// merged — so this is where they go when you are finished with them.
struct WorktreesSection: View {
    @Environment(AppModel.self) private var model
    let folder: URL?

    private var worktrees: [DaemonAPI.WorktreeSummary] {
        guard folder != nil, model.draftCwd == folder else { return [] }
        return model.draftWorktrees.worktrees.filter { $0.madeByApp && !$0.isProjectFolder }
    }

    var body: some View {
        if !worktrees.isEmpty {
            GroupHeading(title: "Worktrees", count: worktrees.count)
            ForEach(worktrees) { worktree in
                WorktreeRow(worktree: worktree)
            }
        }
    }
}

/// One worktree: its name, its branch, who is in it, and Remove.
struct WorktreeRow: View {
    @Environment(AppModel.self) private var model
    let worktree: DaemonAPI.WorktreeSummary

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
                Text(detail)
                    .appText(.supporting)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .help(worktree.root.path(percentEncoded: false))
            Spacer(minLength: 8)
            Button("Remove…") { Task { await remove() } }
                .buttonStyle(.glass)
                .appText(.fine)
                .disabled(isChecking)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14))
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

    private var detail: String {
        let branch = worktree.branch ?? "detached"
        guard worktree.exists else { return "\(branch) · its folder is gone" }
        switch worktree.agents.count {
        case 0: return branch
        case 1: return "\(branch) · 1 agent working"
        case let count: return "\(branch) · \(count) agents working"
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
