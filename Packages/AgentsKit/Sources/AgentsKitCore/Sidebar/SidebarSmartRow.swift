import Foundation

/// One of the rows at the top of the sidebar that gather sessions across every project
/// and host (#495): Pinned, then by what they want — Needs You, Working, Unread. Mail's
/// Favorites and smart mailboxes, Things' Inbox and Today.
///
/// Read off each project's shelf (#165), so a folded smart row costs a sum of counts per
/// project and not a pass over every agent held; only an open one lists its sessions.
public enum SidebarSmartRow: String, CaseIterable, Hashable, Sendable {
    /// The pinned sessions (#180) and workflows (#432) of every project, in the projects'
    /// order and each project's pin order. Out of their projects' groups (Alex, #495).
    case pinned
    case needsYou, working, unread

    public var title: String {
        switch self {
        case .pinned: "Pinned"
        case .needsYou: "Needs You"
        case .working: "Working"
        case .unread: "Unread"
        }
    }

    public var systemImage: String {
        switch self {
        case .pinned: "pin"
        case .needsYou: "hand.raised"
        case .working: "circle.dotted"
        case .unread: "circle.inset.filled"
        }
    }

    /// Needs You starts open, so the first thing the window says is who is waiting;
    /// the others start folded, their counts in sight.
    public var startsOpen: Bool { self == .pinned || self == .needsYou }

    /// How many sessions it gathers across the projects named.
    @MainActor
    public func count(in work: AgentsModel, projects: [ProjectKey]) -> Int {
        projects.reduce(0) { total, key in
            let shelf = work.shelf(key)
            if self == .pinned {
                return total + Self.pinnedSessions(in: work, key).count + Self.pinnedWorkflows(in: work, key).count
            }
            // Less the pinned that would be here: they are listed once, in Pinned (#587).
            let pinnedHere = Self.pinnedSessions(in: work, key).count {
                Self.home(of: $0, in: work.group(of: $0), isPinned: false) == self
            }
            switch self {
            case .needsYou:
                return total + (shelf.counts[.needsAttention] ?? 0) + (shelf.counts[.blocked] ?? 0) - pinnedHere
            case .working:
                return total + (shelf.counts[.running] ?? 0) - pinnedHere
            case .unread:
                return total + Self.unreadAtRest(in: shelf) - pinnedHere
            case .pinned:
                return total
            }
        }
    }

    /// Where a live session is listed (#587): once, in the first of the smart groups it
    /// belongs to — Pinned, Needs You, Working, Unread — or, in none of them, under its
    /// project. Nil for its project.
    public static func home(of agent: Agent, in group: AgentGroup, isPinned: Bool) -> SidebarSmartRow? {
        if isPinned { return .pinned }
        switch group {
        case .needsAttention, .blocked: return .needsYou
        case .running: return .working
        case .archived: return nil
        default: return agent.showsUnread ? .unread : nil
        }
    }

    /// The groups whose sessions go to Needs You or Working whatever else they are.
    static let busyGroups: [AgentGroup] = [.needsAttention, .blocked, .running]

    /// The unread that are neither waiting on a person nor working: Unread's share. The
    /// busy groups are few, so this is the shelf's count less a short count of theirs.
    @MainActor
    static func unreadAtRest(in shelf: ProjectShelf) -> Int {
        shelf.unread - busyGroups.reduce(0) { $0 + (shelf.groups[$1] ?? []).count(where: \.showsUnread) }
            - (shelf.groups[.archived] ?? []).count(where: \.showsUnread)
    }

    /// Whether the sidebar draws it at all (#507): only with something in it, and while
    /// searching only with a match. Its count is a sum of counts; a search, already
    /// filtering every list, filters this one too.
    @MainActor
    public func isShown(in work: AgentsModel, projects: [ProjectKey], query: String = "") -> Bool {
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return count(in: work, projects: projects) > 0
        }
        return !agents(in: work, projects: projects, query: query).isEmpty
            || !workflows(in: work, projects: projects, query: query).isEmpty
    }

    /// The sessions it gathers, newest started first, as a search leaves them.
    @MainActor
    public func agents(in work: AgentsModel, projects: [ProjectKey], query: String = "") -> [Agent] {
        let words = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matcher = words.isEmpty ? nil : SessionLabelQuery(words)
        if self == .pinned {
            // In pin order, not by start: the order they were put in is the point.
            let pinned = projects.flatMap { Self.pinnedSessions(in: work, $0) }
            return matcher.map { pinned.filter($0.matches) } ?? pinned
        }
        let gathered = projects.flatMap { key -> [Agent] in
            let shelf = work.shelf(key)
            let held: [Agent] = switch self {
            case .pinned: []
            case .needsYou: (shelf.groups[.needsAttention] ?? []) + (shelf.groups[.blocked] ?? [])
            case .working: shelf.groups[.running] ?? []
            case .unread: AgentGroup.live.filter { !Self.busyGroups.contains($0) }
                .flatMap { shelf.groups[$0] ?? [] }.filter(\.showsUnread)
            }
            // A pinned session is listed in Pinned and nowhere else (#587).
            let pinned = Set(work.pinnedSessions(in: key.folder))
            return pinned.isEmpty ? held : held.filter { !pinned.contains($0.id) }
        }
        let shown = matcher.map { gathered.filter($0.matches) } ?? gathered
        return shown.sorted { $0.createdAt > $1.createdAt }
    }

    /// The pinned workflows of the projects named, each with its project, in pin order:
    /// only Pinned gathers workflows.
    @MainActor
    public func workflows(in work: AgentsModel, projects: [ProjectKey], query: String = "")
        -> [(project: ProjectKey, workflow: WorkflowSummary)] {
        guard self == .pinned else { return [] }
        let words = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matcher = words.isEmpty ? nil : SessionLabelQuery(words)
        return projects.flatMap { key in
            Self.pinnedWorkflows(in: work, key)
                .filter { matcher?.matches($0) ?? true }
                .map { (project: key, workflow: $0) }
        }
    }

    /// One project's pinned sessions held and not archived, in the order they were put in.
    @MainActor
    public static func pinnedSessions(in work: AgentsModel, _ key: ProjectKey) -> [Agent] {
        work.pinnedSessions(in: key.folder).compactMap { work.agent($0) }
            .filter { $0.host == key.host && $0.state != .archived }
    }

    /// One project's pinned workflows held and not archived, in their order.
    @MainActor
    public static func pinnedWorkflows(in work: AgentsModel, _ key: ProjectKey) -> [WorkflowSummary] {
        let held = work.workflows(in: key.folder)
        return work.pinnedWorkflows(in: key.folder).compactMap { id in
            held.first { $0.workflowID == id && !$0.isArchived }
        }
    }
}
