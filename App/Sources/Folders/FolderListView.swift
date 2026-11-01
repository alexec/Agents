import AgentsKitCore
import SwiftUI

/// The window's one sidebar (#145): Status and Usage at the top, then every folder, each a row
/// that folds open on its sessions and workflows, and at the foot what this Mac and its
/// hosts are doing.
///
/// It used to be two columns, the folders and the sessions of the one picked. The
/// folders column was mostly closed, and closing it hid what it said at a glance: what
/// Spending has left, which folders have something going on, that the Mac is being kept
/// awake, that a host is not answering. One list keeps all of that in sight.
struct FolderListView: View {
    @Environment(AppModel.self) private var model
    @Environment(WindowRequests.self) private var requests
    @Binding var selection: SidebarItem?

    @AppStorage("showsArchivedFolders", store: WindowDefaults.store) private var showsArchived = false
    /// Status, open until folded, and kept so. It keeps Activity's key (#915), so it
    /// opens as Activity was left.
    @AppStorage("showsActivity", store: WindowDefaults.store) private var showsStatus = true
    /// Usage, open until folded, and kept so (#915).
    @AppStorage("showsUsage", store: WindowDefaults.store) private var showsUsage = true
    /// The smart groups turned off in Settings ▸ Sidebar (#846).
    @AppStorage(SidebarSmartRow.offDefaultsKey, store: WindowDefaults.store) private var smartOff = SidebarSmartRow.offAtFirst
    private var smartOn: Set<SidebarSmartRow> { SidebarSmartRow.on(off: smartOff) }
    @State private var folds = SidebarFolds()
    /// What the list has highlighted — one or several (⌘-click), sessions and workflows
    /// alike. Drives bulk Archive; `selection` is still the one thing the detail reads.
    @State private var picked: Set<SidebarItem> = []
    @State private var query = ""
    /// What the folds filter by: the field's words once typing pauses, so a keystroke
    /// costs the field and not a pass over every folder (#176).
    @State private var searched = ""
    /// Bumped to make the list again when its outline has drifted from the model (#237).
    @State private var outlineRebuilds = 0
    /// The archived folder Delete… is asking about, and why one could not go (#677).
    @State private var deletingFolder: DaemonAPI.FolderSummary?
    @State private var cannotDeleteFolder: String?
    /// Folders whose every match is on show, past the first few (#176).
    @State private var showingAllMatches: Set<FolderKey> = []
    @FocusState private var searchFocused: Bool
    /// Whether the list itself has the keyboard: only then is a picked row filled with
    /// the accent rather than a grey wash (see `SidebarInk`).
    @FocusState private var listFocused: Bool
    @State private var isChoosingFolder = false
    @State private var isCloning = false
    /// Which machine the New folder menu was pointed at (037).
    @State private var targetHost: MachineRef = .mac
    @State private var isChoosingServerFolder = false
    /// File ▸ Add a Machine…'s own view of the control plane, while its sheet is open (#503).
    @State private var addingMachine: ControlSettingsModel?

    /// This Mac's folders, then each server's: no headings for hosts (Alex, #145), the
    /// host is in a server folder's own name.
    private var orderedFolders: [DaemonAPI.FolderSummary] {
        SidebarOrder.folders(model.liveFolders, servers: model.hosts.servers)
    }

    /// No runtime can be started on: Runtimes' icon says so in red (#587).
    private var runtimesFailing: Bool {
        RuntimeTally(model.runtimes, allowances: model.runtimeAllowances)?.noneWorking == true
    }

    /// A hosted server stopped while in use: MCP Servers' icon says so in red (#587, #589).
    private var mcpServersStopped: Bool {
        MCPHealthWords.tally(model.work.mcpHealthSnapshot()?.personal ?? [])?.failing == true
    }

