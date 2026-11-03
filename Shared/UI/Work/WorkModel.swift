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
    func lineageWalk(_ node: DaemonAPI.LineageNode, on host: MachineRef) async throws -> DaemonAPI.LineageGraph
    func lineageCost(_ node: DaemonAPI.LineageNode, on host: MachineRef) async -> DaemonAPI.LineageCostRollup?
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
