import AgentsKitCore
import SwiftUI

/// A folder's workflows, under its sessions in its fold of the sidebar (#145): a
/// Workflows row with a chevron and a grey count, and when it is open the workflows one
/// level in, as a mailbox's sub-mailboxes in Mail (#885). Rows the size of a session's,
/// tagged into the same list selection, so the sidebar is one list: the arrow keys,
/// ⌘-click, ⌫ and the highlight go through both, and a workflow opens its page on the
/// right as a session opens its chat.
///
/// Closed until opened, and kept per folder (Alex, #885). Left out for a folder with
/// no live workflow; pinned ones are in Pinned (#432) and archived ones on the Archived
/// page (#495). A search opens it to show what matched.
struct FolderWorkflowRows: View {
    /// The folder's fold, which has its workflows as the search leaves them.
    let fold: SidebarFolderFold
    let folds: SidebarFolds

    private var folder: FolderKey { fold.key }

    var body: some View {
        let workflows = fold.workflows
        if !workflows.isEmpty {
            let isOpen = fold.isSearching || folds.isOpen(folder, .workflows)
            let workflowsFold = Binding(
                get: { isOpen },
                set: { folds.set(folder, .workflows, open: $0) })
            // A plain row rather than a `DisclosureGroup`, whose chevron the list puts by
            // its own indent (#1079): the chevron in the session rows' mark column, the
            // word at their titles, and the workflows one level in, under the word.
            SidebarFoldRow(title: "Workflows", count: workflows.count, isOpen: workflowsFold)
            // A closed fold has no rows at all (#237).
            if isOpen {
                if !fold.folderWorkflows.isEmpty {
                    workflowGroup("Folder workflows", rows: fold.folderWorkflows)
                }
                if !fold.userWorkflows.isEmpty {
                    workflowGroup("User workflows", rows: fold.userWorkflows)
                }
            }
        }
    }

    @ViewBuilder
    private func workflowGroup(_ title: String, rows: [WorkflowSummary]) -> some View {
        SidebarSubheading(title: title, count: rows.count)
            .padding(.leading, 22)
        ForEach(FoldedRow.rows(rows, in: .workflows)) { row in
            WorkflowListRow(summary: row.item, folder: folder, isNested: true)
        }
    }
}

/// The Workflows row of a folder's fold (#885), and its Sessions row (#2312): a chevron in
/// the sidebar's icon column, 16 wide and 6 to the title as a session's mark, then the
/// subheading. A click anywhere on it folds or unfolds it (#440); VoiceOver has it as one
/// button that says which.
struct SidebarFoldRow: View {
    let title: String
    let count: Int
    @Binding var isOpen: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.right")
                .rotationEffect(.degrees(isOpen ? 90 : 0))
                .appText(.fine)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            SidebarSubheading(title: title, count: count)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        // Beside the list's own handling, as `togglesFold` (#440).
        .simultaneousGesture(TapGesture().onEnded { isOpen.toggle() })
        // One label, over children it ignores: one stacked on the subheading's crashes AppKit.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(count)")
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(isOpen ? "open" : "folded")
        .accessibilityAction { isOpen.toggle() }
    }
}

