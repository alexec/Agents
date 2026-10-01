import AgentsKitCore
import SwiftUI

/// What the project is working on besides its sessions, under them in the middle column:
/// its workflows. Rows the size of a session's, tagged into the same list selection, so
/// the column is one list: the arrow keys, ⌘-click, ⌫ and the highlight go through
/// both, and a workflow opens its page on the right as a session opens its chat.
///
/// Always there for a project, even with none, so the place to find workflows is always
/// the same place: an empty one says None. Archived workflows fold away at its foot,
/// where their pages (and Bring Back) are. A search narrows it with the sessions, and
/// leaves it out when nothing in it matches.
struct ProjectWorkSections: View {
    @Environment(AppModel.self) private var model
    let folder: URL?
    let query: String

    @AppStorage("showsArchivedWorkflows") private var showsArchived = false

    private var matching: [WorkflowSummary] {
        let words = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let all = model.workflows(in: folder)
        guard !words.isEmpty else { return all }
        return all.filter(SessionLabelQuery(words).matches)
    }
    private var workflows: [WorkflowSummary] { matching.filter { !$0.isArchived } }
    private var archived: [WorkflowSummary] { matching.filter(\.isArchived) }

    var body: some View {
        if folder != nil, query.isEmpty || !matching.isEmpty {
            Section {
                ForEach(workflows) { summary in
                    WorkflowListRow(summary: summary)
                }
                if workflows.isEmpty, query.isEmpty {
                    Text("None")
                        .appText(.fine)
                        .foregroundStyle(.secondary)
                        .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                }
                if !archived.isEmpty {
                    DisclosureGroup(isExpanded: $showsArchived) {
                        ForEach(archived) { summary in
                            WorkflowListRow(summary: summary)
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Text("Archived workflows")
                            Text("\(archived.count)").monospacedDigit().foregroundStyle(.tertiary)
                        }
                        .appText(.fine)
                        .foregroundStyle(.secondary)
                    }
                }
            } header: {
                HStack(spacing: 6) {
                    Text("Workflows")
                    Text("\(workflows.count)").monospacedDigit().foregroundStyle(.tertiary)
                }
            }
            .onChange(of: query) {
                if !query.isEmpty { showsArchived = true }
            }
        }
    }
}

/// The two lines a row here has: an icon, a title, and a grey line under it, with room
/// for one button on the right.
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
    }
}

// MARK: Workflows

/// One workflow: its name and what it is. Picking it shows its page; the list's own
/// selection lights it, as it does a session's row (066).
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
        .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
        .tag(ColumnPick.workflow(summary.id))
        .accessibilityElement(children: .combine)
        .swipeActions(edge: .trailing) {
            if summary.isArchived {
                Button("Bring Back") { Task { await model.setWorkflowArchived(summary, false) } }
            } else {
                Button("Archive", systemImage: "archivebox") {
                    Task { await model.setWorkflowArchived(summary, true) }
                }
                .tint(.gray)
            }
        }
        .contextMenu {
            Button("Open") { model.openWorkflow = summary.id }
            if summary.isArchived {
                Button("Bring Back") { Task { await model.setWorkflowArchived(summary, false) } }
            } else if summary.awaitingApproval != nil {
                Button("Approve") { Task { await model.approveWorkflow(summary) } }
            } else {
                Button("Run now") { Task { await model.runWorkflow(summary) } }
            }
            if !summary.isArchived {
                Button("Archive") { Task { await model.setWorkflowArchived(summary, true) } }
            }
        }
    }
}
