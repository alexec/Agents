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
    let agent: Agent

    var body: some View {
        HStack(spacing: 6) {
            if let usage = agent.usage, let fraction = usage.fraction {
                meter(usage, fraction)
                    .help(helpText(usage))
            }
            Text(cost)
                .font(.footnote)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .help("What this agent has cost so far")
        }
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
                .stroke(usage.isCloseToFull ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary),
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
        if let total = Cost.total(of: agent.costToDate) { return total }
        let live = agent.usage?.cost
        return (live?.amount ?? 0).formatted(.currency(code: live?.currency ?? "USD"))
    }

    private func helpText(_ usage: Usage) -> String {
        let tokens = "\(usage.used.formatted()) of \(usage.size.formatted()) tokens"
        return usage.isCloseToFull ? "Context nearly full — \(tokens)" : tokens
    }
}
