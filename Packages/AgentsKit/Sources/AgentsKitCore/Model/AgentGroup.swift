import Foundation

/// Where an agent sits in the panel beside its project.
///
/// Derived from the state and never stored, which is what makes it impossible for an
/// agent to be in two groups or in none. The mapping is total over `AgentState`, and a
/// test exhausts it: a state that fell through would be an agent the user cannot see.
public enum AgentGroup: String, Codable, Hashable, Sendable, CaseIterable {
    case needsAttention
    case running
    case finished
    case stopped
    case archived

    /// The heading this group is drawn under.
    public var title: String {
        switch self {
        case .needsAttention: return "Needs attention"
        case .running: return "Working"
        case .finished: return "Complete"
        case .stopped: return "Stopped"
        case .archived: return "Archived"
        }
    }

    /// The four the panel always shows, in the order it shows them. `archived` is not
    /// here because it is only drawn when the user asks for it.
    public static let live: [AgentGroup] = [.needsAttention, .running, .finished, .stopped]

    /// One state in, exactly one group out.
    ///
    /// One group per state, which is the simplest thing that can be true and the
    /// easiest to read: a run that ended cleanly and one that was stopped short are
    /// different news, and putting them under one heading made the reader do the
    /// sorting. `waitingOnUser` is the whole of "Needs attention" because both things
    /// that block an agent on the user — a permission question and an elicitation form
    /// — already put it in that state.
    public init(for state: AgentState) {
        self.init(for: state, wantsEyes: false)
    }

    /// The same, for an agent that has asked the person to look at something.
    ///
    /// `wantsEyes` is not a state and must never become one. `waitingOnUser` carries
    /// `holdsRuntime` and `hasTurnInFlight` with it, so an agent put there for showing
    /// a file would start queueing prompts, and the transition table has no way back
    /// out of it except answering a permission. Showing a file blocks nothing: the
    /// agent asked and carried on working.
    ///
    /// Still total over `(AgentState, Bool)`, so an agent is in exactly one group and
    /// never in none. An agent that is not going anywhere is not waiting on you, so
    /// the settled states ignore it.
    public init(for state: AgentState, wantsEyes: Bool) {
        switch state {
        case .waitingOnUser: self = .needsAttention
        case .running: self = wantsEyes ? .needsAttention : .running
        case .finished: self = wantsEyes ? .needsAttention : .finished
        case .stopped: self = .stopped
        case .archived: self = .archived
        }
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
    /// Which of the four this agent falls in. Leads are asked this too, but the panel
    /// never asks: it pins them above the groups instead.
    var group: AgentGroup { AgentGroup(for: state) }

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
