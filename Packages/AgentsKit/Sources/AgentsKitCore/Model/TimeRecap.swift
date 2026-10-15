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

/// What the recap at the top of the Time page says (#985), worked out once here for the
/// window and the Remote; the page has `timeRecap` in time.ts, which follows this.
public struct TimeRecap: Sendable, Hashable {
    public struct Figures: Sendable, Hashable {
        /// Nil when `gh` said nothing about any of the days.
        public var prsMerged: Int?
        public var turns: Int = 0
        /// Agents that ran a turn, added up day by day: an agent that ran on two days
        /// counts on both.
        public var agents: Int = 0
        /// The agent's own time: thinking, writing and its tools.
        public var agentTime: Double = 0
        /// The time agents waited for the person.
        public var personTime: Double = 0
        public var peakAgents: Int = 0

        /// Agent hours for each hour of the person's own time. Nil until the person
        /// was waited on for a minute: a ratio over seconds says nothing.
        public var leverage: Double? {
            personTime >= 60 && agentTime > 0 ? agentTime / personTime : nil
        }

        public var isEmpty: Bool { turns == 0 && agents == 0 && (prsMerged ?? 0) == 0 }
    }

    public let today: Figures
    /// Today and the six days before it.
    public let week: Figures
    public let records: TimeRecords

    public init(_ history: TimeHistory, calendar: Calendar = .current) {
        let now = UsageChart.date(history.now, calendar: calendar) ?? Date()
        let today = calendar.startOfDay(for: now)
        let days = (0..<7).map { UsageChart.dayStamp(calendar.date(byAdding: .day, value: -$0, to: today)!, calendar: calendar) }
        self.today = Self.figures(history, days: [days[0]])
        self.week = Self.figures(history, days: days)
        self.records = history.records
    }

    static func figures(_ history: TimeHistory, days: [String]) -> Figures {
        var figures = Figures()
        for day in days {
            for bucket in (history.days[day] ?? [:]).values {
                figures.turns += bucket.turns
                figures.agentTime += bucket.agent + bucket.tools
                figures.personTime += bucket.person
            }
            guard let recap = history.recap[day] else { continue }
            if let prs = recap.prsMerged { figures.prsMerged = (figures.prsMerged ?? 0) + prs }
            figures.agents += recap.agents
            figures.peakAgents = max(figures.peakAgents, recap.peakAgents)
        }
        return figures
    }

    /// "6.2×", or a dash when there is no figure.
    public static func leverageWords(_ leverage: Double?) -> String {
        guard let leverage else { return "–" }
        return leverage >= 10 ? "\(Int(leverage.rounded()))×" : String(format: "%.1f×", leverage)
    }

    /// A record's day, as "12 Oct 2026".
    public static func dayWords(_ day: String, calendar: Calendar = .current) -> String {
        guard let date = UsageChart.date(day, calendar: calendar) else { return day }
        return date.formatted(.dateTime.day().month(.abbreviated).year())
    }
}
