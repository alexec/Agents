import Foundation

/// The bars of the Velocity page (#4595, #4597): the PRs that landed, worked out once here for
/// the window as `UsageChart` is for Cost and Tokens; the page has `velocityChart` in
/// velocity.ts, which follows this (#4598).
///
/// The ranges are the usage charts' (`UsageChart.Range`): D is today by the hour, W the last
/// seven days, M the last thirty, and 3M the last thirteen weeks by the week. One series: a
/// merged revert is a PR that landed, and `reverted` says how many of them were reverts.
public struct VelocityChart: Sendable, Hashable {
    public typealias Range = UsageChart.Range

    public struct Bar: Sendable, Hashable, Identifiable {
        /// The first stamp the bar covers: an hour, a day, or a week's first day.
        public let stamp: String
        public let start: Date
        /// The PRs that landed in it, reverts included.
        public let merged: Int
        public var id: String { stamp }
        public var value: Double { Double(merged) }
    }

    public struct Share: Sendable, Hashable, Identifiable {
        /// The repository as the host keys it, such as `github:alexec/agents`.
        public let repo: String
        public let merged: Int
        public var id: String { repo }
        /// The repository without its forge: `alexec/agents`.
        public var name: String { VelocityChart.repoName(repo) }
    }

    public let range: Range
    public let bars: [Bar]
    /// The whole range, by repository, most PRs first.
    public let shares: [Share]
    /// Every PR that landed in the range, reverts included.
    public let total: Int
    /// The merged reverts among `total`.
    public let reverted: Int
    /// PRs a day, over the days that have any, as the usage charts' average is. For D, the
    /// day's total.
    public let average: Double

    public init(_ history: VelocityHistory, range: Range, calendar: Calendar = .current) {
        self.range = range
        let now = UsageChart.date(history.now, calendar: calendar) ?? Date()
        let slots = UsageChart.slots(range, today: calendar.startOfDay(for: now), calendar: calendar)
        let tier = range == .day ? history.hours : history.days

        var total = VelocityBucket()
        var byRepo: [String: Int] = [:]
        var daysWithData = Set<String>()
        var bars: [Bar] = []
        for slot in slots {
            var merged = 0
            for key in slot.keys {
                guard let repos = tier[key] else { continue }
                for (repo, bucket) in repos {
                    merged += bucket.merged
                    total.add(bucket)
                    byRepo[repo, default: 0] += bucket.merged
                }
                daysWithData.insert(String(key.prefix(10)))
            }
            bars.append(Bar(stamp: slot.stamp, start: slot.start, merged: merged))
        }
        self.bars = bars
        self.shares = byRepo.filter { $0.value > 0 }
            .map { Share(repo: $0.key, merged: $0.value) }
            .sorted { $0.merged != $1.merged ? $0.merged > $1.merged : $0.repo < $1.repo }
        self.total = total.merged
        self.reverted = total.reverted
        self.average = range == .day ? Double(total.merged) : Double(total.merged) / Double(max(1, daysWithData.count))
    }

    /// No PR landed in the range: the page says so rather than drawing flat bars.
    public var isEmpty: Bool { total == 0 }

    /// The figure above the bars: PRs a day in every range, so the four Usage pages read alike.
    public static let headline = "PRs a day"

    /// A count of PRs for the eye: *1 PR*, *2.4 PRs*, *46 PRs*. An average under 10 keeps one
    /// decimal, so a slow week does not read as a round number it is not.
    public static func words(_ value: Double) -> String {
        if value == 1 { return "1 PR" }
        let figure = value >= 10 || value == value.rounded()
            ? Int(value.rounded()).formatted()
            : value.formatted(.number.precision(.fractionLength(1)))
        return "\(figure) PRs"
    }

    /// The line under the bars: *Including 4 reverts.*, or *No reverts.* when there are none.
    public var revertsLine: String {
        switch reverted {
        case 0: "No reverts."
        case 1: "Including 1 revert."
        default: "Including \(reverted.formatted()) reverts."
        }
    }

    /// A repository key without its forge prefix: `github:alexec/agents` is `alexec/agents`.
    public static func repoName(_ repo: String) -> String {
        guard let colon = repo.firstIndex(of: ":") else { return repo }
        return String(repo[repo.index(after: colon)...])
    }
}

extension UsageChart {
    /// A range's bars, oldest first, each with the stamps it adds up: 24 hours of today (D),
    /// 7 or 30 days (W, M), or 13 weeks ending today (3M).
    public static func slots(_ range: Range, today: Date,
                             calendar: Calendar) -> [(stamp: String, start: Date, keys: [String])] {
        switch range {
        case .day:
            return (0..<24).map { hour in
                let start = calendar.date(byAdding: .hour, value: hour, to: today)!
                let stamp = UsageHistory.hourStamp(for: start, calendar: calendar)
                return (stamp, start, [stamp])
            }
        case .week, .month:
            let count = range == .week ? 7 : 30
            return stride(from: count - 1, through: 0, by: -1).map { back in
                let start = calendar.date(byAdding: .day, value: -back, to: today)!
                let stamp = dayStamp(start, calendar: calendar)
                return (stamp, start, [stamp])
            }
        case .threeMonths:
            return stride(from: 12, through: 0, by: -1).map { week in
                let start = calendar.date(byAdding: .day, value: -(week * 7 + 6), to: today)!
                let keys = (0..<7).map { dayStamp(calendar.date(byAdding: .day, value: $0, to: start)!, calendar: calendar) }
                return (keys[0], start, keys)
            }
        }
    }
}

extension VelocityBucket {
    public mutating func add(_ other: VelocityBucket) {
        merged += other.merged
        reverted += other.reverted
    }
}

extension VelocityHistory {
    /// Histories added up in `calendar`, the viewer's (#1267): this Mac's alone today (#4595,
    /// v1), moved into the viewer's days when the host's zone is not the viewer's.
    public static func merged(_ histories: [VelocityHistory], calendar: Calendar = .current) -> VelocityHistory {
        let tiers = HistoryMerge.merged(
            histories.map { HistoryMerge.Tiers(hours: $0.hours, days: $0.days, now: $0.now, timeZone: $0.timeZone) },
            calendar: calendar, empty: VelocityBucket(), add: { $0.add($1) })
        return VelocityHistory(hours: tiers.hours, days: tiers.days, now: tiers.now, timeZone: tiers.timeZone)
    }
}
