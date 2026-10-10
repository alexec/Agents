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
            let what = described(wait, names: names)
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
    static func described(_ wait: EventWait, names: (UUID) -> String?) -> String {
        let patterns = wait.patterns
        let agents = patterns.compactMap { pattern -> String? in
            guard pattern.name == "agent.finished", pattern.filters.count == 1,
                  let id = pattern.filters["agent"]?.single else { return nil }
            return UUID(uuidString: id).flatMap(names) ?? id
        }
        if agents.count == patterns.count, !agents.isEmpty { return finishing(agents) }
        return wait.label
    }

    /// What an event wait waits for, one thing a pattern (#582): an agent finishing by
    /// its name in quotes, as a block names it, and anything else by its label.
    static func things(_ patterns: [EventPattern], names: (UUID) -> String?) -> [String] {
        patterns.map { pattern in
            guard pattern.name == "agent.finished", pattern.filters.count == 1,
                  let id = pattern.filters["agent"]?.single else { return pattern.label }
            return "\u{201C}\(UUID(uuidString: id).flatMap(names) ?? id)\u{201D}"
        }
    }

    /// A row's one wait line (#582): "◷ Waiting for “Fix login” (+2)", the first thing
    /// it waits for and how many more. Nil when it waits for nothing.
    public static func rowLine(_ things: [String]) -> String? {
        guard let first = things.first else { return nil }
        return "\(symbol) Waiting for \(first)" + (things.count > 1 ? " (+\(things.count - 1))" : "")
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

/// Everything a waiting agent's row says about it, on one line (#582): its block, its
/// wait on events and the resources it is in line for, which used to be a line each and
/// a line an agent. The whole of it is the line's help; the chat says it in full.
public struct WaitMark: Equatable, Sendable {
    /// "◷ Waiting for “Fix login” (+2)".
    public var line: String
    /// Every line it stands for, one a line, for a tooltip or a screen reader.
    public var detail: String

    public init(line: String, detail: String) {
        self.line = line
        self.detail = detail
    }
}
