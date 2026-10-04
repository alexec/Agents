import Foundation

extension DaemonCore {
    /// `client/catchUp` (#175): what a client reconnecting needs first, in one answer
    /// rather than six calls one after another over a phone's link.
    func catchUp(_ request: DaemonAPI.CatchUpRequest) -> DaemonAPI.CatchUpSnapshot {
        DaemonAPI.CatchUpSnapshot(projects: allProjects(includeArchived: false),
                                  agents: listAgents(request.agents),
                                  permissions: pendingPermissionRequests(),
                                  elicitations: pendingElicitations(),
                                  attention: attentionPending(),
                                  resuming: stillResuming())
    }
}
