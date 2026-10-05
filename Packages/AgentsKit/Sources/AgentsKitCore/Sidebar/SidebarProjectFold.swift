import Foundation

/// What one project's fold of the sidebar holds: its pinned sessions (#180), its live
/// groups in their order (#182), its archived sessions, and its workflows — as held, and
/// as a search leaves them.
///
/// Worked out here once for every screen that draws the sidebar (#226): the Mac's window,
/// and the Remote on an iPad or an iPhone. The views differ by platform; which row goes
/// under which heading, in what order, does not.
@MainActor
public struct SidebarProjectFold {
    /// The most archived sessions a fold holds while open: a page from the host (#164).
    public static let archivedShown = 50
    /// The most archived matches a fold shows before Show all (#176).
    public static let matchesShown = 10

    /// One live group's heading, and the rows under it, the pinned left out.
    public struct Group: Identifiable {
        public let group: AgentGroup
        public let heading: AgentHeading
        public var id: AgentGroup { group }
        public var agents: [Agent] { heading.agents }
        /// How many under it nobody has opened since they finished (#70).
        public var unread: Int { heading.agents.count(where: \.showsUnread) }
    }

    public let key: ProjectKey
    /// The search's words, trimmed; empty when there is no search.
    public let query: String
    /// The pinned sessions held and not archived, in the order they were put in, as the
    /// search leaves them.
    public private(set) var pinned: [Agent] = []
    /// The live groups with something in them, in `AgentGroup.live`'s order.
    public private(set) var groups: [Group] = []
    /// The archived sessions held, newest first: a page while the fold is open (#165).
    public private(set) var archived: [Agent] = []
    /// Whether the project has a session that is not archived, search or not.
    public private(set) var hasLive = false
    public private(set) var workflows: [WorkflowSummary] = []
    public private(set) var archivedWorkflows: [WorkflowSummary] = []
    /// The project's own name matches the search.
    public private(set) var nameMatches = false

    public var isSearching: Bool { !query.isEmpty }

    /// Whether the project is drawn at all: always, unless a search found nothing in it.
    public var isShown: Bool {
        !isSearching || nameMatches || !pinned.isEmpty || !groups.isEmpty || !archived.isEmpty
            || !workflows.isEmpty || !archivedWorkflows.isEmpty
    }

    /// The pinned sessions' heading: attention on a folded one, so folding it never hides
    /// that somebody is waiting.
    public func pinnedWantsAPerson(in work: AgentsModel) -> Bool {
        pinned.contains { work.group(of: $0) == .needsAttention }
    }

    /// How many archived sessions the fold says it holds: the host's count while there is
    /// no search, since the client holds a page of them only while the fold is open (#165).
    public func archivedCount(_ summary: DaemonAPI.ProjectSummary?) -> Int {
        isSearching ? archived.count : max(summary?.counts[.archived] ?? 0, archived.count)
    }

    /// What has been retired from here (051), the Archived fold's last line.
    public func retiredLine(_ summary: DaemonAPI.ProjectSummary?) -> String? {
        isSearching ? nil : RetirementWords.retiredLine(summary?.retiredCount)
    }

    /// Whether the project has an Archived fold to draw.
    public func showsArchivedFold(_ summary: DaemonAPI.ProjectSummary?) -> Bool {
        archivedCount(summary) > 0 || retiredLine(summary) != nil
    }

    /// The archived rows to draw: a page with no search, the first few matches until Show
    /// all with one.
    public func archivedShown(showingAll: Bool) -> ArraySlice<Agent> {
        archived.prefix(!isSearching ? Self.archivedShown : showingAll ? archived.count : Self.matchesShown)
    }

    /// One project's fold. `isOpen` is whether it is unfolded: folded, nothing under the
    /// row is drawn, so nothing is filed for it, and the row reads its own numbers off the
    /// project's shelf (#165). A search unfolds every project, and `label` is the name the
    /// row shows, which the search also matches.
    public init(_ key: ProjectKey, label: String, in work: AgentsModel, query: String = "", isOpen: Bool) {
        self.key = key
        let words = query.trimmingCharacters(in: .whitespacesAndNewlines)
        self.query = words
        let matcher = words.isEmpty ? nil : SessionLabelQuery(words)
        if matcher != nil { nameMatches = label.localizedCaseInsensitiveContains(words) }
        guard isOpen || matcher != nil else { return }
        let held = work.workflows(in: key.folder)
        let workflows = matcher.map { held.filter($0.matches) } ?? held
        self.workflows = workflows.filter { !$0.isArchived }
        archivedWorkflows = workflows.filter(\.isArchived)

        let shelf = work.shelf(key)
        let pinned = work.pinnedSessions(in: key.folder).compactMap { work.agent($0) }
            .filter { $0.host == key.host && $0.state != .archived }
        let pinnedIDs = Set(pinned.map(\.id))
        self.pinned = matcher.map { pinned.filter($0.matches) } ?? pinned
        for group in AgentGroup.live {
            let held = shelf.groups[group] ?? []
            if !held.isEmpty { hasLive = true }
            let unpinned = pinnedIDs.isEmpty ? held : held.filter { !pinnedIDs.contains($0.id) }
            let shown = matcher.map { unpinned.filter($0.matches) } ?? unpinned
            for heading in group.headings(shown) {
                groups.append(Group(group: group, heading: heading))
            }
        }
        let archived = shelf.groups[.archived] ?? []
        self.archived = matcher.map { archived.filter($0.matches) } ?? archived
    }
}

/// The order the sidebar lists projects in: this Mac's, then each server's in the order
/// the hosts are listed (#145). No headings for hosts: a server's project carries its
/// server's name.
public enum SidebarOrder {
    public static func projects(_ live: [DaemonAPI.ProjectSummary], servers: [HostID]) -> [DaemonAPI.ProjectSummary] {
        live.filter { $0.host == .mac } + servers.flatMap { host in live.filter { $0.host == host } }
    }

    /// The name a project's row shows: `server:Project` on a server, so no heading is
    /// needed for each host (Alex, #145).
    public static func label(_ summary: DaemonAPI.ProjectSummary, hostLabel: (HostID) -> String) -> String {
        summary.host == .mac ? summary.name : "\(hostLabel(summary.host)):\(summary.name)"
    }
}
