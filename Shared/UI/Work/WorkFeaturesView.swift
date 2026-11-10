import AgentsKitCore
import Observation
import SwiftUI

/// Work ▸ Features's state (#3269): the features of every machine's forges (`forge/features`), and
/// for each one opened, its open issues (`forge/issues` with the feature). The model keeps it, so
/// Back from an epic's page finds the list as it was left.
@MainActor
@Observable
final class WorkFeaturesState {
    var features: [DaemonAPI.ForgeFeature]?
    /// The open pull requests labelled needs-approval, of every machine (#4115).
    var approvals: [String] = []
    var errors: [String] = []
    /// The features opened, by name in lower case.
    var opened: Set<String> = []
    /// The groups a person opened or closed (#3741, #4115). Each is open until closed, except
    /// Finished, which is closed until opened, unless every feature is in it.
    var groupOpen: [WorkFeatures.Group: Bool] = [:]
    /// An opened feature's open issues, by name in lower case; absent while they are read.
    var items: [String: [DaemonAPI.ForgeItem]] = [:]
    var itemErrors: [String: [String]] = [:]
    var asked = 0
    /// The board the epics are narrowed to (#3282), by its url; "" for every board.
    var board = ""
    /// The boards the Board menu offers, read with the features.
    var boards: [DaemonAPI.ProjectBoard] = []
    private var read: Ask?

    private struct Ask: Equatable {
        var asked: Int
        var board: String
    }

    private var ask: Ask { Ask(asked: asked, board: board) }

    /// Read the features, unless they were read for this Refresh and board already.
    func load(model: any WorkModel) async {
        let mine = ask
        guard read != mine || features == nil else { return }
        read = mine
        features = nil
        approvals = []
        errors = []
        items = [:]
        itemErrors = [:]
        let board = board
        let found = await model.workBoards()
        guard ask == mine else { return }
        boards = found
        let machines = model.workMachines(board: board)
        var got: [(host: MachineRef, list: DaemonAPI.ForgeFeatures)] = []
        await withTaskGroup(of: (MachineRef, DaemonAPI.ForgeFeatures).self) { group in
            for machine in machines {
                group.addTask {
                    do {
                        return (machine.id, try await model.forge(DaemonAPI.Method.forgeFeatures,
                                                                  DaemonAPI.ForgeFeaturesRequest(board: board.isEmpty ? nil : board),
                                                                  returning: DaemonAPI.ForgeFeatures.self, on: machine.id))
                    } catch {
                        return (machine.id, .init(errors: [.init(forge: "", message: error.localizedDescription)]))
                    }
                }
            }
            for await (host, list) in group { got.append((host, list)) }
        }
        guard ask == mine else { return }
        errors = got.flatMap { entry in
            (entry.list.errors ?? []).map { e in
                WorkList.errorWords(e, machine: machines.count > 1 ? machines.first { $0.id == entry.host }?.name : nil)
            }
        }
        features = WorkFeatures.merge(got.map(\.list.features))
        approvals = got.flatMap { $0.list.approvals ?? [] }
        for name in opened { await readItems(name, model: model) }
    }

    func toggle(_ name: String, model: any WorkModel) async {
        let key = name.lowercased()
        if opened.remove(key) != nil { return }
        opened.insert(key)
        if items[key] == nil { await readItems(name, model: model) }
    }

    /// An opened feature's open issues from every machine, each ref once.
    private func readItems(_ name: String, model: any WorkModel) async {
        let key = name.lowercased()
        let mine = ask
        let board = board
        let machines = model.workMachines(board: board)
        var got: [DaemonAPI.ForgeItem] = []
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
                    got += list.items
                    problems += (list.errors ?? []).map { WorkList.errorWords($0, machine: machine) }
                case let .failure(error):
                    problems.append(machine.map { "\($0): \(error.localizedDescription)" } ?? error.localizedDescription)
                }
            }
        }
        guard ask == mine else { return }
        items[key] = got
        itemErrors[key] = problems
    }
}

