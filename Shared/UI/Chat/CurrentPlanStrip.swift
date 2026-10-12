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
/// A card on the well with a bar under the step (#776): grey words on the page's own
/// paper read as part of the transcript, and the plan was missed. The bar is the
/// accent, not a `StateTint`: those three colours say an agent needs a person, is
/// broken or is done, and a plan is none of them.
///
/// The phone's first; the window draws it too since #341, and the page has its own
/// (`Web/src/views/PlanStrip.tsx`). Which plan, and its words, are `Agent.planInForce`,
/// `Plan.stripStep` and `Plan.stripDone`, so the three say the same.
struct CurrentPlanStrip: View {
    let agent: Agent
    @State private var isExpanded = false
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    var body: some View {
        if let plan = agent.planInForce {
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { isExpanded.toggle() }
                } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: "checkmark.square")
                                .appText(.supporting)
                                .accessibilityHidden(true)
                            Text(plan.stripStep)
                                .appText(.supporting)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer(minLength: 8)
                            Text(count(plan))
                                .appText(.fine)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                                .fixedSize()
                            Image(systemName: "chevron.right")
                                .appText(.fine)
                                .foregroundStyle(.secondary)
                                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                                .accessibilityHidden(true)
                        }
                        ProgressBar(fraction: Double(plan.stripDone) / Double(plan.entries.count))
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(plan.stripSummary)
                .accessibilityHint(isExpanded ? "Hides the plan's steps" : "Shows the plan's steps")

                if isExpanded {
                    Paper.rule.frame(height: 1)
                        .padding(.top, 10)
                    PlanView(plan: plan)
                        .padding(.top, 8)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .paperWell(in: RoundedRectangle(cornerRadius: Paper.Radius.card))
            .edges()
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(Paper.ground)
        }
    }

    /// "2 of 5", or "2/5" where a phone's width is short of it.
    private func count(_ plan: Plan) -> String {
        #if os(iOS)
        if sizeClass == .compact { return "\(plan.stripDone)/\(plan.entries.count)" }
        #endif
        return "\(plan.stripDone) of \(plan.entries.count)"
    }
}

/// How far along, as a thin bar in the accent.
private struct ProgressBar: View {
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
