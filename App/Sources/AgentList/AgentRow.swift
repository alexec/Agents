import AgentsKit
import SwiftUI

struct AgentRow: View {
    @Environment(AppModel.self) private var model
    let agent: Agent

    var body: some View {
        HStack(spacing: 8) {
            StateDot(state: agent.state)
            VStack(alignment: .leading, spacing: 2) {
                Text(agent.title ?? "Untitled")
                    .lineLimit(1)

                // What it is doing now, when it has said. A title is what it was asked
                // an hour ago; this is the thing you actually came to find out.
                if let step = agent.currentStep {
                    Text(step)
                        .font(.callout)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .padding(.top, 1)
                }

                HStack(spacing: 4) {
                    // No folder here any more: the panel is one project, so saying
                    // which folder every row is in says the same thing twenty times.
                    Text(runtimeName)
                    if let progress {
                        Text("·")
                        Text(progress)
                    }
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
        // No padding of its own: the card it sits in owns that now.
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

    /// How far through its own plan it is. Only while that plan still means
    /// something: a finished agent's progress is history, and reads as a claim.
    private var progress: String? {
        guard agent.state.holdsRuntime, let progress = agent.planProgress else { return nil }
        // Clamped, because the last step being done would otherwise read "step 6 of 5".
        let step = min(progress.done + 1, progress.total)
        return "step \(step) of \(progress.total)"
    }

    /// Finished, or stopped short with the reason. Never both, and never a reason
    /// dressed up as a finish.
    ///
    /// "Completed" holds both, so each row has to say which it was: a run that ended
    /// cleanly and one the runtime crashed out of are not the same news.
    private var ending: String? {
        if agent.state == .finished { return "finished" }
        guard agent.state == .stopped, let reason = agent.endedReason else { return nil }
        switch reason {
        case .endTurn: return "finished"
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
