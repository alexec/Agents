import Foundation

/// Where an agent sits in the panel beside its project.
///
/// Derived from the state and never stored, which is what makes it impossible for an
/// agent to be in two groups or in none. The mapping is total over `AgentState`, and a
/// test exhausts it: a state that fell through would be an agent the user cannot see.
public enum AgentGroup: String, Codable, Hashable, Sendable, CaseIterable {
    case needsAttention
    /// Legacy wire value, retained so an older project summary still decodes.
    case blocked
    /// Waiting on something the app watches — agents, a time, events — and will carry
    /// on by itself when it comes. Nobody has to do anything.
    case waiting
    case running
    case finished
    /// A turn deliberately stopped by a person or its parent agent.
    case stopped
    /// Put down by the person to come back to (040). Below the others and always open.
    case parked
    case archived

    /// The heading this group is drawn under.
    public var title: String {
        switch self {
        case .needsAttention: return "Needs you"
        case .blocked: return "Blocked"
        case .waiting: return "Waiting"
        case .running: return "Working"
        case .finished: return "Done"
        case .stopped: return "Paused"
        case .parked: return "Parked"
        case .archived: return "Archived"
        }
    }

    /// The groups shown in the panel. Archived is revealed on demand.
    /// The legacy Blocked value is decoded but no longer assigned to a session.
    public static let live: [AgentGroup] = [.needsAttention, .waiting, .running, .finished, .stopped, .parked]

    /// Place a session by what happens next. Questions, unread endings, unresolved
    /// blocks, and unexpected stops need the person; watched waits resume on their
    /// own. A deliberate stop is Paused. Parked and Archived remain explicit choices.
    /// The runtime state stays intact while this presentation changes.
    public init(for state: AgentState, wantsEyes: Bool, report: WorkReport?, outcomeAsked: Bool,
                parked: Bool, waitingOnEvents: Bool = false, isUnread: Bool = false,
                endedReason: EndedReason? = nil, waitingForAllowance: Bool = false) {
        let wantsAnswer = report?.outcome.needsAPerson == true
        if parked, state != .archived, state != .waitingOnUser {
            self = .parked
            return
        }
        switch state {
        // Grouped with the working agents, and without `running`'s `wantsEyes` arm: an
        // agent whose conversation has not begun has not asked anybody to look at
        // anything. No heading is added, renamed or removed (FR-006, FR-023).
        case .starting: self = .running
        case .waitingOnUser: self = .needsAttention
        // Answering the app's question: where it was, not Working. See above.
        case .running where outcomeAsked:
            self = Self.settled(wantsEyes || wantsAnswer || isUnread || report == nil, report,
                                waitingOnEvents: waitingOnEvents)
        case .running: self = wantsEyes ? .needsAttention : .running
        case .finished: self = Self.settled(wantsEyes || wantsAnswer || isUnread || (outcomeAsked && report == nil), report,
                                            waitingOnEvents: waitingOnEvents)
        case .stopped where waitingForAllowance: self = .waiting
        // A spent allowance is Paused, not Needs you (065, R7): the way on is a new chat,
        // which the chat itself cannot be nagged into.
        case .stopped: self = [.cancelled, .stoppedByAgent, .allowanceSpent].contains(endedReason) ? .stopped : .needsAttention
        case .archived: self = .archived
        }
    }

    /// A finished turn needs review before it can be Done. An automatic wait only
    /// wins when nobody needs to read or answer it.
    private static func settled(_ wantsAPerson: Bool, _ report: WorkReport?,
                                waitingOnEvents: Bool) -> AgentGroup {
        if wantsAPerson { return .needsAttention }
        if report?.resumesByItself == true || waitingOnEvents { return .waiting }
        if report?.isOpenBlock == true { return .needsAttention }
        return .finished
    }
}

/// One heading on the panel and the agents under it.
public struct AgentHeading: Identifiable, Sendable {
    public let title: String
    public let agents: [Agent]
    public var id: String { title }
}

