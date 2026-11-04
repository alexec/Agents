import AgentsKitCore
import Observation

/// One Work list's state (#3257): its filters, sort, the rows read and the cursors to the next
/// pages. The model keeps one per kind, so an item's page goes through the list it was opened
/// from (Previous and Next), and Back finds the list as it was left.
@MainActor
@Observable
final class WorkListState {
    let kind: WorkList.Kind
    var filter = WorkList.Filter()
    var sort = WorkList.Sort.updated
    var lists: [(host: MachineRef, list: DaemonAPI.ForgeList)]?
    var lineage: [DaemonAPI.ReportNode] = []
    /// The boards the Board menu offers (#3282), read with the list.
    var boards: [DaemonAPI.ProjectBoard] = []
    var lineageCursor: String?
    var problem: String?
    var loadingMore = false
    var asked = 0
    /// The row whose page was opened last, which the list scrolls to when it is shown again.
    var opened: String?
    /// What the rows were read for; the list reads them again only when that changes.
    private var read: Ask?

    /// How many pages of `reports/nodes` a list reads for its lineage: at most 500 nodes.
    private static let lineagePages = 5

    init(kind: WorkList.Kind) { self.kind = kind }

    struct Ask: Equatable {
        var state: String
        var sort: DaemonAPI.ReportNodesSort
        var asked: Int
        var board: String
    }

    var ask: Ask { Ask(state: filter.state.forge, sort: nodesSort, asked: asked, board: filter.board) }

    /// An issue's or a PR's lineage is joined by ref, in any order; a milestone's or a release's list is lineage's own.
    private var nodesSort: DaemonAPI.ReportNodesSort { !kind.fromForge && sort == .cost ? .cost : .newest }

    var all: [WorkList.Row] {
        kind.fromForge ? WorkList.merge((lists ?? []).map { (host: $0.host, items: $0.list.items) }, lineage: lineage)
            : lineage.map(WorkList.Row.init)
    }

    /// The rows as the list shows them: filtered and sorted.
    var rows: [WorkList.Row] {
        var f = filter
        // Milestones and releases have no state in v1.
        if !kind.fromForge { f.state = .all }
        return WorkList.sort(WorkList.filter(all, f), by: sort)
    }

    var hasMore: Bool { kind.fromForge ? (lists ?? []).contains { $0.list.cursor != nil } : lineageCursor != nil }

    /// Previous and Next for an item's page; nil when the list has not got the item.
    func neighbours(of ref: String) -> WorkList.Neighbours? { WorkList.neighbours(of: ref, in: rows) }

    /// The ref after `ref`, reading the next page first (as More does) when `ref` is the last row read.
    func next(after ref: String, model: any WorkModel) async -> String? {
        if let next = neighbours(of: ref)?.next { return next }
        while hasMore, !loadingMore {
            let before = rows.count
            await loadMore(model: model)
            if let next = neighbours(of: ref)?.next { return next }
            if rows.count == before || problem != nil { break }
        }
        return nil
    }

    /// The lineage of the kind, at most `lineagePages` pages; none from a control plane that does not list nodes.
    private func readLineage(_ model: any WorkModel, from cursor: String? = nil) async throws
        -> (nodes: [DaemonAPI.ReportNode], cursor: String?) {
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

    /// Read the list for what it is asked, unless it was read for that already.
    func load(model: any WorkModel) async {
        let mine = ask
        guard read != mine || lists == nil else { return }
        read = mine
        lists = nil
        lineage = []
        problem = nil
        do {
            let known = try await readLineage(model)
            guard ask == mine else { return }
            lineage = known.nodes
            lineageCursor = known.cursor
        } catch {
            guard ask == mine else { return }
            // A control plane that does not list nodes yet leaves the issues and PRs without figures.
            if !kind.fromForge { problem = ReportValueWords.sentence(error) }
        }
        guard kind.fromForge else { lists = []; return }
        let state = filter.state.forge
        let kind = kind
        let board = filter.board
        if kind == .issue {
            let boards = await model.workBoards()
            guard ask == mine else { return }
            self.boards = boards
        }
        var got: [(host: MachineRef, list: DaemonAPI.ForgeList)] = []
        await withTaskGroup(of: (MachineRef, DaemonAPI.ForgeList).self) { group in
            for machine in model.workMachines(board: board) {
                group.addTask {
                    do {
                        return (machine.id, try await model.forgeList(kind, .init(state: state, limit: 100,
                                                                                  board: board.isEmpty ? nil : board),
                                                                      on: machine.id))
                    } catch {
                        return (machine.id, .init(errors: [.init(forge: "", message: error.localizedDescription)]))
                    }
                }
            }
            for await (host, list) in group { got.append((host, list)) }
        }
        guard ask == mine else { return }
        lists = got
    }

    func loadMore(model: any WorkModel) async {
        loadingMore = true
        defer { loadingMore = false }
        do {
            if kind.fromForge {
                var next: [(host: MachineRef, list: DaemonAPI.ForgeList)] = []
                for entry in lists ?? [] {
                    guard let cursor = entry.list.cursor else { next.append(entry); continue }
                    let page = try await model.forgeList(kind, .init(state: filter.state.forge, cursor: cursor, limit: 100,
                                                                     board: filter.board.isEmpty ? nil : filter.board),
                                                         on: entry.host)
                    next.append((entry.host, .init(items: entry.list.items + page.items, cursor: page.cursor, errors: page.errors)))
                }
                lists = next
            } else if let cursor = lineageCursor {
                let page = try await readLineage(model, from: cursor)
                lineage += page.nodes
                lineageCursor = page.cursor
            }
        } catch {
            problem = ReportValueWords.sentence(error)
        }
    }
}

/// The Work lists, one per kind, kept by the model while the app runs (#3257).
@MainActor
final class WorkLists {
    /// Work ▸ Features (#3269): the features read, and the ones opened.
    let features = WorkFeaturesState()
    private var byKind: [WorkList.Kind: WorkListState] = [:]

    subscript(kind: WorkList.Kind) -> WorkListState {
        if let state = byKind[kind] { return state }
        let state = WorkListState(kind: kind)
        byKind[kind] = state
        return state
    }
}
