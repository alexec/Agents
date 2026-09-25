import Foundation

/// Where an agent sits in the panel beside its project.
///
/// Derived from the state and never stored, which is what makes it impossible for an
/// agent to be in two groups or in none. The mapping is total over `AgentState`, and a
/// test exhausts it: a state that fell through would be an agent the user cannot see.
public enum AgentGroup: String, Codable, Hashable, Sendable, CaseIterable {
    case needsAttention
    /// Its turn ended waiting on something other than the person (039).
    case blocked
    case running
    case finished
    case stopped
    /// Put down by the person to come back to (040). Below the others and always open.
    case parked
    case archived

    /// The heading this group is drawn under.
    public var title: String {
        switch self {
        case .needsAttention: return "Needs attention"
        case .blocked: return "Blocked"
        case .running: return "Working"
        case .finished: return "Complete"
        case .stopped: return "Stopped"
        case .parked: return "Parked"
        case .archived: return "Archived"
        }
    }

    /// The ones the panel shows when they have anybody in them, in the order it shows
    /// them. `archived` is not here because it is only drawn when the user asks for it.
    /// Blocked sits under Needs attention and above Working: nearer the top than
    /// Working, because it is waiting, but below the one group that wants you (039).
    /// Parked is last, below Stopped, so every window draws its heading in the same
    /// place (040).
    public static let live: [AgentGroup] = [.needsAttention, .blocked, .running, .finished, .stopped, .parked]

    /// One state in, exactly one group out.
    ///
    /// One group per state, which is the simplest thing that can be true and the
    /// easiest to read: a run that ended cleanly and one that was stopped short are
    /// different news, and putting them under one heading made the reader do the
    /// sorting. `waitingOnUser` is the whole of "Needs attention" because both things
    /// that block an agent on the user — a permission question and an elicitation form
    /// — already put it in that state.
    ///
    /// The other three arguments are the other ways an agent comes to want a person, or
    /// not to: it asked them to look at something; it said, at the end of its turn, that
    /// it cannot get further without them; or the only thing it is doing is answering
    /// this app's own question, which is not work anybody asked for.
    ///
    /// None of them defaults, on purpose. A default of `false` on `wantsEyes` is how
    /// the daemon's project counts came to disagree with the window's list: the daemon
    /// took the free answer, the window supplied the real one, and the badge and the
    /// panel answered the same question differently. A caller that cannot know a fact
    /// has to say so where a reader can see it — `wantsEyes: false` with a reason
    /// beside it — rather than be handed "no" by the signature (FR-004). The compiler
    /// then lists every caller, which is the whole of how "one grouping" is kept.
    ///
    /// `wantsEyes` is not a state and must never become one. `waitingOnUser` carries
    /// `holdsRuntime` and `hasTurnInFlight` with it, so an agent put there for showing
    /// a file would start queueing prompts, and the transition table has no way back
    /// out of it except answering a permission. Showing a file blocks nothing: the
    /// agent asked and carried on working.
    ///
    /// An agent that is not going anywhere is not waiting on you, so the settled states
    /// ignore it.
    ///
    /// A report is not a state either, and for a sharper reason than `wantsEyes`: it
    /// describes a turn that is already over. `needsAnswer`, `partlyDone` and `stuck`
    /// each mean somebody has to do something, so a finished agent carrying one of them
    /// belongs in the one group a person actually reads — but it holds no runtime, queues
    /// no prompts, and is answered by prompting it rather than by filling in a form.
    ///
    /// `stopped` and `archived` ignore the report entirely. How a turn *ended* outranks
    /// what the agent said about the work: an agent the person put away is not waiting on
    /// them whatever it last claimed, and a run cut short is news of its own.
    ///
    /// `outcomeAsked` is the one fact the daemon already keeps to tell this app's turn
    /// from a person's: it goes up before the question after a silent ending is
    /// enqueued, and only a person's prompt takes it down — the question itself never
    /// does, because not clearing it is how the two are told apart at all. So an agent
    /// that is `running` with it set is answering the app, and nothing else. That turn
    /// is real and costs money, but it is work nobody asked for and it lasts seconds,
    /// and a panel that slides an agent into Working and back unbidden is worse than
    /// one that is briefly incomplete: the agent stays grouped as the finished one it
    /// was a moment ago, with the same eyes and report arms (FR-014, FR-018). A person's
    /// prompt clears the flag and the same agent is Working (FR-016). One that never
    /// answers ends `finished` with the flag still up, which is the unaccounted ending
    /// 014 already draws (FR-017).
    ///
    /// A blocked report (039) is the one report that is neither: nobody has to act,
    /// and the work is not settled. It gets Blocked, under the same arms — settled, or
    /// answering the app — and loses to anything that wants a person.
    ///
    /// `parked` is the person saying "later" (040). It outranks every ending and every
    /// arm above, because the person has seen the chat and chosen not to look at it now
    /// — including a report that wants them, and a workflow's turn that wakes it. Two
    /// things outrank it: `archived`, which is a firmer word than parking, and a
    /// question asked mid-turn, which blocks the agent on the person whatever else is
    /// true. A chat only marked to park when its turn ends is not parked yet, and the
    /// caller passes `false` for it.
    ///
    /// Still total over `(AgentState, Bool, WorkReport?, Bool, Bool)`, so an agent is in
    /// exactly one group and never in none.
    ///
    /// `waitingOnEvents` is an open wait on events (042): Blocked like a block, and under
    /// the same arms — settled, and outranked by wanting a person.
    public init(for state: AgentState, wantsEyes: Bool, report: WorkReport?, outcomeAsked: Bool,
                parked: Bool, waitingOnEvents: Bool = false) {
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
            self = Self.settled(wantsEyes || wantsAnswer, report, waitingOnEvents: waitingOnEvents)
        case .running: self = wantsEyes ? .needsAttention : .running
        case .finished: self = Self.settled(wantsEyes || wantsAnswer, report, waitingOnEvents: waitingOnEvents)
        case .stopped: self = .stopped
        case .archived: self = .archived
        }
    }

    /// Where a settled agent goes: Needs attention if somebody has to act, Blocked if
    /// it is waiting on something that is not a person (039), and Complete otherwise.
    /// Wanting a person outranks being blocked — an agent that asked to be looked at is
    /// asking you, whatever else it is waiting on.
    private static func settled(_ wantsAPerson: Bool, _ report: WorkReport?,
                                waitingOnEvents: Bool) -> AgentGroup {
        if wantsAPerson { return .needsAttention }
        if report?.isOpenBlock == true || waitingOnEvents { return .blocked }
        return .finished
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
                   parked: parking?.isParked == true, waitingOnEvents: eventWait?.isOpen == true)
    }

    /// Whether somebody has to do something about this agent.
    ///
    /// The two ways that becomes true: a question asked mid-turn, which holds the
    /// runtime, and an outcome reported at the end of one, which does not. Both reach
    /// the person the same way, because to them they are the same news.
    var needsAPerson: Bool {
        state == .waitingOnUser || (state == .finished && report?.outcome.needsAPerson == true)
    }

    /// Whether the person has looked at this conversation since its report landed.
    var reportIsSeen: Bool {
        guard let report else { return false }
        return reportSeenAt == report.at
    }

    /// A turn that ended cleanly, was asked how it went, and still said nothing.
    ///
    /// Not a completion — nothing vouched for it. It stays under Complete rather than
    /// competing for attention with the agents that asked for it, and is marked so the
    /// person can see which endings they can trust.
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
