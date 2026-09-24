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
                        .appText(.code)
                        .foregroundStyle(.secondary)
                    Text(entry.content)
                        .appText(.supporting)
                        .foregroundStyle(entry.status == .completed ? .secondary : .primary)
                        .strikethrough(plan.state == .withdrawn)
                }
            }
            if plan.state == .withdrawn {
                Text("The agent dropped this plan")
                    .appText(.fine)
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
        .appText(.fine)
        .foregroundStyle(.secondary)
    }
}
