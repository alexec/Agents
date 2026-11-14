import AgentsKitCore
import AppKit
import Foundation
import os

/// Folders: the sidebar's lists, the archived fold and search.
extension AppModel {
    // MARK: Folders

    /// The ones the sidebar lists.
    var liveFolders: [DaemonAPI.FolderSummary] { work.liveFolders }

    var archivedFolders: [DaemonAPI.FolderSummary] { work.archivedFolders }

    var selectedFolderSummary: DaemonAPI.FolderSummary? { work.folder(selectedFolderKey) }

    /// A folder's agents in one group, newest first.
    func agents(in key: FolderKey?, group: AgentGroup) -> [Agent] {
        work.agents(in: key, group: group)
    }

    /// A folder's newest `limit` archived sessions, for its Archived page when it opens
    /// (#164): the window holds the live agents, and a page of archived ones per open
    /// Archived page. Answers whether the host
    /// did, so the page can tell an empty archive from a silent host (#664).
    @discardableResult
    func loadArchived(in key: FolderKey, limit: Int = archivedShown) async -> Bool {
        let request = DaemonAPI.ListRequest(archivedOnly: true, folder: key.folder,
                                            limit: limit, lean: true)
        guard let listed = try? await client(for: key.host).call(DaemonAPI.Method.agentsList, request,
                                                                  returning: [Agent].self) else { return false }
        work.takeListed(listed.map { var agent = $0; agent.host = key.host; return agent })
        return true
    }

    /// The archived sessions of a folder that hold `words`, for the Archived Sessions page's
    /// filter (#4448), so one older than the page held is found too. Let go with the rest
    /// when the page closes.
    @discardableResult
    func searchArchived(in key: FolderKey, words: String) async -> Bool {
        let request = DaemonAPI.ListRequest(archivedOnly: true, folder: key.folder, limit: Self.searchShown,
                                            lean: true, query: words)
        guard let listed = try? await client(for: key.host).call(DaemonAPI.Method.agentsList, request,
                                                                  returning: [Agent].self) else { return false }
        work.takeListed(listed.map { var agent = $0; agent.host = key.host; return agent })
        return true
    }

    /// Let go of a folder's archived sessions when its Archived fold closes (#165),
    /// keeping the one being read and any with a window of its own (#2744).
    func letGoOfArchived(in key: FolderKey) {
        let held = work.agents(in: key, group: .archived).map(\.id).filter { !isBeingRead($0) }
        work.forget(held)
    }

    /// Whether a session is open, in the main window or a window of its own: a let-go
    /// keeps it, or its window says it was deleted (#2744).
    func isBeingRead(_ id: UUID) -> Bool {
        id == selection || popouts[id] != nil
    }
    /// Whether a host has more matches than it has sent: More matches… asks for them.
    var searchHasMore: Bool { !searchNext.isEmpty }

    /// Ask every host for the sessions matching `words`, archived ones included, a capped
    /// page each (#165): the sidebar holds the live ones and filters those itself.
    func searchSessions(_ words: String) async {
        // Let the last page go before the next is asked, including a refinement.
        // Forgetting only when the field was cleared left every query's matches held (#285).
        let earlier = searched.filter { id in
            !isBeingRead(id) && heldAgent(id)?.state == .archived && !isInOpenArchivedFold(id)
        }
        searched = []
        searchNext = [:]
        work.forget(earlier)
        work.saidLines = [:]
        work.issueSessions = [:]
        work.issueHeadings = []
        guard !words.isEmpty else { return }
        let request = DaemonAPI.ListRequest(archivedCommands: false, limit: Self.searchShown, lean: true, query: words)
        let hosts: [MachineRef] = (hasMacHost ? [.mac] : []) + self.hosts.servers.filter { !hostUnreachable($0) }
        let issue = SessionLabelQuery.issue(in: words)
        for host in hosts {
            await search(request, on: host)
            // The sessions on the issue, its sub-issues and their PRs (#3899). A host too old to
            // say matches the #<n> label only.
            if let issue, self.host(host, has: Capability.lineageSessions1),
               let on = try? await client(for: host).call(DaemonAPI.Method.lineageSessions,
                                                          DaemonAPI.LineageSessionsRequest(number: issue),
                                                          returning: DaemonAPI.LineageSessions.self),
               !Task.isCancelled {
                work.noteIssueSessions(on)
            }
            // What was said (#1585): the sessions whose prompts or replies hold the words. Not
            // asked of a host too old to say (#1748).
            if self.host(host, has: Capability.agentsSaid1),
               let said = try? await client(for: host).call(DaemonAPI.Method.agentsSaid,
                                                            DaemonAPI.SaidSearchRequest(text: words),
                                                            returning: DaemonAPI.SaidSearchResult.self),
               !Task.isCancelled {
                for match in said.matches { work.saidLines[match.agentID] = match.line }
            }
        }
    }

