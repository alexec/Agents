import AgentsKitCore
import SwiftUI

/// What a project is working on besides its sessions, under them in its fold of the
/// sidebar (#145): its workflows. Rows the size of a session's, tagged into the same
/// list selection, so the sidebar is one list: the arrow keys, ⌘-click, ⌫ and the
/// highlight go through both, and a workflow opens its page on the right as a session
/// opens its chat.
///
/// Left out for a project with none, so a fold is as long as its work. Archived
/// workflows fold away at its foot, where their pages (and Bring Back) are. A search
/// narrows it with the sessions, and leaves it out when nothing in it matches.
struct ProjectWorkflowRows: View {
    @Environment(AppModel.self) private var model
    let project: ProjectKey
    let query: String
    let folds: SidebarFolds

    private var matching: [WorkflowSummary] {
        let words = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let all = model.workflows(in: project.folder)
        guard !words.isEmpty else { return all }
        return all.filter(SessionLabelQuery(words).matches)
    }

    var body: some View {
        let matching = matching
        let workflows = matching.filter { !$0.isArchived }
        let archived = matching.filter(\.isArchived)
        if !matching.isEmpty {
            // Folds as a session group does (#181); a search unfolds it to show what matched.
            DisclosureGroup(isExpanded: Binding(
                get: { !query.isEmpty || folds.isOpen(project, .workflows) },
                set: { folds.set(project, .workflows, open: $0) })) {
                ForEach(workflows) { summary in
                    WorkflowListRow(summary: summary, project: project)
                }
            } label: {
                SidebarSubheading(title: "Workflows", count: workflows.count)
            }
            if !archived.isEmpty {
                DisclosureGroup(isExpanded: Binding(
                    get: { !query.isEmpty || folds.isOpen(project, .archivedWorkflows) },
                    set: { folds.set(project, .archivedWorkflows, open: $0) })) {
                    ForEach(archived) { summary in
                        WorkflowListRow(summary: summary, project: project)
                    }
                } label: {
                    SidebarSubheading(title: "Archived workflows", count: archived.count)
                }
            }
        }
    }
}

/// A group within a project's fold: Needs you, Working, Workflows, Archived. With how
/// many under it are unread (#70), so finished work is not missed now it sits in Done.
/// One accessibility element, so VoiceOver reads it as one line.
///
/// Each folds (#181), and folded it still says its count and unread. A folded group of
/// sessions that need a person keeps its count in the attention tint, so folding Needs
/// you never hides that somebody is waiting.
struct SidebarSubheading: View {
    let title: String
    let count: Int
    var unread: Int = 0
    var tint: StateTint = .none

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
            Text("\(count)").monospacedDigit().foregroundStyle(tint.style(or: .tertiary))
            if unread > 0 {
                Text("· \(unread) unread").monospacedDigit()
            }
        }
        .appText(.fine)
        .foregroundStyle(.secondary)
        .padding(.top, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(unread > 0 ? "\(title), \(count), \(unread) unread" : "\(title), \(count)")
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
        .padding(.vertical, 2)
    }
}

// MARK: Workflows

/// One workflow: its name and what it is. Picking it shows its page; the list's own
/// selection lights it, as it does a session's row (066).
private struct WorkflowListRow: View {
    @Environment(AppModel.self) private var model
    let summary: WorkflowSummary
    let project: ProjectKey

    var body: some View {
        WorkRow(summary.workflow.name) {
            WorkflowStatusIcon(summary: summary)
                .appText(.fine)
        } detail: {
            Text(summary.workflow.summary)
        } trailing: {
            // Marked where it stands, rather than moved (#100): off is not put away.
            if !summary.isEnabled, !summary.isArchived {
                Text("Off")
                    .appText(.fine)
                    .foregroundStyle(.secondary)
            }
        }
        .listRowInsets(.vertical, 2)
        .sidebarInk(.workflow(summary.id, in: project))
        .tag(SidebarItem.workflow(summary.id, in: project))
        .accessibilityElement(children: .combine)
        .swipeActions(edge: .trailing) {
            if summary.isArchived {
                SwipeAction("Bring Back") { await model.setWorkflowArchived(summary, false) }
            } else {
                SwipeAction("Archive", systemImage: "archivebox") {
                    await model.setWorkflowArchived(summary, true)
                }
                .tint(.gray)
            }
        }
        .contextMenu {
            Button("Open") { model.sidebarItem = .workflow(summary.id, in: project) }
            if summary.isArchived {
                Button("Bring Back") { Task { await model.setWorkflowArchived(summary, false) } }
            } else if summary.awaitingApproval != nil {
                if summary.canBeApproved {
                    Button("Approve") { Task { await model.approveWorkflow(summary) } }
                }
            } else {
                Button("Run now") { Task { await model.runWorkflow(summary) } }
            }
            if !summary.isArchived {
                Button(summary.isEnabled ? "Turn Off" : "Turn On") {
                    Task { await model.setWorkflowEnabled(summary, !summary.isEnabled) }
                }
                Button("Archive") { Task { await model.setWorkflowArchived(summary, true) } }
            }
        }
    }
}
