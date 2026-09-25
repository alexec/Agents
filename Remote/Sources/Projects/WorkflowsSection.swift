import AgentsKitCore
import SwiftUI

/// A project's standing arrangements, under the agents working on it.
///
/// Each row opens the workflow's page, where it can be read whole and driven as on the
/// Mac: Run now, Archive or Restore, and what it is allowed to do. The rows say what
/// is arranged, when it next fires, and what the last fire produced (FR-021) — a
/// workflow being refused every night looks exactly like one whose trigger never
/// matched unless somebody says so.
///
/// Below the agents rather than above, for the Mac's reason: you come to a project to
/// see what is happening, and workflows are what will happen.
struct WorkflowsSection: View {
    @Environment(RemoteModel.self) private var model
    @State private var showsArchived = false

    private var all: [WorkflowSummary] { model.workflows }
    private var live: [WorkflowSummary] { all.filter { !$0.isArchived } }
    private var archived: [WorkflowSummary] { all.filter(\.isArchived) }

    var body: some View {
        if !all.isEmpty {
            SectionHeading(title: "Workflows")
            ForEach(live) { summary in
                WorkflowRow(summary: summary)
            }
            if live.isEmpty, !archived.isEmpty {
                Text("All of this project's workflows are archived.")
                    .appText(.reading)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            }
            if !archived.isEmpty {
                DisclosureHeading(title: "Archived", count: archived.count, isOpen: $showsArchived)
                if showsArchived {
                    ForEach(archived) { summary in
                        WorkflowRow(summary: summary)
                    }
                }
            }
        }
    }
}

/// One workflow: what it is, when it next runs, and what happened last. The whole row
/// opens its page; Run now and Archive are also a long press away.
private struct WorkflowRow: View {
    @Environment(RemoteModel.self) private var model
    let summary: WorkflowSummary

    private var workflow: Workflow { summary.workflow }

    var body: some View {
        NavigationLink(value: RemoteRoute.workflow(summary.id)) {
            card
        }
        .buttonStyle(.plain)
        .contextMenu {
            if summary.isArchived {
                Button {
                    Task { await model.setWorkflowArchived(summary, false) }
                } label: {
                    Label("Restore", systemImage: "arrow.uturn.backward")
                }
            } else {
                Button {
                    Task { await model.runWorkflow(summary) }
                } label: {
                    Label("Run now", systemImage: "play")
                }
                .disabled(summary.isRunning)
                Button {
                    Task { await model.setWorkflowArchived(summary, true) }
                } label: {
                    Label("Archive", systemImage: "archivebox")
                }
            }
        }
    }

    private var card: some View {
        HStack(alignment: .top, spacing: 12) {
            StatusMark(summary: summary)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                Text(workflow.name)
                    .appText(.reading).fontWeight(.semibold)
                    .lineLimit(1)

                Text(workflow.summary)
                    .appText(.supporting)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                if let happening {
                    Text(happening)
                        .appText(.fine)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .appText(.fine)
                .foregroundStyle(.tertiary)
                .padding(.top, 3)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .paperRaised(in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .combine)
    }

    /// When it next runs and what came of the last one, on one line. The words are
    /// `WorkflowOutcome.summary`'s, which is where the Mac reads them, so a refusal
    /// is worded the same on both screens.
    private var happening: String? {
        var parts: [String] = []
        if summary.isRunning {
            parts.append("Running now")
        } else if let next = summary.nextFireAt {
            parts.append("Next \(next.formatted(.relative(presentation: .named)))")
        }
        if let last = summary.lastOutcome { parts.append(last.summary) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// Whether it is running, waiting, refused or put away. Grey, all of it: the app's one
/// colour means something needs a person, and a row's mark is not where that is said.
private struct StatusMark: View {
    let summary: WorkflowSummary

    var body: some View {
        Group {
            if summary.isRunning {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: symbol)
                    // Decorative: a glyph filling a 20-point well, not text (FR-015).
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 20, height: 20)
        .accessibilityHidden(true)
    }

    private var symbol: String {
        if summary.isArchived { return "archivebox" }
        if case .refused = summary.lastOutcome { return "exclamationmark.triangle" }
        if summary.nextFireAt != nil { return "clock" }
        return "circle.dotted"
    }
}
