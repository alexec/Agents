import Foundation

extension DaemonCore {
    /// `client/catchUp` (#175): what a client reconnecting needs first, in one answer
    /// rather than six calls one after another over a phone's link. With it, the disk and
    /// the store notes every page shows, and the parts the pages on screen asked for
    /// (#884): through the relay each call is a round trip of two or three seconds.
    func catchUp(_ request: DaemonAPI.CatchUpRequest) async -> DaemonAPI.CatchUpSnapshot {
        var snapshot = DaemonAPI.CatchUpSnapshot(projects: allProjects(includeArchived: false),
                                                 agents: listAgents(request.agents),
                                                 permissions: pendingPermissionRequests(),
                                                 elicitations: pendingElicitations(),
                                                 attention: attentionPending(),
                                                 resuming: stillResuming())
        snapshot.disk = diskState()
        snapshot.storeNotes = storeNotes()
        snapshot.milestones = milestones()
        let parts = Set(request.parts)
        if parts.contains(.workflows) { snapshot.workflows = allWorkflows() }
        if parts.contains(.pins) { snapshot.pins = pinsList() }
        if parts.contains(.leases) {
            snapshot.leases = .init(leases: await leaseSnapshot(), hosted: await hostedServers.snapshot(),
                                    health: await mcpHealthSnapshot())
        }
        return snapshot
    }
}
