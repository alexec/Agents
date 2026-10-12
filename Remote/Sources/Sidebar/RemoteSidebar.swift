import AgentsKitCore
import SwiftUI
import UIKit

/// The Mac's one sidebar, on an iPad or an iPhone (#226, #498): New Session at the top,
/// then Activity, then what wants the person across every project — Pinned, Needs You,
/// Working, Unread — then a group per project, its sessions newest first with their state
/// the row's mark, its workflows, and one Archived row opening a page; then the archived
/// projects, folded, each with Bring Back (#343). Never more than two levels deep (#495).
///
/// The rules are the Mac's own, from `SidebarProjectFold`, `SidebarSmartRow`,
/// `SidebarOrder` and `SidebarFolds` in AgentsKitCore: the same groups, order, pins and
/// folds, kept the same way. The views are this device's: on an iPad the list sits beside
/// what it picked; on an iPhone it is the screen the app opens on and a pick is pushed
/// over it. Swipe actions and a long press stand in for the Mac's context menus.
struct RemoteSidebar: View {
    @Environment(RemoteModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var folds = SidebarFolds(scope: "")
    @State private var query = ""
    /// The field's words once typing pauses, so a keystroke costs the field and not a
    /// pass over every project (#176).
    @State private var searched = ""
    /// Projects whose every archived match is on show, past the first few (#176).
    @State private var showingAllMatches: Set<ProjectKey> = []
    /// Archived projects, open or closed, kept as the window keeps it (#343).
    @AppStorage("showsArchivedProjects") private var showsArchived = false
    /// Activity, open until folded, and kept so, as the window keeps it.
    @AppStorage("showsActivity") private var showsActivity = true
    /// Add Project… or Clone Project from Git URL…, on a host, from the + (#537).
    @State private var adding: NewProject?
    /// The smart groups turned off in Settings ▸ Sidebar (#846).
    @AppStorage(SidebarSmartRow.offDefaultsKey) private var smartOff = ""
    /// Settings (#846), opened from the sidebar's foot.
    @State private var showsSettings = false

    private var selection: Binding<SidebarItem?> {
        Binding(get: { model.sidebarItem },
                set: { item in
                    // A list clears its selection by itself while rows come and go, and
                    // that must not empty the detail; going back on a phone clears it
                    // through the split view's column instead.
                    if let item { model.sidebarItem = item }
                })
    }

    /// No runtime can be started on: Runtimes' icon says so in red (#587).
    private var runtimesFailing: Bool {
        RuntimeTally(model.runtimes, allowances: model.runtimeAllowances)?.noneWorking == true
    }

    /// One of the person's servers does not answer: MCP Servers' icon says so in red (#587, #753).
    private var mcpServersStopped: Bool {
        MCPHealthWords.tally(model.work.mcpHealthSnapshot()?.personal ?? [])?.failing == true
    }

    private var servers: [HostID] {
        model.hostSections.map(\.id).filter { $0 != .mac }
    }

    var body: some View {
        let projects = SidebarOrder.projects(model.projects, servers: servers)
        List(selection: selection) {
            if !model.projects.isEmpty {
                // One way to start a session (#495), in the project last started in.
                // A project's long press starts one in it.
                Section {
                    NewSessionTopRow()
                }

                // Pages about all the work rather than one project, above the smart
                // groups, as the window has them (#495). Plain titles beside their icons
                // in the accent (#155). It folds, as a project does.
                Section(isExpanded: $showsActivity) {
                    EventsRow().activityIcon("list.bullet.rectangle").appText(.supporting).tag(SidebarItem.events)
                    ResourcesRow().activityIcon("square.stack.3d.up").appText(.supporting).tag(SidebarItem.resources)
                    RuntimesRow().activityIcon("cpu", warns: runtimesFailing)
                        .appText(.supporting).tag(SidebarItem.runtimes)
                    MCPServersRow().activityIcon("server.rack", warns: mcpServersStopped)
                        .appText(.supporting).tag(SidebarItem.mcpServers)
                    WorktreesRow().activityIcon("arrow.triangle.branch")
                        .appText(.supporting).tag(SidebarItem.worktrees)
                    SpendingRow().activityIcon("dollarsign.circle", warns: model.costState?.dayIsCloseToFull == true)
                        .appText(.supporting).tag(SidebarItem.spending)
                    TimeRow().activityIcon("clock").appText(.supporting).tag(SidebarItem.time)
                } header: {
                    Text("Activity")
                }

                // Pinned, Needs You, Working, Unread: a group each across every project
                // and host (#495), headed and folding as a project's is.
                // A group turned off in Settings ▸ Sidebar is not drawn (#846).
                let on = SidebarSmartRow.on(off: smartOff)
                ForEach(SidebarSmartRow.allCases.filter(on.contains), id: \.self) { row in
                    RemoteSmartFold(row: row, projects: projects, folds: folds, query: searched)
                }
            }

            // One group per project (#495), its name the group's heading, its sessions
            // the rows: Mail's accounts rather than a Projects heading with folds under it.
            ForEach(projects, id: \.key) { summary in
                RemoteProjectFold(summary: summary, folds: folds, query: searched,
                                  label: SidebarOrder.label(summary) { model.hostLabel($0) },
                                  showsAllMatches: showingAllMatches.contains(summary.key),
                                  showAllMatches: { showingAllMatches.insert(summary.key) })
            }
            // A host had more matches than its page: the next page, on asking (#176, #533).
            if !searched.isEmpty, model.searchHasMore {
                Button("More matches…") { Task { await model.searchMore() } }
                    .appText(.fine)
                    .foregroundStyle(.secondary)
            }

            // Projects put away, closed until opened, as the window's (#343).
            if !model.shelvedProjects.isEmpty, searched.isEmpty {
                Section(isExpanded: $showsArchived) {
                    ForEach(model.shelvedProjects, id: \.key) { summary in
                        ArchivedProjectRow(summary: summary,
                                           label: SidebarOrder.label(summary) { model.hostLabel($0) },
                                           isDisabled: model.isStale || model.hostIsOffline(summary.host),
                                           bringBack: { await model.unarchiveProject(summary) },
                                           delete: { model.askingToDeleteProject = summary })
                        .appText(.supporting)
                    }
                } header: {
                    Text("Archived projects")
                }
            }

            // A server gone quiet greys its projects; this says why, once, as the window's
            // sidebar foot does (#534).
            let offline = servers.filter { model.hostIsOffline($0) }
            if !offline.isEmpty {
                Section {
                    ForEach(offline, id: \.self) { host in
                        Label("\(model.hostLabel(host)) is offline", systemImage: "bolt.horizontal.circle")
                            .appText(.fine)
                            .foregroundStyle(.secondary)
                            .accessibilityElement(children: .combine)
                    }
                }
            }

            // A file the Mac keeps that could not be read (#205, #223), as the window's
            // sidebar foot: why paired devices or projects may have gone from view.
            if !model.work.storeNotes.isEmpty {
                Section {
                    ForEach(model.work.storeNotes, id: \.self) { note in
                        Label(note, systemImage: "exclamationmark.triangle")
                            .appText(.fine)
                            .foregroundStyle(.secondary)
                            .accessibilityElement(children: .combine)
                    }
                }
            }

            // This device, at the very foot, as the page's sidebar ends with its browser
            // (#344): its Settings (#846), and the way to forget it from here.
            Section {
                Button("Settings…") { showsSettings = true }
                    .appText(.supporting)
                if !model.needsPairing {
                    ForgetThisDeviceRow()
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(Paper.sidebar)
        .toolbarBackground(Paper.sidebar, for: .navigationBar)
        .navigationTitle("Agents")
        .toolbar {
            if !model.needsPairing {
                ToolbarItem(placement: .primaryAction) { NewProjectMenu(adding: $adding) }
            }
        }
        .sheet(item: $adding) { NewProjectSheet(adding: $0) }
        .sheet(isPresented: $showsSettings) { RemoteSettings() }
        .searchable(text: $query, prompt: "Search")
        .task(id: query) {
            let words = query.trimmingCharacters(in: .whitespacesAndNewlines)
            if !words.isEmpty { try? await Task.sleep(for: .milliseconds(150)) }
            guard !Task.isCancelled else { return }
            if words != searched {
                searched = words
                showingAllMatches = []
            }
            await model.searchSessions(words)
        }
        // Every project's workflows and pinned pages, and the rows' lease marks (#175).
        .shows([.workflows, .pins, .leases])
        .safeAreaInset(edge: .top, spacing: 0) {
            if showsBanner { StaleBanner() }
        }
        .overlay {
            if model.projects.isEmpty { Waiting() }
        }
        // The catch-up leaves archived projects out; they are asked for here (#343), and
        // again once the list is pulled.
        .task(id: model.isConnected) {
            if model.isConnected { await model.loadArchivedProjects() }
        }
        .refreshable {
            await model.catchUp()
            await model.loadArchivedProjects()
        }
    }

    /// Said once on the screen. Beside the detail on a wide iPad, the detail carries the
    /// line; and with no projects yet, the waiting view in the middle says the same thing
    /// in more words.
    private var showsBanner: Bool {
        if sizeClass == .regular { return false }
        if model.projects.isEmpty, model.needsPairing || model.isStale { return false }
        return true
    }
}

/// One of the groups at the top of the sidebar (#495, #498): Pinned, Needs You, Working
/// or Unread, across every project and host, each row naming its project. The window's
/// `SmartFold`. Folded, it reads its count off each project's shelf and lists nothing
/// (#356).
private struct RemoteSmartFold: View {
    @Environment(RemoteModel.self) private var model
    let row: SidebarSmartRow
    /// The projects in the sidebar, in its order.
    let projects: [DaemonAPI.ProjectSummary]
    let folds: SidebarFolds
    /// The search's words, already trimmed; empty when there is no search.
    let query: String
    /// The smart groups turned off in Settings ▸ Sidebar (#846): their sessions are listed
    /// by the next group they fit.
    @AppStorage(SidebarSmartRow.offDefaultsKey) private var smartOff = ""
    private var on: Set<SidebarSmartRow> { SidebarSmartRow.on(off: smartOff) }

    var body: some View {
        let keys = projects.map(\.key)
        // Empty, or with no match for a search, the group is not drawn (#507); Unread
        // with nothing unread still is while it keeps the open session.
        if row.isShown(in: model.work, projects: keys, query: query, on: on) || keptUnread != nil {
            fold(keys)
        }
    }

    private func fold(_ keys: [ProjectKey]) -> some View {
        let isOpen = folds.isOpen(row)
        return Section(isExpanded: Binding(get: { isOpen }, set: { folds.set(row, open: $0) })) {
            if isOpen {
                if row == .pinned {
                    ForEach(keys, id: \.self) { key in pinnedRows(key) }
                } else {
                    // Each under the session that started it when this group lists that too (#835).
                    ForEach(SidebarTree.rows(shown(keys), in: model.work, folds: folds)) { row in
                        SidebarSessionRow(agent: row.agent, place: place(of: row.agent), tree: row, folds: folds)
                    }
                    // Then everything else waiting for an OK (#773), as the window lists it.
                    ForEach(row.approvals(in: model.work, projects: keys, query: query), id: \.approval.id) { item in
                        RemoteApprovalRow(approval: item.approval, project: item.project, place: place(of: item.project))
                    }
                }
            }
        } header: {
            SmartHeading(row: row, count: row.count(in: model.work, projects: keys, on: on))
        }
    }

    /// What the group lists. Unread keeps the session opened from it (`keptInUnread`) in
    /// its place, read now, until another is opened: its count has already dropped.
    private func shown(_ keys: [ProjectKey]) -> [Agent] {
        var agents = row.agents(in: model.work, projects: keys, query: query, on: on)
        if let kept = keptUnread, !agents.contains(where: { $0.id == kept.id }) {
            let at = agents.firstIndex { $0.createdAt < kept.createdAt } ?? agents.endIndex
            agents.insert(kept, at: at)
        }
        return agents
    }

    /// The session Unread keeps, read, while it is the one open; none while searching.
    private var keptUnread: Agent? {
        row == .unread ? SidebarSmartRow.keptInUnread(model.keptInUnread, in: model.work, query: query, on: on) : nil
    }

    /// One project's pinned sessions (#180), then its pinned workflows (#432), each
    /// dragged in the list's edit mode into the order wanted among its own project's and
    /// its own kind, or moved from a row's menu.
    @ViewBuilder
    private func pinnedRows(_ key: ProjectKey) -> some View {
        let searching = !query.isEmpty
        let sessions = SidebarSmartRow.pinned.agents(in: model.work, projects: [key], query: query)
        ForEach(sessions) { agent in
            SidebarSessionRow(agent: agent, place: place(of: agent))
        }
        // The whole order, which a search shows only some of.
        .onMove { from, to in
            guard !searching else { return }
            var ids = sessions.map(\.id)
            ids.move(fromOffsets: from, toOffset: to)
            let shown = Set(ids)
            let rest = model.pinnedSessions(in: key.folder).filter { !shown.contains($0) }
            Task { await model.arrangeSessionPins(ids + rest, in: key.folder) }
        }
        let flows = SidebarSmartRow.pinned.workflows(in: model.work, projects: [key], query: query).map(\.workflow)
        ForEach(flows) { summary in
            SidebarWorkflowRow(summary: summary, project: key)
        }
        .onMove { from, to in
            guard !searching else { return }
            var ids = flows.map(\.workflowID)
            ids.move(fromOffsets: from, toOffset: to)
            let shown = Set(ids)
            let rest = model.pinnedWorkflows(in: key.folder).filter { !shown.contains($0) }
            Task { await model.arrangeWorkflowPins(ids + rest, in: key.folder) }
        }
    }

    /// The project's name as its group in the sidebar says it: `server:Project` on a server.
    private func place(of agent: Agent) -> String? {
        place(of: ProjectKey(host: agent.host, folder: agent.projectFolder))
    }

    private func place(of key: ProjectKey) -> String? {
        guard let summary = projects.first(where: { $0.host == key.host && $0.folder == key.folder }) else { return nil }
        return SidebarOrder.label(summary) { model.hostLabel($0) }
    }
}

/// One thing waiting for an OK under Needs You (#773), the window's `ApprovalListRow`: a
/// tap opens what it is with its buttons, a long press answers at once.
private struct RemoteApprovalRow: View {
    @Environment(RemoteModel.self) private var model
    let approval: Approval
    let project: ProjectKey
    let place: String?
    @State private var open = false

    var body: some View {
        Button { open = true } label: {
            ApprovalRowLabel(approval: approval, place: place)
        }
        .buttonStyle(.plain)
        .contextMenu {
            if approval.actions.contains(.approve) {
                Button(approval.word(for: .approve)) { answerNow(.approve) }
            }
            if approval.actions.contains(.deny) {
                Button(approval.word(for: .deny)) { answerNow(.deny) }
            }
            if approval.actions.contains(.requestChanges) {
                Button(approval.word(for: .requestChanges) + "…") { open = true }
            }
        }
        .sheet(isPresented: $open) {
            ScrollView {
                ApprovalSheet(approval: approval, place: place,
                              read: { await model.readApproval(approval, for: project) },
                              answer: { action, digest, note in
                                  await model.answerApproval(approval, action, digest: digest, note: note, for: project)
                              },
                              isOffline: !model.isConnected)
            }
            .presentationDetents([.medium, .large])
            .paperGround()
        }
    }

    private func answerNow(_ action: Approval.Action) {
        Task { await model.settleApproval(approval, action, for: project) }
    }
}

/// A smart group's heading: its name, and how many, the count in the attention tint for
/// Needs You and absent at none, so the heading stays put. No icon (Alex, #495): the
/// sessions under it carry the marks.
private struct SmartHeading: View {
    let row: SidebarSmartRow
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            Text(row.title).lineLimit(1)
            Spacer(minLength: 4)
            if count > 0 {
                Text("\(count)")
                    .monospacedDigit()
                    .foregroundStyle(row == .needsYou ? StateTint.attention.style(or: .secondary)
                                                      : AnyShapeStyle(.secondary))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(count > 0 ? "\(row.title), \(count)" : "\(row.title), none")
    }
}

/// One project in the sidebar (#495, #498): a group headed by its row, its pinned pages,
/// then its live sessions newest started first, their state the row's mark, then its
/// workflows, then one Archived row opening a page. Its pinned sessions and workflows are
/// in Pinned at the top. The Mac's `ProjectFold`, drawn from the same
/// `SidebarProjectFold`.
private struct RemoteProjectFold: View {
    @Environment(RemoteModel.self) private var model
    let summary: DaemonAPI.ProjectSummary
    let folds: SidebarFolds
    let query: String
    let label: String
    var showsAllMatches = false
    var showAllMatches: () -> Void = {}

    /// Put Files in Drop Box… from the row's menu (#231).
    @State private var fillingDropbox = false
    /// The smart groups turned off in Settings ▸ Sidebar (#846).
    @AppStorage(SidebarSmartRow.offDefaultsKey) private var smartOff = ""

    private var key: ProjectKey { summary.key }

    var body: some View {
        let fold = SidebarProjectFold(key, label: label, in: model.work, query: query, isOpen: folds.isOpen(key),
                                      keptInUnread: model.keptInUnread, on: SidebarSmartRow.on(off: smartOff))
        let isOpen = fold.isUnfolded
        if fold.isShown {
            // A search holds every match open.
            Section(isExpanded: Binding(get: { isOpen },
                                        set: { if !fold.isSearching { folds.set(key, open: $0) } })) {
                // Folded, nothing at all is under the heading (#356): see `isUnfolded`.
                if fold.showsPinnedPages {
                    PinnedPageRows(project: key)
                }
                // Each under the session that started it, folded (#835).
                ForEach(SidebarTree.rows(fold.sessions, in: model.work, folds: folds)) { row in
                    SidebarSessionRow(agent: row.agent, tree: row, folds: folds)
                }
                // Its workflows after the sessions (Alex, #495): rows, not a page, a
                // plain line between the two kinds when there are both (Alex, #631).
                if !fold.sessions.isEmpty && !fold.workflows.isEmpty {
                    Divider()
                        .listRowInsets(.vertical, 2)
                        .accessibilityHidden(true)
                }
                ForEach(fold.workflows) { summary in
                    SidebarWorkflowRow(summary: summary, project: key)
                }
                if fold.isSearching {
                    // What matched in the archive, in the group while searching, so a
                    // match is one tap away.
                    searchMatches(fold)
                } else if isOpen {
                    // Its MCP servers (#753), when its .agents/mcp.json has any: a page, red
                    // when one does not answer.
                    if let tally = MCPHealthWords.tally(model.work.mcpServers(in: key)) {
                        ProjectPageRow(title: "MCP Servers", systemImage: "server.rack", count: nil,
                                       item: .projectMCPServers(key), warns: tally.failing, value: tally.words)
                    }
                    // The archive, one row opening a page (#495): never a fold inside
                    // the group.
                    let archived = fold.archivedCount(summary) + fold.archivedWorkflows.count
                    if archived > 0 {
                        ProjectPageRow(title: "Archived", systemImage: "archivebox",
                                       count: archived, item: .archive(key))
                    }
                }
            } header: {
                ProjectRow(summary: summary, label: label, isFolded: !isOpen, asHeading: true)
                    .foregroundStyle(model.hostIsOffline(summary.host) ? .secondary : .primary)
                    .contextMenu { ProjectMenuItems(summary: summary) { fillingDropbox = true } }
                    .sheet(isPresented: $fillingDropbox) {
                        DropboxSheet(project: key, label: label)
                    }
                    .accessibilityHint(isOpen ? "Folds the project" : "Unfolds the project")
                    // The rest of its live sessions when the first page did not hold them
                    // all. On the heading, which is always there, not on every row.
                    .task(id: isOpen) {
                        if isOpen { await model.fillProject(summary.folder) }
                    }
            }
        }
    }

    /// While searching: the archived workflows and sessions that matched, after the live
    /// ones, the sessions capped until Show all (#176).
    @ViewBuilder
    private func searchMatches(_ fold: SidebarProjectFold) -> some View {
        ForEach(fold.archivedWorkflows) { summary in
            SidebarWorkflowRow(summary: summary, project: key)
        }
        let shown = fold.archivedShown(showingAll: showsAllMatches)
        ForEach(shown) { agent in
            SidebarSessionRow(agent: agent)
        }
        if fold.archived.count > shown.count {
            Button("Show all \(fold.archived.count)", action: showAllMatches)
                .appText(.fine)
                .foregroundStyle(.secondary)
        }
    }
}

/// A row under a project that opens a page about it (#495, #498): its archive. One row
/// where there used to be folds inside the project's fold.
private struct ProjectPageRow: View {
    let title: String
    let systemImage: String
    let count: Int?
    let item: SidebarItem
    /// Red when the page has something wrong to say (#753).
    var warns = false
    /// What VoiceOver says after the title, when it is not the count.
    var value: String?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(warns ? StateTint.failure.style(or: .primary) : AnyShapeStyle(Paper.accent))
                .frame(width: 20)
                .accessibilityHidden(true)
            // Nothing at its end, which is only a session's (#587): the count is
            // VoiceOver's.
            Text(title)
                .lineLimit(1)
            Spacer(minLength: 4)
        }
        .appText(.supporting)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([title, value ?? count.map(String.init)].compactMap { $0 }.joined(separator: ", "))
        .tag(item)
    }
}

/// A page about all the work in the sidebar's Activity group (#495): its icon, in the
/// accent, before the row. Beside the row rather than a `Label`, whose title a sidebar
/// list draws in its own style (#155).
private extension View {
    /// Red when the page has something wrong to say (#587): the row has no figure at its
    /// end to colour, which is only a session's.
    func activityIcon(_ systemImage: String, warns: Bool = false) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(warns ? StateTint.failure.style(or: .primary) : AnyShapeStyle(Paper.accent))
                .frame(width: 20)
                .accessibilityHidden(true)
            self
        }
    }
}

