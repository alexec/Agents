import AgentsKitCore
import Observation
import SwiftUI

/// Work ▸ Features's state (#3269, #4587): the features of every machine's forges and the open
/// pull requests. A machine with `work.features/1` (#4586) gives each feature with its open epics,
/// their places and their children, and its loose issues, in one read (`work/features`). An older
/// one gives the features (`forge/features`); then, for each feature open, its open issues
/// (`forge/issues` with the feature), and each open epic's plan (`forge/plan`) and forecast
/// (`lineage/forecast`) (features-delivery.md note 16). The model keeps it, so Back from an
/// epic's page finds the list as it was left.
@MainActor
@Observable
final class WorkFeaturesState {
    var features: [DaemonAPI.ForgeFeature]?
    /// The open pull requests labelled needs-approval, of every machine (#4115).
    var approvals: [String] = []
    var errors: [String] = []
    /// The features a person opened (true) or folded (false), by name in lower case; the others
    /// are as their group starts them (note 3).
    var picked: [String: Bool] = [:]
    /// The groups a person opened or closed (#3741, #4115). Each is open until closed, except
    /// Finished, which is closed until opened, unless every feature is in it.
    var groupOpen: [WorkFeatures.Group: Bool] = [:]
    /// A feature's open epics and issues, by name in lower case; absent while they are read.
    var items: [String: [DaemonAPI.ForgeItem]] = [:]
    var itemErrors: [String: [String]] = [:]
    /// An open epic's children and where it is, by its ref; absent while it is read (state 13).
    var places: [String: WorkFeatures.Place] = [:]
    /// The epics whose plan could not be read.
    var unread: Set<String> = []
    /// The children `work/features` says wait for the person, by ref.
    var waiting: Set<String> = []
    /// The open pull requests of every machine, by the label a lane gives each (*P#45*).
    var pulls: [String: DaemonAPI.ForgeItem] = [:]
    var asked = 0
    /// The board the epics are narrowed to (#3282), by its url; "" for every board.
    var board = ""
    /// The boards the Board menu offers, read with the features.
    var boards: [DaemonAPI.ProjectBoard] = []
    private var read: Ask?
    /// What the machines with `work/features` gave each feature, by name in lower case.
    private var oneRead: [String: [DaemonAPI.ForgeItem]] = [:]
    /// The machines with no `work/features`, whose features are read issue by issue.
    private var older: [(id: MachineRef, name: String)] = []

    private struct Ask: Equatable {
        var asked: Int
        var board: String
    }

    private var ask: Ask { Ask(asked: asked, board: board) }

    /// Whether a feature is open: as a person left it, else as its group starts it (note 3).
    func isOpen(_ name: String, in group: WorkFeatures.Group, of groups: [WorkFeatures.Group]) -> Bool {
        picked[name.lowercased()] ?? WorkFeatures.startsOpen(group, in: groups)
    }

    private enum Answer: Sendable {
        case one(DaemonAPI.WorkFeatures)
        case features(DaemonAPI.ForgeFeatures)
    }

