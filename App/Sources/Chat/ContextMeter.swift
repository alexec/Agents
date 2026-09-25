import AgentsKit
import SwiftUI

/// How full an agent's context is, and what it has cost.
///
/// The runtimes send this several times a turn and 001 dropped every one. A full
/// context is the most common reason an agent starts behaving oddly, and there is no
/// other way to see it coming. A runtime that sends no size shows no ring: the size is
/// as reported and never estimated.
///
/// The cost is the other way about. It is always shown, because a figure that comes
/// and goes is one you stop trusting, and the row it sits in is the only place to look
/// for it. Every number in it is the runtime's own; the only thing the app supplies is
/// the zero before anything has been priced.
struct ContextMeter: View {
    @Environment(AppModel.self) private var model
    let agent: Agent

    var body: some View {
        HStack(spacing: 6) {
            if let usage = agent.usage, let fraction = usage.fraction {
                meter(usage, fraction)
                    .help(helpText(usage))
            }
            Text(cost)
                .appText(.fine)
                .monospacedDigit()
                // Colour means the limit is about to bite, on the app's one existing
                // threshold rather than a second number for readers to learn.
                .foregroundStyle((isCloseToItsLimit ? StateTint.failure : .none)
                                    .style(or: .secondary))
                .help(costHelp)
        }
    }

    /// The agent's own ceiling, or the app-wide one when it has none.
    private var limits: CostLimits { model.costLimits }

    /// What is left before it stops, when there is a limit to be left of.
    private var headroom: Decimal? { agent.costHeadroom(under: limits) }

    /// Approaching a limit, on `Usage.closeToFull` rather than a threshold of its own.
    private var isCloseToItsLimit: Bool {
        guard let ceiling = agent.ceiling(under: limits), ceiling.amount > 0,
              !agent.costIsUnmeasured else { return false }
        let spent = agent.costToDate[ceiling.currency] ?? 0
        return (spent / ceiling.amount) >= Decimal(Usage.closeToFull)
    }

    private var costHelp: String {
        if agent.costIsUnmeasured {
            return "This runtime reports no price, so this agent cannot be measured "
                + "and no limit applies to it."
        }
        guard let ceiling = agent.ceiling(under: limits), let headroom else {
            return "What this agent has cost so far"
        }
        let left = headroom.money(in: ceiling.currency)
        return agent.isAtCostLimit(under: limits)
            ? PromptWords.atItsCostLimit
            : "What this agent has cost so far — \(left) left of its limit"
    }

    /// A ring that fills as the window does, going round from the top, and turns red
    /// as it nears full. The ring alone: a percentage beside it said the same thing
    /// twice, and the exact numbers are a hover away.
    private func meter(_ usage: Usage, _ fraction: Double) -> some View {
        ZStack {
            Circle()
                .stroke(.quaternary, lineWidth: 2)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke((usage.isCloseToFull ? StateTint.failure : .none).style(or: .secondary),
                        style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 12, height: 12)
        .animation(.default, value: fraction)
        .accessibilityLabel(helpText(usage))
    }

    /// The session's running total, per currency: two currencies are two numbers
    /// rather than one nobody could check.
    ///
    /// Always shown, so the figure never disappears mid-session and leaves the row
    /// shuffling about. Until the first turn ends there is no total, so the figure the
    /// runtime quotes mid-turn stands in — still the runtime's own number, still
    /// unconverted — and before anything has been priced at all, a plain zero.
    private var cost: String {
        // The worst failure available here is a reader believing an agent is covered
        // by a limit that cannot touch it. A runtime that reports no price is named
        // as such, never shown as a zero and never given a headroom.
        if agent.costIsUnmeasured { return "Not measured" }
        let spent = Cost.total(of: agent.costToDate)
            ?? (agent.usage?.cost?.amount ?? 0)
                .money(in: agent.usage?.cost?.currency ?? "USD")
        // `$0.42 of $2.00`, and nothing extra when there is no limit — a figure that
        // comes and goes is one you stop trusting.
        guard let ceiling = agent.ceiling(under: limits) else { return spent }
        return "\(spent) of \(ceiling.amount.formatted(.currency(code: ceiling.currency)))"
    }

    private func helpText(_ usage: Usage) -> String {
        let tokens = "\(usage.used.formatted()) of \(usage.size.formatted()) tokens"
        return usage.isCloseToFull ? "Context nearly full — \(tokens)" : tokens
    }
}