public extension AgentGroup {
    /// The headings this group is drawn under, empty ones left out.
    ///
    /// Every displayed group has one heading. Reading a finished chat can move it
    /// from Needs you to Done without changing its stored state.
    func headings(_ agents: [Agent]) -> [AgentHeading] {
        agents.isEmpty ? [] : [AgentHeading(title: title, agents: agents)]
    }
}

/// So that `[AgentGroup: Int]` is a JSON object keyed by the group's name rather than a
/// flat array of alternating keys and values, which is what Swift does otherwise and
/// which nothing reading the file by eye would forgive.
extension AgentGroup: CodingKeyRepresentable {
    public var codingKey: any CodingKey { GroupKey(stringValue: rawValue) }

    public init?<T: CodingKey>(codingKey: T) {
        self.init(rawValue: codingKey.stringValue)
    }

    private struct GroupKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
}

public extension Agent {
    /// Which group this agent falls in — the one way to ask.
    ///
    /// The argument is the one fact only a window holds: whether this agent asked the
    /// person to look at something and they have not. `false` is honest from anything
    /// that is not a window — the daemon, a preview, a test asking the daemon's view —
    /// and a lie from anything that is. There is no version without the argument,
    /// because the version without it was the bug (FR-001, FR-004).
    func group(wantsEyes: Bool) -> AgentGroup {
        AgentGroup(for: state, wantsEyes: wantsEyes, report: report, outcomeAsked: outcomeAsked,
                   parked: parking?.isParked == true, waitingOnEvents: eventWait?.isOpen == true,
                   isUnread: isUnread, endedReason: endedReason, waitingForAllowance: allowanceWait != nil)
    }

    /// Whether the agent explicitly asked for an answer.
    ///
    /// The two ways that becomes true: a question asked mid-turn, which holds the
    /// runtime, and an outcome reported at the end of one, which does not. Both reach
    /// the person the same way, because to them they are the same news.
    var needsAPerson: Bool {
        state == .waitingOnUser || (state == .finished && report?.outcome.needsAPerson == true)
    }

    /// Whether the app will carry this agent on by itself: an open wait on events, or a
    /// block naming agents or a time. Unread endings can still place it under Needs you.
    var isWaiting: Bool {
        eventWait?.isOpen == true || report?.resumesByItself == true
    }

    /// Whether the person has looked at this conversation since its report landed.
    var reportIsSeen: Bool {
        guard let report else { return false }
        return reportSeenAt == report.at
    }

    /// A turn that ended cleanly, was asked how it went, and still said nothing.
    ///
    /// Not a completion — nothing vouched for it. It needs review even after being read.
    var endingIsUnaccountedFor: Bool {
        state == .finished && endedReason == .endTurn && report == nil && outcomeAsked
    }

    /// The plan it is working to, if it still stands.
    ///
    /// The last current one: a plan replaced by a newer one is history, and a
    /// withdrawn one is something the agent said it was no longer doing.
    var currentPlan: Plan? {
        plans.last { $0.state == .current }
    }

    /// What it is working on, in its own words.
    ///
    /// The step of its own plan it says it is on. This is the most useful line about a
    /// working agent that exists anywhere: a title is what it was asked three hours
    /// ago, and this is what it is doing now.
    ///
    /// Nil when it has no plan, or when nothing in the plan is in progress — an agent
    /// between steps is not working on any of them, and inventing one would be worse
    /// than saying nothing.
    var currentStep: String? {
        guard let entry = currentPlan?.entries.first(where: { $0.status == .inProgress })
        else { return nil }
        let trimmed = entry.content.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// How far through its plan it is: steps done, and steps in total.
    var planProgress: (done: Int, total: Int)? {
        guard let plan = currentPlan, !plan.entries.isEmpty else { return nil }
        return (plan.entries.count { $0.status == .completed }, plan.entries.count)
    }
}
