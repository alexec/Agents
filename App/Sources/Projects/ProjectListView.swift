import AgentsKitCore
import SwiftUI

/// The window's one sidebar (#145): Activity at the top, then every project, each a row
/// that folds open on its sessions and workflows, and at the foot what this Mac and its
/// hosts are doing.
///
/// It used to be two columns, the projects and the sessions of the one picked. The
/// projects column was mostly closed, and closing it hid what it said at a glance: what
/// Spending has left, which projects have something going on, that the Mac is being kept
/// awake, that a host is not answering. One list keeps all of that in sight.
struct ProjectListView: View {
    @Environment(AppModel.self) private var model
    @Environment(WindowRequests.self) private var requests
    @Binding var selection: SidebarItem?

    @AppStorage("showsArchivedProjects") private var showsArchived = false
    /// Activity, open until folded, and kept so.
    @AppStorage("showsActivity") private var showsActivity = true
    @State private var folds = SidebarFolds()
    /// What the list has highlighted — one or several (⌘-click), sessions and workflows
    /// alike. Drives bulk Archive; `selection` is still the one thing the detail reads.
    @State private var picked: Set<SidebarItem> = []
    @State private var query = ""
    /// What the folds filter by: the field's words once typing pauses, so a keystroke
    /// costs the field and not a pass over every project (#176).
    @State private var searched = ""
    /// Bumped to make the list again when its outline has drifted from the model (#237).
    @State private var outlineRebuilds = 0
    /// Projects whose every match is on show, past the first few (#176).
    @State private var showingAllMatches: Set<ProjectKey> = []
    @FocusState private var searchFocused: Bool
    /// Whether the list itself has the keyboard: only then is a picked row filled with
    /// the accent rather than a grey wash (see `SidebarInk`).
    @FocusState private var listFocused: Bool
    @State private var isChoosingFolder = false
    @State private var isCloning = false
    /// Which machine the New project menu was pointed at (037).
    @State private var targetHost: HostID = .mac
    @State private var isChoosingServerFolder = false
    @State private var isAddingServer = false

    /// This Mac's projects, then each server's: no headings for hosts (Alex, #145), the
    /// host is in a server project's own name.
    private var orderedProjects: [DaemonAPI.ProjectSummary] {
        SidebarOrder.projects(model.liveProjects, servers: model.hosts.servers)
    }

