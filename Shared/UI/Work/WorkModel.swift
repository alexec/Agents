import AgentsKitCore
import SwiftUI

/// What the Work views (#3119, #3130) ask of the app that draws them: the Mac's `AppModel` and
/// the Remote's `RemoteModel` (#3256). Each reaches the machines its own way: the Mac through the
/// control plane's hosts, the phone through its home host and the others it has a link to.
@MainActor
protocol WorkModel: AnyObject, Sendable {
    /// Work's places: the list or the item's page open, and the ones before and after it.
    var workHistory: LineageHistory<WorkPlace> { get set }
    /// Each Work list's filters, sort and rows (#3257), kept while the app runs.
    var workLists: WorkLists { get }
    /// Open Work at a place: a list, or an item's page.
    func showWork(_ place: WorkPlace)
    /// The machines that read their forges, the home one first.
    var forgeMachines: [(id: MachineRef, name: String)] { get }
    /// The machines that narrow their forges to a board (#3282), the home one first. None on the
    /// Remote: boards are the Mac's and the web page's (tier Mac + web).
    var boardMachines: [(id: MachineRef, name: String)] { get }
    /// The person's projects (#3283), for Work's Project filter: Mac + web, so the Remote has none.
    var workProjects: [WorkList.Project] { get }
    /// The machines that keep links, the home one first.
    var lineageMachines: [(id: MachineRef, name: String)] { get }
    /// Whether a machine takes the Work pages' writes (#3130).
    func forgeWrites(on host: MachineRef) -> Bool
    func forgeList(_ kind: WorkList.Kind, _ request: DaemonAPI.ForgeListRequest,
                   on host: MachineRef) async throws -> DaemonAPI.ForgeList
    func forgeItem(_ node: DaemonAPI.LineageNode, cursor: String?,
                   on host: MachineRef) async throws -> DaemonAPI.ForgeItemDetail
    func forge<R: Decodable & Sendable>(_ method: String, _ params: some Encodable & Sendable, returning: R.Type,
                                        on host: MachineRef) async throws -> R
    /// A page of the lineage nodes of a kind, from the control plane; nil with none.
    func reportNodes(_ query: DaemonAPI.ReportNodesQuery) async throws -> DaemonAPI.ReportNodes?
    /// What a node is linked to, `depth` links away (1 to 4).
    func lineageWalk(_ node: DaemonAPI.LineageNode, depth: Int, on host: MachineRef) async throws -> DaemonAPI.LineageGraph
    func lineageCost(_ node: DaemonAPI.LineageNode, on host: MachineRef) async -> DaemonAPI.LineageCostRollup?
    /// An issue's or an epic's estimate from past work (#3560); nil where the machine cannot make one.
    func lineageEstimate(_ node: DaemonAPI.LineageNode, on host: MachineRef) async -> DaemonAPI.LineageEstimate?
    /// A session's title, or nil when this app does not know the session.
    func workSessionTitle(_ id: UUID) -> String?
    /// A session's state, or nil when this app does not know the session (#3268, a plan's marks).
    func workSessionState(_ id: UUID) -> AgentState?
    /// The session that leads an epic, of those this app knows (#3269, Work ▸ Features); nil with none.
    func workLead(of epic: DaemonAPI.LineageNode) -> Agent?
    /// Show a session's chat.
    func openWorkSession(_ id: UUID)
    /// The new-session form in a folder, filled in. Why it did not open, or nil.
    func offerStart(_ start: AppViewStart, in key: FolderKey) -> String?
}

extension WorkModel {
    var workProjects: [WorkList.Project] { [] }

    /// The boards of every machine's folders' projects (#3282), each once, by url, the first
    /// name kept; none from a machine that cannot be read.
    func workBoards() async -> [DaemonAPI.ProjectBoard] {
        let machines = boardMachines
        var got: [(host: MachineRef, boards: [DaemonAPI.ProjectBoard])] = []
        await withTaskGroup(of: (MachineRef, [DaemonAPI.ProjectBoard]).self) { group in
            for machine in machines {
                group.addTask {
                    let list = try? await self.forge(DaemonAPI.Method.forgeBoards, DaemonAPI.ForgeBoardsRequest(),
                                                     returning: DaemonAPI.ForgeBoards.self, on: machine.id)
                    return (machine.id, list?.boards ?? [])
                }
            }
            for await (host, boards) in group { got.append((host, boards)) }
        }
        // The machines' own order, the home one first, so the same board keeps the same name.
        let order = machines.map(\.id)
        got.sort { (order.firstIndex(of: $0.host) ?? .max) < (order.firstIndex(of: $1.host) ?? .max) }
        return WorkList.mergeBoards(got.map(\.boards))
    }

    /// The machines a list asks: those that narrow to the board when one is chosen.
    func workMachines(board: String) -> [(id: MachineRef, name: String)] {
        board.isEmpty ? forgeMachines : boardMachines
    }

    /// Where Work is: Issues until something else is opened.
    var workPlace: WorkPlace { workHistory.current ?? WorkPlace(kind: .issue) }

    /// Where the item's page open stands in the list it was opened from (#3257); nil on a list,
    /// or on a page opened from a link or an address.
    var workNeighbours: WorkList.Neighbours? {
        let place = workPlace
        guard place.fromList, let ref = place.ref else { return nil }
        return workLists[place.kind].neighbours(of: ref)
    }

    /// Whether Next can go on: a row below, or another page to read.
    var workHasNext: Bool {
        guard let n = workNeighbours else { return false }
        return n.next != nil || workLists[workPlace.kind].hasMore
    }

    /// Previous or Next (#3257): the row above or below, in place of this one, so Back goes to
    /// the list and not through each item. Next at the last row read reads the next page first.
    func stepWork(forward: Bool) async {
        let place = workPlace
        guard let n = workNeighbours, let ref = place.ref else { return }
        let list = workLists[place.kind]
        let to = forward ? await list.next(after: ref, model: self) : n.previous
        guard let to, workPlace == place else { return }
        list.opened = to
        workHistory.replace(WorkPlace(kind: place.kind, ref: to, fromList: true))
    }
}

extension View {
    /// `.task(id:)` for Work's loads, run to their end. On the Remote a collapsing split view
    /// says a page disappeared while it stays on screen (#3256): a cancelled load was never
    /// started again, and the page waited for ever. A load checks that its id is still the
    /// current one before it shows what it read, so a newer one wins.
    func workTask<ID: Equatable>(id: ID, _ work: @escaping @MainActor () async -> Void) -> some View {
        task(id: id) { await Task { await work() }.value }
    }
}
