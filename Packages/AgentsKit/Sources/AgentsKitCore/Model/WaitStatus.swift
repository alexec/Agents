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
    /// The chat's wait card (#1995): what, since when, until when.
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

    /// Nil when the agent is waiting on nothing. A place in a lease's line (#2361) is said
    /// as the line says it: "◷ Waiting for build · held by “Fix login” until 14:12 · 2nd in
    /// line", from `lease` when the daemon has said its leases.
    public static func of(_ agent: Agent, names: (UUID) -> String?, lease: LeaseStatus? = nil) -> WaitStatus? {
        if let wait = agent.eventWait, wait.isOpen, let resource = wait.lineResource {
            let place = lease?.waiting.first { $0.name == resource }
            let what = place.map { place in
                "\(place.displayName) · held by \(place.holderName)"
                    + (place.until.map { " until \(LeaseWords.clock($0))" } ?? "")
                    + " · \(LeaseWords.ordinal(place.place)) in line"
            } ?? "your turn with \(resource)"
            let short = place.map { "\($0.shortName) · \(LeaseWords.ordinal($0.place)) in line" } ?? resource.key
            return WaitStatus(line: "\(symbol) Waiting for \(what)", mark: "\(symbol) Waiting for \(short)", cancellable: true)
        }
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
    /// that agent finishing, which is how a block says it, also beside other patterns
    /// (#3236): "“Tidy tests” to finish or ci.finished".
    static func described(_ wait: EventWait, names: (UUID) -> String?) -> String {
        let agents = wait.patterns.map { finishedAgent($0, names: names) }
        let named = agents.compactMap { $0 }
        if named.count == agents.count, !named.isEmpty { return finishing(named) }
        return zip(agents, wait.labels).map { agent, label in agent.map { finishing([$0]) } ?? label }
            .joined(separator: " or ")
    }

    /// The agent's name, or its id, when the pattern is `agent.finished` narrowed to one
    /// agent. Nil for any other pattern.
    static func finishedAgent(_ pattern: EventPattern, names: (UUID) -> String?) -> String? {
        guard pattern.name == "agent.finished", pattern.filters.count == 1,
              let id = pattern.filters["agent"]?.single else { return nil }
        return UUID(uuidString: id).flatMap(names) ?? id
    }

    /// What an event wait waits for, one thing a pattern (#582): an agent finishing by
    /// its name in quotes, as a block names it, and anything else by its label.
    static func things(_ wait: EventWait, names: (UUID) -> String?, lease: LeaseStatus? = nil) -> [String] {
        // A place in a line, by the resource's short name, as the lease mark had it.
        if let resource = wait.lineResource {
            return [lease?.waiting.first { $0.name == resource }?.shortName ?? resource.key]
        }
        return things(wait.patterns, names: names)
    }

    static func things(_ patterns: [EventPattern], names: (UUID) -> String?) -> [String] {
        patterns.map { pattern in
            finishedAgent(pattern, names: names).map { "\u{201C}\($0)\u{201D}" } ?? pattern.label
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
