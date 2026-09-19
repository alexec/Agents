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
        case .running: return "Running"
        case .finished: return "Finished"
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
        switch state {
        case .waitingOnUser: self = .needsAttention
        case .running: self = .running
        case .finished: self = .finished
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
}
