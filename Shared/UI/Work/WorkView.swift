import AgentsKitCore
import SwiftUI

/// Work (#3119, spec 3100), as the web page's Work section: Issues and Pull requests from every
/// machine's forges (`forge/issues`, `forge/pulls`), one row per ref, with what lineage knows
/// (`reports/nodes`) under each title; Milestones and Releases from lineage alone. A row opens the
/// item's page; Back and Forward go along the places, as a browser's. One view for the Mac's
/// window and the Remote (#3256): on a phone the filters scroll sideways and a row wraps.
struct WorkView: View {
    let model: any WorkModel
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    var body: some View {
        let place = model.workPlace
        Group {
            if place.ref != nil {
                WorkItemPage(model: model, place: place).id(place)
            } else if place.kind == .feature {
                WorkFeaturesPane(model: model, state: model.workLists.features)
            } else if place.kind == .timeline {
                #if os(macOS)
                WorkTimelinePane(model: model, state: model.workLists.timeline)
                #endif
            } else {
                WorkListPane(model: model, kind: place.kind, list: model.workLists[place.kind]).id(place.kind)
            }
        }
        // The list's own title: its row in the sidebar chose it (#4004). On the Remote an item's
        // page says its number, *#4331*, as the bar's title (#4401).
        .navigationTitle(Self.title(place))
        #if os(iOS)
        // A phone's list has a large title (lists.md section 3); an item's page and the iPad keep it small.
        .navigationBarTitleDisplayMode(sizeClass == .compact && place.ref == nil && place.kind.fromForge ? .large : .inline)
        #endif
        .toolbar {
            // The Remote's item page has its own bar: ‹ Issues, ↑ ↓ and Open on GitHub (#4401).
            if Self.history(place) {
                ToolbarItemGroup(placement: Self.historyPlacement) {
                    Button { model.workHistory.back() } label: { Image(systemName: "chevron.left") }
                        .disabled(!model.workHistory.canGoBack)
                        .help("Back")
                    Button { model.workHistory.forward() } label: { Image(systemName: "chevron.right") }
                        .disabled(!model.workHistory.canGoForward)
                        .help("Forward")
                }
            }
        }
    }

    private static func title(_ place: WorkPlace) -> String {
        #if os(iOS)
        if let ref = place.ref { return WorkList.shortRef(ref) }
        #endif
        return place.kind.title
    }

    private static func history(_ place: WorkPlace) -> Bool {
        #if os(iOS)
        place.ref == nil
        #else
        true
        #endif
    }

    /// Back and Forward: beside the window's title on the Mac, at the bar's end on the Remote,
    /// whose start is its own way back to the sidebar.
    private static var historyPlacement: ToolbarItemPlacement {
        #if os(iOS)
        .topBarTrailing
        #else
        .navigation
        #endif
    }
}

extension WorkList.Kind {
    /// The list's row in the sidebar's Work group (#4004), in the accent as the other rows.
    var sidebarIcon: String {
        switch self {
        case .issue: "smallcircle.filled.circle"
        case .pr: "arrow.triangle.pull"
        case .feature: "sparkles"
        case .milestone: "flag"
        case .release: "shippingbox"
        case .timeline: "timeline.selection"
        }
    }

    var sidebarHelp: String {
        switch self {
        case .issue: "Every issue in your folders’ repos, and what agents spent on each"
        case .pr: "Every pull request in your folders’ repos, and what agents spent on each"
        case .feature: "Each feature label on your epics, with its epics and their leads"
        case .milestone: "The milestones lineage knows, and what their work cost"
        case .release: "The releases lineage knows, and what went into each"
        case .timeline: "Your epics in time: when each started, what closed, and when it is forecast to close"
        }
    }
}

/// One Work list: its filters, and a row per item (lists.md, #4393).
private struct WorkListPane: View {
    let model: any WorkModel
    let kind: WorkList.Kind
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var compact: Bool { sizeClass == .compact }
    #else
    private let compact = false
    @Environment(\.openSettings) private var openSettings
    #endif
    /// Back from an item's page gives the list the keys, so ↑ and ↓ go on from the row left.
    @FocusState private var focused: Bool

    /// The list's state lives in the model (#3257), so an item's page can go through it and Back finds it as it was.
    @Bindable var list: WorkListState

