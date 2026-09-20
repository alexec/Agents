import AgentsKitCore
import SwiftUI

/// The plan the agent is working to, with the step it is on.
///
/// Drawn twice, from two different places, and the difference matters. In the
/// transcript this is the plan as it was at that point in the conversation — a thing
/// that happened. At the head of the screen, `CurrentPlanStrip` draws `Agent.plans`,
/// which is the plan as it is now.
///
/// On the Mac one view does both, because the whole transcript is on screen and the
/// last plan in it is the current one. On an iPad the first page is sized to the
/// screen and a plan made an hour ago is several fetches back, so the current plan
/// needs somewhere of its own to be (research §5).
struct PlanView: View {
    let plan: Plan

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(plan.entries.enumerated()), id: \.offset) { _, entry in
                PlanLine(entry: entry, withdrawn: plan.state == .withdrawn)
            }
            if plan.state == .withdrawn {
                Text("The agent dropped this plan")
                    .chatText(.fine)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 12))
    }
}

/// One step. The mark is an image and hidden from VoiceOver; the status is said in
/// the line's own label instead, because "circle, write the tests" is not a sentence
/// anybody wants read to them (FR-037).
private struct PlanLine: View {
    let entry: PlanEntry
    let withdrawn: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .chatText(.fine)
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text(entry.content)
                .chatText(.supporting)
                .foregroundStyle(entry.status == .completed ? .tertiary : .secondary)
                .strikethrough(entry.status == .completed || withdrawn)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(spoken): \(entry.content)")
    }

    private var symbol: String {
        switch entry.status {
        case .completed: return "checkmark"
        case .inProgress: return "arrow.right"
        case .pending: return "circle"
        }
    }

    private var spoken: String {
        if withdrawn { return "Dropped" }
        switch entry.status {
        case .completed: return "Done"
        case .inProgress: return "Doing now"
        case .pending: return "To do"
        }
    }
}

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
                            .chatText(.fine)
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .accessibilityHidden(true)
                        Text(summary(plan))
                            .chatText(.supporting)
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
            .background(.bar)
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
