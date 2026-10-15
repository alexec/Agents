import Foundation

/// One day's recap figures (#985), beside the day's time by kind in `TimeHistory.days`.
/// Kept for the same 90 days.
public struct DayRecap: Codable, Sendable, Hashable {
    /// Pull requests merged that day from the branches the app makes (`agents/…`), as
    /// `gh` said. Nil when `gh` was never asked about the day, or could not answer.
    public var prsMerged: Int?
    /// Agents that ran a turn that day.
    public var agents: Int
    /// The most agents in a turn at the same time.
    public var peakAgents: Int
    /// The longest stretch, in seconds, that agents ran with none waiting for the person.
    public var longestClear: Double

    public init(prsMerged: Int? = nil, agents: Int = 0, peakAgents: Int = 0, longestClear: Double = 0) {
        self.prsMerged = prsMerged
        self.agents = agents
        self.peakAgents = peakAgents
        self.longestClear = longestClear
    }
}

/// A personal best, and the day it was set.
public struct TimeRecord: Codable, Sendable, Hashable {
    public var value: Double
    /// `yyyy-MM-dd` in the host's own calendar.
    public var day: String

    public init(value: Double, day: String) {
        self.value = value
        self.day = day
    }
}

/// The person's records (#985): three values, kept for ever, so a record outlives the
/// 90 days of figures it came from. Nothing here counts tokens or cost, and nothing
/// breaks on a day off.
public struct TimeRecords: Codable, Sendable, Hashable {
    /// The most agents in a turn at the same time.
    public var mostAgents: TimeRecord?
    /// The most pull requests merged in a day.
    public var mostPRs: TimeRecord?
    /// The longest stretch, in seconds, with no agent waiting for the person.
    public var longestClear: TimeRecord?

    public init(mostAgents: TimeRecord? = nil, mostPRs: TimeRecord? = nil, longestClear: TimeRecord? = nil) {
        self.mostAgents = mostAgents
        self.mostPRs = mostPRs
        self.longestClear = longestClear
    }

    public var isEmpty: Bool { mostAgents == nil && mostPRs == nil && longestClear == nil }

    /// Take a day's figures as records where they beat the ones held. A tie keeps the
    /// earlier day.
    public mutating func note(_ recap: DayRecap, day: String) {
        Self.beat(&mostAgents, Double(recap.peakAgents), day: day)
        Self.beat(&mostPRs, Double(recap.prsMerged ?? 0), day: day)
        Self.beat(&longestClear, recap.longestClear, day: day)
    }

    private static func beat(_ record: inout TimeRecord?, _ value: Double, day: String) {
        guard value > 0, value > (record?.value ?? 0) else { return }
        record = TimeRecord(value: value, day: day)
    }
}
