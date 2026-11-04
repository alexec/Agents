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
    var errors: [String] = []
    /// The features opened, by name in lower case.
    var opened: Set<String> = []
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

/// Work ▸ Features (#3269, spec 3265), as the web page's `WorkFeatures`: a row per `feature:` label
/// with its epic counts; opened, its open epics, each with its progress and lead, and its issues
/// with no epic. A row opens the issue's page.
struct WorkFeaturesPane: View {
    let model: any WorkModel
    @Bindable var state: WorkFeaturesState

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("The feature:<name> labels on the epics.").appText(.supporting).foregroundStyle(.secondary)
                Spacer()
                #if os(macOS)
                // Boards are the Mac's and the web page's (#3282, tier Mac + web).
                if !state.boards.isEmpty || !state.board.isEmpty {
                    WorkBoardPicker(selection: $state.board, boards: state.boards)
                }
                #endif
                Button("Refresh") { state.asked += 1 }.linkStyle()
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            Divider()
            content
        }
        .workTask(id: [String(state.asked), state.board]) { await state.load(model: model) }
    }

    @ViewBuilder
    private var content: some View {
        if model.forgeMachines.isEmpty {
            Text(WorkList.noForgeHere).appText(.supporting).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let features = state.features {
            List {
                ForEach(state.errors, id: \.self) { line in
                    Label(line, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
                }
                if features.isEmpty {
                    Text(WorkFeatures.noFeatures).foregroundStyle(.secondary)
                }
                ForEach(features, id: \.name) { feature in
                    featureRow(feature)
                    if state.opened.contains(feature.name.lowercased()) {
                        opened(feature)
                    }
                }
            }
            .listStyle(.inset)
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func featureRow(_ feature: DaemonAPI.ForgeFeature) -> some View {
        let isOpen = state.opened.contains(feature.name.lowercased())
        return Button {
            Task { await state.toggle(feature.name, model: model) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
                    .foregroundStyle(.secondary)
                    .frame(width: 12)
                if let rgb = WorkList.rgb(feature.color) {
                    Circle().fill(Color(red: rgb.r, green: rgb.g, blue: rgb.b)).frame(width: 8, height: 8)
                }
                Text(WorkFeatures.title(feature.name)).fontWeight(.semibold)
                Spacer(minLength: 8)
                Text(WorkFeatures.countWords(feature)).monospacedDigit().foregroundStyle(.secondary)
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(WorkFeatures.title(feature.name)), \(WorkFeatures.countWords(feature))")
        .accessibilityValue(isOpen ? "open" : "closed")
        .help(isOpen ? "Fold \(feature.name)" : "Show \(feature.name)'s open epics and issues")
    }

    @ViewBuilder
    private func opened(_ feature: DaemonAPI.ForgeFeature) -> some View {
        let key = feature.name.lowercased()
        ForEach(state.itemErrors[key] ?? [], id: \.self) { line in
            Label(line, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary).padding(.leading, 20)
        }
        if let items = state.items[key] {
            let shown = WorkFeatures.opened(items)
            if shown.epics.isEmpty, shown.loose.isEmpty {
                Text(WorkFeatures.nothingOpen).foregroundStyle(.secondary).padding(.leading, 20)
            }
            ForEach(shown.epics, id: \.node.ref) { epicRow($0) }
            if !shown.loose.isEmpty {
                Text("Issues with no epic").appText(.supporting).fontWeight(.semibold).foregroundStyle(.secondary)
                    .padding(.leading, 20).padding(.top, 4)
                ForEach(shown.loose, id: \.node.ref) { issueRow($0) }
            }
        } else {
            ProgressView().controlSize(.small).padding(.leading, 20)
        }
    }

    private func epicRow(_ epic: DaemonAPI.ForgeItem) -> some View {
        let lead = model.workLead(of: epic.node)
        return open(epic) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(WorkList.shortRef(epic.node.ref)).foregroundStyle(.tint).monospacedDigit()
                Text(epic.title).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 8)
                Text(WorkFeatures.progressWords(epic)).monospacedDigit().foregroundStyle(.secondary)
                    .help("Sub-issues closed, of all")
                Text(WorkFeatures.leadWords(lead?.state))
                    .foregroundStyle((lead?.state == .waitingOnUser ? StateTint.attention : .none).style(or: .secondary))
                    .frame(minWidth: 130, alignment: .leading)
            }
        }
    }

    private func issueRow(_ issue: DaemonAPI.ForgeItem) -> some View {
        open(issue) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(WorkList.shortRef(issue.node.ref)).foregroundStyle(.tint).monospacedDigit()
                Text(issue.title).lineLimit(1).truncationMode(.tail)
                if let level = issue.level { Text(level).foregroundStyle(.secondary) }
                Spacer(minLength: 0)
            }
        }
    }

    private func open(_ item: DaemonAPI.ForgeItem, @ViewBuilder label: () -> some View) -> some View {
        Button {
            model.showWork(WorkPlace(kind: .issue, ref: item.node.ref))
        } label: {
            label().padding(.leading, 20).padding(.vertical, 2).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open \(WorkList.shortRef(item.node.ref))'s page")
    }
}
