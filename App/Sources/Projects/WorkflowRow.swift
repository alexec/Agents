import AgentsKit
import SwiftUI

/// One workflow on a project page: what it is, and what is happening to it.
///
/// The same three lines an `AgentRow` uses, deliberately, so the page has one way of
/// describing a thing rather than two. The name, then what it is — its trigger, in the
/// words a person would use rather than the metadata it was written as — then what is
/// happening: when it next runs, and what the last fire produced.
///
/// That third line is the whole of the third user story. A workflow that fires leaves
/// an agent behind and the list below makes that obvious. A workflow that is refused
/// leaves nothing at all, and without this line a workflow skipping every fire looks
/// exactly like one whose trigger never matched.
struct WorkflowRow: View {
    @Environment(AppModel.self) private var model
    let summary: WorkflowSummary
    @Binding var selection: UUID?

    private var workflow: Workflow { summary.workflow }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            WorkflowStatusIcon(summary: summary)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                Text(workflow.name)
                    .font(.headline)
                    .lineLimit(1)

                Text(workflow.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                happening
            }

            Spacer(minLength: 8)
            controls
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14))
        .contextMenu {
            Button(summary.isPaused ? "Resume" : "Pause") {
                Task { await model.setWorkflowPaused(summary, !summary.isPaused) }
            }
            Button("Run now") { Task { await model.runWorkflow(summary) } }
            Divider()
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([
                    WorkflowFile.url(for: workflow.workflowID, in: workflow.folder)
                ])
            }
        }
    }

    /// When it next runs, and what happened last — the line that makes a refusal
    /// visible at all.
    @ViewBuilder
    private var happening: some View {
        HStack(spacing: 4) {
            if let next = nextText {
                Text(next)
                Text("·")
            }
            if let agentID = ranAgentID {
                // A run leads to the agent it started. The only thing on this row that
                // goes anywhere, because it is the only thing that has somewhere to go.
                Button { selection = agentID } label: {
                    HStack(spacing: 2) {
                        Text(outcomeText ?? "Ran")
                        Image(systemName: "arrow.right")
                    }
                }
                .buttonStyle(.link)
            } else if let outcome = outcomeText {
                Text(outcome)
            }
        }
        .font(.caption)
        // Grey unless somebody is needed. The app's one use of colour, and spending it
        // on a workflow that skipped a single fire would be spending it on nothing.
        .foregroundStyle(summary.needsAPerson ? AnyShapeStyle(Color.red) : AnyShapeStyle(.tertiary))
        .lineLimit(1)
    }

    private var controls: some View {
        HStack(spacing: 6) {
            if summary.isRunning {
                Text("Running…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                // Offered on every row, always — including a paused one and one whose
                // triggers this version cannot act on. Being able to try a workflow is
                // what makes writing one worth doing.
                Button("Run now") { Task { await model.runWorkflow(summary) } }
                    .buttonStyle(.glass)
                    .font(.caption)
            }
            Button {
                Task { await model.setWorkflowPaused(summary, !summary.isPaused) }
            } label: {
                Image(systemName: summary.isPaused ? "play" : "pause")
            }
            .buttonStyle(.glass)
            .help(summary.isPaused ? "Resume this workflow" : "Pause this workflow")
        }
    }

    private var nextText: String? {
        guard !summary.isPaused, let next = summary.nextFireAt else { return nil }
        return "Next \(next.formatted(.relative(presentation: .named)))"
    }

    private var ranAgentID: UUID? {
        if case .ran(let agentID, _) = summary.lastOutcome { return agentID }
        return nil
    }

    /// What happened last, said plainly. A paused workflow says so instead, because
    /// that is the more useful fact about it.
    private var outcomeText: String? {
        if summary.isPaused { return "Paused" }
        guard let outcome = summary.lastOutcome else { return nil }
        let when = outcome.at.formatted(.relative(presentation: .named))
        switch outcome {
        case .ran: return "Ran \(when)"
        case .refused: return outcome.summary
        }
    }
}

/// What state a workflow is in, as one symbol.
///
/// Grey, all of it, except the one that wants you — the same rule the agent list
/// follows, and the reason it holds here is that most refusals resolve themselves.
private struct WorkflowStatusIcon: View {
    let summary: WorkflowSummary

    var body: some View {
        Image(systemName: name)
            .font(.callout)
            .foregroundStyle(summary.needsAPerson ? AnyShapeStyle(Color.red) : AnyShapeStyle(.secondary))
            .accessibilityLabel(label)
    }

    private var name: String {
        if summary.needsAPerson { return "exclamationmark.triangle" }
        if summary.isRunning { return "circle.dotted" }
        if summary.isPaused { return "pause.circle" }
        if !summary.workflow.canFire { return "circle.dashed" }
        return "clock"
    }

    private var label: String {
        if summary.needsAPerson { return "Needs attention" }
        if summary.isRunning { return "Running" }
        if summary.isPaused { return "Paused" }
        if !summary.workflow.canFire { return "Not yet supported" }
        return "Waiting for its trigger"
    }
}