    var body: some View {
        List(selection: $picked) {
            // A machine asking to join as this person (#994): above everything, as it
            // waits on an answer and its code lasts ten minutes.
            let joining = model.people.open()
            if !joining.isEmpty {
                Section {
                    ForEach(joining) { request in
                        JoinRequestCard(request: request, you: model.people.you?.id,
                                        isAnswering: model.people.answering.contains(request.request),
                                        answer: { approve in Task { await model.answerJoin(request, approve: approve) } })
                            .listRowSeparator(.hidden)
                            .selectionDisabled()
                    }
                }
            }
            // A bot stopped at its cap (#2073), for an admin, beside the machines.
            if model.people.list?.admin == true, !model.people.capped.isEmpty {
                Section {
                    ForEach(model.people.capped, id: \.user) { reached in
                        CapReachedCard(reached: reached, control: model.controlRequests, people: model.people)
                            .listRowSeparator(.hidden)
                            .selectionDisabled()
                    }
                }
            }
            // A channel identity asking to act as this person (#1762), beside the machines.
            let linking = model.people.openLinks()
            if !linking.isEmpty {
                Section {
                    ForEach(linking) { request in
                        ChannelLinkCard(request: request, people: model.people.linkPeople,
                                        isAnswering: model.people.answering.contains(request.request),
                                        answer: { approve, to in Task { await model.answerLink(request, approve: approve, to: to) } })
                            .listRowSeparator(.hidden)
                            .selectionDisabled()
                    }
                }
            }
            // A new client that signed in with GitHub as this person (#995), beside them.
            let signingIn = model.signIn.open()
            if !signingIn.isEmpty {
                Section {
                    ForEach(signingIn) { request in
                        SignInRequestCard(request: request, isAnswering: model.signIn.answering.contains(request.request),
                                          answer: { approve, code in Task { await model.answerSignIn(request, approve: approve, code: code) } })
                            .listRowSeparator(.hidden)
                            .selectionDisabled()
                    }
                }
            }
            // A newcomer's checklist (#982), above everything until it has gone.
            if model.showsGetStarted {
                Section {
                    GetStartedCard(isChoosingFolder: $isChoosingFolder)
                        .listRowSeparator(.hidden)
                        .selectionDisabled()
                }
            }
            // A milestone just earned (#984): once, until closed or opened.
            if let milestone = model.milestoneCard {
                Section {
                    MilestoneCard(milestone: milestone,
                                  open: { model.dismissMilestone(milestone); picked = [.milestones] },
                                  dismiss: { model.dismissMilestone(milestone) })
                        .listRowSeparator(.hidden)
                        .selectionDisabled()
                }
            }

            // What wants the person, across every folder and host (#495): Things'
            // Inbox and Today, Mail's smart mailboxes, each drawn only with something in
            // it (#507).
            Section {
                // One way to start a session (#495), in the folder last started in; the
                // page it opens can switch folder.
                NewSessionTopRow()
            }

            // The pages about all the work, a group like a folder's, above the smart
            // groups (Alex, #495): rows of
            // the list, so they take its selection and keys, each with its icon in the
            // accent beside the plain title (#155), and folding as a folder does.
            // Status is what goes on now; Usage charts the past (#915).
            Section(isExpanded: $showsStatus) {
                EventsRow().activityIcon("list.bullet.rectangle")
                    .appText(.supporting).sidebarInk(.events).tag(SidebarItem.events)
                ResourcesRow().activityIcon("square.stack.3d.up")
                    .appText(.supporting).sidebarInk(.resources).tag(SidebarItem.resources)
                RuntimesRow().activityIcon("cpu", warns: runtimesFailing)
                    .appText(.supporting).sidebarInk(.runtimes).tag(SidebarItem.runtimes)
                MCPServersRow().activityIcon("server.rack", warns: mcpServersStopped)
                    .appText(.supporting).sidebarInk(.mcpServers).tag(SidebarItem.mcpServers)
                WorktreesRow().activityIcon("arrow.triangle.branch")
                    .appText(.supporting).sidebarInk(.worktrees).tag(SidebarItem.worktrees)
            } header: {
                // The size of every other group's heading (#495).
                Text("Status").appText(.supporting)
            }

            Section(isExpanded: $showsUsage) {
                SpendingRow(selection: $selection).activityIcon("dollarsign.circle",
                                                                warns: model.costState?.daySpendIsCloseToFull == true)
                    .appText(.supporting).sidebarInk(.spending).tag(SidebarItem.spending)
                TokensRow().activityIcon("number", warns: model.costState?.dayTokensAreCloseToFull == true)
                    .appText(.supporting).sidebarInk(.tokens).tag(SidebarItem.tokens)
                TimeRow().activityIcon("clock")
                    .appText(.supporting).sidebarInk(.time).tag(SidebarItem.time)
                // The work's cost and links from any start (#3087), the Cost page's Lineage pane.
                HStack { Text("Lineage").foregroundStyle(.primary); Spacer() }
                    .help("The work’s cost, time and links, from a session, an issue, a pull request or a milestone")
                    .activityIcon("point.3.connected.trianglepath.dotted")
                    .appText(.supporting).sidebarInk(.lineage).tag(SidebarItem.lineage)
                // The newcomer's checklist (#1067), only while a milestone is still to earn,
                // as an empty smart group hides (#507). Then the list is under Time's charts.
                if model.work.milestones?.isComplete == false {
                    MilestonesRow().activityIcon("checkmark.seal")
                        .appText(.supporting).sidebarInk(.milestones).tag(SidebarItem.milestones)
                }
            } header: {
                Text("Usage").appText(.supporting)
            }

            // Pinned, Needs You (with everything waiting for an OK, #773), Working, Unread: a group each, headed and folding as a
            // folder's is, so every group in the list lines up alike (#495). Empty, or
            // with no match for a search, a group is not drawn (#507).
            // A group turned off in Settings ▸ Sidebar is not drawn (#846).
            ForEach(SidebarSmartRow.allCases.filter(smartOn.contains), id: \.self) { row in
                SmartFold(row: row, folders: orderedFolders.map(\.key), folds: folds, query: searched)
            }

            // One group per folder (#495), its name the group's heading, its sessions the
            // rows: Mail's accounts rather than a Folders heading with folds under it.
            ForEach(orderedFolders, id: \.key) { summary in
                FolderFold(summary: summary, folds: folds, query: searched,
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
                    GoneFolderRows(host: host)
                }
                // Where the folder will be once it is one (027).
                ForEach(model.clones) { clone in
                    CloningRow(clone: clone).appText(.supporting)
                }
                if model.folders.isEmpty, model.clones.isEmpty, model.hasLoadedFolders, model.isConnected {
                    EmptyFolderList(isChoosingFolder: $isChoosingFolder, isCloning: $isCloning)
                        .appText(.supporting)
                }
            }

            if !model.archivedFolders.isEmpty, searched.isEmpty {
                Section(isExpanded: $showsArchived) {
                    // None while folded, as under a folded folder (#356).
                    ForEach(showsArchived ? model.archivedFolders : [], id: \.key) { summary in
                        ArchivedFolderRow(summary: summary, label: label(summary),
                                           unarchive: { await model.unarchiveFolder(summary.key) },
                                           delete: { deletingFolder = summary })
                            .appText(.supporting)
                    }
                } header: {
                    Text("Archived folders").appText(.supporting)
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
        .confirmationDialog(DeletionWords.folderConfirmTitle(deletingFolder.map(label) ?? ""),
                            isPresented: Binding(get: { deletingFolder != nil },
                                                 set: { if !$0 { deletingFolder = nil } }),
                            presenting: deletingFolder) { summary in
            Button("Delete", role: .destructive) {
                Task {
                    if case .failure(let refusal) = await model.deleteFolder(summary.key) {
                        cannotDeleteFolder = refusal.message
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text(DeletionWords.folderConfirmMessage)
        }
        .alert("This folder cannot be deleted yet",
               isPresented: Binding(get: { cannotDeleteFolder != nil }, set: { if !$0 { cannotDeleteFolder = nil } })) {
            Button("OK") {}
        } message: {
            Text(cannotDeleteFolder ?? "")
        }
        // What this Mac and its hosts are doing, pinned at the foot: status lines rather
        // than somewhere to go, so not rows of the list. Each is absent when there is
        // nothing to say, which is most of the time (024 FR-015).
        // Undo after Archive (#1534), for a few seconds, just over the foot. An overlay, not
        // part of the inset: the list's rows draw over what is in the inset.
        .overlay(alignment: .bottom) {
            if let undo = model.archiveUndo {
                ArchiveUndoStrip(undo: undo,
                                 perform: { Task { await model.undoArchive() } },
                                 dismiss: { model.dismissArchiveUndo(undo) })
            }
        }
        .animation(.easeOut(duration: 0.2), value: model.archiveUndo?.id)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            SidebarFoot()
        }
        // ⌫ archives everything highlighted that is not already archived (one or many).
        .onDeleteCommand { archivePicked() }
        // Return renames the one session highlighted, as Finder renames a file (#751).
        .onKeyPress(.return, action: renamePicked)
        .onChange(of: picked) { _, picks in applyPicked(picks) }
        .onChange(of: selection, initial: true) { _, item in applySelection(item) }
        .onChange(of: requests.wantsSessionSearchFocus) { _, wants in
            guard wants else { return }
            searchFocused = true
            requests.wantsSessionSearchFocus = false
        }
        // A folder dragged in from Finder becomes a folder, as File ▸ Add Folder
        // Folder… does. Folders only: a file is not somewhere to work. A file dropped on
        // a folder's or a session's row goes into its drop box instead (#231).
        .dropDestination(for: URL.self) { urls, _ in
            let folders = urls.filter { $0.hasDirectoryPath || (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            guard !folders.isEmpty else { return false }
            Task { for folder in folders { await model.addFolder(folder) } }
            return true
        }
        // The system's folder panel, with the Project picker under it (#2671).
        .onChange(of: isChoosingFolder) { _, choosing in
            guard choosing else { return }
            isChoosingFolder = false
            Task {
                guard let chosen = await AddFolderPanel.choose(control: model.controlRequests) else { return }
                await model.addFolder(chosen.folder, project: chosen.project)
            }
        }
        .sheet(isPresented: $isCloning) { CloneSheet(host: targetHost).paperSheet() }
        .sheet(isPresented: $isChoosingServerFolder) { RemoteFolderSheet(host: targetHost).paperSheet() }
        .sheet(isPresented: Binding(get: { requests.dropboxFolder != nil },
                                    set: { if !$0 { requests.dropboxFolder = nil } })) {
            if let folder = requests.dropboxFolder { DropboxSheet(folder: folder).paperSheet() }
        }
        .sendToHostSheet(requests)
        .bringBackSheet(requests)
        // The sheet Settings ▸ Machines ▸ Add a Machine… shows (#503, #2755).
        .sheet(isPresented: Binding(get: { addingMachine != nil }, set: { if !$0 { addingMachine = nil } })) {
            if let control = addingMachine {
                AddMachineSheet(control: control)
                    .task { await control.start() }
                    .onDisappear { control.stop() }
                    .paperSheet()
            }
        }
        // File ▸ Add Folder…, Clone Folder from Git URL…, their On menus for a server,
        // and Add a Machine….
        .onChange(of: requests.folderSheet) { _, sheet in
            guard let sheet else { return }
            requests.folderSheet = nil
            switch sheet {
            case .chooseFolder(let host):
                targetHost = host
                if model.isOnThisMac(host) { isChoosingFolder = true } else { isChoosingServerFolder = true }
            case .clone(let host):
                targetHost = host
                isCloning = true
            case .addMachine:
                addingMachine = ControlConfig.endpoint.flatMap { ControlSettingsModel(endpoint: $0) }
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
    /// unfolds its folder so the row is there to light.
    private func applySelection(_ item: SidebarItem?) {
        guard let item else {
            if picked.count == 1 { picked = [] }
            return
        }
        if case .session(let id) = item, let agent = model.work.agent(id) {
            folds.set(FolderKey(host: agent.host, folder: agent.folderPath), open: true)
        } else if case .workflow(_, let key) = item {
            folds.set(key, open: true)
        } else if case .pin(_, let key) = item {
            folds.set(key, open: true)
        } else if case .archive(let key) = item {
            folds.set(key, open: true)
        } else if case .folderMCPServers(let key) = item {
            folds.set(key, open: true)
        } else if case .folder(let key) = item {
            // A new session, from ⌘N or a menu: its row is in the fold.
            folds.set(key, open: true)
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
            // One Undo for the whole selection (#1664).
            await model.archive(sessions: sessions, workflows: flows)
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

    /// An archived folder's name as its live row had it: `server:Folder` on a server (#677).
    private func label(_ summary: DaemonAPI.FolderSummary) -> String {
        SidebarOrder.label(summary) { model.hosts.label($0) }
    }
}

/// One folder in the sidebar: its row, and folded under it its sessions — Needs you
/// first, the way the folder page groups them — then its Workflows fold (#885), then
/// its pages: MCP Servers and Archived.
///
/// A search unfolds every folder with something that matches and hides the rest.
///
/// In a folder's own window (#1089) the same rows go under a Sessions heading: the
/// window is the folder, so its name is the window's title and not a heading.
struct FolderFold: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @AppStorage(SidebarSmartRow.offDefaultsKey, store: WindowDefaults.store) private var smartOff = SidebarSmartRow.offAtFirst
    @Environment(WindowRequests.self) private var requests
    let summary: DaemonAPI.FolderSummary
    let folds: SidebarFolds
    /// The search's words, already trimmed; empty when there is no search.
    let query: String
    var showsAllMatches = false
    var showAllMatches: () -> Void = {}
    /// The smart groups this list draws, when not the ones Settings ▸ Sidebar turns on:
    /// a folder's window has Pinned and Needs You only (#1089).
    var smartGroups: Set<SidebarSmartRow>? = nil
    /// Drawn in a folder's own window (#1089).
    var inWindow = false

    private var key: FolderKey { summary.key }

    var body: some View {
        // Folded, nothing under the row is drawn, so nothing is filed for it: the row
        // reads its own numbers off the folder's shelf (#165). What goes under which
        // heading is the shared model's, which the Remote draws too (#226).
        let fold = SidebarFolderFold(key, label: label, in: model.work, query: query,
                                      isOpen: folds.isOpen(key), keptInUnread: model.keptInUnread,
                                      on: smartGroups ?? SidebarSmartRow.on(off: smartOff))
        let isOpen = fold.isUnfolded
        if fold.isShown {
            Section(isExpanded: Binding(
                get: { isOpen },
                set: { folds.set(key, open: $0) })) {
                // Folded, nothing at all is under the heading (#356): see `isUnfolded`.
                // A session starts from New Session at the top (#495), or the menu.
                // The folder's pinned pages (#159), before its sessions. Not while
                // searching: the search is for sessions.
                if fold.showsPinnedPages {
                    PinnedPageRows(folder: key)
                    // Then its servers' list views, without a pin (#2032).
                    ServerViewRows(folder: key)
                }
                // Its pinned sessions and workflows are in Pinned at the top (#495).
                // Then every other live session, newest first, its state a mark on the
                // row rather than a heading over it (#495). Each under the session that
                // started it, folded (#835). Under a Sessions row, as the workflows are
                // under theirs (#2312), the only layout (#2381); not in a folder's own
                // window, whose group is headed Sessions already.
                let grouped = !inWindow && !fold.sessions.isEmpty
                let sessionsOpen = !grouped || fold.isSearching || folds.isOpen(key, .sessions)
                if grouped {
                    SidebarFoldRow(title: "Sessions", count: fold.sessions.count, isOpen: Binding(
                        get: { sessionsOpen },
                        set: { folds.set(key, .sessions, open: $0) }))
                }
                // A closed fold has no rows at all (#237).
                ForEach(FoldedRow.rows(sessionsOpen ? SidebarTree.rows(fold.sessions, in: model.work, folds: folds) : [],
                                       in: .sessions)) { row in
                    SessionSidebarRow(agent: row.item.agent, tree: row.item, folds: folds, isNested: grouped)
                }
                if !fold.recentArchived.isEmpty {
                    let recentOpen = folds.isOpen(key, .recentArchivedSessions)
                    SidebarFoldRow(title: "Recently archived sessions", count: fold.recentArchived.count, isOpen: Binding(
                        get: { recentOpen },
                        set: { folds.set(key, .recentArchivedSessions, open: $0) }))
                    ForEach(FoldedRow.rows(recentOpen ? fold.recentArchived : [], in: .recentArchivedSessions)) { row in
                        SessionSidebarRow(agent: row.item, isNested: true)
                    }
                }
                // Then its workflows, after the sessions (Alex, #495), in a Workflows fold
                // of their own, one level in, as a mailbox's sub-mailboxes in Mail (#885).
                FolderWorkflowRows(fold: fold, folds: folds)
                if fold.isSearching {
                    // What matched in the archive, in the group while searching, so a
                    // match is one click away as it was.
                    searchMatches(fold)
                } else {
                    // Its connectors (#753), under every folder even with none yet (#1422):
                    // a page, red when one does not answer, with how many (#1569).
                    let servers = model.work.mcpServers(in: key)
                    let tally = MCPHealthWords.tally(servers)
                    FolderPageRow(title: "Connectors", systemImage: "server.rack",
                                   item: .folderMCPServers(key), warns: tally?.failing ?? false,
                                   count: servers.count)
                        .help(tally?.words ?? "No connectors yet")
                    // The archive, one row opening a page (#495): never a fold inside
                    // the group.
                    let archived = fold.archivedCount(summary) + fold.archivedWorkflows.count
                    if archived > 0 {
                        FolderPageRow(title: "Archived", systemImage: "archivebox", item: .archive(key))
                            .help("\(archived) archived")
                    }
                }
            } header: {
                if inWindow {
                    Text("Sessions").appText(.supporting)
                } else {
                    heading(fold, isOpen: isOpen)
                }
            }
            // The few Recently archived sessions it shows, while it is open by hand (#2731):
            // not because a search unfolded it, since the search brings its own matches.
            .task(id: folds.isOpen(key)) {
                if folds.isOpen(key) {
                    _ = await model.loadArchived(in: key, limit: SidebarFolderFold.recentArchivedShown)
                } else { model.letGoOfArchived(in: key) }
            }
        }
    }

    /// The folder's row, as the main window's sidebar heads its group with it.
    private func heading(_ fold: SidebarFolderFold, isOpen: Bool) -> some View {
        FolderRow(summary: summary, label: label, isFolded: !isOpen, asHeading: true) {
            // A search holds every match open.
            if !fold.isSearching { folds.set(key, open: !isOpen) }
        }
            .appText(.supporting)
            // As tall as its one or two lines and a little air (#104).
            .listRowInsets(.vertical, 3)
            // Last known, not current: the server is not answering (037).
            .foregroundStyle(model.hostUnreachable(summary.host) ? .secondary : .primary)
            .contextMenu { FolderMenu(summary: summary) }
            // A file dropped here goes into the folder's drop box (#231).
            .dropsIntoDropbox(of: key)
            // No tag: the row is not something to open (#375). The folder's
            // `.folder` item is its New session row.
            // A double-click opens the folder in a window of its own (#1089).
            .simultaneousGesture(TapGesture(count: 2).onEnded { openWindow(id: FolderWindowScene.id, value: key) })
    }

    /// A server's folder says which server (Alex, #145): no heading for each host, so
    /// the host goes in the name. This Mac's go by name alone.
    private var label: String {
        SidebarOrder.label(summary) { model.hosts.label($0) }
    }

    /// While searching: the workflows and archived sessions that matched, after the live
    /// ones, the archived capped until Show all (#176).
    @ViewBuilder
    private func searchMatches(_ fold: SidebarFolderFold) -> some View {
        ForEach(FoldedRow.rows(fold.archivedWorkflows, in: .archivedWorkflows)) { row in
            WorkflowListRow(summary: row.item, folder: key)
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

/// The first row of the sidebar (#495): a new session, in the folder the last one was
/// started in, as ⌘N starts one. The page it opens can switch folder. It carries that
/// folder's own item, which the sidebar lights while its new session is open.
private struct NewSessionTopRow: View {
    @Environment(AppModel.self) private var model
    @Environment(WindowRequests.self) private var requests

    var body: some View {
        let folder = model.newSessionFolder
        HStack(spacing: 6) {
            Image(systemName: "square.and.pencil")
                .sidebarMark(Paper.accent)
                .frame(width: 16)
                .accessibilityHidden(true)
            Text("New Session")
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .appText(.supporting)
        .contentShape(Rectangle())
        // Every click, not only a changed selection: the row may already be the lit one
        // while the prompt has lost the keyboard. See `FolderRow` before #375.
        .simultaneousGesture(TapGesture().onEnded {
            guard let folder else { return }
            model.showFolder(folder)
            requests.focusPrompt()
        })
        .disabled(folder == nil)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("New Session")
        .modifier(NewSessionTag(folder: folder))
    }
}

/// The row's item while there is a folder to start in; none while there is not.
private struct NewSessionTag: ViewModifier {
    let folder: FolderKey?

    func body(content: Content) -> some View {
        if let folder {
            content.sidebarInk(.folder(folder)).tag(SidebarItem.folder(folder))
        } else {
            content
        }
    }
}

/// One session under its folder: the sessions column's row, tagged into the sidebar's
/// one selection.
struct SessionSidebarRow: View {
    @Environment(AppModel.self) private var model
    /// In a folder's own window, how it opens what is picked (#1090).
    @Environment(\.windowOpen) private var windowOpen
    let agent: Agent
    /// Its folder's name, after the title, under a smart row (#495).
    var place: String? = nil
    /// Where it sits in its list's tree (#835), and the folds that keep a parent's.
    var tree: SidebarTree.Row? = nil
    var folds: SidebarFolds? = nil
    /// In its folder's Sessions fold: one level in, under the word Sessions (#2312).
    var isNested = false

    var body: some View {
        AgentRow(agent: agent, isCompact: true, place: place, tree: tree) {
            guard let tree else { return }
            folds?.set(session: agent.id, open: !tree.isUnfolded)
        }
            .padding(.leading, isNested ? 22 : 0)
            .padding(.vertical, 2)
            .listRowInsets(.vertical, 2)
            .sidebarInk(.session(agent.id))
            .tag(SidebarItem.session(agent.id))
            // A click on the session already open goes to its latest message, as opening it
            // does (#1349): the list hears no change of selection for it.
            .simultaneousGesture(TapGesture().onEnded {
                if windowOpen == nil, model.selection == agent.id { model.scrollToEnd() }
            })
            // A double-click edits its title in the row, as Return does (#1518).
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                guard agent.state != .archived else { return }
                model.renaming = Renaming(id: agent.id)
            })
            // Into its folder's drop box, never its worktree (#231).
            .dropsIntoDropbox(of: FolderKey(host: agent.host, folder: agent.folderPath))
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
                    SwipeAction("Unarchive") { await model.unarchive(agent.id) }
                } else {
                    SwipeAction("Archive", systemImage: "archivebox") {
                        await model.archive(agent.id, andLeave: true)
                    }
                    .tint(.gray)
                }
            }
    }
}

/// A folder's or a session's row taking files dragged from Finder (#231): each file
/// goes into the top of the folder's drop box, where a workflow can pick it up; the
/// folder's *Put Files in Drop Box…* names a folder inside it. A folder dropped here is
/// added as a folder, as one dropped on the list around the rows is. Once the files are
/// in, a note under the row says where for a moment (#934): a session's row sends them
/// to its folder, not to the chat.
private struct DropboxDrop: ViewModifier {
    @Environment(AppModel.self) private var model
    let folder: FolderKey
    @State private var isTargeted = false
    /// "Put 2 files in work’s drop box", while it shows.
    @State private var note: String?
    @State private var clearing: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            // Room under the row for the note, by padding and not a stack: a stack would
            // hide the row's tag from the List.
            .padding(.bottom, note == nil ? 0 : 16)
            .overlay(alignment: .bottomLeading) {
                if let note {
                    Text(note)
                        .appText(.fine)
                        .foregroundStyle(Paper.accent)
                        .lineLimit(1)
                        .padding(.leading, 4)
                        .transition(.opacity)
                }
            }
            .background(isTargeted || note != nil ? Paper.accent.opacity(0.18) : .clear, in: .rect(cornerRadius: 5))
            .dropDestination(for: URL.self) { urls, _ in
                let isFolder: (URL) -> Bool = {
                    $0.hasDirectoryPath || (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                }
                let folders = urls.filter(isFolder)
                let files = urls.filter { !isFolder($0) }
                guard !urls.isEmpty else { return false }
                Task {
                    for folder in folders { await model.addFolder(folder) }
                    // One that could not go is the window's alert, said already.
                    if !files.isEmpty, await model.putInDropbox(files, folder: folder) { show(files.count) }
                }
                return true
            } isTargeted: { isTargeted = $0 }
    }

    private func show(_ count: Int) {
        let said = "Put \(count == 1 ? "1 file" : "\(count) files") in \(folder.folder.lastPathComponent)\u{2019}s drop box"
        withAnimation { note = said }
        AccessibilityNotification.Announcement(said).post()
        clearing?.cancel()
        clearing = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            withAnimation { note = nil }
        }
    }
}

private extension View {
    func dropsIntoDropbox(of folder: FolderKey) -> some View {
        modifier(DropboxDrop(folder: folder))
    }
}

/// A folder's context menu, and the folder menu's items.
private struct FolderMenu: View {
    @Environment(AppModel.self) private var model
    @Environment(WindowRequests.self) private var requests
    @Environment(\.openWindow) private var openWindow
    let summary: DaemonAPI.FolderSummary

    var body: some View {
        // The folder alone, in a window of its own (#1089); its key is the Window menu's.
        Button("Open in New Window") { openWindow(id: FolderWindowScene.id, value: summary.key) }
            .keyboardShortcut("o", modifiers: [.command, .option])
        Divider()
        Button("New Session") {
            model.showFolder(summary.key)
            requests.focusPrompt()
        }
        .disabled(model.hostUnreachable(summary.host))
        Button("Folder Settings…") {
            model.showFolder(summary.key)
            requests.folderSettings = .general
        }
        // A drag onto the row goes to the drop box's top; this names a folder in it.
        Button("Put Files in Drop Box…") { requests.dropboxFolder = summary.key }
            .disabled(model.hostUnreachable(summary.host) || !summary.exists)
        ShowHiddenViewsButton(folder: summary.key)
        // This Mac's repository, sent to a server and added there (#1123).
        if model.canSend(from: summary.host) {
            ForEach(model.sendTargets, id: \.self) { host in
                Button("Send to \(model.hosts.label(host))…") {
                    requests.sendToHost = SendToHostRequest(folder: summary.folder.folder, from: summary.host, host: host)
                }
                .disabled(!summary.exists)
            }
            // The server's branches, brought back into this Mac's repository (#1473).
            ForEach(model.sendTargets, id: \.self) { host in
                Button("Bring Back from \(model.hosts.label(host))…") {
                    requests.bringBackFromHost = BringBackFromHostRequest(folder: summary.folder.folder, from: summary.host, host: host)
                }
                .disabled(!summary.exists)
            }
        }
        Divider()
        // To the top of the sidebar, above the folders that are not.
        Button(summary.folder.isPinned ? "Unpin" : "Pin") {
            Task { await model.setPinned(!summary.folder.isPinned, for: summary.key) }
        }
        .disabled(model.hostUnreachable(summary.host))
        Button("Archive") {
            Task { await model.archiveFolder(summary.key) }
        }
        .disabled(model.hostUnreachable(summary.host))
        Divider()
        // Its agents as a .tar.gz, and an export brought back on its machine (#1001).
        // Off while one is on its way, so a second tap makes no second export (#2437).
        Button("Export Agents…") { Task { await model.exportFolder(summary) } }
            .disabled(model.hostUnreachable(summary.host) || model.exportImport != nil)
        Button("Import Agents…") { Task { await model.importAgents(into: summary) } }
            .disabled(model.hostUnreachable(summary.host) || model.exportImport != nil)
        // Only this Mac's folder is somewhere Finder can show (058, FR-019).
        if model.isOnThisMac(summary.host) {
            Button("Show in Finder") {
                model.reveal(summary.folder.folder, on: summary.host)
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
                // the folders stay listed under it (058, frame H).
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
                // A server gone quiet greys its folders; this says why, once, where the
                // Mac's own state is said. One on a stopped workspace says so, with Start (#961).
                let row = model.hosts.controlRows[host]
                HStack(spacing: 8) {
                    Label(OfflineWords.footLine(name: model.hosts.label(host), row: row),
                          systemImage: "bolt.horizontal.circle")
                        .appText(.fine)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityElement(children: .combine)
                    Spacer(minLength: 0)
                    if let row, let workspace = row.workspace, OfflineWords.offersStart(state: row.state, workspace: workspace) {
                        Button("Start") { Task { await model.startHost(host) } }
                            .controlSize(.small)
                            .disabled(model.hostsBeingStarted.contains(host))
                            .help("Starts \(workspace.workspaceName) at \(workspace.providerName).")
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 4)
            }
            // A file this Mac keeps that could not be read (#205): why paired devices or
            // folders may have gone from view, and that what they held is kept.
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
private struct EmptyFolderList: View {
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
                Text("No folders yet")
                    .appText(.reading).fontWeight(.semibold)
                Text("Pick a folder and say what you want done.")
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Add Folder…") { isChoosingFolder = true }
                        .buttonStyle(.paperProminent)
                    Button("Clone Folder from Git URL…") { isCloning = true }
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
/// rather than in a row above the folders: a line that already shows a figure is the
/// one place somebody looks for more of it. It is a row of the sidebar and not a
/// button to a window of its own — the bill is something you read beside the work and
/// come back out of, like a folder.
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
        if state.isHolding, state.onPower { return WakeWords.onPowerLine }
        if state.isHolding, let until = state.graceUntil {
            return WakeWords.untilLine(until)
        }
        return state.isHolding ? nil : state.batteryPercent.map { "\($0)%" }
    }

    private func help(_ state: DaemonAPI.WakeState) -> String {
        if state.isHolding, state.onPower { return WakeWords.onPowerHelp }
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

/// Folders a server no longer has (043, contracts/ui.md § 6): shown as gone, never as
/// offline, until the person removes them.
private struct GoneFolderRows: View {
    @Environment(AppModel.self) private var model
    let host: MachineRef

    var body: some View {
        ForEach(model.hosts.goneFolders[host] ?? [], id: \.self) { path in
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text((path as NSString).lastPathComponent).foregroundStyle(.secondary)
                    Text("Gone from \(model.hosts.label(host))").appText(.fine).foregroundStyle(.tertiary)
                }
                Spacer()
                Button("Remove") { model.hosts.forgetGoneFolder(host, path: path) }
                    .controlSize(.small)
            }
            .appText(.supporting)
            .help(path)
        }
    }
}

/// In the folders list while this Mac's host is quiet (#83, #303): said whole, in a
/// person's words, naming why and the step that fixes it. The folders under it stay
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
            // The marks set their own colour, which wins over this one: they read it (#2382).
            content.foregroundStyle(Paper.ground).environment(\.sidebarRowInked, true)
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
