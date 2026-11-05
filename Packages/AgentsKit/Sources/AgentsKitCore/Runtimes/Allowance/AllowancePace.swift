import Foundation

/// A plan's week against an even pace, and its past weeks (#3438), from the weekly
/// readings the daemon keeps on a credential (`AllowanceState.weeks`). Like a reading,
/// this is only ever shown: it never decides whether a turn can run.
public struct AllowancePace: Hashable, Sendable {
    /// The latest reading of the week now running, when the runtime gave an amount.
    public var current: AllowanceReading?
    /// The final reading of each week that has reset, oldest first.
    public var past: [AllowanceReading]

    public static let week: TimeInterval = 7 * 86400

    /// The pace of the state's weekly window: Claude's `seven_day` or Grok's `weekly`
    /// first, then the window of the newest week kept. Nil when it kept no week.
    public init?(_ state: AllowanceState?, now: Date) {
        guard let weeks = state?.weeks, !weeks.isEmpty else { return nil }
        let windows = weeks.compactMap(\.window)
        guard let window = ["seven_day", "weekly"].first(where: windows.contains) ?? windows.last else { return nil }
        let mine = weeks.filter { $0.window == window && $0.resetsAt != nil && $0.usedFraction != nil }
        current = mine.last { $0.isCurrent(now: now) }
        past = mine.filter { !$0.isCurrent(now: now) }
        if current == nil && past.isEmpty { return nil }
    }

    /// What an even pace leaves of the current week at its reading, from 0 to 1: the
    /// share of the week still to go then.
    public var evenLeft: Double? {
        guard let current, let resetsAt = current.resetsAt else { return nil }
        return min(max(resetsAt.timeIntervalSince(current.at) / Self.week, 0), 1)
    }

    public enum Verdict: Hashable, Sendable { case faster, even, slower }

    /// Faster when more than five points less is left than an even pace leaves, slower
    /// when more than five points more is.
    public var verdict: Verdict? {
        guard let left = current?.left, let even = evenLeft else { return nil }
        if left < even - 0.05 { return .faster }
        if left > even + 0.05 { return .slower }
        return .even
    }
}

extension PoolWords {
    /// The pace line under the reading (#3438): "3 days to go · used faster than an even
    /// pace (43% left)". With the amount first, "28% left this week · …", when the
    /// reading line says another window. Nil when no week is running.
    public static func pace(_ state: AllowanceState?, now: Date) -> String? {
        guard let pace = AllowancePace(state, now: now), let current = pace.current,
              let resetsAt = current.resetsAt, let left = current.left,
              let even = pace.evenLeft, let verdict = pace.verdict else { return nil }
        var parts: [String] = []
        if let reading = state?.reading, reading.window == current.window, reading.resetsAt == current.resetsAt,
           reading.isCurrent(now: now) {
            // The reading line above says the amount already.
        } else {
            parts.append(left <= 0 ? "None left this week" : "\(percent(left)) left this week")
        }
        parts.append(toGo(resetsAt.timeIntervalSince(now)))
        switch verdict {
        case .faster: parts.append("used faster than an even pace (\(percent(even)) left)")
        case .slower: parts.append("used slower than an even pace (\(percent(even)) left)")
        case .even: parts.append("on an even pace")
        }
        return parts.joined(separator: " · ")
    }

    /// The past weeks in words, for VoiceOver and the chart's label: "Past weeks: 62%,
    /// 71%, 90% used". Nil when no week has reset yet.
    public static func pastWeeks(_ state: AllowanceState?, now: Date) -> String? {
        guard let past = AllowancePace(state, now: now)?.past, !past.isEmpty else { return nil }
        let shares = past.compactMap(\.usedFraction).map(percent)
        return "Past weeks: \(shares.joined(separator: ", ")) used"
    }

    /// "3 days to go", "1 day to go", "5 hours to go", "Under an hour to go", to the
    /// nearest day or hour, so that it agrees with the reset day the reading line says.
    static func toGo(_ interval: TimeInterval) -> String {
        let days = Int((interval / 86400).rounded())
        if days > 1 { return "\(days) days to go" }
        if interval >= 86400 { return "1 day to go" }
        let hours = Int((interval / 3600).rounded())
        if hours > 1 { return "\(hours) hours to go" }
        if hours == 1 { return "1 hour to go" }
        return "Under an hour to go"
    }

    static func percent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }
}
