import AgentsKit
import SwiftUI

/// The person's open pull requests on a GitHub project, between Sessions and Workflows
/// (038 US1): what is happening, then what it is happening to, then what will happen.
///
/// Present only on a project whose `origin` is on GitHub, so a project that is not
/// looks exactly as it did (SC-006). Nothing here polls: the daemon refreshes on its own
/// clock and tells the window, and ↻ asks it to now.
struct PullRequestsSection: View {
    @Environment(AppModel.self) private var model
    let folder: URL?
    @Binding var selection: UUID?

    private var list: PullRequestList? {
        folder.flatMap { model.pullRequestLists[Project.standardize($0)] }
    }

    var body: some View {
        if let folder, let list {
            heading(list, folder: folder)
            if list.showsRows {
                if list.pullRequests.isEmpty {
                    empty(list)
                } else {
                    ForEach(list.pullRequests) { pull in
                        PullRequestRow(pull: pull, folder: list.folder, selection: $selection)
                    }
                }
                footer(list)
            } else if let problem = list.problem {
                problemLine(problem)
            }
            if let refused = model.babysitterRefusals[list.folder] {
                Text(refused)
                    .appText(.fine)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 2)
            }
        }
    }

    // MARK: The parts

    private func heading(_ list: PullRequestList, folder: URL) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("Pull requests")
                .appText(.reading).fontWeight(.semibold)
                .accessibilityAddTraits(.isHeader)
            Button {
                Task { await model.refreshPullRequests(for: folder) }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .appText(.fine)
            .foregroundStyle(.secondary)
            .help("Refresh")
            .accessibilityLabel("Refresh pull requests")
            Spacer()
            // With a problem there is nothing to babysit, so no button.
            if list.showsRows {
                if let id = list.babysitterWorkflowID {
                    Button("Show babysitter") { model.openWorkflow = list.folder.path + "/" + id }
                        .buttonStyle(.paper)
                        .appText(.fine)
                } else {
                    Button("Babysit my pull requests") {
                        Task { await model.addBabysitter(in: list.folder) }
                    }
                    .buttonStyle(.paper)
                    .appText(.fine)
                }
            }
        }
        .padding(.top, 22)
        .padding(.bottom, 2)
        .padding(.leading, 2)
    }

    private func empty(_ list: PullRequestList) -> some View {
        Text(list.fetchedAt == nil ? "Looking for your pull requests…"
                                   : "No open pull requests of yours on \(list.repository.fullName)")
            .appText(.reading)
            .foregroundStyle(.secondary)
            .padding(.vertical, 6)
            .padding(.leading, 2)
    }

    /// When the rows are from, or that GitHub couldn't be reached and when these are
    /// from instead (FR-009).
    @ViewBuilder
    private func footer(_ list: PullRequestList) -> some View {
        let count = list.pullRequests.count
        if let fetched = list.fetchedAt {
            Group {
                if list.problem?.isUnreachable == true {
                    Text("Couldn't reach GitHub · showing \(fetched.formatted(date: .omitted, time: .shortened))")
                } else if count > 0 {
                    Text("Fetched \(fetched.formatted(.relative(presentation: .named))) · \(count) open")
                }
            }
            .appText(.fine)
            .foregroundStyle(.tertiary)
            .padding(.top, 4)
            .padding(.leading, 2)
        }
    }

    /// One line instead of the rows, naming the fix (FR-003). The command is text to
    /// copy, never a button: the app does not sign in to GitHub for anybody (FR-002).
    private func problemLine(_ problem: PullRequestProblem) -> some View {
        HStack(spacing: 4) {
            Text(problem.message ?? "Can't see pull requests.")
            if let fix = problem.fix {
                Text(problem.fix == "brew install gh" ? fix : "Run \(fix) in Terminal.")
                    .textSelection(.enabled)
            }
        }
        .appText(.supporting)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .paperRow()
    }
}
