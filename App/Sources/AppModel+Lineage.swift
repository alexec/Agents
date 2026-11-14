import AgentsKitCore
import AppKit
import Foundation
import os

/// Lineage and the Work page's machine lists.
extension AppModel {
    // MARK: Lineage

    /// What a node is linked to, on a host (#3087): an epic's plan reads its children's links.
    func lineageWalk(_ node: DaemonAPI.LineageNode, depth: Int, on host: MachineRef) async throws -> DaemonAPI.LineageGraph {
        try await client(for: host).call(DaemonAPI.Method.lineageWalk,
                                         DaemonAPI.LineageNodeRequest(node: node, depth: depth),
                                         returning: DaemonAPI.LineageGraph.self)
    }

    /// Ask a lead's host for its epic's progress when its state or labels changed since. A call
    /// that fails keeps what the row said: the next wake asks again.
    func loadLeadProgress(_ agent: Agent) async {
        guard let turn = LeadProgress.turn(agent), agent.state != .archived, leadAsked[agent.id] != turn,
              self.agent(agent.id, has: Capability.lineage1), self.agent(agent.id, has: Capability.forge1) else { return }
        leadAsked[agent.id] = turn
        let host = host(ofAgent: agent.id)
        guard let walked = try? await client(for: host).call(
            DaemonAPI.Method.lineageWalk,
            DaemonAPI.LineageNodeRequest(node: LineageList.node(ofSession: agent.id), depth: 1),
            returning: DaemonAPI.LineageGraph.self) else { return }
        guard let epic = LeadProgress.epic(of: agent.id, in: walked.links) else {
            leadProgress[agent.id] = nil
            return
        }
        guard let plan = try? await client(for: host).call(DaemonAPI.Method.forgePlan, DaemonAPI.ForgePlanRequest(node: epic),
                                                           returning: DaemonAPI.ForgePlan.self) else { return }
        leadProgress[agent.id] = LeadProgress.words(plan)
    }

    /// An issue's or a PR's cost rolled up, from a host; nil when it will not say.
    func lineageCost(_ node: DaemonAPI.LineageNode, on host: MachineRef) async -> DaemonAPI.LineageCostRollup? {
        try? await client(for: host).call(DaemonAPI.Method.lineageCost, DaemonAPI.LineageNodeRequest(node: node),
                                          returning: DaemonAPI.LineageCostRollup.self)
    }

    func lineageEstimate(_ node: DaemonAPI.LineageNode, on host: MachineRef) async -> DaemonAPI.LineageEstimate? {
        try? await client(for: host).call(DaemonAPI.Method.lineageEstimate, DaemonAPI.LineageEstimateRequest(node: node),
                                          returning: DaemonAPI.LineageEstimate.self)
    }

    func lineageForecast(_ node: DaemonAPI.LineageNode, on host: MachineRef) async -> DaemonAPI.LineageForecast? {
        try? await client(for: host).call(DaemonAPI.Method.lineageForecast, DaemonAPI.LineageForecastRequest(node: node),
                                          returning: DaemonAPI.LineageForecast.self)
    }

    /// The machines that keep links (#3157), for an Issue page's estimate and an epic's plan: This
    /// Mac first, then the rest by name. Empty without a control plane, where there is only one.
    var lineageMachines: [(id: MachineRef, name: String)] {
        let mine = thisMacHostID
        return (controlPlaneHosts ?? [])
            .filter { $0.has(Capability.lineage1) }
            .map { (id: $0.id, name: $0.id == mine ? "This Mac" : $0.name) }
            .sorted { ($0.id == mine ? 0 : 1, $0.name) < ($1.id == mine ? 0 : 1, $1.name) }
    }

    /// Work's projects (#3283): New Session's, each folder named by the machine Work's lists
    /// read it on, this Mac by its control plane id.
    var workProjects: [WorkList.Project] {
        let mine = thisMacHostID ?? .mac
        return newSessionProjects.map { choice in
            WorkList.Project(id: choice.id, name: choice.name, folders: Set(choice.folders.map {
                WorkList.folderKey(host: $0.host == .mac ? mine : $0.host, path: $0.folder.path(percentEncoded: false))
            }))
        }
    }

