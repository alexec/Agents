import Foundation

/// How many agents started by other agents a project may hold at once (028, #64).
///
/// Two limits, both counted across every agent in the project rather than per starter:
/// how many may be **running**, and how many may exist **not yet archived**. A start
/// that would break either is **queued** (#362): saved, nothing spawned, and started by
/// the daemon, oldest first, once both have a place. A third limit says how many may
/// wait in that queue; a start past it is refused. Queued helpers count only against
/// the queue, and take their other places when they start.
///
/// The person sets both per project, in Project Settings ▸ General, and only the person:
/// `projects/setHelperLimits` is not in the agent's allowlist, for the reason
/// `WorkflowLimit` gives — a ceiling something can raise for itself is not a ceiling.
/// They are kept in the project's own `.agents/project.json` (#126), so they travel with
/// it. And the setting has a hard maximum, enforced whatever the file says, so neither a
/// typo nor a hand edit can let a project fill.
public enum HelperLimit {
    /// What a project with no setting gets.
    public static let defaultRunning = 3
    public static let defaultNotArchived = 5
    /// The most either can ever be set to, by anybody.
    public static let maximumRunning = 10
    public static let maximumNotArchived = 20
    /// How many may wait in a project's queue (#362), by default and at most.
    public static let defaultQueued = 5
    public static let maximumQueued = 20
    /// Whether an agent may archive the agents it started (#120) in a project with no
    /// setting. On: a lead that archives its finished helpers frees their places
    /// without waiting on the person, who can still bring any of them back.
    public static let defaultAgentsMayArchive = true

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
    /// refusal names. Queued ones hold none yet.
    public static func helpers(in project: URL, agents: some Sequence<Agent>) -> [Agent] {
        let folder = Project.standardize(project)
        return agents
            .filter { $0.startedByAgent != nil && $0.state != .archived && $0.state != .queued
                      && $0.projectFolder == folder }
            .sorted { $0.createdAt < $1.createdAt }
    }

    /// A project's queue (#362), first in first: the order they will start in.
    public static func queue(in project: URL, agents: some Sequence<Agent>) -> [Agent] {
        let folder = Project.standardize(project)
        return agents
            .filter { $0.state == .queued && $0.projectFolder == folder }
            .sorted { ($0.createdAt, $0.id.uuidString) < ($1.createdAt, $1.id.uuidString) }
    }

    /// Where a queued agent stands in its project's queue, counting from 1; nil when it
    /// is not queued. What a row says ("Queued, 2nd") and what `list_my_agents` says.
    public static func queuePosition(of agent: Agent, among agents: some Sequence<Agent>) -> Int? {
        guard agent.state == .queued else { return nil }
        return queue(in: agent.projectFolder, agents: agents).firstIndex { $0.id == agent.id }.map { $0 + 1 }
    }

    /// What a row calls a queued agent, in all three clients: "Queued", or with its
    /// place when it has one ("Queued, 1st").
    public static func queuedLabel(position: Int?) -> String {
        guard let position else { return "Queued" }
        return "Queued, \(ordinal(position))"
    }

    public static func ordinal(_ n: Int) -> String {
        let tens = n % 100
        let suffix = (11...13).contains(tens) ? "th"
            : [1: "st", 2: "nd", 3: "rd"][n % 10] ?? "th"
        return "\(n)\(suffix)"
    }

    /// The agents holding a project's running places, oldest first.
    public static func runningHelpers(in project: URL, agents: some Sequence<Agent>,
                                      comingBack: Set<UUID> = []) -> [Agent] {
        helpers(in: project, agents: agents).filter { isRunning($0, comingBack: comingBack) }
    }
}

/// One project's helper limits, as the person set them (#64, #362), and whether agents
/// may archive the helpers they started (#120). Kept in `.agents/project.json` (#126).
///
/// Each is nil until the person sets it, which is the default; `effective` is what is
/// enforced, clamped to the hard maximums whatever the file says, so a hand-edited
/// `.agents/project.json` cannot raise a ceiling either.
public struct HelperLimits: Codable, Hashable, Sendable {
    public var running: Int?
    public var notArchived: Int?
    /// How many may wait in the queue (#362). Nil is `HelperLimit.defaultQueued`.
    public var queued: Int?
    /// Whether `archive_agent` is answered in this project (#120). Nil is the default,
    /// `HelperLimit.defaultAgentsMayArchive`.
    public var agentsMayArchive: Bool?

    public init(running: Int? = nil, notArchived: Int? = nil, queued: Int? = nil,
                agentsMayArchive: Bool? = nil) {
        self.running = running
        self.notArchived = notArchived
        self.queued = queued
        self.agentsMayArchive = agentsMayArchive
    }

    /// Whether agents may archive the helpers they started here: the person's
    /// choice, or the default.
    public var mayArchive: Bool { agentsMayArchive ?? HelperLimit.defaultAgentsMayArchive }

    /// What is enforced: each limit, or its default, between 1 and its maximum.
    /// Running is never more than not archived, since every running helper is one not
    /// archived.
    public var effective: (running: Int, notArchived: Int) {
        let places = Self.clamp(notArchived ?? HelperLimit.defaultNotArchived, to: HelperLimit.maximumNotArchived)
        let running = Self.clamp(running ?? HelperLimit.defaultRunning, to: HelperLimit.maximumRunning)
        return (min(running, places), places)
    }

    /// How many may wait in the queue: the person's number, or the default, between 1
    /// and its maximum whatever the file says.
    public var effectiveQueued: Int {
        Self.clamp(queued ?? HelperLimit.defaultQueued, to: HelperLimit.maximumQueued)
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
        if let queued, !(1...HelperLimit.maximumQueued).contains(queued) {
            return "Queued helpers must be between 1 and \(HelperLimit.maximumQueued)."
        }
        let (running, places) = (running ?? HelperLimit.defaultRunning,
                                 notArchived ?? HelperLimit.defaultNotArchived)
        if running > places {
            return "Running helpers (\(running)) cannot be more than helpers not yet archived (\(places))."
        }
        return nil
    }

    /// Nil when all four are the defaults, so a project that never changed them keeps
    /// no record of it. The switch set to its default is kept as no choice at all.
    public var orNilIfDefault: HelperLimits? {
        var kept = self
        if kept.agentsMayArchive == HelperLimit.defaultAgentsMayArchive { kept.agentsMayArchive = nil }
        return kept.running == nil && kept.notArchived == nil && kept.queued == nil
            && kept.agentsMayArchive == nil ? nil : kept
    }
}
