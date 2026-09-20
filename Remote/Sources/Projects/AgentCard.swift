import AgentsKitCore
import SwiftUI

/// One agent, as a card you can go into.
///
/// The whole card is the control, which is what earns it interactive glass rather than
/// a decorated background — and what makes it a target a thumb can hit without aiming.
struct AgentCard: View {
    @Environment(RemoteModel.self) private var model
    let agent: Agent

    var body: some View {
        NavigationLink(value: agent.id) {
            HStack(alignment: .top, spacing: 12) {
                StatusIcon(state: agent.state, isComingBack: isComingBack,
                           outcome: agent.report?.outcome,
                           isUnaccountedFor: agent.endingIsUnaccountedFor)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 3) {
                    Text(agent.title ?? "Untitled")
                        .font(.headline)
                        .lineLimit(2)

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
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 14))
            .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    /// Whether the Mac is bringing this chat back by itself after a restart.
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
        // anything we would otherwise derive (FR-013). The same branch, in the same
        // place, as the Mac's row.
        if let message = agent.report?.message { return message }
        // Ours, because nobody said. A turn that ended cleanly, was asked how it went,
        // and still said nothing is a thing to know rather than a thing to do — so it
        // is marked, and left where it is (FR-019).
        if agent.endingIsUnaccountedFor { return "Finished without saying how it went" }
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

    /// The state said in words, because the icon beside it is not one VoiceOver reads.
    private var accessibilityLabel: String {
        [agent.title ?? "Untitled",
         isComingBack
            ? AgentsModel.comingBackDescription
            : StatusIcon.words(for: agent.state, outcome: agent.report?.outcome,
                               isUnaccountedFor: agent.endingIsUnaccountedFor),
         description]
            .joined(separator: ", ")
    }
}

/// What state an agent is in, as one symbol.
///
/// Grey, all of it, except the one that wants you: the only colour in this app means
/// something needs a person.
struct StatusIcon: View {
    let state: AgentState
    /// Its own symbol rather than a spinner: nothing is running yet, and the card
    /// stays under "Stopped" until the chat's own state moves it.
    var isComingBack = false
    /// What the agent said about the work, where it said anything. Filled means
    /// somebody said so, hollow means nobody did, and colour means you.
    var outcome: WorkOutcome?
    /// A turn that ended cleanly, was asked how it went, and still said nothing.
    /// Hollow and grey: nobody vouched for it, which is worth seeing and not worth
    /// spending the app's one colour on.
    var isUnaccountedFor = false

    var body: some View {
        Group {
            if state == .running {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: symbol)
                    .font(.system(size: 16))
                    .foregroundStyle(tint)
            }
        }
        .frame(width: 20, height: 20)
        .accessibilityHidden(true)
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
        if isUnaccountedFor && state == .finished { return "questionmark.circle" }
        switch state {
        case .running: return "circle.dotted"
        case .waitingOnUser: return "questionmark.circle.fill"
        // Hollow, because nobody vouched for it. Filled is now reserved for an agent
        // that said `done` itself (FR-012).
        case .finished: return "checkmark.circle"
        case .stopped: return "stop.circle"
        case .archived: return "archivebox"
        }
    }

    private var tint: Color {
        if let settledOutcome { return settledOutcome.needsAPerson ? .accentColor : .secondary }
        return state == .waitingOnUser ? .accentColor : .secondary
    }

    /// The words a screen reader hears. An outcome's come from `WorkOutcome.heading`,
    /// which is the same place the Mac reads them, so the two cannot drift (FR-017).
    static func words(for state: AgentState, outcome: WorkOutcome? = nil,
                      isUnaccountedFor: Bool = false) -> String {
        if state == .finished, let outcome { return outcome.heading }
        if state == .finished, isUnaccountedFor { return "Finished without saying how it went" }
        switch state {
        case .running: return "Working"
        case .waitingOnUser: return "Waiting on you"
        case .finished: return "Finished"
        case .stopped: return "Stopped"
        case .archived: return "Archived"
        }
    }
}