    var body: some View {
        List(selection: $picked) {
            // What wants the person, across every project and host (#495): Things'
            // Inbox and Today, Mail's smart mailboxes. Always drawn, so the list does not
            // move as states change; the pages about all the work that used to be here
            // are in the toolbar and the View menu.
            Section {
                // One way to start a session (#495), in the project last started in; the
                // page it opens can switch project.
                NewSessionTopRow()
            }

            // The pages about all the work, a group like a project's, above the smart
            // groups (Alex, #495): rows of
            // the list, so they take its selection and keys, each with its icon in the
            // accent beside the plain title (#155), and folding as a project does.
            Section(isExpanded: $showsActivity) {
                EventsRow().activityIcon("list.bullet.rectangle")
                    .appText(.supporting).sidebarInk(.events).tag(SidebarItem.events)
                ResourcesRow().activityIcon("square.stack.3d.up")
                    .appText(.supporting).sidebarInk(.resources).tag(SidebarItem.resources)
                RuntimesRow().activityIcon("cpu")
                    .appText(.supporting).sidebarInk(.runtimes).tag(SidebarItem.runtimes)
                SpendingRow(selection: $selection).activityIcon("dollarsign.circle")
                    .appText(.supporting).sidebarInk(.spending).tag(SidebarItem.spending)
            } header: {
                // The size of every other group's heading (#495).
                Text("Activity").appText(.supporting)
            }

            // Pinned, Needs You, Working, Unread: a group each, headed and folding as a
            // project's is, so every group in the list lines up alike (#495).
            ForEach(SidebarSmartRow.allCases, id: \.self) { row in
                SmartFold(row: row, projects: orderedProjects.map(\.key), folds: folds, query: searched)
            }

            // One group per project (#495), its name the group's heading, its sessions the
            // rows: Mail's accounts rather than a Projects heading with folds under it.
            ForEach(orderedProjects, id: \.key) { summary in
                ProjectFold(summary: summary, folds: folds, query: searched,
                            showsAllMatches: showingAllMatches.contains(summary.key),
                            showAllMatches: { showingAllMatches.insert(summary.key) })
            }

            Section {
                // A host had more matches than its page: the next page, on asking (#176).
                if !searched.isEmpty, model.searchHasMore {
                    Button("More matches…") { Task { await model.searchMore() } }
                        .buttonStyle(.plain)
                        .appText(.fine)
                        .foregroundStyle(.secondary)
                }
                ForEach(model.hosts.servers, id: \.self) { host in
                    GoneProjectRows(host: host)
                }
                // Where the project will be once it is one (027).
                ForEach(model.clones) { clone in
                    CloningRow(clone: clone).appText(.supporting)
                }
                if model.projects.isEmpty, model.clones.isEmpty, model.hasLoadedProjects, model.isConnected {
                    EmptyProjectList(isChoosingFolder: $isChoosingFolder, isCloning: $isCloning)
                        .appText(.supporting)
                }
            }

            if !model.archivedProjects.isEmpty, searched.isEmpty {
                Section(isExpanded: $showsArchived) {
                    // None while folded, as under a folded project (#356).
                    ForEach(showsArchived ? model.archivedProjects : [], id: \.key) { summary in
                        ArchivedProjectRow(summary: summary) { await model.unarchiveProject(summary.key) }
                            .appText(.supporting)
                    }
                } header: {
                    Text("Archived projects").appText(.supporting)
                }
            }
        }
        // AppKit swallows the exception a drifted outline throws, and the rows stay wrong
        // until the list is made again (#237): once per drift, keeping folds, selection
        // and search, which live outside it. The scroll goes back to the top.
        .id(outlineRebuilds)
        .onReceive(NotificationCenter.default.publisher(for: .outlineListDrifted)) { _ in
            outlineRebuilds &+= 1
        }
        .listStyle(.sidebar)
        .focused($listFocused)
        .environment(\.sidebarPicks, SidebarPicks(items: picked, listFocused: listFocused))
        // Rows as tall as their lines (#104). Small also makes the sidebar's own text
        // small, so each row says `.appText(.supporting)` to keep the size it was read at,
        // the size of the session titles beside it.
        .environment(\.sidebarRowSize, .small)
        .scrollContentBackground(.hidden)
        .background(Paper.sidebar)
        .searchable(text: $query, placement: .sidebar, prompt: "Search")
        // After a pause in the typing (#176): the folds filter what is held, and the
        // archived sessions that match are the hosts' to find, a capped page each (#165).
        .task(id: query) {
            let words = query.trimmingCharacters(in: .whitespacesAndNewlines)
            if !words.isEmpty { try? await Task.sleep(for: .milliseconds(150)) }
            guard !Task.isCancelled else { return }
            if words != searched {
                let timing = Perf.begin("search")
                searched = words
                showingAllMatches = []
                Perf.endWhenDrawn(timing, "\(words.count) characters")
            }
            await model.searchSessions(words)
        }
        .searchFocused($searchFocused)
        // What this Mac and its hosts are doing, pinned at the foot: status lines rather
        // than somewhere to go, so not rows of the list. Each is absent when there is
        // nothing to say, which is most of the time (024 FR-015).
        .safeAreaInset(edge: .bottom, spacing: 0) {
            SidebarFoot()
        }
        // ⌫ archives everything highlighted that is not already archived (one or many).
        .onDeleteCommand { archivePicked() }
        .onChange(of: picked) { _, picks in applyPicked(picks) }
        .onChange(of: selection, initial: true) { _, item in applySelection(item) }
        .onChange(of: requests.wantsSessionSearchFocus) { _, wants in
            guard wants else { return }
            searchFocused = true
            requests.wantsSessionSearchFocus = false
        }
        // A folder dragged in from Finder becomes a project, as File ▸ Add Project
        // Folder… does. Folders only: a file is not somewhere to work. A file dropped on
        // a project's or a session's row goes into its drop box instead (#231).
        .dropDestination(for: URL.self) { urls, _ in
            let folders = urls.filter { $0.hasDirectoryPath || (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            guard !folders.isEmpty else { return false }
            Task { for folder in folders { await model.addProject(folder) } }
            return true
        }
        .fileImporter(isPresented: $isChoosingFolder, allowedContentTypes: [.folder]) { result in
            guard case .success(let folder) = result else { return }
            Task { await model.addProject(folder) }
        }
        // New Chat found no chat project to open (#229): why, and Unarchive when that is it.
        .alert("No chat project", isPresented: Binding(
            get: { model.chatProblem != nil }, set: { if !$0 { model.chatProblem = nil } }),
            presenting: model.chatProblem) { problem in
            if problem.archived != nil {
                Button("Unarchive") {
                    Task {
                        await model.unarchiveChatProject(problem)
                        requests.focusPrompt()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } else {
                Button("OK", role: .cancel) {}
            }
        } message: { problem in
            Text(problem.message)
        }
        .sheet(isPresented: $isCloning) { CloneSheet(host: targetHost).paperSheet() }
        .sheet(isPresented: $isChoosingServerFolder) { RemoteFolderSheet(host: targetHost).paperSheet() }
        .sheet(isPresented: Binding(get: { requests.dropboxProject != nil },
                                    set: { if !$0 { requests.dropboxProject = nil } })) {
            if let project = requests.dropboxProject { DropboxSheet(project: project).paperSheet() }
        }
        // File ▸ Add Project…, Clone Project from Git URL…, their On menus for a server,
        // and Add Server….
        .onChange(of: requests.projectSheet) { _, sheet in
            guard let sheet else { return }
            requests.projectSheet = nil
            switch sheet {
            case .chooseFolder(let host):
                targetHost = host
                if model.isOnThisMac(host) { isChoosingFolder = true } else { isChoosingServerFolder = true }
            case .clone(let host):
                targetHost = host
                isCloning = true
            case .addServer:
                targetHost = .mac
                isAddingServer = true
            }
        }
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

    /// What is open, from anywhere — a menu, Go, a banner, a link — lights its row, and
    /// unfolds its project so the row is there to light.
    private func applySelection(_ item: SidebarItem?) {
        guard let item else {
            if picked.count == 1 { picked = [] }
            return
        }
        if case .session(let id) = item, let agent = model.work.agent(id) {
            folds.set(ProjectKey(host: agent.host, folder: agent.projectFolder), open: true)
        } else if case .workflow(_, let key) = item {
            folds.set(key, open: true)
        } else if case .pin(_, let key) = item {
            folds.set(key, open: true)
        } else if case .archive(let key) = item {
            folds.set(key, open: true)
        } else if case .project(let key) = item {
            // A new session, from ⌘N or a menu: its row is in the fold.
            folds.set(key, open: true)
        }
        if picked.count <= 1 || !picked.contains(item) { picked = [item] }
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

/// One project in the sidebar: its row, and folded under it its sessions — Needs you
/// first, the way the project page groups them — then its workflows, each kind's
/// archived ones folded once more at its foot.
///
/// A search unfolds every project with something that matches and hides the rest.
private struct ProjectFold: View {
    @Environment(AppModel.self) private var model
    @Environment(WindowRequests.self) private var requests
    let summary: DaemonAPI.ProjectSummary
    let folds: SidebarFolds
    /// The search's words, already trimmed; empty when there is no search.
    let query: String
    var showsAllMatches = false
    var showAllMatches: () -> Void = {}

    private var key: ProjectKey { summary.key }

    var body: some View {
        // Folded, nothing under the row is drawn, so nothing is filed for it: the row
        // reads its own numbers off the project's shelf (#165). What goes under which
        // heading is the shared model's, which the Remote draws too (#226).
        let fold = SidebarProjectFold(key, label: label, in: model.work, query: query,
                                      isOpen: folds.isOpen(key))
        let isOpen = fold.isUnfolded
        if fold.isShown {
            Section(isExpanded: Binding(
                get: { isOpen },
                set: { folds.set(key, open: $0) })) {
                // Folded, nothing at all is under the heading (#356): see `isUnfolded`.
                // A session starts from New Session at the top (#495), or the menu.
                // The project's pinned pages (#159), before its sessions. Not while
                // searching: the search is for sessions.
                if fold.showsPinnedPages {
                    PinnedPageRows(project: key)
                }
                // Its pinned sessions and workflows are in Pinned at the top (#495).
                // Then every other live session, newest first, its state a mark on the
                // row rather than a heading over it (#495).
                ForEach(FoldedRow.rows(fold.sessions, in: .sessions)) { row in
                    SessionSidebarRow(agent: row.item)
                }
                // Then its workflows, after the sessions (Alex, #495): rows, not a page.
                ForEach(FoldedRow.rows(fold.workflows, in: .workflows)) { row in
                    WorkflowListRow(summary: row.item, project: key)
                }
                if fold.isSearching {
                    // What matched in the archive, in the group while searching, so a
                    // match is one click away as it was.
                    searchMatches(fold)
                } else {
                    // The archive, one row opening a page (#495): never a fold inside
                    // the group.
                    let archived = fold.archivedCount(summary) + fold.archivedWorkflows.count
                    if archived > 0 {
                        ProjectPageRow(title: "Archived", systemImage: "archivebox",
                                       count: archived, item: .archive(key))
                    }
                }
            } header: {
                ProjectRow(summary: summary, label: label, isFolded: !isOpen, asHeading: true) {
                    // A search holds every match open.
                    if !fold.isSearching { folds.set(key, open: !isOpen) }
                }
                    .appText(.supporting)
                    // As tall as its one or two lines and a little air (#104).
                    .listRowInsets(.vertical, 3)
                    // Last known, not current: the server is not answering (037).
                    .foregroundStyle(model.hostUnreachable(summary.host) ? .secondary : .primary)
                    .contextMenu { ProjectMenu(summary: summary) }
                    // A file dropped here goes into the project's drop box (#231).
                    .dropsIntoDropbox(of: key)
                    // No tag: the row is not something to open (#375). The project's
                    // `.project` item is its New session row.
            }
        }
    }

    /// A server's project says which server (Alex, #145): no heading for each host, so
    /// the host goes in the name. This Mac's go by name alone.
    private var label: String {
        SidebarOrder.label(summary) { model.hosts.label($0) }
    }

    /// While searching: the workflows and archived sessions that matched, after the live
    /// ones, the archived capped until Show all (#176).
    @ViewBuilder
    private func searchMatches(_ fold: SidebarProjectFold) -> some View {
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
    }
}

/// The first row of the sidebar (#495): a new session, in the project the last one was
/// started in, as ⌘N starts one. The page it opens can switch project. It carries that
/// project's own item, which the sidebar lights while its new session is open.
private struct NewSessionTopRow: View {
    @Environment(AppModel.self) private var model
    @Environment(WindowRequests.self) private var requests

    var body: some View {
        let project = model.newSessionProject
        HStack(spacing: 6) {
            Image(systemName: "square.and.pencil")
                .foregroundStyle(Paper.accent)
                .frame(width: 16)
                .accessibilityHidden(true)
            Text("New Session")
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .appText(.supporting)
        .contentShape(Rectangle())
        // Every click, not only a changed selection: the row may already be the lit one
        // while the prompt has lost the keyboard. See `ProjectRow` before #375.
        .simultaneousGesture(TapGesture().onEnded {
            guard let project else { return }
            model.showProject(project)
            requests.focusPrompt()
        })
        .disabled(project == nil)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("New Session")
        .modifier(NewSessionTag(project: project))
    }
}

/// The row's item while there is a project to start in; none while there is not.
private struct NewSessionTag: ViewModifier {
    let project: ProjectKey?

    func body(content: Content) -> some View {
        if let project {
            content.sidebarInk(.project(project)).tag(SidebarItem.project(project))
        } else {
            content
        }
    }
}

/// One session under its project: the sessions column's row, tagged into the sidebar's
/// one selection.
struct SessionSidebarRow: View {
    @Environment(AppModel.self) private var model
    let agent: Agent
    /// Its project's name, after the title, under a smart row (#495).
    var place: String? = nil

    var body: some View {
        AgentRow(agent: agent, isCompact: true, place: place)
            .padding(.vertical, 2)
            .listRowInsets(.vertical, 2)
            .sidebarInk(.session(agent.id))
            .tag(SidebarItem.session(agent.id))
            // Into its project's drop box, never its worktree (#231).
            .dropsIntoDropbox(of: ProjectKey(host: agent.host, folder: agent.projectFolder))
            // Pin or Unpin (#180), from the other edge.
            .swipeActions(edge: .leading) {
                if agent.state != .archived {
                    let pinned = model.isPinned(agent)
                    SwipeAction(pinned ? "Unpin" : "Pin", systemImage: pinned ? "pin.slash" : "pin") {
                        await model.setPinned(agent, !pinned)
                    }
                    .tint(Paper.accent)
                }
            }
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
}

/// A project's or a session's row taking files dragged from Finder (#231): each file
/// goes into the top of the project's drop box, where a workflow can pick it up; the
/// project's *Put Files in Drop Box…* names a folder inside it. A folder dropped here is
/// added as a project, as one dropped on the list around the rows is.
private struct DropboxDrop: ViewModifier {
    @Environment(AppModel.self) private var model
    let project: ProjectKey
    @State private var isTargeted = false

    func body(content: Content) -> some View {
        content
            .background(isTargeted ? Paper.accent.opacity(0.18) : .clear, in: .rect(cornerRadius: 5))
            .dropDestination(for: URL.self) { urls, _ in
                let isFolder: (URL) -> Bool = {
                    $0.hasDirectoryPath || (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                }
                let folders = urls.filter(isFolder)
                let files = urls.filter { !isFolder($0) }
                guard !urls.isEmpty else { return false }
                Task {
                    for folder in folders { await model.addProject(folder) }
                    if !files.isEmpty { await model.putInDropbox(files, project: project) }
                }
                return true
            } isTargeted: { isTargeted = $0 }
    }
}

private extension View {
    func dropsIntoDropbox(of project: ProjectKey) -> some View {
        modifier(DropboxDrop(project: project))
    }
}

/// A project's context menu, and the project menu's items.
private struct ProjectMenu: View {
    @Environment(AppModel.self) private var model
    @Environment(WindowRequests.self) private var requests
    let summary: DaemonAPI.ProjectSummary

    var body: some View {
        Button("New Session") {
            model.showProject(summary.key)
            requests.focusPrompt()
        }
        .disabled(model.hostUnreachable(summary.host))
        Button("Project Settings…") {
            model.showProject(summary.key)
            requests.projectSettings = .general
        }
        // A drag onto the row goes to the drop box's top; this names a folder in it.
        Button("Put Files in Drop Box…") { requests.dropboxProject = summary.key }
            .disabled(model.hostUnreachable(summary.host) || !summary.exists)
        Divider()
        // To the top of the sidebar, above the projects that are not.
        Button(summary.project.isPinned ? "Unpin" : "Pin") {
            Task { await model.setPinned(!summary.project.isPinned, for: summary.key) }
        }
        .disabled(model.hostUnreachable(summary.host))
        Button("Archive") {
            Task { await model.archiveProject(summary.key) }
        }
        .disabled(model.hostUnreachable(summary.host))
        // Only this Mac's folder is somewhere Finder can show (058, FR-019).
        if model.isOnThisMac(summary.host) {
            Button("Show in Finder") {
                model.reveal(summary.folder, on: summary.host)
            }
            .disabled(!summary.exists)
        }
    }
}

/// The sidebar's foot: the connection, then why the Mac is awake. Nothing at all when
/// both have nothing to say.
private struct SidebarFoot: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !model.controlPlaneAway, model.macHostNotice != nil || (!model.isConnected && model.hasMacHost) {
                // Said rather than left to look like a quiet afternoon: what is listed
                // may have moved on. A host that never enrolled, or is not running, says
                // so (#303). The control plane being away is the strip's sentence, and
                // the projects stay listed under it (058, frame H).
                Group {
                    if model.macHostNotice != nil {
                        MacHostDownNotice()
                    } else {
                        Text("Connecting…")
                            .appText(.fine)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 6)
                    }
                }
                .padding(.horizontal, 14)
            }
            ForEach(model.hosts.servers.filter { model.hostUnreachable($0) }, id: \.self) { host in
                // A server gone quiet greys its projects; this says why, once, where the
                // Mac's own state is said.
                Label("\(model.hosts.label(host)) is offline", systemImage: "bolt.horizontal.circle")
                    .appText(.fine)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 4)
                    .accessibilityElement(children: .combine)
            }
            // A file this Mac keeps that could not be read (#205): why paired devices or
            // projects may have gone from view, and that what they held is kept.
            ForEach(model.storeNotes, id: \.self) { note in
                Label(note, systemImage: "exclamationmark.triangle")
                    .appText(.fine)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 4)
                    .accessibilityElement(children: .combine)
            }
            WakefulnessRow()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Paper.sidebar)
    }
}

/// The first thing anybody sees. It says what to do, not that something is wrong.
private struct EmptyProjectList: View {
    @Environment(AppModel.self) private var model
    @Binding var isChoosingFolder: Bool
    @Binding var isCloning: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.macRuntimesAvailable.isEmpty {
                Text("No agent runtime found")
                    .appText(.reading).fontWeight(.semibold)
                Text("Agents runs the coding CLIs on this Mac. Install one here, or from its own page.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(model.runtimes) { status in
                    RuntimeMissingLine(status: status)
                }
            } else {
                Text("No projects yet")
                    .appText(.reading).fontWeight(.semibold)
                Text("A project is a folder you work in. Pick one and say what you want done.")
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Add Project…") { isChoosingFolder = true }
                        .buttonStyle(.paperProminent)
                    Button("Clone Project from Git URL…") { isCloning = true }
                        .buttonStyle(.paper)
                }
            }
        }
        .padding(.vertical, 8)
    }
}

/// Why a runtime this app knows about is not usable, and the way to get it (048): the
/// same row as the start-up sheet's.
private struct RuntimeMissingLine: View {
    let status: RuntimeStatus

