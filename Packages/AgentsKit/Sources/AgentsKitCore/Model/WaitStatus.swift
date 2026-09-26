import Foundation

/// What an agent is waiting on, as the chat's capsule and the row's mark say it (042
/// FR-012).
///
/// Two things are waiting: a wait on events, and 039's block on other agents. They are
/// built differently and read the same, so a block on "Fix login" and a wait on
/// `agent.finished` for that agent say exactly the same thing (research R4). Worked out
/// here once, so the Mac's row and the phone's card cannot say it two ways. Not tinted:
/// a waiting agent takes Blocked's look from its group, and this adds nothing to it.
public struct WaitStatus: Codable, Hashable, Sendable {
    /// The capsule: what, since when, until when.
    public var line: String
    /// The row and card: what, in a few words.
    public var mark: String
    /// Whether the person can cancel it from the Mac. A block is not: it goes when the
    /// person prompts, as it always has.
    public var cancellable: Bool

    public init(line: String, mark: String, cancellable: Bool) {
        self.line = line
        self.mark = mark
        self.cancellable = cancellable
    }

    public static let symbol = LeaseStatus.waitingSymbol

    /// Nil when the agent is waiting on nothing.
    public static func of(_ agent: Agent, names: (UUID) -> String?) -> WaitStatus? {
        if let wait = agent.eventWait, wait.isOpen {
            let what = described(wait.patterns, names: names)
            var line = "\(symbol) Waiting for \(what) · since \(LeaseWords.clock(wait.since))"
            if let deadline = wait.deadline { line += " · until \(LeaseWords.clock(deadline))" }
            return WaitStatus(line: line, mark: "\(symbol) Waiting for \(what)", cancellable: true)
        }
        if let block = agent.report?.block, agent.report?.isOpenBlock == true, !block.waits.isEmpty {
            let what = finishing(block.waits.map { names($0.agentID) ?? $0.nameAtReport })
            return WaitStatus(line: "\(symbol) Waiting for \(what)", mark: "\(symbol) Waiting for \(what)",
                              cancellable: false)
        }
        return nil
    }

    /// A wait's patterns in words. `agent.finished` narrowed to one agent is written as
    /// that agent finishing, which is how a block says it.
    static func described(_ patterns: [EventPattern], names: (UUID) -> String?) -> String {
        let agents = patterns.compactMap { pattern -> String? in
            guard pattern.name == "agent.finished", pattern.filters.count == 1,
                  let id = pattern.filters["agent"] else { return nil }
            return UUID(uuidString: id).flatMap(names) ?? id
        }
        if agents.count == patterns.count, !agents.isEmpty { return finishing(agents) }
        return patterns.map(\.label).joined(separator: " or ")
    }

    static func finishing(_ names: [String]) -> String {
        let quoted = names.map { "\u{201C}\($0)\u{201D}" }
        switch quoted.count {
        case 1: return "\(quoted[0]) to finish"
        case 2: return "\(quoted[0]) and \(quoted[1]) to finish"
        default: return quoted.dropLast().joined(separator: ", ") + " and \(quoted.last!) to finish"
        }
    }
}
