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
                Button("Archive") { Task { await model.archive(agent.id) } }
            }
            Divider()
            Button("Show folder in Finder") {
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
        Circle()
            .fill(colour)
            .frame(width: 8, height: 8)
            .overlay {
                if state == .running {
                    Circle().stroke(colour.opacity(0.35), lineWidth: 4)
                }
            }
            .help(description)
    }

    private var colour: Color {
        switch state {
        case .running: return .green
        case .waitingOnUser: return .orange
        case .finished: return .blue
        case .stopped: return .secondary
        case .archived: return .secondary.opacity(0.5)
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
