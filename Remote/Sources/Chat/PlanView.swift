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
struct CurrentPlanStrip: View {
    let agent: Agent
    @State private var isExpanded = false

    var body: some View {
        if let plan = current {
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
                        Text(summary(plan))
                            .appText(.supporting)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

                if isExpanded {
                    PlanView(plan: plan)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 10)
                }
            }
            .frame(maxWidth: .infinity)
            .background(Paper.ground)
        }
    }

    /// The plan in force: the last one the agent put forward that it has not dropped.
    /// A dropped plan is kept on the record and shown in the transcript where it
    /// happened, but it is not what the agent is doing now, so it is not up here.
    private var current: Plan? {
        agent.plans.last { $0.state == .current && !$0.entries.isEmpty }
    }

    /// The step being worked, because that is the one thing worth a line of the
    /// screen; how far along, because that is the other. No plan has a title.
    private func summary(_ plan: Plan) -> String {
        let done = plan.entries.filter { $0.status == .completed }.count
        let progress = "\(done) of \(plan.entries.count) done"
        guard let doing = plan.entries.first(where: { $0.status == .inProgress }) else {
            return "Plan — \(progress)"
        }
        return "\(doing.content) — \(progress)"
    }
}
