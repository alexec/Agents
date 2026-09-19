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
            StatusIcon(state: agent.state, isComingBack: isComingBack)
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

    /// Whether the daemon is bringing this chat back by itself after a restart.
    private var isComingBack: Bool { model.isComingBack(agent) }

    /// What it is doing, in its own words where it has said them.
    ///
    /// Coming back wins over everything, including whatever step the agent last named:
    /// that step is from the turn the daemon took with it, and saying it now would be
    /// describing work nothing is doing.
    private var description: String {
        if isComingBack { return AgentsModel.comingBackDescription }
        if let step = agent.currentStep { return step }
        switch agent.state {
        case .running: return "Working"
        case .waitingOnUser: return "Waiting for your answer"
        case .finished: return "Complete"
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

    /// Stopped short, and why. The words live on `EndedReason`, so this row and the
    /// phone's card say the same thing about the same agent.
    private var ending: String? { agent.endedReason?.summary }
}

/// What state an agent is in, as one symbol.
///
/// Grey, all of it, except the one that wants you: the only colour in this app means
/// something needs a person.
struct StatusIcon: View {
    let state: AgentState
    /// Its own symbol rather than a spinner: nothing is running yet, and the row
    /// stays under "Stopped" until the chat's own state moves it.
    var isComingBack = false

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
        if isComingBack { return AgentsModel.comingBackSymbol }
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
        if isComingBack { return AgentsModel.comingBackDescription }
        switch state {
        case .running: return "Working"
        case .waitingOnUser: return "Waiting on you"
        case .finished: return "Complete"
        case .stopped: return "Stopped"
        case .archived: return "Archived"
        }
    }
}
