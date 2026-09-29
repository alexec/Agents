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
            // What else the project is working on: pull requests, Ready issues and
            // workflows. Not while searching, which is a search of the sessions.
            if query.isEmpty {
                ProjectWorkSections(folder: model.selectedProject)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(Paper.ground)
        .overlay {
            if model.selectedProjectSummary == nil {
                EmptyState.noProject
            } else if !hasAny, !(query.isEmpty && hasWork) {
                ContentUnavailableView(query.isEmpty ? "No sessions yet" : "No matches",
                                       systemImage: "bubble.left.and.bubble.right",
                                       description: Text(query.isEmpty
                                                         ? "Say what you want done on the right."
                                                         : "Nothing here says “\(query)”."))
            }
        }
        // ⌫ archives every highlighted session that is not already archived (one or many).
        .onDeleteCommand { archivePicked() }
        // The window's title is this column's: the worktree this build came from, then
        // whatever the right-hand side is reading. The primary checkout is "main".
        .navigationTitle(AppCheckout.windowTitle(model.selectedAgent?.title ?? model.selectedProjectSummary?.name))
        .navigationSubtitle(model.selectedAgent == nil ? "" : (model.selectedProjectSummary?.name ?? ""))
        .safeAreaInset(edge: .top, spacing: 0) {
            if model.selectedProjectSummary != nil {
                NewSessionRow {
                    picked = []
                    selection = nil
                    requests.focusPrompt()
                }
            }
        }
        .toolbar {
            ToolbarSpacer(.fixed)
            ToolbarItem {
                SessionSearchField(text: $query, wantsFocus: Binding(
                    get: { requests.wantsSessionSearchFocus },
                    set: { if !$0 { requests.wantsSessionSearchFocus = false } }))
                    .frame(width: 240)
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
        // The pull requests and issues the daemon has, then a refresh, each time a
        // project opens (038 FR-008). Never polled from here.
        .task(id: model.selectedProject) {
            if let folder = model.selectedProject {
                await model.loadPullRequests(for: folder)
                await model.loadGitHubProjectBoard(for: folder)
            }
        }
        .onChange(of: picked) { _, ids in applyPicked(ids) }
        .onChange(of: selection) { _, id in applySelection(id) }
        .onAppear { applySelection(selection) }
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
        let words = query.trimmingCharacters(in: .whitespaces)
        guard !words.isEmpty else { return agents }
        return agents.filter { agent in
            [agent.title, agent.report?.message].compactMap { $0 }
                .contains { $0.localizedCaseInsensitiveContains(words) }
        }
    }

    /// Whether `ProjectWorkSections` has anything to draw, so the empty state does not
    /// sit over it.
    private var hasWork: Bool {
        guard let folder = model.selectedProject.map(Project.standardize) else { return false }
        if let list = model.pullRequestLists[folder], !list.pullRequests.isEmpty || list.problem != nil { return true }
        if let board = model.githubProjectBoards[folder],
           board.problem != nil || board.issues.contains(where: { $0.status == .ready }) { return true }
        return model.workflows(in: folder).contains { !$0.isArchived }
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
                .background(isHovered ? Paper.wash : .clear,
                            in: RoundedRectangle(cornerRadius: Paper.Radius.card))
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