    /// Read the features, unless they were read for this Refresh and board already; then, from an
    /// older machine, the issues and plans of the features that are open.
    func load(model: any WorkModel) async {
        let mine = ask
        guard read != mine || features == nil else { return }
        read = mine
        features = nil
        approvals = []
        errors = []
        items = [:]
        itemErrors = [:]
        places = [:]
        unread = []
        waiting = []
        pulls = [:]
        oneRead = [:]
        let board = board
        let found = await model.workBoards()
        guard ask == mine else { return }
        boards = found
        let machines = model.workMachines(board: board)
        let reads = Set(model.featuresMachines.map(\.id))
        older = machines.filter { !reads.contains($0.id) }
        var got: [(host: MachineRef, answer: Answer)] = []
        var prs: [DaemonAPI.ForgeItem] = []
        let narrow = board.isEmpty ? nil : board
        await withTaskGroup(of: (MachineRef, Answer, [DaemonAPI.ForgeItem]).self) { group in
            for machine in machines {
                let one = reads.contains(machine.id)
                group.addTask {
                    // The open pull requests say what works on a child and its checks (note 8).
                    async let open = try? model.forgeList(.pr, .init(state: "open", limit: 100), on: machine.id)
                    let answer: Answer
                    do {
                        answer = one
                            ? .one(try await model.forge(DaemonAPI.Method.workFeatures, DaemonAPI.WorkFeaturesRequest(board: narrow),
                                                         returning: DaemonAPI.WorkFeatures.self, on: machine.id))
                            : .features(try await model.forge(DaemonAPI.Method.forgeFeatures,
                                                              DaemonAPI.ForgeFeaturesRequest(board: narrow),
                                                              returning: DaemonAPI.ForgeFeatures.self, on: machine.id))
                    } catch {
                        answer = .features(.init(errors: [.init(forge: "", message: error.localizedDescription)]))
                    }
                    return (machine.id, answer, await open?.items ?? [])
                }
            }
            for await (host, answer, open) in group {
                got.append((host, answer))
                prs += open
            }
        }
        guard ask == mine else { return }
        var lists: [[DaemonAPI.ForgeFeature]] = []
        var ones: [DaemonAPI.WorkFeatures] = []
        for entry in got {
            let machine = machines.count > 1 ? machines.first { $0.id == entry.host }?.name : nil
            let (found, approved, problems): ([DaemonAPI.ForgeFeature], [String]?, [DaemonAPI.ForgeListError]?)
            switch entry.answer {
            case let .one(one):
                ones.append(one)
                (found, approved, problems) = (one.features.map(\.feature), one.approvals, one.errors)
            case let .features(list):
                (found, approved, problems) = (list.features, list.approvals, list.errors)
            }
            lists.append(found)
            approvals += approved ?? []
            errors += (problems ?? []).map { WorkList.errorWords($0, machine: machine) }
        }
        let one = WorkFeatures.read(ones)
        oneRead = one.items
        places = one.places
        unread = one.unread
        waiting = one.waiting
        let merged = WorkFeatures.merge(lists)
        // With every machine on `work/features`, every feature is read: an open one draws at once.
        if older.isEmpty {
            items = Dictionary(merged.map { ($0.name.lowercased(), one.items[$0.name.lowercased()] ?? []) }, uniquingKeysWith: { a, _ in a })
        }
        pulls = WorkFeatures.pullsByLabel(prs)
        features = merged
        guard !older.isEmpty else { return }
        let groups = WorkFeatures.groups(merged, agents: model.workAgents, approvals: approvals)
        let open = groups.flatMap { entry in
            entry.features.filter { isOpen($0.name, in: entry.group, of: groups.map(\.group)) }.map(\.name)
        }
        await withTaskGroup(of: Void.self) { group in
            for name in open { group.addTask { await self.readItems(name, model: model) } }
        }
    }

    /// Open or fold a feature; read its issues when it opens and they are not read yet.
    func setOpen(_ name: String, _ open: Bool, model: any WorkModel) async {
        let key = name.lowercased()
        picked[key] = open
        if open, items[key] == nil { await readItems(name, model: model) }
    }

    /// An open feature's open issues from the older machines, each ref once, with what the others
    /// gave it; then its epics' plans.
    private func readItems(_ name: String, model: any WorkModel) async {
        let key = name.lowercased()
        let mine = ask
        let board = board
        let machines = older
        var got: [(host: MachineRef, item: DaemonAPI.ForgeItem)] = []
        var problems: [String] = []
        await withTaskGroup(of: (MachineRef, Result<DaemonAPI.ForgeList, Error>).self) { group in
            for machine in machines {
                group.addTask {
                    do {
                        return (machine.id, .success(try await model.forgeList(.issue, .init(state: "open", limit: 100, feature: name,
                                                                                             board: board.isEmpty ? nil : board),
                                                                               on: machine.id)))
                    } catch {
                        return (machine.id, .failure(error))
                    }
                }
            }
            for await (host, result) in group {
                let machine = machines.count > 1 ? machines.first { $0.id == host }?.name : nil
                switch result {
                case let .success(list):
                    got += list.items.map { (host, $0) }
                    problems += (list.errors ?? []).map { WorkList.errorWords($0, machine: machine) }
                case let .failure(error):
                    problems.append(machine.map { "\($0): \(error.localizedDescription)" } ?? error.localizedDescription)
                }
            }
        }
        guard ask == mine else { return }
        items[key] = (oneRead[key] ?? []) + got.map(\.item)
        itemErrors[key] = problems
        let epics = WorkFeatures.opened(got.map(\.item)).epics
        let hosts = Dictionary(got.map { ($0.item.node.ref, $0.host) }, uniquingKeysWith: { a, _ in a })
        await withTaskGroup(of: Void.self) { group in
            for epic in epics where places[epic.node.ref] == nil {
                guard let host = hosts[epic.node.ref] else { continue }
                group.addTask { await self.readPlan(epic, on: host, model: model) }
            }
        }
    }

