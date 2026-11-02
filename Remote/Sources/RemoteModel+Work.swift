import AgentsKitCore
import Foundation

/// Work on the Remote (#3256): the window's views (`Shared/UI/Work`), each call to the machine it
/// names. The home host is `.mac` here, as its folders are; another host is reached over the
/// phone's own link to it, and only while that answers.
extension RemoteModel {
    func showWork(_ place: WorkPlace) {
        if place != workHistory.current { workHistory.go(place) }
        sidebarItem = .work
    }

    var forgeMachines: [(id: MachineRef, name: String)] {
        workMachines { $0.has(Capability.forge1) && $0.state != "offline" }
    }

    var lineageMachines: [(id: MachineRef, name: String)] {
        workMachines { $0.has(Capability.lineage1) }
    }

    /// The control plane's machines that run agents, can do `can` and answer this phone: the
    /// home host first, as `.mac`, then the rest by name. Empty without a control plane, as on
    /// the Mac.
    private func workMachines(_ can: (DaemonAPI.ControlMachine) -> Bool) -> [(id: MachineRef, name: String)] {
        controlHosts
            .filter { $0.runsAgents && can($0) }
            .compactMap { row -> (id: MachineRef, name: String)? in
                let id: MachineRef = row.id == controlHome ? .mac : row.id
                return hostClient(id) == nil ? nil : (id: id, name: row.name)
            }
            .sorted { ($0.id == .mac ? 0 : 1, $0.name) < ($1.id == .mac ? 0 : 1, $1.name) }
    }

    func forgeWrites(on host: MachineRef) -> Bool {
        let id = host == .mac ? controlHome : host
        return controlHosts.first { $0.id == id }?.has(Capability.forgeWrite1) ?? false
    }

    func forgeList(_ kind: WorkList.Kind, _ request: DaemonAPI.ForgeListRequest,
                   on host: MachineRef) async throws -> DaemonAPI.ForgeList {
        try await workClient(host).call(kind == .pr ? DaemonAPI.Method.forgePulls : DaemonAPI.Method.forgeIssues,
                                        request, returning: DaemonAPI.ForgeList.self)
    }

    func forgeItem(_ node: DaemonAPI.LineageNode, cursor: String?,
                   on host: MachineRef) async throws -> DaemonAPI.ForgeItemDetail {
        try await workClient(host).call(node.kind == "pr" ? DaemonAPI.Method.forgePull : DaemonAPI.Method.forgeIssue,
                                        DaemonAPI.ForgeItemRequest(node: node, cursor: cursor),
                                        returning: DaemonAPI.ForgeItemDetail.self)
    }

    func forge<R: Decodable & Sendable>(_ method: String, _ params: some Encodable & Sendable, returning: R.Type,
                                        on host: MachineRef) async throws -> R {
        try await workClient(host).call(method, params, returning: R.self)
    }

    func reportNodes(_ query: DaemonAPI.ReportNodesQuery) async throws -> DaemonAPI.ReportNodes? {
        guard let controlPlane else { return nil }
        return try await controlPlane.call(DaemonAPI.Method.reportsNodes, query, returning: DaemonAPI.ReportNodes.self)
    }

    func lineageWalk(_ node: DaemonAPI.LineageNode, on host: MachineRef) async throws -> DaemonAPI.LineageGraph {
        try await workClient(host).call(DaemonAPI.Method.lineageWalk,
                                        DaemonAPI.LineageNodeRequest(node: node, depth: LineageList.depth),
                                        returning: DaemonAPI.LineageGraph.self)
    }

    func lineageCost(_ node: DaemonAPI.LineageNode, on host: MachineRef) async -> DaemonAPI.LineageCostRollup? {
        try? await workClient(host).call(DaemonAPI.Method.lineageCost, DaemonAPI.LineageNodeRequest(node: node),
                                         returning: DaemonAPI.LineageCostRollup.self)
    }

    func workSessionTitle(_ id: UUID) -> String? { work.agent(id)?.title }

    func workSessionState(_ id: UUID) -> AgentState? { work.agent(id)?.state }

    func openWorkSession(_ id: UUID) { sidebarItem = .session(id) }

    /// The client for a Work call: the home host's, or another's while it answers.
    private func workClient(_ host: MachineRef) throws -> DaemonClient {
        guard let client = hostClient(host) else { throw HostAway(host: host) }
        return client
    }
}