    /// This window's copy (#4791). A walk's window (`--walk`, run-app) keeps its copy in the walk's
    /// own folder, never the person's: a scratch session must not draw in the person's window, nor
    /// the person's in a walk's screenshots (#4930).
    static func windowCopy() -> LocalCopy {
        guard let walk = ControlConfig.walkFolder else { return .mac() }
        return LocalCopy(folder: walk.appendingPathComponent("copy", isDirectory: true), cap: LocalCopy.macCap)
    }

    /// Work's part of this device's copy (#4930).
    var workCopy: LocalCopy? { localCopy?.copy }

    /// The machines that read their forges (#3119), This Mac first: Work's issues and PRs come from each.
    var forgeMachines: [(id: MachineRef, name: String)] {
        let mine = thisMacHostID
        return (controlPlaneHosts ?? [])
            .filter { $0.has(Capability.forge1) && $0.state != "offline" }
            .map { (id: $0.id, name: $0.id == mine ? "This Mac" : $0.name) }
            .sorted { ($0.id == mine ? 0 : 1, $0.name) < ($1.id == mine ? 0 : 1, $1.name) }
    }

    /// The machines that narrow their forges to a board (#3282), This Mac first.
    var boardMachines: [(id: MachineRef, name: String)] {
        let narrows = Set((controlPlaneHosts ?? []).filter { $0.has(Capability.forgeBoards1) }.map(\.id))
        return forgeMachines.filter { narrows.contains($0.id) }
    }

    /// The machines that draw Work ▸ Timeline (#4173), This Mac first.
    var timelineMachines: [(id: MachineRef, name: String)] {
        let draws = Set((controlPlaneHosts ?? []).filter { $0.has(Capability.workTimeline1) }.map(\.id))
        return forgeMachines.filter { draws.contains($0.id) }
    }

    /// The machines that give Work ▸ Features in one read (#4586), This Mac first.
    var featuresMachines: [(id: MachineRef, name: String)] {
        let reads = Set((controlPlaneHosts ?? []).filter { $0.has(Capability.workFeatures1) }.map(\.id))
        return forgeMachines.filter { reads.contains($0.id) }
    }

    /// The machines that read docs (#3321), this Mac first.
    var docsMachines: [(id: MachineRef, name: String)] {
        let mine = thisMacHostID
        return (controlPlaneHosts ?? [])
            .filter { $0.has(Capability.docs1) && $0.state != "offline" }
            .map { (id: $0.id, name: $0.id == mine ? "This Mac" : $0.name) }
            .sorted { ($0.id == mine ? 0 : 1, $0.name) < ($1.id == mine ? 0 : 1, $1.name) }
    }

    /// The machines that read messages (#4344), this Mac first.
    var messagesMachines: [(id: MachineRef, name: String)] {
        let mine = thisMacHostID
        return (controlPlaneHosts ?? [])
            .filter { $0.has(Capability.messages1) && $0.state != "offline" }
            .map { (id: $0.id, name: $0.id == mine ? "This Mac" : $0.name) }
            .sorted { ($0.id == mine ? 0 : 1, $0.name) < ($1.id == mine ? 0 : 1, $1.name) }
    }

    /// The machines that mark all their messages read (#5137), in messagesMachines' order.
    var messagesMarkMachines: [(id: MachineRef, name: String)] {
        let marks = Set((controlPlaneHosts ?? []).filter { $0.has(Capability.messagesMarkRead1) }.map(\.id))
        return messagesMachines.filter { marks.contains($0.id) }
    }

    /// Open in Files on a doc's page (#3321): the file as its folder's own page, as a pinned page
    /// opens. The folder as this window knows it, so the page finds it; false when it knows none.
    func showDocFile(_ path: String, folder: String, on host: MachineRef) -> Bool {
        let wanted = Folder.standardize(URL(fileURLWithPath: folder))
        guard let known = folders.first(where: { $0.host == host && Folder.standardize($0.folder.folder) == wanted }) else {
            return false
        }
        showPin(path, in: FolderKey(host: host, folder: known.folder.folder))
        return true
    }

    /// One of Docs' reads (#3321): `docs/list`, `docs/search` or `docs/read`, on a machine.
    func docs<R: Decodable & Sendable>(_ method: String, _ params: some Encodable & Sendable, returning: R.Type,
                                       on host: MachineRef) async throws -> R {
        try await client(for: host).call(method, params, returning: R.self)
    }

