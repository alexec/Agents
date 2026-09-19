import AgentsKit
import SwiftUI

/// How full an agent's context is, and what it has cost.
///
/// The runtimes send this several times a turn and 001 dropped every one. A full
/// context is the most common reason an agent starts behaving oddly, and there is no
/// other way to see it coming. A runtime that sends no size shows no meter, and one
/// that sends no cost shows no cost: nothing here is estimated.
///
/// The two are separate facts and a runtime may send either, so they are drawn
/// separately. Cost used to sit inside the meter, which hid it from a runtime that
/// prices a turn without saying how big its window is, and hid it for the whole of
/// the first turn, because a total only lands once a turn has ended.
struct ContextMeter: View {
    let agent: Agent

    var body: some View {
        if agent.usage?.fraction != nil || cost != nil {
            HStack(spacing: 6) {
                if let usage = agent.usage, let fraction = usage.fraction {
                    meter(usage, fraction)
                        .help(helpText(usage))
                }
                if let cost {
                    Text(cost)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func meter(_ usage: Usage, _ fraction: Double) -> some View {
        HStack(spacing: 6) {
            Capsule()
                .fill(.quaternary)
                .frame(width: 44, height: 4)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(usage.isCloseToFull ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                        .frame(width: 44 * fraction, height: 4)
                }
            Text(usage.isCloseToFull ? "Context nearly full" : "\(Int(fraction * 100))%")
                .font(.footnote)
                .foregroundStyle(usage.isCloseToFull ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
        }
    }

    /// What to show beside the meter. The running total, per currency: two currencies
    /// are two numbers rather than one nobody could check.
    ///
    /// Until the first turn ends there is no total, so the figure the runtime quotes
    /// mid-turn stands in. Still the runtime's own number, still unconverted.
    private var cost: String? {
        if let total = Cost.total(of: agent.costToDate) { return total }
        guard let live = agent.usage?.cost else { return nil }
        return live.amount.formatted(.currency(code: live.currency))
    }

    private func helpText(_ usage: Usage) -> String {
        "\(usage.used.formatted()) of \(usage.size.formatted()) tokens"
    }
}
