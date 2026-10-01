import AgentsKitCore
#if !AGENTS_STORE
import AgentsKit
#endif
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
    /// What the list has highlighted — one or several (⌘-click). Drives bulk Archive;
    /// `selection` is still the one chat the right-hand column is reading.
    @State private var picked: Set<UUID> = []

    /// Enough archived chats to find last week's; the rest are on the phone's archive
    /// and in Events. A list of every chat ever is the thing projects replaced.
    private static let archivedShown = 50

    var body: some View {
        List(selection: $picked) {
            // The same headings the project page draws.
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
            // A project with no sessions yet says so where they would be, rather than
            // over the whole column: its workflows are still below.
            if query.isEmpty, model.selectedProjectSummary != nil, !hasLive {
                Text("No sessions yet. Say what you want done on the right.")
                    .appText(.fine)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 6)
            }
            // Its workflows, above Archived so a long archive never buries them (066).
            // Not while searching, which is a search of the sessions.
            if query.isEmpty {
                ProjectWorkSections(folder: model.selectedProject)
            }
            let archived = matching(model.agents(in: model.selectedProjectKey, group: .archived))
            // What has been retired from here (051), as the section's last line.
            let retiredLine = query.isEmpty
                ? RetirementWords.retiredLine(model.selectedProjectSummary?.retiredCount) : nil
            if !archived.isEmpty || retiredLine != nil {
                Section(isExpanded: $showsArchived) {
                    ForEach(query.isEmpty ? Array(archived.prefix(Self.archivedShown)) : archived) { agent in
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
        .onChange(of: query) {
            if !query.isEmpty { showsArchived = true }
        }
        .scrollContentBackground(.hidden)
        .background(Paper.ground)
        .overlay {
            if model.selectedProjectSummary == nil {
                EmptyState.noProject
            } else if !hasAny, !query.isEmpty {
                ContentUnavailableView("No matching sessions",
                                       systemImage: "bubble.left.and.bubble.right",
                                       description: Text("No session matches “\(query)”."))
            }
        }
        // ⌫ archives every highlighted session that is not already archived (one or many).
        .onDeleteCommand { archivePicked() }
        // The window's title is this column's: the worktree this build came from, then
        // whatever the right-hand side is reading. The primary checkout is "main".
        .navigationTitle(AppCheckout.windowTitle(model.selectedAgent?.title ?? model.selectedProjectSummary?.name))
        .navigationSubtitle(model.selectedAgent == nil ? "" : (model.selectedProjectSummary?.name ?? ""))
        .toolbar {
            ToolbarSpacer(.fixed)
            ToolbarItem {
                SessionSearchField(text: $query, wantsFocus: Binding(
                    get: { requests.wantsSessionSearchFocus },
                    set: { if !$0 { requests.wantsSessionSearchFocus = false } }))
                    .frame(width: 240)
            }
            ToolbarSpacer(.fixed)
            // Compose, where Mail and Notes have it (066): the empty project pane is the
            // new chat, and this is the way back to it from a session.
            ToolbarItem {
                Button { newSession() } label: {
                    Label("New Session", systemImage: "square.and.pencil")
                }
                .help("Start a new session in this project (⌘N)")
                .disabled(model.selectedProjectSummary == nil)
            }
            if picked.count > 1 {
                ToolbarSpacer(.fixed)
                ToolbarItem {
                    Button("Archive \(picked.count)") { archivePicked() }
                        .help("Archive the highlighted sessions")
                }
            }
            if model.selection != nil, model.openWorkflow == nil {
                ToolbarSpacer(.fixed)
                ToolbarItem {
                    SidebarToggle(windowWidth: frame.windowWidth)
                }
            }
        }
        .onChange(of: picked) { _, ids in applyPicked(ids) }
        // A workflow opened is what the right-hand side reads now, so no session stays
        // lit or names the window.
        .onChange(of: model.openWorkflow) { _, id in
            guard id != nil else { return }
            picked = []
            selection = nil
        }
        .onChange(of: selection) { _, id in applySelection(id) }
        .onAppear { applySelection(selection) }
    }

    private func newSession() {
        picked = []
        selection = nil
        model.openWorkflow = nil
        requests.focusPrompt()
    }

    /// One pick opens that chat; several keep the open chat only if it is among them.
    private func applyPicked(_ ids: Set<UUID>) {
        switch ids.count {
        case 0:
            break
        case 1:
            if selection != ids.first { selection = ids.first }
        default:
            if let current = selection, !ids.contains(current) { selection = nil }
        }
    }

    /// Opening a chat from the menu or Go replaces a multi-pick with that one row.
    private func applySelection(_ id: UUID?) {
        if let id {
            if picked.count <= 1 || !picked.contains(id) { picked = [id] }
        } else if picked.count == 1 {
            picked = []
        }
    }

    private func archivePicked() {
        let ids = picked.isEmpty ? Set(selection.map { [$0] } ?? []) : picked
        let toArchive = ids.filter { id in
            model.agents.first(where: { $0.id == id })?.state != .archived
        }
        guard !toArchive.isEmpty else { return }
        Task {
            for id in toArchive {
                await model.archive(id, andLeave: false)
            }
            if let open = selection, toArchive.contains(open) { selection = nil }
            picked.subtract(toArchive)
        }
    }

    private func row(_ agent: Agent) -> some View {
        AgentRow(agent: agent, isCompact: true)
            // Title plus the line under it (what it said); list rows that start too short
            // clip that second line once it arrives.
            .padding(.vertical, 6)
            .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
            .tag(agent.id)
            // The list's own swipe, in place of the cards' hand-built one.
            .swipeActions(edge: .trailing) {
                if agent.state == .archived {
                    Button("Bring Back") { Task { await model.unarchive(agent.id) } }
                } else {
                    Button("Archive", systemImage: "archivebox") {
                        Task { await model.archive(agent.id, andLeave: true) }
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
        let words = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return agents }
        let matcher = SessionLabelQuery(words)
        return agents.filter(matcher.matches)
    }

    /// Whether the project has a session that is not archived.
    private var hasLive: Bool {
        AgentGroup.live.contains { !model.agents(in: model.selectedProjectKey, group: $0).isEmpty }
    }

    private var hasAny: Bool {
        AgentGroup.allCases.contains {
            !matching(model.agents(in: model.selectedProjectKey, group: $0)).isEmpty
        }
    }
}

/// The Mac's own search field, as the toolbar's search item draws it.
private struct SessionSearchField: NSViewRepresentable {
    @Binding var text: String
    @Binding var wantsFocus: Bool

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = "Search sessions"
        field.sendsSearchStringImmediately = true
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        if field.stringValue != text { field.stringValue = text }
        if wantsFocus {
            field.window?.makeFirstResponder(field)
            DispatchQueue.main.async { wantsFocus = false }
        }
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
