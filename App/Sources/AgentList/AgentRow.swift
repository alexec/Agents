import AgentsKit
import SwiftUI

/// One agent on a project page: what it is, and what it is doing.
///
/// An icon for the state, the name it was given, and a line saying what it is working
/// on. The name is what it was asked; the line under it is what is happening now, which
/// is the thing you came to find out.
struct AgentRow: View {
    @Environment(AppModel.self) private var model
    let agent: Agent

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            StatusIcon(state: agent.state)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                Text(agent.title ?? "Untitled")
                    .font(.headline)
                    .lineLimit(1)

                Text(description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .contextMenu {
            if agent.state.holdsRuntime {
                Button("Stop") { Task { await model.stop(agent.id) } }
            }
            if agent.state == .archived {
                Button("Bring back") { Task { await model.unarchive(agent.id) } }
            } else {
                // Branching leaves the original alone and carries the history so far.
                Button("Branch") { Task { await model.fork(agent.id) } }
                Button("Archive") { Task { await model.archive(agent.id) } }
            }
            Divider()
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([agent.cwd])
            }
        }
    }

    /// What it is doing, in its own words where it has said them.
    private var description: String {
        if let step = agent.currentStep { return step }
        switch agent.state {
        case .running: return "Working"
        case .waitingOnUser: return "Waiting for your answer"
        case .finished: return "Finished"
        case .stopped: return ending ?? "Stopped"
        case .archived: return "Archived"
        }
    }

    /// The runtime, and how far through its plan it is.
    private var detail: String? {
        var parts = [runtimeName]
        if agent.state.holdsRuntime, let progress = agent.planProgress {
            // Clamped, because the last step being done would read "step 6 of 5".
            let step = min(progress.done + 1, progress.total)
            parts.append("step \(step) of \(progress.total)")
        }
        return parts.joined(separator: " · ")
    }

    private var runtimeName: String {
        RuntimeCatalog.runtime(id: agent.runtimeID)?.name ?? agent.runtimeID
    }

    /// Stopped short, and why. Never a reason dressed up as a finish.
    private var ending: String? {
        guard let reason = agent.endedReason else { return nil }
        switch reason {
        case .endTurn: return nil
        case .maxTokens: return "Ran out of room"
        case .maxTurnRequests: return "Hit its limit"
        case .refusal: return "Refused"
        case .cancelled: return "Stopped by you"
        case .processDied: return "The runtime crashed"
        case .daemonGone: return "Stopped with the daemon"
        case .unrecognised: return "Stopped for a reason we do not know"
        }
    }
}

/// What state an agent is in, as one symbol.
///
/// Grey, all of it, except the one that wants you: the only colour in this app means
/// something needs a person.
struct StatusIcon: View {
    let state: AgentState

    var body: some View {
        Group {
            if state == .running {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
            } else {
                Image(systemName: symbol)
                    .font(.system(size: 15))
                    .foregroundStyle(tint)
            }
        }
        .frame(width: 18, height: 18)
        .help(description)
        .accessibilityLabel(description)
    }

    private var symbol: String {
        switch state {
        case .running: return "circle.dotted"
        case .waitingOnUser: return "questionmark.circle.fill"
        case .finished: return "checkmark.circle.fill"
        case .stopped: return "stop.circle"
        case .archived: return "archivebox"
        }
    }

    private var tint: Color {
        state == .waitingOnUser ? .accentColor : .secondary
    }

    private var description: String {
        switch state {
        case .running: return "Working"
        case .waitingOnUser: return "Waiting on you"
        case .finished: return "Finished"
        case .stopped: return "Stopped"
        case .archived: return "Archived"
        }
    }
}
