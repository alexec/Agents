import AgentsKitCore
import SwiftUI
import UIKit

/// The Mac's one sidebar, on an iPad or an iPhone (#226, #498): New Session at the top,
/// then Status and Usage, then what wants the person across every folder — Pinned, Needs You,
/// Working, Unread — then a group per folder, its sessions newest first with their state
/// the row's mark, its workflows, and one Archived row opening a page; then the archived
/// folders, folded, each with Unarchive (#343). Never more than two levels deep (#495).
///
/// The rules are the Mac's own, from `SidebarFolderFold`, `SidebarSmartRow`,
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
    /// pass over every folder (#176).
    @State private var searched = ""
    /// Folders whose every archived match is on show, past the first few (#176).
    @State private var showingAllMatches: Set<FolderKey> = []
    /// Archived folders, open or closed, kept as the window keeps it (#343).
    @AppStorage("showsArchivedFolders") private var showsArchived = false
    /// Status, open until folded, and kept so, as the window keeps it. It keeps Activity's
    /// key (#915), so it opens as Activity was left.
    @AppStorage("showsActivity") private var showsStatus = true
    /// Usage, open until folded, and kept so, as the window keeps it (#915).
    @AppStorage("showsUsage") private var showsUsage = true
    /// Add Folder… or Clone Folder from Git URL…, on a host, from the + (#537).
    @State private var adding: NewFolder?
    /// The smart groups turned off in Settings ▸ Sidebar (#846).
    @AppStorage(SidebarSmartRow.offDefaultsKey) private var smartOff = SidebarSmartRow.offAtFirst
    /// Settings (#846), opened from the sidebar's foot.
    @State private var showsSettings = false
    /// Add a Browser… (#1459): a code for a browser, as the window's.
    @State private var addsBrowser = false

    private var selection: Binding<SidebarItem?> {
        Binding(get: { model.sidebarItem },
                set: { item in
                    // A list clears its selection by itself while rows come and go, and
                    // that must not empty the detail; going back on a phone clears it
                    // through the split view's column instead.
                    guard let item else { return }
                    // The session already open, picked again: to its latest message (#1349).
                    if item == model.sidebarItem, case .session = item { model.scrollToEnd() }
                    model.sidebarItem = item
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
        let folders = SidebarOrder.folders(model.folders, servers: servers)
        List(selection: selection) {
            // A machine asking to join as this person (#994): at the top, as it waits on
            // an answer and its code lasts ten minutes.
            let joining = model.people.open()
            if !joining.isEmpty {
                Section {
                    ForEach(joining) { request in
                        JoinRequestCard(request: request, you: model.people.you?.id,
                                        isAnswering: model.people.answering.contains(request.request),
                                        answer: { approve in Task { await model.answerJoin(request, approve: approve) } })
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                    }
                }
            }
            // A bot stopped at its cap (#2073), for an admin, beside the machines.
            if model.people.list?.admin == true, !model.people.capped.isEmpty {
                Section {
                    ForEach(model.people.capped, id: \.user) { reached in
                        CapReachedCard(reached: reached, control: model.controlPlane, people: model.people)
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
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
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
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
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                    }
                }
            }

            if !model.folders.isEmpty {
                // One way to start a session (#495), in the folder last started in.
                // A folder's long press starts one in it.
                Section {
                    NewSessionTopRow()
                }

                // Pages about all the work rather than one folder, above the smart
                // groups, as the window has them (#495). Plain titles beside their icons
                // in the accent (#155). Each folds, as a folder does. Status is what
                // goes on now; Usage charts the past (#915).
                Section(isExpanded: $showsStatus) {
                    EventsRow().activityIcon("list.bullet.rectangle").appText(.supporting).tag(SidebarItem.events)
                    ResourcesRow().activityIcon("square.stack.3d.up").appText(.supporting).tag(SidebarItem.resources)
                    RuntimesRow().activityIcon("cpu", warns: runtimesFailing)
                        .appText(.supporting).tag(SidebarItem.runtimes)
                    MCPServersRow().activityIcon("server.rack", warns: mcpServersStopped)
                        .appText(.supporting).tag(SidebarItem.mcpServers)
                    WorktreesRow().activityIcon("arrow.triangle.branch")
                        .appText(.supporting).tag(SidebarItem.worktrees)
                } header: {
                    Text("Status")
                }

                Section(isExpanded: $showsUsage) {
                    SpendingRow().activityIcon("dollarsign.circle", warns: model.costState?.daySpendIsCloseToFull == true)
                        .appText(.supporting).tag(SidebarItem.spending)
                    TokensRow().activityIcon("number", warns: model.costState?.dayTokensAreCloseToFull == true)
                        .appText(.supporting).tag(SidebarItem.tokens)
                    TimeRow().activityIcon("clock").appText(.supporting).tag(SidebarItem.time)
                    // The newcomer's checklist (#1067), only while a milestone is still to
                    // earn, as an empty smart group hides (#507).
                    if model.work.milestones?.isComplete == false {
                        MilestonesRow().activityIcon("checkmark.seal").appText(.supporting).tag(SidebarItem.milestones)
                    }
                } header: {
                    Text("Usage")
                }

                // Pinned, Needs You, Working, Unread: a group each across every folder
                // and host (#495), headed and folding as a folder's is.
                // A group turned off in Settings ▸ Sidebar is not drawn (#846).
                let on = SidebarSmartRow.on(off: smartOff)
                ForEach(SidebarSmartRow.allCases.filter(on.contains), id: \.self) { row in
                    RemoteSmartFold(row: row, folders: folders, folds: folds, query: searched)
                }
            }

            // One group per folder (#495), its name the group's heading, its sessions
            // the rows: Mail's accounts rather than a Folders heading with folds under it.
            ForEach(folders, id: \.key) { summary in
                RemoteFolderFold(summary: summary, folds: folds, query: searched,
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

            // Folders put away, closed until opened, as the window's (#343).
            if !model.shelvedFolders.isEmpty, searched.isEmpty {
                Section(isExpanded: $showsArchived) {
                    ForEach(model.shelvedFolders, id: \.key) { summary in
                        ArchivedFolderRow(summary: summary,
                                           label: SidebarOrder.label(summary) { model.hostLabel($0) },
                                           isDisabled: model.isStale || model.hostIsOffline(summary.host),
                                           unarchive: { await model.unarchiveFolder(summary) },
                                           delete: { model.askingToDeleteFolder = summary })
                        .appText(.supporting)
                    }
                } header: {
                    Text("Archived folders")
                }
            }

            // A server gone quiet greys its folders; this says why, once, as the window's
            // sidebar foot does (#534).
            let offline = servers.filter { model.hostIsOffline($0) }
            if !offline.isEmpty {
                Section {
                    ForEach(offline, id: \.self) { host in
                        // One on a stopped workspace says so, with Start, as its strip (#961).
                        let row = model.controlHost(host)
                        HStack(spacing: 8) {
                            Label(OfflineWords.footLine(name: model.hostLabel(host), row: row),
                                  systemImage: "bolt.horizontal.circle")
                                .appText(.fine)
                                .foregroundStyle(.secondary)
                                .accessibilityElement(children: .combine)
                            Spacer(minLength: 0)
                            if let row, let workspace = row.workspace,
                               OfflineWords.offersStart(state: row.state, workspace: workspace) {
                                Button("Start") { Task { await model.startHost(host) } }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                    .appText(.fine)
                                    .disabled(model.hostsBeingStarted.contains(host))
                                    .accessibilityLabel("Start \(model.hostLabel(host))")
                            }
                        }
                    }
                }
            }

            // A file the Mac keeps that could not be read (#205, #223), as the window's
            // sidebar foot: why paired devices or folders may have gone from view.
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
                    Button("Add a Browser…") { addsBrowser = true }
                        .appText(.supporting)
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
                ToolbarItem(placement: .primaryAction) { NewFolderMenu(adding: $adding) }
            }
        }
        .sheet(item: $adding) { NewFolderSheet(adding: $0) }
        .sheet(isPresented: $showsSettings) { RemoteSettings() }
        .sheet(isPresented: $addsBrowser) { AddBrowserSheet() }
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
        // Every folder's workflows and pinned pages, and the rows' lease marks (#175).
        .shows([.workflows, .pins, .leases])
        .safeAreaInset(edge: .top, spacing: 0) {
            if showsBanner { StaleBanner() }
        }
        .overlay {
            // Not over a machine's ask to join (#994): the card is the list's, and the
            // waiting view in the middle would lie over the rows under it.
            if model.folders.isEmpty, model.people.open().isEmpty, model.people.openLinks().isEmpty, model.signIn.open().isEmpty {
                Waiting()
            }
        }
        // The catch-up leaves archived folders out; they are asked for here (#343), and
        // again once the list is pulled.
        .task(id: model.isConnected) {
            if model.isConnected { await model.loadArchivedFolders() }
        }
        .refreshable {
            await model.catchUp()
            await model.loadArchivedFolders()
        }
    }

    /// Said once on the screen. Beside the detail on a wide iPad, the detail carries the
    /// line; and with no folders yet, the waiting view in the middle says the same thing
    /// in more words.
    private var showsBanner: Bool {
        if sizeClass == .regular { return false }
        if model.folders.isEmpty, model.needsPairing || model.isStale { return false }
        return true
    }
}

/// One of the groups at the top of the sidebar (#495, #498): Pinned, Needs You, Working
/// or Unread, across every folder and host, each row naming its folder. The window's
/// `SmartFold`. Folded, it reads its count off each folder's shelf and lists nothing
/// (#356).
struct RemoteSmartFold: View {
    @Environment(RemoteModel.self) private var model
    let row: SidebarSmartRow
    /// The folders in the sidebar, in its order.
    let folders: [DaemonAPI.FolderSummary]
    let folds: SidebarFolds
    /// The search's words, already trimmed; empty when there is no search.
    let query: String
    /// The smart groups turned off in Settings ▸ Sidebar (#846): their sessions are listed
    /// by the next group they fit.
    @AppStorage(SidebarSmartRow.offDefaultsKey) private var smartOff = SidebarSmartRow.offAtFirst
    /// The groups drawn, when not those Settings ▸ Sidebar turns on: a folder's own
    /// scene has Pinned and Needs You only (#1089).
    var groups: Set<SidebarSmartRow>? = nil
    private var on: Set<SidebarSmartRow> { groups ?? SidebarSmartRow.on(off: smartOff) }

    var body: some View {
        let keys = folders.map(\.key)
        // Empty, or with no match for a search, the group is not drawn (#507); Unread
        // with nothing unread still is while it keeps the open session.
        if row.isShown(in: model.work, folders: keys, query: query, on: on) || keptUnread != nil {
            fold(keys)
        }
    }

    private func fold(_ keys: [FolderKey]) -> some View {
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
                    ForEach(row.approvals(in: model.work, folders: keys, query: query), id: \.approval.id) { item in
                        if item.approval.opensItsSubject {
                            RemoteFailedWorkflowRow(approval: item.approval, folder: item.folder,
                                                    place: place(of: item.folder))
                        } else {
                            RemoteApprovalRow(approval: item.approval, folder: item.folder, place: place(of: item.folder))
                        }
                    }
                }
            }
        } header: {
            SmartHeading(row: row, count: row.count(in: model.work, folders: keys, on: on),
                         updatedAt: row == .needsYou ? model.needsYouUpdatedAt : nil)
        }
    }

    /// What the group lists. Unread keeps the session opened from it (`keptInUnread`) in
    /// its place, read now, until another is opened: its count has already dropped.
    private func shown(_ keys: [FolderKey]) -> [Agent] {
        var agents = row.agents(in: model.work, folders: keys, query: query, on: on)
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

    /// One folder's pinned sessions (#180), then its pinned workflows (#432), each
    /// dragged in the list's edit mode into the order wanted among its own folder's and
    /// its own kind, or moved from a row's menu.
    @ViewBuilder
    private func pinnedRows(_ key: FolderKey) -> some View {
        let searching = !query.isEmpty
        let sessions = SidebarSmartRow.pinned.agents(in: model.work, folders: [key], query: query)
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
        let flows = SidebarSmartRow.pinned.workflows(in: model.work, folders: [key], query: query).map(\.workflow)
        ForEach(flows) { summary in
            SidebarWorkflowRow(summary: summary, folder: key)
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

    /// The folder's name as its group in the sidebar says it: `server:Folder` on a server.
    private func place(of agent: Agent) -> String? {
        place(of: FolderKey(host: agent.host, folder: agent.folderPath))
    }

    private func place(of key: FolderKey) -> String? {
        guard let summary = folders.first(where: { $0.host == key.host && $0.folder.folder == key.folder }) else { return nil }
        return SidebarOrder.label(summary) { model.hostLabel($0) }
    }
}

/// One thing waiting for an OK under Needs You (#773), the window's `ApprovalListRow`: a
/// tap opens its Review page (#1472), pushed on an iPhone; a long press answers at once.
private struct RemoteApprovalRow: View {
    @Environment(RemoteModel.self) private var model
    let approval: Approval
    let folder: FolderKey
    let place: String?

    private var item: SidebarItem { .review(approval.id, in: folder) }

    var body: some View {
        ApprovalRowLabel(approval: approval, place: place)
            .tag(item)
            .contextMenu {
                Button("Review…", systemImage: "doc.text.magnifyingglass") { model.sidebarItem = item }
                if approval.actions.contains(.approve) {
                    Button(approval.word(for: .approve)) { answerNow(.approve) }
                }
                if approval.actions.contains(.deny) {
                    Button(approval.word(for: .deny)) { answerNow(.deny) }
                }
                if approval.actions.contains(.requestChanges) {
                    Button(approval.word(for: .requestChanges) + "…") { model.sidebarItem = item }
                }
            }
    }

    private func answerNow(_ action: Approval.Action) {
        Task { await model.settleApproval(approval, action, for: folder) }
    }
}

/// A workflow that has stopped working, under Needs You (#989), the window's
/// `FailedWorkflowRow`: a tap opens the run's agent, or the workflow when no agent ran;
/// Dismiss is a swipe and in the long press.
private struct RemoteFailedWorkflowRow: View {
    @Environment(RemoteModel.self) private var model
    let approval: Approval
    let folder: FolderKey
    let place: String?

    var body: some View {
        ApprovalRowLabel(approval: approval, place: place)
            .tag(item)
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                if approval.actions.contains(.dismiss) {
                    Button(approval.word(for: .dismiss), systemImage: "xmark") { dismissNow() }
                        .tint(.gray)
                }
            }
            .contextMenu {
                if approval.agentID != nil {
                    Button("Open Workflow", systemImage: "flowchart") { model.sidebarItem = workflow }
                }
                if approval.actions.contains(.dismiss) {
                    Button(approval.word(for: .dismiss), systemImage: "xmark") { dismissNow() }
                }
            }
    }

    private var item: SidebarItem { approval.agentID.map(SidebarItem.session) ?? workflow }

    private var workflow: SidebarItem {
        let id = model.work.workflows(in: folder.folder).first { $0.workflowID == approval.key }?.id
            ?? folder.folder.path + "/" + approval.key
        return .workflow(id, in: folder)
    }

    private func dismissNow() {
        Task { await model.settleApproval(approval, .dismiss, for: folder) }
    }
}

/// A smart group's heading: its name, and how many, the count in the attention tint for
/// Needs You and absent at none, so the heading stays put. No icon (Alex, #495): the
/// sessions under it carry the marks.
///
/// Needs You says when its count was last true while the Mac is out of reach (#1163), so
/// an old count does not pass for a live one.
private struct SmartHeading: View {
    let row: SidebarSmartRow
    let count: Int
    var updatedAt: Date?

    var body: some View {
        HStack(spacing: 6) {
            Text(row.title).lineLimit(1)
            if let updatedAt {
                Text(Self.updated(updatedAt))
                    .appText(.fine)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if count > 0 {
                Text("\(count)")
                    .monospacedDigit()
                    .foregroundStyle(row == .needsYou ? StateTint.attention.style(or: .secondary)
                                                      : AnyShapeStyle(.secondary))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([row.title, count > 0 ? "\(count)" : "none", updatedAt.map(Self.updated)]
            .compactMap { $0 }.joined(separator: ", "))
    }

    /// "Updated 14:02" today, "Updated Tue 14:02" before.
    static func updated(_ date: Date) -> String {
        Calendar.current.isDateInToday(date)
            ? "Updated \(date.formatted(date: .omitted, time: .shortened))"
            : "Updated \(date.formatted(.dateTime.weekday(.abbreviated).hour().minute()))"
    }
}

/// One folder in the sidebar (#495, #498): a group headed by its row, its pinned pages,
/// then its live sessions newest started first, their state the row's mark, then its
/// Workflows fold (#885), then one Archived row opening a page. Its pinned sessions and
/// workflows are in Pinned at the top. The Mac's `FolderFold`, drawn from the same
/// `SidebarFolderFold`.
///
/// In a folder's own scene (#1089) the same rows go under a Sessions heading: the scene
/// is the folder, so its name is the title and not a heading.
struct RemoteFolderFold: View {
    @Environment(RemoteModel.self) private var model
    let summary: DaemonAPI.FolderSummary
    let folds: SidebarFolds
    let query: String
    let label: String
    var showsAllMatches = false
    var showAllMatches: () -> Void = {}

    /// Put Files in Drop Box… from the row's menu (#231).
    @State private var fillingDropbox = false
    /// The smart groups turned off in Settings ▸ Sidebar (#846).
    @AppStorage(SidebarSmartRow.offDefaultsKey) private var smartOff = SidebarSmartRow.offAtFirst
    /// The smart groups the list draws, when not those Settings turns on (#1089).
    var smartGroups: Set<SidebarSmartRow>? = nil
    /// Drawn in a folder's own scene (#1089).
    var inScene = false

    private var key: FolderKey { summary.key }

    var body: some View {
        let fold = SidebarFolderFold(key, label: label, in: model.work, query: query, isOpen: folds.isOpen(key),
                                      keptInUnread: model.keptInUnread,
                                      on: smartGroups ?? SidebarSmartRow.on(off: smartOff))
        let isOpen = fold.isUnfolded
        if fold.isShown {
            // A search holds every match open.
            Section(isExpanded: Binding(get: { isOpen },
                                        set: { if !fold.isSearching { folds.set(key, open: $0) } })) {
                // Folded, nothing at all is under the heading (#356): see `isUnfolded`.
                if fold.showsPinnedPages {
                    PinnedPageRows(folder: key)
                    // Then its servers' list views, without a pin (#2032).
                    ServerViewRows(folder: key)
                }
                // Each under the session that started it, folded (#835). Under a Sessions
                // row, as the workflows are under theirs (#2312), unless Settings turns it
                // off; not in a folder's own scene, whose group is headed Sessions already.
                sessionsFold(fold)
                // Its workflows after the sessions (Alex, #495), in a Workflows fold of
                // their own, one level in, as a mailbox's sub-mailboxes in Mail (#885).
                if !fold.workflows.isEmpty {
                    workflowsFold(fold)
                }
                if fold.isSearching {
                    // What matched in the archive, in the group while searching, so a
                    // match is one tap away.
                    searchMatches(fold)
                } else if isOpen {
                    // Its connectors (#753), under every folder even with none yet (#1422):
                    // a page, red when one does not answer, with how many (#1569).
                    let servers = model.work.mcpServers(in: key)
                    let tally = MCPHealthWords.tally(servers)
                    FolderPageRow(title: "Connectors", systemImage: "server.rack", count: servers.count,
                                   item: .folderMCPServers(key), warns: tally?.failing ?? false,
                                   value: tally?.words ?? "none yet", showsCount: true)
                    // The archive, one row opening a page (#495): never a fold inside
                    // the group.
                    let archived = fold.archivedCount(summary) + fold.archivedWorkflows.count
                    if archived > 0 {
                        FolderPageRow(title: "Archived", systemImage: "archivebox",
                                       count: archived, item: .archive(key))
                    }
                }
            } header: {
                if inScene {
                    Text("Sessions")
                        .task(id: isOpen) {
                            if isOpen { await model.fillFolder(summary.folder.folder) }
                        }
                } else {
                    heading(isOpen)
                }
            }
            .task(id: isOpen) {
                if isOpen { _ = await model.loadArchived(in: key) }
                else { model.letGoOfArchived(in: key.folder) }
            }
        }
    }

    /// The folder's row, heading its group in the sidebar of every folder.
    private func heading(_ isOpen: Bool) -> some View {
        FolderRow(summary: summary, label: label, isFolded: !isOpen, asHeading: true)
            .foregroundStyle(model.hostIsOffline(summary.host) ? .secondary : .primary)
            .contextMenu { FolderMenuItems(summary: summary) { fillingDropbox = true } }
            .sheet(isPresented: $fillingDropbox) {
                DropboxSheet(folder: key, label: label)
            }
            .accessibilityHint(isOpen ? "Folds the folder" : "Unfolds the folder")
            // The rest of its live sessions when the first page did not hold them
            // all. On the heading, which is always there, not on every row.
            .task(id: isOpen) {
                if isOpen { await model.fillFolder(summary.folder.folder) }
            }
    }

    /// The folder's live sessions, as the Mac's `FolderFold` draws them (#2312): under a
    /// Sessions row, open until closed and kept per folder, held open by a search. The
    /// only layout (#2381); not in a folder's own scene, whose group is Sessions already.
    @ViewBuilder
    private func sessionsFold(_ fold: SidebarFolderFold) -> some View {
        let grouped = !inScene && !fold.sessions.isEmpty
        let isOpen = !grouped || fold.isSearching || folds.isOpen(key, .sessions)
        if grouped {
            SidebarFoldRow(title: "Sessions", count: fold.sessions.count, isOpen: isOpen) {
                folds.set(key, .sessions, open: !isOpen)
            }
        }
        // A closed fold has no rows at all (#237).
        ForEach(isOpen ? SidebarTree.rows(fold.sessions, in: model.work, folds: folds) : []) { row in
            SidebarSessionRow(agent: row.agent, tree: row, folds: folds, isNested: grouped)
        }
        if !fold.recentArchived.isEmpty {
            let recentOpen = fold.isSearching || folds.isOpen(key, .recentArchivedSessions)
            SidebarFoldRow(title: "Recently archived sessions", count: fold.recentArchived.count, isOpen: recentOpen) {
                folds.set(key, .recentArchivedSessions, open: !recentOpen)
            }
            ForEach(FoldedRow.rows(recentOpen ? fold.recentArchived : [], in: .recentArchivedSessions)) { row in
                SidebarSessionRow(agent: row.item, isNested: true)
            }
        }
    }

    /// The folder's live workflows, under a Workflows row with a chevron and a grey
    /// count (Alex, #885). Closed until opened, kept per folder; a search opens it to
    /// show what matched. The Mac's `FolderWorkflowRows`: a plain row rather than a
    /// `DisclosureGroup`, whose chevron the list puts at the row's end (#1079).
    @ViewBuilder
    private func workflowsFold(_ fold: SidebarFolderFold) -> some View {
        let isOpen = fold.isSearching || folds.isOpen(key, .workflows)
        SidebarFoldRow(title: "Workflows", count: fold.workflows.count, isOpen: isOpen) {
            folds.set(key, .workflows, open: !isOpen)
        }
        // A closed fold has no rows at all (#237).
        if isOpen {
            if !fold.folderWorkflows.isEmpty {
                workflowGroup("Folder workflows", rows: fold.folderWorkflows)
            }
            if !fold.userWorkflows.isEmpty {
                workflowGroup("User workflows", rows: fold.userWorkflows)
            }
        }
    }

    @ViewBuilder
    private func workflowGroup(_ title: String, rows: [WorkflowSummary]) -> some View {
        HStack(spacing: 6) {
            Text(title)
            Text("\(rows.count)").monospacedDigit()
        }
            .appText(.fine)
            .foregroundStyle(.secondary)
            .padding(.leading, 30)
        ForEach(rows) { summary in
            SidebarWorkflowRow(summary: summary, folder: key, isNested: true)
        }
    }

    /// While searching: the archived workflows and sessions that matched, after the live
    /// ones, the sessions capped until Show all (#176).
    @ViewBuilder
    private func searchMatches(_ fold: SidebarFolderFold) -> some View {
        ForEach(fold.archivedWorkflows) { summary in
            SidebarWorkflowRow(summary: summary, folder: key)
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

/// A row under a folder that opens a page about it (#495, #498): its archive. One row
/// where there used to be folds inside the folder's fold.
private struct FolderPageRow: View {
    let title: String
    let systemImage: String
    let count: Int?
    let item: SidebarItem
    /// Red when the page has something wrong to say (#753).
    var warns = false
    /// What VoiceOver says after the title, when it is not the count.
    var value: String?
    /// The count small and grey after the title (#1569), none at zero: the Connectors
    /// row's, which Alex asked to see. The Archived row's stays VoiceOver's.
    var showsCount = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .sidebarMark(warns ? StateTint.failure.style(or: .primary) : AnyShapeStyle(Paper.accent))
                .frame(width: 20)
                .accessibilityHidden(true)
            // Nothing at its end, which is only a session's (#587): the count is
            // VoiceOver's, or after the title when `showsCount`.
            Text(title)
                .lineLimit(1)
            if showsCount, let count, count > 0 {
                Text("\(count)")
                    .monospacedDigit()
                    .appText(.fine)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
        }
        .appText(.supporting)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([title, value ?? count.map(String.init)].compactMap { $0 }.joined(separator: ", "))
        .tag(item)
    }
}

/// The Workflows row of a folder's fold (#885), and its Sessions row (#2312): the chevron
/// in the session rows' mark well, the word where their titles start, and the count at the
/// end (#1079). A tap anywhere on it folds or unfolds it.
private struct SidebarFoldRow: View {
    let title: String
    let count: Int
    let isOpen: Bool
    let toggle: () -> Void

    /// The well grows with the text beside it (#750), as a session's mark does.
    @ScaledMetric private var scale: CGFloat = 1

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 10) {
                Image(systemName: "chevron.right")
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
                    .appText(.fine)
                    .foregroundStyle(.secondary)
                    .frame(width: 20 * scale)
                Text(title).lineLimit(1)
                Spacer(minLength: 4)
                Text("\(count)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .appText(.supporting)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(count)")
        .accessibilityValue(isOpen ? "open" : "folded")
        .accessibilityAddTraits(.isButton)
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
                .sidebarMark(warns ? StateTint.failure.style(or: .primary) : AnyShapeStyle(Paper.accent))
                .frame(width: 20)
                .accessibilityHidden(true)
            self
        }
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

/// A folder's long-press menu: the Mac's, less what the phone leaves to the Mac
/// (Folder Settings, Show in Finder).
private struct FolderMenuItems: View {
    @Environment(RemoteModel.self) private var model
    @State private var showingAgentConfiguration = false
    let summary: DaemonAPI.FolderSummary
    /// Files into the folder's drop box (#231), as a drag onto the Mac's row puts them.
    let putInDropbox: () -> Void

    var body: some View {
        NewSessionButton(folder: summary.folder.folder)
        // The folder alone (#1089): a scene of its own on an iPad, a screen on an iPhone.
        OpenFolderButton(key: summary.key)
        Button("Agent Configuration…", systemImage: "slider.horizontal.3") {
            showingAgentConfiguration = true
        }
        .sheet(isPresented: $showingAgentConfiguration) {
            RemoteFolderAgentConfiguration(folder: summary.folder.folder)
        }
        Button(action: putInDropbox) {
            Label("Put Files in Drop Box…", systemImage: "tray.and.arrow.down")
        }
        .disabled(model.isStale(on: summary.host))
        ShowHiddenViewsButton(summary: summary)
        // To the top of the sidebar, as the window's Pin.
        Button {
            Task { await model.setPinned(!summary.folder.isPinned, for: summary) }
        } label: {
            Label(summary.folder.isPinned ? "Unpin" : "Pin",
                  systemImage: summary.folder.isPinned ? "pin.slash" : "pin")
        }
        .disabled(model.isStale(on: summary.host))
        // Into Archived folders, asked first (#668), as the window's Archive.
        Button {
            model.askingToArchiveFolder = summary
        } label: {
            Label("Archive…", systemImage: "archivebox")
        }
        .disabled(model.isStale(on: summary.host))
        // Its agents as a .tar.gz, and an export brought back on its machine (#1001).
        ExportImportFolderButtons(summary: summary)
    }
}

/// New session in a folder: its page, the start form (029, #366).
struct NewSessionButton: View {
    @Environment(RemoteModel.self) private var model
    let folder: URL

    var body: some View {
        Button {
            model.sidebarItem = .folder(FolderKey(host: model.work.folder(folder)?.host ?? .mac, folder: folder))
        } label: {
            Label("New Session", systemImage: "plus")
        }
        .disabled(model.isStale)
    }
}

/// The first row of the sidebar (#495, #498): a new session, in the folder the last one
/// was started in, as the window's. It carries that folder's own item, which the list
/// lights while that form is open. A folder's long press starts one in that folder
/// instead.
private struct NewSessionTopRow: View {
    @Environment(RemoteModel.self) private var model

    var body: some View {
        let folder = model.newSessionFolder
        HStack(spacing: 8) {
            Image(systemName: "square.and.pencil")
                .sidebarMark(Paper.accent)
                .frame(width: 20)
                .accessibilityHidden(true)
            Text("New Session")
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .appText(.supporting)
        .foregroundStyle(model.isStale || folder == nil ? .secondary : .primary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("New Session")
        .modifier(NewSessionTag(folder: folder))
        .selectionDisabled(model.isStale || folder == nil)
    }
}

/// The row's item while there is a folder to start in; none while there is not.
private struct NewSessionTag: ViewModifier {
    let folder: FolderKey?

    func body(content: Content) -> some View {
        if let folder {
            content.tag(SidebarItem.folder(folder))
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
