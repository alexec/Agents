import AgentsKitCore
import SwiftUI

/// What the Work views (#3119, #3130) ask of the app that draws them: the Mac's `AppModel` and
/// the Remote's `RemoteModel` (#3256). Each reaches the machines its own way: the Mac through the
/// control plane's hosts, the phone through its home host and the others it has a link to.
@MainActor
protocol WorkModel: AnyObject, Sendable {
    /// Work's places: the list or the item's page open, and the ones before and after it.
    var workHistory: LineageHistory<WorkPlace> { get set }
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
    /// Show a session's chat.
    func openWorkSession(_ id: UUID)
    /// The new-session form in a folder, filled in. Why it did not open, or nil.
    func offerStart(_ start: AppViewStart, in key: FolderKey) -> String?
}

extension WorkModel {
    /// Where Work is: Issues until something else is opened.
    var workPlace: WorkPlace { workHistory.current ?? WorkPlace(kind: .issue) }
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