/// Work ▸ Features (#3269, spec 3265), as the web page's `WorkFeatures`, in the Work look (#4416,
/// `specs/4328-work-look/epic.md`, Features): the title *Features*, Board ▾ at its end (Mac + web,
/// #3282) and Refresh in the toolbar; then the groups (#4115) Needs you, In flight, Idle and
/// Finished (folded, #3741), each head with its count. A feature is two lines: its colour, title
/// and label chip; its counts and, in Needs you, what waits; a bar of its epics done at the end.
/// Opened, its open epics, each a mini row with its bar and lead, and its issues with no epic. A
/// row opens the issue's page. The Remote draws it too: on a phone the bar goes alone, and an
/// epic's counts and lead go under its title.
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
        // Refresh in the toolbar (⌘R); a phone has pull to refresh in its place.
        .toolbar {
            if !compact {
                ToolbarItem(placement: .primaryAction) {
                    WorkRefreshButton(running: state.features == nil) { state.asked += 1 }
                }
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
            // The first read (states board, 9): placeholder features, no spinner in the middle.
            List { WorkPlaceholderRows(count: 5) }.listStyle(.inset).disabled(true)
        }
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
                        feature(f, sessions: entry.group == .inFlight ? sessions.count : nil,
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
    private func feature(_ feature: DaemonAPI.ForgeFeature, sessions: Int?, needs: String?) -> some View {
        featureRow(feature, sessions: sessions, needs: needs)
        if state.opened.contains(feature.name.lowercased()) {
            opened(feature)
        }
    }

    /// A group's head (#3741, #4115; Features note 1): a chevron, *Needs you* (in the attention
    /// colour), and its count after it in the tertiary colour.
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

    /// A feature (Features note 2): line 1 its colour, title and (not on a phone) its label as a
    /// chip; line 2 its counts and what waits for you; at the end a bar of its epics done.
    private func featureRow(_ feature: DaemonAPI.ForgeFeature, sessions: Int?, needs: String?) -> some View {
        let isOpen = state.opened.contains(feature.name.lowercased())
        return Button {
            Task { await state.toggle(feature.name, model: model) }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "chevron.right")
                    .imageScale(.small)
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
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
                    featureLine(feature, sessions: sessions, needs: needs)
                }
                Spacer(minLength: 8)
                if feature.epics > 0 {
                    HStack(spacing: 10) {
                        WorkBar(parts: [(WorkFeatures.epicsDone(feature) ?? 0, WorkLook.Tone.purple.color)])
                            .frame(width: compact ? 60 : 120)
                        if !compact {
                            Text(WorkFeatures.epicsDoneWords(feature)).appText(.supporting).monospacedDigit()
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
            .accessibilityLabel([WorkFeatures.title(feature.name), sessions.map(WorkFeatures.sessionWords), WorkFeatures.countWords(feature),
                             needs, feature.epics > 0 ? WorkFeatures.epicsDoneWords(feature) : nil]
            .compactMap(\.self).joined(separator: ", "))
        }
        .buttonStyle(.plain)
        .accessibilityValue(isOpen ? "open" : "closed")
        .help(isOpen ? "Fold \(feature.name)" : "Show \(feature.name)'s open epics and issues")
    }

    /// "2 epics · 1 open · 3 open issues · ⚠ P#4405 waits for your approval".
    private func featureLine(_ feature: DaemonAPI.ForgeFeature, sessions: Int?, needs: String?) -> some View {
        WrappingHStack(spacing: 4) {
            Text([WorkFeatures.countWords(feature), sessions.map(WorkFeatures.sessionWords)].compactMap { $0 }.joined(separator: " · "))
                .monospacedDigit().foregroundStyle(.secondary)
            if let needs {
                Text("·").foregroundStyle(.secondary)
                Label(needs, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Self.attention).fontWeight(.semibold)
            }
        }
        .appText(.supporting)
    }

    @ViewBuilder
    private func opened(_ feature: DaemonAPI.ForgeFeature) -> some View {
        let key = feature.name.lowercased()
        if let lines = state.itemErrors[key], !lines.isEmpty {
            WorkErrorStrip(lines: lines).padding(.leading, 40).listRowSeparator(.hidden)
        }
        if let items = state.items[key] {
            let shown = WorkFeatures.opened(items)
            if shown.epics.isEmpty, shown.loose.isEmpty {
                Text(WorkFeatures.nothingOpen).appText(.supporting).foregroundStyle(.secondary).padding(.leading, 40)
                    .listRowSeparator(.hidden)
            }
            ForEach(shown.epics, id: \.node.ref) { epicRow($0) }
            if !shown.loose.isEmpty {
                Text("Issues with no epic").appText(.fine).fontWeight(.semibold).foregroundStyle(.secondary)
                    .padding(.leading, 40).padding(.top, 4)
                    .listRowSeparator(.hidden)
                ForEach(shown.loose, id: \.node.ref) { issueRow($0) }
            }
        } else {
            // While its epics are read (states board, 13): two placeholder mini rows.
            WorkPlaceholderRows(count: 2).padding(.leading, 40).listRowSeparator(.hidden)
        }
    }

    /// An open epic (Features note 3): the state icon, the title, the number, a bar and *4 of 9*,
    /// and its lead in words and colour. On a phone the counts and the lead go under the title.
    private func epicRow(_ epic: DaemonAPI.ForgeItem) -> some View {
        let lead = model.workLead(of: epic.node)
        return open(epic) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                WorkStateIcon(kind: "issue", state: epic.state)
                if compact {
                    VStack(alignment: .leading, spacing: 2) {
                        title(epic).lineLimit(2)
                        HStack(spacing: 10) {
                            epicProgress(epic)
                            epicLead(lead)
                        }
                        .appText(.supporting)
                    }
                } else {
                    title(epic).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 8)
                    WorkBar(parts: [(epicDone(epic), WorkLook.Tone.purple.color)]).frame(width: 110)
                        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                    epicProgress(epic).frame(minWidth: 50, alignment: .leading)
                    epicLead(lead).frame(minWidth: 130, alignment: .leading)
                }
            }
        }
    }

    /// The title and its number after it in grey, as one text.
    private func title(_ item: DaemonAPI.ForgeItem) -> Text {
        Text("\(Text.forgeTitle(item.title)) \(Text(WorkList.shortRef(item.node.ref)).foregroundStyle(.secondary))")
    }

    private func epicDone(_ epic: DaemonAPI.ForgeItem) -> Double {
        guard let p = epic.progress, p.total > 0 else { return 0 }
        return Double(p.done) / Double(p.total)
    }

    private func epicProgress(_ epic: DaemonAPI.ForgeItem) -> some View {
        Text(WorkFeatures.progressWords(epic)).appText(.supporting).monospacedDigit().foregroundStyle(.secondary)
            .help("Sub-issues closed, of all")
    }

    private func epicLead(_ lead: Agent?) -> some View {
        Text(WorkFeatures.leadWords(lead?.state)).appText(.supporting)
            .foregroundStyle(lead?.state == .waitingOnUser ? Self.attention
                : lead?.state.holdsRuntime == true ? WorkLook.Tone.green.color : .secondary)
    }

    /// An issue with no epic (Features note 4): the state icon, the title, the number, the level chip.
    private func issueRow(_ issue: DaemonAPI.ForgeItem) -> some View {
        open(issue) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                WorkStateIcon(kind: "issue", state: issue.state)
                title(issue).lineLimit(compact ? 2 : 1).truncationMode(.tail)
                if let level = issue.level {
                    WorkLabelChip(label: issue.labels.first { $0.name.lowercased() == level } ?? .init(name: level)).fixedSize()
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func open(_ item: DaemonAPI.ForgeItem, @ViewBuilder label: () -> some View) -> some View {
        Button {
            model.showWork(WorkPlace(kind: .issue, ref: item.node.ref))
        } label: {
            label().padding(.leading, 40).padding(.vertical, 2).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowSeparator(.hidden)
        .help("Open \(WorkList.shortRef(item.node.ref))'s page")
    }
}
