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
    /// The project's fold, which has its workflows as the search leaves them.
    let fold: SidebarProjectFold
    let folds: SidebarFolds

    private var project: ProjectKey { fold.key }

    var body: some View {
        let workflows = fold.workflows
        let archived = fold.archivedWorkflows
        if !workflows.isEmpty || !archived.isEmpty {
            // Folds as a session group does (#181); a search unfolds it to show what matched.
            let workflowsOpen = fold.isSearching || folds.isOpen(project, .workflows)
            let workflowsFold = Binding(
                get: { workflowsOpen },
                set: { folds.set(project, .workflows, open: $0) })
            DisclosureGroup(isExpanded: workflowsFold) {
                ForEach(FoldedRow.rows(workflowsOpen ? workflows : [], in: .workflows)) { row in
                    WorkflowListRow(summary: row.item, project: project)
                }
            } label: {
                SidebarSubheading(title: "Workflows", count: workflows.count)
                    .togglesFold(workflowsFold)
            }
            if !archived.isEmpty {
                let archivedOpen = fold.isSearching || folds.isOpen(project, .archivedWorkflows)
                let archivedFold = Binding(
                    get: { archivedOpen },
                    set: { folds.set(project, .archivedWorkflows, open: $0) })
                DisclosureGroup(isExpanded: archivedFold) {
                    ForEach(FoldedRow.rows(archivedOpen ? archived : [], in: .archivedWorkflows)) { row in
                        WorkflowListRow(summary: row.item, project: project)
                    }
                } label: {
                    SidebarSubheading(title: "Archived workflows", count: archived.count)
                        .togglesFold(archivedFold)
                }
            }
        }
    }
}

/// A group within a project's fold: Needs you, Working, Workflows, Archived. With how
/// many under it are unread (#70), so finished work is not missed now it sits in Done.
/// One accessibility element, so VoiceOver reads it as one line.
///
/// Each folds (#181), at its chevron or its label (#440), and folded it still says its count and unread. A folded group of
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

/// One workflow: its name, with what it is as its tooltip. Picking it shows its page; the list's own
/// selection lights it, as it does a session's row (066).
struct WorkflowListRow: View {
    @Environment(AppModel.self) private var model
    let summary: WorkflowSummary
    let project: ProjectKey

    var body: some View {
        WorkRow(summary.workflow.name) {
            WorkflowStatusIcon(summary: summary, accented: true)
                .appText(.fine)
        } detail: {
            // The title only (Alex, #495): what it does is the tooltip and the page's.
            EmptyView()
        } trailing: {
            // Marked where it stands, rather than moved (#100): off is not put away.
            if !summary.isEnabled, !summary.isArchived {
                Text("Off")
                    .appText(.fine)
                    .foregroundStyle(.secondary)
            }
        }
        .listRowInsets(.vertical, 2)
        .help(summary.workflow.summary)
        .sidebarInk(.workflow(summary.id, in: project))
        .tag(SidebarItem.workflow(summary.id, in: project))
        .accessibilityElement(children: .combine)
        // Pin or Unpin (#432), from the other edge, as a session's row has it.
        .swipeActions(edge: .leading) {
            if !summary.isArchived {
                let pinned = model.isPinned(summary)
                SwipeAction(pinned ? "Unpin" : "Pin", systemImage: pinned ? "pin.slash" : "pin") {
                    await model.setPinned(summary, !pinned, on: project.host)
                }
                .tint(Paper.accent)
            }
        }
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
            } else if summary.isUnapproved {
                if summary.canBeApproved {
                    Button("Approve") { Task { await model.approveWorkflow(summary) } }
                }
                // Not here, without archiving it everywhere (#391).
                if summary.canBeDenied {
                    Button("Deny on This Host") { Task { await model.denyWorkflow(summary) } }
                }
            } else {
                Button("Run now") { Task { await model.runWorkflow(summary) } }
            }
            if !summary.isArchived {
                let pinned = model.isPinned(summary)
                Button(pinned ? "Unpin" : "Pin") { Task { await model.setPinned(summary, !pinned, on: project.host) } }
                Button(summary.isEnabled ? "Turn Off" : "Turn On") {
                    Task { await model.setWorkflowEnabled(summary, !summary.isEnabled) }
                }
                Button("Archive") { Task { await model.setWorkflowArchived(summary, true) } }
            }
        }
    }
}
