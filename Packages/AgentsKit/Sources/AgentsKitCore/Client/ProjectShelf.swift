import Foundation
import Observation

/// One project's agents as a client holds them: filed by group, in the order each
/// heading draws them, with the numbers its row shows (#165).
///
/// One per project, so a sidebar fold that reads its own shelf is redrawn when an agent
/// in its project changes and not when one in any other does. They used to be one
/// dictionary filed again from every agent held after every change, and every fold read
/// it: at 5,000 agents in 50 projects the window sat at 116–129 % CPU while one agent
/// changed 53 times a second, with every project folded.
///
/// Kept by `AgentsModel`, which moves an agent from one place to another as it changes.
/// Each number is its own property, so a folded row that reads only `unread` and
/// `counts` is not redrawn by a change that moves neither.
@MainActor
@Observable
public final class ProjectShelf {
    /// Each group's agents, newest activity first; Parked, most recently parked first
    /// (040, FR-003).
    public private(set) var groups: [AgentGroup: [Agent]] = [:]
    /// How many agents are in each group, by the client's own grouping.
    public private(set) var counts: [AgentGroup: Int] = [:]
    /// Finished and not opened since, whichever group they are under (#70).
    public private(set) var unread = 0
    /// Needs you, Blocked, and the unread under the rest: what the badge counts.
    public private(set) var attention = 0
    /// Needs you, and the unread under the rest: what Next Needing Attention visits.
    public private(set) var toVisit = 0

    init() {}

    var isEmpty: Bool { groups.isEmpty }

    /// Put in where its group's order says, or taken out, then the numbers again.
    func insert(_ agent: Agent, in group: AgentGroup) {
        var list = groups[group] ?? []
        list.insert(agent, at: Self.place(of: agent, in: list, group: group))
        groups[group] = list
        settle()
    }

    func remove(_ agent: Agent, from group: AgentGroup) {
        guard var list = groups[group] else { return }
        if let at = Self.index(of: agent, in: list, group: group) {
            list.remove(at: at)
        } else if let at = list.firstIndex(where: { $0.id == agent.id }) {
            list.remove(at: at)
        } else {
            return
        }
        groups[group] = list.isEmpty ? nil : list
        settle()
    }

    /// The agent changed and stays in its group at the same place: a label, a usage.
    func replace(_ old: Agent, with new: Agent, in group: AgentGroup) -> Bool {
        guard var list = groups[group], let at = Self.index(of: old, in: list, group: group),
              Self.ordered(group)(at == 0 ? nil : list[at - 1], new),
              Self.ordered(group)(new, at + 1 < list.count ? list[at + 1] : nil) else { return false }
        list[at] = new
        groups[group] = list
        settle()
        return true
    }

    /// Everything at once, from a list already filed.
    func replaceAll(_ filed: [AgentGroup: [Agent]]) {
        if groups != filed { groups = filed }
        settle()
    }

    private func settle() {
        let counts = groups.mapValues(\.count)
        if self.counts != counts { self.counts = counts }
        let unread = groups.values.reduce(0) { $0 + $1.count(where: \.showsUnread) }
        if self.unread != unread { self.unread = unread }
        let attention = groups.reduce(0) { total, bucket in
            total + (bucket.key == .needsAttention || bucket.key == .blocked
                ? bucket.value.count : bucket.value.count(where: \.showsUnread))
        }
        if self.attention != attention { self.attention = attention }
        let toVisit = groups.reduce(0) { total, bucket in
            total + (bucket.key == .needsAttention ? bucket.value.count
                : AgentGroup.live.contains(bucket.key) ? bucket.value.count(where: \.showsUnread) : 0)
        }
        if self.toVisit != toVisit { self.toVisit = toVisit }
    }

    // MARK: Order

    /// Newest activity first, then by id, so two agents with the same moment are always
    /// in the same order.
    nonisolated static func byActivity(_ a: Agent, _ b: Agent) -> Bool {
        if a.lastActivityAt != b.lastActivityAt { return a.lastActivityAt > b.lastActivityAt }
        return a.id.uuidString < b.id.uuidString
    }

    /// Parked reads most recently parked first; the rest, newest activity first.
    nonisolated static func order(_ group: AgentGroup) -> (Agent, Agent) -> Bool {
        guard group == .parked else { return byActivity }
        return { a, b in
            let at = a.parking?.parkedAt ?? .distantPast, bt = b.parking?.parkedAt ?? .distantPast
            return at != bt ? at > bt : byActivity(a, b)
        }
    }

    /// Whether `a` may stand before `b` (nil being either end).
    private static func ordered(_ group: AgentGroup) -> (Agent?, Agent?) -> Bool {
        let before = order(group)
        return { a, b in
            guard let a, let b else { return true }
            return !before(b, a)
        }
    }

    /// Where `agent` goes in `list`, which is in the group's order.
    static func place(of agent: Agent, in list: [Agent], group: AgentGroup) -> Int {
        let before = order(group)
        var low = 0, high = list.count
        while low < high {
            let mid = (low + high) / 2
            if before(list[mid], agent) { low = mid + 1 } else { high = mid }
        }
        return low
    }

    /// Where `agent`, as it was filed, is in `list`.
    static func index(of agent: Agent, in list: [Agent], group: AgentGroup) -> Int? {
        let at = place(of: agent, in: list, group: group)
        return at < list.count && list[at].id == agent.id ? at : nil
    }
}

/// One agent as a client holds it, for a row that looks its agent up by id on every
/// render (`AgentRow`, `AgentCard`): reading it ties the row to this agent and no other.
@MainActor
@Observable
final class AgentCell {
    var agent: Agent?

    init(_ agent: Agent?) {
        self.agent = agent
    }
}