    private var errors: [String] {
        let machines = model.forgeMachines
        return (list.lists ?? []).flatMap { entry in
            (entry.list.errors ?? []).map { e in
                WorkList.errorWords(e, machine: machines.count > 1 ? machines.first { $0.id == entry.host }?.name : nil)
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if compact {
                filters.padding(.horizontal, 16).padding(.vertical, 6)
            } else {
                filters.padding(.horizontal, 16).padding(.vertical, 8)
                Divider()
            }
            content
        }
        #if os(iOS)
        // On a phone the search is the navigation bar's; the menus scroll under it.
        .modifier(PhoneSearch(on: compact, text: $list.filter.text, prompt: WorkLook.searchPrompt(kind)))
        #endif
        // Refresh in the toolbar; a phone has pull to refresh in its place (lists.md section 3).
        .toolbar {
            if !compact {
                ToolbarItem(placement: .primaryAction) {
                    WorkRefreshButton(running: list.lists == nil || list.loadingMore) { list.asked += 1 }
                }
            }
        }
        .workTask(id: list.ask) { await list.load(model: model) }
        .onChange(of: model.workProjects, initial: true) { _, projects in list.projects = projects }
    }

    /// The filter bar (lists.md section 1): the search field, Project, State, Repo, Label,
    /// Assignee, Board, Clear, and Sort at the trailing edge.
    private var filters: some View {
        WorkFilterBar(kind: kind, text: $list.filter.text, compact: compact) { folded in
            choices(.bar(folded: folded))
        } more: {
            choices(.more)
        } trailing: {
            WorkFilterMenu(name: "Sort", selection: $list.sort, options: kind.sorts, words: \.title, compact: compact, named: true)
        }
    }

    /// Where a filter menu is drawn: in the bar (with `folded`, only the ones set), or in More.
    private enum Place: Equatable {
        case bar(folded: Bool)
        case more

        func shows(set: Bool) -> Bool {
            switch self {
            case let .bar(folded): set || !folded
            case .more: !set
            }
        }
    }

    @ViewBuilder
    private func choices(_ place: Place) -> some View {
        let offered = WorkList.choices(list.all)
        project(place)
        if kind.fromForge, place != .more {
            WorkFilterMenu(name: "State", selection: $list.filter.state, options: kind.states, words: \.title, compact: compact)
        }
        choice("Repo", any: "All", selection: $list.filter.repo, options: offered.repos, words: WorkList.repoName, place: place)
        choice("Label", any: "Any", selection: $list.filter.label, options: offered.labels, place: place)
        if kind.fromForge {
            choice("Assignee", any: "Any", selection: $list.filter.assignee, options: offered.assignees, place: place)
        }
        #if os(macOS)
        // Boards are the Mac's and the web page's (#3282, tier Mac + web): the machines narrow to one as they read.
        if kind == .issue, !list.boards.isEmpty || !list.filter.board.isEmpty, place.shows(set: !list.filter.board.isEmpty) {
            WorkFilterMenu(name: "Board", selection: $list.filter.board, options: boardOptions, words: { WorkList.boardName($0, in: list.boards) },
                           any: "", anyWords: "All boards", inMore: place == .more)
        }
        #endif
        // On a phone the empty list's Clear filters does it (lists.md section 3).
        if !compact, place != .more, WorkLook.narrows(list.filter) {
            WorkClearButton { list.filter = WorkLook.cleared(list.filter) }
        }
    }

    #if os(macOS)
    /// The boards read, and the one picked when the machines no longer list it.
    private var boardOptions: [String] {
        let urls = list.boards.map(\.url)
        let picked = list.filter.board
        return picked.isEmpty || urls.contains(picked) ? urls : urls + [picked]
    }
    #endif

    /// The Project filter (#3283): All projects, then each project whose folders read something.
    /// With one project it is not there, so a person with one sees Work as before.
    @ViewBuilder
    private func project(_ place: Place) -> some View {
        let projects = list.projectRepos.map(\.project)
        if projects.count > 1 || !list.filter.project.isEmpty, place.shows(set: !list.filter.project.isEmpty) {
            WorkFilterMenu(name: "Project", selection: $list.filter.project, options: projects.map(\.id),
                           words: { id in projects.first { $0.id == id }?.name ?? WorkList.allProjects },
                           any: "", anyWords: WorkList.allProjects, compact: compact, inMore: place == .more)
        }
    }

    @ViewBuilder
    private func choice(_ label: String, any: String, selection: Binding<String>, options: [String],
                        words: @escaping (String) -> String = { $0 }, place: Place) -> some View {
        if !options.isEmpty || !selection.wrappedValue.isEmpty, place.shows(set: !selection.wrappedValue.isEmpty) {
            WorkFilterMenu(name: label, selection: selection, options: options, words: words, any: "", anyWords: any,
                           compact: compact, inMore: place == .more)
        }
    }

    @ViewBuilder
    private var content: some View {
        let lines = [list.problem].compactMap { $0 } + errors
        if kind.fromForge, model.forgeMachines.isEmpty {
            WorkEmptyState(symbol: kind.sidebarIcon, title: WorkLook.emptyTitle(kind, state: list.filter.state, filtered: false),
                           line: WorkList.noForgeHere)
        } else if list.lists == nil {
            // The first read: placeholder rows, no spinner in the middle.
            List { WorkPlaceholderRows() }.listStyle(.inset).disabled(true)
        } else {
            let shown = list.rows
            if shown.isEmpty {
                Group {
                    if list.all.isEmpty, !lines.isEmpty {
                        // Nothing read: what the forge said in the middle, in place of the list.
                        WorkEmptyState(symbol: "exclamationmark.triangle", title: WorkLook.couldNotRead(kind),
                                       line: lines.joined(separator: "\n"), action: (WorkLook.tryAgain, { list.asked += 1 }),
                                       also: connectors(lines))
                    } else {
                        VStack(spacing: 0) {
                            WorkErrorStrip(lines: lines) { list.asked += 1 }.padding(.horizontal, 16).padding(.top, 8)
                            empty
                        }
                    }
                }
                #if os(iOS)
                .refreshable { list.asked += 1 }
                #endif
            } else {
                rowsList(shown, lines: lines)
            }
        }
    }

    /// Settings ▸ Connectors, beside Try again, when what a forge said is about its credential.
    private func connectors(_ lines: [String]) -> (title: String, run: () -> Void)? {
        #if os(macOS)
        guard lines.contains(where: WorkLook.credentialProblem) else { return nil }
        return (WorkLook.connectors, { if model.askWorkConnectors() { openSettings() } })
        #else
        nil
        #endif
    }

    /// The empty list: "No open issues" with a line under it, or "No issues match", the filters
    /// that are set, and Clear filters.
    private var empty: some View {
        let filtered = WorkLook.narrows(list.filter)
        let set = WorkLook.setFilters(list.filter, project: list.projectRepos.first { $0.project.id == list.filter.project }?.project.name,
                                      board: list.filter.board.isEmpty ? nil : WorkList.boardName(list.filter.board, in: list.boards))
        return WorkEmptyState(symbol: kind.sidebarIcon, title: WorkLook.emptyTitle(kind, state: list.filter.state, filtered: filtered),
                              line: filtered ? set : kind.fromForge ? WorkLook.emptyLine(kind, repos: Array(Set(list.all.map(\.repo))))
                                  : WorkList.lineageOnlyNote,
                              action: filtered ? (WorkLook.clearFilters, { list.filter = WorkLook.cleared(list.filter) }) : nil)
    }

    private func open(_ ref: String) {
        list.opened = ref
        list.selected = ref
        model.showWork(WorkPlace(kind: kind, ref: ref, fromList: true))
    }

    private func rowsList(_ shown: [WorkList.Row], lines: [String]) -> some View {
        let several = Set(list.all.map(\.repo)).count > 1
        return ScrollViewReader { reader in
            selectable {
                if !lines.isEmpty {
                    WorkErrorStrip(lines: lines) { list.asked += 1 }.listRowSeparator(.hidden).selectionDisabled()
                }
                ForEach(shown) { row in
                    Button { open(row.id) } label: {
                        WorkItemRow(row: row, several: several, compact: compact, pick: pick)
                    }
                    .buttonStyle(WorkRowButtonStyle())
                    // A forge that failed leaves its rows, dimmed, under the strip (lists.md section 5).
                    .opacity(lines.isEmpty ? 1 : 0.6)
                    .id(row.id)
                    .tag(row.id)
                }
                footer(shown: shown.count)
                if !kind.fromForge {
                    Text(WorkList.lineageOnlyNote).appText(.fine).foregroundStyle(.tertiary).selectionDisabled()
                }
            }
            .listStyle(.inset)
            #if os(iOS)
            .refreshable { list.asked += 1 }
            #endif
            // Back from an item's page: the list where it was left, at the row last opened, selected.
            .onAppear {
                guard let opened = list.opened else { return }
                list.selected = opened
                reader.scrollTo(opened, anchor: .center)
                focused = !compact
            }
        }
    }

    /// The Mac's list keeps a selection that ↑ and ↓ move and Return opens; so does an iPad's with
    /// a keyboard (lists.md section 3). On a phone a tap opens the row, with no selection.
    @ViewBuilder
    private func selectable(@ViewBuilder _ rows: () -> some View) -> some View {
        #if os(macOS)
        List(selection: $list.selected) { rows() }
            .focused($focused)
            .contextMenu(forSelectionType: String.self) { _ in } primaryAction: { refs in
                if let ref = refs.first { open(ref) }
            }
        #else
        if compact {
            List { rows() }
        } else {
            // A tap goes to the row's button; Return opens the row the keys selected.
            List(selection: $list.selected) { rows() }
                .focused($focused)
                .onKeyPress(.return) {
                    guard let ref = list.selected else { return .ignored }
                    open(ref)
                    return .handled
                }
        }
        #endif
    }

    /// The end of the list (lists.md sections 2 and 5): the next page loads when this row shows,
    /// with "Loading more…"; a page that failed says so with Try again; at the end, the count.
    @ViewBuilder
    private func footer(shown: Int) -> some View {
        Group {
            if list.loadingMore {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(WorkLook.loadingMore(shown: shown))
                }
            } else if let failed = list.pageProblem {
                HStack(spacing: 8) {
                    Text(WorkLook.couldNotLoadMore).help(failed)
                    Button(WorkLook.tryAgain) { Task { await list.loadMore(model: model) } }.buttonStyle(.paper)
                }
            } else {
                Text(WorkLook.endWords(kind, shown: shown, more: list.hasMore))
            }
        }
        .appText(.fine)
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .listRowSeparator(.hidden)
        .selectionDisabled()
        // Shown, and again each time a page adds rows while it still shows: read the next page.
        .workTask(id: list.all.count) {
            guard list.hasMore, !list.loadingMore, list.pageProblem == nil else { return }
            await list.loadMore(model: model)
        }
    }

