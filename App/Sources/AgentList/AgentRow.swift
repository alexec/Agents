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
                       outcome: agent.report?.outcome)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                Text(agent.title ?? "Untitled")
                    .font(.headline)
                    .lineLimit(1)

                Text(description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .contextMenu {
            if agent.state.holdsRuntime {
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

    /// What it is doing, in its own words where it has said them.
    ///
    /// Coming back wins over everything, including whatever step the agent last named:
    /// that step is from the turn the daemon took with it, and saying it now would be
    /// describing work nothing is doing.
    private var description: String {
        if isComingBack { return AgentsModel.comingBackDescription }
        if let step = agent.currentStep { return step }
        // The agent's own words about the turn that just ended, in preference to
        // anything we would otherwise derive (FR-013). It wrote them for somebody who
        // has not read the conversation, which is exactly who is reading this row.
        if let message = agent.report?.message { return message }
        switch agent.state {
        case .running: return "Working"
        case .waitingOnUser: return "Waiting for your answer"
        // Never "Complete" on the strength of the turn ending. That word belongs to
        // `AgentGroup.finished`, which is the heading, and to an agent that reported
        // `done`, which is a claim somebody made (FR-012).
        case .finished: return "Finished"
        case .stopped: return ending ?? "Stopped"
        case .archived: return "Archived"
        }
    }

    /// The runtime, and how far through its plan it is.
    private var detail: String? {
        var parts = [runtimeName]
        if agent.state.holdsRuntime, let progress = agent.planProgress {
            // Clamped, because the last step being done would read "step 6 of 5".
            let step = min(progress.done + 1, progress.total)
            parts.append("step \(step) of \(progress.total)")
        }
        return parts.joined(separator: " · ")
    }

    private var runtimeName: String {
        RuntimeCatalog.runtime(id: agent.runtimeID)?.name ?? agent.runtimeID
    }

    /// Stopped short, and why. The words live on `EndedReason`, so this row and the
    /// phone's card say the same thing about the same agent.
    private var ending: String? { agent.endedReason?.summary }
}

/// What state an agent is in, as one symbol.
///
/// Grey, all of it, except the one that wants you: the only colour in this app means
/// something needs a person.
struct StatusIcon: View {
    let state: AgentState
    /// Its own symbol rather than a spinner: nothing is running yet, and the row
    /// stays under "Stopped" until the chat's own state moves it.
    var isComingBack = false
    /// What the agent said about the work, where it said anything. Filled means
    /// somebody said so, hollow means nobody did, and orange means you.
    var outcome: WorkOutcome?

    var body: some View {
        Group {
            if state == .running {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
            } else {
                Image(systemName: symbol)
                    .font(.system(size: 15))
                    .foregroundStyle(tint)
            }
        }
        .frame(width: 18, height: 18)
        .help(description)
        .accessibilityLabel(description)
    }

    /// The outcome, where the turn it describes is the one the agent is settled on.
    /// A stopped or archived agent keeps its own symbol whatever it last claimed,
    /// which is the rule `AgentGroup` follows for the same reason.
    private var settledOutcome: WorkOutcome? {
        state == .finished && !isComingBack ? outcome : nil
    }

    private var symbol: String {
        if isComingBack { return AgentsModel.comingBackSymbol }
        if let settledOutcome {
            switch settledOutcome {
            case .done: return "checkmark.circle.fill"
            case .nothingToDo: return "checkmark.circle"
            case .needsAnswer: return "questionmark.circle.fill"
            case .partlyDone: return "circle.lefthalf.filled"
            case .stuck: return "exclamationmark.triangle.fill"
            }
        }
        switch state {
        case .running: return "circle.dotted"
        case .waitingOnUser: return "questionmark.circle.fill"
        // Hollow, because nobody vouched for it. Green and filled is now reserved for
        // an agent that said `done` itself (FR-012).
        case .finished: return "checkmark.circle"
        case .stopped: return "stop.circle"
        case .archived: return "archivebox"
        }
    }

    private var tint: Color {
        if let settledOutcome {
            if settledOutcome.needsAPerson { return .orange }
            return settledOutcome == .done ? .green : .secondary
        }
        switch state {
        case .waitingOnUser: return .orange
        default: return .secondary
        }
    }

    /// What a screen reader hears, and what the tooltip says. The outcome's words come
    /// from `WorkOutcome.heading`, so they are the same words the phone uses.
    private var description: String {
        if isComingBack { return AgentsModel.comingBackDescription }
        if let settledOutcome { return settledOutcome.heading }
        switch state {
        case .running: return "Working"
        case .waitingOnUser: return "Waiting on you"
        case .finished: return "Finished"
        case .stopped: return "Stopped"
        case .archived: return "Archived"
        }
    }
}
