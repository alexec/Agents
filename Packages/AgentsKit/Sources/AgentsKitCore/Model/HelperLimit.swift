import Foundation

/// How many agents started by other agents a project may hold at once (028).
///
/// Fixed, and deliberately not settable, for the reason `WorkflowLimit` gives: a
/// ceiling something can raise for itself is not a ceiling. Counted across every agent
/// in the project, not per starter, so the most a project can ever hold that nobody
/// typed for is this many.
public enum HelperLimit {
    public static let perProject = 3

    /// The places in use in a project: every agent another agent started there that
    /// has not been archived, plus starts that have taken a place and not yet made
    /// their agent.
    ///
    /// Stopped and finished ones count. Only archiving gives a place back, so a
    /// project cannot quietly fill with idle agents nobody sees.
    public static func placesInUse(in project: URL, agents: some Sequence<Agent>,
                                   reserved: Int = 0) -> Int {
        let folder = Project.standardize(project)
        return helpers(in: folder, agents: agents).count + reserved
    }

    /// The agents holding a project's places, oldest first — what a refusal names.
    public static func helpers(in project: URL, agents: some Sequence<Agent>) -> [Agent] {
        let folder = Project.standardize(project)
        return agents
            .filter { $0.startedByAgent != nil && $0.state != .archived
                      && Project.standardize($0.cwd) == folder }
            .sorted { $0.createdAt < $1.createdAt }
    }
}