    /// An epic's plan, on the machine that read it, and its forecast on the machine that keeps links.
    private func readPlan(_ epic: DaemonAPI.ForgeItem, on host: MachineRef, model: any WorkModel) async {
        let mine = ask
        let lineage = model.lineageMachines
        let lineageHost = lineage.contains { $0.id == host } ? host : lineage.first?.id
        async let forecast = Self.forecast(epic.node, on: lineageHost, model: model)
        let plan = try? await model.forge(DaemonAPI.Method.forgePlan, DaemonAPI.ForgePlanRequest(node: epic.node),
                                          returning: DaemonAPI.ForgePlan.self, on: host)
        let closes = await forecast?.lands?.p50
        guard ask == mine else { return }
        if let plan { places[epic.node.ref] = WorkFeatures.place(plan, closes: closes) } else { unread.insert(epic.node.ref) }
    }

    private static func forecast(_ node: DaemonAPI.LineageNode, on host: MachineRef?,
                                 model: any WorkModel) async -> DaemonAPI.LineageForecast? {
        guard let host else { return nil }
        return await model.lineageForecast(node, on: host)
    }
}

/// Work ▸ Features as a delivery view (#4587, `specs/4328-work-look/features-delivery.md`): the
/// title *Features*, Board ▾ at its end (Mac + web, #3282) and Refresh in the toolbar; then the
/// groups (#4115) Needs you, In flight, Idle and Finished, each head with its count. A feature is
/// two lines, its colour, title and label chip, then its epics, what is in flight and what waits,
/// with a bar of its children done, in flight and not started at the end. A feature in Needs you
/// or In flight starts open: each open epic is a line with where it is in its plan, its bar and
/// its lead, and under it the children in flight (Needs you first), then the rest in words; then
/// the issues with no epic that are in flight. A row opens the issue's page. The Remote draws it
/// too (#4417, #4588): on a phone the bar goes alone, and the words after a title go under it.
struct WorkFeaturesPane: View {
    let model: any WorkModel
    @Bindable var state: WorkFeaturesState

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var compact: Bool { sizeClass == .compact }
    #else
    private let compact = false
    #endif

