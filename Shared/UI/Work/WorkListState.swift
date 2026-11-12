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
    /// The person's projects (#3283), as the model last said them, for the Project filter.
    var projects: [WorkList.Project] = []
    var sort = WorkList.Sort.updated
    var lists: [(host: MachineRef, list: DaemonAPI.ForgeList)]?
    var lineage: [DaemonAPI.ReportNode] = []
    /// The boards the Board menu offers (#3282), read with the list.
    var boards: [DaemonAPI.ProjectBoard] = []
    var lineageCursor: String?
    var problem: String?
    /// Why the last page after the first did not load: one line at the end of the list, and Try again.
    var pageProblem: String?
    var loadingMore = false
    var asked = 0
    /// The row whose page was opened last, which the list scrolls to when it is shown again.
    var opened: String?
    /// The selected row on the Mac (lists.md section 2): ↑ and ↓ move it, Return opens it.
    var selected: String?
    /// The rows on screen came from this device's copy (#4930): the machines are asked again,
    /// and the list says so until they answer.
    var fromDevice = false
    /// A read runs: the rows read before stay until the new ones come (#4930), and Refresh spins.
    var reading = false
    /// What the rows were read for; the list reads them again only when that changes.
    private var read: Ask?
    /// What the rows on screen were read for, without Refresh: the copy is drawn only for another.
    private var shownFor: String?

    /// How many pages of `reports/nodes` a list reads for its lineage: at most 500 nodes.
    private static let lineagePages = 5

    init(kind: WorkList.Kind) {
        self.kind = kind
        sort = kind.defaultSort
    }

    struct Ask: Equatable {
        var state: String
        var sort: DaemonAPI.ReportNodesSort
        var asked: Int
        var board: String
    }

    var ask: Ask { Ask(state: filter.state.forge, sort: nodesSort, asked: asked, board: filter.board) }

    /// What a list's first page is kept under in this device's copy (#4930): the kind, state, sort and board.
    var copyAsk: String { [kind.rawValue, filter.state.forge, nodesSort.rawValue, filter.board].joined(separator: "|") }

    /// A list's first page as this device keeps it (#4930): each machine's page, the lineage
    /// figures, and the boards the Board menu offers.
    struct Kept: Codable, Sendable {
        var hosts: [MachineRef]
        var lists: [DaemonAPI.ForgeList]
        var lineage: [DaemonAPI.ReportNode]
        var lineageCursor: String?
        var boards: [DaemonAPI.ProjectBoard]
    }

    /// Draws the first page this device kept for what is asked, unless rows read for it are on
    /// screen. Whether there was one.
    @discardableResult
    func drawKept(model: any WorkModel) async -> Bool {
        let wanted = copyAsk
        guard shownFor != wanted, let kept = await model.keptWork(Kept.self, .list, wanted),
              copyAsk == wanted, shownFor != wanted, kept.hosts.count == kept.lists.count else { return false }
        lists = Array(zip(kept.hosts, kept.lists)).map { (host: $0.0, list: $0.1) }
        lineage = kept.lineage
        lineageCursor = kept.lineageCursor
        if kind == .issue { boards = kept.boards }
        shownFor = wanted
        fromDevice = true
        return true
    }

    /// An issue's or a PR's lineage is joined by ref, in any order; a release's list is lineage's own.
    private var nodesSort: DaemonAPI.ReportNodesSort { !kind.fromForge && sort == .cost ? .cost : .newest }

    var all: [WorkList.Row] {
        kind.fromForge ? WorkList.merge((lists ?? []).map { (host: $0.host, items: $0.list.items) }, lineage: lineage)
            : lineage.map(WorkList.Row.init)
    }

    /// The rows as the list shows them: filtered and sorted.
    var rows: [WorkList.Row] {
        var f = filter
        // Releases have no state in v1.
        if !kind.fromForge { f.state = .all }
        return WorkList.sort(WorkList.filter(all, f, projects: projectRepos), by: sort)
    }

    /// Each project with the repos its folders read (#3283); none for releases,
    /// which lineage alone lists, with no folder.
    var projectRepos: [(project: WorkList.Project, repos: Set<String>)] {
        kind.fromForge ? WorkList.projectRepos(projects, lists: (lists ?? []).map { (host: $0.host, items: $0.list.items) }) : []
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
            if rows.count == before || pageProblem != nil { break }
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

    /// Read the list for what it is asked, unless it was read for that already. The rows on
    /// screen stay until the new ones come (#4930); a list not read yet this run draws this
    /// device's copy first, and the machines' answer replaces it.
    func load(model: any WorkModel) async {
        let mine = ask
        guard read != mine || lists == nil else { return }
        read = mine
        problem = nil
        pageProblem = nil
        reading = true
        defer { if ask == mine { reading = false } }
        await drawKept(model: model)
        guard ask == mine else { return }
        let wanted = copyAsk
        var known: (nodes: [DaemonAPI.ReportNode], cursor: String?) = ([], nil)
        do {
            known = try await readLineage(model)
            guard ask == mine else { return }
        } catch {
            guard ask == mine else { return }
            // A control plane that does not list nodes yet leaves the issues and PRs without figures.
            if !kind.fromForge { problem = ReportValueWords.sentence(error) }
        }
        guard kind.fromForge else {
            lineage = known.nodes
            lineageCursor = known.cursor
            lists = []
            answered(wanted)
            if problem == nil { model.keepWork(Kept(hosts: [], lists: [], lineage: known.nodes, lineageCursor: known.cursor, boards: []),
                                               .list, wanted) }
            return
        }
        let state = filter.state.forge
        let kind = kind
        let board = filter.board
        var readBoards: [DaemonAPI.ProjectBoard] = []
        if kind == .issue {
            readBoards = await model.workBoards()
            guard ask == mine else { return }
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
        if kind == .issue { boards = readBoards }
        lineage = known.nodes
        lineageCursor = known.cursor
        lists = got
        answered(wanted)
        // Only a read some forge answered is kept: a failed one would draw an empty list next time.
        if got.contains(where: { ($0.list.errors ?? []).isEmpty }) {
            model.keepWork(Kept(hosts: got.map(\.host), lists: got.map(\.list), lineage: known.nodes,
                                lineageCursor: known.cursor, boards: readBoards), .list, wanted)
        }
    }

    /// The machines answered for what is asked: the rows are theirs now.
    private func answered(_ wanted: String) {
        shownFor = wanted
        fromDevice = false
    }

    func loadMore(model: any WorkModel) async {
        // A page after the copy's is read once the machines answered (#4930): the copy's cursors may be old.
        guard !fromDevice else { return }
        loadingMore = true
        pageProblem = nil
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
            pageProblem = ReportValueWords.sentence(error)
        }
    }
}

/// The Work lists, one per kind, kept by the model while the app runs (#3257).
@MainActor
final class WorkLists {
    /// Work ▸ Features (#3269): the features read, and the ones opened.
    let features = WorkFeaturesState()
    #if os(macOS)
    /// Work ▸ Timeline (#4173): the Mac's alone for now (remote: by design).
    let timeline = WorkTimelineState()
    #endif
    private var byKind: [WorkList.Kind: WorkListState] = [:]

    subscript(kind: WorkList.Kind) -> WorkListState {
        if let state = byKind[kind] { return state }
        let state = WorkListState(kind: kind)
        byKind[kind] = state
        return state
    }
}
