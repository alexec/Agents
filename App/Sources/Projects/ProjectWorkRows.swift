import AgentsKit
import SwiftUI

/// What the project is working on besides its sessions, under them in the middle column:
/// its open pull requests, its Ready issues, and its workflows. Each is a list section of
/// rows the size of a session's, so the column reads as one list.
///
/// A section with nothing in it is left out, so a project that is not on GitHub and has
/// no workflows shows only its sessions.
struct ProjectWorkSections: View {
    @Environment(AppModel.self) private var model
    let folder: URL?

    private var pullRequests: PullRequestList? {
        folder.flatMap { model.pullRequestLists[Project.standardize($0)] }
    }
    private var board: GitHubProjectBoard? {
        folder.flatMap { model.githubProjectBoards[Project.standardize($0)] }
    }
    private var workflows: [WorkflowSummary] {
        model.workflows(in: folder).filter { !$0.isArchived }
    }

    var body: some View {
        if let list = pullRequests, list.showsRows ? !list.pullRequests.isEmpty : list.problem != nil {
            Section {
                if list.showsRows {
                    ForEach(list.pullRequests) { pull in
                        PullRequestListRow(pull: pull, folder: list.folder)
                    }
                } else if let problem = list.problem {
                    ProblemLine(text: problem.message ?? "Can't see pull requests.", fix: problem.fix)
                }
            } header: {
                SectionCount(title: "Pull requests", count: list.pullRequests.count) {
                    Task { await model.refreshPullRequests(for: list.folder) }
                }
            }
        }
        if let board {
            let ready = board.issues.filter { $0.status == .ready }
            if !ready.isEmpty || board.problem != nil {
                Section {
                    if let problem = board.problem {
                        ProblemLine(text: problem.message, fix: problem.fix)
                    }
                    ForEach(ready) { issue in
                        ReadyIssueRow(issue: issue, board: board)
                    }
                } header: {
                    SectionCount(title: "Ready issues", count: ready.count) {
                        Task { await model.refreshGitHubProjectBoard(for: board.folder) }
                    }
                }
            }
        }
        if !workflows.isEmpty {
            Section {
                ForEach(workflows) { summary in
                    WorkflowListRow(summary: summary)
                }
            } header: {
                SectionCount(title: "Workflows", count: workflows.count, refresh: nil)
            }
        }
    }
}

/// A section's name and count, as the sessions' headings have them, with ↻ on the right
/// when the section is fetched from GitHub.
private struct SectionCount: View {
    let title: String
    let count: Int
    let refresh: (() -> Void)?

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
            Text("\(count)").monospacedDigit().foregroundStyle(.tertiary)
            Spacer()
            if let refresh {
                Button(action: refresh) { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Refresh")
                    .accessibilityLabel("Refresh \(title.lowercased())")
            }
        }
    }
}

/// Why a section cannot show its rows, and the command that fixes it, as text to copy.
private struct ProblemLine: View {
    let text: String
    let fix: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(text).appText(.fine)
            if let fix {
                Text(fix).appText(.fine).monospaced().textSelection(.enabled)
            }
        }
        .foregroundStyle(.secondary)
        .padding(.vertical, 4)
    }
}

/// The two lines every row here has: a number or icon, a title, and a grey line under it,
/// with one button on the right.
private struct WorkRow<Leading: View, Detail: View, Trailing: View>: View {
    let title: String
    let leading: Leading
    let detail: Detail
    let trailing: Trailing

    init(_ title: String, @ViewBuilder leading: () -> Leading, @ViewBuilder detail: () -> Detail,
         @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.leading = leading()
        self.detail = detail()
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    leading
                    Text(title)
                        .appText(.supporting).fontWeight(.semibold)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                detail
                    .appText(.fine)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
            trailing
        }
        .padding(.vertical, 6)
        .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
    }
}

// MARK: Pull requests

