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
    private var compact: Bool { sizeClass == .compact }
    #else
    private let compact = false
    #endif

    var body: some View {
        let place = model.workPlace
        Group {
            if place.ref != nil {
                WorkItemPage(model: model, place: place).id(place)
            } else {
                WorkListPane(model: model, kind: place.kind).id(place.kind)
            }
        }
        .navigationTitle(place.ref == nil ? "Work" : place.kind.title)
        .toolbar {
            ToolbarItemGroup(placement: Self.historyPlacement) {
                Button { model.workHistory.back() } label: { Image(systemName: "chevron.left") }
                    .disabled(!model.workHistory.canGoBack)
                    .help("Back")
                Button { model.workHistory.forward() } label: { Image(systemName: "chevron.right") }
                    .disabled(!model.workHistory.canGoForward)
                    .help("Forward")
            }
            ToolbarItem(placement: .principal) {
                Picker("Show", selection: Binding(get: { place.kind }, set: { model.showWork(WorkPlace(kind: $0)) })) {
                    ForEach(WorkList.Kind.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .workKindPickerStyle(compact: compact)
                .fixedSize()
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

private extension View {
    /// Work's kinds as segments, or as a menu where a phone has no room for four.
    @ViewBuilder
    func workKindPickerStyle(compact: Bool) -> some View {
        if compact { pickerStyle(.menu) } else { pickerStyle(.segmented) }
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

    @State private var filter = WorkList.Filter()
    @State private var sort = WorkList.Sort.updated
    @State private var lists: [(host: MachineRef, list: DaemonAPI.ForgeList)]?
    @State private var lineage: [DaemonAPI.ReportNode] = []
    @State private var lineageCursor: String?
    @State private var problem: String?
    @State private var loadingMore = false
    @State private var asked = 0

    /// How many pages of `reports/nodes` a list reads for its lineage: at most 500 nodes.
    private static let lineagePages = 5

    /// An issue's or a PR's lineage is joined by ref, in any order; a milestone's or a release's list is lineage's own.
    private var nodesSort: DaemonAPI.ReportNodesSort { !kind.fromForge && sort == .cost ? .cost : .newest }

    private var all: [WorkList.Row] {
        kind.fromForge ? WorkList.merge((lists ?? []).map { (host: $0.host, items: $0.list.items) }, lineage: lineage)
            : lineage.map(WorkList.Row.init)
    }

    private var rows: [WorkList.Row] {
        var f = filter
        // Milestones and releases have no state in v1.
        if !kind.fromForge { f.state = .all }
        return WorkList.sort(WorkList.filter(all, f), by: sort)
    }

    private var errors: [String] {
        let machines = model.forgeMachines
        return (lists ?? []).flatMap { entry in
            (entry.list.errors ?? []).map { e in
                WorkList.errorWords(e, machine: machines.count > 1 ? machines.first { $0.id == entry.host }?.name : nil)
            }
        }
    }

    private var hasMore: Bool { kind.fromForge ? (lists ?? []).contains { $0.list.cursor != nil } : lineageCursor != nil }

    var body: some View {
        VStack(spacing: 0) {
            filters.padding(.horizontal, 16).padding(.vertical, 8)
            Divider()
            content
        }
        .task(id: Ask(state: filter.state.forge, sort: nodesSort, asked: asked)) { await load() }
    }

    private struct Ask: Equatable {
        var state: String
        var sort: DaemonAPI.ReportNodesSort
        var asked: Int
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
                Button("Refresh") { asked += 1 }
                    .linkStyle()
            }
        }
    }

    private var filterField: some View {
        TextField("Filter", text: $filter.text)
            .textFieldStyle(.roundedBorder)
            .accessibilityLabel("Filter by words")
    }

    @ViewBuilder
    private var choices: some View {
        let offered = WorkList.choices(all)
        if kind.fromForge {
            named("State", filter.state.title) {
                Picker("State", selection: $filter.state) {
                    ForEach(kind.states, id: \.self) { Text($0.title).tag($0) }
                }
            }
        }
        choice("Repo", any: "All", selection: $filter.repo, options: offered.repos, words: WorkList.repoName)
        choice("Label", any: "Any", selection: $filter.label, options: offered.labels)
        if kind.fromForge {
            choice("Assignee", any: "Any", selection: $filter.assignee, options: offered.assignees)
        }
        named("Sort", sort.title) {
            Picker("Sort", selection: $sort) {
                ForEach(kind.sorts, id: \.self) { Text($0.title).tag($0) }
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
        } else if lists == nil {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let shown = rows
            let several = Set(all.map(\.repo)).count > 1
            List {
                ForEach([problem].compactMap { $0 } + errors, id: \.self) { line in
                    Label(line, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                }
                if shown.isEmpty {
                    Text(WorkList.noWork(kind)).foregroundStyle(.secondary)
                }
                ForEach(shown) { row in
                    Button { model.showWork(WorkPlace(kind: kind, ref: row.id)) } label: {
                        WorkRowView(row: row, several: several, compact: compact)
                    }
                    .buttonStyle(.plain)
                }
                if hasMore {
                    Button(loadingMore ? "Loading…" : "More") { Task { await loadMore() } }
                        .linkStyle()
                        .disabled(loadingMore)
                }
                if !kind.fromForge {
                    Text(WorkList.lineageOnlyNote).appText(.fine).foregroundStyle(.tertiary)
                }
            }
            .listStyle(.inset)
            #if os(iOS)
            .refreshable { asked += 1 }
            #endif
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

    /// The lineage of the kind, at most `lineagePages` pages; none from a control plane that does not list nodes.
    private func readLineage(from cursor: String? = nil) async throws -> (nodes: [DaemonAPI.ReportNode], cursor: String?) {
        var nodes: [DaemonAPI.ReportNode] = []
        var next = cursor
        for _ in 0 ..< Self.lineagePages {
            guard let page = try await model.reportNodes(.init(kind: kind.rawValue, sort: nodesSort, cursor: next, limit: 100)) else {
                return (nodes, nil)
            }
            nodes += page.nodes
            next = page.cursor
            if next == nil || !kind.fromForge { break }
        }
        return (nodes, next)
    }

    private func load() async {
        lists = nil
        lineage = []
        problem = nil
        do {
            let known = try await readLineage()
            guard !Task.isCancelled else { return }
            lineage = known.nodes
            lineageCursor = known.cursor
        } catch {
            guard !Task.isCancelled else { return }
            // A control plane that does not list nodes yet leaves the issues and PRs without figures.
            if !kind.fromForge { problem = ReportValueWords.sentence(error) }
        }
        guard kind.fromForge else { lists = []; return }
        let state = filter.state.forge
        var read: [(host: MachineRef, list: DaemonAPI.ForgeList)] = []
        await withTaskGroup(of: (MachineRef, DaemonAPI.ForgeList).self) { group in
            for machine in model.forgeMachines {
                group.addTask {
                    do {
                        return (machine.id, try await model.forgeList(kind, .init(state: state, limit: 100), on: machine.id))
                    } catch {
                        return (machine.id, .init(errors: [.init(forge: "", message: error.localizedDescription)]))
                    }
                }
            }
            for await (host, list) in group { read.append((host, list)) }
        }
        guard !Task.isCancelled else { return }
        lists = read
    }

    private func loadMore() async {
        loadingMore = true
        defer { loadingMore = false }
        do {
            if kind.fromForge {
                var next: [(host: MachineRef, list: DaemonAPI.ForgeList)] = []
                for entry in lists ?? [] {
                    guard let cursor = entry.list.cursor else { next.append(entry); continue }
                    let page = try await model.forgeList(kind, .init(state: filter.state.forge, cursor: cursor, limit: 100),
                                                         on: entry.host)
                    next.append((entry.host, .init(items: entry.list.items + page.items, cursor: page.cursor, errors: page.errors)))
                }
                lists = next
            } else if let cursor = lineageCursor {
                let page = try await readLineage(from: cursor)
                lineage += page.nodes
                lineageCursor = page.cursor
            }
        } catch {
            problem = ReportValueWords.sentence(error)
        }
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
                Text(row.title).fontWeight(.semibold).lineLimit(2)
            }
            WrappingHStack(spacing: 4) {
                WorkStatePill(state: row.state, draft: row.draft)
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
                Text(row.title).fontWeight(.semibold).lineLimit(1)
                WorkStatePill(state: row.state, draft: row.draft)
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

/// The state as a word in a pill: open, closed, merged or draft.
struct WorkStatePill: View {
    let state: String
    var draft = false

    var body: some View {
        if !state.isEmpty {
            let word = draft && state == "open" ? "draft" : state
            Text(word)
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
