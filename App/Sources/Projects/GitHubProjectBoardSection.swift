import AgentsKit
import SwiftUI

/// The two working lanes from the first GitHub Project linked to this repository.
struct GitHubProjectBoardSection: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @Binding var selection: UUID?
    let folder: URL?
    @State private var assigningIssue: GitHubProjectIssue?

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
            .sheet(item: $assigningIssue) { issue in
                GitHubIssueAssignmentSheet(issue: issue, board: board)
                    .environment(model)
            }
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
                    assigningIssue = issue
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
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("#\(issue.number)")
                    .appText(.fine).monospacedDigit()
                    .foregroundStyle(.secondary)
                Button(issue.title) { openURL(issue.url) }
                    .buttonStyle(.link)
                    .appText(.reading).fontWeight(.medium)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
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
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .paperRow()
    }
}

private struct GitHubIssueAssignmentSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let issue: GitHubProjectIssue
    let board: GitHubProjectBoard
    @State private var runtimeID = ""
    @State private var prompt = ""
    @State private var errorMessage: String?
    @State private var isAssigning = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Assign issue #\(issue.number)")
                    .appText(.title).fontWeight(.semibold)
                Text(issue.title)
                    .appText(.reading)
                    .foregroundStyle(.secondary)
            }
            if model.availableRuntimes.isEmpty {
                Text("No agent runtime is available for this project.")
                    .appText(.supporting)
                    .foregroundStyle(.secondary)
            } else {
                Picker("Agent runtime", selection: $runtimeID) {
                    ForEach(model.availableRuntimes) { status in
                        Text(status.runtime.name).tag(status.runtime.id)
                    }
                }
                .pickerStyle(.menu)
                Text("The issue will start a fresh agent in its own worktree.")
                    .appText(.fine)
                    .foregroundStyle(.secondary)
                Label("Branch: \(WorktreeName.branch(for: WorktreeName.issue(number: issue.number, title: issue.title)))",
                      systemImage: "arrow.branch")
                    .appText(.fine)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            TextField("Task for the agent", text: $prompt, axis: .vertical)
                .lineLimit(4...8)
                .textFieldStyle(.roundedBorder)
            if let errorMessage {
                Text(errorMessage)
                    .appText(.supporting)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Start agent") { start() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(runtimeID.isEmpty || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isAssigning)
            }
        }
        .padding(22)
        .frame(minWidth: 420, idealWidth: 480)
        .onAppear {
            runtimeID = model.draftRuntimeID.flatMap { id in model.availableRuntimes.contains { $0.id == id } ? id : nil }
                ?? model.availableRuntimes.first?.runtime.id ?? ""
            let body = issue.body.trimmingCharacters(in: .whitespacesAndNewlines)
            prompt = "Work on GitHub issue #\(issue.number): \(issue.title)\n\n\(body)"
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private func start() {
        guard let runtime = model.availableRuntimes.first(where: { $0.runtime.id == runtimeID }) else { return }
        isAssigning = true
        errorMessage = nil
        Task {
            do {
                let result = try await model.assign(issue, in: board, runtimeID: runtime.runtime.id, prompt: prompt)
                if result.statusSync == .failed {
                    errorMessage = result.statusSyncProblem?.message ?? "Agent started, but the GitHub status could not be updated."
                    await model.refreshGitHubProjectBoard(for: board.folder)
                }
                dismiss()
            } catch {
                errorMessage = String(describing: error)
                isAssigning = false
            }
        }
    }
}
