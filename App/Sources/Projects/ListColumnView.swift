import AgentsKitCore
import SwiftUI

/// The window's second column (#866): the sessions and workflows of what the source list
/// has picked, a smart group's or a project's, each helper under the session that started
/// it (#835). A session is listed in every group it fits, and in its project too: with a
/// column each, "listed once" (#587, #689) has no list to keep short.
///
/// The search is this column's, and finds within what it lists.
struct ListColumnView: View {
    @Environment(AppModel.self) private var model
    @Environment(WindowRequests.self) private var requests
    let column: ListColumn
    @Binding var selection: SidebarItem?

    @State private var folds = SidebarFolds()
    /// What the list has highlighted — one or several (⌘-click), sessions and workflows
    /// alike. Drives bulk Archive; `selection` is still the one thing the detail reads.
    @State private var picked: Set<SidebarItem> = []
    @State private var query = ""
    /// What the rows filter by: the field's words once typing pauses (#176).
    @State private var searched = ""
    /// Bumped to make the list again when its outline has drifted from the model (#237).
    @State private var outlineRebuilds = 0
    /// Projects whose every archived match is on show, past the first few (#176).
    @State private var showingAllMatches = false
    @FocusState private var searchFocused: Bool
    @FocusState private var listFocused: Bool

    /// What it lists: column 1's pick, or Needs You before anything is picked.
    private var source: ListSource { column.source ?? .smart(.needsYou) }

    private var orderedProjects: [DaemonAPI.ProjectSummary] {
        SidebarOrder.projects(model.liveProjects, servers: model.hosts.servers)
    }

    var body: some View {
        List(selection: $picked) {
            switch source {
            case .smart(let row):
                SmartListRows(row: row, projects: orderedProjects.map(\.key), folds: folds, query: searched)
            case .project(let key):
                if let summary = model.work.project(key) {
                    ProjectListRows(summary: summary, folds: folds, query: searched,
                                    showsAllMatches: showingAllMatches,
                                    showAllMatches: { showingAllMatches = true })
                }
            case .activity:
                EmptyView()
            }
        }
        .id(outlineRebuilds)
        .onReceive(NotificationCenter.default.publisher(for: .outlineListDrifted)) { _ in
            outlineRebuilds &+= 1
        }
        .listStyle(.sidebar)
        .focused($listFocused)
        .environment(\.sidebarPicks, SidebarPicks(items: picked, listFocused: listFocused))
        .environment(\.sidebarRowSize, .small)
        .scrollContentBackground(.hidden)
        .background(Paper.ground)
        .overlay { if isEmpty { emptyWords } }
        .safeAreaInset(edge: .top, spacing: 0) { heading }
        .task(id: query) {
            let words = query.trimmingCharacters(in: .whitespacesAndNewlines)
            if !words.isEmpty { try? await Task.sleep(for: .milliseconds(150)) }
            guard !Task.isCancelled else { return }
            if words != searched {
                searched = words
                showingAllMatches = false
            }
            await model.searchSessions(words)
        }
        .onChange(of: column.source) { showingAllMatches = false }
        .onDeleteCommand { archivePicked() }
        .onKeyPress(.return, action: renamePicked)
        .onChange(of: picked) { _, picks in applyPicked(picks) }
        .onChange(of: selection, initial: true) { _, item in applySelection(item) }
        .onChange(of: requests.wantsSessionSearchFocus) { _, wants in
            guard wants else { return }
            column.isShown = true
            searchFocused = true
            requests.wantsSessionSearchFocus = false
        }
    }