    /// One of Messages' reads (#4344): `messages/conversations` or `messages/read`, on a machine.
    func messages<R: Decodable & Sendable>(_ method: String, _ params: some Encodable & Sendable, returning: R.Type,
                                           on host: MachineRef) async throws -> R {
        try await client(for: host).call(method, params, returning: R.self)
    }

    /// A page of a machine's issues or pull requests (#3129), as Work lists them.
    func forgeList(_ kind: WorkList.Kind, _ request: DaemonAPI.ForgeListRequest,
                   on host: MachineRef) async throws -> DaemonAPI.ForgeList {
        try await client(for: host).call(kind == .pr ? DaemonAPI.Method.forgePulls : DaemonAPI.Method.forgeIssues,
                                         request, returning: DaemonAPI.ForgeList.self)
    }

    /// One issue or pull request with its body and a page of its comments (#3129), for its Work page.
    func forgeItem(_ node: DaemonAPI.LineageNode, cursor: String?,
                   on host: MachineRef) async throws -> DaemonAPI.ForgeItemDetail {
        try await client(for: host).call(node.kind == "pr" ? DaemonAPI.Method.forgePull : DaemonAPI.Method.forgeIssue,
                                         DaemonAPI.ForgeItemRequest(node: node, cursor: cursor),
                                         returning: DaemonAPI.ForgeItemDetail.self)
    }

    /// Whether a machine takes the Work pages' writes (#3130): comment, labels, close, merge,
    /// approve, rerun, and a pull request's logs and diff.
    func forgeWrites(on host: MachineRef) -> Bool {
        controlPlaneHosts?.first { $0.id == host }?.has(Capability.forgeWrite1) ?? false
    }

    /// One of the Work pages' writes or reads (#3130), on the machine that read the item.
    func forge<R: Decodable & Sendable>(_ method: String, _ params: some Encodable & Sendable, returning: R.Type,
                             on host: MachineRef) async throws -> R {
        try await client(for: host).call(method, params, returning: R.self)
    }

    /// A session's title for Work's links (#3256).
    func workSessionTitle(_ id: UUID) -> String? { work.agent(id)?.title }

    func workSessionState(_ id: UUID) -> AgentState? { work.agent(id)?.state }

    func openWorkSession(_ id: UUID) { openAgent(id) }

    func workLead(of epic: DaemonAPI.LineageNode) -> Agent? { WorkFeatures.lead(of: epic, in: work.agents) }

    var workAgents: [Agent] { work.agents }

    /// A page of the lineage nodes of a kind (#3118), from the control plane: Work's figures; nil
    /// with no control plane.
    func reportNodes(_ query: DaemonAPI.ReportNodesQuery) async throws -> DaemonAPI.ReportNodes? {
        guard let controlRequests else { return nil }
        return try await controlRequests.call(DaemonAPI.Method.reportsNodes, query, returning: DaemonAPI.ReportNodes.self)
    }

    /// Every machine's sessions on these nodes, from the control plane's merged copy (#4276): Work ▸
    /// Timeline's starts; nil with no control plane, or one from before it.
    func lineageSessionsOn(_ nodes: [DaemonAPI.LineageNode]) async -> DaemonAPI.LineageSessionsOn? {
        guard let controlRequests, !nodes.isEmpty else { return nil }
        return try? await controlRequests.call(DaemonAPI.Method.lineageSessionsOn, DaemonAPI.LineageSessionsOnRequest(nodes: nodes),
                                               returning: DaemonAPI.LineageSessionsOn.self)
    }


    /// Go to a match in the open chat: earlier pages come in until its turn is in hand
    /// (`AgentsModel.reveal`, bounded), then the chat goes to it, or as near as it can.
    func reveal(_ match: DaemonAPI.FindMatch) async {
        await work.reveal(index: match.index) { await self.loadEarlier(turns: $0) }
        focusEntry(match.entryID, at: match.index)
    }

    /// What this agent last asked the user to look at, taken rather than read: a file
    /// that has been put in front of somebody is not still waiting to be.
    func takeFileToShow(for agentID: UUID) -> ShownFile? {
        work.takeFileToShow(for: agentID)
    }
}
