import AgentsKitCore
import SwiftUI

/// Work (#3119, spec 3100), as the web page's Work section: Issues and Pull requests from every
/// machine's forges (`forge/issues`, `forge/pulls`), one row per ref, with what lineage knows
/// (`reports/nodes`) under each title; Milestones and Releases from lineage alone. A row opens the
/// item's page; Back and Forward go along the places, as a browser's. One view for the Mac's
/// window and the Remote (#3256): on a phone the filters scroll sideways and a row wraps.
struct WorkView: View {
    let model: any WorkModel

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
        // The list's own title: its row in the sidebar chose it (#4004).
        .navigationTitle(place.kind.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
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

/// One Work list: its filters, and a row per item.
private struct WorkListPane: View {
    let model: any WorkModel
    let kind: WorkList.Kind
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var compact: Bool { sizeClass == .compact }
    #else
    private let compact = false
    #endif

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
        #else
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                WorkRefreshButton(running: list.lists == nil || list.loadingMore) { list.asked += 1 }
            }
        }
        #endif
        .workTask(id: list.ask) { await list.load(model: model) }
        .onChange(of: model.workProjects, initial: true) { _, projects in list.projects = projects }
    }

    /// The filter bar (#4391): the search field, then a compact menu per filter. Project and
    /// Board come first and last, where they show.
    private var filters: some View {
        WorkFilterBar(kind: kind, text: $list.filter.text, compact: compact) { choices }
    }

    @ViewBuilder
    private var choices: some View {
        let offered = WorkList.choices(list.all)
        project
        if kind.fromForge {
            WorkFilterMenu(name: "State", selection: $list.filter.state, options: kind.states, words: \.title, compact: compact)
        }
        choice("Repo", any: "All", selection: $list.filter.repo, options: offered.repos, words: WorkList.repoName)
        choice("Label", any: "Any", selection: $list.filter.label, options: offered.labels)
        if kind.fromForge {
            choice("Assignee", any: "Any", selection: $list.filter.assignee, options: offered.assignees)
        }
        WorkFilterMenu(name: "Sort", selection: $list.sort, options: kind.sorts, words: \.title, compact: compact, named: true)
        #if os(macOS)
        // Boards are the Mac's and the web page's (#3282, tier Mac + web): the machines narrow to one as they read.
        if kind == .issue, !list.boards.isEmpty || !list.filter.board.isEmpty {
            WorkFilterMenu(name: "Board", selection: $list.filter.board, options: boardOptions, words: { WorkList.boardName($0, in: list.boards) },
                           any: "", anyWords: "All")
        }
        #endif
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
    private var project: some View {
        let projects = list.projectRepos.map(\.project)
        if projects.count > 1 || !list.filter.project.isEmpty {
            WorkFilterMenu(name: "Project", selection: $list.filter.project, options: projects.map(\.id),
                           words: { id in projects.first { $0.id == id }?.name ?? WorkList.allProjects },
                           any: "", anyWords: WorkList.allProjects, compact: compact)
        }
    }

    @ViewBuilder
    private func choice(_ label: String, any: String, selection: Binding<String>, options: [String],
                        words: @escaping (String) -> String = { $0 }) -> some View {
        if !options.isEmpty || !selection.wrappedValue.isEmpty {
            WorkFilterMenu(name: label, selection: selection, options: options, words: words, any: "", anyWords: any, compact: compact)
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
                VStack(spacing: 0) {
                    if list.all.isEmpty, !lines.isEmpty {
                        // Nothing read: the strip in the middle, in place of the list.
                        WorkErrorStrip(lines: lines) { list.asked += 1 }
                            .frame(maxWidth: 640)
                            .padding(24)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        WorkErrorStrip(lines: lines) { list.asked += 1 }.padding(.horizontal, 16).padding(.top, 8)
                        empty
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

    /// The empty list: "No open issues" with a line under it, or "No issues match" with Clear filters.
    private var empty: some View {
        let filtered = WorkLook.narrows(list.filter)
        return WorkEmptyState(symbol: kind.sidebarIcon, title: WorkLook.emptyTitle(kind, state: list.filter.state, filtered: filtered),
                              line: filtered ? nil : kind.fromForge ? WorkLook.emptyLine(kind, repos: Array(Set(list.all.map(\.repo))))
                                  : WorkList.lineageOnlyNote,
                              action: filtered ? (WorkLook.clearFilters, { list.filter = WorkLook.cleared(list.filter) }) : nil)
    }

    private func rowsList(_ shown: [WorkList.Row], lines: [String]) -> some View {
        let several = Set(list.all.map(\.repo)).count > 1
        return ScrollViewReader { reader in
            List {
                if !lines.isEmpty {
                    WorkErrorStrip(lines: lines) { list.asked += 1 }.listRowSeparator(.hidden)
                }
                ForEach(shown) { row in
                    Button {
                        list.opened = row.id
                        model.showWork(WorkPlace(kind: kind, ref: row.id, fromList: true))
                    } label: {
                        WorkItemRow(row: row, several: several, compact: compact, pick: pick)
                    }
                    .buttonStyle(.plain)
                    .id(row.id)
                }
                if list.hasMore {
                    Button(list.loadingMore ? "Loading…" : "More") { Task { await list.loadMore(model: model) } }
                        .linkStyle()
                        .disabled(list.loadingMore)
                }
                if !kind.fromForge {
                    Text(WorkList.lineageOnlyNote).appText(.fine).foregroundStyle(.tertiary)
                }
            }
            .listStyle(.inset)
            #if os(iOS)
            .refreshable { list.asked += 1 }
            #endif
            // Back from an item's page: the list where it was left, at the row last opened.
            .onAppear { if let opened = list.opened { reader.scrollTo(opened, anchor: .center) } }
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
