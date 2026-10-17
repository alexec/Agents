import Foundation

/// What the work used over time, by runtime (#823): cost and tokens, drawn as Health
/// draws steps.
///
/// Bounded, as every store is: the last 168 hours are kept by the hour and the last 90
/// days by the day, per runtime, so the worst case is 258 buckets a runtime whatever
/// the work. Both tiers are written on every turn, so a day never has to be folded
/// out of its hours and the two cannot disagree.
public struct UsageHistory: Codable, Sendable, Hashable {
    /// `yyyy-MM-ddTHH` in the host's own calendar, then runtime id.
    public var hours: [String: [String: UsageBucket]]
    /// `yyyy-MM-dd` in the host's own calendar, then runtime id.
    public var days: [String: [String: UsageBucket]]
    /// The host's hour when this was read. A client never asks its own clock what
    /// "today" is: it may be in another time zone from the host that stamped these.
    public var now: String
    /// The zone those stamps are in, an IANA identifier (#1267). Nil from a host too old
    /// to say, read as the viewer's own.
    public var timeZone: String?

    public static let hoursKept = 168
    public static let daysKept = 90

    /// Cost the history was seeded with from `spend.json`, which never said which
    /// runtime spent it (#823). Named "Earlier" wherever a runtime is.
    public static let unattributed = ""

    public init(hours: [String: [String: UsageBucket]] = [:],
                days: [String: [String: UsageBucket]] = [:], now: String = "", timeZone: String? = nil) {
        self.hours = hours
        self.days = days
        self.now = now
        self.timeZone = timeZone
    }

    public var isEmpty: Bool { hours.isEmpty && days.isEmpty }

    /// Add one turn's worth into both tiers.
    public mutating func add(_ bucket: UsageBucket, runtime: String, hour: String) {
        hours[hour, default: [:]][runtime, default: UsageBucket()].add(bucket)
        days[String(hour.prefix(10)), default: [:]][runtime, default: UsageBucket()].add(bucket)
    }

    /// Drop what is past the bound. By count rather than by date: a clock moved back
    /// cannot make the file grow, and an idle week keeps older days rather than none.
    public mutating func prune() {
        let hoursKept = Set(hours.keys.sorted().suffix(Self.hoursKept))
        hours = hours.filter { hoursKept.contains($0.key) }
        let daysKept = Set(days.keys.sorted().suffix(Self.daysKept))
        days = days.filter { daysKept.contains($0.key) }
    }

    /// The host's local hour, `yyyy-MM-ddTHH`.
    public static func hourStamp(for date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day, .hour], from: date)
        return String(format: "%04d-%02d-%02dT%02d", parts.year ?? 0, parts.month ?? 0,
                      parts.day ?? 0, parts.hour ?? 0)
    }
}

/// What one runtime used in one hour or one day.
public struct UsageBucket: Codable, Sendable, Hashable {
    /// Per currency, never added across.
    public var cost: [String: Decimal]
    public var inputTokens: Int
    public var outputTokens: Int
    public var thoughtTokens: Int
    public var cachedReadTokens: Int
    public var cachedWriteTokens: Int
    public var turns: Int
    /// Turns on an agent whose runtime has never quoted it a price, so the cost here is
    /// a floor rather than the whole (`Agent.isUnmeasured`).
    public var unpricedTurns: Int

    public init(cost: [String: Decimal] = [:], inputTokens: Int = 0, outputTokens: Int = 0,
                thoughtTokens: Int = 0, cachedReadTokens: Int = 0, cachedWriteTokens: Int = 0,
                turns: Int = 0, unpricedTurns: Int = 0) {
        self.cost = cost
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.thoughtTokens = thoughtTokens
        self.cachedReadTokens = cachedReadTokens
        self.cachedWriteTokens = cachedWriteTokens
        self.turns = turns
        self.unpricedTurns = unpricedTurns
    }

    /// One turn's tokens. Its cost is banked on its own, as it arrives.
    public init(turn usage: TurnUsage, priced: Bool) {
        self.init(inputTokens: usage.inputTokens, outputTokens: usage.outputTokens,
                  thoughtTokens: usage.thoughtTokens ?? 0,
                  cachedReadTokens: usage.cachedReadTokens ?? 0,
                  cachedWriteTokens: usage.cachedWriteTokens ?? 0,
                  turns: 1, unpricedTurns: priced ? 0 : 1)
    }

    public init(cost: Cost) {
        self.init(cost: [cost.currency: cost.amount])
    }

    /// What the work asked for and got back. Cache reads are counted apart: they are
    /// most of every total and would hide the rest.
    public var freshTokens: Int { inputTokens + outputTokens + thoughtTokens + cachedWriteTokens }

    public mutating func add(_ other: UsageBucket) {
        for (currency, amount) in other.cost { cost[currency, default: 0] += amount }
        inputTokens += other.inputTokens
        outputTokens += other.outputTokens
        thoughtTokens += other.thoughtTokens
        cachedReadTokens += other.cachedReadTokens
        cachedWriteTokens += other.cachedWriteTokens
        turns += other.turns
        unpricedTurns += other.unpricedTurns
    }
}
