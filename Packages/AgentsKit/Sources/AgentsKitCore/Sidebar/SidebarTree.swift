import Foundation

/// One list of the sidebar with each session under the session that started it (#835): a
/// lead's lanes, a lane's helpers.
///
/// Settled with Alex: one indent whatever the depth, so a lane's helpers sit under the
/// lead with the lane, oldest first, and the sidebar keeps its depth (#495). Folded by
/// default, the fold kept per row. A folded parent's mark is the most urgent of its own
/// and its live descendants'. A tree in each list: a session is still listed once (#587),
/// under its parent only when the same list holds the parent, otherwise as a row of its
/// own with the started-by mark, as before.
///
/// The list stays flat, the children indented rows of it, so no row moves from one parent
/// to another in `NSOutlineView` (#237).
public enum SidebarTree {
    /// One row as the list draws it.
    public struct Row: Identifiable, Sendable {
        public let agent: Agent
        /// Under the session at the top of its chain: drawn one indent in.
        public let isChild: Bool
        /// For a row at the top, how many of the list's rows are under it; none for a child.
        public let children: Int
        /// For a parent, whether its children are shown.
        public let isUnfolded: Bool
        public var id: UUID { agent.id }
    }

    /// `list`, in its order, with each session taken out from where it was and put under
    /// the highest of its starters the list also holds, oldest started first. `starter`
    /// says who started a session the list does not hold, so a chain is followed through
    /// one listed elsewhere.
    public static func nest(_ list: [Agent], starter: (UUID) -> UUID?) -> [(agent: Agent, children: [Agent])] {
        let listed = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var topOf: [UUID: UUID] = [:]
        for agent in list {
            var top = agent.id
            var seen: Set<UUID> = [agent.id]
            var next = agent.startedByAgent
            while let id = next {
                // A chain that comes back on itself is no chain: the session stands alone.
                guard seen.insert(id).inserted else { top = agent.id; break }
                if listed[id] != nil { top = id }
                next = listed[id]?.startedByAgent ?? starter(id)
            }
            topOf[agent.id] = top
        }
        var children: [UUID: [Agent]] = [:]
        for agent in list {
            if let top = topOf[agent.id], top != agent.id { children[top, default: []].append(agent) }
        }
        return list.filter { topOf[$0.id] == $0.id }.map { agent in
            (agent, (children[agent.id] ?? []).sorted { $0.createdAt < $1.createdAt })
        }
    }

    /// The rows to draw: each parent, then its children while it is unfolded.
    public static func rows(_ list: [Agent], starter: (UUID) -> UUID?, isOpen: (UUID) -> Bool) -> [Row] {
        nest(list, starter: starter).flatMap { parent, children -> [Row] in
            let open = !children.isEmpty && isOpen(parent.id)
            let top = Row(agent: parent, isChild: false, children: children.count, isUnfolded: open)
            guard open else { return [top] }
            return [top] + children.map { Row(agent: $0, isChild: true, children: 0, isUnfolded: false) }
        }
    }

    /// The rows of a list as the model holds it.
    @MainActor
    public static func rows(_ list: [Agent], in work: AgentsModel, folds: SidebarFolds) -> [Row] {
        rows(list, starter: { work.starter(of: $0) }, isOpen: { folds.isOpen(session: $0) })
    }

    /// The session whose mark a folded parent shows (#835): the most urgent of the parent
    /// and its live descendants — needs you, asks to be archived, working, waiting, unread,
    /// paused, done — the parent on a tie.
    @MainActor
    public static func markAgent(of parent: Agent, in work: AgentsModel) -> Agent {
        var shown = parent
        var rank = urgency(of: parent, in: work.group(of: parent))
        for child in work.liveDescendants(of: parent.id) {
            let own = urgency(of: child, in: work.group(of: child))
            if own < rank { (shown, rank) = (child, own) }
        }
        return shown
    }

    /// How urgent a session's mark is, the most urgent lowest: the order of the marks.
    public static func urgency(of agent: Agent, in group: AgentGroup) -> Int {
        switch group {
        case .needsAttention, .blocked: 0
        case _ where agent.asksToArchive: 1
        case .running: 2
        case .waiting: 3
        case .finished where agent.showsUnread: 4
        case .stopped: 5
        case .finished: 6
        case .archived: 7
        }
    }
}
