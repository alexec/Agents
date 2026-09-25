import AgentsKit
import SwiftUI

/// One agent on a project page: what it is, and what it is doing.
///
/// An icon for the state, the name it was given, and a line saying what it is working
/// on. The name is what it was asked; the line under it is what is happening now, which
/// is the thing you came to find out.
struct AgentRow: View {
    @Environment(AppModel.self) private var model
    let agent: Agent

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            StatusIcon(state: agent.state, isComingBack: isComingBack,
                       outcome: agent.report?.outcome,
                       isUnaccountedFor: agent.endingIsUnaccountedFor,
                       ending: agent.endedReason?.summary)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(agent.title ?? "Untitled")
                        .appText(.reading).fontWeight(.semibold)
                        .lineLimit(1)
                    // Started by a workflow rather than a person: the one thing about
                    // an agent's origin worth a mark, because it is the difference
                    // between something you asked for and something that ran itself.
                    if let workflowName = startedByWorkflowName {
                        Image(systemName: "clock.arrow.circlepath")
                            .appText(.fine)
                            .foregroundStyle(.tertiary)
                            .help("Started by the workflow \(workflowName)")
                            .accessibilityLabel("started by the workflow \(workflowName)")
                    }
                    // Started by another agent (028): the same kind of mark, for the
                    // same reason — this is not something the person typed for.
                    if let starter = model.startedByAgentLabel(agent) {
                        Image(systemName: AgentsModel.startedByAgentSymbol)
                            .appText(.fine)
                            .foregroundStyle(.tertiary)
                            .help(starter)
                            .accessibilityLabel(starter)
                    }
                }

                // The agent's own account of its last turn, and nothing else. This line
                // used to be whichever of five things was true — a plan step, the
                // report, "Waiting for your answer", why it stopped — with the runtime
                // and a step count under it, and a row that says a different kind of
                // thing depending on state is a row nobody can read at a glance. The
                // state is the icon's; what it is doing is the title, which the agent
                // keeps current; this is what it said.
                if let report = agent.report?.message {
                    Text(report)
                        .appText(.supporting)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .contextMenu {
            if model.canStop(agent) {
                Button("Stop") { Task { await model.stop(agent.id) } }
            }
            if agent.state == .archived {
                Button("Bring back") { Task { await model.unarchive(agent.id) } }
            } else {
                // Branching leaves the original alone and carries the history so far.
                Button("Branch") { Task { await model.fork(agent.id) } }
                Button("Archive") { Task { await model.archive(agent.id) } }
            }
            Divider()
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([agent.cwd])
            }
        }
    }

    /// Whether the daemon is bringing this chat back by itself after a restart.
    private var isComingBack: Bool { model.isComingBack(agent) }

    /// The name of the workflow that started this agent, if one did — or its id when
    /// the file has since gone, so the mark never disappears with it.
    private var startedByWorkflowName: String? {
        guard let id = agent.startedByWorkflow else { return nil }
        return model.workflows(in: agent.cwd).first { $0.workflow.workflowID == id }?.workflow.name ?? id
    }
}

/// What state an agent is in, as one of four shapes.
///
/// The shape is `StatusShape`'s, which the phone's card draws from too. Grey, all of
/// it, except the one that wants you: the only colour in this app means something
/// needs a person. The finer distinctions — which outcome, why it stopped, whether
/// anyone vouched for the ending — are still said, in the tooltip and to a screen
/// reader, rather than drawn.
struct StatusIcon: View {
    let state: AgentState
    /// The daemon is bringing this chat back by itself after a restart.
    var isComingBack = false
    /// What the agent said about the work, where it said anything.
    var outcome: WorkOutcome?
    /// A turn that ended cleanly, was asked how it went, and still said nothing.
    var isUnaccountedFor = false
    /// Why it stopped, where it did, in `EndedReason`'s words.
    var ending: String?

    private var shape: StatusShape {
        StatusShape(state: state, outcome: outcome, isComingBack: isComingBack)
    }

    var body: some View {
        Group {
            if let symbol = shape.symbol {
                Image(systemName: symbol)
                    // Decorative: a glyph filling an 18-point well, not text (FR-015).
                    .font(.system(size: 15))
                    .foregroundStyle((shape.wantsAPerson ? StateTint.attention : .none)
                        .style(or: .secondary))
            } else {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
            }
        }
        .frame(width: 18, height: 18)
        .help(description)
        .accessibilityLabel(description)
    }

    /// The outcome, where the turn it describes is the one the agent is settled on.
    private var settledOutcome: WorkOutcome? {
        state == .finished && !isComingBack ? outcome : nil
    }

    /// What a screen reader hears, and what the tooltip says. Precise where the shape
    /// is not: the outcome's words come from `WorkOutcome.heading`, which the phone
    /// reads too, and a stopped agent says why.
    private var description: String {
        if isComingBack { return AgentsModel.comingBackDescription }
        if let settledOutcome { return settledOutcome.heading }
        if isUnaccountedFor && state == .finished { return "Finished without saying how it went" }
        switch state {
        case .running: return "Working"
        case .starting: return AgentState.startingLabel
        case .waitingOnUser: return "Waiting on you"
        case .finished: return "Finished"
        case .stopped: return ending ?? "Stopped"
        case .archived: return "Archived"
        }
    }
}
