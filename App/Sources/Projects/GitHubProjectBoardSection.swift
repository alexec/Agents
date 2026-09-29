import AgentsKit
import SwiftUI

/// The two working lanes from the first GitHub Project linked to this repository.
struct GitHubProjectBoardSection: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @Binding var selection: UUID?
    let folder: URL?

    private var board: GitHubProjectBoard? {
        folder.map(Project.standardize).flatMap { model.githubProjectBoards[$0] }
    }

    var body: some View {
        if let folder, let board {
            VStack(alignment: .leading, spacing: 8) {
                header(board, folder: folder)
                if board.projectID == nil {
                    if let problem = board.problem {
                        problemRow(problem)
                    } else {
                        Text("No GitHub Project is linked to this repository.")
                            .appText(.supporting)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 7)
                    }
                } else {
                    if let problem = board.problem { problemRow(problem) }
                    lane("Ready", issues: board.issues.filter { $0.status == .ready }, board: board)
                    lane("In progress", issues: board.issues.filter { $0.status == .inProgress }, board: board)
                    if board.issues.isEmpty {
                        Text("No issues in Ready or In progress.")
                            .appText(.supporting)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 7)
                    }
                    if let fetchedAt = board.fetchedAt {
                        Text(board.problem != nil
                             ? "Couldn't refresh · showing issues from \(fetchedAt.formatted(.relative(presentation: .named)))"
                             : "Updated \(fetchedAt.formatted(.relative(presentation: .named)))")
                            .appText(.fine)
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 2)
                    }
                }
            }
            .padding(.top, 22)
        }
    }

    private func header(_ board: GitHubProjectBoard, folder: URL) -> some View {
        HStack(spacing: 8) {
            Text("GitHub Project")
                .appText(.reading).fontWeight(.semibold)
                .accessibilityAddTraits(.isHeader)
            if let title = board.projectTitle, let url = board.projectURL {
                Button(title) { openURL(url) }
                    .buttonStyle(.link)
                    .appText(.fine)
                    .lineLimit(1)
                    .help("Open GitHub Project")
            }
            Spacer(minLength: 0)
            Button {
                Task { await model.refreshGitHubProjectBoard(for: folder) }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .appText(.fine)
            .foregroundStyle(.secondary)
            .disabled(model.loadingGitHubProjectBoards.contains(Project.standardize(folder)))
            .help("Refresh issues")
            .accessibilityLabel("Refresh GitHub Project issues")
        }
        .padding(.leading, 2)
    }

    @ViewBuilder
    private func lane(_ title: String, issues: [GitHubProjectIssue], board: GitHubProjectBoard) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("\(title) · \(issues.count)")
                .appText(.supporting).fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .padding(.leading, 2)
                .accessibilityAddTraits(.isHeader)
            ForEach(issues) { issue in
                GitHubProjectIssueRow(issue: issue, board: board, selection: $selection) {
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
        }
    }

    private func problemRow(_ problem: GitHubProjectProblem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(problem.message)
                .appText(.supporting)
            if let fix = problem.fix {
                Text("Run \(fix) in Terminal.")
                    .appText(.fine)
                    .textSelection(.enabled)
            }
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .paperRow()
    }
}

private struct GitHubProjectIssueRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    let issue: GitHubProjectIssue
    let board: GitHubProjectBoard
    @Binding var selection: UUID?
    let assign: () -> Void

    private var busyKey: String { "\(board.folder.path)|\(board.projectID ?? "")|\(issue.itemID)" }
    private var assignedAgent: Agent? {
        issue.assignment.flatMap { assignment in model.agents.first { $0.id == assignment.agentID } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // The same first line as a pull request's (PullRequestRow): the whole line
            // is the button that opens it on GitHub.
            Button { openURL(issue.url) } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("#\(issue.number)")
                        .appText(.supporting)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .fixedSize()
                    Text(issue.title)
                        .appText(.reading).fontWeight(.semibold)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .layoutPriority(1)
                    Image(systemName: "arrow.up.right")
                        .appText(.fine)
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(issue.url.absoluteString)
            .accessibilityLabel("#\(issue.number) \(issue.title), open on GitHub")
            if !issue.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(issue.body)
                    .appText(.fine)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if !issue.labels.isEmpty {
                Text(issue.labels.joined(separator: " · "))
                    .appText(.fine)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            if let assignment = issue.assignment {
                HStack(spacing: 7) {
                    if let agent = assignedAgent {
                        Button("Agent · \(agent.title ?? "Issue agent") · \(agent.state.rawValue.capitalized)") {
                            selection = agent.id
                        }
                            .buttonStyle(.paper)
                            .appText(.fine)
                    } else {
                        Label("Agent · \(assignment.agentID.uuidString.prefix(8))", systemImage: "person.crop.circle")
                            .appText(.fine)
                            .foregroundStyle(.secondary)
                    }
                    Label(assignment.worktree.branch ?? assignment.worktree.name, systemImage: "arrow.branch")
                        .appText(.fine)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if assignment.statusSync == .failed {
                        Button("Retry status") {
                            Task {
                                try? await model.syncGitHubIssueStatus(issue, in: board)
                                await model.refreshGitHubProjectBoard(for: board.folder)
                            }
                        }
                        .buttonStyle(.paper)
                        .appText(.fine)
                        .help(assignment.statusSyncProblem?.message ?? "Retry moving this issue to In progress")
                    }
                }
            } else if issue.status == .ready {
                Button(action: assign) {
                    Label("Assign to agent", systemImage: "plus")
                }
                .buttonStyle(.paper)
                .appText(.fine)
                .disabled(!board.canAssignIssues || model.availableRuntimes.isEmpty || model.assigningGitHubIssues.contains(busyKey))
                .help(board.canAssignIssues ? "Start a fresh agent in an issue worktree" : "GitHub Project status needs a Ready and In progress option")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .paperRow()
    }
}