    /// The column's name and its search, above the rows: Mail's mailbox name over its
    /// messages.
    private var heading: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .appText(.reading).fontWeight(.semibold)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let subtitle {
                    Text(subtitle)
                        .appText(.fine)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search", text: $query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onSubmit { listFocused = true }
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Clear the search")
                }
            }
            .appText(.supporting)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(.quaternary.opacity(0.6), in: .rect(cornerRadius: 6))
            .onExitCommand { query = ""; listFocused = true }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .background(Paper.ground)
    }

    private var title: String {
        switch source {
        case .smart(let row): row.title
        case .project(let key):
            model.work.project(key).map { SidebarOrder.label($0) { model.hosts.label($0) } } ?? key.folder.lastPathComponent
        case .activity: ""
        }
    }

    private var subtitle: String? {
        let count: Int
        switch source {
        case .smart(let row): count = row.count(in: model.work, projects: orderedProjects.map(\.key), listedOnce: false)
        case .project(let key): count = SidebarProjectFold.ownCount(key, in: model.work, listedOnce: false)
        case .activity: return nil
        }
        return count > 0 ? "\(count)" : nil
    }

    private var isEmpty: Bool {
        switch source {
        case .smart(let row):
            !row.isShown(in: model.work, projects: orderedProjects.map(\.key), query: searched, listedOnce: false)
        case .project(let key):
            model.work.project(key) == nil
        case .activity:
            false
        }
    }

    private var emptyWords: some View {
        let words: String = switch source {
        case .smart(.needsYou) where searched.isEmpty: "Nobody needs you"
        case .smart(.working) where searched.isEmpty: "Nothing working"
        case .smart(.unread) where searched.isEmpty: "Nothing unread"
        case .smart(.pinned) where searched.isEmpty: "Nothing pinned"
        case .project: "This project is gone"
        default: "No matches"
        }
        return Text(words)
            .appText(.supporting)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(false)
    }

    /// One pick opens that page; several keep what is open only if it is among them.
    /// None changes nothing: macOS clears a list's selection by itself while rows come
    /// and go, and that must not empty the detail.
    private func applyPicked(_ picks: Set<SidebarItem>) {
        switch picks.count {
        case 0:
            break
        case 1:
            if let pick = picks.first, selection != pick { selection = pick }
        default:
            if let current = selection, !picks.contains(current) { model.showNothing() }
        }
    }

    /// What is open, from anywhere, lights its row when this list has it.
    private func applySelection(_ item: SidebarItem?) {
        guard let item else {
            if picked.count == 1 { picked = [] }
            return
        }
        if picked.count <= 1 || !picked.contains(item) { picked = [item] }
    }

    /// Return on one highlighted session edits its title in its row (#751).
    private func renamePicked() -> KeyPress.Result {
        guard model.renaming == nil, picked.count == 1, case .session(let id)? = picked.first,
              let agent = model.work.agent(id), agent.state != .archived else { return .ignored }
        model.renaming = Renaming(id: id)
        return .handled
    }

    private func archivePicked() {
        var sessions: [UUID] = []
        var flows: [WorkflowSummary] = []
        for pick in picked.isEmpty ? Set(selection.map { [$0] } ?? []) : picked {
            switch pick {
            case .session(let id):
                if model.work.agent(id)?.state != .archived { sessions.append(id) }
            case .workflow(let id, let key):
                if let summary = model.workflows(in: key.folder).first(where: { $0.id == id }), !summary.isArchived {
                    flows.append(summary)
                }
            default:
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
            if case .session(let open) = selection, sessions.contains(open) { model.showNothing() }
            if case .workflow(let open, _) = selection, flows.contains(where: { $0.id == open }) { model.showNothing() }
            picked = picked.filter { pick in
                switch pick {
                case .session(let id): !sessions.contains(id)
                case .workflow(let id, _): !flows.contains { $0.id == id }
                default: true
                }
            }
        }
    }
}

/// A smart group's rows (#866): its sessions, each under the session that started it
/// when the group lists that too (#835), each with its project's name; Needs You's
/// approvals after them (#773); Pinned's workflows after its sessions.
struct SmartListRows: View {
    @Environment(AppModel.self) private var model
    let row: SidebarSmartRow
    let projects: [ProjectKey]
    let folds: SidebarFolds
    let query: String

    var body: some View {
        if row == .pinned {
            pinnedRows
        } else {
            let agents = row.agents(in: model.work, projects: projects, query: query, listedOnce: false)
            ForEach(FoldedRow.rows(SidebarTree.rows(agents, in: model.work, folds: folds), in: .smart(row))) { item in
                SessionSidebarRow(agent: item.item.agent, place: place(of: item.item.agent),
                                  tree: item.item, folds: folds)
            }
            ForEach(row.approvals(in: model.work, projects: projects, query: query), id: \.approval.id) { item in
                ApprovalListRow(approval: item.approval, project: item.project, place: place(of: item.project))
            }
        }
    }

