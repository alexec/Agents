import Foundation

/// What a waiting session waits on, as its mark draws it (#5022): a clock for a time, a
/// pull request, checks, other agents, a place in a lease's line, or the beacon for any
/// other wait and for a mix. Worked out from the agent's own record (its wait on events and
/// its block), so the window, the Remote and the web page (`waitKind` in `rowLines.ts`)
/// draw the same mark for the same wait.
public enum WaitKind: String, CaseIterable, Sendable {
    case time
    case pullRequest
    case checks
    case agents
    case line
    case other

    /// The SF Symbol its mark breathes. The web page draws the same shapes in `SessionRow.tsx`.
    public var symbol: String {
        switch self {
        case .time: return "clock"
        case .pullRequest: return "arrow.triangle.pull"
        case .checks: return "checkmark.seal"
        case .agents: return "person.2"
        case .line: return "lock"
        case .other: return StatusShape.waitingSymbol
        }
    }

    /// What it waits on, in words, for a screen reader: "Waiting for a pull request".
    public var spoken: String {
        switch self {
        case .time: return "Waiting for a time"
        case .pullRequest: return "Waiting for a pull request"
        case .checks: return "Waiting for checks"
        case .agents: return "Waiting for other agents"
        case .line: return "Waiting for its turn"
        case .other: return "Waiting"
        }
    }

    /// The kind of an agent's wait. A wait on events goes before a block, as the row's line
    /// names it first; `other` when it waits on nothing the app can name.
    public static func of(_ agent: Agent) -> WaitKind {
        if let wait = agent.eventWait, wait.isOpen { return of(wait) }
        if agent.report?.isOpenBlock == true, agent.report?.block?.waits.isEmpty == false { return .agents }
        return .other
    }

    public static func of(_ wait: EventWait) -> WaitKind {
        if wait.lineResource != nil { return .line }
        if wait.isTimeWait { return .time }
        let kinds = Set(wait.patterns.map { of(eventName: $0.name) })
        if kinds.count == 1, let one = kinds.first { return one }
        // A PR's own events and its checks: the PR is what it waits on.
        if kinds == [.pullRequest, .checks] { return .pullRequest }
        return .other
    }

    /// One event name's kind: `pr.*`, `checks.*` and `ci.*`, and `agent.*`.
    static func of(eventName name: String) -> WaitKind {
        if name.hasPrefix("pr.") { return .pullRequest }
        if name.hasPrefix("checks.") || name.hasPrefix("ci.") { return .checks }
        if name.hasPrefix("agent.") { return .agents }
        return .other
    }

    /// The PR a wait's server events name (#577), when they name one and only one:
    /// "#4980". Nil when they name none, or more than one.
    public static func pullRequest(of wait: EventWait) -> String? {
        let numbers = Set((wait.serverEvents ?? []).compactMap { event -> String? in
            guard let value = event.trigger.arguments["pr"] else { return nil }
            return value.intValue.map(String.init) ?? value.stringValue
        })
        guard numbers.count == 1, let number = numbers.first else { return nil }
        return "#\(number)"
    }

    /// What a wait of this kind waits on, as one thing for the row's line (#5022): "PR #4980",
    /// "checks on #4980", "until 14:30". Nil for a kind said by its patterns, one a thing, as before.
    public static func thing(of wait: EventWait) -> String? {
        switch of(wait) {
        case .time:
            return wait.deadline.map { "until \(LeaseWords.clock($0))" }
        case .pullRequest:
            return pullRequest(of: wait).map { "PR \($0)" } ?? "a pull request"
        case .checks:
            return pullRequest(of: wait).map { "checks on \($0)" } ?? "checks"
        case .agents, .line, .other:
            return nil
        }
    }
}
