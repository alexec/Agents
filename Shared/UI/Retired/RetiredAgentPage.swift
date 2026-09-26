import AgentsKitCore
import SwiftUI

/// What the Mac and the phone show for an agent that has been retired (051, FR-021).
///
/// Reached only through something that names the agent — an event, a "Started by" line,
/// a workflow's run, a link — never listed. It says who the agent was and when it went,
/// in the words `RetirementWords` has for it, and offers nothing to do: there is nothing
/// left to open, unarchive or branch from.
struct RetiredAgentPage: View {
    let tombstone: Tombstone
    /// "Started by …", when the app can name the starter.
    var startedBy: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .appText(.title)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Retired")
                        .appText(.fine)
                        .foregroundStyle(.secondary)
                }
                Text(RetirementWords.retiredSentence(tombstone))
                    .appText(.reading)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Its conversation was deleted. What is left is enough to say who it was.")
                    .appText(.supporting)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    fact("Project", tombstone.project.lastPathComponent)
                    fact("Runtime", tombstone.runtimeID)
                    fact("Started", tombstone.createdAt.formatted(date: .abbreviated, time: .shortened))
                    fact("Archived", tombstone.archivedAt.formatted(date: .abbreviated, time: .shortened))
                    fact("Retired", tombstone.retiredAt.formatted(date: .abbreviated, time: .shortened))
                    if let cost = Cost.total(of: tombstone.costToDate) { fact("Cost", cost) }
                    if let startedBy { fact("Started by", startedBy) }
                    if let workflow = tombstone.startedByWorkflow { fact("Workflow", workflow) }
                    if let worktree = tombstone.worktreeName {
                        fact("Worktree", tombstone.worktreeBranch.map { "\(worktree) (\($0))" } ?? worktree)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 620, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var title: String {
        let trimmed = tombstone.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "An agent" : trimmed
    }

    private func fact(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .appText(.supporting)
                .foregroundStyle(.secondary)
            Text(value)
                .appText(.supporting)
                .textSelection(.enabled)
        }
    }
}