    var body: some View {
        RuntimeInstallRow(status: status)
    }
}

/// The way into Spending, and what today has cost on the way past.
///
/// The bottom of this column has always been where the money is, so Spending is here
/// rather than in a row above the projects: a line that already shows a figure is the
/// one place somebody looks for more of it. It is a row of the sidebar and not a
/// button to a window of its own — the bill is something you read beside the work and
/// come back out of, like a project.
///
/// Today rather than "this sitting": today's figure is what the daily limit is
/// measured against, it survives closing the window, and it needs no baseline
/// subtracted from it. The meter in a chat says what one agent cost. Per currency,
/// like every other total here: two currencies read as two numbers rather than one
/// nobody could check.
///
/// Drawn whether or not anything has been spent, unlike the line it replaces. A row
/// that hides itself until the first pound is spent is a row nobody can use to find
/// out that nothing has been — and while the cost was going unbanked, it was the only
/// way in and it was never there.
private struct SpendingRow: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: SidebarItem?

    private var isPicked: Bool { selection == .spending }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Cost").foregroundStyle(.primary)
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                if let today {
                    Text(today).monospacedDigit()
                }
                // Nothing when there is no limit: headroom that does not exist is
                // not a thing to draw an empty gauge for.
                if let state = model.costState, let left = state.dayHeadroom,
                   let daily = state.limits.daily {
                    Text("\(left.money(in: daily.currency)) left")
                }
            }
            .appText(.fine)
            .foregroundStyle(foreground)
        }
        .help(today == nil
              ? "What all of the work has cost"
              : "What every agent has cost today. Opens Cost.")
    }

    /// This Mac's day and every server's, as one figure: what the work cost is the
    /// question, not where it ran. Each daemon still keeps its own day and its own limit
    /// (037); only the reading is added up.
    private var today: String? {
        guard let state = model.costState else { return nil }
        return Cost.total(of: state.today.merging(model.serversToday, uniquingKeysWith: +))
    }

    /// Colour means the limit is about to bite. The app's existing threshold for a
    /// nearly full context, not a second number to learn. A picked row is drawn on the
    /// selection colour, where red on blue is neither legible nor a warning anybody
    /// reads.
    private var foreground: AnyShapeStyle {
        if isPicked { return AnyShapeStyle(.primary) }
        return (model.costState?.dayIsCloseToFull == true ? StateTint.failure : .none)
            .style(or: .secondary)
    }
}

