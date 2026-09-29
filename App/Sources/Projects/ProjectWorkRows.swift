import AgentsKit
import SwiftUI

/// What the project is working on besides its sessions, under them in the middle column
/// and above Archived: its workflows. A list section of rows the size of a session's, so
/// the column reads as one list, and each opens its page on the right as a session opens
/// its chat.
///
/// Always there for a project, even with none, so the place to find workflows is always
/// the same place: an empty one says what a workflow is and offers to have an agent write
/// one. Archived workflows fold away at its foot, where their pages (and Bring Back) are.
struct ProjectWorkSections: View {
    @Environment(AppModel.self) private var model
    let folder: URL?

    @AppStorage("showsArchivedWorkflows") private var showsArchived = false

    private var workflows: [WorkflowSummary] {
        model.workflows(in: folder).filter { !$0.isArchived }
    }
    private var archived: [WorkflowSummary] {
        model.workflows(in: folder).filter(\.isArchived)
    }

    var body: some View {
        if folder != nil {
            Section {
                ForEach(workflows) { summary in
                    WorkflowListRow(summary: summary)
                }
                if workflows.isEmpty {
                    NoWorkflowsLine()
                }
                if !archived.isEmpty {
                    DisclosureGroup(isExpanded: $showsArchived) {
                        ForEach(archived) { summary in
                            WorkflowListRow(summary: summary)
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Text("Archived")
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
        }
    }
}

/// What a project with no workflows shows under the heading: what one is, and a way to
/// get one that needs no file format learned — ask an agent, in the prompt beside it.
private struct NoWorkflowsLine: View {
    @Environment(AppModel.self) private var model
    @Environment(WindowRequests.self) private var requests

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("None yet. A workflow gives an agent a prompt by itself: on a schedule, or when something happens in this project.")
                .appText(.fine)
                .foregroundStyle(.secondary)
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)
            Button("Ask an agent to write one") {
                model.selection = nil
                model.openWorkflow = nil
                model.offeredPrompt = "Add a workflow to this project. Ask me what it should do and when it should run, then write it into .agents/workflows."
                requests.focusPrompt()
            }
            .buttonStyle(.link)
            .appText(.fine)
            .help("Fill the prompt to have an agent ask what the workflow should do, then write it")
        }
        .padding(.vertical, 4)
        .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
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

/// One workflow: its name and what it is. Opening it shows its page.
private struct WorkflowListRow: View {
    @Environment(AppModel.self) private var model
    let summary: WorkflowSummary

    var body: some View {
        // The row is the button, so a click, VoiceOver and the keyboard all open it.
        Button { model.openWorkflow = summary.id } label: {
            WorkRow(summary.workflow.name) {
                WorkflowStatusIcon(summary: summary)
                    .appText(.fine)
            } detail: {
                Text(summary.workflow.summary)
            } trailing: {
                EmptyView()
            }
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
        .accessibilityLabel(summary.workflow.name)
        .accessibilityAddTraits(model.openWorkflow == summary.id ? [.isButton, .isSelected] : .isButton)
        // Lit while its page is the one on the right, as a session's row is while its
        // chat is (066). The list's own selection is the sessions', so drawn here.
        .listRowBackground(
            RoundedRectangle(cornerRadius: 5)
                .fill(model.openWorkflow == summary.id ? AnyShapeStyle(.selection) : AnyShapeStyle(.clear))
                .padding(.horizontal, 10))
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
