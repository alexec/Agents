import AgentsKit
import SwiftUI

/// The middle column: the selected project's sessions, as a list you move through.
///
/// A list rather than a stack of cards, so the Mac's own ways through a list work on
/// it: the arrow keys, a selection that shows what the right-hand side is reading, and
/// a search field over the top. Picking a row shows its chat beside the list rather
/// than over it, so the list is still there to pick the next one.
struct SessionsColumn: View {
    @Environment(AppModel.self) private var model
    @Environment(WindowRequests.self) private var requests
    @Binding var selection: UUID?

    @AppStorage("showsArchivedAgents") private var showsArchived = false
    @State private var query = ""

    /// Enough archived chats to find last week's; the rest are on the phone's archive
    /// and in Events. A list of every chat ever is the thing projects replaced.
    private static let archivedShown = 50

    var body: some View {
        List(selection: $selection) {
            // The same headings the project page drew, Complete split into Unread and
            // Read and all.
            ForEach(AgentGroup.live, id: \.self) { group in
                ForEach(group.headings(matching(model.agents(in: model.selectedProjectKey, group: group)))) { part in
                    Section {
                        ForEach(part.agents) { agent in
                            row(agent)
                        }
                    } header: {
                        heading(part.title, count: part.agents.count)
                    }
                }
            }
            let archived = matching(model.agents(in: model.selectedProjectKey, group: .archived))
            if !archived.isEmpty {
                Section(isExpanded: $showsArchived) {
                    ForEach(archived.prefix(Self.archivedShown)) { agent in
                        row(agent)
                    }
                } header: {
                    heading("Archived", count: archived.count)
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(Paper.ground)
        .overlay {
            if model.selectedProjectSummary == nil {
                ContentUnavailableView("No project", systemImage: "folder",
                                       description: Text("Pick one on the left."))
            } else if !hasAny {
                ContentUnavailableView(query.isEmpty ? "No sessions yet" : "No matches",
                                       systemImage: "bubble.left.and.bubble.right",
                                       description: Text(query.isEmpty
                                                         ? "Say what you want done on the right."
                                                         : "Nothing here says “\(query)”."))
            }
        }
        // ⌫ (Edit ▸ Delete) archives the picked session, as it deletes the picked
        // message in Mail. Archived is not gone: Bring Back is on its row.
        .onDeleteCommand {
            guard let id = selection, let agent = model.agents.first(where: { $0.id == id }),
                  agent.state != .archived else { return }
            Task { await model.archive(id) }
            selection = nil
        }
        .searchable(text: $query, placement: .toolbar, prompt: "Search sessions")
        // The window's title is this column's: whatever the right-hand side is reading.
        .navigationTitle(model.selectedAgent?.title ?? model.selectedProjectSummary?.name ?? "Agents")
        .navigationSubtitle(model.selectedAgent == nil ? "" : (model.selectedProjectSummary?.name ?? ""))
        .toolbar {
            ToolbarItem {
                Button {
                    selection = nil
                    requests.focusPrompt()
                } label: {
                    Label("New Session", systemImage: "square.and.pencil")
                }
                .help("Start a new session in this project (⌘N)")
                .disabled(model.selectedProjectSummary == nil)
            }
        }
    }

    private func row(_ agent: Agent) -> some View {
        AgentRow(agent: agent, isCompact: true)
            .padding(.vertical, 3)
            .tag(agent.id)
            // The list's own swipe, in place of the cards' hand-built one.
            .swipeActions(edge: .trailing) {
                if agent.state == .archived {
                    Button("Bring Back") { Task { await model.unarchive(agent.id) } }
                } else {
                    Button("Archive", systemImage: "archivebox") {
                        Task { await model.archive(agent.id) }
                        if selection == agent.id { selection = nil }
                    }
                    .tint(.gray)
                }
            }
    }

    private func heading(_ title: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(title)
            Text("\(count)").monospacedDigit().foregroundStyle(.tertiary)
        }
    }

    private func matching(_ agents: [Agent]) -> [Agent] {
        let words = query.trimmingCharacters(in: .whitespaces)
        guard !words.isEmpty else { return agents }
        return agents.filter { agent in
            [agent.title, agent.report?.message].compactMap { $0 }
                .contains { $0.localizedCaseInsensitiveContains(words) }
        }
    }

    private var hasAny: Bool {
        AgentGroup.allCases.contains {
            !matching(model.agents(in: model.selectedProjectKey, group: $0)).isEmpty
        }
    }
}
