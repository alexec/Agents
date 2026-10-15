import Foundation

/// A first step in Agents (#984), awarded the first time a person does it. The set is
/// also the newcomer checklist: the ones not earned yet say what to try next.
public enum Milestone: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
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
        case .firstCloudHost: "First cloud host started"
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
        case .firstCloudHost: "Start a workspace on a cloud provider."
        case .firstLandedPR: "Let an agent open a pull request that merges by itself."
        case .fiveAtOnce: "Have five agents in a turn at the same time."
        }
    }
}

/// One milestone the person has earned, and when.
public struct EarnedMilestone: Codable, Hashable, Sendable {
    /// A `Milestone`'s raw value. A string, so a milestone a newer host knows is kept and
    /// passed on by an older one.
    public var id: String
    public var at: Date

    public init(id: String, at: Date) {
        self.id = id
        self.at = at
    }
}

/// The milestones a person has earned (#984), kept on the host in `achievements.json`
/// so every client shows the same set. Bounded: one entry for each milestone, never
/// more, and an entry is never changed once made.
public struct Milestones: Codable, Hashable, Sendable {
    public var earned: [EarnedMilestone]

    public init(earned: [EarnedMilestone] = []) {
        self.earned = earned
    }

    public func at(_ milestone: Milestone) -> Date? {
        earned.first { $0.id == milestone.rawValue }?.at
    }

    public func has(_ milestone: Milestone) -> Bool { at(milestone) != nil }

    /// Whether every milestone this build knows is earned: nothing is left to look for.
    public var isComplete: Bool { Milestone.allCases.allSatisfy(has) }

    /// Earn a milestone, once. Returns whether it is new.
    @discardableResult
    public mutating func earn(_ milestone: Milestone, at date: Date) -> Bool {
        guard !has(milestone) else { return false }
        earned.append(EarnedMilestone(id: milestone.rawValue, at: date))
        return true
    }

    /// The milestones in the order the page lists them: earned first, earliest first,
    /// then the rest in the order a newcomer meets them.
    public var ordered: [(milestone: Milestone, at: Date?)] {
        let done = Milestone.allCases.compactMap { m in at(m).map { (milestone: m, at: Optional($0)) } }
            .sorted { $0.at! < $1.at! }
        let open = Milestone.allCases.filter { !has($0) }.map { (milestone: $0, at: Date?.none) }
        return done + open
    }

    // MARK: Deriving

    /// What the host already keeps that says a milestone was earned, and when, for the
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
            firstAgent = agents.filter(GetStarted.hasRunATurn).map(\.createdAt).min()
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
    public mutating func earn(from facts: Facts, now: Date) -> [Milestone] {
        let found: [(Milestone, Date?)] = [
            (.firstAgent, facts.firstAgent),
            (.firstPairing, facts.firstPairing),
            (.firstWorkflow, facts.hasWorkflow ? now : nil),
            (.firstLandedPR, facts.firstLandedPR),
            (.fiveAtOnce, facts.fiveAtOnce),
        ]
        // A date ahead of now (a day stamp read as its start, a clock moved) is now.
        return found.compactMap { milestone, at in
            guard let at, earn(milestone, at: min(at, now)) else { return nil }
            return milestone
        }
    }

    // MARK: The card

    /// Which earned milestones a client shows its one-time card for, and what it keeps as
    /// seen after. `seen` is nil the first time a client looks: everything earned so far,
    /// back-filled or not, is taken as seen, so the card is only ever for something the
    /// person just did.
    public func unseen(_ seen: Set<String>?) -> (show: [Milestone], seen: Set<String>) {
        let ids = Set(earned.map(\.id))
        guard let seen else { return ([], ids) }
        let show = ordered.compactMap { $0.at != nil && !seen.contains($0.milestone.rawValue) ? $0.milestone : nil }
        return (show, seen)
    }
}
