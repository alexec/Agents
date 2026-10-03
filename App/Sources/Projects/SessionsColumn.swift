import AgentsKitCore
import SwiftUI

/// A row in the middle column: a session or a workflow. One list, one selection, so
/// the arrow keys, ⌘-click and ⌫ go through both alike.
enum ColumnPick: Hashable {
    case session(UUID)
    case workflow(Workflow.ID)
    /// The selected project's Dashboard (074), at the top of the column.
    case dashboard
}

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
    /// What the list has highlighted — one or several (⌘-click), sessions and workflows
    /// alike. Drives bulk Archive; `selection` and `model.openWorkflow` are still the one
    /// thing the right-hand column is reading.
    @State private var picked: Set<ColumnPick> = []

    /// Enough archived chats to find last week's; the rest are on the phone's archive
    /// and in Events. A list of every chat ever is the thing projects replaced.
    private static let archivedShown = 50

    var body: some View {
        List(selection: $picked) {
            // The Dashboard, then two groups: the sessions, archived ones folded at their
            // foot, then the workflows. A search narrows both.
            // The Dashboard first, above Needs you (074 FR-031): somewhere to come back to,
            // not a session. Left out of a search, which is about sessions and workflows.
            if let folder = model.selectedProject, model.selectedProjectSummary != nil, query.isEmpty {
                Section {
                    DashboardRow(folder: folder)
                }
            }
            if model.selectedProjectSummary != nil {
                Section {
                    // The same headings the project page draws, one step down.
                    ForEach(AgentGroup.live, id: \.self) { group in
                        ForEach(group.headings(matching(model.agents(in: model.selectedProjectKey, group: group)))) { part in
                            subheading(part.title, count: part.agents.count,
                                       unread: part.agents.filter(\.showsUnread).count)
                            ForEach(part.agents) { agent in
                                row(agent)
                            }
                        }
                    }
                    if query.isEmpty, !hasLive {
                        Text("No sessions yet. Say what you want done on the right.")
                            .appText(.fine)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.vertical, 6)
                    }
                    archivedSessions
                } header: {
                    heading("Sessions", count: liveCount)
                }
            }
            ProjectWorkSections(folder: model.selectedProject, query: query)
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
                ContentUnavailableView("No matches",
                                       systemImage: "bubble.left.and.bubble.right",
                                       description: Text("No session or workflow matches “\(query)”."))
            }
        }
        // ⌫ archives everything highlighted that is not already archived (one or many).
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
            // Here rather than on the project's own page, so it stays in reach with a
            // session open (#97). A session's project is the selected one: opening an
            // agent selects its project.
            ToolbarItem {
                Button { requests.projectSettings = .general } label: {
                    Label("Project Settings", systemImage: "slider.horizontal.3")
                }
                .help("Project Settings (⌥⌘,)")
                .disabled(model.selectedProjectSummary == nil)
            }
            if picked.count > 1 {
                ToolbarSpacer(.fixed)
                ToolbarItem {
                    Button("Archive \(picked.count)") { archivePicked() }
                        .help("Archive the highlighted sessions and workflows")
                }
            }
            if model.selection != nil, model.openWorkflow == nil, !model.openDashboard {
                ToolbarSpacer(.fixed)
                ToolbarItem {
                    SidebarToggle(windowWidth: frame.windowWidth)
                }
            }
        }
        .onChange(of: picked) { _, ids in applyPicked(ids) }
        // A workflow opened is what the right-hand side reads now, so it is the row lit
        // and no session names the window.
        .onChange(of: model.openWorkflow) { _, id in applyOpenWorkflow(id) }
        .onChange(of: model.openDashboard) { _, open in applyOpenDashboard(open) }
        .onChange(of: selection) { _, id in applySelection(id) }
        .onAppear {
            applySelection(selection)
            applyOpenWorkflow(model.openWorkflow)
            applyOpenDashboard(model.openDashboard)
        }
    }

    private func newSession() {
        picked = []
        selection = nil
        model.openWorkflow = nil
        model.openDashboard = false
        requests.focusPrompt()
    }

    /// One pick opens that chat or that workflow's page; several keep what is open only
    /// if it is among them.
    private func applyPicked(_ picks: Set<ColumnPick>) {
        switch picks.count {
        case 0:
            break
        case 1:
            switch picks.first {
            case .session(let id):
                if selection != id { selection = id }
            case .workflow(let id):
                if model.openWorkflow != id { model.openWorkflow = id }
            case .dashboard:
                if !model.openDashboard { model.openDashboard = true }
            case nil:
                break
            }
        default:
            if let current = selection, !picks.contains(.session(current)) { selection = nil }
            if let open = model.openWorkflow, !picks.contains(.workflow(open)) { model.openWorkflow = nil }
            if model.openDashboard, !picks.contains(.dashboard) { model.openDashboard = false }
        }
    }

    /// The Dashboard opened from anywhere lights its row.
    private func applyOpenDashboard(_ open: Bool) {
        if open {
            if picked != [.dashboard] { picked = [.dashboard] }
        } else if picked == [.dashboard] {
            picked = []
        }
    }

    /// Opening a chat from the menu or Go replaces a multi-pick with that one row.
    private func applySelection(_ id: UUID?) {
        if let id {
            if picked.count <= 1 || !picked.contains(.session(id)) { picked = [.session(id)] }
        } else if picked.count == 1, case .session = picked.first {
            picked = []
        }
    }

    /// The same for a workflow opened from anywhere: the banner, Go, its own page.
    private func applyOpenWorkflow(_ id: Workflow.ID?) {
        if let id {
            selection = nil
            if picked.count <= 1 || !picked.contains(.workflow(id)) { picked = [.workflow(id)] }
        } else if picked.count == 1, case .workflow = picked.first {
            picked = []
        }
    }

    private func archivePicked() {
        var picks = picked
        if picks.isEmpty {
            if let selection { picks = [.session(selection)] }
            else if let open = model.openWorkflow { picks = [.workflow(open)] }
        }
        let workflows = model.workflows(in: model.selectedProject)
        var sessions: [UUID] = []
        var flows: [WorkflowSummary] = []
        for pick in picks {
            switch pick {
            case .session(let id):
                if model.agents.first(where: { $0.id == id })?.state != .archived { sessions.append(id) }
            case .workflow(let id):
                if let summary = workflows.first(where: { $0.id == id }), !summary.isArchived { flows.append(summary) }
            case .dashboard:
                break
            }
        }
        guard !sessions.isEmpty || !flows.isEmpty else { return }
        Task {
            for id in sessions {
                await model.archive(id, andLeave: false)
            }
            for summary in flows {
                await model.setWorkflowArchived(summary, true)
            }
            if let open = selection, sessions.contains(open) { selection = nil }
            if let open = model.openWorkflow, flows.contains(where: { $0.id == open }) { model.openWorkflow = nil }
            picked.subtract(sessions.map(ColumnPick.session))
            picked.subtract(flows.map { ColumnPick.workflow($0.id) })
        }
    }

    private func row(_ agent: Agent) -> some View {
        AgentRow(agent: agent, isCompact: true)
            // Title plus the line under it (what it said); list rows that start too short
            // clip that second line once it arrives.
            .padding(.vertical, 6)
            .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
            .tag(ColumnPick.session(agent.id))
            // The list's own swipe, in place of the cards' hand-built one.
            .swipeActions(edge: .trailing) {
                if agent.state == .archived {
                    SwipeAction("Bring Back") { await model.unarchive(agent.id) }
                } else {
                    SwipeAction("Archive", systemImage: "archivebox") {
                        await model.archive(agent.id, andLeave: true)
                    }
                    .tint(.gray)
                }
            }
    }

    /// Archived sessions, folded under the live ones, with what has been retired from
    /// here (051) as the last line.
    @ViewBuilder
    private var archivedSessions: some View {
        let archived = matching(model.agents(in: model.selectedProjectKey, group: .archived))
        let retiredLine = query.isEmpty
            ? RetirementWords.retiredLine(model.selectedProjectSummary?.retiredCount) : nil
        if !archived.isEmpty || retiredLine != nil {
            DisclosureGroup(isExpanded: $showsArchived) {
                ForEach(query.isEmpty ? Array(archived.prefix(Self.archivedShown)) : archived) { agent in
                    row(agent)
                }
                if let retiredLine {
                    Text(retiredLine)
                        .appText(.supporting)
                        .foregroundStyle(.secondary)
                }
            } label: {
                // Named for what it holds, as Workflows' own is: the section heading is
                // often scrolled away by the time this is read.
                subheading("Archived sessions", count: archived.count)
            }
        }
    }

    /// A group within Sessions: Working, Needs you, Archived sessions. With how many
    /// under it are unread (#70), so finished work is not missed now it sits in Done.
    private func subheading(_ title: String, count: Int, unread: Int = 0) -> some View {
        HStack(spacing: 6) {
            Text(title)
            Text("\(count)").monospacedDigit().foregroundStyle(.tertiary)
            if unread > 0 {
                Text("· \(unread) unread").monospacedDigit()
            }
        }
        .appText(.fine)
        .foregroundStyle(.secondary)
        .padding(.top, 4)
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

    /// The sessions under the Sessions heading that are not archived.
    private var liveCount: Int {
        AgentGroup.live.reduce(0) { $0 + matching(model.agents(in: model.selectedProjectKey, group: $1)).count }
    }

    /// Whether the project has a session that is not archived.
    private var hasLive: Bool {
        AgentGroup.live.contains { !model.agents(in: model.selectedProjectKey, group: $0).isEmpty }
    }

    private var hasAny: Bool {
        AgentGroup.allCases.contains {
            !matching(model.agents(in: model.selectedProjectKey, group: $0)).isEmpty
        } || model.workflows(in: model.selectedProject).contains(where: SessionLabelQuery(query).matches)
    }
}

/// The Mac's own search field, as the toolbar's search item draws it.
private struct SessionSearchField: NSViewRepresentable {
    @Binding var text: String
    @Binding var wantsFocus: Bool

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = "Search sessions and workflows"
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
