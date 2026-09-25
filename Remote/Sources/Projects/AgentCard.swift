import AgentsKitCore
import SwiftUI

/// One agent, as a card you can go into.
///
/// The whole card is the control, which is why it is a paper row rather than a
/// line of text — and what makes it a target a thumb can hit without aiming.
struct AgentCard: View {
    @Environment(RemoteModel.self) private var model
    /// The agent as the list had it when it drew this card. Only its id is trusted.
    private let given: Agent

    init(agent: Agent) {
        given = agent
    }

    /// The agent as the phone has it now, read from the model rather than kept. A card
    /// that drew the copy it was handed kept its first render when it moved between
    /// groups in the lazy stack — the Mac's row did exactly that; see `AgentRow`.
    private var agent: Agent { model.work.agent(given.id) ?? given }

    var body: some View {
        NavigationLink(value: agent.id) {
            HStack(alignment: .top, spacing: 12) {
                StatusIcon(state: agent.state, isComingBack: isComingBack,
                           outcome: agent.report?.outcome,
                           isParked: agent.parking?.isParked == true)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(agent.title ?? "Untitled")
                            .appText(.reading).fontWeight(.semibold)
                            .lineLimit(2)
                        // Started by another agent (028), marked as the Mac's row
                        // marks it.
                        if model.startedByAgentLabel(agent) != nil {
                            Image(systemName: AgentsModel.startedByAgentSymbol)
                                .appText(.fine)
                                .foregroundStyle(.tertiary)
                        }
                        // Working in a worktree (030), named as on the Mac's row. The
                        // phone cannot see the Mac's disk, so a worktree that has gone
                        // is not marked here.
                        if let worktree = agent.worktree {
                            HStack(spacing: 3) {
                                Image(systemName: "arrow.triangle.branch")
                                Text(worktree.name).lineLimit(1)
                            }
                            .appText(.fine)
                            .foregroundStyle(.tertiary)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("in worktree \(worktree.name)")
                        }
                    }

                    // The agent's own account of its last turn, and nothing else — the
                    // same two lines as the Mac's row. The state is the icon's; what it
                    // is doing is the title, which the agent keeps current.
                    if let report = agent.report?.message {
                        Text(report)
                            .appText(.supporting)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    // As on the Mac's row (040).
                    if let line = ParkWords.line(agent.parking) {
                        Text(line)
                            .appText(.fine)
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 14))
            .paperRow()
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    /// Whether the Mac is bringing this chat back by itself after a restart.
    private var isComingBack: Bool { model.isComingBack(agent) }

    /// The state said in words, because the icon beside it is not one VoiceOver reads.
    /// Precise where the shape is not: which outcome, and why it stopped.
    private var accessibilityLabel: String {
        var words = isComingBack
            ? AgentsModel.comingBackDescription
            : StatusIcon.words(for: agent.state, outcome: agent.report?.outcome,
                               isUnaccountedFor: agent.endingIsUnaccountedFor)
        if agent.state == .stopped, let why = agent.endedReason?.summary { words = why }
        return [agent.title ?? "Untitled", model.startedByAgentLabel(agent), words, agent.report?.message,
                ParkWords.line(agent.parking)]
            .compactMap { $0 }
            .joined(separator: ", ")
    }
}

/// What state an agent is in, as one of four shapes.
///
/// The shape is `StatusShape`'s, which the Mac's row draws from too, so the two cannot
/// disagree about it. Grey, all of it, except the one that wants you.
struct StatusIcon: View {
    let state: AgentState
    /// The Mac is bringing this chat back by itself after a restart.
    var isComingBack = false
    /// What the agent said about the work, where it said anything.
    var outcome: WorkOutcome?
    /// Parked (040): the shape, but not orange. See the Mac's `StatusIcon`.
    var isParked = false

    private var shape: StatusShape {
        StatusShape(state: state, outcome: outcome, isComingBack: isComingBack)
    }

    var body: some View {
        Group {
            if let symbol = shape.symbol {
                Image(systemName: symbol)
                    // Decorative: a glyph filling a 20-point well, not text (FR-015).
                    .font(.system(size: 16))
                    .foregroundStyle((shape.wantsAPerson && !isParked ? StateTint.attention : .none)
                        .style(or: .secondary))
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .frame(width: 20, height: 20)
        .accessibilityHidden(true)
    }

    /// The words a screen reader hears. An outcome's come from `WorkOutcome.heading`,
    /// which is the same place the Mac reads them, so the two cannot drift (FR-017).
    static func words(for state: AgentState, outcome: WorkOutcome? = nil,
                      isUnaccountedFor: Bool = false) -> String {
        if state == .finished, let outcome { return outcome.heading }
        if state == .finished, isUnaccountedFor { return "Finished without saying how it went" }
        switch state {
        case .running: return "Working"
        case .starting: return AgentState.startingLabel
        case .waitingOnUser: return "Waiting on you"
        case .finished: return "Finished"
        case .stopped: return "Stopped"
        case .archived: return "Archived"
        }
    }
}
