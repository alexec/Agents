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
                StatusIcon(state: agent.state, isComingBack: isComingBack)
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
        switch agent.state {
        case .running: return "Working"
        case .waitingOnUser: return "Waiting for your answer"
        case .finished: return "Complete"
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
         isComingBack ? AgentsModel.comingBackDescription : StatusIcon.words(for: agent.state),
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

    private var symbol: String {
        if isComingBack { return AgentsModel.comingBackSymbol }
        switch state {
        case .running: return "circle.dotted"
        case .waitingOnUser: return "questionmark.circle.fill"
        case .finished: return "checkmark.circle.fill"
        case .stopped: return "stop.circle"
        case .archived: return "archivebox"
        }
    }

    private var tint: Color {
        state == .waitingOnUser ? .accentColor : .secondary
    }

    static func words(for state: AgentState) -> String {
        switch state {
        case .running: return "Working"
        case .waitingOnUser: return "Waiting on you"
        case .finished: return "Complete"
        case .stopped: return "Stopped"
        case .archived: return "Archived"
        }
    }
}