    /// The next page from each host that has more, newest first as the host lists them.
    func searchMore() async {
        let next = searchNext
        searchNext = [:]
        for (host, request) in next { await search(request, on: host) }
    }

    func search(_ request: DaemonAPI.ListRequest, on host: MachineRef) async {
        guard let page = await ArchiveActions.searchArchived(request, on: host, fetch: {
            try? await self.client(for: host).call(DaemonAPI.Method.agentsList, request, returning: [Agent].self)
        }) else { return }
        let fresh = page.agents.filter { heldAgent($0.id) == nil }.map(\.id)
        searched.formUnion(fresh)
        work.takeListed(page.agents)
        searchNext[host] = page.next
    }

    /// Whether an archived session is on show in its folder's open Archived fold.
    /// Held, without making a cell: a search or a history page asking must not leave
    /// one behind for every id it looked at (#285).
    func heldAgent(_ id: UUID) -> Agent? {
        work.agents.first { $0.id == id }
    }

    func isInOpenArchivedFold(_ id: UUID) -> Bool {
        guard let agent = heldAgent(id) else { return false }
        // As the sidebar keeps them: in defaults, read here once per search ended.
        return SidebarFolds().isOpen(FolderKey(host: agent.host, folder: agent.folderPath), .archivedSessions)
    }

    /// A workflow's newest runs, archived ones included, for its History (#164).
    /// Archived runs this page brought in are remembered, so a larger page can let go
    /// of the ones that left it, and closing the page lets go of the rest (#285).
    func loadRuns(of workflowID: String, in folder: URL, on host: MachineRef, limit: Int) async {
        let key = RunsKey(host: host, folder: Folder.standardize(folder), workflowID: workflowID)
        let request = DaemonAPI.ListRequest(archivedCommands: false, folder: folder,
                                            startedByWorkflow: workflowID, limit: limit, lean: true)
        guard let listed = try? await client(for: host).call(DaemonAPI.Method.agentsList, request,
                                                              returning: [Agent].self) else { return }
        guard !Task.isCancelled else { return }
        let stamped = listed.map { var agent = $0; agent.host = host; return agent }
        let previous = runsIntroduced[key] ?? []
        var introduced = Set<UUID>()
        for agent in stamped where agent.state == .archived {
            // Already held by a fold, or live, is not this page's to drop later.
            if previous.contains(agent.id) || heldAgent(agent.id) == nil {
                introduced.insert(agent.id)
            }
        }
        let left = previous.subtracting(introduced).filter { id in
            !isBeingRead(id) && heldAgent(id)?.state == .archived && !isInOpenArchivedFold(id)
        }
        work.forget(left)
        work.takeListed(stamped)
        runsIntroduced[key] = introduced
    }

    /// The archived runs one History page brought in, let go when that page closes.
    func letGoOfRuns(of workflowID: String, in folder: URL, on host: MachineRef) {
        let key = RunsKey(host: host, folder: Folder.standardize(folder), workflowID: workflowID)
        guard let ids = runsIntroduced.removeValue(forKey: key) else { return }
        work.forget(ids.filter { id in
            !isBeingRead(id) && heldAgent(id)?.state == .archived && !isInOpenArchivedFold(id)
        })
    }

    struct RunsKey: Hashable {
        var host: MachineRef
        var folder: URL
        var workflowID: String
    }

    /// This window's own counts for a folder, from the grouping its panel uses.
    func counts(in key: FolderKey?) -> [AgentGroup: Int] { work.counts(in: key) }
    func unreadCount(in key: FolderKey?) -> Int { work.unreadCount(in: key) }

    /// How many requests and sessions across every folder need the person: each open
    /// request (#3864), and the sessions under Needs you and Blocked that asked none; not
    /// unread finishes (#1565), and a terminal's agents-secret (#4179). Drives the Dock badge.
    var needsPersonCount: Int {
        liveFolders.reduce(work.terminalRequests.count) { $0 + work.attentionCount(in: $1.key) + work.requestBadgeShift(in: $1.key.folder) }
    }

    /// The Blob's mood on the Dock tile (#1317), from the same groups the sidebar shows.
    var iconMood: IconMood {
        IconMood(counts: liveFolders.lazy.map { self.work.counts(in: $0.key) })
    }

    /// Whether the daemon is bringing this chat back by itself after a restart.
    func isComingBack(_ agent: Agent) -> Bool { work.isComingBack(agent) }

    /// "Started by …" for an agent another agent started, and nil otherwise (028).
    func startedByAgentLabel(_ agent: Agent) -> String? { work.startedByAgentLabel(agent) }

    /// Whether Stop is offered for this chat, in the toolbar and on the card alike.
    func canStop(_ agent: Agent) -> Bool { work.canStop(agent) }
    func blockLines(_ agent: Agent) -> [String] { work.blockLines(agent) }
    func queuedLine(_ agent: Agent) -> String? { work.queuedLine(agent) }
    func isBlocked(_ agent: Agent) -> Bool { work.openBlock(agent) != nil }
}