/// A group within a folder's fold: Needs you, Working, Workflows, Archived. With how
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
    /// Heavier only when the row needs someone (#520).
    var emphasized = false
    let leading: Leading
    let detail: Detail
    let trailing: Trailing

    init(_ title: String, emphasized: Bool = false, @ViewBuilder leading: () -> Leading, @ViewBuilder detail: () -> Detail,
         @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.emphasized = emphasized
        self.leading = leading()
        self.detail = detail()
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                // The sidebar's icon column (#495): 16 wide, 6 to the title.
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    leading
                        .frame(width: 16)
                    Text(title)
                        .appText(.supporting).fontWeight(emphasized ? .semibold : .regular)
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
    /// In a folder's own window, how it opens what is picked (#1090).
    @Environment(\.windowOpen) private var windowOpen

    /// In this window: a folder's own, or the main window's selection.
    private func open(_ item: SidebarItem) {
        if let windowOpen { windowOpen(item) } else { model.sidebarItem = item }
    }
    let summary: WorkflowSummary
    let folder: FolderKey
    /// In its folder's Workflows fold: one level in, under the word Workflows (#1079).
    var isNested = false
    @State private var confirmsDelete = false

    var body: some View {
        // Heavier only while it waits for an OK (#520), as a session's title is while unread.
        WorkRow(summary.workflow.name, emphasized: summary.awaitingApproval != nil && !summary.isArchived) {
            WorkflowStatusIcon(summary: summary, accented: true)
                .appText(.fine)
        } detail: {
            EmptyView()
        } trailing: {
            // When it last ran, as a session's row has its time (#755); nothing if it never
            // has. A running one counts from when this run started. Off is marked where it
            // stands, rather than moved (#100), by its icon and its tooltip.
            HStack(spacing: 4) {
                // Its runs send no notifications (#2003), marked as a muted session is.
                if summary.workflow.isMuted, !summary.isArchived {
                    Image(systemName: MuteWords.symbol)
                        .appText(.fine)
                        .sidebarMark(.tertiary)
                        .help(MuteWords.mutedHelp)
                        .accessibilityLabel(MuteWords.muted)
                }
                if let at = summary.lastFiredAt {
                    ActivityTime(date: at)
                }
            }
        }
        .padding(.leading, isNested ? 22 : 0)
        .listRowInsets(.vertical, 2)
        // A user workflow says it is in every folder (#2759), pinned or under Needs You too.
        .help(summary.rowHelp)
        .sidebarInk(.workflow(summary.id, in: folder))
        .tag(SidebarItem.workflow(summary.id, in: folder))
        .accessibilityElement(children: .combine)
        .accessibilityValue(summary.scopeSentence ?? "")
        // Pin or Unpin (#432), from the other edge, as a session's row has it.
        .swipeActions(edge: .leading) {
            if !summary.isArchived {
                let pinned = model.isPinned(summary)
                SwipeAction(pinned ? "Unpin" : "Pin", systemImage: pinned ? "pin.slash" : "pin") {
                    await model.setPinned(summary, !pinned, on: folder.host)
                }
                .tint(Paper.accent)
            }
        }
        .swipeActions(edge: .trailing) {
            if summary.isArchived {
                SwipeAction("Unarchive") { await model.setWorkflowArchived(summary, false) }
            } else {
                SwipeAction("Archive", systemImage: "archivebox") {
                    await model.setWorkflowArchived(summary, true)
                }
                .tint(.gray)
            }
        }
        .contextMenu {
            Button("Open") { open(.workflow(summary.id, in: folder)) }
            if summary.isArchived {
                Button("Unarchive") { Task { await model.setWorkflowArchived(summary, false) } }
            } else if summary.isUnapproved {
                if summary.canBeApproved {
                    Button("Approve") { Task { await model.approveWorkflow(summary) } }
                }
                // Not here, without archiving it everywhere (#391).
                if summary.canBeDenied {
                    Button("Deny on This Machine") { Task { await model.denyWorkflow(summary) } }
                }
            } else if summary.runsHere {
                Button("Run now") { Task { await model.runWorkflow(summary) } }
            }
            if !summary.isArchived {
                let pinned = model.isPinned(summary)
                Button(pinned ? "Unpin" : "Pin") { Task { await model.setPinned(summary, !pinned, on: folder.host) } }
                Button(summary.isEnabled ? "Turn Off" : "Turn On") {
                    Task { await model.setWorkflowEnabled(summary, !summary.isEnabled) }
                }
                if model.host(folder.host, has: Capability.mute1) {
                    let muted = summary.workflow.isMuted
                    Button(MuteWords.label(muted: muted)) {
                        Task { await model.setWorkflowMuted(summary, !muted, on: folder.host) }
                    }
                    .help(MuteWords.workflowHelp(muted: muted))
                }
                Button("Archive") { Task { await model.setWorkflowArchived(summary, true) } }
            }
            Divider()
            Button("Delete…", role: .destructive) { confirmsDelete = true }
        }
        .confirmationDialog("Delete \"\(summary.workflow.name)\"? Its file is removed from disk.",
                            isPresented: $confirmsDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { Task { await model.deleteWorkflow(summary, on: folder.host) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The file can be restored from the folder's git history.")
        }
    }
}
