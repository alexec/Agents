import AgentsKitCore
import SwiftUI

/// The window's source list (#866), its first column: New Session, Activity, the smart
/// groups and the projects, and at its foot what this Mac and its hosts are doing. What
/// is picked here, the list column beside it lists — Mail's mailboxes.
///
/// It was the one sidebar of #145, every project folded open on its sessions. Now that
/// it holds only sources it is narrow, and stays open: Activity, the awake line and the
/// hosts' state stay in sight, which is what #145 joined the columns for.
struct ProjectListView: View {
    @Environment(AppModel.self) private var model
    @Environment(WindowRequests.self) private var requests
    let column: ListColumn
    @Binding var selection: SidebarItem?

    @AppStorage("showsArchivedProjects") private var showsArchived = false
    /// Activity, open until folded, and kept so.
    @AppStorage("showsActivity") private var showsActivity = true
    /// Bumped to make the list again when its outline has drifted from the model (#237).
    @State private var outlineRebuilds = 0
    /// The archived project Delete… is asking about, and why one could not go (#677).
    @State private var deletingProject: DaemonAPI.ProjectSummary?
    @State private var cannotDeleteProject: String?
    /// Whether the list itself has the keyboard: only then is a picked row filled with
    /// the accent rather than a grey wash (see `SidebarInk`).
    @FocusState private var listFocused: Bool
    @State private var isChoosingFolder = false
    @State private var isCloning = false
    /// Which machine the New project menu was pointed at (037).
    @State private var targetHost: HostID = .mac
    @State private var isChoosingServerFolder = false
    /// File ▸ Add Server…'s own view of the control plane, while its sheet is open (#503).
    @State private var addingServer: ControlSettingsModel?

    /// This Mac's projects, then each server's: no headings for hosts (Alex, #145), the
    /// host is in a server project's own name.
    private var orderedProjects: [DaemonAPI.ProjectSummary] {
        SidebarOrder.projects(model.liveProjects, servers: model.hosts.servers)
    }

    /// No runtime can be started on: Runtimes' icon says so in red (#587).
    private var runtimesFailing: Bool {
        RuntimeTally(model.runtimes, allowances: model.runtimeAllowances)?.noneWorking == true
    }

    /// A hosted server stopped while in use: MCP Servers' icon says so in red (#587, #589).
    private var mcpServersStopped: Bool {
        MCPHealthWords.tally(model.work.mcpHealthSnapshot()?.personal ?? [])?.failing == true
    }

    /// What the list has picked. Set by a click, it opens what the source opens; set by
    /// the window following what is open (`ListColumn.follow`), it only lights the row.
    private var picked: Binding<ListSource?> {
        Binding(get: { column.source }, set: { source in
            // macOS clears a list's selection by itself while rows come and go.
            guard let source else { return }
            pick(source)
        })
    }