    /// A click on a chip sets the Label filter to it (Mac); on a phone a tap opens the row.
    private var pick: ((String) -> Void)? {
        #if os(macOS)
        { list.filter.label = $0 }
        #else
        nil
        #endif
    }
}

/// A row as a button: plain on the Mac, whose list draws the selection; on the Remote the row
/// shows pressed (grey) as a tap opens it (lists.md section 3).
private struct WorkRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        #if os(iOS)
        configuration.label
            .background(Color.secondary.opacity(configuration.isPressed ? 0.15 : 0).padding(.horizontal, -16).padding(.vertical, -4))
        #else
        configuration.label
        #endif
    }
}

#if os(iOS)
/// The phone's search field in the navigation bar; on an iPad the bar's own field stays.
private struct PhoneSearch: ViewModifier {
    let on: Bool
    @Binding var text: String
    let prompt: String

    func body(content: Content) -> some View {
        if on { content.searchable(text: $text, prompt: prompt) } else { content }
    }
}
#endif

/// The state as a word in a pill: open, closed, merged or draft; or the tracker's own status (a
/// Jira status, #3260), in the colour of the state it is in.
struct WorkStatePill: View {
    let state: String
    var draft = false
    var status: String?

    var body: some View {
        if !state.isEmpty {
            let word = draft && state == "open" ? "draft" : state
            Text(status ?? word)
                .appText(.fine)
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Capsule().fill(color(word)))
        }
    }

    /// The forge's own state colours, as the web page draws them: these say the item's state on
    /// its forge, not the app's (`StateTint`).
    private func color(_ word: String) -> Color {
        switch word {
        case "open": Color(red: 0x1f / 255, green: 0x88 / 255, blue: 0x3d / 255)
        case "merged": Color(red: 0x82 / 255, green: 0x50 / 255, blue: 0xdf / 255)
        case "closed": Color(red: 0xcf / 255, green: 0x22 / 255, blue: 0x2e / 255)
        default: Color(red: 0x59 / 255, green: 0x63 / 255, blue: 0x6e / 255)
        }
    }
}

#if os(macOS)
/// Work's Board menu (#3282): every board, or one of the boards of the folders' projects.
struct WorkBoardPicker: View {
    @Binding var selection: String
    let boards: [DaemonAPI.ProjectBoard]

    var body: some View {
        Picker("Board", selection: $selection) {
            Text("All").tag("")
            ForEach(boards) { Text($0.name).tag($0.url) }
            if !selection.isEmpty, !boards.contains(where: { $0.url == selection }) {
                Text(WorkList.boardName(selection, in: boards)).tag(selection)
            }
        }
        .fixedSize()
    }
}
#endif