/// Why the Mac is not asleep, when it is not asleep because of us.
///
/// A machine behaving unusually with no visible cause is how an app loses the benefit of
/// the doubt. This is the whole of 024's answer to that: it connects two facts the person
/// can already see separately — an agent is working, and the Mac has not slept.
///
/// **Absent, not empty, when there is nothing to say.** Nil `wakeState` (a daemon too old
/// to know, or one not yet heard from) and a state with neither flag set are drawn the
/// same way: no row at all. A row that says "not keeping your Mac awake" is a row that
/// trains people to stop reading the footer.
private struct WakefulnessRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let state = model.wakeState, state.hasSomethingToSay {
            // Stacked rather than headline-left/detail-right, which is the shape
            // `SpendingRow` uses below. That shape wrapped: this column is about
            // 226pt wide and "Keeping this Mac awake" plus a trailing count is a few
            // points over, so it broke mid-phrase and read as a mistake. Two lines on
            // purpose, left-aligned, survives a narrower sidebar too.
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: state.isHolding ? "sun.max" : "battery.25")
                    .foregroundStyle(state.isHolding ? AnyShapeStyle(.secondary)
                                                     : StateTint.attention.style(or: .secondary))
                VStack(alignment: .leading, spacing: 1) {
                    Text(headline(state)).fixedSize(horizontal: false, vertical: true)
                    if let detail = detail(state) {
                        Text(detail).monospacedDigit().foregroundStyle(.tertiary)
                    }
                }
                Spacer(minLength: 0)
            }
            .appText(.fine)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Paper.sidebar)
            .help(help(state))
            .accessibilityElement(children: .combine)
            .accessibilityLabel(help(state))
        }
    }

    /// The two situations must not read alike. "Nothing is running" and "running, but
    /// your battery is low" are different news, and a person who cannot tell them apart
    /// learns nothing from either (FR-016).
    private func headline(_ state: DaemonAPI.WakeState) -> String {
        state.isHolding ? "Keeping this Mac awake" : "Letting this Mac sleep"
    }

    /// No count of working agents. The daemon tells windows only when the hold is
    /// taken or let go, not as agents join a hold already in place, so a count here
    /// froze at whatever it was when the hold began — "1 working" while three ran.
    /// The sidebar already shows which agents are working; this row says only why
    /// the Mac is awake.
    private func detail(_ state: DaemonAPI.WakeState) -> String? {
        if state.isHolding, let until = state.graceUntil {
            return WakeWords.untilLine(until)
        }
        return state.isHolding ? nil : state.batteryPercent.map { "\($0)%" }
    }

    private func help(_ state: DaemonAPI.WakeState) -> String {
        if state.isHolding, let until = state.graceUntil {
            return WakeWords.graceHelp(until)
        }
        if state.isHolding {
            return "This Mac will not sleep while an agent is mid-turn."
        }
        let charge = state.batteryPercent.map { " The battery is at \($0)%." } ?? ""
        return "Work is still in flight, but the battery is low, so this Mac is being "
             + "allowed to sleep." + charge
    }
}

