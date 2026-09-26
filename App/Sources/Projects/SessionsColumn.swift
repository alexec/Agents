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
    @Environment(SidebarFrame.self) private var frame
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
            // What has been retired from here (051), as the section's last line.
            let retiredLine = query.isEmpty
                ? RetirementWords.retiredLine(model.selectedProjectSummary?.retiredCount) : nil
            if !archived.isEmpty || retiredLine != nil {
                Section(isExpanded: $showsArchived) {
                    ForEach(archived.prefix(Self.archivedShown)) { agent in
                        row(agent)
                    }
                    if let retiredLine {
                        Text(retiredLine)
                            .appText(.supporting)
                            .foregroundStyle(.secondary)
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
        // The window's title is this column's: whatever the right-hand side is reading.
        .navigationTitle(model.selectedAgent?.title ?? model.selectedProjectSummary?.name ?? "Agents")
        .navigationSubtitle(model.selectedAgent == nil ? "" : (model.selectedProjectSummary?.name ?? ""))
        // Over the list it adds to, not in the window's toolbar: up there it sat at the
        // far right, over the chat, a long way from the sessions it starts.
        .safeAreaInset(edge: .top, spacing: 0) {
            if model.selectedProjectSummary != nil {
                NewSessionRow {
                    selection = nil
                    requests.focusPrompt()
                }
            }
        }
        .toolbar {
            // A search field of our own rather than `.searchable`, which pins its field
            // to the window's far right edge whatever the order: the chat's sidebar
            // toggle belongs to the right of the search, beside the sidebar it opens.
            ToolbarSpacer(.fixed)
            ToolbarItem {
                SessionSearchField(text: $query)
                    .frame(width: 240)
            }
            // Only while a chat is showing: a workflow or project page has no sidebar.
            if model.selection != nil, model.openWorkflow == nil {
                ToolbarSpacer(.fixed)
                ToolbarItem {
                    SidebarToggle(windowWidth: frame.windowWidth)
                }
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

/// The sessions column's first line: start a new session in this project, as ⌘N does.
/// The whole row is the button, so it can be hit anywhere along it.
private struct NewSessionRow: View {
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Label("New session", systemImage: "square.and.pencil")
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .contentShape(.rect)
                .background(isHovered ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear),
                            in: .rect(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("Start a new session in this project (⌘N)")
        .padding(.horizontal, 10)
        .padding(.top, 6)
        .background(Paper.ground)
    }
}

/// The Mac's own search field, as the toolbar's search item draws it.
private struct SessionSearchField: NSViewRepresentable {
    @Binding var text: String

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = "Search sessions"
        field.sendsSearchStringImmediately = true
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        if field.stringValue != text { field.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }

        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSSearchField else { return }
            text.wrappedValue = field.stringValue
        }
    }
}
