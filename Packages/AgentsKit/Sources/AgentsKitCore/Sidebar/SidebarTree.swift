import Foundation

/// One list of the sidebar with each session under the session that started it (#835): a
/// lead's lanes, a lane's helpers.
///
/// Each session sits under the nearest of its starters that the same list holds, at every
/// depth, one more indent a level up to `maxIndent` (#3553; one indent whatever the depth
/// put a lane's helper under a later lane, #495). Folded by default, the fold kept per row.
/// A folded parent's mark is the most urgent of its own and its live descendants'. A tree
/// in each list: a session is still listed once (#587), under its parent only when the
/// same list holds the parent, otherwise as a row of its own with the started-by mark.
///
/// The list stays flat, the children indented rows of it, so no row moves from one parent
/// to another in `NSOutlineView` (#237).
public enum SidebarTree {
    /// The deepest indent drawn; a row deeper still sits at this one, so the sidebar keeps
    /// its width.
    public static let maxIndent = 3

    /// One row as the list draws it.
    public struct Row: Identifiable, Sendable {
        public let agent: Agent
        /// How many parents it sits under in the list: 0 at the top.
        public let depth: Int
        /// How many of the list's rows it started itself: the rows its fold shows.
        public let children: Int
        /// For a parent, whether its children are shown.
        public let isUnfolded: Bool
        public var id: UUID { agent.id }
        /// Under another row of the list.
        public var isChild: Bool { depth > 0 }
        /// How many indents in it is drawn.
        public var indent: Int { min(depth, SidebarTree.maxIndent) }
    }

    /// `list`, in its order, with each session taken out from where it was and put under
    /// the nearest of its starters the list also holds, oldest started first: the rows at
    /// the top, and each parent's own children. `starter` says who started a session the
    /// list does not hold, so a chain is followed through one listed elsewhere.
    public static func nest(_ list: [Agent], starter: (UUID) -> UUID?) -> (tops: [Agent], children: [UUID: [Agent]]) {
        let listed = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var parentOf: [UUID: UUID] = [:]
        for agent in list {
            var parent: UUID?
            var seen: Set<UUID> = [agent.id]
            var next = agent.startedByAgent
            while let id = next {
                // A chain that comes back on itself is no chain: the session stands alone.
                guard seen.insert(id).inserted else { parent = nil; break }
                if parent == nil, listed[id] != nil { parent = id }
                next = listed[id]?.startedByAgent ?? starter(id)
            }
            if let parent { parentOf[agent.id] = parent }
        }
        var children: [UUID: [Agent]] = [:]
        for agent in list {
            if let parent = parentOf[agent.id] { children[parent, default: []].append(agent) }
        }
        for key in children.keys { children[key]?.sort { $0.createdAt < $1.createdAt } }
        return (list.filter { parentOf[$0.id] == nil }, children)
    }

    /// The rows to draw: each parent, then, while it is unfolded, each of its children with
    /// that child's own rows under it.
    public static func rows(_ list: [Agent], starter: (UUID) -> UUID?, isOpen: (UUID) -> Bool) -> [Row] {
        let (tops, children) = nest(list, starter: starter)
        func rows(of agent: Agent, depth: Int) -> [Row] {
            let own = children[agent.id] ?? []
            let open = !own.isEmpty && isOpen(agent.id)
            let row = Row(agent: agent, depth: depth, children: own.count, isUnfolded: open)
            guard open else { return [row] }
            return [row] + own.flatMap { rows(of: $0, depth: depth + 1) }
        }
        return tops.flatMap { rows(of: $0, depth: 0) }
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