/// One open pull request: where it stands, and Babysit, which fills the prompt.
private struct PullRequestListRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    let pull: PullRequest
    let folder: URL

    var body: some View {
        WorkRow(pull.title) {
            Text("#\(pull.number)").monospacedDigit().foregroundStyle(.secondary)
                .appText(.fine)
        } detail: {
            Text(detail)
        } trailing: {
            Button("Babysit") { babysit() }
                .buttonStyle(.paper)
                .appText(.fine)
                .help("Fill the prompt to babysit #\(pull.number)")
        }
        .onTapGesture { openURL(pull.url) }
        .help(pull.url.absoluteString)
        .contextMenu {
            Button("Open on GitHub") { openURL(pull.url) }
            Button("Babysit this PR") { babysit() }
            if pull.babysitting.isStopped {
                Button("Resume babysitting") { Task { await model.resume(pull.number, in: folder) } }
            }
        }
    }

    /// Checks, review and where it is, whichever of them there are.
    private var detail: String {
        var parts: [String] = []
        if pull.isDraft { parts.append("Draft") }
        switch pull.checks {
        case .failing: parts.append("✕ checks")
        case .passing: parts.append("✓ checks")
        case .running: parts.append("◌ checks")
        case .none: break
        }
        switch pull.review {
        case .changesRequested: parts.append("changes requested")
        case .approved: parts.append("approved")
        case .commented: parts.append("commented")
        case .none: break
        }
        if pull.conflicts == .conflicting { parts.append("conflicts") }
        if pull.babysitting.isStopped { parts.append("babysitting stopped") }
        parts.append(pull.worktree?.name ?? "not checked out")
        return parts.joined(separator: " · ")
    }

    /// Fill the page's prompt bar to babysit this one pull request, and show it: where to
    /// work, and what to say. Nothing starts until the person sends it. What babysitting
    /// means is the repository's to say (its instructions or a skill), so the prompt is
    /// just that.
    ///
    /// Where is the worktree it is already checked out in, else a new worktree on its
    /// branch when that branch is here, else a new worktree the agent checks it out into.
    /// The branches are asked for again first, since a fetch since the page opened is
    /// what puts the branch here.
    private func babysit() {
        model.selection = nil
        model.offeredPrompt = "Babysit PR#\(pull.number)"
        Task {
            await model.loadDraftWorktrees()
            let listed = model.draftWorktrees
            let place: WorktreeChoice?
            if let worktree = pull.worktree {
                let root = worktree.root.standardizedFileURL.path
                let isProjectFolder = listed.worktrees.contains {
                    $0.isProjectFolder && $0.root.standardizedFileURL.path == root
                }
                place = isProjectFolder ? nil : .existing(worktree.root)
            } else if listed.branches.contains(where: { $0.name == pull.headBranch }) {
                place = .branch(pull.headBranch)
            } else {
                place = .new
            }
            model.chooseWorktree(place)
        }
    }
}

// MARK: Ready issues

/// One issue in the linked GitHub Project's Ready lane, and Assign, which fills the
/// prompt to start an agent on it in a worktree of its own.
private struct ReadyIssueRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    let issue: GitHubProjectIssue
    let board: GitHubProjectBoard

    private var busyKey: String { "\(board.folder.path)|\(board.projectID ?? "")|\(issue.itemID)" }

    var body: some View {
        WorkRow(issue.title) {
            Text("#\(issue.number)").monospacedDigit().foregroundStyle(.secondary)
                .appText(.fine)
        } detail: {
            Text(issue.labels.isEmpty ? "Ready" : issue.labels.joined(separator: " · "))
        } trailing: {
            Button("Assign") { assign() }
                .buttonStyle(.paper)
                .appText(.fine)
                .disabled(!board.canAssignIssues || model.availableRuntimes.isEmpty
                          || model.assigningGitHubIssues.contains(busyKey))
                .help(board.canAssignIssues ? "Fill the prompt to start an agent on this issue in its own worktree"
                                            : "GitHub Project status needs a Ready and In progress option")
        }
        .onTapGesture { openURL(issue.url) }
        .help(issue.url.absoluteString)
        .contextMenu {
            Button("Open on GitHub") { openURL(issue.url) }
        }
    }

    private func assign() {
        model.selection = nil
        model.pendingGitHubIssueAssignment = (issue, board)
        model.draftRuntimeID = model.draftRuntimeID.flatMap { id in
            model.availableRuntimes.contains { $0.id == id } ? id : nil
        } ?? model.availableRuntimes.first?.runtime.id
        Task { await model.loadDraftOptions() }
        let body = issue.body.trimmingCharacters(in: .whitespacesAndNewlines)
        model.offeredPrompt = "Work on GitHub issue #\(issue.number): \(issue.title)\n\n\(body)"
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: Workflows

/// One workflow: its name and what it is. Opening it shows its page.
private struct WorkflowListRow: View {
    @Environment(AppModel.self) private var model
    let summary: WorkflowSummary

    var body: some View {
        WorkRow(summary.workflow.name) {
            WorkflowStatusIcon(summary: summary)
                .appText(.fine)
        } detail: {
            Text(summary.workflow.summary)
        } trailing: {
            EmptyView()
        }
        .onTapGesture { model.openWorkflow = summary.id }
        .contextMenu {
            Button("Open") { model.openWorkflow = summary.id }
            if summary.awaitingApproval != nil {
                Button("Approve") { Task { await model.approveWorkflow(summary) } }
            } else {
                Button("Run now") { Task { await model.runWorkflow(summary) } }
            }
            Button("Archive") { Task { await model.setWorkflowArchived(summary, true) } }
        }
    }
}
