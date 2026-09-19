import Foundation

/// Where an agent sits in the panel beside its project.
///
/// Derived from the state and never stored, which is what makes it impossible for an
/// agent to be in two groups or in none. The mapping is total over `AgentState`, and a
/// test exhausts it: a state that fell through would be an agent the user cannot see.
public enum AgentGroup: String, Codable, Hashable, Sendable, CaseIterable {
    case needsInput
    case working
    case completed
    case archived

    /// The heading this group is drawn under.
    public var title: String {
        switch self {
        case .needsInput: return "Needs input"
        case .working: return "Working"
        case .completed: return "Completed"
        case .archived: return "Archived"
        }
    }

    /// The three the panel always shows, in the order it shows them. `archived` is not
    /// here because it is only drawn when the user asks for it.
    public static let live: [AgentGroup] = [.needsInput, .working, .completed]

    /// One state in, exactly one group out.
    ///
    /// `waitingOnUser` is the whole of "Needs input" because both things that block an
    /// agent on the user — a permission question and an elicitation form — already put
    /// it in that state. There is no second condition to keep in step.
    public init(for state: AgentState) {
        switch state {
        case .waitingOnUser: self = .needsInput
        case .running: self = .working
        case .finished, .stopped: self = .completed
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
