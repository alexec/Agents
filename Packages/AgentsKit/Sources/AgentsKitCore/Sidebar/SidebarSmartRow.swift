import Foundation

/// One of the rows at the top of the sidebar that gather sessions across every project
/// and host (#495): Pinned, then by what they want — Needs You, Working, Unread. Mail's
/// Favorites and smart mailboxes, Things' Inbox and Today.
///
/// Needs You holds everything waiting for the person (#773): sessions asking a question or
/// blocked, sessions asking to be archived (#584, #649, once their own group), and each
/// project's `approvals` — MCP servers, workflows, plugins and guarded files — as rows of
/// their own.
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

    /// Needs You starts open, so the first thing the window says is who is waiting;
    /// the others start folded, their counts in sight.
    public var startsOpen: Bool { self == .pinned || self == .needsYou }

    /// How many sessions it gathers across the projects named, and for Needs You the
    /// approvals besides. `listedOnce` false (the Mac's four columns, #866) counts every
    /// session the group fits, pinned or listed in another group too.
    @MainActor
    public func count(in work: AgentsModel, projects: [ProjectKey], listedOnce: Bool = true) -> Int {
        projects.reduce(0) { total, key in
            let shelf = work.shelf(key)
            if self == .pinned {
                return total + Self.pinnedSessions(in: work, key).count + Self.pinnedWorkflows(in: work, key).count
            }
            if !listedOnce {
                switch self {
                case .needsYou:
                    return total + (shelf.counts[.needsAttention] ?? 0) + (shelf.counts[.blocked] ?? 0)
                        + Self.askingAtRest(in: shelf) + Self.ownApprovals(in: work, key).count
                case .working:
                    return total + (shelf.counts[.running] ?? 0)
                case .unread:
                    return total + shelf.unread - (shelf.groups[.archived] ?? []).count(where: \.showsUnread)
                case .pinned:
                    return total
                }
            }
            // Less the pinned that would be here: they are listed once, in Pinned (#587).
            let pinnedHere = Self.pinnedSessions(in: work, key).count {
                Self.home(of: $0, in: work.group(of: $0), isPinned: false) == self
            }
            switch self {
            case .needsYou:
                return total + (shelf.counts[.needsAttention] ?? 0) + (shelf.counts[.blocked] ?? 0)
                    + Self.askingAtRest(in: shelf) + Self.ownApprovals(in: work, key).count - pinnedHere
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
    /// belongs to — Pinned, Needs You (asking, blocked, or asking to be archived, #773),
    /// Working, Unread — or, in none of them, under its project. Nil for its project.
    public static func home(of agent: Agent, in group: AgentGroup, isPinned: Bool) -> SidebarSmartRow? {
        if isPinned { return .pinned }
        switch group {
        case .needsAttention, .blocked: return .needsYou
        case .running: return .working
        case .archived: return nil
        default: return agent.asksToArchive ? .needsYou : agent.showsUnread ? .unread : nil
        }
    }

    /// The session Unread keeps (#495): opened from it, read now, and listed there until
    /// another is opened, so it does not leave under the pointer. Until then it is not under
    /// its project too (#689). Nil while searching, or once it belongs elsewhere: archived,
    /// pinned, waiting, working or asking to be archived.
    @MainActor
    public static func keptInUnread(_ id: UUID?, in work: AgentsModel, query: String = "") -> Agent? {
        guard query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let id,
              let kept = work.agent(id), kept.state != .archived,
              !work.pinnedSessions(in: kept.projectFolder).contains(id) else { return nil }
        switch home(of: kept, in: work.group(of: kept), isPinned: false) {
        case nil, .unread: return kept
        default: return nil
        }
    }

    /// The groups whose sessions go to Needs You or Working whatever else they are.
    static let busyGroups: [AgentGroup] = [.needsAttention, .blocked, .running]

    /// The unread that are neither waiting on a person nor working nor asking to be
    /// archived: Unread's share. The busy groups are few, so this is the shelf's count
    /// less a short count of theirs.
    @MainActor
    static func unreadAtRest(in shelf: ProjectShelf) -> Int {
        shelf.unread - busyGroups.reduce(0) { $0 + (shelf.groups[$1] ?? []).count(where: \.showsUnread) }
            - (shelf.groups[.archived] ?? []).count(where: \.showsUnread)
            - AgentGroup.live.filter { !busyGroups.contains($0) }
                .reduce(0) { $0 + (shelf.groups[$1] ?? []).count { $0.showsUnread && $0.asksToArchive } }
    }

    /// Those asking to be archived that are neither waiting on a person nor working: Needs
    /// You's share of them (#584, #773).
    @MainActor
    static func askingAtRest(in shelf: ProjectShelf) -> Int {
        shelf.asking - busyGroups.reduce(0) { $0 + (shelf.groups[$1] ?? []).count(where: \.asksToArchive) }
    }

    /// Whether the sidebar draws it at all (#507): only with something in it, and while
    /// searching only with a match. Its count is a sum of counts; a search, already
    /// filtering every list, filters this one too.
    @MainActor
    public func isShown(in work: AgentsModel, projects: [ProjectKey], query: String = "",
                        listedOnce: Bool = true) -> Bool {
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return count(in: work, projects: projects, listedOnce: listedOnce) > 0
        }
        return !agents(in: work, projects: projects, query: query, listedOnce: listedOnce).isEmpty
            || !workflows(in: work, projects: projects, query: query).isEmpty
            || !approvals(in: work, projects: projects, query: query).isEmpty
    }

    /// The sessions it gathers, newest started first, as a search leaves them. With
    /// `listedOnce` false (#866), each session it fits: pinned or not, and Unread's
    /// unread whether working or waiting too.
    @MainActor
    public func agents(in work: AgentsModel, projects: [ProjectKey], query: String = "",
                       listedOnce: Bool = true) -> [Agent] {
        let words = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matcher = words.isEmpty ? nil : SessionLabelQuery(words)
        if self == .pinned {
            // In pin order, not by start: the order they were put in is the point.
            let pinned = projects.flatMap { Self.pinnedSessions(in: work, $0) }
            return matcher.map { pinned.filter($0.matches) } ?? pinned
        }
        let gathered = projects.flatMap { key -> [Agent] in
            let shelf = work.shelf(key)
            if !listedOnce {
                let held: [Agent] = switch self {
                case .pinned: []
                case .needsYou: (shelf.groups[.needsAttention] ?? []) + (shelf.groups[.blocked] ?? [])
                    + AgentGroup.live.filter { !Self.busyGroups.contains($0) }
                    .flatMap { shelf.groups[$0] ?? [] }.filter(\.asksToArchive)
                case .working: shelf.groups[.running] ?? []
                case .unread: AgentGroup.live.flatMap { shelf.groups[$0] ?? [] }.filter(\.showsUnread)
                }
                return held
            }
            let held: [Agent] = switch self {
            case .pinned: []
            case .needsYou: (shelf.groups[.needsAttention] ?? []) + (shelf.groups[.blocked] ?? [])
                + AgentGroup.live.filter { !Self.busyGroups.contains($0) }
                .flatMap { shelf.groups[$0] ?? [] }.filter(\.asksToArchive)
            case .working: shelf.groups[.running] ?? []
            case .unread: AgentGroup.live.filter { !Self.busyGroups.contains($0) }
                .flatMap { shelf.groups[$0] ?? [] }.filter { $0.showsUnread && !$0.asksToArchive }
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

    /// What waits for an OK in the projects named, each with its project (#773): only Needs
    /// You lists them, oldest first, after its sessions. A search matches the title, the
    /// kind and the grey line.
    @MainActor
    public func approvals(in work: AgentsModel, projects: [ProjectKey], query: String = "")
        -> [(project: ProjectKey, approval: Approval)] {
        guard self == .needsYou else { return [] }
        let words = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return projects.flatMap { key in
            Self.ownApprovals(in: work, key)
                .filter { words.isEmpty || "\($0.title) \($0.kindWord) \($0.line)".lowercased().contains(words) }
                .map { (project: key, approval: $0) }
        }
        .sorted { ($0.approval.since ?? .distantPast) < ($1.approval.since ?? .distantPast) }
    }

    /// One project's approvals drawn as rows of their own: every kind but a session's
    /// archive request, which is the session's row (`home`).
    @MainActor
    public static func ownApprovals(in work: AgentsModel, _ key: ProjectKey) -> [Approval] {
        (work.project(key)?.approvals ?? []).filter { !$0.isSession }
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
