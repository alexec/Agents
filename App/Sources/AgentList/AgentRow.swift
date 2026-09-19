import AgentsKit
import SwiftUI

struct AgentRow: View {
    @Environment(AppModel.self) private var model
    let agent: Agent

    var body: some View {
        HStack(spacing: 8) {
            StateDot(state: agent.state)
            VStack(alignment: .leading, spacing: 1) {
                Text(agent.title ?? "Untitled")
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(runtimeName)
                    Text("·")
                    Text(agent.cwd.lastPathComponent)
                    if let ending {
                        Text("·")
                        Text(ending)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
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

    private var runtimeName: String {
        RuntimeCatalog.runtime(id: agent.runtimeID)?.name ?? agent.runtimeID
    }

    /// Finished, or stopped short with the reason. Never both, and never a reason
    /// dressed up as a finish.
    private var ending: String? {
        guard agent.state == .stopped, let reason = agent.endedReason else { return nil }
        switch reason {
        case .endTurn: return nil
        case .maxTokens: return "ran out of room"
        case .maxTurnRequests: return "hit its limit"
        case .refusal: return "refused"
        case .cancelled: return "stopped by you"
        case .processDied: return "the runtime crashed"
        case .daemonGone: return "stopped with the daemon"
        case .unrecognised: return "stopped for a reason we do not know"
        }
    }
}

struct StateDot: View {
    let state: AgentState

    var body: some View {
        // Filled while there is a runtime in hand, hollow once there is not: the
        // difference a glance needs, without a colour.
        Group {
            if state.holdsRuntime {
                Circle().fill(colour)
            } else {
                Circle().strokeBorder(colour, lineWidth: 1.5)
            }
        }
        .frame(width: 8, height: 8)
        .opacity(opacity)
        .overlay {
            if state == .waitingOnUser {
                Circle().stroke(colour.opacity(0.35), lineWidth: 4)
            }
        }
        .help(description)
    }

    /// Grey, all of it. A colour here would be decoration, and the one colour in the
    /// app means something went wrong.
    private var colour: Color { .secondary }

    private var opacity: Double {
        switch state {
        case .running: return 1
        case .waitingOnUser: return 1
        case .finished: return 0.55
        case .stopped: return 0.4
        case .archived: return 0.25
        }
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