    var body: some View {
        VStack(spacing: 0) {
            #if os(macOS)
            HStack(alignment: .firstTextBaseline) {
                Text("Features").appText(.title).fontWeight(.semibold)
                Spacer()
                // Boards are the Mac's and the web page's (#3282, tier Mac + web).
                if !state.boards.isEmpty || !state.board.isEmpty {
                    WorkFilterMenu(name: "Board", selection: $state.board, options: boardOptions,
                                   words: { WorkList.boardName($0, in: state.boards) }, any: "", anyWords: "All boards")
                        .fixedSize()
                }
            }
            .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 10)
            Divider()
            #endif
            content
        }
        // Refresh in the toolbar (⌘R); the Remote has it as a bar button and pull to refresh (Features note 7).
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                WorkRefreshButton(running: state.features == nil) { state.asked += 1 }
            }
        }
        .workTask(id: [String(state.asked), state.board]) { await state.load(model: model) }
    }

    /// The boards read, and the one picked when the machines no longer list it.
    private var boardOptions: [String] {
        let urls = state.boards.map(\.url)
        return state.board.isEmpty || urls.contains(state.board) ? urls : urls + [state.board]
    }

    @ViewBuilder
    private var content: some View {
        if model.forgeMachines.isEmpty {
            WorkEmptyState(symbol: "square.stack.3d.up", title: "Connect a forge to see features", line: WorkList.noForgeHere)
        } else if let features = state.features {
            if features.isEmpty, state.errors.isEmpty {
                WorkEmptyState(symbol: "square.stack.3d.up", title: WorkFeatures.noFeaturesTitle,
                               line: "\(WorkFeatures.noFeatures)\n\(WorkFeatures.noFeaturesLabel)")
            } else {
                list(features)
            }
        } else {
            // The first read (state 9): five placeholder features, the first two with two
            // placeholder epic lines and a placeholder child under each; no spinner in the middle.
            List {
                ForEach(Self.loadingLines, id: \.self) { line in
                    placeholder(indent: line.indent, wide: line.wide)
                }
            }
            .listStyle(.inset).disabled(true)
        }
    }

    /// A placeholder line: its place in the list, its indent, and whether it is the wide one.
    private struct Placeholder: Hashable {
        var at: Int
        var indent: CGFloat
        var wide: Bool
    }

    /// Two placeholder epic lines, each with a placeholder child under it, from `at` on.
    private static func epicLines(from at: Int) -> [Placeholder] {
        [Placeholder(at: at, indent: epicIndent, wide: true), Placeholder(at: at + 1, indent: childIndent, wide: false),
         Placeholder(at: at + 2, indent: epicIndent, wide: false), Placeholder(at: at + 3, indent: childIndent, wide: true)]
    }

    /// The first read's lines (state 9): five features, the first two with their epic lines.
    private static let loadingLines: [Placeholder] = (0 ..< 5).flatMap { i -> [Placeholder] in
        let feature = Placeholder(at: i * 10, indent: 0, wide: i.isMultiple(of: 2))
        return i < 2 ? [feature] + epicLines(from: i * 10 + 1) : [feature]
    }

    /// An open feature's placeholder lines while its epics are read, with ids of its own.
    private func epicPlaceholders(_ key: String) -> some View {
        ForEach(Self.epicLines(from: 0).map { ("\(key) \($0.at)", $0) }, id: \.0) { _, line in
            placeholder(indent: line.indent, wide: line.wide)
        }
    }

    /// One placeholder line, as `WorkPlaceholderRows` draws them, at its indent.
    private func placeholder(indent: CGFloat, wide: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle().frame(width: 14, height: 14).padding(.top, 2)
            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: 3).frame(height: 11).frame(maxWidth: wide ? 360 : 280)
                RoundedRectangle(cornerRadius: 3).frame(width: 180, height: 9)
            }
        }
        .foregroundStyle(Paper.wash)
        .padding(.leading, indent).padding(.vertical, 5)
        .listRowSeparator(.hidden)
        .redacted(reason: .placeholder)
        .modifier(WorkShimmer())
        .accessibilityHidden(true)
    }

    private static let epicIndent: CGFloat = 40
    private static let childIndent: CGFloat = 72

    /// The approvals as the labels a lane gives its pull request: *P#45*.
    private var approvals: Set<String> { Set(state.approvals.map { "P" + WorkList.shortRef($0) }) }

    private func work(_ item: DaemonAPI.ForgeItem) -> WorkFeatures.Work {
        WorkFeatures.work(of: item, agents: model.workAgents, pulls: state.pulls, waiting: state.waiting)
    }

    private func list(_ features: [DaemonAPI.ForgeFeature]) -> some View {
        List {
            if !state.errors.isEmpty {
                WorkErrorStrip(lines: state.errors) { state.asked += 1 }
                    .listRowSeparator(.hidden)
            }
            let agents = model.workAgents
            let groups = WorkFeatures.groups(features, agents: agents, approvals: state.approvals)
            ForEach(groups, id: \.group) { entry in
                let isOpen = state.groupOpen[entry.group] ?? (entry.group != .finished || groups.count == 1)
                groupRow(entry.group, count: entry.features.count, isOpen: isOpen)
                if isOpen {
                    ForEach(entry.features, id: \.name) { f in
                        let sessions = WorkFeatures.sessions(of: f, in: agents)
                        feature(f, open: state.isOpen(f.name, in: entry.group, of: groups.map(\.group)),
                                sessions: entry.group == .inFlight ? sessions.count : nil,
                                idle: entry.group == .idle || entry.group == .finished,
                                needs: entry.group == .needsYou
                                    ? WorkFeatures.needsWords(f, sessions: sessions, approvals: state.approvals) : nil)
                    }
                }
            }
        }
        .listStyle(.inset)
        #if os(iOS)
        .refreshable { state.asked += 1 }
        #endif
    }

    @ViewBuilder
    private func feature(_ feature: DaemonAPI.ForgeFeature, open: Bool, sessions: Int?, idle: Bool, needs: String?) -> some View {
        let shown = state.items[feature.name.lowercased()].map(WorkFeatures.opened)
        featureRow(feature, open: open, shown: shown, sessions: sessions, idle: idle, needs: needs)
        if open {
            opened(feature, shown: shown)
        }
    }

    /// A group's head (#3741, #4115; note 2): a chevron, *Needs you* (in the attention colour),
    /// and its count after it in the tertiary colour.
    private func groupRow(_ group: WorkFeatures.Group, count: Int, isOpen: Bool) -> some View {
        Button {
            state.groupOpen[group] = !isOpen
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .imageScale(.small)
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
                    .frame(width: 12)
                Text(group.words).fontWeight(.semibold)
                    .foregroundStyle(group == .needsYou ? Self.attention : .secondary)
                Text("\(count)").monospacedDigit().foregroundStyle(.tertiary)
                Spacer(minLength: 0)
            }
            .foregroundStyle(.secondary)
            .padding(.top, 8).padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowSeparator(.hidden)
        .accessibilityLabel("\(group.words), \(count)")
        .accessibilityValue(isOpen ? "open" : "closed")
        .help(isOpen ? "Fold \(group.words)" : "Show \(group.words)")
    }

    private static let attention = Color(light: 0x9A6700, dark: 0xD29922)

    // MARK: Counting

    /// A read epic's children; nil while its plan is read.
    private func children(_ epic: DaemonAPI.ForgeItem) -> [DaemonAPI.ForgeItem]? {
        state.places[epic.node.ref]?.children
    }

    /// An epic's bar: over its children once its plan is read, else its closed sub-issues of all.
    private func tally(_ epic: DaemonAPI.ForgeItem) -> WorkFeatures.Tally {
        children(epic).map { WorkFeatures.tally($0, work: work, approvals: approvals) } ?? WorkFeatures.tally(progress: epic)
    }

    /// A feature's bar (note 4): its open epics' children and its loose issues; nil until its issues are read.
    private func tally(_ shown: WorkFeatures.Opened?) -> WorkFeatures.Tally? {
        guard let shown else { return nil }
        return shown.epics.map(tally).reduce(WorkFeatures.tally(shown.loose, work: work, approvals: approvals), +)
    }

    /// The children in flight under a feature, its loose issues too; nil while a plan is read.
    private func inFlight(_ shown: WorkFeatures.Opened?) -> Int? {
        guard let shown else { return nil }
        var count = WorkFeatures.inFlight(shown.loose, work: work, approvals: approvals).count
        for epic in shown.epics {
            if let children = children(epic) {
                count += WorkFeatures.inFlight(children, work: work, approvals: approvals).count
            } else if !state.unread.contains(epic.node.ref) {
                return nil
            }
        }
        return count
    }

    // MARK: A feature

    /// A feature (note 3): line 1 its colour, title and (not on a phone) its label as a chip;
    /// line 2 its epics, what is in flight and what waits for you; at the end its bar (note 4).
    private func featureRow(_ feature: DaemonAPI.ForgeFeature, open: Bool, shown: WorkFeatures.Opened?, sessions: Int?,
                            idle: Bool, needs: String?) -> some View {
        let tally = tally(shown)
        let line = WorkFeatures.deliveryWords(feature, inFlight: inFlight(shown) ?? (idle ? 0 : nil), sessions: sessions)
        let barWords = tally?.words ?? (feature.epics > 0 ? WorkFeatures.epicsDoneWords(feature) : nil)
        return Button {
            Task { await state.setOpen(feature.name, !open, model: model) }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "chevron.right")
                    .imageScale(.small)
                    .rotationEffect(.degrees(open ? 90 : 0))
                    .foregroundStyle(.secondary)
                    .frame(width: 12)
                Circle().fill(WorkList.rgb(feature.color).map { Color(red: $0.r, green: $0.g, blue: $0.b) } ?? .secondary)
                    .frame(width: 9, height: 9)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(WorkFeatures.title(feature.name)).fontWeight(.semibold)
                        if !compact {
                            WorkLabelChip(label: .init(name: "feature:\(feature.name)", color: feature.color)).fixedSize()
                        }
                    }
                    featureLine(line, needs: needs)
                }
                Spacer(minLength: 8)
                if let barWords {
                    HStack(spacing: 10) {
                        bar(tally ?? .init(done: max(feature.epics - feature.open, 0), notStarted: feature.open))
                            .frame(width: compact ? 60 : 120)
                        if !compact {
                            Text(barWords).appText(.supporting).monospacedDigit()
                                .foregroundStyle(.secondary).frame(minWidth: 110, alignment: .trailing)
                        }
                    }
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            // One element with one label, inside the button so it keeps its role: the chip has its own.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel([WorkFeatures.title(feature.name), line, needs, barWords].compactMap(\.self).joined(separator: ", "))
        }
        .buttonStyle(.plain)
        .accessibilityValue(open ? "open" : "closed")
        .help(open ? "Fold \(feature.name)" : "Show \(feature.name)'s epics and what is in flight")
    }

    /// "2 epics · 4 in flight · ⚠ P#45 waits for your approval", in the attention colour in Needs you.
    private func featureLine(_ words: String, needs: String?) -> some View {
        WrappingHStack(spacing: 4) {
            Text(words).monospacedDigit().foregroundStyle(needs == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(Self.attention))
            if let needs {
                Text("·").foregroundStyle(Self.attention)
                Label(needs, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Self.attention).fontWeight(.semibold)
            }
        }
        .appText(.supporting)
    }

    /// The three-part bar (note 4): done (purple), in flight (green), not started (the grey well).
    private func bar(_ tally: WorkFeatures.Tally) -> some View {
        let shares = tally.shares
        return WorkBar(parts: [(shares.done, WorkLook.Tone.purple.color), (shares.inFlight, WorkLook.Tone.green.color)])
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private func opened(_ feature: DaemonAPI.ForgeFeature, shown: WorkFeatures.Opened?) -> some View {
        let key = feature.name.lowercased()
        if let lines = state.itemErrors[key], !lines.isEmpty {
            WorkErrorStrip(lines: lines).padding(.leading, Self.epicIndent).listRowSeparator(.hidden)
        }
        if let shown {
            if shown.epics.isEmpty, shown.loose.isEmpty {
                Text(WorkFeatures.nothingOpen).appText(.supporting).foregroundStyle(.secondary).padding(.leading, Self.epicIndent)
                    .listRowSeparator(.hidden)
            }
            ForEach(shown.epics, id: \.node.ref) { epic($0) }
            loose(shown.loose)
        } else {
            // While its epics are read (state 13): two placeholder epic lines, each with a child.
            epicPlaceholders(key)
        }
    }

    // MARK: An epic

    @ViewBuilder
    private func epic(_ epic: DaemonAPI.ForgeItem) -> some View {
        epicRow(epic)
        if let children = children(epic) {
            let lines = WorkFeatures.inFlight(children, work: work, approvals: approvals)
            let most = compact ? WorkFeatures.shownInFlightOnPhone : WorkFeatures.shownInFlight
            if lines.isEmpty {
                quiet(WorkFeatures.nothingInFlight)
            }
            ForEach(lines.prefix(most), id: \.item.node.ref) { childRow($0) }
            rest(epic, tally: tally(epic), more: max(lines.count - most, 0), afterLines: !lines.isEmpty)
        } else if state.unread.contains(epic.node.ref) {
            // A plan that could not be read: its counts from the epic, and the link to its page.
            rest(epic, tally: WorkFeatures.tally(progress: epic), more: 0, afterLines: false)
        } else {
            quiet(WorkFeatures.reading)
        }
    }

    /// An open epic's line (notes 5 to 7): the epic glyph, the title, the number and where it is
    /// in its plan; the three-part bar and *4 of 9*; the lead in words. On a phone where it is
    /// and the lead go on a second line.
    private func epicRow(_ epic: DaemonAPI.ForgeItem) -> some View {
        let lead = model.workLead(of: epic.node)
        let tally = tally(epic)
        let place = state.places[epic.node.ref].flatMap { WorkFeatures.whereWords($0) }
        return open(epic, indent: Self.epicIndent) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "chart.pie")
                    .foregroundStyle(epic.state == "open" ? WorkLook.Tone.green.color : WorkLook.Tone.purple.color)
                    .accessibilityHidden(true)
                if compact {
                    VStack(alignment: .leading, spacing: 2) {
                        epicTitle(epic, place: nil).lineLimit(2)
                        HStack(spacing: 10) {
                            if let place { Text(place).foregroundStyle(.secondary) }
                            epicLead(lead)
                        }
                        .appText(.supporting)
                    }
                    Spacer(minLength: 8)
                    bar(tally).frame(width: 60)
                        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                } else {
                    epicTitle(epic, place: place).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 8)
                    bar(tally).frame(width: 110)
                        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                    Text(tally.epicWords).appText(.supporting).monospacedDigit().foregroundStyle(.secondary)
                        .frame(minWidth: 50, alignment: .leading)
                        .help("Children closed, of all")
                    epicLead(lead).frame(minWidth: 130, alignment: .leading)
                }
            }
        }
    }

    /// The title semibold, its number and where it is after it in grey, as one text.
    private func epicTitle(_ item: DaemonAPI.ForgeItem, place: String?) -> Text {
        let rest = [WorkList.shortRef(item.node.ref), place].compactMap(\.self).joined(separator: "  ")
        return Text("\(Text.forgeTitle(item.title).fontWeight(.semibold))  \(Text(rest).foregroundStyle(.secondary))")
    }

    private func epicLead(_ lead: Agent?) -> some View {
        Text(WorkFeatures.leadWords(lead?.state)).appText(.supporting)
            .foregroundStyle(lead?.state == .waitingOnUser ? Self.attention
                : lead?.state.holdsRuntime == true ? WorkLook.Tone.green.color : .secondary)
    }

    /// The rest under an epic's lines (notes 8 and 9): *2 more in flight*, then *2 more not
    /// started · 4 done · open the epic for the plan*; on a phone, one line (note 15).
    @ViewBuilder
    private func rest(_ epic: DaemonAPI.ForgeItem, tally: WorkFeatures.Tally, more: Int, afterLines: Bool) -> some View {
        if compact {
            if let words = WorkFeatures.phoneRestWords(tally, moreInFlight: more) {
                openPlan(epic, words: words, link: nil)
            }
        } else {
            if more > 0 {
                openPlan(epic, words: nil, link: WorkFeatures.moreInFlightWords(more))
            }
            openPlan(epic, words: WorkFeatures.restWords(tally, afterLines: afterLines), link: WorkFeatures.openThePlan)
        }
    }

    /// Words in the tertiary colour and a link to the epic's page after them.
    private func openPlan(_ epic: DaemonAPI.ForgeItem, words: String?, link: String?) -> some View {
        Button {
            model.showWork(WorkPlace(kind: .issue, ref: epic.node.ref))
        } label: {
            linkText(words: words, link: link)
                .appText(.supporting).foregroundStyle(.tertiary)
                .padding(.leading, Self.childIndent).padding(.vertical, 1)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowSeparator(.hidden)
        .help("Open \(WorkList.shortRef(epic.node.ref))'s page, with its plan")
    }

    /// *2 more not started · 4 done · open the epic for the plan*, the last words in the link colour.
    private func linkText(words: String?, link: String?) -> Text {
        guard let link else { return Text(words ?? "") }
        let linked = Text(link).foregroundStyle(Color.accentColor)
        guard let words else { return linked }
        return Text("\(words) · \(linked)")
    }

    private func quiet(_ words: String) -> some View {
        Text(words).appText(.supporting).foregroundStyle(.tertiary)
            .padding(.leading, Self.childIndent).padding(.vertical, 1)
            .listRowSeparator(.hidden)
    }

    // MARK: A child in flight

    /// A child in flight (note 8): its mark, its number in the tertiary colour, its title, and what
    /// works on it (the lane's title a link to its chat); its pull request at the end. Needs you
    /// is the one line in the attention colour. On a phone the words go on a second line.
    private func childRow(_ line: WorkFeatures.Line) -> some View {
        let needs = line.flight == .needsYou
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Button {
                model.showWork(WorkPlace(kind: .issue, ref: line.item.node.ref))
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    mark(line.flight)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(Text(WorkList.shortRef(line.item.node.ref)).foregroundStyle(.tertiary)) \(Text.forgeTitle(line.item.title))")
                            .lineLimit(compact ? 2 : 1).truncationMode(.tail)
                        if compact { childWords(line, needs: needs) }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open \(WorkList.shortRef(line.item.node.ref))'s page")
            if !compact { childWords(line, needs: needs).layoutPriority(-1) }
            Spacer(minLength: 8)
            if let pr = line.pr {
                Button {
                    model.showWork(WorkPlace(kind: .pr, ref: pr.node.ref))
                } label: {
                    HStack(spacing: 3) {
                        WorkStateIcon(kind: "pr", state: pr.state, draft: pr.draft ?? false)
                        Text("P" + WorkList.shortRef(pr.node.ref)).monospacedDigit()
                    }
                    .appText(.supporting).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Open P\(WorkList.shortRef(pr.node.ref))'s page")
            }
        }
        .padding(.leading, Self.childIndent).padding(.vertical, 1)
        .listRowSeparator(.hidden)
    }

    /// The words after a child's title: *· Working · “its lane”* with the lane a link to its chat.
    @ViewBuilder
    private func childWords(_ line: WorkFeatures.Line, needs: Bool) -> some View {
        let words = Text((compact ? "" : "· ") + line.words)
            .appText(.supporting).lineLimit(1).truncationMode(.tail)
            .foregroundStyle(needs ? AnyShapeStyle(Self.attention) : AnyShapeStyle(.secondary))
            .fontWeight(needs ? .semibold : .regular)
        if let lane = line.lane, model.workSessionTitle(lane.id) != nil {
            Button { model.openWorkSession(lane.id) } label: { words }
                .buttonStyle(.plain)
                .help("Open “\(lane.title ?? "the lane")”")
        } else {
            words
        }
    }

    /// A child's mark: the warning glyph for Needs you, a green dot for Working.
    @ViewBuilder
    private func mark(_ flight: WorkFeatures.Flight) -> some View {
        if flight == .needsYou {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(Self.attention).imageScale(.small)
                .accessibilityLabel("Needs you")
        } else {
            Circle().fill(WorkLook.Tone.green.color).frame(width: 8, height: 8)
                .accessibilityLabel("Working")
        }
    }

    // MARK: Issues with no epic

    /// The loose issues (note 11): the heading, the ones in flight, then *3 more not started*.
    @ViewBuilder
    private func loose(_ items: [DaemonAPI.ForgeItem]) -> some View {
        if !items.isEmpty {
            let lines = WorkFeatures.inFlight(items, work: work, approvals: approvals)
            Text(WorkFeatures.looseHeading).appText(.fine).fontWeight(.semibold).foregroundStyle(.secondary)
                .padding(.leading, Self.epicIndent).padding(.top, 4)
                .listRowSeparator(.hidden)
            ForEach(lines, id: \.item.node.ref) { childRow($0) }
            if items.count > lines.count {
                quiet(lines.isEmpty ? "\(items.count) not started" : "\(items.count - lines.count) more not started")
            }
        }
    }

    private func open(_ item: DaemonAPI.ForgeItem, indent: CGFloat, @ViewBuilder label: () -> some View) -> some View {
        Button {
            model.showWork(WorkPlace(kind: .issue, ref: item.node.ref))
        } label: {
            label().padding(.leading, indent).padding(.vertical, 2).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowSeparator(.hidden)
        .help("Open \(WorkList.shortRef(item.node.ref))'s page")
    }
}