/// Settings (#846): Appearance and Sidebar, both kept on this device only, as the window's
/// Settings panes of the same names and the page's Settings keep theirs. Everything else
/// follows the Mac.
private struct RemoteSettings: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Appearance") {
                    TextSizeRow()
                }
                .paperListRow()
                SidebarSettingsSection()
            }
            .scrollContentBackground(.hidden)
            .background(Paper.ground)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}

/// Text Size (#750): Default, Large or Larger, kept on this device only, as the window's
/// Settings ▸ Appearance and the page's Settings keep theirs.
private struct TextSizeRow: View {
    @AppStorage(TextSize.defaultsKey) private var textSize = TextSize.standard

    var body: some View {
        Picker("Text Size", selection: $textSize) {
            ForEach(TextSize.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.menu)
        .appText(.supporting)
    }
}

/// Forget This iPhone… (#344, 071 FR-015): the control plane forgets this device, and only
/// it, asked first as the window asks before forgetting a client. Gone, the app asks for a
/// code again.
private struct ForgetThisDeviceRow: View {
    @Environment(RemoteModel.self) private var model
    @State private var confirming = false
    @State private var problem: String?

    private var device: String { UIDevice.current.model }

    var body: some View {
        Button("Forget This \(device)…") { confirming = true }
            .appText(.supporting)
            .confirmationDialog("Forget this \(device)?", isPresented: $confirming, titleVisibility: .visible) {
                Button("Forget", role: .destructive) { Task { problem = await model.forgetThisDevice() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This \(device) is cut off at once, at home and away, until it is paired again.")
            }
        if let problem {
            Text(problem).appText(.fine).tinted(.failure)
        }
    }
}

/// A project's long-press menu: the Mac's, less what the phone leaves to the Mac
/// (Project Settings, Show in Finder).
private struct ProjectMenuItems: View {
    @Environment(RemoteModel.self) private var model
    let summary: DaemonAPI.ProjectSummary
    /// Files into the project's drop box (#231), as a drag onto the Mac's row puts them.
    let putInDropbox: () -> Void

    var body: some View {
        NewSessionButton(folder: summary.folder)
        Button(action: putInDropbox) {
            Label("Put Files in Drop Box…", systemImage: "tray.and.arrow.down")
        }
        .disabled(model.isStale(on: summary.host))
        // To the top of the sidebar, as the window's Pin.
        Button {
            Task { await model.setPinned(!summary.project.isPinned, for: summary) }
        } label: {
            Label(summary.project.isPinned ? "Unpin" : "Pin",
                  systemImage: summary.project.isPinned ? "pin.slash" : "pin")
        }
        .disabled(model.isStale(on: summary.host))
        // Into Archived projects, asked first (#668), as the window's Archive.
        Button {
            model.askingToArchiveProject = summary
        } label: {
            Label("Archive…", systemImage: "archivebox")
        }
        .disabled(model.isStale(on: summary.host))
    }
}

/// New session in a project: its page, the start form (029, #366).
struct NewSessionButton: View {
    @Environment(RemoteModel.self) private var model
    let folder: URL

    var body: some View {
        Button {
            model.sidebarItem = .project(ProjectKey(host: model.work.project(folder)?.host ?? .mac, folder: folder))
        } label: {
            Label("New Session", systemImage: "plus")
        }
        .disabled(model.isStale)
    }
}

/// The first row of the sidebar (#495, #498): a new session, in the project the last one
/// was started in, as the window's. It carries that project's own item, which the list
/// lights while that form is open. A project's long press starts one in that project
/// instead.
private struct NewSessionTopRow: View {
    @Environment(RemoteModel.self) private var model

    var body: some View {
        let project = model.newSessionProject
        HStack(spacing: 8) {
            Image(systemName: "square.and.pencil")
                .foregroundStyle(Paper.accent)
                .frame(width: 20)
                .accessibilityHidden(true)
            Text("New Session")
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .appText(.supporting)
        .foregroundStyle(model.isStale || project == nil ? .secondary : .primary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("New Session")
        .modifier(NewSessionTag(project: project))
        .selectionDisabled(model.isStale || project == nil)
    }
}

/// The row's item while there is a project to start in; none while there is not.
private struct NewSessionTag: ViewModifier {
    let project: ProjectKey?

    func body(content: Content) -> some View {
        if let project {
            content.tag(SidebarItem.project(project))
        } else {
            content
        }
    }
}

/// The Runtimes row under Activity, as the window's: the title alone (#587), how many of
/// the Mac's runtimes work said to VoiceOver, and none working turns the row's icon red
/// (#379).
private struct RuntimesRow: View {
    @Environment(RemoteModel.self) private var model

    var body: some View {
        let tally = RuntimeTally(model.runtimes, allowances: model.runtimeAllowances)
        HStack {
            Text("Runtimes")
            Spacer()
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(tally.map { $0.noneWorking ? "None of \($0.total) working"
                                                       : "\($0.working) of \($0.total) working" } ?? "")
        .accessibilityHint("Opens Runtimes")
    }
}
