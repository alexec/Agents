import Foundation

/// How many agents started by other agents a project may hold at once (028, #64).
///
/// Two limits, both counted across every agent in the project rather than per starter:
/// how many may be **running**, and how many may exist **not yet archived**. A start is
/// refused if it would break either.
///
/// The person sets both per project, in Project Settings ▸ General, and only the person:
/// the setting is an operator's (`projects/setHelperLimits` is in neither the agent's
/// nor the device's allowlist), for the reason `WorkflowLimit` gives — a ceiling
/// something can raise for itself is not a ceiling. And the person's own setting has a
/// hard maximum, so a typo cannot let a project fill.
public enum HelperLimit {
    /// What a project with no setting gets.
    public static let defaultRunning = 3
    public static let defaultNotArchived = 5
    /// The most either can ever be set to, by anybody.
    public static let maximumRunning = 10
    public static let maximumNotArchived = 20

    /// The places in use in a project: every agent another agent started there that
    /// has not been archived, plus starts that have taken a place and not yet made
    /// their agent.
    ///
    /// Stopped, finished and parked ones count. Only archiving gives this place back,
    /// so a project cannot quietly fill with idle agents nobody sees.
    public static func placesInUse(in project: URL, agents: some Sequence<Agent>,
                                   reserved: Int = 0) -> Int {
        helpers(in: project, agents: agents).count + reserved
    }

    /// How many of a project's helpers are running, plus starts that have taken a
    /// place and not yet made their agent. See `isRunning`.
    public static func running(in project: URL, agents: some Sequence<Agent>,
                               reserved: Int = 0, comingBack: Set<UUID> = []) -> Int {
        runningHelpers(in: project, agents: agents, comingBack: comingBack).count + reserved
    }

    /// Whether a helper holds a running place.
    ///
    /// Running is anything that is using a runtime now or will start using one again
    /// without the person doing anything:
    /// - `starting`, `running` and `waitingOnUser` — working, or mid-turn on a
    ///   permission question or a form;
    /// - a finished or stopped agent the app will carry on by itself: an open wait on
    ///   events, a block that names agents or a time (039), or a wait for an allowance
    ///   to come back (052);
    /// - one the daemon is bringing back after a restart (`comingBack`).
    ///
    /// Not running: finished, stopped, parked, a block only the person can clear, and
    /// archived. One set to park when its turn ends is still in that turn, so it counts
    /// until it parks.
    public static func isRunning(_ agent: Agent, comingBack: Set<UUID> = []) -> Bool {
        if agent.state == .archived { return false }
        if agent.parking?.isParked == true { return false }
        if agent.state.hasTurnInFlight { return true }
        if comingBack.contains(agent.id) { return true }
        return agent.isWaiting || agent.allowanceWait != nil
    }

    /// The agents holding a project's not-archived places, oldest first — what a
    /// refusal names.
    public static func helpers(in project: URL, agents: some Sequence<Agent>) -> [Agent] {
        let folder = Project.standardize(project)
        return agents
            .filter { $0.startedByAgent != nil && $0.state != .archived
                      && $0.projectFolder == folder }
            .sorted { $0.createdAt < $1.createdAt }
    }

    /// The agents holding a project's running places, oldest first.
    public static func runningHelpers(in project: URL, agents: some Sequence<Agent>,
                                      comingBack: Set<UUID> = []) -> [Agent] {
        helpers(in: project, agents: agents).filter { isRunning($0, comingBack: comingBack) }
    }
}

/// One project's two helper limits, as the person set them (#64). Kept on `Project`.
///
/// Each is nil until the person sets it, which is the default; `effective` is what is
/// enforced, clamped to the hard maximums whatever the file says, so a hand-edited
/// `projects.json` cannot raise a ceiling either.
public struct HelperLimits: Codable, Hashable, Sendable {
    public var running: Int?
    public var notArchived: Int?

    public init(running: Int? = nil, notArchived: Int? = nil) {
        self.running = running
        self.notArchived = notArchived
    }

    /// What is enforced: each limit, or its default, between 1 and its maximum.
    /// Running is never more than not archived, since every running helper is one not
    /// archived.
    public var effective: (running: Int, notArchived: Int) {
        let places = Self.clamp(notArchived ?? HelperLimit.defaultNotArchived, to: HelperLimit.maximumNotArchived)
        let running = Self.clamp(running ?? HelperLimit.defaultRunning, to: HelperLimit.maximumRunning)
        return (min(running, places), places)
    }

    private static func clamp(_ value: Int, to maximum: Int) -> Int {
        Swift.max(1, Swift.min(value, maximum))
    }

    /// Why a setting cannot be kept, in the person's words; nil when it can.
    public var problem: String? {
        if let running, !(1...HelperLimit.maximumRunning).contains(running) {
            return "Running helpers must be between 1 and \(HelperLimit.maximumRunning)."
        }
        if let notArchived, !(1...HelperLimit.maximumNotArchived).contains(notArchived) {
            return "Helpers not yet archived must be between 1 and \(HelperLimit.maximumNotArchived)."
        }
        let (running, places) = (running ?? HelperLimit.defaultRunning,
                                 notArchived ?? HelperLimit.defaultNotArchived)
        if running > places {
            return "Running helpers (\(running)) cannot be more than helpers not yet archived (\(places))."
        }
        return nil
    }

    /// Nil when both are the defaults, so a project that never changed them keeps no
    /// record of it.
    public var orNilIfDefault: HelperLimits? {
        running == nil && notArchived == nil ? nil : self
    }
}
