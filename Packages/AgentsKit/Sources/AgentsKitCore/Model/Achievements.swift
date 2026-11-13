import Foundation

/// A first step in Agents (#984), awarded the first time a person does it. The set is
/// also the newcomer checklist: the ones not earned yet say what to try next.
public enum Achievement: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case firstAgent
    case firstPairing
    case firstRemoteAnswer
    case firstWorkflow
    case firstCloudHost
    case firstLandedPR
    case fiveAtOnce

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .firstAgent: "First agent started"
        case .firstPairing: "First phone or browser paired"
        case .firstRemoteAnswer: "First question answered away from the Mac"
        case .firstWorkflow: "First workflow made"
        case .firstCloudHost: "First cloud machine started"
        case .firstLandedPR: "First pull request landed with nobody watching"
        case .fiveAtOnce: "Five agents working at once"
        }
    }

    /// How to earn it, in one line, while it is not earned.
    public var how: String {
        switch self {
        case .firstAgent: "Start an agent and let it run a turn."
        case .firstPairing: "Pair a phone or a browser with Pair a Device…."
        case .firstRemoteAnswer: "Answer an agent's question from the Remote or the web page."
        case .firstWorkflow: "Make a workflow that runs an agent on a schedule or an event."
        case .firstCloudHost: "Start a machine on a cloud provider."
        case .firstLandedPR: "Let an agent open a pull request that merges by itself."
        case .fiveAtOnce: "Have five agents in a turn at the same time."
        }
    }
}

/// One achievement the person has earned, and when.
public struct EarnedAchievement: Codable, Hashable, Sendable {
    /// An `Achievement`'s raw value. A string, so an achievement a newer host knows is kept and
    /// passed on by an older one.
    public var id: String
    public var at: Date

    public init(id: String, at: Date) {
        self.id = id
        self.at = at
    }
}

/// The achievements a person has earned (#984), kept on the host in `achievements.json`
/// so every client shows the same set. Bounded: one entry for each achievement, never
/// more, and an entry is never changed once made.
public struct Achievements: Codable, Hashable, Sendable {
    public var earned: [EarnedAchievement]

    public init(earned: [EarnedAchievement] = []) {
        self.earned = earned
    }

    public func at(_ achievement: Achievement) -> Date? {
        earned.first { $0.id == achievement.rawValue }?.at
    }

    public func has(_ achievement: Achievement) -> Bool { at(achievement) != nil }

    /// Whether every achievement this build knows is earned: nothing is left to look for.
    public var isComplete: Bool { Achievement.allCases.allSatisfy(has) }

    /// Earn an achievement, once. Returns whether it is new.
    @discardableResult
    public mutating func earn(_ achievement: Achievement, at date: Date) -> Bool {
        guard !has(achievement) else { return false }
        earned.append(EarnedAchievement(id: achievement.rawValue, at: date))
        return true
    }

    /// The achievements in the order the page lists them: earned first, earliest first,
    /// then the rest in the order a newcomer meets them.
    public var ordered: [(achievement: Achievement, at: Date?)] {
        let done = Achievement.allCases.compactMap { m in at(m).map { (achievement: m, at: Optional($0)) } }
            .sorted { $0.at! < $1.at! }
        let open = Achievement.allCases.filter { !has($0) }.map { (achievement: $0, at: Date?.none) }
        return done + open
    }

    // MARK: Deriving

    /// Whether an agent has run a turn to its end: any time after its creation, and no
    /// turn in flight now.
    public static func hasRunATurn(_ agent: Agent) -> Bool {
        agent.lastActivityAt > agent.createdAt && !agent.state.hasTurnInFlight && agent.state != .queued
    }

    /// What the host already keeps that says an achievement was earned, and when, for the
    /// ones it can tell from records: on the first run, so what was earned before #984
    /// shipped is back-filled, and whenever those records change.
    public struct Facts: Sendable {
        /// When the first agent that has run a turn was made.
        public var firstAgent: Date?
        /// When the first phone or iPad paired.
        public var firstPairing: Date?
        /// A workflow is there now. Workflows carry no date: earned when first seen.
        public var hasWorkflow: Bool
        /// The first day a pull request from an agent's branch merged.
        public var firstLandedPR: Date?
        /// The day five or more agents first ran a turn at once.
        public var fiveAtOnce: Date?

        public init(firstAgent: Date? = nil, firstPairing: Date? = nil, hasWorkflow: Bool = false,
                    firstLandedPR: Date? = nil, fiveAtOnce: Date? = nil) {
            self.firstAgent = firstAgent
            self.firstPairing = firstPairing
            self.hasWorkflow = hasWorkflow
            self.firstLandedPR = firstLandedPR
            self.fiveAtOnce = fiveAtOnce
        }

        /// The facts the host's records hold: its agents, its paired devices, and the
        /// Time page's days and records (#985).
        public init(agents: some Sequence<Agent>, devices: some Sequence<Device>, hasWorkflow: Bool,
                    time: TimeHistory, calendar: Calendar = .current) {
            firstAgent = agents.filter(Achievements.hasRunATurn).map(\.createdAt).min()
            firstPairing = devices.map(\.announcedAt).min()
            self.hasWorkflow = hasWorkflow
            firstLandedPR = time.recap.filter { ($0.value.prsMerged ?? 0) > 0 }.keys.min()
                .flatMap { UsageChart.date($0, calendar: calendar) }
            // The days kept say when it first happened; the record outlives them.
            let fiveDay = time.recap.filter { $0.value.peakAgents >= 5 }.keys.min()
                ?? time.records.mostAgents.flatMap { $0.value >= 5 ? $0.day : nil }
            fiveAtOnce = fiveDay.flatMap { UsageChart.date($0, calendar: calendar) }
        }
    }

    /// Earn whatever `facts` says was earned and is not yet. Returns the new ones.
    @discardableResult
    public mutating func earn(from facts: Facts, now: Date) -> [Achievement] {
        let found: [(Achievement, Date?)] = [
            (.firstAgent, facts.firstAgent),
            (.firstPairing, facts.firstPairing),
            (.firstWorkflow, facts.hasWorkflow ? now : nil),
            (.firstLandedPR, facts.firstLandedPR),
            (.fiveAtOnce, facts.fiveAtOnce),
        ]
        // A date ahead of now (a day stamp read as its start, a clock moved) is now.
        return found.compactMap { achievement, at in
            guard let at, earn(achievement, at: min(at, now)) else { return nil }
            return achievement
        }
    }

    // MARK: The card

    /// Which earned achievements a client shows its one-time card for, and what it keeps as
    /// seen after. `seen` is nil the first time a client looks: everything earned so far,
    /// back-filled or not, is taken as seen, so the card is only ever for something the
    /// person just did.
    public func unseen(_ seen: Set<String>?) -> (show: [Achievement], seen: Set<String>) {
        let ids = Set(earned.map(\.id))
        guard let seen else { return ([], ids) }
        let show = ordered.compactMap { $0.at != nil && !seen.contains($0.achievement.rawValue) ? $0.achievement : nil }
        return (show, seen)
    }
}
