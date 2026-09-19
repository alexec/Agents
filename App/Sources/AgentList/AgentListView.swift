import AgentsKit
import SwiftUI

/// Every agent, with the busy ones kept apart from the done ones.
struct AgentListView: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: UUID?
    @Binding var isStarting: Bool

    private var groups: [(title: String, states: [AgentState])] {
        [("Working", [.running, .waitingOnUser]),
         ("Finished", [.finished]),
         ("Stopped", [.stopped]),
         ("Archived", [.archived])]
    }

    var body: some View {
        List(selection: $selection) {
            if !model.permissions.isEmpty {
                Section("Waiting on you") {
                    ForEach(model.permissions) { request in
                        PermissionRow(request: request)
                            .tag(request.agentID)
                    }
                }
            }
            ForEach(groups, id: \.title) { group in
                let agents = model.agents.filter { group.states.contains($0.state) }
                if !agents.isEmpty {
                    Section(group.title) {
                        ForEach(agents) { agent in
                            AgentRow(agent: agent).tag(agent.id)
                        }
                    }
                }
            }
            if model.agents.isEmpty {
                EmptyAgentList(isStarting: $isStarting)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Agents")
        .toolbar {
            ToolbarItem {
                Button {
                    isStarting = true
                } label: {
                    Label("New agent", systemImage: "plus")
                }
                .disabled(model.availableRuntimes.isEmpty)
                .help(model.availableRuntimes.isEmpty
                      ? "No agent runtime was found on this Mac."
                      : "Start an agent in a folder")
            }
        }
    }
}

/// The first thing anybody sees. It says what to do, not that something is wrong.
private struct EmptyAgentList: View {
    @Environment(AppModel.self) private var model
    @Binding var isStarting: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.availableRuntimes.isEmpty {
                Text("No agent runtime found")
                    .font(.headline)
                Text("Agents runs the coding CLIs you already have. Install one and it appears here.")
                    .foregroundStyle(.secondary)
                ForEach(model.runtimes) { status in
                    RuntimeMissingLine(status: status)
                }
            } else {
                Text("Nothing running yet")
                    .font(.headline)
                Text("Pick a folder, choose \(model.availableRuntimes.map(\.runtime.name).formatted(.list(type: .or))), and say what you want done.")
                    .foregroundStyle(.secondary)
                Button("Start an agent") { isStarting = true }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(.vertical, 8)
    }
}

private struct RuntimeMissingLine: View {
    let status: RuntimeStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(status.runtime.name).font(.callout.weight(.medium))
            switch status.availability {
            case .missing(let lookedIn):
                Text("Looked for \(status.runtime.executable) in \(lookedIn.prefix(4).joined(separator: ", "))…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .needsSignIn(_, let fixCommand):
                Text(fixCommand.map { "Signed out. Run \($0)." } ?? "Signed out.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .failed(let reason):
                Text(reason).font(.caption).foregroundStyle(.secondary)
            case .available:
                EmptyView()
            }
        }
    }
}

private struct PermissionRow: View {
    @Environment(AppModel.self) private var model
    let request: PermissionRequest

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.agents.first { $0.id == request.agentID }?.title ?? "An agent")
                    .lineLimit(1)
                Text(request.toolCall.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}
