import AgentsKit
import SwiftUI

/// How full an agent's context is, and what it has cost.
///
/// The runtimes send this several times a turn and 001 dropped every one. A full
/// context is the most common reason an agent starts behaving oddly, and there is no
/// other way to see it coming. A runtime that sends no size shows no meter, and one
/// that sends no cost shows no cost: nothing here is estimated.
struct ContextMeter: View {
    let agent: Agent

    var body: some View {
        if let usage = agent.usage, let fraction = usage.fraction {
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
                if let cost = total {
                    Text(cost)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .help(helpText(usage))
        }
    }

    /// The running total, per currency. Two currencies are shown as two numbers rather
    /// than added into one nobody could check.
    private var total: String? {
        guard !agent.costToDate.isEmpty else { return nil }
        return agent.costToDate
            .sorted { $0.key < $1.key }
            .map { $0.value.formatted(.currency(code: $0.key)) }
            .joined(separator: " · ")
    }

    private func helpText(_ usage: Usage) -> String {
        "\(usage.used.formatted()) of \(usage.size.formatted()) tokens"
    }
}