    /// Every project's pinned sessions, then its pinned workflows, each dragged into the
    /// order wanted among its own project's and its own kind (#180, #432).
    @ViewBuilder
    private var pinnedRows: some View {
        let searching = !query.isEmpty
        ForEach(projects, id: \.self) { key in
            let sessions = SidebarSmartRow.pinned.agents(in: model.work, projects: [key], query: query)
            ForEach(FoldedRow.rows(sessions, in: .smart(.pinned))) { item in
                SessionSidebarRow(agent: item.item, place: place(of: item.item))
            }
            .onMove { from, to in
                guard !searching else { return }
                var ids = sessions.map(\.id)
                ids.move(fromOffsets: from, toOffset: to)
                let shown = Set(ids)
                let rest = model.pinnedSessions(in: key.folder).filter { !shown.contains($0) }
                Task { await model.arrangeSessionPins(ids + rest, in: key) }
            }
            let flows = SidebarSmartRow.pinned.workflows(in: model.work, projects: [key], query: query).map(\.workflow)
            ForEach(FoldedRow.rows(flows, in: .smart(.pinned))) { item in
                WorkflowListRow(summary: item.item, project: key)
            }
            .onMove { from, to in
                guard !searching else { return }
                var ids = flows.map(\.workflowID)
                ids.move(fromOffsets: from, toOffset: to)
                let shown = Set(ids)
                let rest = model.pinnedWorkflows(in: key.folder).filter { !shown.contains($0) }
                Task { await model.arrangeWorkflowPins(ids + rest, in: key) }
            }
        }
    }

    private func place(of agent: Agent) -> String? {
        place(of: ProjectKey(host: agent.host, folder: agent.projectFolder))
    }

    private func place(of key: ProjectKey) -> String? {
        guard let summary = model.work.project(key) else { return nil }
        return SidebarOrder.label(summary) { model.hosts.label($0) }
    }
}

/// One project's rows (#866): its pinned pages, every live session newest first (pinned
/// or waiting too), its workflows, then its MCP Servers and Archived pages; while
/// searching, its archived matches.
struct ProjectListRows: View {
    @Environment(AppModel.self) private var model
    let summary: DaemonAPI.ProjectSummary
    let folds: SidebarFolds
    let query: String
    var showsAllMatches = false
    var showAllMatches: () -> Void = {}

    private var key: ProjectKey { summary.key }

    var body: some View {
        let fold = SidebarProjectFold(key, label: SidebarOrder.label(summary) { model.hosts.label($0) },
                                      in: model.work, query: query, isOpen: true, listedOnce: false)
        if fold.showsPinnedPages {
            PinnedPageRows(project: key)
        }
        ForEach(FoldedRow.rows(SidebarTree.rows(fold.sessions, in: model.work, folds: folds), in: .sessions)) { row in
            SessionSidebarRow(agent: row.item.agent, tree: row.item, folds: folds)
        }
        if !fold.sessions.isEmpty && !fold.workflows.isEmpty {
            Divider()
                .listRowInsets(.vertical, 2)
                .accessibilityHidden(true)
        }
        ForEach(FoldedRow.rows(fold.workflows, in: .workflows)) { row in
            WorkflowListRow(summary: row.item, project: key)
        }
        if fold.isSearching {
            ForEach(FoldedRow.rows(fold.archivedWorkflows, in: .archivedWorkflows)) { row in
                WorkflowListRow(summary: row.item, project: key)
            }
            let shown = fold.archivedShown(showingAll: showsAllMatches)
            ForEach(FoldedRow.rows(shown, in: .archivedSessions)) { row in
                SessionSidebarRow(agent: row.item)
            }
            if fold.archived.count > shown.count {
                Button("Show all \(fold.archived.count)", action: showAllMatches)
                    .buttonStyle(.plain)
                    .appText(.fine)
                    .foregroundStyle(.secondary)
            }
        } else {
            let servers = model.work.mcpServers(in: key)
            if let tally = MCPHealthWords.tally(servers) {
                ProjectPageRow(title: "MCP Servers", systemImage: "server.rack",
                               item: .projectMCPServers(key), warns: tally.failing)
                    .help(tally.words)
            }
            let archived = fold.archivedCount(summary) + fold.archivedWorkflows.count
            if archived > 0 {
                ProjectPageRow(title: "Archived", systemImage: "archivebox", item: .archive(key))
                    .help("\(archived) archived")
            }
        }
    }
}

/// The handle between the list column and the session, dragged to size the list.
struct ListColumnHandle: View {
    let column: ListColumn
    @State private var startWidth: CGFloat?

    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1)
            .padding(.horizontal, 2)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { drag in
                    let start = startWidth ?? column.width
                    startWidth = start
                    column.width = min(max(start + drag.translation.width, ListColumn.minWidth), ListColumn.maxWidth)
                }
                .onEnded { _ in startWidth = nil })
            .accessibilityHidden(true)
    }
}