    var body: some View {
        let projectKeys = orderedProjects.map(\.key)
        List(selection: picked) {
            Section {
                // One way to start a session (#495), in the project last started in; the
                // page it opens can switch project.
                NewSessionTopRow(column: column)
            }

            // The pages about all the work (#495). Each fills the list column and the
            // session's (#866): there is no list beside a page.
            Section(isExpanded: $showsActivity) {
                EventsRow().activityIcon("list.bullet.rectangle")
                    .appText(.supporting).sourceInk(.activity(.events)).tag(ListSource.activity(.events))
                ResourcesRow().activityIcon("square.stack.3d.up")
                    .appText(.supporting).sourceInk(.activity(.resources)).tag(ListSource.activity(.resources))
                RuntimesRow().activityIcon("cpu", warns: runtimesFailing)
                    .appText(.supporting).sourceInk(.activity(.runtimes)).tag(ListSource.activity(.runtimes))
                MCPServersRow().activityIcon("server.rack", warns: mcpServersStopped)
                    .appText(.supporting).sourceInk(.activity(.mcpServers)).tag(ListSource.activity(.mcpServers))
                WorktreesRow().activityIcon("arrow.triangle.branch")
                    .appText(.supporting).sourceInk(.activity(.worktrees)).tag(ListSource.activity(.worktrees))
                SpendingRow(selection: $selection).activityIcon("dollarsign.circle",
                                                                warns: model.costState?.dayIsCloseToFull == true)
                    .appText(.supporting).sourceInk(.activity(.spending)).tag(ListSource.activity(.spending))
                TimeRow().activityIcon("clock")
                    .appText(.supporting).sourceInk(.activity(.time)).tag(ListSource.activity(.time))
            } header: {
                Text("Activity").appText(.supporting)
            }

            // Pinned, Needs You, Working, Unread (#495): a row each, listed in the list
            // column. Empty, a group is not drawn (#507), unless it is the one picked.
            Section {
                ForEach(SidebarSmartRow.allCases, id: \.self) { row in
                    let count = row.count(in: model.work, projects: projectKeys, listedOnce: false)
                    if count > 0 || column.source == .smart(row) {
                        SmartSourceRow(row: row, count: count)
                            .sourceInk(.smart(row))
                            .tag(ListSource.smart(row))
                    }
                }
            }

            // Every project, a row each (#866): its sessions are the list column's.
            Section {
                ForEach(orderedProjects, id: \.key) { summary in
                    ProjectRow(summary: summary, label: label(summary), asSource: true)
                        .appText(.supporting)
                        // Last known, not current: the server is not answering (037).
                        .foregroundStyle(model.hostUnreachable(summary.host) ? .secondary : .primary)
                        .contextMenu { ProjectMenu(summary: summary) }
                        // A file dropped here goes into the project's drop box (#231).
                        .dropsIntoDropbox(of: summary.key)
                        .sourceInk(.project(summary.key))
                        .tag(ListSource.project(summary.key))
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
            } header: {
                Text("Projects").appText(.supporting)
            }

            if !model.archivedProjects.isEmpty {
                Section(isExpanded: $showsArchived) {
                    // None while folded, as under a folded project (#356).
                    ForEach(showsArchived ? model.archivedProjects : [], id: \.key) { summary in
                        ArchivedProjectRow(summary: summary, label: label(summary),
                                           bringBack: { await model.unarchiveProject(summary.key) },
                                           delete: { deletingProject = summary })
                            .appText(.supporting)
                    }
                } header: {
                    Text("Archived projects").appText(.supporting)
                }
            }
        }
        // AppKit swallows the exception a drifted outline throws, and the rows stay wrong
        // until the list is made again (#237).
        .id(outlineRebuilds)
        .onReceive(NotificationCenter.default.publisher(for: .outlineListDrifted)) { _ in
            outlineRebuilds &+= 1
        }
        .listStyle(.sidebar)
        .focused($listFocused)
        .environment(\.sidebarPicks, SidebarPicks(source: column.source, listFocused: listFocused))
        // Rows as tall as their lines (#104).
        .environment(\.sidebarRowSize, .small)
        .scrollContentBackground(.hidden)
        .background(Paper.sidebar)
        .confirmationDialog(DeletionWords.projectConfirmTitle(deletingProject.map(label) ?? ""),
                            isPresented: Binding(get: { deletingProject != nil },
                                                 set: { if !$0 { deletingProject = nil } }),
                            presenting: deletingProject) { summary in
            Button("Delete", role: .destructive) {
                Task {
                    if case .failure(let refusal) = await model.deleteProject(summary.key) {
                        cannotDeleteProject = refusal.message
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text(DeletionWords.projectConfirmMessage)
        }
        .alert("This project cannot be deleted yet",
               isPresented: Binding(get: { cannotDeleteProject != nil }, set: { if !$0 { cannotDeleteProject = nil } })) {
            Button("OK") {}
        } message: {
            Text(cannotDeleteProject ?? "")
        }
        // What this Mac and its hosts are doing, pinned at the foot: status lines rather
        // than somewhere to go, so not rows of the list. Each is absent when there is
        // nothing to say, which is most of the time (024 FR-015).
        .safeAreaInset(edge: .bottom, spacing: 0) {
            SidebarFoot()
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
        // The sheet Settings ▸ Control plane ▸ Add a Server… shows (#503).
        .sheet(isPresented: Binding(get: { addingServer != nil }, set: { if !$0 { addingServer = nil } })) {
            if let control = addingServer {
                ControlAddServerSheet(control: control)
                    .task { await control.start() }
                    .onDisappear { control.stop() }
                    .paperSheet()
            }
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
                addingServer = ControlConfig.endpoint.flatMap { ControlSettingsModel(endpoint: $0) }
            }
        }
    }

    /// A source picked by a click: an Activity page opens, a project opens its new
    /// session (#866, Alex), and a smart group leaves the session open beside it.
    private func pick(_ source: ListSource) {
        column.source = source
        switch source {
        case .activity(let item):
            selection = item
        case .project(let key):
            selection = .project(key)
        case .smart:
            model.leaveActivity()
        }
    }

    /// An archived project's name as its live row had it: `server:Project` on a server (#677).
    private func label(_ summary: DaemonAPI.ProjectSummary) -> String {
        SidebarOrder.label(summary) { model.hosts.label($0) }
    }
}

/// The first row of the source list (#495): a new session, in the project the last one
/// was started in, as ⌘N starts one. The page it opens can switch project. The list
/// column lists that project (#866).
private struct NewSessionTopRow: View {
    @Environment(AppModel.self) private var model
    @Environment(WindowRequests.self) private var requests
    let column: ListColumn

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
            column.source = .project(project)
            model.showProject(project)
            requests.focusPrompt()
        })
        .disabled(project == nil)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("New Session")
        .accessibilityAddTraits(.isButton)
    }
}

/// One session under its project: the sessions column's row, tagged into the sidebar's
/// one selection.
struct SessionSidebarRow: View {
    @Environment(AppModel.self) private var model
    let agent: Agent
    /// Its project's name, after the title, under a smart row (#495).
    var place: String? = nil
    /// Where it sits in its list's tree (#835), and the folds that keep a parent's.
    var tree: SidebarTree.Row? = nil
    var folds: SidebarFolds? = nil

