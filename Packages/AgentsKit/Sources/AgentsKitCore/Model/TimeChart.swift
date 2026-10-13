import Foundation

/// The bars of the Time page (#852), worked out once here for the window and the Remote;
/// the page has `timeChart` in time.ts, which follows this.
///
/// The ranges are the usage charts' (`UsageChart.Range`): D is today by the hour, W the
/// last seven days, M the last thirty, and 3M the last thirteen weeks by the week. Each
/// bar is stacked by kind of time. Chats run side by side, so an hour can hold more
/// than an hour of chat time.
public struct TimeChart: Sendable, Hashable {
    public typealias Range = UsageChart.Range

    public struct Bar: Sendable, Hashable, Identifiable {
        public let stamp: String
        public let start: Date
        public let time: TimeBucket
        public var id: String { stamp }
        public var total: Double { time.total }
    }

    public struct Share: Sendable, Hashable, Identifiable {
        public let runtime: String
        public let time: TimeBucket
        public var id: String { runtime }
    }

    public let range: Range
    public let bars: [Bar]
    /// The whole range, by kind.
    public let time: TimeBucket
    /// The whole range, by runtime, most time first.
    public let shares: [Share]
    /// Per day, over the days that have any time, as Health's average does. For D, the
    /// day's total.
    public let average: Double

    public init(_ history: TimeHistory, range: Range, calendar: Calendar = .current) {
        self.range = range
        let now = UsageChart.date(history.now, calendar: calendar) ?? Date()
        let today = calendar.startOfDay(for: now)

        var slots: [(stamp: String, start: Date, keys: [String])] = []
        let tier: [String: [String: TimeBucket]]
        switch range {
        case .day:
            tier = history.hours
            for hour in 0..<24 {
                let start = calendar.date(byAdding: .hour, value: hour, to: today)!
                let stamp = UsageHistory.hourStamp(for: start, calendar: calendar)
                slots.append((stamp, start, [stamp]))
            }
        case .week, .month:
            tier = history.days
            let count = range == .week ? 7 : 30
            for back in stride(from: count - 1, through: 0, by: -1) {
                let start = calendar.date(byAdding: .day, value: -back, to: today)!
                let stamp = UsageChart.dayStamp(start, calendar: calendar)
                slots.append((stamp, start, [stamp]))
            }
        case .threeMonths:
            tier = history.days
            for week in stride(from: 12, through: 0, by: -1) {
                let start = calendar.date(byAdding: .day, value: -(week * 7 + 6), to: today)!
                let keys = (0..<7).map {
                    UsageChart.dayStamp(calendar.date(byAdding: .day, value: $0, to: start)!, calendar: calendar)
                }
                slots.append((keys[0], start, keys))
            }
        }

        var merged = TimeBucket()
        var byRuntime: [String: TimeBucket] = [:]
        var daysWithData = Set<String>()
        var bars: [Bar] = []
        for slot in slots {
            var bucket = TimeBucket()
            for key in slot.keys {
                guard let runtimes = tier[key] else { continue }
                for (runtime, time) in runtimes {
                    bucket.add(time)
                    byRuntime[runtime, default: TimeBucket()].add(time)
                }
                if runtimes.values.contains(where: { $0.total > 0 }) { daysWithData.insert(String(key.prefix(10))) }
            }
            merged.add(bucket)
            bars.append(Bar(stamp: slot.stamp, start: slot.start, time: bucket))
        }
        self.bars = bars
        self.time = merged
        self.shares = byRuntime.map { Share(runtime: $0.key, time: $0.value) }
            .filter { $0.time.total > 0 }
            .sorted { $0.time.total != $1.time.total ? $0.time.total > $1.time.total : $0.runtime < $1.runtime }
        self.average = range == .day ? merged.total : merged.total / Double(max(1, daysWithData.count))
    }

    public var isEmpty: Bool { time.total == 0 }

    /// The figure above the bars, as Health words it.
    public var headline: String { range == .day ? "Total" : "Daily average" }

    /// A share of the whole, as a whole percent: "42%".
    public func percent(_ seconds: Double) -> String {
        guard time.total > 0 else { return "0%" }
        return "\(Int((seconds / time.total * 100).rounded()))%"
    }

    /// A length of time read at a glance: 45s, 12m, 3h 20m, 140h.
    public static func words(_ seconds: Double) -> String {
        let seconds = max(0, seconds)
        if seconds < 60 { return "\(Int(seconds.rounded()))s" }
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours >= 100 { return "\(hours)h" }
        let rest = minutes % 60
        return rest == 0 ? "\(hours)h" : "\(hours)h \(rest)m"
    }
}
