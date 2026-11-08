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
        }
    }

    var sidebarHelp: String {
        switch self {
        case .issue: "Every issue in your folders’ repos, and what agents spent on each"
        case .pr: "Every pull request in your folders’ repos, and what agents spent on each"
        case .feature: "Each feature label on your epics, with its epics and their leads"
        case .milestone: "The milestones lineage knows, and what their work cost"
        case .release: "The releases lineage knows, and what went into each"
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
            filters.padding(.horizontal, 16).padding(.vertical, 8)
            Divider()
            content
        }
        .workTask(id: list.ask) { await list.load(model: model) }
        .onChange(of: model.workProjects, initial: true) { _, projects in list.projects = projects }
    }

    /// One row of them on the Mac and an iPad; on a phone the choices scroll sideways over
    /// the words to filter by.
    @ViewBuilder
    private var filters: some View {
        if compact {
            VStack(alignment: .leading, spacing: 8) {
                ScrollView(.horizontal) {
                    HStack(spacing: 12) { choices }
                }
                .scrollIndicators(.hidden)
                filterField
            }
        } else {
            HStack(spacing: 12) {
                choices
                filterField
                Button("Refresh") { list.asked += 1 }
                    .linkStyle()
            }
        }
    }

    private var filterField: some View {
        TextField("Filter", text: $list.filter.text)
            .textFieldStyle(.roundedBorder)
            .accessibilityLabel("Filter by words")
    }

    @ViewBuilder
    private var choices: some View {
        let offered = WorkList.choices(list.all)
        if kind.fromForge {
            named("State", list.filter.state.title) {
                Picker("State", selection: $list.filter.state) {
                    ForEach(kind.states, id: \.self) { Text($0.title).tag($0) }
                }
            }
        }
        project
        choice("Repo", any: "All", selection: $list.filter.repo, options: offered.repos, words: WorkList.repoName)
        choice("Label", any: "Any", selection: $list.filter.label, options: offered.labels)
        if kind.fromForge {
            choice("Assignee", any: "Any", selection: $list.filter.assignee, options: offered.assignees)
        }
        #if os(macOS)
        // Boards are the Mac's and the web page's (#3282, tier Mac + web): the machines narrow to one as they read.
        if kind == .issue, !list.boards.isEmpty || !list.filter.board.isEmpty {
            WorkBoardPicker(selection: $list.filter.board, boards: list.boards)
        }
        #endif
        named("Sort", list.sort.title) {
            Picker("Sort", selection: $list.sort) {
                ForEach(kind.sorts, id: \.self) { Text($0.title).tag($0) }
            }
        }
    }

    /// The Project filter (#3283): All projects, then each project whose folders read something.
    /// With one project it is not there, so a person with one sees Work as before.
    @ViewBuilder
    private var project: some View {
        let projects = list.projectRepos.map(\.project)
        let picked = list.filter.project
        if projects.count > 1 || !picked.isEmpty {
            let name = picked.isEmpty ? WorkList.allProjects : projects.first { $0.id == picked }?.name ?? WorkList.allProjects
            named("Project", name) {
                Picker("Project", selection: $list.filter.project) {
                    Text(WorkList.allProjects).tag("")
                    ForEach(projects) { Text($0.name).tag($0.id) }
                }
            }
        }
    }

    @ViewBuilder
    private func choice(_ label: String, any: String, selection: Binding<String>, options: [String],
                        words: @escaping (String) -> String = { $0 }) -> some View {
        if !options.isEmpty || !selection.wrappedValue.isEmpty {
            let value = selection.wrappedValue
            named(label, value.isEmpty ? any : words(value)) {
                Picker(label, selection: selection) {
                    Text(any).tag("")
                    ForEach(options, id: \.self) { Text(words($0)).tag($0) }
                }
            }
        }
    }

    /// A choice as the Mac draws it, its name beside its menu; on the Remote, whose menu shows
    /// only the value, a button that says both ("Label: Any") and opens the choices.
    @ViewBuilder
    private func named(_ label: String, _ value: String, @ViewBuilder picker: () -> some View) -> some View {
        #if os(iOS)
        Menu { picker() } label: {
            Text("\(label): \(value)").appText(.supporting).lineLimit(1)
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .fixedSize()
        #else
        picker().fixedSize()
        #endif
    }

    @ViewBuilder
    private var content: some View {
        if kind.fromForge, model.forgeMachines.isEmpty {
            message(WorkList.noForgeHere)
        } else if list.lists == nil {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let shown = list.rows
            let several = Set(list.all.map(\.repo)).count > 1
            ScrollViewReader { reader in
                List {
                    ForEach([list.problem].compactMap { $0 } + errors, id: \.self) { line in
                        Label(line, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                    }
                    if shown.isEmpty {
                        Text(WorkList.noWork(kind)).foregroundStyle(.secondary)
                    }
                    ForEach(shown) { row in
                        Button {
                            list.opened = row.id
                            model.showWork(WorkPlace(kind: kind, ref: row.id, fromList: true))
                        } label: {
                            WorkRowView(row: row, several: several, compact: compact)
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
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .appText(.supporting)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A row: its short ref, title, state and labels, and what lineage knows about it.
private struct WorkRowView: View {
    let row: WorkList.Row
    let several: Bool
    var compact = false

    var body: some View {
        if compact { stacked } else { inline }
    }

    /// On a phone: the title on lines of its own, its state and labels wrapping under it.
    private var stacked: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if !WorkList.titleSaysRef(row.title, row.node.ref) {
                    Text(WorkList.shortRef(row.node.ref)).foregroundStyle(.tint).monospacedDigit()
                }
                Text.forgeTitle(row.title).fontWeight(.semibold).lineLimit(2)
            }
            WrappingHStack(spacing: 4) {
                WorkStatePill(state: row.state, draft: row.draft, status: row.status)
                ForEach(row.labels, id: \.name) { WorkLabelChip(label: $0) }
                if several {
                    Text(WorkList.repoName(row.repo)).appText(.fine).foregroundStyle(.secondary)
                }
            }
            figures
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }

    private var figures: some View {
        let figures = WorkList.lineageWords(row.lineage)
        return Text(figures ?? WorkList.noAgentYet)
            .appText(.fine)
            .foregroundStyle(figures == nil ? .tertiary : .secondary)
            .monospacedDigit()
    }

    private var inline: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if !WorkList.titleSaysRef(row.title, row.node.ref) {
                    Text(WorkList.shortRef(row.node.ref)).foregroundStyle(.tint).monospacedDigit()
                }
                Text.forgeTitle(row.title).fontWeight(.semibold).lineLimit(1)
                WorkStatePill(state: row.state, draft: row.draft, status: row.status)
                ForEach(row.labels, id: \.name) { WorkLabelChip(label: $0) }
                if several {
                    Text(WorkList.repoName(row.repo)).appText(.fine).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            figures
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }
}

/// A label in its forge's colour (#2956).
struct WorkLabelChip: View {
    let label: DaemonAPI.ForgeLabel

    var body: some View {
        let rgb = WorkList.rgb(label.color)
        Text(label.name)
            .appText(.fine)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .foregroundStyle(rgb == nil ? Color.primary : WorkList.isLight(label.color) ? Color.black : Color.white)
            .background(Capsule().fill(rgb.map { c in Color(red: c.r, green: c.g, blue: c.b) } ?? Color.clear))
            .overlay(Capsule().strokeBorder(rgb == nil ? Color.secondary.opacity(0.4) : Color.clear))
    }
}

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
