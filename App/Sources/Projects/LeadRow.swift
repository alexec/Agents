import AgentsKit
import SwiftUI

/// The project lead, pinned above the groups.
///
/// It is in none of the three, because the groups are about work being done and the
/// lead is about work being handed out. There is no archive action here: a lead is
/// archived with its project or not at all.
struct LeadRow: View {
    @Environment(AppModel.self) private var model
    let agent: Agent

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "person.badge.shield.checkmark")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("Project lead")
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if agent.state == .waitingOnUser {
                Circle().fill(Color.accentColor).frame(width: 7, height: 7)
                    .accessibilityHidden(true)
            } else if agent.state == .running {
                ProgressView().controlSize(.small)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Project lead, \(subtitle)")
        .contextMenu {
            if agent.state.holdsRuntime {
                Button("Stop") { Task { await model.stop(agent.id) } }
            }
        }
    }

    /// What it is doing, or what it is for when it has not been asked anything yet.
    private var subtitle: String {
        switch agent.state {
        case .running: return "Working"
        case .waitingOnUser: return "Needs you"
        case .archived: return "Archived with this project"
        case .finished, .stopped:
            return agent.runtimeSessionID == nil
                ? "Tell it what you want done"
                : "Ready"
        }
    }
}