/// Projects a server no longer has (043, contracts/ui.md § 6): shown as gone, never as
/// offline, until the person removes them.
private struct GoneProjectRows: View {
    @Environment(AppModel.self) private var model
    let host: HostID

    var body: some View {
        ForEach(model.hosts.goneProjects[host] ?? [], id: \.self) { path in
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text((path as NSString).lastPathComponent).foregroundStyle(.secondary)
                    Text("Gone from \(model.hosts.label(host))").appText(.fine).foregroundStyle(.tertiary)
                }
                Spacer()
                Button("Remove") { model.hosts.forgetGoneProject(host, path: path) }
                    .controlSize(.small)
            }
            .appText(.supporting)
            .help(path)
        }
    }
}

/// In the projects list while this Mac's host is quiet (#83, #303): said whole, in a
/// person's words, naming why and the step that fixes it. The projects under it stay
/// listed, greyed: what they show is what the window last heard.
private struct MacHostDownNotice: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let notice = model.macHostNotice ?? .notAnswering
        VStack(alignment: .leading, spacing: 6) {
            // A sidebar row is one line unless told otherwise, and cut off this said
            // nothing (the walk on 2026-10-01 saw "Not connected to the daemon. Tr…").
            Label(notice.title, systemImage: "exclamationmark.triangle")
                .appText(.supporting).fontWeight(.semibold)
                .tinted(.attention)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            Text(notice.detail)
                .appText(.fine).foregroundStyle(.secondary)
                .lineLimit(8)
                .fixedSize(horizontal: false, vertical: true)
            Button("Try Again") { model.tryMacHostAgain() }
                .controlSize(.small)
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
    }
}

/// What the sidebar has picked, and whether it has the keyboard, for `SidebarInk`.
struct SidebarPicks {
    var items: Set<SidebarItem> = []
    var listFocused = false
}

extension EnvironmentValues {
    @Entry var sidebarPicks = SidebarPicks()
}

/// A picked row in the focused sidebar of the key window is filled with the accent, and
/// macOS draws its text white: 2.5:1 on the dark violet. The ground is 6.6:1 there, and
/// 6.3:1 on the light one, as on the prominent button (#156). The list tells no row it
/// is drawn so (`backgroundProminence` stays standard in a macOS sidebar), so the row
/// works it out from what is picked, the list's focus and the window's.
private struct SidebarInk: ViewModifier {
    let item: SidebarItem
    @Environment(\.sidebarPicks) private var picks
    @Environment(\.controlActiveState) private var windowState

    func body(content: Content) -> some View {
        if picks.listFocused, windowState == .key, picks.items.contains(item) {
            content.foregroundStyle(Paper.ground)
        } else {
            content
        }
    }
}

extension View {
    /// On a sidebar row, outside its own foreground, with the tag the row carries.
    func sidebarInk(_ item: SidebarItem) -> some View {
        modifier(SidebarInk(item: item))
    }
}
