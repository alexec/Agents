import Foundation

/// What one folder's fold of the sidebar holds: its pinned sessions (#180), its live
/// groups in their order (#182), its archived sessions, and its workflows — as held, and
/// as a search leaves them.
///
/// Worked out here once for every screen that draws the sidebar (#226): the Mac's window,
/// and the Remote on an iPad or an iPhone. The views differ by platform; which row goes
/// under which heading, in what order, does not.
@MainActor
public struct SidebarFolderFold {
    /// The most archived sessions a fold holds while open: a page from the host (#164).
    nonisolated public static let archivedShown = 50
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

    public let key: FolderKey
    /// The search's words, trimmed; empty when there is no search.
    public let query: String
    /// The pinned sessions held and not archived, in the order they were put in, as the
    /// search leaves them.
    public private(set) var pinned: [Agent] = []
    /// The pinned workflows held and not archived (#432), in their order, after the pinned
    /// sessions under the same heading, as the search leaves them. They leave `workflows`.
    public private(set) var pinnedWorkflows: [WorkflowSummary] = []
    /// The live groups with something in them, in `AgentGroup.live`'s order.
    public private(set) var groups: [Group] = []
    /// The live sessions, the pinned left out, as one list newest started first (#495):
    /// no heading per state, the state is the row's mark. By when they started, not by
    /// their last activity, so a working session does not climb past the pointer with
    /// every line it writes (as folders stopped doing, #357).
    public private(set) var sessions: [Agent] = []
    /// The archived sessions held, newest first: a page while the fold is open (#165).
    public private(set) var archived: [Agent] = []
    /// The three most recently archived sessions, shown under Sessions (#2587).
    public var recentArchived: [Agent] { Array(archived.prefix(3)) }
    /// Whether the folder has a session that is not archived, search or not.
    public private(set) var hasLive = false
    public private(set) var workflows: [WorkflowSummary] = []
    /// The two sections within the Workflows fold, after pins and archived files leave it.
    public var folderWorkflows: [WorkflowSummary] { workflows.filter { $0.scope != "user" } }
    public var userWorkflows: [WorkflowSummary] { workflows.filter { $0.scope == "user" } }
    public private(set) var archivedWorkflows: [WorkflowSummary] = []
    /// The folder's own name matches the search.
    public private(set) var nameMatches = false

    public var isSearching: Bool { !query.isEmpty }

    /// Whether the folder's rows are open, by hand or by a search. Folded, it holds no
    /// rows at all, not even the ones that need nothing filed (#356): `NSOutlineView`
    /// does not follow the children of an item it has not expanded, so a row that came or
    /// went under a folded folder (an Archived fold appearing as a session is archived,
    /// a pinned page, "No sessions yet") left its count apart from SwiftUI's. The next
    /// update then threw (#237), and Apple Intelligence reading the list asked for a row
    /// SwiftUI no longer had, which is a crash.
    public let isUnfolded: Bool

    /// Whether the folder is drawn at all: always, unless a search found nothing in it.
    public var isShown: Bool {
        !isSearching || nameMatches || hasPinned || !groups.isEmpty || !archived.isEmpty
            || !workflows.isEmpty || !archivedWorkflows.isEmpty
    }

    /// Whether there is a Pinned heading to draw: a pinned session or workflow.
    public var hasPinned: Bool { !pinned.isEmpty || !pinnedWorkflows.isEmpty }

    /// How many the Pinned heading counts: sessions and workflows.
    public var pinnedCount: Int { pinned.count + pinnedWorkflows.count }

    /// The pinned sessions' heading: attention on a folded one, so folding it never hides
    /// that somebody is waiting.
    public func pinnedWantsAPerson(in work: AgentsModel) -> Bool {
        pinned.contains { work.group(of: $0) == .needsAttention } || pinnedWorkflows.contains(where: \.needsAPerson)
    }

    /// How many archived sessions the fold says it holds: the host's count while there is
    /// no search, since the client holds a page of them only while the fold is open (#165).
    public func archivedCount(_ summary: DaemonAPI.FolderSummary?) -> Int {
        isSearching ? archived.count : max(summary?.counts[.archived] ?? 0, archived.count)
    }

    /// Whether the folder has an Archived fold to draw: never while it is folded.
    public func showsArchivedFold(_ summary: DaemonAPI.FolderSummary?) -> Bool {
        isUnfolded && archivedCount(summary) > 0
    }

    /// Whether the folder's pinned pages (#159) go first: unfolded, and not while
    /// searching, since the search is for sessions.
    public var showsPinnedPages: Bool { isUnfolded && !isSearching }

    /// Whether the fold says it has no sessions yet: unfolded, with none that is live.
    public var showsNoSessions: Bool { isUnfolded && !isSearching && !hasLive }

