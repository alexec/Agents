import Foundation

/// The shared work of archiving a session and the live sessions it started.
/// Each client supplies its own call for one session, because leaving the chat has
/// different effects in the window and on the Remote.
@MainActor
public enum ArchiveActions {
    /// The approval that keeps an archived session and the folder that owns it.
    public struct Denial {
        public let approval: Approval
        public let folder: FolderKey
    }

    /// A page of archived sessions, stamped with the host that returned it.
    public struct ArchivedSearchPage {
        public let agents: [Agent]
        public let next: DaemonAPI.ListRequest?
    }

    /// Build the shared denial for a session's request to be archived.
    public static func denial(for agent: Agent) -> Denial {
        Denial(
            approval: Approval(kind: .archive, key: agent.id.uuidString, title: agent.title ?? "", digest: nil,
                               line: "", actions: [.deny], agentID: agent.id),
            folder: FolderKey(host: agent.host, folder: agent.folderPath))
    }

    /// Fetch one page for archived-session search. A cancelled search must not replace
    /// the results of the newer search that superseded it.
    public static func searchArchived(
        _ request: DaemonAPI.ListRequest,
        on host: MachineRef,
        fetch: () async -> [Agent]?
    ) async -> ArchivedSearchPage? {
        guard let found = await fetch(), !Task.isCancelled else { return nil }
        let archived = found.filter { $0.state == .archived }.map { agent in
            var agent = agent
            agent.host = host
            return agent
        }
        return ArchivedSearchPage(agents: archived, next: request.next(after: found))
    }

    /// Archive a session and its live descendants, and return what Undo must restore.
    /// A child that another action archived while this ran is left as it is.
    public static func archiveWithChildren(
        _ id: UUID,
        in work: AgentsModel,
        andLeave: Bool,
        archiveOne: (UUID, Bool) async -> Bool
    ) async -> ArchiveUndo? {
        let children = work.liveDescendants(of: id).map(\.id)
        let agent = work.agent(id)
        let stopped = ([agent] + children.map(work.agent)).contains {
            $0.map { ArchiveUndo.stops($0.state) } ?? false
        }
        guard await archiveOne(id, andLeave) else { return nil }

        var agentIDs = [id]
        for child in children where work.agent(child)?.state != .archived {
            if await archiveOne(child, andLeave) { agentIDs.append(child) }
        }
        return ArchiveUndo(agentIDs: agentIDs, title: agent?.title, stopped: stopped)
    }
}
