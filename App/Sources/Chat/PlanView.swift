import AgentsKit
import SwiftUI

/// What the agent said it was going to do.
///
/// The clearest statement an agent makes of its intentions, which is the moment to stop
/// it if it is wrong. 001 drew "Made a plan".
struct PlanView: View {
    let plan: Plan

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(plan.entries) { entry in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(mark(for: entry.status))
                        .chatText(.code)
                        .foregroundStyle(.secondary)
                    Text(entry.content)
                        .chatText(.supporting)
                        .foregroundStyle(entry.status == .completed ? .secondary : .primary)
                        .strikethrough(plan.state == .withdrawn)
                }
            }
            if plan.state == .withdrawn {
                Text("The agent dropped this plan")
                    .chatText(.fine)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .textSelection(.enabled)
    }

    private func mark(for status: PlanEntry.Status) -> String {
        switch status {
        case .pending: return "○"
        case .inProgress: return "◐"
        case .completed: return "●"
        }
    }
}

/// What a turn consumed. Only what the runtime sent: Grok sends none of this, and then
/// nothing is shown rather than a zero.
struct UsageLine: View {
    let usage: TurnUsage

    var body: some View {
        Text(summary)
            .chatText(.fine)
            .foregroundStyle(.tertiary)
    }

    private var summary: String {
        var parts: [String] = []
        if usage.totalTokens > 0 {
            parts.append("\(usage.totalTokens.formatted()) tokens")
        }
        if let cost = usage.cost {
            parts.append(cost.amount.money(in: cost.currency))
        }
        return parts.joined(separator: " · ")
    }
}

/// Something the agent asked the app to do. Reads are quiet; a write says what it did.
struct ServedRequestLine: View {
    let request: ServedRequest

    var body: some View {
        HStack(spacing: 6) {
            Text(request.summary)
            if case .refused(let reason) = request.outcome {
                Text(reason).tinted(.failure)
            }
            if case .failed(let message) = request.outcome {
                Text(message).tinted(.failure)
            }
        }
        .chatText(.fine)
        .foregroundStyle(.secondary)
    }
}
