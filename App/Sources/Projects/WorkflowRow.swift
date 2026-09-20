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
        // The whole card is the button, exactly as an agent's card is (`AgentCard`):
        // the content is the label, the glass is interactive, and the play button and
        // the Ran → link inside keep their own clicks because a nested button wins
        // its own hit. A button *behind* the card was tried first and a real mouse
        // never reached it through the glass.
        Button { model.openWorkflow = summary.id } label: {
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
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open \(workflow.name)")
        .contextMenu {
            // The contract said the menu gains nothing because opening is what the row
            // does by itself. It is here because the row did not, on a real mouse, and
            // a page nobody can reach is worse than a menu with one more line.
            Button("Open") { model.openWorkflow = summary.id }
            Divider()
            if summary.isArchived {
                Button("Restore") { Task { await model.setWorkflowArchived(summary, false) } }
            } else {
                Button("Run now") { Task { await model.runWorkflow(summary) } }
                Button("Archive") { Task { await model.setWorkflowArchived(summary, true) } }
            }
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
                // Only when something follows it. A workflow that has never fired has
                // nothing on the right of the dot, and a separator separating one thing
                // reads as a line that got cut off.
                if hasHappened { Text("·") }
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
                // What the run's agent said about the work, in its own words. Without
                // this the row can say a run happened and nothing about whether it was
                // any good, which is the whole of the fourth story: four quiet nights
                // and one that stopped half way look identical otherwise.
                if let said = ranReport?.message {
                    Text("·")
                    Text(said).lineLimit(1).truncationMode(.tail)
                }
            } else if let outcome = outcomeText {
                Text(outcome)
            }
        }
        .font(.caption)
        // Grey unless somebody is needed. The attention tint is `StateTint`'s to name,
        // and spending it on a workflow that skipped a single fire would be spending
        // it on nothing. An agent that said it cannot get further without a person
        // earns it on the same terms a refusal that needs one does.
        .foregroundStyle((wantsAPerson ? StateTint.attention : .none).style(or: .tertiary))
        .lineLimit(1)
    }

    /// What the agent this workflow's last run started said about how it went.
    ///
    /// Looked up rather than copied onto the workflow record: `WorkflowOutcome.ran`
    /// already carries the agent's id, and a second copy of the report would be a
    /// second thing to keep in step with the first.
    private var ranReport: WorkReport? {
        model.work.agent(ranAgentID)?.report
    }

    /// Whether this row wants a person: because the workflow itself does, or because
    /// the agent its last run started said so.
    private var wantsAPerson: Bool {
        summary.needsAPerson || ranReport?.outcome.needsAPerson == true
    }

    /// One icon, and on an archived row one word.
    ///
    /// An icon because this row repeats down the page and a word would be the loudest
    /// thing on it. Archiving is not here: it is the same two-finger swipe an agent's
    /// card takes, and it is a button on the workflow's own page, one click from going
    /// back to the project — the way it is on a chat. The context menu still has both.
    private var controls: some View {
        HStack(spacing: 6) {
            // An archived workflow gets one control, and it is the way back. Nothing
            // else on this row does anything while it is put away, and offering to run
            // a thing that will not run would be offering a lie.
            if summary.isArchived {
                Button("Restore") { Task { await model.setWorkflowArchived(summary, false) } }
                    .buttonStyle(.glass)
                    .font(.caption)
            } else {
                if summary.isRunning {
                    Text("Running…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    // Offered on every row, always — including one whose triggers this
                    // version cannot act on, and one over a ceiling. Being able to try a
                    // workflow is what makes writing one worth doing, and a refusal says
                    // why on the row rather than doing nothing.
                    Button {
                        Task { await model.runWorkflow(summary) }
                    } label: {
                        Image(systemName: "play")
                    }
                    .buttonStyle(.glass)
                    .help("Run this workflow now")
                }
            }
        }
    }

    private var nextText: String? {
        guard !summary.isArchived, summary.overLimit == nil,
              let next = summary.nextFireAt else { return nil }
        return "Next \(next.formatted(.relative(presentation: .named)))"
    }

    /// Whether anything is drawn after the next-fire time.
    private var hasHappened: Bool { ranAgentID != nil || outcomeText != nil }

    /// The id of the agent the last run started, if the last thing that happened was
    /// a run rather than a refusal.

    private var ranAgentID: UUID? {
        if case .ran(let agentID, _) = summary.lastOutcome { return agentID }
        return nil
    }

    /// What happened last, said plainly. A workflow that is not going to run says that
    /// instead, because it is the more useful fact about it.
    private var outcomeText: String? {
        if summary.isArchived { return "Archived — it will not run" }
        // Ahead of the pause, because unpausing it would change nothing: what has to
        // happen is that something else goes.
        if let limit = summary.overLimit {
            return "\(limit.sentence). \(limit.remedy)"
        }
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
            .foregroundStyle((summary.needsAPerson ? StateTint.attention : .none).style(or: .secondary))
            .accessibilityLabel(label)
    }

    private var name: String {
        if summary.isArchived { return "archivebox" }
        if summary.needsAPerson { return "exclamationmark.triangle" }
        if summary.isRunning { return "circle.dotted" }
        if !summary.workflow.canFire { return "circle.dashed" }
        return "clock"
    }

    private var label: String {
        if summary.isArchived { return "Archived" }
        if summary.overLimit != nil { return "Over the limit" }
        if summary.needsAPerson { return "Needs attention" }
        if summary.isRunning { return "Running" }
        if !summary.workflow.canFire { return "Not yet supported" }
        return "Waiting for its trigger"
    }
}
