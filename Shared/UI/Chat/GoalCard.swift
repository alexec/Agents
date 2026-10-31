import AgentsKitCore
import SwiftUI

/// The goal the agent's runtime keeps working towards, at the head of the chat over the plan
/// (#2742), as Codex's and Claude's `/goal` set it.
///
/// The plan card's place and look (#776): a card on the well, one line until it is opened.
/// The line is the objective and where it stands; a stopped goal says why under it, because
/// that is the moment the person has something to do; a budget is a bar in the accent. A goal
/// is not a status, so the status word is grey and the row keeps its own marks.
///
/// The window and the phone draw this; the page has its own (`Web/src/views/GoalCard.tsx`).
/// Its words are `Goal.statusWord`, `progressLine` and `summary`, so the three say the same.
struct GoalCard: View {
    let agent: Agent
    @State private var isExpanded = false

    var body: some View {
        if let goal = agent.goal {
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { isExpanded.toggle() }
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: goal.status == .complete ? "checkmark.circle" : "scope")
                                .appText(.supporting)
                                .accessibilityHidden(true)
                            Text(goal.objective)
                                .appText(.supporting)
                                .lineLimit(isExpanded ? nil : 1)
                                .truncationMode(.tail)
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: 8)
                            Text(goal.statusWord)
                                .appText(.fine)
                                .foregroundStyle(.secondary)
                                .fixedSize()
                            Image(systemName: "chevron.right")
                                .appText(.fine)
                                .foregroundStyle(.secondary)
                                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                                .accessibilityHidden(true)
                        }
                        if let reason = goal.reason, goal.isStopped || isExpanded {
                            Text(reason)
                                .appText(.fine)
                                .foregroundStyle(.secondary)
                                .lineLimit(isExpanded ? nil : 1)
                                .multilineTextAlignment(.leading)
                        }
                        if isExpanded, let progress = goal.progressLine {
                            Text(progress)
                                .appText(.fine)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        if let fraction = goal.budgetFraction {
                            GoalBar(fraction: fraction)
                                .padding(.top, 2)
                        }
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(goal.summary)
                .accessibilityHint(isExpanded ? "Shows the goal on one line" : "Shows the whole goal")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .paperWell(in: RoundedRectangle(cornerRadius: Paper.Radius.card))
            .goalEdges()
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(Paper.ground)
        }
    }
}

/// How much of its budget it has used, as the plan card's bar.
private struct GoalBar: View {
    let fraction: Double

    var body: some View {
        Capsule()
            .fill(Paper.rule)
            .frame(height: 4)
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    Capsule()
                        .fill(Paper.accent)
                        .frame(width: proxy.size.width * min(max(fraction, 0), 1))
                }
            }
            .accessibilityHidden(true)
    }
}

private extension View {
    /// The window's chat column, where the plan card sits; the phone's own margin.
    @ViewBuilder
    func goalEdges() -> some View {
        #if os(macOS)
        chatColumn()
        #else
        padding(.horizontal, 16)
        #endif
    }
}