    /// The archived rows to draw: a page with no search, the first few matches until Show
    /// all with one.
    public func archivedShown(showingAll: Bool) -> ArraySlice<Agent> {
        archived.prefix(!isSearching ? Self.archivedShown : showingAll ? archived.count : Self.matchesShown)
    }

    /// One folder's fold. `isOpen` is whether it is unfolded: folded, nothing under the
    /// row is drawn, so nothing is filed for it, and the row reads its own numbers off the
    /// folder's shelf (#165). A search unfolds every folder, and `label` is the name the
    /// row shows, which the search also matches. `keptInUnread` is the session Unread keeps
    /// while it is open, listed there and not here (#689). `on` is the smart groups turned
    /// on (#846): with Pinned off, the pinned are listed here as any other.
    public init(_ key: FolderKey, label: String, in work: AgentsModel, query: String = "", isOpen: Bool,
                keptInUnread: UUID? = nil, on: Set<SidebarSmartRow> = SidebarSmartRow.all) {
        self.key = key
        let words = query.trimmingCharacters(in: .whitespacesAndNewlines)
        self.query = words
        let matcher = words.isEmpty ? nil : SessionLabelQuery(words, said: work.saidLines)
        isUnfolded = isOpen || matcher != nil
        if matcher != nil { nameMatches = label.localizedCaseInsensitiveContains(words) }
        guard isUnfolded else { return }
        let held = work.workflows(in: key.folder)
        let workflows = matcher.map { held.filter($0.matches) } ?? held
        // Pinned (#432): in the pin's order, out of the Workflows group. An archived one
        // shows only under Archived workflows, though its pin may linger until the host
        // takes it off.
        let pinsOn = on.contains(.pinned)
        let pinnedFlows = !pinsOn ? [] : work.pinnedWorkflows(in: key.folder).compactMap { id in
            workflows.first { $0.workflowID == id && !$0.isArchived }
        }
        let pinnedFlowIDs = Set(pinnedFlows.map(\.workflowID))
        pinnedWorkflows = pinnedFlows
        self.workflows = workflows.filter { !$0.isArchived && !pinnedFlowIDs.contains($0.workflowID) }
        archivedWorkflows = workflows.filter(\.isArchived)

        let shelf = work.shelf(key)
        let pinned = !pinsOn ? [] : work.pinnedSessions(in: key.folder).compactMap { work.agent($0) }
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
        // Only those no smart group lists: each session is in the sidebar once (#587), the
        // one Unread keeps too (#689).
        let kept = SidebarSmartRow.keptInUnread(keptInUnread, in: work, query: words, on: on)?.id
        sessions = groups.flatMap { group in
            group.agents.filter { SidebarSmartRow.home(of: $0, in: group.group, isPinned: false, on: on) == nil && $0.id != kept }
        }.sorted { $0.createdAt > $1.createdAt }
        let archived = shelf.groups[.archived] ?? []
        self.archived = matcher.map { archived.filter($0.matches) } ?? archived
    }
}

/// The order the sidebar lists folders in: the pinned first, then the rest; each of the
/// two this Mac's, then each server's in the order the hosts are listed (#145), each
/// host's oldest added first (#357). No headings for hosts: a server's folder carries its
/// server's name.
public enum SidebarOrder {
    /// Oldest added first, then by folder, so a row stays where it is however busy its
    /// folder is and a new folder lands at the end (#357). Ordered by activity, every
    /// `folder/changed` moved a folder to the top under the pointer. The web's
    /// `byAdded` is the same.
    public static func byAdded(_ a: DaemonAPI.FolderSummary, _ b: DaemonAPI.FolderSummary) -> Bool {
        if a.folder.addedAt != b.folder.addedAt { return a.folder.addedAt < b.folder.addedAt }
        if a.folder.folder.path != b.folder.folder.path { return a.folder.folder.path < b.folder.folder.path }
        return a.host.rawValue < b.host.rawValue
    }

    public static func folders(_ live: [DaemonAPI.FolderSummary], servers: [HostID]) -> [DaemonAPI.FolderSummary] {
        let byHost = live.filter { $0.host == .mac } + servers.flatMap { host in live.filter { $0.host == host } }
        return byHost.filter(\.folder.isPinned) + byHost.filter { !$0.folder.isPinned }
    }

    /// The name a folder's row shows: `server:Folder` on a server, so no heading is
    /// needed for each host (Alex, #145).
    public static func label(_ summary: DaemonAPI.FolderSummary, hostLabel: (HostID) -> String) -> String {
        summary.host == .mac ? summary.name : "\(hostLabel(summary.host)):\(summary.name)"
    }
}
