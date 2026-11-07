import AgentsKitCore
import SwiftUI

/// A machine's worktrees on its page (#790, #3627), and how much each holds on disk: a
/// section per folder.
///
/// They were Activity ▸ Worktrees, and before that Folder Settings ▸ Worktrees (030). A
/// worktree is a folder's, and a folder is one machine's, so its page is where its disk
/// and its worktrees are seen together. On 2026-10-03 the disk filled with 80 GB of them:
/// idle ones, with no session in them, come first, largest first, with Remove build
/// output and Remove….
///
/// All of them are listed, because an agent working in one made in a terminal, or by a
/// runtime, is still working on the folder. Only the app's own can be cleaned or
/// removed: the others are somebody else's. Sizes are walked by the daemon in the
/// background and fill in as they come (`worktrees/sized`); the list never waits on them.
struct MachineWorktreesSections: View {
    @Environment(AppModel.self) private var model
    let host: MachineRef
    @State private var loading = false

    var body: some View {
        let groups = model.work.worktreesForCleanup(on: host)
        Section {
            LabeledContent {
                Button("Refresh") {
                    loading = true
                    Task {
                        await model.loadWorktrees(on: host)
                        loading = false
                    }
                }
                .disabled(loading)
                .help("List the worktrees again")
            } label: {
                Text(WorktreeTally(groups).pageLine)
            }
        } header: {
            Text("Worktrees")
        } footer: {
            Text(WorktreeTally.intro).foregroundStyle(.secondary)
        }
        .task(id: host) { await model.loadWorktrees(on: host) }
        ForEach(groups) { group in
            WorktreesGroup(group: group, host: host)
        }
    }
}

/// One folder's worktrees under its name, with Clean up worktrees.
struct WorktreesGroup: View {
    @Environment(AppModel.self) private var model
    let group: DaemonAPI.FolderWorktrees
    let host: MachineRef

    var body: some View {
        Section {
            ForEach(group.worktrees) { worktree in
                WorktreeRow(worktree: worktree, folder: group.folder, host: host)
            }
        } header: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(model.work.folder(FolderKey(host: host, folder: group.folder))?.name ?? group.folder.lastPathComponent)
                Spacer()
                Button("Clean up worktrees") { model.offerCleanUp(in: group.folder, on: host) }
                    .buttonStyle(.paper)
                    .appText(.fine)
                    .help("A new session here, offered the words to remove what has been merged")
            }
        }
    }
}

/// One worktree: its name, its branch, who is in it, how much it holds, and Remove build
/// output and Remove… when the app made it and nobody works in it.
struct WorktreeRow: View {
    @Environment(AppModel.self) private var model
    let worktree: DaemonAPI.WorktreeSummary
    let folder: URL
    let host: MachineRef

    @State private var asking: DaemonAPI.RemovalCheck?
    @State private var isBusy = false
    /// What Remove build output freed, said under the row until the list changes.
    @State private var freed: String?
    /// The Send to ‹host›… sheet up for this worktree (#1123).
    @State private var sending: SendToHostRequest?
    /// The Bring back from ‹host›… sheet up for this worktree (#1473).
    @State private var bringingBack: BringBackFromHostRequest?

    private var canClean: Bool { worktree.madeByApp && worktree.exists && worktree.isIdle }
    /// Send to and Bring Back are from this Mac's worktrees only.
    private var sendsToServers: Bool { host == .mac && worktree.exists }

    var body: some View {
        // An icon at the reading size, a semibold name, a grey line under it, as `AgentRow`.
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
                if let freed {
                    Text(freed)
                        .appText(.fine)
                        .foregroundStyle(.secondary)
                }
            }
            .help(worktree.root.path(percentEncoded: false))
            Spacer(minLength: 8)
            if worktree.exists {
                Text(worktree.size?.words ?? WorktreeTally.measuring)
                    .appText(.supporting)
                    .monospacedDigit()
                    .foregroundStyle(worktree.size == nil ? .tertiary : .secondary)
                    .padding(.top, 1)
            }
            if canClean {
                Button("Remove build output") { Task { await removeBuildOutput() } }
                    .buttonStyle(.paper)
                    .appText(.fine)
                    .disabled(isBusy)
                    .help("Delete build, .build, DerivedData, node_modules, target and dist that git ignores")
                Button("Remove…") { Task { await remove() } }
                    .buttonStyle(.paper)
                    .appText(.fine)
                    .disabled(isBusy)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contextMenu {
            // This Mac's worktree, sent to a server and added there (#1123). The worktrees are
            // this Mac's host's, by its own id when it has one (#1496, #1536).
            ForEach(sendsToServers ? model.sendTargets : [], id: \.self) { server in
                Button("Send to \(model.hosts.label(server))…") {
                    sending = SendToHostRequest(folder: worktree.root, from: model.thisMacHostID ?? .mac, host: server)
                }
            }
            // The server's branches, brought back into this worktree's repository (#1473).
            ForEach(sendsToServers ? model.sendTargets : [], id: \.self) { server in
                Button("Bring Back from \(model.hosts.label(server))…") {
                    bringingBack = BringBackFromHostRequest(folder: worktree.root, from: model.thisMacHostID ?? .mac, host: server)
                }
            }
        }
        .sheet(item: $sending) { SendToHostSheet(request: $0).paperSheet() }
        .sheet(item: $bringingBack) { BringBackSheet(request: $0).paperSheet() }
        .alert(alertTitle, isPresented: isAsking, presenting: asking) { check in
            if check.blockedBy.isEmpty {
                Button("Remove", role: .destructive) {
                    Task { await model.removeWorktree(worktree.root, in: folder, on: host, confirmed: true) }
                }
            }
            Button(check.blockedBy.isEmpty ? "Keep it" : "OK", role: .cancel) {}
        } message: { check in
            Text(message(check))
        }
    }

    /// Branch, git status, who is in it. One concatenated `Text`, so the row stays a
    /// single element to accessibility; uncommitted work is secondary, not orange —
    /// colour is reserved for when a person is needed.
    private var detail: Text {
        let branch = worktree.branch ?? "detached"
        guard worktree.exists else { return Text("\(branch) · its folder is gone") }
        var text = Text(branch)
        if let status = worktree.status {
            let summary = Text(status.summary)
            text = Text("\(text) · \(status.hasPendingWork ? summary.foregroundStyle(.secondary) : summary)")
        }
        switch worktree.agents.count {
        case 0: return text
        case 1: return Text("\(text) · 1 agent working")
        case let count: return Text("\(text) · \(count) agents working")
        }
    }

    private func removeBuildOutput() async {
        isBusy = true
        defer { isBusy = false }
        freed = await model.removeBuildOutput(worktree.root, in: folder, on: host)
    }

    /// Asked first, always; removed straight away only when nothing would be lost and
    /// nobody is in it.
    private func remove() async {
        isBusy = true
        defer { isBusy = false }
        guard let check = await model.checkWorktreeRemoval(worktree.root, in: folder, on: host) else { return }
        if check.blockedBy.isEmpty && !check.losesWork {
            await model.removeWorktree(worktree.root, in: folder, on: host, confirmed: false)
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
                model.work.agent(id)?.title ?? "An agent"
            }
            return "Still working here: \(names.joined(separator: ", ")). Archive them first."
        }
        return WorktreeTally.removalMessage(check, branch: worktree.branch)
    }
}