    var body: some View {
        AgentRow(agent: agent, isCompact: true, place: place, tree: tree) {
            guard let tree else { return }
            folds?.set(session: agent.id, open: !tree.isUnfolded)
        }
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

extension View {
    func dropsIntoDropbox(of project: ProjectKey) -> some View {
        modifier(DropboxDrop(project: project))
    }
}

/// A project's context menu, and the project menu's items.
struct ProjectMenu: View {
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

    var body: some View {
        // The title alone (#587): the day's figure and what is left are the tooltip's,
        // and near the limit the row's icon turns red (`activityIcon(_:warns:)`).
        HStack(alignment: .firstTextBaseline) {
            Text("Cost").foregroundStyle(.primary)
            Spacer()
        }
        .help(help)
        .accessibilityValue(figures ?? "")
    }

    /// Today's cost, and what is left of a daily limit where there is one.
    private var figures: String? {
        guard let today else { return nil }
        if let state = model.costState, let left = state.dayHeadroom, let daily = state.limits.daily {
            return "\(today) today, \(left.money(in: daily.currency)) left"
        }
        return "\(today) today"
    }

    private var help: String {
        figures.map { "\($0). What every agent has cost. Opens Cost." } ?? "What all of the work has cost"
    }

    /// This Mac's day and every server's, as one figure: what the work cost is the
    /// question, not where it ran. Each daemon still keeps its own day and its own limit
    /// (037); only the reading is added up.
    private var today: String? {
        guard let state = model.costState else { return nil }
        return Cost.total(of: state.today.merging(model.serversToday, uniquingKeysWith: +))
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

/// What a list column has picked, and whether it has the keyboard, for `SidebarInk`:
/// the list column's items, or the source list's source (#866).
struct SidebarPicks {
    var items: Set<SidebarItem> = []
    var source: ListSource?
    var listFocused = false
}

extension EnvironmentValues {
    @Entry var sidebarPicks = SidebarPicks()
}

/// A picked row in the focused sidebar of the key window is filled with the accent, and
/// macOS draws its text white: 2.2:1 on the dark cobalt. The ground is 7.7:1 there, and
/// 5.6:1 on the light one, as on the prominent button (#156). The list tells no row it
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

/// `SidebarInk` for a row of the source list (#866).
private struct SourceInk: ViewModifier {
    let source: ListSource
    @Environment(\.sidebarPicks) private var picks
    @Environment(\.controlActiveState) private var windowState

    func body(content: Content) -> some View {
        if picks.listFocused, windowState == .key, picks.source == source {
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

    /// On a source list row, with the tag the row carries (#866).
    func sourceInk(_ source: ListSource) -> some View {
        modifier(SourceInk(source: source))
    }
}
