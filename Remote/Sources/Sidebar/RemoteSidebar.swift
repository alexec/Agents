import AgentsKitCore
import SwiftUI
import UIKit

/// The Mac's one sidebar, on an iPad or an iPhone (#226): Activity at the top, then every
/// project, each a row that folds open on its pinned pages, its sessions in their groups,
/// its archived sessions and its workflows; then the archived projects, folded, each with
/// Bring Back (#343).
///
/// The rules are the Mac's own, from `SidebarProjectFold`, `SidebarOrder` and
/// `SidebarFolds` in AgentsKitCore: the same groups, order, pins and folds, kept the same
/// way. The views are this device's: on an iPad the list sits beside what it picked; on
/// an iPhone it is the screen the app opens on and a pick is pushed over it. Swipe
/// actions and a long press stand in for the Mac's context menus.
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

    private var selection: Binding<SidebarItem?> {
        Binding(get: { model.sidebarItem },
                set: { item in
                    // A list clears its selection by itself while rows come and go, and
                    // that must not empty the detail; going back on a phone clears it
                    // through the split view's column instead.
                    if let item { model.sidebarItem = item }
                })
    }

    private var servers: [HostID] {
        model.hostSections.map(\.id).filter { $0 != .mac }
    }

    var body: some View {
        List(selection: selection) {
            if !model.projects.isEmpty {
                // Pages about all the work rather than one project, at the top so what
                // they say at a glance is never folded or scrolled away. Plain titles, as
                // on the Mac (#155).
                Section("Activity") {
                    EventsRow().appText(.supporting).tag(SidebarItem.events)
                    ResourcesRow().appText(.supporting).tag(SidebarItem.resources)
                    RuntimesRow().appText(.supporting).tag(SidebarItem.runtimes)
                    SpendingRow().appText(.supporting).tag(SidebarItem.spending)
                }
            }

            Section("Projects") {
                ForEach(SidebarOrder.projects(model.projects, servers: servers), id: \.key) { summary in
                    RemoteProjectFold(summary: summary, folds: folds, query: searched,
                                      label: SidebarOrder.label(summary) { model.hostLabel($0) },
                                      showsAllMatches: showingAllMatches.contains(summary.key),
                                      showAllMatches: { showingAllMatches.insert(summary.key) })
                }
            }

            // Projects put away, closed until opened, as the window's (#343).
            if !model.shelvedProjects.isEmpty, searched.isEmpty {
                Section(isExpanded: $showsArchived) {
                    ForEach(model.shelvedProjects, id: \.key) { summary in
                        ArchivedProjectRow(summary: summary, isDisabled: model.isStale
                                            || model.hostIsOffline(summary.host)) {
                            await model.unarchiveProject(summary)
                        }
                        .appText(.supporting)
                    }
                } header: {
                    Text("Archived projects")
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
            // (#344): the way to forget it from here.
            if !model.needsPairing {
                Section {
                    ForgetThisDeviceRow()
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(Paper.sidebar)
        .toolbarBackground(Paper.sidebar, for: .navigationBar)
        .navigationTitle("Agents")
        .searchable(text: $query, prompt: "Search sessions and workflows")
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

/// One project in the sidebar: its row, and folded under it its pinned pages and
/// sessions, then its archived sessions and its workflows. The Mac's `ProjectFold`, drawn
/// from the same `SidebarProjectFold`.
private struct RemoteProjectFold: View {
    @Environment(RemoteModel.self) private var model
    let summary: DaemonAPI.ProjectSummary
    let folds: SidebarFolds
    let query: String
    let label: String
    var showsAllMatches = false
    var showAllMatches: () -> Void = {}

    private var key: ProjectKey { summary.key }

    var body: some View {
        let fold = SidebarProjectFold(key, label: label, in: model.work, query: query, isOpen: folds.isOpen(key))
        let isOpen = fold.isUnfolded
        if fold.isShown {
            DisclosureGroup(isExpanded: Binding(get: { isOpen }, set: { folds.set(key, open: $0) })) {
                // Folded, nothing at all is under the row (#356): see `isUnfolded`.
                if fold.showsPinnedPages {
                    PinnedPageRows(project: key)
                }
                if !fold.pinned.isEmpty {
                    pinnedSessions(fold)
                }
                ForEach(fold.groups) { part in
                    sessionGroup(part, searching: fold.isSearching)
                }
                if fold.showsNoSessions {
                    Text("No sessions yet")
                        .appText(.fine)
                        .foregroundStyle(.secondary)
                }
                archivedSessions(fold)
                workflows(fold)
            } label: {
                ProjectRow(summary: summary, label: label, isFolded: !isOpen)
                    .appText(.supporting)
                    .foregroundStyle(model.hostIsOffline(summary.host) ? .secondary : .primary)
                    .contextMenu { ProjectMenuItems(summary: summary) }
                    .swipeActions(edge: .leading) {
                        NewSessionButton(folder: summary.folder).tint(Paper.accent)
                    }
                    .tag(SidebarItem.project(key))
            }
            // The rest of its live sessions when the first page did not hold them all.
            .task(id: isOpen) {
                if isOpen { await model.fillProject(summary.folder) }
            }
        }
    }

    /// One group of sessions, folding at its heading (#181).
    private func sessionGroup(_ part: SidebarProjectFold.Group, searching: Bool) -> some View {
        let group = part.group
        let isOpen = searching || folds.isOpen(key, .group(group))
        return DisclosureGroup(isExpanded: Binding(get: { isOpen },
                                                   set: { folds.set(key, .group(group), open: $0) })) {
            ForEach(part.agents) { agent in
                SidebarSessionRow(agent: agent)
            }
        } label: {
            SidebarSubheading(title: part.heading.title, count: part.agents.count, unread: part.unread,
                              tint: !isOpen && group == .needsAttention ? .attention : .none)
        }
    }

    /// The pinned sessions (#180), folding as a group does, in the order they were put in:
    /// dragged into another in the list's edit mode, or moved from a row's menu.
    private func pinnedSessions(_ fold: SidebarProjectFold) -> some View {
        let pinned = fold.pinned
        let searching = fold.isSearching
        let isOpen = searching || folds.isOpen(key, .pinned)
        return DisclosureGroup(isExpanded: Binding(get: { isOpen }, set: { folds.set(key, .pinned, open: $0) })) {
            ForEach(pinned) { agent in
                SidebarSessionRow(agent: agent)
            }
            .onMove { from, to in
                guard !searching else { return }
                var ids = pinned.map(\.id)
                ids.move(fromOffsets: from, toOffset: to)
                let shown = Set(ids)
                let rest = model.pinnedSessions(in: key.folder).filter { !shown.contains($0) }
                Task { await model.arrangeSessionPins(ids + rest, in: key.folder) }
            }
        } label: {
            SidebarSubheading(title: "Pinned", count: pinned.count,
                              unread: pinned.count(where: \.showsUnread),
                              tint: !isOpen && fold.pinnedWantsAPerson(in: model.work) ? .attention : .none)
        }
    }

    /// Archived sessions, folded under the live ones, a page of them held while the fold
    /// is open (#165), with what has been retired from here (051) as the last line.
    @ViewBuilder
    private func archivedSessions(_ fold: SidebarProjectFold) -> some View {
        let isOpen = fold.isSearching || folds.isOpen(key, .archivedSessions)
        if fold.showsArchivedFold(summary) {
            DisclosureGroup(isExpanded: Binding(get: { isOpen },
                                                set: { folds.set(key, .archivedSessions, open: $0) })) {
                let shown = fold.archivedShown(showingAll: showsAllMatches)
                ForEach(shown) { agent in
                    SidebarSessionRow(agent: agent)
                }
                if fold.isSearching, fold.archived.count > shown.count {
                    Button("Show all \(fold.archived.count)", action: showAllMatches)
                        .appText(.fine)
                        .foregroundStyle(.secondary)
                }
                if let line = fold.retiredLine(summary) {
                    Text(line)
                        .appText(.fine)
                        .foregroundStyle(.secondary)
                }
            } label: {
                SidebarSubheading(title: "Archived sessions", count: fold.archivedCount(summary))
            }
            .task(id: !fold.isSearching && isOpen) {
                if !fold.isSearching && isOpen {
                    await model.loadArchived(in: key.folder)
                } else if !fold.isSearching {
                    model.letGoOfArchived(in: key.folder)
                }
            }
        }
    }

    /// The project's workflows, and its archived ones folded at their foot.
    @ViewBuilder
    private func workflows(_ fold: SidebarProjectFold) -> some View {
        if !fold.workflows.isEmpty || !fold.archivedWorkflows.isEmpty {
            DisclosureGroup(isExpanded: Binding(get: { fold.isSearching || folds.isOpen(key, .workflows) },
                                                set: { folds.set(key, .workflows, open: $0) })) {
                ForEach(fold.workflows) { summary in
                    SidebarWorkflowRow(summary: summary, project: key)
                }
            } label: {
                SidebarSubheading(title: "Workflows", count: fold.workflows.count)
            }
            if !fold.archivedWorkflows.isEmpty {
                DisclosureGroup(isExpanded: Binding(get: { fold.isSearching || folds.isOpen(key, .archivedWorkflows) },
                                                    set: { folds.set(key, .archivedWorkflows, open: $0) })) {
                    ForEach(fold.archivedWorkflows) { summary in
                        SidebarWorkflowRow(summary: summary, project: key)
                    }
                } label: {
                    SidebarSubheading(title: "Archived workflows", count: fold.archivedWorkflows.count)
                }
            }
        }
    }
}

/// A group within a project's fold, with how many under it are unread (#70). Folded, a
/// Needs you group keeps its count in the attention tint. The Mac's `SidebarSubheading`.
struct SidebarSubheading: View {
    let title: String
    let count: Int
    var unread: Int = 0
    var tint: StateTint = .none

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
            Text("\(count)").monospacedDigit().foregroundStyle(tint.style(or: .tertiary))
            if unread > 0 {
                Text("· \(unread) unread").monospacedDigit()
            }
        }
        .appText(.fine)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(unread > 0 ? "\(title), \(count), \(unread) unread" : "\(title), \(count)")
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
/// (Project Settings, Archive, Show in Finder).
private struct ProjectMenuItems: View {
    @Environment(RemoteModel.self) private var model
    let summary: DaemonAPI.ProjectSummary

    var body: some View {
        NewSessionButton(folder: summary.folder)
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

/// The Runtimes row under Activity, with the Mac's dot when a runtime is out (065).
private struct RuntimesRow: View {
    @Environment(RemoteModel.self) private var model

    var body: some View {
        HStack {
            Text("Runtimes")
            Spacer()
            if model.runtimeAllowances?.anyOut == true {
                Circle().fill(StateTint.failure.style(or: .primary)).frame(width: 7, height: 7)
                    .accessibilityLabel("A runtime is out")
            }
        }
        .accessibilityHint("Opens Runtimes")
    }
}
