import AgentsKitCore
import SwiftUI

/// What the agent says it is going to do, at the head of the conversation.
///
/// FR-017 asks for the plan to be shown and kept current. `Agent.plans` arrives on
/// `agent/changed` and is always current, so this needs no wire of its own — the
/// `agent/plan` notification is a dead constant and stays one (research §5).
///
/// Collapsed to one line by default. A plan is context for what is being read below
/// it, and seven steps pinned over a phone-sized transcript would be most of the
/// screen given to something the reader has already taken in.
///
/// The phone's first; the window draws it too since #341, and the page has its own
/// (`Web/src/views/PlanStrip.tsx`). Which plan, and its line, are `Agent.planInForce` and
/// `Plan.stripSummary`, so the three say the same.
struct CurrentPlanStrip: View {
    let agent: Agent
    @State private var isExpanded = false

    var body: some View {
        if let plan = agent.planInForce {
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { isExpanded.toggle() }
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "chevron.right")
                            .appText(.fine)
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .accessibilityHidden(true)
                        Text(plan.stripSummary)
                            .appText(.supporting)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .padding(.vertical, 8)

                if isExpanded {
                    PlanView(plan: plan)
                        .padding(.bottom, 10)
                }
            }
            .edges()
            .frame(maxWidth: .infinity)
            .background(Paper.ground)
        }
    }
}

private extension View {
    /// The window's chat column, where its other strips sit; the phone's own margin.
    @ViewBuilder
    func edges() -> some View {
        #if os(macOS)
        chatColumn()
        #else
        padding(.horizontal, 16)
        #endif
    }
}
